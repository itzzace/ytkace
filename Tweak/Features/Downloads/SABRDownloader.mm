#import "SABRDownloader.h"
#import "DownloadLog.h"
#import "StreamResolver.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef YTKACE_COMBINED_SABR
#define YTKACE_COMBINED_SABR 0
#endif

static NSString *const YTKACESABRErrorDomain = @"YTKACESABR";
static NSData *YTKACESABRPoToken;
static NSDictionary<NSString *, NSString *> *YTKACESABRNativeHeaders;
static NSData *YTKACESABRNativeBody;
static NSString *YTKACESABRCurrentVideoID;
static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *YTKACESABRHeadersByVideo;
static NSMutableDictionary<NSString *, NSData *> *YTKACESABRBodiesByVideo;
static NSMutableDictionary<NSData *, NSDictionary<NSString *, NSString *> *> *YTKACESABRHeadersByConfig;
static NSMutableDictionary<NSData *, NSData *> *YTKACESABRBodiesByConfig;
static const NSUInteger YTKACESABRRequestCacheLimit = 32;
static NSString *YTKACEPBFieldSummary(NSData *data);
static BOOL YTKACESABRIsPlaybackBody(NSData *data);
static NSData *YTKACEPBDataField(NSData *data, NSUInteger wanted);

static BOOL YTKACESABRIsAllowedServerURL(NSURL *URL) {
    if (URL == nil || ![URL.scheme.lowercaseString isEqualToString:@"https"] ||
        URL.user.length != 0 || URL.password.length != 0 ||
        (URL.port != nil && URL.port.integerValue != 443)) {
        return NO;
    }
    NSString *host = URL.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"googlevideo.com"] ||
        [host hasSuffix:@".googlevideo.com"] ||
        [host isEqualToString:@"youtube.com"] ||
        [host hasSuffix:@".youtube.com"] ||
        [host isEqualToString:@"youtube-nocookie.com"] ||
        [host hasSuffix:@".youtube-nocookie.com"];
}

void YTKACESABRSetCurrentVideoID(NSString *videoID) {
    if (videoID.length == 0) return;
    @synchronized (YTKACESABRDownloader.class) {
        YTKACESABRCurrentVideoID = [videoID copy];
    }
}

NSString *YTKACESABRCurrentVideoIDValue(void) {
    @synchronized (YTKACESABRDownloader.class) {
        return [YTKACESABRCurrentVideoID copy];
    }
}

void YTKACESABRSetNativeHeaders(NSDictionary<NSString *, NSString *> *headers) {
    if (headers.count == 0) return;
    @synchronized (YTKACESABRDownloader.class) {
        YTKACESABRNativeHeaders = [headers copy];
        if (YTKACESABRCurrentVideoID.length != 0) {
            if (YTKACESABRHeadersByVideo == nil) {
                YTKACESABRHeadersByVideo = [NSMutableDictionary dictionary];
            }
            if (YTKACESABRHeadersByVideo[YTKACESABRCurrentVideoID] == nil &&
                YTKACESABRHeadersByVideo.count >= YTKACESABRRequestCacheLimit) {
                [YTKACESABRHeadersByVideo removeAllObjects];
                [YTKACESABRBodiesByVideo removeAllObjects];
            }
            YTKACESABRHeadersByVideo[YTKACESABRCurrentVideoID] = [headers copy];
        }
    }
    YTKACEDownloadLog(@"native", @"captured headers count=%lu",
        (unsigned long)headers.count);
}

static NSDictionary<NSString *, NSString *> *YTKACESABRCurrentNativeHeaders(
    NSString *videoID, NSData *config) {
    @synchronized (YTKACESABRDownloader.class) {
        NSDictionary *matched = config.length != 0
            ? YTKACESABRHeadersByConfig[config] : nil;
        if (matched.count != 0) return [matched copy];
        if (videoID.length != 0) return [YTKACESABRHeadersByVideo[videoID] copy];
        return [YTKACESABRNativeHeaders copy];
    }
}

void YTKACESABRSetNativeRequest(NSURLRequest *request) {
    if (request == nil) return;
    BOOL usable = YTKACESABRIsPlaybackBody(request.HTTPBody);
    if (!usable) {
        YTKACEDownloadLog(@"native", @"body ignored video=%@ bytes=%lu fields=%@",
            YTKACESABRCurrentVideoID ?: @"unknown",
            (unsigned long)request.HTTPBody.length,
            YTKACEPBFieldSummary(request.HTTPBody));
        return;
    }
    YTKACESABRSetNativeHeaders(request.allHTTPHeaderFields);
    @synchronized (YTKACESABRDownloader.class) {
        YTKACESABRNativeBody = [request.HTTPBody copy];
        if (YTKACESABRCurrentVideoID.length != 0 && request.HTTPBody.length != 0) {
            if (YTKACESABRBodiesByVideo == nil) {
                YTKACESABRBodiesByVideo = [NSMutableDictionary dictionary];
            }
            if (YTKACESABRBodiesByVideo[YTKACESABRCurrentVideoID] == nil &&
                YTKACESABRBodiesByVideo.count >= YTKACESABRRequestCacheLimit) {
                [YTKACESABRHeadersByVideo removeAllObjects];
                [YTKACESABRBodiesByVideo removeAllObjects];
            }
            YTKACESABRBodiesByVideo[YTKACESABRCurrentVideoID] = [request.HTTPBody copy];
        }
        NSData *config = YTKACEPBDataField(request.HTTPBody, 5);
        if (config.length != 0) {
            if (YTKACESABRBodiesByConfig == nil) {
                YTKACESABRBodiesByConfig = [NSMutableDictionary dictionary];
                YTKACESABRHeadersByConfig = [NSMutableDictionary dictionary];
            }
            if (YTKACESABRBodiesByConfig.count >= YTKACESABRRequestCacheLimit) {
                [YTKACESABRBodiesByConfig removeAllObjects];
                [YTKACESABRHeadersByConfig removeAllObjects];
            }
            YTKACESABRBodiesByConfig[config] = [request.HTTPBody copy];
            YTKACESABRHeadersByConfig[config] = [request.allHTTPHeaderFields copy];
        }
    }
    YTKACEDownloadLog(@"native", @"body video=%@ bytes=%lu fields=%@",
        YTKACESABRCurrentVideoID ?: @"unknown",
        (unsigned long)request.HTTPBody.length,
        YTKACEPBFieldSummary(request.HTTPBody));
}

static NSData *YTKACESABRCurrentNativeBody(NSString *videoID, NSData *config) {
    @synchronized (YTKACESABRDownloader.class) {
        NSData *matched = config.length != 0 ? YTKACESABRBodiesByConfig[config] : nil;
        if (matched.length != 0) return [matched copy];
        if (videoID.length != 0) return [YTKACESABRBodiesByVideo[videoID] copy];
        return [YTKACESABRNativeBody copy];
    }
}

static NSData *YTKACESABRDecodeTokenString(NSString *value) {
    if (value.length == 0) return nil;
    NSString *decoded = [value stringByRemovingPercentEncoding] ?: value;
    NSMutableString *base64 = [decoded mutableCopy];
    [base64 replaceOccurrencesOfString:@"-" withString:@"+"
        options:0 range:NSMakeRange(0, base64.length)];
    [base64 replaceOccurrencesOfString:@"_" withString:@"/"
        options:0 range:NSMakeRange(0, base64.length)];
    while (base64.length % 4 != 0) [base64 appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

void YTKACESABRSetPoToken(id token) {
    NSData *data = nil;
    NSString *encoding = @"raw";
    if ([token isKindOfClass:NSData.class]) {
        data = token;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length != 0) {
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=%"] invertedSet];
            if ([text rangeOfCharacterFromSet:invalid].location == NSNotFound) {
                NSData *decoded = YTKACESABRDecodeTokenString(text);
                if (decoded.length != 0) {
                    data = decoded;
                    encoding = @"base64url";
                }
            }
        }
    } else if ([token isKindOfClass:NSString.class]) {
        data = YTKACESABRDecodeTokenString(token);
        encoding = @"base64url";
    } else if ([token respondsToSelector:NSSelectorFromString(@"poToken")]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"poToken"));
        if (value != token) YTKACESABRSetPoToken(value);
        return;
    }
    if (data.length == 0) return;
    @synchronized (YTKACESABRDownloader.class) {
        YTKACESABRPoToken = [data copy];
    }
    YTKACEDownloadLog(@"token", @"captured PoToken bytes=%lu encoding=%@",
        (unsigned long)data.length, encoding);
}

NSString *YTKACESABRPoTokenString(void) {
    NSData *token = nil;
    @synchronized (YTKACESABRDownloader.class) {
        token = [YTKACESABRPoToken copy];
    }
    if (token.length == 0) return nil;
    NSMutableString *text = [[token base64EncodedStringWithOptions:0] mutableCopy];
    [text replaceOccurrencesOfString:@"+" withString:@"-"
                             options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"/" withString:@"_"
                             options:0 range:NSMakeRange(0, text.length)];
    while ([text hasSuffix:@"="]) {
        [text deleteCharactersInRange:NSMakeRange(text.length - 1, 1)];
    }
    return text;
}

static NSData *YTKACESABRCurrentPoToken(void) {
    @synchronized (YTKACESABRDownloader.class) {
        return [YTKACESABRPoToken copy];
    }
}

static id YTKACESABRObject(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static id YTKACESABRFindPlayerData(id object,
                                   NSHashTable *visited,
                                   NSUInteger depth) {
    if (object == nil || depth > 8 || [visited containsObject:object]) return nil;
    [visited addObject:object];
    if (YTKACESABRObject(object, @[@"streamingData"]) != nil) return object;
    for (NSString *name in @[@"playerData", @"playerResponse", @"playbackData",
                              @"contentPlaybackData", @"contentPlayerResponse",
                              @"response", @"video", @"shortsPlayerData"]) {
        id nested = YTKACESABRObject(object, @[name]);
        id found = YTKACESABRFindPlayerData(nested, visited, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static id YTKACESABRPlayerData(id response) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return YTKACESABRFindPlayerData(response, visited, 0) ?: response;
}

static void YTKACEPBVarint(NSMutableData *data, uint64_t value) {
    while (value >= 0x80) {
        uint8_t byte = (uint8_t)(value | 0x80);
        [data appendBytes:&byte length:1];
        value >>= 7;
    }
    uint8_t byte = (uint8_t)value;
    [data appendBytes:&byte length:1];
}

static void YTKACEPBKey(NSMutableData *data, NSUInteger field, uint8_t wire) {
    YTKACEPBVarint(data, ((uint64_t)field << 3) | wire);
}

static void YTKACEPBInteger(NSMutableData *data, NSUInteger field, uint64_t value) {
    YTKACEPBKey(data, field, 0);
    YTKACEPBVarint(data, value);
}

static void YTKACEPBBytes(NSMutableData *data, NSUInteger field, NSData *value) {
    if (value.length == 0) {
        return;
    }
    YTKACEPBKey(data, field, 2);
    YTKACEPBVarint(data, value.length);
    [data appendData:value];
}

static void YTKACEPBString(NSMutableData *data, NSUInteger field, NSString *value) {
    YTKACEPBBytes(data, field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}

static void YTKACEPBFloat(NSMutableData *data, NSUInteger field, float value) {
    YTKACEPBKey(data, field, 5);
    [data appendBytes:&value length:sizeof(value)];
}

static BOOL YTKACEPBReadVarint(NSData *data, NSUInteger *offset, uint64_t *value) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint64_t result = 0;
    NSUInteger shift = 0;
    while (*offset < data.length && shift < 70) {
        uint8_t byte = bytes[(*offset)++];
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

static BOOL YTKACEPBSkip(NSData *data, NSUInteger *offset, uint8_t wire) {
    if (wire == 0) {
        uint64_t value = 0;
        return YTKACEPBReadVarint(data, offset, &value);
    }
    if (wire == 1) {
        if (*offset + 8 > data.length) return NO;
        *offset += 8;
        return YES;
    }
    if (wire == 2) {
        uint64_t length = 0;
        if (!YTKACEPBReadVarint(data, offset, &length) || *offset + length > data.length) {
            return NO;
        }
        *offset += (NSUInteger)length;
        return YES;
    }
    if (wire == 5) {
        if (*offset + 4 > data.length) return NO;
        *offset += 4;
        return YES;
    }
    return NO;
}

static uint64_t YTKACEPBIntegerField(NSData *data, NSUInteger wanted, uint64_t fallback) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        uint64_t key = 0;
        if (!YTKACEPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (field == wanted && wire == 0) {
            uint64_t value = 0;
            return YTKACEPBReadVarint(data, &offset, &value) ? value : fallback;
        }
        if (!YTKACEPBSkip(data, &offset, wire)) break;
    }
    return fallback;
}

static NSData *YTKACEPBDataField(NSData *data, NSUInteger wanted) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        uint64_t key = 0;
        if (!YTKACEPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (wire == 2) {
            uint64_t length = 0;
            if (!YTKACEPBReadVarint(data, &offset, &length) || offset + length > data.length) {
                break;
            }
            NSData *value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)length)];
            if (field == wanted) {
                return value;
            }
            offset += (NSUInteger)length;
            continue;
        }
        if (!YTKACEPBSkip(data, &offset, wire)) break;
    }
    return nil;
}

static BOOL YTKACESABRIsPlaybackBody(NSData *data) {
    return YTKACEPBDataField(data, 1).length != 0 &&
        YTKACEPBDataField(data, 5).length != 0 &&
        YTKACEPBDataField(data, 19).length != 0;
}

static NSString *YTKACEPBFieldSummary(NSData *data) {
    if (data.length == 0) return @"empty";
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < data.length && fields.count < 40) {
        uint64_t key = 0;
        if (!YTKACEPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (wire == 2) {
            uint64_t length = 0;
            if (!YTKACEPBReadVarint(data, &offset, &length) || offset + length > data.length) break;
            [fields addObject:[NSString stringWithFormat:@"%lu:%llu",
                (unsigned long)field, length]];
            offset += (NSUInteger)length;
        } else {
            [fields addObject:[NSString stringWithFormat:@"%lu/w%u",
                (unsigned long)field, wire]];
            if (!YTKACEPBSkip(data, &offset, wire)) break;
        }
    }
    return fields.count != 0 ? [fields componentsJoinedByString:@","] : @"unparsed";
}

static NSString *YTKACEPBStringField(NSData *data, NSUInteger field) {
    NSData *value = YTKACEPBDataField(data, field);
    return value != nil ? [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] : nil;
}

static NSString *YTKACESABRHex(NSData *data, NSUInteger limit) {
    if (data.length == 0) return @"";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = MIN(data.length, limit);
    NSMutableString *result = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger index = 0; index < length; index++) {
        [result appendFormat:@"%02x", bytes[index]];
    }
    return result;
}

static BOOL YTKACEUMPValue(NSData *data, NSUInteger *offset, uint32_t *result) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (*offset >= data.length) return NO;
    uint8_t first = bytes[*offset];
    NSUInteger count = first < 128 ? 1 : first < 192 ? 2 : first < 224 ? 3 : first < 240 ? 4 : 5;
    if (*offset + count > data.length) return NO;
    uint32_t value = 0;
    if (count == 1) {
        value = first;
    } else if (count == 2) {
        value = (first & 0x3f) + 64u * bytes[*offset + 1];
    } else if (count == 3) {
        value = (first & 0x1f) + 32u * (bytes[*offset + 1] + 256u * bytes[*offset + 2]);
    } else if (count == 4) {
        value = (first & 0x0f) + 16u * (bytes[*offset + 1] +
            256u * (bytes[*offset + 2] + 256u * bytes[*offset + 3]));
    } else {
        memcpy(&value, bytes + *offset + 1, sizeof(value));
    }
    *offset += count;
    *result = value;
    return YES;
}

static NSData *YTKACESABRFormatID(YTKACEStreamOption *option) {
    NSMutableData *data = [NSMutableData data];
    YTKACEPBInteger(data, 1, (uint64_t)option.itag);
    if (option.lastModified > 0) {
        YTKACEPBInteger(data, 2, (uint64_t)option.lastModified);
    }
    if (option.xtags.length != 0) {
        YTKACEPBString(data, 3, option.xtags);
    } else {
        YTKACEPBKey(data, 3, 2);
        YTKACEPBVarint(data, 0);
    }
    return data;
}

static NSData *YTKACESABRClientInfo(void) {
    NSMutableData *data = [NSMutableData data];
    UIDevice *device = UIDevice.currentDevice;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"21.28.3";
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en-US";
    NSString *region = NSLocale.currentLocale.countryCode ?: @"US";
    CGSize points = UIScreen.mainScreen.bounds.size;
    YTKACEPBString(data, 12, @"Apple");
    YTKACEPBString(data, 13, device.model ?: @"iOS");
    YTKACEPBInteger(data, 16, 5);
    YTKACEPBString(data, 17, version);
    YTKACEPBString(data, 18, @"IOS");
    YTKACEPBString(data, 19, device.systemVersion ?: @"16.0");
    YTKACEPBString(data, 21, language);
    YTKACEPBString(data, 22, region);
    YTKACEPBInteger(data, 37, (uint64_t)llround(points.width));
    YTKACEPBInteger(data, 38, (uint64_t)llround(points.height));
    YTKACEPBInteger(data, 41, (uint64_t)llround(UIScreen.mainScreen.scale));
    YTKACEPBInteger(data, 46, device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2 : 1);
    YTKACEPBString(data, 80, NSTimeZone.localTimeZone.name ?: @"UTC");
    return data;
}

@interface YTKACESABRHeader : NSObject
@property(nonatomic, assign) NSInteger headerID;
@property(nonatomic, assign) NSInteger itag;
@property(nonatomic, copy) NSString *xtags;
@property(nonatomic, assign) BOOL initialization;
@property(nonatomic, assign) NSInteger sequence;
@property(nonatomic, assign) int64_t startTime;
@property(nonatomic, assign) int64_t duration;
@property(nonatomic, assign) int64_t contentLength;
@property(nonatomic, strong) NSMutableData *data;
@end

@implementation YTKACESABRHeader
@end

@interface YTKACESABRTrack : NSObject
@property(nonatomic, strong) YTKACEStreamOption *option;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic, strong) NSMutableSet<NSString *> *segments;
@property(nonatomic, assign) BOOL initialized;
@property(nonatomic, assign) BOOL initializationWritten;
@property(nonatomic, assign) NSInteger endSequence;
@property(nonatomic, assign) NSInteger lastSequence;
@property(nonatomic, assign) int64_t endTime;
@property(nonatomic, assign) int64_t downloadedDuration;
@property(nonatomic, assign) int64_t downloadedBytes;
@property(nonatomic, assign) BOOL hasRound;
@property(nonatomic, assign) int64_t roundStart;
@property(nonatomic, assign) int64_t roundDuration;
@property(nonatomic, assign) NSInteger roundStartSequence;
@property(nonatomic, assign) NSInteger roundEndSequence;
@end

@implementation YTKACESABRTrack
@end

@interface YTKACESABRSession : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) id playerResponse;
@property(nonatomic, strong) id streamingData;
@property(nonatomic, strong) NSData *ustreamerConfig;
@property(nonatomic, copy) NSString *serverURL;
@property(nonatomic, strong) YTKACESABRTrack *video;
@property(nonatomic, strong) YTKACESABRTrack *audio;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YTKACESABRHeader *> *headers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *contexts;
@property(nonatomic, strong, nullable) NSData *playbackCookie;
@property(nonatomic, assign) NSInteger requestNumber;
@property(nonatomic, assign) NSInteger stalledRequests;
@property(nonatomic, assign) NSInteger backoffMilliseconds;
@property(nonatomic, copy, nullable) YTKACESABRProgress progress;
@property(nonatomic, copy) YTKACESABRCompletion completion;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, assign) NSInteger retryCount;
@property(nonatomic, assign) NSInteger attestationRetries;
@property(nonatomic, assign) NSInteger reloadCount;
@property(nonatomic, assign) BOOL reloadInFlight;
@property(nonatomic, assign) BOOL audioOnly;
@property(nonatomic, assign) BOOL combinedMode;
@property(nonatomic, assign) NSInteger mediaPhase;
@property(nonatomic, assign) NSInteger preparationAttempts;
@property(nonatomic, assign) BOOL preparationInFlight;
@property(nonatomic, assign) NSTimeInterval lastPreparationRequest;
@property(nonatomic, assign) NSInteger audioStalledRequests;
@property(nonatomic, assign) NSInteger videoStalledRequests;
@property(nonatomic, assign) NSInteger stallRecoveryCount;
@property(nonatomic, assign) BOOL sequentialFallback;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, strong) NSMutableData *activeResponseData;
@property(nonatomic, strong, nullable) NSHTTPURLResponse *activeResponse;
@property(nonatomic, assign) NSInteger activeRequestNumber;
@property(nonatomic, assign) NSTimeInterval activeRequestStart;
@property(nonatomic, assign) NSTimeInterval lastLiveProgress;
@property(nonatomic, assign) int64_t activeBaseAudioBytes;
@property(nonatomic, assign) int64_t activeBaseVideoBytes;
@property(nonatomic, assign) int64_t activeNetworkBytes;
@property(nonatomic, assign) BOOL requestBuildInFlight;
@property(nonatomic, assign) BOOL nativeRefreshInFlight;
@property(nonatomic, assign) NSInteger nativeRefreshAttempts;
@property(nonatomic, assign) NSInteger nativeBuildFailures;
- (void)start;
- (void)cancel;
- (void)sendPreparedRequest:(NSURLRequest * _Nullable)nativeRequest
        nativeRequestNumber:(NSInteger)nativeRequestNumber;
- (void)refreshNativeSession:(NSString *)reason;
- (BOOL)restartStalledSession:(NSString *)reason;
- (BOOL)switchToSequentialFallback:(NSString *)reason;
@end

@implementation YTKACESABRSession

- (NSError *)error:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:YTKACESABRErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"SABR failed"}];
}

- (YTKACESABRTrack *)trackForItag:(NSInteger)itag xtags:(NSString *)xtags {
    if (self.video.option.itag == itag &&
        (xtags.length == 0 || self.video.option.xtags.length == 0 ||
         [self.video.option.xtags isEqualToString:xtags])) {
        return self.video;
    }
    if (self.audio.option.itag == itag &&
        (xtags.length == 0 || self.audio.option.xtags.length == 0 ||
         [self.audio.option.xtags isEqualToString:xtags])) {
        return self.audio;
    }
    return nil;
}

- (YTKACESABRTrack *)makeTrack:(YTKACEStreamOption *)option
                           name:(NSString *)name
                      directory:(NSURL *)directory
                         error:(NSError **)error {
    YTKACESABRTrack *track = [YTKACESABRTrack new];
    track.option = option;
    track.segments = [NSMutableSet set];
    track.endSequence = NSIntegerMax;
    track.lastSequence = -1;
    track.roundStartSequence = NSIntegerMax;
    NSString *extension = [option.mimeType containsString:@"webm"] ? @"webm" :
        ([option.mimeType hasPrefix:@"audio/"] ? @"m4a" : @"mp4");
    track.URL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", name, extension]];
    [NSFileManager.defaultManager createFileAtPath:track.URL.path contents:nil attributes:nil];
    track.handle = [NSFileHandle fileHandleForWritingToURL:track.URL error:error];
    return track;
}

- (BOOL)applyPlayerResponse:(id)response error:(NSError **)error {
    id playerData = YTKACESABRPlayerData(response);
    id streamingData = YTKACESABRObject(playerData, @[@"streamingData"]);
    id playerConfig = YTKACESABRObject(playerData, @[@"playerConfig"]);
    id common = YTKACESABRObject(playerConfig, @[@"mediaCommonConfig"]);
    id requestConfig = YTKACESABRObject(common, @[@"mediaUstreamerRequestConfig"]);
    NSData *ustreamerConfig = YTKACESABRObject(requestConfig,
        @[@"videoPlaybackUstreamerConfig"]);
    NSString *serverURL = YTKACESABRObject(streamingData, @[@"serverAbrStreamingURL"]);
    if (![ustreamerConfig isKindOfClass:NSData.class] || ustreamerConfig.length == 0 ||
        ![serverURL isKindOfClass:NSString.class] || serverURL.length == 0) {
        if (error != NULL) *error = [self error:@"YouTube did not provide SABR session data." code:1];
        return NO;
    }
    NSURL *parsedServerURL = [NSURL URLWithString:serverURL];
    if (!YTKACESABRIsAllowedServerURL(parsedServerURL)) {
        if (error != NULL) *error = [self error:@"YouTube returned an unsafe SABR server URL." code:2];
        return NO;
    }
    self.playerResponse = response;
    self.streamingData = streamingData;
    self.ustreamerConfig = ustreamerConfig;
    self.serverURL = parsedServerURL.absoluteString;
    NSArray<YTKACEStreamOption *> *options =
        [YTKACEStreamResolver optionsFromPlayerResponse:playerData];
    for (YTKACEStreamOption *option in options) {
        YTKACESABRTrack *track = [self trackForItag:option.itag xtags:option.xtags];
        if (track == nil) continue;
        YTKACEDownloadLog(self.identifier,
            @"refreshed itag=%ld lmt=%ld->%ld xtags=%@->%@",
            (long)option.itag, (long)track.option.lastModified,
            (long)option.lastModified, track.option.xtags, option.xtags);
        track.option.lastModified = option.lastModified;
        track.option.xtags = option.xtags ?: @"";
        track.option.rawFormat = option.rawFormat;
    }
    return YES;
}

NSUInteger YTKACEPurgeDownloadScratch(BOOL includeActive) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
        includingPropertiesForKeys:@[NSURLContentModificationDateKey,
                                     NSURLTotalFileAllocatedSizeKey,
                                     NSURLIsDirectoryKey]
                           options:0 error:nil];
    NSUInteger freed = 0;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-600.0];
    for (NSURL *entry in entries) {
        NSString *name = entry.lastPathComponent;
        BOOL scratch = [name hasPrefix:@"YTKACE-"];
        BOOL dump = [name hasPrefix:@"ytkace-"] && [name hasSuffix:@".pb"];
        if (!scratch && !dump) continue;
        if (!includeActive) {
            NSDate *modified = nil;
            [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey
                              error:nil];
            if (modified != nil && [modified compare:cutoff] == NSOrderedDescending) {
                continue;
            }
        }
        NSNumber *size = nil;
        [entry getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        NSDirectoryEnumerator *walker = [manager enumeratorAtURL:entry
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 errorHandler:nil];
        NSUInteger nested = 0;
        for (NSURL *child in walker) {
            NSNumber *childSize = nil;
            [child getResourceValue:&childSize forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            nested += childSize.unsignedIntegerValue;
        }
        if ([manager removeItemAtURL:entry error:nil]) {
            freed += nested + size.unsignedIntegerValue;
        }
    }
    if (freed != 0) {
        YTKACEDownloadLog(@"cache", @"purged scratch bytes=%lu",
            (unsigned long)freed);
    }
    return freed;
}

- (BOOL)prepare:(NSError **)error {
    if (![self applyPlayerResponse:self.playerResponse error:error]) return NO;
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    directory = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTKACE-%@", NSUUID.UUID.UUIDString]
        isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    self.video = [self makeTrack:self.video.option name:@"video" directory:directory error:error];
    if (self.video.handle == nil) return NO;
    self.audio = [self makeTrack:self.audio.option name:@"audio" directory:directory error:error];
    return self.audio.handle != nil;
}

- (NSData *)bufferedRangeForTrack:(YTKACESABRTrack *)track {
    if (!track.hasRound || track.roundDuration <= 0) {
        return nil;
    }
    NSMutableData *timeRange = [NSMutableData data];
    YTKACEPBInteger(timeRange, 1, (uint64_t)MAX(track.roundStart, 0));
    YTKACEPBInteger(timeRange, 2, (uint64_t)track.roundDuration);
    YTKACEPBInteger(timeRange, 3, 1000);
    NSMutableData *range = [NSMutableData data];
    YTKACEPBBytes(range, 1, YTKACESABRFormatID(track.option));
    YTKACEPBInteger(range, 2, (uint64_t)MAX(track.roundStart, 0));
    YTKACEPBInteger(range, 3, (uint64_t)track.roundDuration);
    YTKACEPBInteger(range, 4, (uint64_t)MAX(track.roundStartSequence, 0));
    YTKACEPBInteger(range, 5, (uint64_t)MAX(track.roundEndSequence, 0));
    YTKACEPBBytes(range, 6, timeRange);
    return range;
}

- (void)clearRound:(YTKACESABRTrack *)track {
    track.hasRound = NO;
    track.roundStart = 0;
    track.roundDuration = 0;
    track.roundStartSequence = NSIntegerMax;
    track.roundEndSequence = 0;
}

- (NSData *)requestBody {
    BOOL formatsInitialized = self.video.initialized || self.audio.initialized;
    if (formatsInitialized && self.mediaPhase == 0) {
        self.mediaPhase = self.combinedMode ? 3 : 1;
    }
    NSInteger trackMode = self.combinedMode ? 0 : (self.mediaPhase == 2 ? 2 :
        ((self.mediaPhase == 1 || self.audioOnly) ? 1 : 0));
    int64_t playerTime = (self.mediaPhase == 2 || self.combinedMode)
        ? self.video.downloadedDuration : self.audio.downloadedDuration;
    NSInteger resolution = MAX(self.video.option.height, 360);
    NSData *nativeBody = YTKACESABRCurrentNativeBody(self.videoID, self.ustreamerConfig);
    NSData *nativeState = YTKACEPBDataField(nativeBody, 1);
    NSMutableData *state = [NSMutableData data];
    if (nativeState.length != 0) {
        [state appendData:nativeState];
        YTKACEPBInteger(state, 16, (uint64_t)resolution);
        YTKACEPBInteger(state, 28, (uint64_t)MAX(playerTime, 0));
        YTKACEPBInteger(state, 40, (uint64_t)trackMode);
    } else {
        YTKACEPBInteger(state, 16, (uint64_t)resolution);
        YTKACEPBInteger(state, 21, (uint64_t)resolution);
        YTKACEPBInteger(state, 22, 0);
        YTKACEPBInteger(state, 28, (uint64_t)MAX(playerTime, 0));
        YTKACEPBInteger(state, 34, 1);
        YTKACEPBFloat(state, 35, 1.0f);
        YTKACEPBInteger(state, 40, (uint64_t)trackMode);
        YTKACEPBInteger(state, 46, 0);
    }
    if (self.audio.option.audioTrackID.length != 0) {
        YTKACEPBString(state, 69, self.audio.option.audioTrackID);
    }

    NSData *nativeContext = YTKACEPBDataField(nativeBody, 19);
    NSMutableData *context = [NSMutableData data];
    if (nativeContext.length != 0) {
        [context appendData:nativeContext];
    } else {
        YTKACEPBBytes(context, 1, YTKACESABRClientInfo());
        NSData *poToken = YTKACESABRCurrentPoToken();
        if (poToken.length != 0) {
            YTKACEPBBytes(context, 2, poToken);
        }
    }
    if (self.playbackCookie.length != 0) {
        YTKACEPBBytes(context, 3, self.playbackCookie);
    }
    for (NSNumber *type in self.contexts) {
        NSMutableData *item = [NSMutableData data];
        YTKACEPBInteger(item, 1, type.unsignedIntegerValue);
        YTKACEPBBytes(item, 2, self.contexts[type]);
        YTKACEPBBytes(context, 5, item);
    }

    NSMutableData *request = [NSMutableData data];
    YTKACEPBBytes(request, 1, state);
    NSData *videoID = YTKACESABRFormatID(self.video.option);
    NSData *audioID = YTKACESABRFormatID(self.audio.option);
    if (formatsInitialized) {
        if (self.combinedMode) {
            YTKACEPBBytes(request, 2, videoID);
            YTKACEPBBytes(request, 2, audioID);
        } else if (self.mediaPhase == 1) {
            YTKACEPBBytes(request, 2, audioID);
        } else {
            YTKACEPBBytes(request, 2, videoID);
        }
    }
    NSData *videoRange = [self bufferedRangeForTrack:self.video];
    NSData *audioRange = [self bufferedRangeForTrack:self.audio];
    if (videoRange != nil) YTKACEPBBytes(request, 3, videoRange);
    if (audioRange != nil) YTKACEPBBytes(request, 3, audioRange);
    YTKACEPBBytes(request, 5, self.ustreamerConfig);
    YTKACEPBBytes(request, 16, audioID);
    YTKACEPBBytes(request, 17, videoID);
    YTKACEPBBytes(request, 19, context);
    [self clearRound:self.video];
    [self clearRound:self.audio];
    if (self.requestNumber == 0) {
        YTKACEDownloadLog(self.identifier, @"request fields native=%lu outgoing=%lu summary=%@",
            (unsigned long)nativeBody.length, (unsigned long)request.length,
            YTKACEPBFieldSummary(request));
    }
    return request;
}

- (NSURL *)requestURLForBaseURL:(NSURL *)baseURL
                  requestNumber:(NSInteger)requestNumber {
    NSURLComponents *components = [NSURLComponents componentsWithURL:baseURL
        resolvingAgainstBaseURL:NO];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (![item.name isEqualToString:@"rn"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"rn"
        value:[NSString stringWithFormat:@"%ld", (long)requestNumber]]];
    components.queryItems = items;
    return components.URL;
}

- (void)start {
    if (self.finished) return;
    if (self.ustreamerConfig.length == 0) {
        NSError *responseError = nil;
        if (![self applyPlayerResponse:self.playerResponse error:&responseError]) {
            [self fail:responseError ?: [self error:@"SABR setup failed." code:2]];
            return;
        }
    }
    if (YTKACESABRCurrentNativeBody(self.videoID, self.ustreamerConfig).length == 0) {
        if (self.preparationAttempts == 0) {
            YTKACEDownloadLog(self.identifier, @"waiting native video=%@", self.videoID);
        }
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (!self.preparationInFlight &&
            (self.lastPreparationRequest == 0.0 ||
             now - self.lastPreparationRequest >= 2.0)) {
            self.preparationInFlight = YES;
            self.lastPreparationRequest = now;
            __weak YTKACESABRSession *weakSelf = self;
            YTKACEPreparePlayer(self.videoID, ^(id playerResponse, NSError *prepareError) {
                YTKACESABRSession *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.finished) return;
                strongSelf.preparationInFlight = NO;
                if (playerResponse != nil) {
                    NSError *applyError = nil;
                    [strongSelf applyPlayerResponse:playerResponse error:&applyError];
                }
                YTKACEDownloadLog(strongSelf.identifier,
                    @"prepare result=%@ error=%@",
                    playerResponse != nil ? @"response" : @"none",
                    prepareError.localizedDescription ?: @"none");
                dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf start]; });
            });
        }
        self.preparationAttempts += 1;
        if (self.preparationAttempts > 300) {
            [self fail:[self error:
                @"YouTube could not prepare this video automatically. Play it briefly and retry."
                code:10]];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    YTKACEDownloadLog(self.identifier, @"native ready video=%@ wait=%ld",
        self.videoID, (long)self.preparationAttempts);
    NSError *error = nil;
    if (![self prepare:&error]) {
        [self fail:error ?: [self error:@"SABR setup failed." code:2]];
        return;
    }
    self.headers = [NSMutableDictionary dictionary];
    self.contexts = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 60.0;
    configuration.timeoutIntervalForResource = 3600.0;
    configuration.waitsForConnectivity = YES;
    configuration.allowsCellularAccess = YES;
    configuration.allowsExpensiveNetworkAccess = YES;
    configuration.allowsConstrainedNetworkAccess = YES;
    configuration.networkServiceType = (NSURLRequestNetworkServiceType)8;
    configuration.HTTPMaximumConnectionsPerHost = 4;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
    self.session = [NSURLSession sessionWithConfiguration:configuration
        delegate:self delegateQueue:queue];
    NSString *serverHost = [NSURL URLWithString:self.serverURL].host ?: @"unknown";
    YTKACEDownloadLog(self.identifier,
        @"SABR start video=%ld audio=%ld server=%@ mode=%@ connections=%ld native=%d",
        (long)self.video.option.itag, (long)self.audio.option.itag, serverHost,
        self.combinedMode ? @"combined" : @"sequential", 4L,
        YTKACEHasNativeOnesieSession(self.videoID));
    YTKACEDownloadLog(self.identifier,
        @"formats video=%ld lmt=%ld xtags=%@ quality=%@ mime=%@ audio=%ld lmt=%ld xtags=%@",
        (long)self.video.option.itag, (long)self.video.option.lastModified,
        self.video.option.xtags, self.video.option.qualityLabel, self.video.option.mimeType,
        (long)self.audio.option.itag, (long)self.audio.option.lastModified,
        self.audio.option.xtags);
    YTKACEDownloadLog(self.identifier, @"PoToken bytes=%lu",
        (unsigned long)YTKACESABRCurrentPoToken().length);
    [self sendRequest];
}

- (void)sendRequest {
    if (self.finished || self.requestBuildInFlight) return;
    if (self.requestNumber > 10000) {
        [self fail:[self error:@"The SABR stream did not finish." code:3]];
        return;
    }
    [self sendPreparedRequest:nil nativeRequestNumber:self.requestNumber];
}

- (void)sendPreparedRequest:(NSURLRequest *)nativeRequest
        nativeRequestNumber:(NSInteger)nativeRequestNumber {
    if (self.finished) return;
    (void)nativeRequest;
    (void)nativeRequestNumber;
    NSInteger logicalRequestNumber = self.requestNumber;
    NSInteger wireRequestNumber = logicalRequestNumber;
    NSURL *baseURL = [NSURL URLWithString:self.serverURL];
    if (!YTKACESABRIsAllowedServerURL(baseURL)) {
        [self fail:[self error:@"SABR setup did not provide a safe request URL." code:2]];
        return;
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:baseURL];
    request.URL = [self requestURLForBaseURL:baseURL
        requestNumber:wireRequestNumber];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [self requestBody];
    NSDictionary<NSString *, NSString *> *nativeHeaders =
        YTKACESABRCurrentNativeHeaders(self.videoID, self.ustreamerConfig);
    for (NSString *key in nativeHeaders) {
        NSString *lower = key.lowercaseString;
        if ([lower isEqualToString:@"host"] ||
            [lower isEqualToString:@"content-length"] ||
            [lower isEqualToString:@"content-encoding"] ||
            [lower isEqualToString:@"content-type"] ||
            [lower isEqualToString:@"accept"] ||
            [lower isEqualToString:@"accept-encoding"]) continue;
        [request setValue:nativeHeaders[key] forHTTPHeaderField:key];
    }
    [request setValue:nil forHTTPHeaderField:@"Content-Length"];
    [request setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"application/vnd.yt-ump" forHTTPHeaderField:@"Accept"];
    self.activeRequestNumber = logicalRequestNumber;
    self.activeRequestStart = NSDate.date.timeIntervalSinceReferenceDate;
    self.lastLiveProgress = 0.0;
    self.activeBaseAudioBytes = self.audio.downloadedBytes;
    self.activeBaseVideoBytes = self.video.downloadedBytes;
    self.activeNetworkBytes = 0;
    self.activeResponseData = [NSMutableData data];
    self.activeResponse = nil;
    YTKACEDownloadLog(self.identifier,
        @"request logical=%ld wire=%ld source=%@ url=%@ body=%lu",
        (long)logicalRequestNumber, (long)wireRequestNumber,
        nativeHeaders.count != 0 ? @"native-session" : @"raw", request.URL.host,
        (unsigned long)request.HTTPBody.length);
    self.requestNumber += 1;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    task.taskDescription = [NSString stringWithFormat:@"%ld",
        (long)logicalRequestNumber];
    task.priority = NSURLSessionTaskPriorityHigh;
    [task resume];
}

- (void)refreshNativeSession:(NSString *)reason {
    if (self.finished) return;
    if (self.nativeRefreshInFlight) return;
    if (self.nativeRefreshAttempts >= 3) {
        [self retryOrFail:[self error:
            @"YouTube could not refresh the native download session." code:9]];
        return;
    }
    self.nativeRefreshInFlight = YES;
    self.nativeRefreshAttempts += 1;
    YTKACEDownloadLog(self.identifier, @"native refresh attempt=%ld reason=%@",
        (long)self.nativeRefreshAttempts, reason ?: @"authorization");
    __weak YTKACESABRSession *weakSelf = self;
    YTKACEPreparePlayer(self.videoID, ^(id playerResponse, NSError *error) {
        YTKACESABRSession *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.finished) return;
        strongSelf.nativeRefreshInFlight = NO;
        NSError *applyError = nil;
        BOOL applied = playerResponse != nil &&
            [strongSelf applyPlayerResponse:playerResponse error:&applyError];
        if (!applied) {
            NSError *finalError = error ?: applyError ?: [strongSelf error:
                @"YouTube could not refresh the native download session." code:9];
            [strongSelf retryOrFail:finalError];
            return;
        }
        strongSelf.retryCount = 0;
        strongSelf.stalledRequests = 0;
        strongSelf.playbackCookie = nil;
        [strongSelf.contexts removeAllObjects];
        [strongSelf.headers removeAllObjects];
        [strongSelf sendRequest];
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    if (dataTask.taskDescription.integerValue == self.activeRequestNumber) {
        self.activeResponse = (NSHTTPURLResponse *)response;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (self.finished || dataTask.taskDescription.integerValue != self.activeRequestNumber) return;
    [self.activeResponseData appendData:data];
    self.activeNetworkBytes += (int64_t)data.length;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (self.mediaPhase == 0 || now - self.lastLiveProgress < 0.08) return;
    self.lastLiveProgress = now;
    int64_t audioBytes = self.activeBaseAudioBytes;
    int64_t videoBytes = self.activeBaseVideoBytes;
    if (self.combinedMode) {
        int64_t estimatedMediaBytes =
            (int64_t)llround((double)self.activeNetworkBytes * 0.985);
        double audioWeight = MAX(self.audio.option.bitrate, 0);
        double videoWeight = MAX(self.video.option.bitrate, 0);
        if (audioWeight + videoWeight <= 0.0) {
            audioWeight = MAX(self.audio.option.contentLength - audioBytes, 0);
            videoWeight = MAX(self.video.option.contentLength - videoBytes, 0);
        }
        double totalWeight = audioWeight + videoWeight;
        double audioShare = totalWeight > 0.0 ? audioWeight / totalWeight : 0.04;
        audioShare = MIN(MAX(audioShare, 0.005), 0.30);
        int64_t estimatedAudio =
            (int64_t)llround((double)estimatedMediaBytes * audioShare);
        audioBytes += estimatedAudio;
        videoBytes += estimatedMediaBytes - estimatedAudio;
        if (self.audio.option.contentLength > 0) {
            audioBytes = MIN(audioBytes, self.audio.option.contentLength);
        }
        if (self.video.option.contentLength > 0) {
            videoBytes = MIN(videoBytes, self.video.option.contentLength);
        }
    } else if (self.mediaPhase == 1) {
        audioBytes += self.activeNetworkBytes;
        if (self.audio.option.contentLength > 0) {
            audioBytes = MIN(audioBytes, self.audio.option.contentLength);
        }
    } else {
        videoBytes += self.activeNetworkBytes;
        if (self.video.option.contentLength > 0) {
            videoBytes = MIN(videoBytes, self.video.option.contentLength);
        }
    }
    [self sendProgressWithAudioBytes:audioBytes videoBytes:videoBytes];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {
    (void)session;
    if (self.finished || task.taskDescription.integerValue != self.activeRequestNumber) return;
    NSData *data = [self.activeResponseData copy];
    NSHTTPURLResponse *http = self.activeResponse ?: (NSHTTPURLResponse *)task.response;
    NSTimeInterval elapsed = MAX(NSDate.date.timeIntervalSinceReferenceDate -
        self.activeRequestStart, 0.001);
    double megabytesPerSecond = ((double)data.length / 1048576.0) / elapsed;
    YTKACEDownloadLog(self.identifier,
        @"response %ld status=%ld bytes=%lu seconds=%.2f speed=%.2fMB/s error=%@",
        (long)self.activeRequestNumber, (long)http.statusCode, (unsigned long)data.length,
        elapsed, megabytesPerSecond, error.localizedDescription ?: @"none");
    if (error != nil || http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
        NSError *requestError = error ?: [self error:
            [NSString stringWithFormat:@"SABR returned HTTP %ld.", (long)http.statusCode]
            code:4];
        if ((http.statusCode == 401 || http.statusCode == 403 ||
             http.statusCode == 409 || http.statusCode == 410) &&
            YTKACEHasNativeOnesieSession(self.videoID)) {
            [self refreshNativeSession:requestError.localizedDescription];
        } else {
            [self retryOrFail:requestError];
        }
        return;
    }
    [self processResponse:data];
}

- (void)retryOrFail:(NSError *)error {
    if (self.combinedMode && self.retryCount >= 2 &&
        [self switchToSequentialFallback:error.localizedDescription]) {
        return;
    }
    self.retryCount += 1;
    if (self.retryCount > 8) {
        [self fail:error];
        return;
    }
    NSTimeInterval delay = MIN(pow(2.0, self.retryCount - 1) * 0.5, 12.0);
    YTKACEDownloadLog(self.identifier, @"retry %ld delay=%.1f reason=%@",
        (long)self.retryCount, delay, error.localizedDescription);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
}

- (void)handleInitialization:(NSData *)data {
    NSData *formatID = YTKACEPBDataField(data, 2);
    NSInteger itag = (NSInteger)YTKACEPBIntegerField(formatID, 1, 0);
    NSString *xtags = YTKACEPBStringField(formatID, 3) ?: @"";
    YTKACESABRTrack *track = [self trackForItag:itag xtags:xtags];
    if (track == nil) return;
    track.initialized = YES;
    track.endTime = (int64_t)YTKACEPBIntegerField(data, 3, 0);
    track.endSequence = (NSInteger)YTKACEPBIntegerField(data, 4, NSIntegerMax);
    YTKACEDownloadLog(self.identifier, @"init itag=%ld end=%lld sequence=%ld",
        (long)itag, track.endTime, (long)track.endSequence);
}

- (void)handlePolicy:(NSData *)data {
    self.backoffMilliseconds = (NSInteger)YTKACEPBIntegerField(data, 4, 0);
    NSData *cookie = YTKACEPBDataField(data, 7);
    if (cookie.length != 0) self.playbackCookie = cookie;
}

- (void)handleContext:(NSData *)data {
    NSNumber *type = @((NSInteger)YTKACEPBIntegerField(data, 1, 0));
    NSData *value = YTKACEPBDataField(data, 3);
    BOOL send = YTKACEPBIntegerField(data, 4, 0) != 0;
    NSInteger policy = (NSInteger)YTKACEPBIntegerField(data, 5, 0);
    if (type.integerValue == 0 || value.length == 0 || !send) return;
    if (policy != 2 || self.contexts[type] == nil) self.contexts[type] = value;
}

- (void)handleHeader:(NSData *)data {
    YTKACESABRHeader *header = [YTKACESABRHeader new];
    header.headerID = (NSInteger)YTKACEPBIntegerField(data, 1, 0);
    header.itag = (NSInteger)YTKACEPBIntegerField(data, 3, 0);
    header.xtags = YTKACEPBStringField(data, 5) ?: @"";
    header.initialization = YTKACEPBIntegerField(data, 8, 0) != 0;
    header.sequence = (NSInteger)YTKACEPBIntegerField(data, 9, 0);
    header.startTime = (int64_t)YTKACEPBIntegerField(data, 11, 0);
    header.duration = (int64_t)YTKACEPBIntegerField(data, 12, 0);
    NSData *timeRange = YTKACEPBDataField(data, 15);
    int64_t timescale = (int64_t)YTKACEPBIntegerField(timeRange, 3, 0);
    if (timescale > 0) {
        if (header.startTime == 0) {
            int64_t ticks = (int64_t)YTKACEPBIntegerField(timeRange, 1, 0);
            header.startTime = (ticks * 1000) / timescale;
        }
        if (header.duration == 0) {
            int64_t ticks = (int64_t)YTKACEPBIntegerField(timeRange, 2, 0);
            header.duration = (ticks * 1000) / timescale;
        }
    }
    header.contentLength = (int64_t)YTKACEPBIntegerField(data, 14, 0);
    NSData *formatID = YTKACEPBDataField(data, 13);
    if (header.itag == 0 && formatID != nil) {
        header.itag = (NSInteger)YTKACEPBIntegerField(formatID, 1, 0);
        header.xtags = YTKACEPBStringField(formatID, 3) ?: header.xtags;
    }
    header.data = [NSMutableData data];
    if (header.headerID >= 0) self.headers[@(header.headerID)] = header;
}

- (void)handleMedia:(NSData *)data {
    if (data.length < 1) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    YTKACESABRHeader *header = self.headers[@(bytes[0])];
    if (header == nil || data.length == 1) return;
    [header.data appendData:[data subdataWithRange:NSMakeRange(1, data.length - 1)]];
}

- (void)finishHeader:(NSData *)data {
    if (data.length < 1) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSNumber *key = @(bytes[0]);
    YTKACESABRHeader *header = self.headers[key];
    [self.headers removeObjectForKey:key];
    YTKACESABRTrack *track = [self trackForItag:header.itag xtags:header.xtags];
    if (track == nil || header.data.length == 0) {
        YTKACEDownloadLog(self.identifier,
            @"segment ignored itag=%ld bytes=%lu", (long)header.itag,
            (unsigned long)header.data.length);
        return;
    }
    NSString *segmentKey = [NSString stringWithFormat:@"%ld:%@:%ld:%d",
        (long)header.itag, header.xtags, (long)header.sequence, header.initialization];
    if ([track.segments containsObject:segmentKey]) return;
    if (header.contentLength > 0 && header.data.length != (NSUInteger)header.contentLength) {
        YTKACEDownloadLog(self.identifier,
            @"segment size mismatch itag=%ld got=%lu expected=%lld",
            (long)header.itag, (unsigned long)header.data.length,
            header.contentLength);
        return;
    }
    [track.segments addObject:segmentKey];
    if (header.initialization) {
        if (!track.initializationWritten) {
            [track.handle writeData:header.data];
            track.initializationWritten = YES;
        }
        return;
    }
    [track.handle writeData:header.data];
    track.downloadedBytes += (int64_t)header.data.length;
    track.lastSequence = MAX(track.lastSequence, header.sequence);
    track.downloadedDuration += MAX(header.duration, 0);
    if (!track.hasRound) {
        track.hasRound = YES;
        track.roundStart = header.startTime;
        track.roundStartSequence = header.sequence;
    }
    track.roundDuration += MAX(header.duration, 0);
    track.roundStartSequence = MIN(track.roundStartSequence, header.sequence);
    track.roundEndSequence = MAX(track.roundEndSequence, header.sequence);
}

- (void)handleRedirect:(NSData *)data {
    NSString *redirect = YTKACEPBStringField(data, 1);
    if (redirect.length != 0) {
        NSURL *redirectURL = [NSURL URLWithString:redirect];
        if (!YTKACESABRIsAllowedServerURL(redirectURL)) {
            YTKACEDownloadLog(self.identifier, @"rejected unsafe SABR redirect");
            return;
        }
        self.serverURL = redirectURL.absoluteString;
        YTKACEDownloadLog(self.identifier, @"redirect host=%@",
            redirectURL.host);
    }
}

- (BOOL)trackComplete:(YTKACESABRTrack *)track {
    if (track.endSequence != NSIntegerMax && track.lastSequence >= track.endSequence) {
        return YES;
    }
    return track.endTime > 0 && track.downloadedDuration + 1000 >= track.endTime;
}

- (YTKACESABRTrack *)activeTrack {
    return self.mediaPhase == 2 ? self.video : self.audio;
}

- (void)advanceOrFinish {
    if (self.audioOnly || self.mediaPhase == 2 ||
        (self.mediaPhase == 1 && [self trackComplete:self.video])) {
        [self finish];
        return;
    }
    self.mediaPhase = 2;
    self.stalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    YTKACEDownloadLog(self.identifier, @"phase video");
    [self sendProgress];
    [self sendRequest];
}

- (void)sendProgressWithAudioBytes:(int64_t)audioBytes videoBytes:(int64_t)videoBytes {
    double video = self.video.endTime > 0
        ? (double)self.video.downloadedDuration / (double)self.video.endTime : 0.0;
    double audio = self.audio.endTime > 0
        ? (double)self.audio.downloadedDuration / (double)self.audio.endTime : 0.0;
    if (self.progress != nil) {
        audio = MIN(MAX(audio, 0.0), 1.0);
        video = MIN(MAX(video, 0.0), 1.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progress(audio, video, audioBytes, videoBytes, self.mediaPhase);
        });
    }
}

- (void)sendProgress {
    [self sendProgressWithAudioBytes:self.audio.downloadedBytes
        videoBytes:self.video.downloadedBytes];
}

- (void)processResponse:(NSData *)response {
    int64_t beforeAudio = self.audio.downloadedDuration;
    int64_t beforeVideo = self.video.downloadedDuration;
    int64_t before = beforeVideo + beforeAudio;
    BOOL rejected = NO;
    BOOL attestation = NO;
    NSString *rejectionType = nil;
    NSInteger rejectionCode = 0;
    NSInteger protectionStatus = 0;
    NSInteger protectionRetries = 0;
    BOOL terminalMarker = NO;
    NSString *reloadToken = nil;
    NSMutableDictionary<NSNumber *, NSNumber *> *partCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *partBytes = [NSMutableDictionary dictionary];
    NSUInteger offset = 0;
    while (offset < response.length) {
        uint32_t type = 0;
        uint32_t size = 0;
        if (!YTKACEUMPValue(response, &offset, &type) ||
            !YTKACEUMPValue(response, &offset, &size) || offset + size > response.length) {
            [self retryOrFail:[self error:@"YouTube returned an incomplete SABR response." code:5]];
            return;
        }
        NSData *part = [response subdataWithRange:NSMakeRange(offset, size)];
        offset += size;
        NSNumber *partType = @(type);
        partCounts[partType] = @([partCounts[partType] unsignedIntegerValue] + 1);
        partBytes[partType] = @([partBytes[partType] unsignedLongLongValue] + size);
        if (self.requestNumber <= 1 && (type == 46 || type == 51)) {
            YTKACEDownloadLog(self.identifier, @"directive type=%u bytes=%lu", type,
                (unsigned long)part.length);
        }
        if (type == 20) [self handleHeader:part];
        else if (type == 21) [self handleMedia:part];
        else if (type == 22) [self finishHeader:part];
        else if (type == 35) [self handlePolicy:part];
        else if (type == 42) [self handleInitialization:part];
        else if (type == 43) [self handleRedirect:part];
        else if (type == 46) {
            NSData *params = YTKACEPBDataField(part, 1);
            reloadToken = YTKACEPBStringField(params, 1);
        }
        else if (type == 44) {
            rejected = YES;
            rejectionType = YTKACEPBStringField(part, 1);
            rejectionCode = (NSInteger)YTKACEPBIntegerField(part, 2, 0);
            YTKACEDownloadLog(self.identifier, @"SABR error type=%@ code=%ld data=%@",
                rejectionType ?: @"unknown", (long)rejectionCode,
                YTKACESABRHex(part, 64));
        }
        else if (type == 47 && size <= 8) terminalMarker = YES;
        else if (type == 57) [self handleContext:part];
        else if (type == 58) {
            protectionStatus = (NSInteger)YTKACEPBIntegerField(part, 1, 0);
            protectionRetries = (NSInteger)YTKACEPBIntegerField(part, 2, 0);
            attestation = protectionStatus >= 3;
            YTKACEDownloadLog(self.identifier,
                @"protection status=%ld retries=%ld data=%@", (long)protectionStatus,
                (long)protectionRetries, YTKACESABRHex(part, 64));
        }
    }
    NSMutableArray<NSString *> *partSummary = [NSMutableArray array];
    NSArray<NSNumber *> *sortedTypes = [partCounts.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *partType in sortedTypes) {
        [partSummary addObject:[NSString stringWithFormat:@"%@:%@/%@",
            partType, partCounts[partType], partBytes[partType]]];
    }
    YTKACEDownloadLog(self.identifier, @"UMP parts=%@",
        [partSummary componentsJoinedByString:@","]);
    if (reloadToken.length != 0 && !self.reloadInFlight && self.reloadCount < 3) {
        self.reloadInFlight = YES;
        self.reloadCount += 1;
        YTKACEDownloadLog(self.identifier, @"reload requested attempt=%ld token=%lu",
            (long)self.reloadCount, (unsigned long)reloadToken.length);
        __weak YTKACESABRSession *weakSelf = self;
        YTKACEReloadPlayer(self.videoID, reloadToken,
            ^(id playerResponse, NSError *error) {
            YTKACESABRSession *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.finished) return;
            strongSelf.reloadInFlight = NO;
            NSError *applyError = nil;
            if (playerResponse == nil || ![strongSelf applyPlayerResponse:playerResponse
                                                                     error:&applyError]) {
                NSError *finalError = error ?: applyError ?: [strongSelf error:
                    @"YouTube could not refresh the high-resolution stream." code:9];
                YTKACEDownloadLog(strongSelf.identifier, @"reload failed error=%@",
                    finalError.localizedDescription);
                [strongSelf retryOrFail:finalError];
                return;
            }
            strongSelf.stalledRequests = 0;
            strongSelf.retryCount = 0;
            strongSelf.requestNumber = 0;
            strongSelf.playbackCookie = nil;
            [strongSelf.contexts removeAllObjects];
            [strongSelf.headers removeAllObjects];
            YTKACEDownloadLog(strongSelf.identifier, @"reload applied host=%@ config=%lu",
                [NSURL URLWithString:strongSelf.serverURL].host,
                (unsigned long)strongSelf.ustreamerConfig.length);
            [strongSelf sendRequest];
            });
        return;
    }
    if (protectionStatus == 2 && [partCounts[@21] unsignedIntegerValue] == 0) {
        attestation = YES;
    }
    if (attestation || rejected) {
        NSString *message = attestation
            ? [NSString stringWithFormat:@"YouTube requires stream authorization (%ld).",
                (long)protectionStatus]
            : [NSString stringWithFormat:@"YouTube rejected the SABR request (%@/%ld).",
                rejectionType ?: @"unknown", (long)rejectionCode];
        NSError *error = [self error:message
            code:attestation ? 7 : 6];
        if (self.attestationRetries < 3) {
            self.attestationRetries += 1;
            if (YTKACEHasNativeOnesieSession(self.videoID)) {
                [self refreshNativeSession:message];
            } else {
                [self retryOrFail:error];
            }
        } else {
            [self fail:error];
        }
        return;
    }
    [self sendProgress];
    YTKACESABRTrack *activeTrack = [self activeTrack];
    if (self.combinedMode && [self trackComplete:self.video] &&
        [self trackComplete:self.audio]) {
        [self finish];
        return;
    }
    int64_t afterAudio = self.audio.downloadedDuration;
    int64_t afterVideo = self.video.downloadedDuration;
    if (self.combinedMode) {
        self.audioStalledRequests = [self trackComplete:self.audio] ||
            afterAudio > beforeAudio ? 0 : self.audioStalledRequests + 1;
        self.videoStalledRequests = [self trackComplete:self.video] ||
            afterVideo > beforeVideo ? 0 : self.videoStalledRequests + 1;
        BOOL trackStalled = self.audioStalledRequests >= 3 ||
            self.videoStalledRequests >= 3;
        BOOL endedEarly = terminalMarker && afterAudio + afterVideo <= before;
        if ((trackStalled || endedEarly) &&
            [self switchToSequentialFallback:trackStalled
                ? @"one track stopped advancing" : @"combined stream ended early"]) {
            return;
        }
    }
    if (self.mediaPhase > 0 && [self trackComplete:activeTrack]) {
        if (!self.combinedMode) [self advanceOrFinish];
        else [self sendRequest];
        return;
    }
    int64_t after = afterVideo + afterAudio;
    BOOL hasActiveMedia = self.combinedMode
        ? ((self.video.initializationWritten && self.video.downloadedBytes > 0) ||
           (self.audio.initializationWritten && self.audio.downloadedBytes > 0))
        : (activeTrack.initializationWritten && activeTrack.downloadedBytes > 0);
    if (!self.combinedMode && self.mediaPhase > 0 && terminalMarker &&
        after <= before && hasActiveMedia) {
        if ([self restartStalledSession:@"early terminal marker"]) return;
        [self fail:[self error:@"The SABR stream ended before all media was received."
                               code:8]];
        return;
    }
    if (after <= before) self.stalledRequests += 1;
    else {
        self.stalledRequests = 0;
        self.retryCount = 0;
        self.stallRecoveryCount = 0;
        self.nativeRefreshAttempts = 0;
        self.attestationRetries = 0;
    }
    YTKACEDownloadLog(self.identifier,
        @"progress audio=%.3f/%lld video=%.3f/%lld bytes=%lld+%lld stalled=%ld",
        (double)self.audio.downloadedDuration, self.audio.endTime,
        (double)self.video.downloadedDuration, self.video.endTime,
        self.audio.downloadedBytes, self.video.downloadedBytes,
        (long)self.stalledRequests);
    BOOL missingInitialization = self.audio.endTime == 0 ||
        (!self.audioOnly && self.video.endTime == 0);
    if (self.combinedMode && missingInitialization && self.stalledRequests >= 3 &&
        [self switchToSequentialFallback:@"missing combined initialization"]) {
        return;
    }
    if (!self.combinedMode && self.mediaPhase > 0 &&
        self.stalledRequests >= 3 && hasActiveMedia &&
        [self restartStalledSession:@"media stopped advancing"]) {
        return;
    }
    if ((missingInitialization && self.stalledRequests >= 3) || self.stalledRequests > 8) {
        [self fail:[self error:@"The SABR download stopped making progress." code:8]];
        return;
    }
    NSTimeInterval delay = MAX(self.backoffMilliseconds, 0) / 1000.0;
    self.backoffMilliseconds = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
}

- (BOOL)restartStalledSession:(NSString *)reason {
    if (self.finished || self.stallRecoveryCount >= 3) return NO;
    self.stallRecoveryCount += 1;
    NSTimeInterval delay = MAX(self.backoffMilliseconds, 250) / 1000.0;
    self.requestNumber = 0;
    self.stalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    self.playbackCookie = nil;
    [self.headers removeAllObjects];
    [self.contexts removeAllObjects];
    YTKACEDownloadLog(self.identifier,
        @"session restart attempt=%ld phase=%ld reason=%@ audio=%.0f/%lld video=%.0f/%lld",
        (long)self.stallRecoveryCount, (long)self.mediaPhase, reason ?: @"stalled",
        (double)self.audio.downloadedDuration, self.audio.endTime,
        (double)self.video.downloadedDuration, self.video.endTime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
    return YES;
}

- (BOOL)switchToSequentialFallback:(NSString *)reason {
    if (!self.combinedMode || self.finished) return NO;
    self.combinedMode = NO;
    self.sequentialFallback = YES;
    self.mediaPhase = [self trackComplete:self.audio] ? 2 : 1;
    self.stalledRequests = 0;
    self.audioStalledRequests = 0;
    self.videoStalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    [self.headers removeAllObjects];
    YTKACEDownloadLog(self.identifier,
        @"combined fallback phase=%@ reason=%@ audio=%lld video=%lld",
        self.mediaPhase == 1 ? @"audio" : @"video", reason ?: @"unknown",
        self.audio.downloadedBytes, self.video.downloadedBytes);
    [self sendProgress];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self sendRequest];
    });
    return YES;
}

- (void)finish {
    if (self.finished) return;
    if (![self trackComplete:self.audio] ||
        (!self.audioOnly && ![self trackComplete:self.video])) {
        [self fail:[self error:@"The SABR stream ended before all media was received."
                               code:8]];
        return;
    }
    self.finished = YES;
    [self.video.handle closeFile];
    [self.audio.handle closeFile];
    [self.session invalidateAndCancel];
    YTKACEDownloadLog(self.identifier, @"SABR complete audio=%lld video=%lld",
        self.audio.downloadedBytes, self.video.downloadedBytes);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.completion(self.video.URL, self.audio.URL, nil);
    });
}

- (void)fail:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.video.handle closeFile];
    [self.audio.handle closeFile];
    [self.session invalidateAndCancel];
    YTKACEDownloadLog(self.identifier, @"SABR failed code=%ld error=%@",
        (long)error.code, error.localizedDescription);
    NSURL *scratch = self.video.URL.URLByDeletingLastPathComponent
        ?: self.audio.URL.URLByDeletingLastPathComponent;
    if (self.video.URL != nil) [NSFileManager.defaultManager removeItemAtURL:self.video.URL error:nil];
    if (self.audio.URL != nil) [NSFileManager.defaultManager removeItemAtURL:self.audio.URL error:nil];
    if ([scratch.lastPathComponent hasPrefix:@"YTKACE-"]) {
        [NSFileManager.defaultManager removeItemAtURL:scratch error:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(nil, nil, error); });
}

- (void)cancel {
    if (self.finished) return;
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorCancelled userInfo:@{
            NSLocalizedDescriptionKey: @"Download cancelled"
        }];
    [self fail:error];
}

@end

@interface YTKACESABRTask ()
@property(nonatomic, copy) dispatch_block_t cancelBlock;
@end

@implementation YTKACESABRTask

- (void)cancel {
    if (self.cancelBlock != nil) self.cancelBlock();
}

@end

@implementation YTKACESABRDownloader

+ (YTKACESABRTask *)downloadPlayerResponse:(id)playerResponse
                   videoOption:(YTKACEStreamOption *)videoOption
                   audioOption:(YTKACEStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                       videoID:(NSString *)videoID
                     identifier:(NSString *)identifier
                      progress:(YTKACESABRProgress)progress
                    completion:(YTKACESABRCompletion)completion {
    YTKACESABRSession *session = [YTKACESABRSession new];
    YTKACESABRTask *task = [YTKACESABRTask new];
    session.playerResponse = playerResponse;
    session.video = [YTKACESABRTrack new];
    session.video.option = videoOption;
    session.audio = [YTKACESABRTrack new];
    session.audio.option = audioOption;
    session.audioOnly = audioOnly;
    session.combinedMode = YTKACE_COMBINED_SABR && !audioOnly;
    session.videoID = videoID ?: @"";
    session.identifier = identifier;
    session.progress = progress;
    session.completion = completion;
    __weak YTKACESABRSession *weakSession = session;
    task.cancelBlock = ^{ [weakSession cancel]; };
    objc_setAssociatedObject(session, @selector(start), session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACESABRCompletion original = [completion copy];
    __weak YTKACESABRTask *weakTask = task;
    session.completion = ^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
        original(videoURL, audioURL, error);
        weakTask.cancelBlock = nil;
        YTKACESABRSession *strongSession = weakSession;
        objc_setAssociatedObject(strongSession, @selector(start), nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    [session start];
    return task;
}

@end
