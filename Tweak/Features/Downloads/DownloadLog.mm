#import "DownloadLog.h"



static const NSUInteger YTKACEDownloadLogLimit = 512 * 1024;

static NSURL *YTKACEDownloadLogURL(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *candidates = @[@(NSDocumentDirectory),
                                            @(NSApplicationSupportDirectory),
                                            @(NSCachesDirectory)];
        for (NSNumber *candidate in candidates) {
            NSURL *base = [NSFileManager.defaultManager
                URLsForDirectory:(NSSearchPathDirectory)candidate.unsignedIntegerValue
                       inDomains:NSUserDomainMask].firstObject;
            if (base == nil) continue;
            NSURL *directory = [[base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES]
                URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
                continue;
            }
            NSURL *probe = [directory URLByAppendingPathComponent:@"downloads.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-downloads.log"]];
        }
        [NSUserDefaults.standardUserDefaults setObject:cached.path
                                                forKey:@"YTKACELogPath"];
    });
    return cached;
}

static dispatch_queue_t YTKACEDownloadLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytkace.download-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString * const YTKACEDebugLogsKey = @"YTKACE.Preference.Developer.DebugLogs";

// -1 until read once; the settings toggle is the only thing that changes it.
static _Atomic int YTKACEDebugLogsState = -1;

BOOL YTKACEDebugLogsEnabled(void) {
    int state = YTKACEDebugLogsState;
    if (state < 0) {
        state = [NSUserDefaults.standardUserDefaults boolForKey:YTKACEDebugLogsKey] ? 1 : 0;
        YTKACEDebugLogsState = state;
    }
    return state == 1;
}

void YTKACESetDebugLogsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YTKACEDebugLogsKey];
    YTKACEDebugLogsState = enabled ? 1 : 0;
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message);

void YTKACEDownloadLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

void YTKACEDebugLogWrite(NSString *identifier, NSString *format, ...) {
    if (format.length == 0 || !YTKACEDebugLogsEnabled()) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

// Lines are collected on the log queue and written in batches about every
// half second, so logging never waits on the disk. A line that repeats the
// last one within a second is counted instead of written again.
static NSMutableData *YTKACELogBuffer;
static BOOL YTKACELogFlushScheduled;
static NSString *YTKACELastLogLine;
static CFAbsoluteTime YTKACELastLogTime;
static NSUInteger YTKACELogRepeats;
static const NSUInteger YTKACELogBufferLimit = 32 * 1024;

static NSString *YTKACELogStamp(CFAbsoluteTime time) {
    static NSDateFormatter *formatter;
    if (formatter == nil) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss '+0000'";
    }
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:time]];
}

static void YTKACEBufferLogLine(NSString *line) {
    if (YTKACELogBuffer == nil) YTKACELogBuffer = [NSMutableData data];
    [YTKACELogBuffer appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

static void YTKACENoteLogRepeats(void) {
    if (YTKACELogRepeats == 0) return;
    YTKACEBufferLogLine([NSString stringWithFormat:@"%@ [log] last line repeated %lu more times\n",
                         YTKACELogStamp(YTKACELastLogTime), (unsigned long)YTKACELogRepeats]);
    YTKACELogRepeats = 0;
}

// Runs on the log queue.
static void YTKACEFlushLog(void) {
    YTKACELogFlushScheduled = NO;
    YTKACENoteLogRepeats();
    NSData *bytes = YTKACELogBuffer;
    if (bytes.length == 0) return;
    YTKACELogBuffer = nil;
    NSURL *URL = YTKACEDownloadLogURL();
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:URL error:nil];
    unsigned long long size = 0;
    if (handle == nil ||
        ![handle seekToEndReturningOffset:&size error:nil] ||
        ![handle writeData:bytes error:nil]) {
        [handle closeAndReturnError:nil];
        NSMutableData *data = [([NSData dataWithContentsOfURL:URL] ?: NSData.data) mutableCopy];
        [data appendData:bytes];
        [data writeToURL:URL atomically:YES];
        return;
    }
    [handle closeAndReturnError:nil];
    if (size + bytes.length <= YTKACEDownloadLogLimit) return;
    NSData *data = [NSData dataWithContentsOfURL:URL];
    NSUInteger keep = YTKACEDownloadLogLimit * 3 / 4;
    if (data.length > keep) {
        [[data subdataWithRange:NSMakeRange(data.length - keep, keep)] writeToURL:URL atomically:YES];
    }
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    if (message.length > 4096) message = [message substringToIndex:4096];
    dispatch_async(YTKACEDownloadLogQueue(), ^{
        NSString *body = [NSString stringWithFormat:@"[%@] %@",
                          identifier.length == 0 ? @"download" : identifier, message];
        if (YTKACELastLogLine != nil && [body isEqualToString:YTKACELastLogLine] &&
            time - YTKACELastLogTime < 1.0) {
            YTKACELogRepeats++;
            YTKACELastLogTime = time;
            return;
        }
        YTKACENoteLogRepeats();
        YTKACELastLogLine = body;
        YTKACELastLogTime = time;
        YTKACEBufferLogLine([NSString stringWithFormat:@"%@ %@\n", YTKACELogStamp(time), body]);
        if (YTKACELogBuffer.length >= YTKACELogBufferLimit) {
            YTKACEFlushLog();
        } else if (!YTKACELogFlushScheduled) {
            YTKACELogFlushScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           YTKACEDownloadLogQueue(), ^{ YTKACEFlushLog(); });
        }
    });
}

NSString *YTKACEDownloadLogContents(void) {
    __block NSString *contents = @"No download activity yet.";
    dispatch_sync(YTKACEDownloadLogQueue(), ^{
        YTKACEFlushLog();
        NSString *value = [NSString stringWithContentsOfURL:YTKACEDownloadLogURL()
            encoding:NSUTF8StringEncoding error:nil];
        if (value.length != 0) contents = value;
    });
    return contents;
}

void YTKACEClearDownloadLog(void) {
    dispatch_sync(YTKACEDownloadLogQueue(), ^{
        YTKACELogBuffer = nil;
        YTKACELogRepeats = 0;
        YTKACELastLogLine = nil;
        [NSFileManager.defaultManager removeItemAtURL:YTKACEDownloadLogURL() error:nil];
    });
}
