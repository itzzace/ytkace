#import "YTKACEVOTLog.h"

static const NSUInteger kYTKACEVOTLogLimit = 512 * 1024; // 512 KB

NSURL *YTKACEVOTLogFileURL(void) {
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
            NSURL *probe = [directory URLByAppendingPathComponent:@"vot.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-vot.log"]];
        }
    });
    return cached;
}

static dispatch_queue_t YTKACEVOTLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytkace.vot-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void YTKACEWriteVOTLogLine(NSString *category, NSString *message) {
    dispatch_async(YTKACEVOTLogQueue(), ^{
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t formatterToken;
        dispatch_once(&formatterToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        });

        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *tag = category.length > 0 ? category : @"General";
        NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n", timestamp, tag, message];

        NSLog(@"[YTKACE:VOT] [%@] %@", tag, message);

        NSURL *url = YTKACEVOTLogFileURL();
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (handle == nil) {
            [[line dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
            return;
        }

        @try {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];

            unsigned long long size = [handle offsetInFile];
            if (size > kYTKACEVOTLogLimit) {
                [handle seekToFileOffset:size / 2];
                NSData *remaining = [handle readDataToEndOfFile];
                [handle truncateFileAtOffset:0];
                [handle writeData:remaining];
            }
        } @catch (NSException *exception) {
            (void)exception;
        } @finally {
            [handle closeFile];
        }
    });
}

void YTKACEVOTLog(NSString *category, NSString *format, ...) {
    if (format.length == 0) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    YTKACEWriteVOTLogLine(category, message);
}

NSString *YTKACEVOTLogContents(void) {
    __block NSString *contents = @"";
    dispatch_sync(YTKACEVOTLogQueue(), ^{
        NSURL *url = YTKACEVOTLogFileURL();
        contents = [NSString stringWithContentsOfURL:url
                                            encoding:NSUTF8StringEncoding
                                               error:nil] ?: @"";
    });
    return contents;
}

void YTKACEClearVOTLog(void) {
    dispatch_sync(YTKACEVOTLogQueue(), ^{
        NSURL *url = YTKACEVOTLogFileURL();
        [@"" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}
