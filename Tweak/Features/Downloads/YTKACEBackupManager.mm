#import "YTKACEBackupManager.h"
#import "DownloadLog.h"
#import "../../Runtime/Preferences.h"

#include <zlib.h>

static NSString * const YTKACEBackupErrorDomain = @"YTKACEBackup";
static const NSUInteger YTKACEMaxBackupEntries = 10000;
static const uint64_t YTKACEMaxBackupEntrySize = 16ULL * 1024ULL * 1024ULL * 1024ULL;
static const uint64_t YTKACEMaxBackupTotalSize = 64ULL * 1024ULL * 1024ULL * 1024ULL;

static BOOL YTKACEIsRestorablePreference(NSString *key, id value) {
    return [key isKindOfClass:NSString.class] &&
        [key hasPrefix:@"YTKACE.Preference."] && value != nil &&
        [NSPropertyListSerialization propertyList:value
                                 isValidForFormat:NSPropertyListXMLFormat_v1_0];
}

static NSError *YTKACEBackupError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTKACEBackupErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Backup failed"}];
}

static NSError *YTKACEBackupException(NSException *exception) {
    NSString *message = exception.reason.length != 0
        ? exception.reason : @"The backup file could not be written";
    return YTKACEBackupError(13, message);
}

static NSData *YTKACEReadData(NSFileHandle *handle,
                              NSUInteger length,
                              NSError **error) {
    @try {
        return [handle readDataOfLength:length];
    } @catch (NSException *exception) {
        if (error != NULL) *error = YTKACEBackupException(exception);
        return nil;
    }
}

static BOOL YTKACEWriteData(NSFileHandle *handle,
                            NSData *data,
                            NSError **error) {
    @try {
        [handle writeData:data];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = YTKACEBackupException(exception);
        return NO;
    }
}

static void YTKACEAppend16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void YTKACEAppend32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void YTKACEAppend64(NSMutableData *data, uint64_t value) {
    uint8_t bytes[] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24),
        (uint8_t)(value >> 32), (uint8_t)(value >> 40),
        (uint8_t)(value >> 48), (uint8_t)(value >> 56)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t YTKACERead16(const uint8_t *bytes) {
    return (uint16_t)(bytes[0] | (bytes[1] << 8));
}

static uint32_t YTKACERead32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t YTKACERead64(const uint8_t *bytes) {
    return (uint64_t)YTKACERead32(bytes) |
        ((uint64_t)YTKACERead32(bytes + 4) << 32);
}

static NSString *YTKACERelativePath(NSURL *URL, NSURL *baseURL) {
    NSString *path = URL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *base = baseURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *prefix = [base stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    return [path substringFromIndex:prefix.length];
}

static NSDictionary *YTKACEBackupSettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    // dictionaryRepresentation is the reliable source: preferences are written
    // through standardUserDefaults, and persistentDomainForName: returns nil for
    // the app's own domain here, which produced an empty backup plist.
    NSMutableDictionary *domain =
        [[defaults dictionaryRepresentation] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (bundleID.length != 0) {
        NSDictionary *persistent = [defaults persistentDomainForName:bundleID];
        if ([persistent isKindOfClass:NSDictionary.class]) {
            [domain addEntriesFromDictionary:persistent];
        }
    }
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    NSSet *named = [NSSet setWithArray:@[
        @"YTKACE.Preference.Playback.WiFiQuality", @"YTKACE.Preference.Playback.CellularQuality", @"YTKACE.Preference.SponsorBlock.Mode",
        @"YTKACE.Preference.SponsorBlock.Enabled", @"YTKACE.Preference.Downloads.ClearOnStartup",
        @"YTKACE.Preference.SponsorBlock.AudioFeedback"
    ]];
    [domain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:NSString.class]) return;
        if (![key hasPrefix:@"YTKACE.Preference."] &&
            ![named containsObject:key]) {
            return;
        }
        if (![NSPropertyListSerialization propertyList:value
                                     isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            return;
        }
        settings[key] = value;
    }];
    YTKACEDownloadLog(@"backup", @"captured %lu settings",
                      (unsigned long)settings.count);
    return settings;
}

static void YTKACEApplyBackupSettings(NSDictionary *settings) {
    if (![settings isKindOfClass:NSDictionary.class]) {
        YTKACEDownloadLog(@"backup", @"restore skipped: no settings in backup");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    __block NSUInteger applied = 0;
    [settings enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (YTKACEIsRestorablePreference(key, value)) {
            [defaults setObject:value forKey:key];
            applied++;
        }
    }];
    [defaults synchronize];
    YTKACEDownloadLog(@"backup", @"restored %lu of %lu settings",
                      (unsigned long)applied, (unsigned long)settings.count);
}

static uint32_t YTKACECRCAndSize(NSURL *URL, uint64_t *size, NSError **error) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (handle == nil) return 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t total = 0;
    while (true) {
        @autoreleasepool {
            NSData *chunk = YTKACEReadData(handle, 4 * 1024 * 1024, error);
            if (chunk == nil || chunk.length == 0) break;
            crc = crc32(crc, (const Bytef *)chunk.bytes, (uInt)chunk.length);
            total += chunk.length;
        }
        if (error != NULL && *error != nil) break;
    }
    [handle closeFile];
    if (error != NULL && *error != nil) return 0;
    *size = total;
    return (uint32_t)crc;
}

static BOOL YTKACECopyFileToHandle(NSURL *URL, NSFileHandle *output, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (input == nil) return NO;
    while (true) {
        @autoreleasepool {
            NSData *chunk = YTKACEReadData(input, 4 * 1024 * 1024, error);
            if (chunk == nil || chunk.length == 0) break;
            if (!YTKACEWriteData(output, chunk, error)) break;
        }
        if (error != NULL && *error != nil) break;
    }
    [input closeFile];
    return error == NULL || *error == nil;
}

static BOOL YTKACEWriteZip(NSURL *outputURL,
                           NSArray<NSDictionary *> *entries,
                           NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager removeItemAtURL:outputURL error:nil];
    [manager createFileAtPath:outputURL.path contents:nil attributes:nil];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
    if (output == nil) return NO;
    NSMutableArray<NSDictionary *> *central = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSURL *URL = entry[@"url"];
        NSData *name = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        if (name.length > UINT16_MAX) {
            if (error != NULL) *error = YTKACEBackupError(3, @"A backup path is too long");
            [output closeFile];
            return NO;
        }
        uint64_t size = 0;
        uint32_t crc = YTKACECRCAndSize(URL, &size, error);
        if (error != NULL && *error != nil) {
            [output closeFile];
            return NO;
        }
        uint64_t offset64 = output.offsetInFile;
        BOOL largeFile = size >= UINT32_MAX;
        NSMutableData *extra = [NSMutableData data];
        if (largeFile) {
            YTKACEAppend16(extra, 0x0001);
            YTKACEAppend16(extra, 16);
            YTKACEAppend64(extra, size);
            YTKACEAppend64(extra, size);
        }
        NSMutableData *header = [NSMutableData data];
        YTKACEAppend32(header, 0x04034b50);
        YTKACEAppend16(header, largeFile ? 45 : 20);
        YTKACEAppend16(header, 0x0800);
        YTKACEAppend16(header, 0);
        YTKACEAppend16(header, 0);
        YTKACEAppend16(header, 0);
        YTKACEAppend32(header, crc);
        YTKACEAppend32(header, largeFile ? UINT32_MAX : (uint32_t)size);
        YTKACEAppend32(header, largeFile ? UINT32_MAX : (uint32_t)size);
        YTKACEAppend16(header, (uint16_t)name.length);
        YTKACEAppend16(header, (uint16_t)extra.length);
        [header appendData:name];
        [header appendData:extra];
        if (!YTKACEWriteData(output, header, error)) {
            [output closeFile];
            return NO;
        }
        if (!YTKACECopyFileToHandle(URL, output, error)) {
            [output closeFile];
            return NO;
        }
        [central addObject:@{
            @"name": name, @"crc": @(crc), @"size": @(size),
            @"offset": @(offset64)
        }];
    }
    uint64_t centralOffset = output.offsetInFile;
    BOOL needsZip64 = central.count >= UINT16_MAX || centralOffset >= UINT32_MAX;
    for (NSDictionary *entry in central) {
        NSData *name = entry[@"name"];
        uint64_t size = [entry[@"size"] unsignedLongLongValue];
        uint64_t offset = [entry[@"offset"] unsignedLongLongValue];
        BOOL largeFile = size >= UINT32_MAX;
        BOOL largeOffset = offset >= UINT32_MAX;
        BOOL largeEntry = largeFile || largeOffset;
        needsZip64 = needsZip64 || largeEntry;
        NSMutableData *extra = [NSMutableData data];
        if (largeEntry) {
            NSMutableData *values = [NSMutableData data];
            if (largeFile) {
                YTKACEAppend64(values, size);
                YTKACEAppend64(values, size);
            }
            if (largeOffset) YTKACEAppend64(values, offset);
            YTKACEAppend16(extra, 0x0001);
            YTKACEAppend16(extra, (uint16_t)values.length);
            [extra appendData:values];
        }
        NSMutableData *record = [NSMutableData data];
        YTKACEAppend32(record, 0x02014b50);
        YTKACEAppend16(record, largeEntry ? 45 : 20);
        YTKACEAppend16(record, largeEntry ? 45 : 20);
        YTKACEAppend16(record, 0x0800);
        YTKACEAppend16(record, 0);
        YTKACEAppend16(record, 0);
        YTKACEAppend16(record, 0);
        YTKACEAppend32(record, [entry[@"crc"] unsignedIntValue]);
        YTKACEAppend32(record, largeFile ? UINT32_MAX : (uint32_t)size);
        YTKACEAppend32(record, largeFile ? UINT32_MAX : (uint32_t)size);
        YTKACEAppend16(record, (uint16_t)name.length);
        YTKACEAppend16(record, (uint16_t)extra.length);
        YTKACEAppend16(record, 0);
        YTKACEAppend16(record, 0);
        YTKACEAppend16(record, 0);
        YTKACEAppend32(record, 0);
        YTKACEAppend32(record, largeOffset ? UINT32_MAX : (uint32_t)offset);
        [record appendData:name];
        [record appendData:extra];
        if (!YTKACEWriteData(output, record, error)) {
            [output closeFile];
            return NO;
        }
    }
    uint64_t centralSize = output.offsetInFile - centralOffset;
    needsZip64 = needsZip64 || centralSize >= UINT32_MAX;
    if (needsZip64) {
        uint64_t zip64Offset = output.offsetInFile;
        NSMutableData *zip64 = [NSMutableData data];
        YTKACEAppend32(zip64, 0x06064b50);
        YTKACEAppend64(zip64, 44);
        YTKACEAppend16(zip64, 45);
        YTKACEAppend16(zip64, 45);
        YTKACEAppend32(zip64, 0);
        YTKACEAppend32(zip64, 0);
        YTKACEAppend64(zip64, central.count);
        YTKACEAppend64(zip64, central.count);
        YTKACEAppend64(zip64, centralSize);
        YTKACEAppend64(zip64, centralOffset);
        if (!YTKACEWriteData(output, zip64, error)) {
            [output closeFile];
            return NO;
        }
        NSMutableData *locator = [NSMutableData data];
        YTKACEAppend32(locator, 0x07064b50);
        YTKACEAppend32(locator, 0);
        YTKACEAppend64(locator, zip64Offset);
        YTKACEAppend32(locator, 1);
        if (!YTKACEWriteData(output, locator, error)) {
            [output closeFile];
            return NO;
        }
    }
    NSMutableData *end = [NSMutableData data];
    YTKACEAppend32(end, 0x06054b50);
    YTKACEAppend16(end, 0);
    YTKACEAppend16(end, 0);
    YTKACEAppend16(end, needsZip64 ? UINT16_MAX : (uint16_t)central.count);
    YTKACEAppend16(end, needsZip64 ? UINT16_MAX : (uint16_t)central.count);
    YTKACEAppend32(end, needsZip64 ? UINT32_MAX : (uint32_t)centralSize);
    YTKACEAppend32(end, needsZip64 ? UINT32_MAX : (uint32_t)centralOffset);
    YTKACEAppend16(end, 0);
    if (!YTKACEWriteData(output, end, error)) {
        [output closeFile];
        return NO;
    }
    [output closeFile];
    return YES;
}

static uint64_t YTKACEBackupSize(NSArray<NSDictionary *> *entries) {
    uint64_t total = 0;
    for (NSDictionary *entry in entries) {
        @autoreleasepool {
            NSNumber *size = nil;
            [entry[@"url"] getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            uint64_t value = size.unsignedLongLongValue;
            if (UINT64_MAX - total < value) return UINT64_MAX;
            total += value;
        }
    }
    return total;
}

static BOOL YTKACEHasBackupSpace(NSURL *URL,
                                 uint64_t required,
                                 NSError **error) {
    NSNumber *available = nil;
    [URL getResourceValue:&available
                   forKey:NSURLVolumeAvailableCapacityForImportantUsageKey
                    error:nil];
    if (available == nil) return YES;
    uint64_t reserve = 128ULL * 1024ULL * 1024ULL;
    if (required <= UINT64_MAX - reserve &&
        available.unsignedLongLongValue >= required + reserve) return YES;
    if (error != NULL) {
        *error = YTKACEBackupError(14, @"Not enough free space to create the backup");
    }
    return NO;
}

static NSArray<NSDictionary *> *YTKACEBackupEntries(NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = YTKACEApplicationSupportDirectory();
    NSURL *settingsURL = [root URLByAppendingPathComponent:@"SettingsBackup.plist"];
    if (![YTKACEBackupSettings() writeToURL:settingsURL atomically:YES]) {
        if (error != NULL) *error = YTKACEBackupError(6, @"Settings could not be saved");
        return nil;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithObject:@{
        @"url": settingsURL, @"name": @"SettingsBackup.plist"
    }];
    NSURL *downloads = [root URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *items = [manager enumeratorAtURL:downloads
        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                           options:NSDirectoryEnumerationSkipsHiddenFiles
                      errorHandler:nil];
    for (NSURL *URL in items) {
        NSNumber *regular = nil;
        [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        NSString *relative = YTKACERelativePath(URL, downloads);
        if (relative.length == 0) continue;
        [entries addObject:@{
            @"url": URL,
            @"name": [@"Downloads" stringByAppendingPathComponent:relative]
        }];
    }
    return entries;
}

static BOOL YTKACEExtractStoredZip(NSURL *URL, NSURL *destination, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (input == nil) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSUInteger entryCount = 0;
    uint64_t totalSize = 0;
    while (true) {
        NSData *fixed = [input readDataOfLength:30];
        if (fixed.length == 0) break;
        if (fixed.length < 4) {
            if (error != NULL) *error = YTKACEBackupError(7, @"The backup is incomplete");
            [input closeFile];
            return NO;
        }
        const uint8_t *bytes = (const uint8_t *)fixed.bytes;
        uint32_t signature = YTKACERead32(bytes);
        if (signature == 0x02014b50 || signature == 0x06054b50) break;
        if (signature != 0x04034b50 || fixed.length != 30) {
            if (error != NULL) *error = YTKACEBackupError(8, @"This is not a YTKACE backup");
            [input closeFile];
            return NO;
        }
        uint16_t flags = YTKACERead16(bytes + 6);
        uint16_t method = YTKACERead16(bytes + 8);
        uint32_t expectedCRC = YTKACERead32(bytes + 14);
        uint32_t compressedSize32 = YTKACERead32(bytes + 18);
        uint32_t size32 = YTKACERead32(bytes + 22);
        uint16_t nameLength = YTKACERead16(bytes + 26);
        uint16_t extraLength = YTKACERead16(bytes + 28);
        if ((flags & 0x0008) != 0 || method != 0) {
            if (error != NULL) *error = YTKACEBackupError(9, @"Unsupported ZIP compression");
            [input closeFile];
            return NO;
        }
        NSData *nameData = YTKACEReadData(input, nameLength, error);
        if (nameData == nil || nameData.length != nameLength) {
            if (error != NULL && *error == nil) {
                *error = YTKACEBackupError(11, @"The backup is incomplete");
            }
            [input closeFile];
            return NO;
        }
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        NSData *extra = extraLength == 0 ? NSData.data :
            YTKACEReadData(input, extraLength, error);
        if (extra == nil || extra.length != extraLength) {
            if (error != NULL && *error == nil) {
                *error = YTKACEBackupError(11, @"The backup is incomplete");
            }
            [input closeFile];
            return NO;
        }
        uint64_t compressedSize = compressedSize32;
        uint64_t size = size32;
        if (compressedSize32 == UINT32_MAX || size32 == UINT32_MAX) {
            const uint8_t *extraBytes = (const uint8_t *)extra.bytes;
            NSUInteger cursor = 0;
            BOOL parsedSize = size32 != UINT32_MAX;
            BOOL parsedCompressedSize = compressedSize32 != UINT32_MAX;
            while (cursor + 4 <= extra.length) {
                uint16_t identifier = YTKACERead16(extraBytes + cursor);
                uint16_t length = YTKACERead16(extraBytes + cursor + 2);
                cursor += 4;
                if (cursor + length > extra.length) break;
                if (identifier == 0x0001) {
                    NSUInteger valueCursor = cursor;
                    if (size32 == UINT32_MAX && valueCursor + 8 <= cursor + length) {
                        size = YTKACERead64(extraBytes + valueCursor);
                        valueCursor += 8;
                        parsedSize = YES;
                    }
                    if (compressedSize32 == UINT32_MAX &&
                        valueCursor + 8 <= cursor + length) {
                        compressedSize = YTKACERead64(extraBytes + valueCursor);
                        valueCursor += 8;
                        parsedCompressedSize = YES;
                    }
                    break;
                }
                cursor += length;
            }
            if (!parsedSize || !parsedCompressedSize) {
                if (error != NULL) *error = YTKACEBackupError(9, @"Invalid ZIP64 backup");
                [input closeFile];
                return NO;
            }
        }
        if (compressedSize != size) {
            if (error != NULL) *error = YTKACEBackupError(9, @"Unsupported ZIP compression");
            [input closeFile];
            return NO;
        }
        entryCount += 1;
        if (entryCount > YTKACEMaxBackupEntries || size > YTKACEMaxBackupEntrySize ||
            UINT64_MAX - totalSize < size ||
            totalSize + size > YTKACEMaxBackupTotalSize) {
            if (error != NULL) *error = YTKACEBackupError(15, @"The backup is too large");
            [input closeFile];
            return NO;
        }
        NSNumber *available = nil;
        [destination getResourceValue:&available
                               forKey:NSURLVolumeAvailableCapacityForImportantUsageKey
                                error:nil];
        const uint64_t reserve = 128ULL * 1024ULL * 1024ULL;
        if (available != nil &&
            (size > UINT64_MAX - reserve || available.unsignedLongLongValue < size + reserve)) {
            if (error != NULL) *error = YTKACEBackupError(14, @"Not enough free space to restore the backup");
            [input closeFile];
            return NO;
        }
        totalSize += size;
        NSString *clean = name.stringByStandardizingPath;
        BOOL allowed = [clean isEqualToString:@"SettingsBackup.plist"] ||
            [clean hasPrefix:@"Downloads/"];
        if (!allowed || [clean isEqualToString:@".."] ||
            [clean hasPrefix:@"/"] || [clean containsString:@"../"]) {
            if (error != NULL) *error = YTKACEBackupError(10, @"The backup contains an unsafe path");
            [input closeFile];
            return NO;
        }
        NSURL *outputURL = [destination URLByAppendingPathComponent:clean];
        [manager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createFileAtPath:outputURL.path contents:nil attributes:nil];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
        if (output == nil) {
            [input closeFile];
            return NO;
        }
        uint64_t remaining = size;
        uLong crc = crc32(0L, Z_NULL, 0);
        while (remaining != 0) {
            @autoreleasepool {
                NSUInteger amount = (NSUInteger)MIN((uint64_t)(1024 * 1024), remaining);
                NSData *chunk = YTKACEReadData(input, amount, error);
                if (chunk.length != amount) {
                    [output closeFile];
                    [input closeFile];
                    if (error != NULL && *error == nil) {
                        *error = YTKACEBackupError(11, @"The backup is incomplete");
                    }
                    return NO;
                }
                if (!YTKACEWriteData(output, chunk, error)) {
                    [output closeFile];
                    [input closeFile];
                    return NO;
                }
                crc = crc32(crc, (const Bytef *)chunk.bytes, (uInt)chunk.length);
                remaining -= chunk.length;
            }
        }
        [output closeFile];
        if ((uint32_t)crc != expectedCRC) {
            [input closeFile];
            if (error != NULL) *error = YTKACEBackupError(12, @"A backup file is damaged");
            return NO;
        }
    }
    [input closeFile];
    return YES;
}

static void YTKACERestoreDownloads(NSURL *source, NSURL *destination) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSURL *> *items = [manager enumeratorAtURL:source
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                           options:0 errorHandler:nil];
    for (NSURL *URL in items) {
        NSNumber *directory = nil;
        [URL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue) continue;
        NSString *relative = YTKACERelativePath(URL, source);
        NSArray<NSString *> *components = relative.pathComponents;
        NSUInteger categoryIndex = NSNotFound;
        NSString *category = nil;
        for (NSUInteger index = 0; index < components.count; index++) {
            for (NSString *candidate in @[@"Video", @"Audio", @"Shorts"]) {
                if ([components[index] caseInsensitiveCompare:candidate] == NSOrderedSame) {
                    categoryIndex = index;
                    category = candidate;
                    break;
                }
            }
            if (categoryIndex != NSNotFound) break;
        }
        if (categoryIndex == NSNotFound || categoryIndex + 1 >= components.count) continue;
        NSURL *target = [destination URLByAppendingPathComponent:category isDirectory:YES];
        for (NSUInteger index = categoryIndex + 1; index < components.count; index++) {
            target = [target URLByAppendingPathComponent:components[index]];
        }
        [manager createDirectoryAtURL:target.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        [manager removeItemAtURL:target error:nil];
        [manager copyItemAtURL:URL toURL:target error:nil];
    }
}

@implementation YTKACEBackupManager

+ (void)createBackupWithCompletion:(YTKACEBackupCreationCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSFileManager *manager = NSFileManager.defaultManager;
            NSURL *URL = nil;
            @try {
                NSURL *backups = [[NSURL fileURLWithPath:NSTemporaryDirectory()
                                              isDirectory:YES]
                    URLByAppendingPathComponent:@"YTKACEBackups" isDirectory:YES];
                [manager removeItemAtURL:backups error:nil];
                [manager createDirectoryAtURL:backups
                  withIntermediateDirectories:YES attributes:nil error:&error];
                NSDateFormatter *formatter = [NSDateFormatter new];
                formatter.dateFormat = @"yyyyMMdd-HHmmss";
                NSString *name = [NSString stringWithFormat:@"YTKACE-Backup-%@.zip",
                    [formatter stringFromDate:NSDate.date]];
                URL = error == nil ? [backups URLByAppendingPathComponent:name] : nil;
                NSArray *entries = error == nil ? YTKACEBackupEntries(&error) : nil;
                uint64_t size = entries == nil ? 0 : YTKACEBackupSize(entries);
                if (entries != nil && !YTKACEHasBackupSpace(backups, size, &error)) {
                    entries = nil;
                }
                if (entries != nil && !YTKACEWriteZip(URL, entries, &error)) {
                    [manager removeItemAtURL:URL error:nil];
                    URL = nil;
                }
            } @catch (NSException *exception) {
                error = YTKACEBackupException(exception);
                if (URL != nil) [manager removeItemAtURL:URL error:nil];
                URL = nil;
            }
            if (error != nil) URL = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(URL, error); });
        }
    });
}

+ (void)restoreBackupFromURL:(NSURL *)URL
                  completion:(YTKACEBackupRestoreCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *temporary = [YTKACEApplicationSupportDirectory()
            URLByAppendingPathComponent:[@"Restore-" stringByAppendingString:NSUUID.UUID.UUIDString]
                             isDirectory:YES];
        [manager createDirectoryAtURL:temporary withIntermediateDirectories:YES
                           attributes:nil error:nil];
        if (YTKACEExtractStoredZip(URL, temporary, &error)) {
            NSURL *restoredDownloads = [temporary URLByAppendingPathComponent:@"Downloads"
                                                                   isDirectory:YES];
            NSURL *downloads = [YTKACEApplicationSupportDirectory()
                URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
            if ([manager fileExistsAtPath:restoredDownloads.path]) {
                [manager createDirectoryAtURL:downloads withIntermediateDirectories:YES
                                   attributes:nil error:nil];
                YTKACERestoreDownloads(restoredDownloads, downloads);
            }
            NSDictionary *settings = [NSDictionary dictionaryWithContentsOfURL:
                [temporary URLByAppendingPathComponent:@"SettingsBackup.plist"]];
            YTKACEApplyBackupSettings(settings);
        }
        [manager removeItemAtURL:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error == nil) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"YTKACEDownloadLibraryChanged" object:nil];
            }
            completion(error);
        });
    });
}

@end
