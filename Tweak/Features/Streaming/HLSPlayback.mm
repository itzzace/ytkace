#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>

// visionOS client identifiers from yt-dlp (Unlicense, public domain)
static NSString *const YTKACEVisionClientName    = @"VISIONOS";
static NSString *const YTKACEVisionClientVersion = @"1.02";
static NSString *const YTKACEVisionDeviceMake    = @"Apple";
static NSString *const YTKACEVisionDeviceModel   = @"RealityDevice17,1";
static NSString *const YTKACEVisionOSName        = @"visionOS";
static NSString *const YTKACEVisionOSVersion     = @"26.5.23O471";
static NSString *const YTKACEVisionUserAgent     =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";

static const NSTimeInterval YTKACEHLSCacheLifetime = 4.0 * 60.0 * 60.0;

static IMP YTKACEHLSOrigInitFull;
static IMP YTKACEHLSOrigInitShort;
static IMP YTKACEHLSOrigInitRental;
static IMP YTKACEHLSOrigParseString;
static IMP YTKACEHLSOrigSetConstraint;
static IMP YTKACEHLSOrigPlay;
static IMP YTKACEHLSOrigPause;
static IMP YTKACEHLSOrigScrubStart;
static IMP YTKACEHLSOrigScrubEnd;

static NSMutableDictionary<NSString *, NSDictionary *> *YTKACEHLSCache;
static NSMutableSet<NSString *> *YTKACEHLSPending;
static NSMutableDictionary<NSString *, id> *YTKACEHLSOriginals;

static NSMutableDictionary<NSString *, NSString *> *YTKACEHLSSources;
static NSMutableSet<NSString *> *YTKACEHLSFallbacks;
static BOOL YTKACEHLSInScrubStart;
static BOOL YTKACEHLSScrubPaused;
static NSUInteger YTKACEHLSScrubGeneration;

static BOOL YTKACEHLSEnabled(void) {
    return YTKACEPlaybackFixMode() == 2;
}

static id YTKACEHLSGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL YTKACEHLSBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long YTKACEHLSInteger(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return LLONG_MIN;
    const char *type = [object methodSignatureForSelector:selector].methodReturnType;
    if (type[0] == 'i') return ((int (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'q' || type[0] == 'l') return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'B' || type[0] == 'c') return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return LLONG_MIN;
}

static NSDictionary *YTKACEVisionContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": YTKACEVisionClientName,
        @"clientVersion": YTKACEVisionClientVersion,
        @"deviceMake": YTKACEVisionDeviceMake,
        @"deviceModel": YTKACEVisionDeviceModel,
        @"osName": YTKACEVisionOSName,
        @"osVersion": YTKACEVisionOSVersion,
        @"userAgent": YTKACEVisionUserAgent,
        @"hl": @"en",
        @"gl": @"US"
    } mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSMutableURLRequest *YTKACEVisionRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *url = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 12;
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:YTKACEVisionUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *YTKACEVisionVisitor(void) {
    NSDictionary *cached = YTKACEPreferenceObject(@"YTKACE.Cache.DirectVisitor");
    NSString *value = [cached isKindOfClass:NSDictionary.class] ? cached[@"id"] : nil;
    if ([value isKindOfClass:NSString.class] && value.length != 0) return value;
    static NSString *fetched;
    if (fetched.length != 0) return fetched;
    __block NSString *visitor = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:YTKACEVisionRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": YTKACEVisionContext(nil)}, nil)
        completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id found = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
        if ([found isKindOfClass:NSString.class]) visitor = found;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
    fetched = visitor;
    return visitor;
}

static NSString *YTKACEHLSCachedURL(NSString *videoID) {
    @synchronized (YTKACEHLSCache) {
        NSDictionary *entry = YTKACEHLSCache[videoID];
        if (entry == nil) return nil;
        if (NSDate.date.timeIntervalSince1970 - [entry[@"time"] doubleValue] > YTKACEHLSCacheLifetime) {
            [YTKACEHLSCache removeObjectForKey:videoID];
            return nil;
        }
        return entry[@"url"];
    }
}

static void YTKACEHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready));

static void YTKACEHLSFetchVision(NSString *videoID) {
    YTKACEHLSFetchVisionThen(videoID, nil);
}

static void YTKACEHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready)) {
    @synchronized (YTKACEHLSCache) {
        const BOOL cached = YTKACEHLSCache[videoID] != nil;
        if (cached) {
            if (done != nil) done(YES);
            return;
        }
        if ([YTKACEHLSPending containsObject:videoID]) {
            if (done != nil) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    done(YTKACEHLSCachedURL(videoID) != nil);
                });
            }
            return;
        }
        [YTKACEHLSPending addObject:videoID];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *visitor = YTKACEVisionVisitor();
        NSDictionary *body = @{
            @"context": YTKACEVisionContext(visitor),
            @"videoId": videoID,
            @"contentCheckOk": @YES,
            @"racyCheckOk": @YES
        };
        [[NSURLSession.sharedSession dataTaskWithRequest:YTKACEVisionRequest(@"player?prettyPrint=false", body, visitor)
            completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *root = [json isKindOfClass:NSDictionary.class] ? json : @{};
            NSDictionary *playability = [root[@"playabilityStatus"] isKindOfClass:NSDictionary.class]
                ? root[@"playabilityStatus"] : @{};
            NSDictionary *streaming = [root[@"streamingData"] isKindOfClass:NSDictionary.class]
                ? root[@"streamingData"] : @{};
            NSString *hls = [streaming[@"hlsManifestUrl"] isKindOfClass:NSString.class] ? streaming[@"hlsManifestUrl"] : nil;
            @synchronized (YTKACEHLSCache) {
                [YTKACEHLSPending removeObject:videoID];
                if (hls.length != 0) {
                    YTKACEHLSCache[videoID] = @{@"url": hls, @"time": @(NSDate.date.timeIntervalSince1970)};
                }
            }
            if (hls.length == 0) {
                YTKACEDownloadLog(@"hls", @"vision video=%@ playability=%@ no manifest", videoID,
                                  playability[@"status"] ?: @"-");
            }
            if (done != nil) done(hls.length != 0);
        }] resume];
    });
}

static NSString *YTKACEHLSLastVideo;

BOOL YTKACEHLSBeginFallback(NSString *videoID, void (^ready)(BOOL available)) {
    if (!YTKACEHLSEnabled() || YTKACEHLSSources == nil) return NO;
    @synchronized (YTKACEHLSSources) {
        // the player has no video yet when the manifest fails on load
        if (videoID.length == 0) videoID = YTKACEHLSLastVideo;
        if (videoID.length == 0) return NO;
        if (![YTKACEHLSSources[videoID] isEqualToString:@"ios"] || [YTKACEHLSFallbacks containsObject:videoID]) {
            return NO;
        }
        [YTKACEHLSFallbacks addObject:videoID];
    }
    YTKACEHLSFetchVisionThen(videoID, ^(BOOL available) {
        dispatch_async(dispatch_get_main_queue(), ^{ ready(available); });
    });
    return YES;
}

id YTKACEHLSOriginalResponse(NSString *videoID) {
    if (videoID.length == 0 || YTKACEHLSOriginals == nil) return nil;
    @synchronized (YTKACEHLSOriginals) {
        return YTKACEHLSOriginals[videoID];
    }
}

static void YTKACEHLSKeepOriginal(NSString *videoID, id data) {
    if (![data respondsToSelector:@selector(copyWithZone:)]) return;
    id copy = [data copy];
    if (copy == nil) return;
    @synchronized (YTKACEHLSOriginals) {
        if (YTKACEHLSOriginals.count > 20) [YTKACEHLSOriginals removeAllObjects];
        YTKACEHLSOriginals[videoID] = copy;
    }
}

static void YTKACEHLSSwap(id data) {
    if (!YTKACEHLSEnabled() || data == nil) return;
    NSString *videoID = YTKACEHLSGet(YTKACEHLSGet(data, @"videoDetails"), @"videoId");
    if (![videoID isKindOfClass:NSString.class] || videoID.length == 0) {
        YTKACEDebugLog(@"hls", @"skip no video id class=%@", NSStringFromClass([data class]));
        return;
    }
    id streaming = YTKACEHLSGet(data, @"streamingData");
    if (streaming == nil) {
        YTKACEDebugLog(@"hls", @"skip video=%@ no streaming data", videoID);
        return;
    }
    if (YTKACEHLSBool(streaming, @"isLivePlayback")) {
        YTKACEDebugLog(@"hls", @"skip video=%@ live", videoID);
        return;
    }
    SEL setHLS = NSSelectorFromString(@"setHlsManifestURL:");
    SEL setSABR = NSSelectorFromString(@"setHasServerAbrStreamingURL:");
    SEL setOnesie = NSSelectorFromString(@"setHasOnesieStreamingURL:");
    if (![streaming respondsToSelector:setHLS] || ![streaming respondsToSelector:setSABR] ||
        ![streaming respondsToSelector:setOnesie]) {
        YTKACEDebugLog(@"hls", @"skip video=%@ setters missing class=%@", videoID,
                       NSStringFromClass([streaming class]));
        return;
    }
    NSString *ios = YTKACEHLSGet(streaming, @"hlsManifestURL");
    if (![ios isKindOfClass:NSString.class]) ios = nil;
    const NSUInteger token = YTKACESABRPoTokenLength();
    const BOOL untrusted = token > 0 && token < 100;
    YTKACEHLSFetchVision(videoID);
    NSString *vision = YTKACEHLSCachedURL(videoID);
    if (vision.length == 0 && (untrusted || ios.length == 0)) {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.5;
        while (vision.length == 0 && CFAbsoluteTimeGetCurrent() < deadline) {
            usleep(20000);
            vision = YTKACEHLSCachedURL(videoID);
        }
    }
    YTKACEDebugLog(@"hls", @"check video=%@ token=%lu ios=%d vision=%d", videoID, (unsigned long)token,
                   ios.length != 0, vision.length != 0);
    NSString *chosen = vision.length != 0 ? vision : ios;
    if (chosen.length == 0) {
        YTKACEDownloadLog(@"hls", @"skip video=%@ no manifest", videoID);
        return;
    }
    YTKACEHLSKeepOriginal(videoID, data);
    ((void (*)(id, SEL, id))objc_msgSend)(streaming, setHLS, chosen);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setSABR, NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setOnesie, NO);
    NSMutableArray *formats = YTKACEHLSGet(streaming, @"adaptiveFormatsArray");
    if ([formats respondsToSelector:@selector(removeAllObjects)]) [formats removeAllObjects];
    @synchronized (YTKACEHLSSources) {
        if (YTKACEHLSSources.count > 50) [YTKACEHLSSources removeAllObjects];
        YTKACEHLSSources[videoID] = vision.length != 0 ? @"vision" : @"ios";
        YTKACEHLSLastVideo = [videoID copy];
    }
    YTKACEDownloadLog(@"hls", @"swap video=%@ source=%@", videoID, vision.length != 0 ? @"vision" : @"ios");
}

static id YTKACEHLSInitFull(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                            id qoe, id key, id context, id latency, BOOL rental) {
    YTKACEHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, id, id, id, id, BOOL))YTKACEHLSOrigInitFull)(
        self, _cmd, data, date, offline, state, trailer, qoe, key, context, latency, rental);
}

static id YTKACEHLSInitShort(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer) {
    YTKACEHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL))YTKACEHLSOrigInitShort)(
        self, _cmd, data, date, offline, state, trailer);
}

static id YTKACEHLSInitRental(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                              BOOL rental) {
    YTKACEHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, BOOL))YTKACEHLSOrigInitRental)(
        self, _cmd, data, date, offline, state, trailer, rental);
}

static BOOL YTKACEHLSDeviceDecodesVP9(void) {
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = VTIsHardwareDecodeSupported('vp09');
        YTKACEDownloadLog(@"hls", @"device vp9=%d", supported);
    });
    return supported;
}

static NSString *YTKACEHLSFilterManifest(NSString *text) {
    if (![text containsString:@"vp09"] || YTKACEHLSDeviceDecodesVP9()) return text;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger dropped = 0, total = 0;
    BOOL skipNext = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (skipNext) {
            skipNext = NO;
            if (![line hasPrefix:@"#"]) continue;
        }
        if ([line hasPrefix:@"#EXT-X-STREAM-INF"]) {
            total++;
            if ([line containsString:@"vp09"]) {
                dropped++;
                skipNext = YES;
                continue;
            }
        }
        [kept addObject:line];
    }
    if (dropped == 0 || dropped == total) return text;
    return [kept componentsJoinedByString:@"\n"];
}

static id YTKACEHLSParseString(id self, SEL _cmd, NSString *string, NSError **error) {
    if (YTKACEHLSEnabled() && [string isKindOfClass:NSString.class]) string = YTKACEHLSFilterManifest(string);
    return ((id (*)(id, SEL, id, NSError **))YTKACEHLSOrigParseString)(self, _cmd, string, error);
}

static BOOL YTKACEHLSSameConstraint(id current, id incoming) {
    if (current == incoming) return YES;
    if (current == nil || incoming == nil) return NO;
    if ([current isEqual:incoming]) return YES;
    if ([current class] != [incoming class]) return NO;
    for (NSString *key in @[@"videoQualitySetting", @"stickyResolutionCap", @"disableTrack"]) {
        if (YTKACEHLSInteger(current, key) != YTKACEHLSInteger(incoming, key)) return NO;
    }
    id currentLabel = YTKACEHLSGet(current, @"qualityLabel");
    id incomingLabel = YTKACEHLSGet(incoming, @"qualityLabel");
    return currentLabel == incomingLabel || [currentLabel isEqual:incomingLabel];
}

static void YTKACEHLSSetConstraint(id self, SEL _cmd, id constraint) {
    if (YTKACEHLSSameConstraint(YTKACEHLSGet(self, @"videoFormatConstraint"), constraint)) return;
    ((void (*)(id, SEL, id))YTKACEHLSOrigSetConstraint)(self, _cmd, constraint);
}

static void YTKACEHLSScrubStart(id self, SEL _cmd, BOOL bar) {
    YTKACEHLSScrubPaused = NO;
    YTKACEHLSScrubGeneration++;
    YTKACEHLSInScrubStart = YES;
    ((void (*)(id, SEL, BOOL))YTKACEHLSOrigScrubStart)(self, _cmd, bar);
    YTKACEHLSInScrubStart = NO;
}

static void YTKACEHLSScrubEnd(id self, SEL _cmd, BOOL bar, BOOL cancelled, int source) {
    ((void (*)(id, SEL, BOOL, BOOL, int))YTKACEHLSOrigScrubEnd)(self, _cmd, bar, cancelled, source);
    if (!YTKACEHLSScrubPaused) return;
    const NSUInteger generation = YTKACEHLSScrubGeneration;
    __weak id weakOverlay = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id overlay = weakOverlay;
        if (overlay == nil || !YTKACEHLSScrubPaused || generation != YTKACEHLSScrubGeneration) return;
        YTKACEHLSScrubPaused = NO;
        SEL play = NSSelectorFromString(@"didPressPlay:");
        if ([overlay respondsToSelector:play]) ((void (*)(id, SEL, id))objc_msgSend)(overlay, play, nil);
    });
}

static void YTKACEHLSPlay(id self, SEL _cmd) {
    YTKACEHLSScrubPaused = NO;
    ((void (*)(id, SEL))YTKACEHLSOrigPlay)(self, _cmd);
}

static void YTKACEHLSPause(id self, SEL _cmd, int reason) {
    if (YTKACEHLSInScrubStart) YTKACEHLSScrubPaused = YES;
    ((void (*)(id, SEL, int))YTKACEHLSOrigPause)(self, _cmd, reason);
}

void YTKACEInstallHLSPlaybackHooks(void) {
    if (!YTKACEHLSEnabled()) return;
    YTKACEDownloadLog(@"hls", @"enabled");
    YTKACEHLSCache = [NSMutableDictionary dictionary];
    YTKACEHLSPending = [NSMutableSet set];
    YTKACEHLSOriginals = [NSMutableDictionary dictionary];
    YTKACEHLSSources = [NSMutableDictionary dictionary];
    YTKACEHLSFallbacks = [NSMutableSet set];
    NSString *response = @"YTPlayerResponse";
    YTKACEInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:QOEController:cacheKey:cacheContext:latencyLogger:offlineRentalActivated:",
        (IMP)YTKACEHLSInitFull, &YTKACEHLSOrigInitFull);
    YTKACEInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:",
        (IMP)YTKACEHLSInitShort, &YTKACEHLSOrigInitShort);
    YTKACEInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:offlineRentalActivated:",
        (IMP)YTKACEHLSInitRental, &YTKACEHLSOrigInitRental);
    YTKACEInstallInstanceHook(@"MLHLSMasterPlaylistParser", @"parseFromString:error:",
        (IMP)YTKACEHLSParseString, &YTKACEHLSOrigParseString);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"setVideoFormatConstraint:",
        (IMP)YTKACEHLSSetConstraint, &YTKACEHLSOrigSetConstraint);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"play", (IMP)YTKACEHLSPlay, &YTKACEHLSOrigPlay);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"pauseWithStoppageReason:",
        (IMP)YTKACEHLSPause, &YTKACEHLSOrigPause);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didStartPlayerBarScrubbingWithGestureOriginatingInPlayerBar:",
        (IMP)YTKACEHLSScrubStart, &YTKACEHLSOrigScrubStart);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didEndPlayerBarScrubbingWithGestureOriginatingInPlayerBar:withSeekCancelled:seekSource:",
        (IMP)YTKACEHLSScrubEnd, &YTKACEHLSOrigScrubEnd);
}
