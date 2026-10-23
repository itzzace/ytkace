#import "DownloadCoordinator.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"
#import "StreamResolver.h"
#import "../Translation/YTKACEVOTHooks.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../UI/Assets.h"
#import <objc/message.h>
#import <objc/runtime.h>

UIImage *YTKACEDownloadGlyphImage(void) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *image = [YTKACEDownloadTabImage(NO)
        imageByApplyingSymbolConfiguration:configuration];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static IMP OriginalSetPlayerResponse;
static IMP OriginalSetPoToken;
static IMP OriginalMintWithVideoID;
static IMP OriginalMakePlayerRequest;
static IMP OriginalMakePlaybackRequest;
static IMP OriginalMakePrefetchPlayerRequest;
static IMP OriginalFactoryRequest;
static IMP OriginalFactoryRequestExtended;
static IMP OriginalOnesieRequest;
static IMP OriginalOnesieRequestAsync;
static IMP OriginalOnesieRequestCompletion;
static IMP OriginalHAMBuildURLRequest;
static id YTKACELastPlayerService;
static id YTKACELastPlayerRequest;
static id YTKACELastPlaybackRequest;
static id YTKACELastPlayerFactory;
static id YTKACELastRequestProperties;
static NSMutableDictionary<NSString *, NSArray *> *YTKACEPlayerRequests;
static NSMutableDictionary<NSString *, id> *YTKACEPlaybackRequests;
static NSInteger YTKACEPlayerHookAttempts;
static NSString *YTKACELastCapturedVideoID;
id YTKACELatestPlayerAuthorization;

NSString *YTKACELastVideoID(void) {
    return [YTKACELastCapturedVideoID copy];
}
static NSString *YTKACERequestVideoID(id request);
static void YTKACEPersistPlayerRequest(id request);
static BOOL YTKACEUsingRestoredRequest;
static id YTKACECopyObject(id object);

static NSURLRequest *YTKACEURLRequestFromObject(id object) {
    if ([object isKindOfClass:NSURLRequest.class]) return object;
    SEL builder = NSSelectorFromString(@"buildURLRequest");
    if ([object respondsToSelector:builder]) {
        id result = ((id (*)(id, SEL))objc_msgSend)(object, builder);
        if ([result isKindOfClass:NSURLRequest.class]) return result;
    }
    return nil;
}

@interface YTKACEOnesieSessionState : NSObject
@property(nonatomic, strong) id factory;
@property(nonatomic, strong) id playerRequest;
@property(nonatomic, strong, nullable) id authorization;
@property(nonatomic, strong) id dataLoader;
@property(nonatomic, strong) id context;
@property(nonatomic, strong) id cryptor;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, assign) NSInteger observedRequestNumber;
@property(nonatomic, assign) NSInteger nextRequestNumber;
@property(nonatomic, assign) BOOL asynchronous;
@property(nonatomic, strong) NSDate *capturedAt;
@end

@implementation YTKACEOnesieSessionState
@end

static NSMutableDictionary<NSString *, YTKACEOnesieSessionState *> *
    YTKACEOnesieSessions;
static YTKACEOnesieSessionState *YTKACELastOnesieSession;

static void YTKACEPruneOnesieSessions(void) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-900.0];
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    for (NSString *key in YTKACEOnesieSessions) {
        YTKACEOnesieSessionState *state = YTKACEOnesieSessions[key];
        if ([state.capturedAt compare:cutoff] == NSOrderedAscending) {
            [expired addObject:key];
        }
    }
    [YTKACEOnesieSessions removeObjectsForKeys:expired];
    if (YTKACEOnesieSessions.count <= 16) return;
    NSArray<NSString *> *keys = [YTKACEOnesieSessions keysSortedByValueUsingComparator:
        ^NSComparisonResult(YTKACEOnesieSessionState *left,
                            YTKACEOnesieSessionState *right) {
            return [left.capturedAt compare:right.capturedAt];
        }];
    NSUInteger removeCount = YTKACEOnesieSessions.count - 16;
    [YTKACEOnesieSessions removeObjectsForKeys:
        [keys subarrayWithRange:NSMakeRange(0, removeCount)]];
}

static void YTKACECaptureOnesieSession(id factory,
                                       id playerRequest,
                                       id authorization,
                                       id dataLoader,
                                       id context,
                                       id cryptor,
                                       NSInteger requestNumber,
                                       BOOL asynchronous) {
    if (factory == nil || playerRequest == nil || dataLoader == nil ||
        context == nil || cryptor == nil) {
        return;
    }
    NSString *videoID = YTKACERequestVideoID(playerRequest);
    if (videoID.length == 0) videoID = YTKACELastCapturedVideoID;
    YTKACEOnesieSessionState *state = [YTKACEOnesieSessionState new];
    state.factory = factory;
    state.playerRequest = YTKACECopyObject(playerRequest);
    state.authorization = YTKACECopyObject(authorization);
    if (authorization != nil) YTKACELatestPlayerAuthorization = authorization;
    state.dataLoader = dataLoader;
    state.context = context;
    state.cryptor = cryptor;
    state.videoID = videoID ?: @"";
    state.observedRequestNumber = requestNumber;
    state.nextRequestNumber = requestNumber + 1;
    state.asynchronous = asynchronous;
    state.capturedAt = NSDate.date;
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACEOnesieSessions == nil) {
            YTKACEOnesieSessions = [NSMutableDictionary dictionary];
        }
        YTKACELastOnesieSession = state;
        if (videoID.length != 0) YTKACEOnesieSessions[videoID] = state;
        YTKACEPruneOnesieSessions();
    }
}

static YTKACEOnesieSessionState *YTKACEOnesieSessionForVideo(
    NSString *videoID) {
    @synchronized (YTKACESABRDownloader.class) {
        YTKACEPruneOnesieSessions();
        YTKACEOnesieSessionState *state = YTKACEOnesieSessions[videoID];
        if (state != nil) return state;
        if (YTKACELastOnesieSession.videoID.length == 0 ||
            [YTKACELastOnesieSession.videoID isEqualToString:videoID]) {
            return YTKACELastOnesieSession;
        }
        return nil;
    }
}

BOOL YTKACEHasNativeOnesieSession(NSString *videoID) {
    return YTKACEOnesieSessionForVideo(videoID) != nil;
}

void YTKACEBuildNativeOnesieRequest(
    NSString *videoID,
    YTKACENativeRequestCompletion completion) {
    YTKACEOnesieSessionState *state = YTKACEOnesieSessionForVideo(videoID);
    if (state == nil) {
        completion(nil, NSNotFound, [NSError errorWithDomain:@"YTKACEOnesie"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"No native Onesie session is available."}]);
        return;
    }
    NSInteger requestNumber = 0;
    @synchronized (YTKACESABRDownloader.class) {
        requestNumber = MAX(state.nextRequestNumber,
            state.observedRequestNumber + 1);
        state.nextRequestNumber = requestNumber + 1;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state.asynchronous && OriginalOnesieRequestAsync != NULL) {
            void (^nativeCompletion)(id, NSError *) = ^(id result, NSError *error) {
                NSURLRequest *request = YTKACEURLRequestFromObject(result);
                if (request != nil) YTKACESABRSetNativeRequest(request);
                completion(request, requestNumber, error);
            };
            ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))
                OriginalOnesieRequestAsync)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:authorization:dataLoader:"
                         "context:cryptor:requestNumber:completionHandler:"),
                    YTKACECopyObject(state.playerRequest), state.authorization,
                    state.dataLoader, state.context, state.cryptor,
                    requestNumber, nativeCompletion);
            return;
        }
        if (OriginalOnesieRequest != NULL) {
            NSError *error = nil;
            id result = ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))
                OriginalOnesieRequest)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:dataLoader:context:"
                         "cryptor:requestNumber:error:"),
                    YTKACECopyObject(state.playerRequest), state.dataLoader,
                    state.context, state.cryptor, requestNumber, &error);
            NSURLRequest *request = YTKACEURLRequestFromObject(result);
            if (request != nil) YTKACESABRSetNativeRequest(request);
            completion(request, requestNumber, error);
            return;
        }
        completion(nil, requestNumber, [NSError errorWithDomain:@"YTKACEOnesie"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's native Onesie factory is unavailable."}]);
    });
}

static id YTKACEOnesieRequest(id receiver,
                              SEL selector,
                              id playerRequest,
                              id dataLoader,
                              id context,
                              id cryptor,
                              NSInteger requestNumber,
                              NSError **error) {
    if (YTKACEPlaybackFixMode() == 2) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"YTKACEHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}];
        }
        return nil;
    }
    id result = OriginalOnesieRequest != NULL
        ? ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))OriginalOnesieRequest)(
            receiver, selector, playerRequest, dataLoader, context, cryptor,
            requestNumber, error)
        : nil;
    NSURLRequest *builtRequest = YTKACEURLRequestFromObject(result);
    if (builtRequest != nil) {
        NSURLRequest *request = builtRequest;
        YTKACESABRSetNativeRequest(request);
    }
    YTKACECaptureOnesieSession(receiver, playerRequest, nil, dataLoader,
        context, cryptor, requestNumber, NO);
    return result;
}

static void YTKACEOnesieRequestAsync(id receiver,
                                     SEL selector,
                                     id playerRequest,
                                     id authorization,
                                     id dataLoader,
                                     id context,
                                     id cryptor,
                                     NSInteger requestNumber,
                                     void (^completion)(id, NSError *)) {
    if (YTKACEPlaybackFixMode() == 2) {
        if (completion != nil) {
            completion(nil, [NSError errorWithDomain:@"YTKACEHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}]);
        }
        return;
    }
    void (^wrapped)(id, NSError *) = ^(id result, NSError *error) {
        NSURLRequest *builtRequest = YTKACEURLRequestFromObject(result);
        if (builtRequest != nil) {
            NSURLRequest *request = builtRequest;
            YTKACESABRSetNativeRequest(request);
        }
        YTKACECaptureOnesieSession(receiver, playerRequest, authorization,
            dataLoader, context, cryptor, requestNumber, YES);
        if (completion != nil) completion(result, error);
    };
    if (OriginalOnesieRequestAsync != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))OriginalOnesieRequestAsync)(
            receiver, selector, playerRequest, authorization, dataLoader, context,
            cryptor, requestNumber, wrapped);
    }
}

static void YTKACEOnesieRequestCompletion(id receiver,
                                          SEL selector,
                                          id request,
                                          id error) {
    NSURLRequest *builtRequest = YTKACEURLRequestFromObject(request);
    if (builtRequest != nil) {
        NSURLRequest *URLRequest = builtRequest;
        YTKACESABRSetNativeRequest(URLRequest);
    }
    if (OriginalOnesieRequestCompletion != NULL) {
        ((void (*)(id, SEL, id, id))OriginalOnesieRequestCompletion)(
            receiver, selector, request, error);
    }
}

static id YTKACEHAMBuildURLRequest(id receiver, SEL selector) {
    id result = OriginalHAMBuildURLRequest != NULL
        ? ((id (*)(id, SEL))OriginalHAMBuildURLRequest)(receiver, selector)
        : nil;
    if ([result isKindOfClass:NSURLRequest.class]) {
        NSURLRequest *request = result;
        NSString *host = request.URL.host.lowercaseString;
        if ([host containsString:@"googlevideo.com"] &&
            [request.HTTPMethod.uppercaseString isEqualToString:@"POST"]) {
            NSData *rawBody = nil;
            SEL bodySelector = NSSelectorFromString(@"HTTPBody");
            if ([receiver respondsToSelector:bodySelector]) {
                rawBody = ((id (*)(id, SEL))objc_msgSend)(receiver, bodySelector);
            }
            NSMutableURLRequest *nativeRequest = [request mutableCopy];
            if ([rawBody isKindOfClass:NSData.class] && rawBody.length != 0) {
                nativeRequest.HTTPBody = rawBody;
                [nativeRequest setValue:nil forHTTPHeaderField:@"Content-Encoding"];
            }
            YTKACESABRSetNativeRequest(nativeRequest);
        }
    }
    return result;
}

static id YTKACEGetValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        }
        @try {
            id value = [object valueForKey:key];
            if (value != nil) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static BOOL YTKACESetValue(id object, NSString *key, id value) {
    if (object == nil || key.length == 0) return NO;
    NSString *first = [[key substringToIndex:1] uppercaseString];
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:", first,
        [key substringFromIndex:1]];
    SEL setter = NSSelectorFromString(setterName);
    if ([object respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, setter, value);
        return YES;
    }
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id YTKACECopyObject(id object) {
    if ([object respondsToSelector:@selector(copyWithZone:)]) {
        return [object copy];
    }
    return object;
}

static NSString *YTKACERequestVideoID(id request) {
    id value = YTKACEGetValue(request, @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void YTKACECaptureService(id receiver, id request) {
    NSString *videoID = YTKACERequestVideoID(request);
    if (videoID.length != 0) YTKACELastCapturedVideoID = videoID;
    YTKACESABRSetCurrentVideoID(videoID);
    id requestCopy = YTKACECopyObject(request);
    @synchronized (YTKACESABRDownloader.class) {
        YTKACELastPlayerService = receiver;
        YTKACELastPlayerRequest = requestCopy;
        YTKACEUsingRestoredRequest = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTKACEPersistPlayerRequest(requestCopy ?: request);
        });
        if (YTKACEPlayerRequests == nil) YTKACEPlayerRequests = [NSMutableDictionary dictionary];
        if (videoID.length != 0) {
            YTKACEPlayerRequests[videoID] = @[receiver, requestCopy ?: request];
        }
    }
}

static NSMutableDictionary<NSString *, id> *YTKACEPlayerResponses;
static NSMutableArray<NSString *> *YTKACEPlayerResponseOrder;

static NSString *YTKACEResponseVideoID(id response) {
    if (response == nil) return nil;
    id details = YTKACEGetValue(response, @[@"videoDetails"]);
    id value = YTKACEGetValue(details != nil ? details : response,
                              @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

__attribute__((unused))
static void YTKACEReportStreamingData(id response) {
    static NSUInteger logged = 0;
    if (response == nil || logged >= 2) return;
    SEL selector = NSSelectorFromString(@"streamingData");
    if (![response respondsToSelector:selector]) {
        YTKACEDownloadLog(@"spoof", @"player response has no streamingData (%@)",
                          NSStringFromClass([response class]));
        logged++;
        return;
    }
    id streaming = ((id (*)(id, SEL))objc_msgSend)(response, selector);
    if (streaming == nil) {
        YTKACEDownloadLog(@"spoof", @"player response streamingData nil");
        logged++;
        return;
    }
    logged++;
    NSString *text = [[streaming description]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    const NSUInteger limit = 1500;
    for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
         offset += limit) {
        const NSUInteger length = MIN(limit, text.length - offset);
        YTKACEDownloadLog(@"spoof", @"streaming[%lu] %@",
                          (unsigned long)(offset / limit),
                          [text substringWithRange:NSMakeRange(offset, length)]);
    }
}

static void YTKACECachePlayerResponse(id response) {
    if (response == nil) return;
    NSString *videoID =
        [YTKACEStreamResolver videoIDFromPlayerResponse:response];
    if (videoID.length == 0) videoID = YTKACEResponseVideoID(response);
    if (videoID.length == 0) return;
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACEPlayerResponses == nil) {
            YTKACEPlayerResponses = [NSMutableDictionary dictionary];
            YTKACEPlayerResponseOrder = [NSMutableArray array];
        }
        if (YTKACEPlayerResponses[videoID] == nil) {
            [YTKACEPlayerResponseOrder addObject:videoID];
        }
        YTKACEPlayerResponses[videoID] = response;
        while (YTKACEPlayerResponseOrder.count > 8) {
            NSString *oldest = YTKACEPlayerResponseOrder.firstObject;
            [YTKACEPlayerResponseOrder removeObjectAtIndex:0];
            [YTKACEPlayerResponses removeObjectForKey:oldest];
        }
    }
}

void YTKACEStorePlayerResponse(NSString *videoID, id response) {
    if (videoID.length == 0 || response == nil) return;
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACEPlayerResponses == nil) {
            YTKACEPlayerResponses = [NSMutableDictionary dictionary];
            YTKACEPlayerResponseOrder = [NSMutableArray array];
        }
        if (YTKACEPlayerResponses[videoID] == nil) {
            [YTKACEPlayerResponseOrder addObject:videoID];
        }
        YTKACEPlayerResponses[videoID] = response;
        while (YTKACEPlayerResponseOrder.count > 8) {
            NSString *oldest = YTKACEPlayerResponseOrder.firstObject;
            [YTKACEPlayerResponseOrder removeObjectAtIndex:0];
            [YTKACEPlayerResponses removeObjectForKey:oldest];
        }
    }
}

id YTKACECachedPlayerResponse(NSString *videoID) {
    if (videoID.length == 0) return nil;
    id original = YTKACEHLSOriginalResponse(videoID);
    if (original != nil) return original;
    @synchronized (YTKACESABRDownloader.class) {
        return YTKACEPlayerResponses[videoID];
    }
}

static id YTKACEObservedResponseBlock(id responseBlock) {
    if (responseBlock == nil) return nil;
    void (^original)(id, void *) = responseBlock;
    return [^(id playerResponse, void *cacheContext) {
        YTKACECachePlayerResponse(playerResponse);
        original(playerResponse, cacheContext);
    } copy];
}

static void YTKACEMakePlayerRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    YTKACECaptureService(receiver, request);
    if (OriginalMakePlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            receiver, selector, request,
            YTKACEObservedResponseBlock(responseBlock), errorBlock
        );
    }
}

static id YTKACEMakePlaybackRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    YTKACECaptureService(receiver, request);
    @synchronized (YTKACESABRDownloader.class) {
        YTKACELastPlaybackRequest = YTKACECopyObject(request);
        NSString *videoID = YTKACERequestVideoID(request);
        if (YTKACEPlaybackRequests == nil) {
            YTKACEPlaybackRequests = [NSMutableDictionary dictionary];
        }
        if (videoID.length != 0) {
            YTKACEPlaybackRequests[videoID] = YTKACECopyObject(request);
        }
    }
    return OriginalMakePlaybackRequest != NULL
        ? ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
            receiver, selector, request,
            YTKACEObservedResponseBlock(responseBlock), errorBlock)
        : nil;
}

static void YTKACEMakePrefetchPlayerRequest(id receiver,
                                            SEL selector,
                                            id request,
                                            id responseBlock,
                                            id errorBlock) {
    YTKACECaptureService(receiver, request);
    if (OriginalMakePrefetchPlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePrefetchPlayerRequest)(
            receiver, selector, request, responseBlock, errorBlock
        );
    }
}

static void YTKACECaptureFactory(id receiver, id request, id properties, id result) {
    NSString *videoID = YTKACERequestVideoID(request);
    if (videoID.length != 0) YTKACELastCapturedVideoID = videoID;
    YTKACESABRSetCurrentVideoID(videoID);
    @synchronized (YTKACESABRDownloader.class) {
        YTKACELastPlayerFactory = receiver;
        YTKACELastPlayerRequest = YTKACECopyObject(request);
        YTKACEUsingRestoredRequest = NO;
        id persistCopy = YTKACELastPlayerRequest;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTKACEPersistPlayerRequest(persistCopy);
        });
        YTKACELastRequestProperties = properties;
        if (videoID.length != 0 && YTKACELastPlayerService != nil) {
            if (YTKACEPlayerRequests == nil) {
                YTKACEPlayerRequests = [NSMutableDictionary dictionary];
            }
            YTKACEPlayerRequests[videoID] = @[
                YTKACELastPlayerService, YTKACECopyObject(request)
            ];
            if (YTKACELastPlaybackRequest != nil) {
                if (YTKACEPlaybackRequests == nil) {
                    YTKACEPlaybackRequests = [NSMutableDictionary dictionary];
                }
                YTKACEPlaybackRequests[videoID] =
                    YTKACECopyObject(YTKACELastPlaybackRequest);
            }
        }
    }
    static BOOL dumped = YES;
    if (!dumped) {
        dumped = YES;
        for (NSArray *pair in @[@[@"request", request ?: [NSNull null]],
                                @[@"result", result ?: [NSNull null]]]) {
            id value = pair[1];
            if (value == [NSNull null]) continue;
            NSString *text = [[value description]
                stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            while ([text containsString:@"  "]) {
                text = [text stringByReplacingOccurrencesOfString:@"  "
                                                       withString:@" "];
            }
            const NSUInteger limit = 1800;
            for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
                 offset += limit) {
                const NSUInteger length = MIN(limit, text.length - offset);
                YTKACEDownloadLog(@"spoof", @"%@[%lu] %@", pair[0],
                                  (unsigned long)(offset / limit),
                                  [text substringWithRange:NSMakeRange(offset, length)]);
            }
        }
    }
}

static id YTKACEFactoryRequest(id receiver, SEL selector, id request, id properties) {
    YTKACESABRSetCurrentVideoID(YTKACERequestVideoID(request));
    id result = OriginalFactoryRequest != NULL
        ? ((id (*)(id, SEL, id, id))OriginalFactoryRequest)(receiver, selector, request, properties)
        : nil;
    YTKACECaptureFactory(receiver, request, properties, result);
    return result;
}

static id YTKACEFactoryRequestExtended(id receiver,
                                       SEL selector,
                                       id request,
                                       id properties,
                                       BOOL relaxation,
                                       id cacheToken,
                                       BOOL skipCache) {
    YTKACESABRSetCurrentVideoID(YTKACERequestVideoID(request));
    id result = OriginalFactoryRequestExtended != NULL
        ? ((id (*)(id, SEL, id, id, BOOL, id, BOOL))OriginalFactoryRequestExtended)(
            receiver, selector, request, properties, relaxation, cacheToken, skipCache)
        : nil;
    YTKACECaptureFactory(receiver, request, properties, result);
    return result;
}

static id YTKACELastInnerTubeContext;
static IMP OriginalContextShort;
static IMP OriginalContextMedium;
static IMP OriginalContextLong;

static void YTKACECaptureContext(id context) {
    if (context == nil) return;
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACELastInnerTubeContext == nil) {
        }
        YTKACELastInnerTubeContext = context;
    }
}

static id YTKACEContextShort(id receiver, SEL selector, id pageID,
                             BOOL incognito, int criticality, id tracking,
                             BOOL sendIdentifier, long long serviceType) {
    id result = OriginalContextShort == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, long long))OriginalContextShort)(
            receiver, selector, pageID, incognito, criticality, tracking,
            sendIdentifier, serviceType);
    YTKACECaptureContext(result);
    return result;
}

static id YTKACEContextMedium(id receiver, SEL selector, id pageID,
                              BOOL incognito, int criticality, id tracking,
                              BOOL sendIdentifier, id nonce, id jars,
                              id attestation, long long serviceType) {
    id result = OriginalContextMedium == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, long long))
            OriginalContextMedium)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars,
                attestation, serviceType);
    YTKACECaptureContext(result);
    return result;
}

static id YTKACEContextLong(id receiver, SEL selector, id pageID,
                            BOOL incognito, int criticality, id tracking,
                            BOOL sendIdentifier, id nonce, id jars,
                            id attestation, id reauth, long long serviceType,
                            BOOL isPrefetch) {
    id result = OriginalContextLong == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, id, long long, BOOL))
            OriginalContextLong)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars, attestation,
                reauth, serviceType, isPrefetch);
    YTKACECaptureContext(result);
    return result;
}

static IMP OriginalPlayerServiceInit;

static id YTKACEPlayerServiceInit(id receiver, SEL selector) {
    id result = OriginalPlayerServiceInit == NULL ? receiver :
        ((id (*)(id, SEL))OriginalPlayerServiceInit)(receiver, selector);
    if (result != nil) {
        @synchronized (YTKACESABRDownloader.class) {
            if (YTKACELastPlayerService == nil) {
                YTKACELastPlayerService = result;
            }
        }
    }
    return result;
}

static void YTKACEInstallPlayerServiceHook(void) {
    YTKACEInstallInstanceHook(@"YTPlayerService", @"init",
                              (IMP)YTKACEPlayerServiceInit,
                              &OriginalPlayerServiceInit);
    YTKACEInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:serviceType:",
        (IMP)YTKACEContextShort, &OriginalContextShort);
    YTKACEInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:serviceType:",
        (IMP)YTKACEContextMedium, &OriginalContextMedium);
    YTKACEInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:reauthProofToken:serviceType:isPrefetch:",
        (IMP)YTKACEContextLong, &OriginalContextLong);
    BOOL serviceInstalled = YTKACEInstallInstanceHook(
        @"YTPlayerService",
        @"makePlayerRequest:responseBlock:errorBlock:",
        (IMP)YTKACEMakePlayerRequest,
        &OriginalMakePlayerRequest
    );
    BOOL playbackInstalled = YTKACEInstallInstanceHook(
        @"YTPlayerService",
        @"makePlaybackRequest:responseBlock:errorBlock:",
        (IMP)YTKACEMakePlaybackRequest,
        &OriginalMakePlaybackRequest
    );
    BOOL prefetchInstalled = YTKACEInstallInstanceHook(
        @"YTPlayerService",
        @"makePrefetchPlayerRequest:responseBlock:errorBlock:",
        (IMP)YTKACEMakePrefetchPlayerRequest,
        &OriginalMakePrefetchPlayerRequest
    );
    BOOL factoryInstalled = YTKACEInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:",
        (IMP)YTKACEFactoryRequest,
        &OriginalFactoryRequest
    );
    BOOL extendedInstalled = YTKACEInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:skipInnertubeCacheLookup:",
        (IMP)YTKACEFactoryRequestExtended,
        &OriginalFactoryRequestExtended
    );
    BOOL onesieInstalled = YTKACEInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
        (IMP)YTKACEOnesieRequest,
        &OriginalOnesieRequest
    );
    BOOL onesieAsyncInstalled = YTKACEInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:authorization:dataLoader:context:cryptor:requestNumber:completionHandler:",
        (IMP)YTKACEOnesieRequestAsync,
        &OriginalOnesieRequestAsync
    );
    BOOL onesieCompletionInstalled = YTKACEInstallInstanceHook(
        @"MLOnesieUMPFetcherTask",
        @"onRequestFactoryCompletionWithRequest:error:",
        (IMP)YTKACEOnesieRequestCompletion,
        &OriginalOnesieRequestCompletion
    );
    BOOL HAMRequestInstalled = YTKACEInstallInstanceHook(
        @"HAMDataLoadRequest",
        @"buildURLRequest",
        (IMP)YTKACEHAMBuildURLRequest,
        &OriginalHAMBuildURLRequest
    );
    if (serviceInstalled && playbackInstalled && prefetchInstalled &&
        factoryInstalled && extendedInstalled && onesieInstalled &&
        onesieAsyncInstalled && onesieCompletionInstalled && HAMRequestInstalled) {
        YTKACEDownloadLog(@"reload", @"player path hooked");
        return;
    }
    YTKACEPlayerHookAttempts += 1;
    if (YTKACEPlayerHookAttempts >= 30) {
        YTKACEDownloadLog(@"reload", @"player path unavailable service=%d playback=%d prefetch=%d factory=%d extended=%d onesie=%d async=%d completion=%d ham=%d",
            serviceInstalled, playbackInstalled, prefetchInstalled,
            factoryInstalled, extendedInstalled, onesieInstalled,
            onesieAsyncInstalled, onesieCompletionInstalled, HAMRequestInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ YTKACEInstallPlayerServiceHook(); });
}

void YTKACEPreparePlayerWithRoute(NSString *videoID,
                                  BOOL forcePlayerRoute,
                                  YTKACEPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (YTKACESABRDownloader.class) {
        NSArray *pair = YTKACEPlayerRequests[videoID];
        service = pair.count > 0 ? pair[0] : nil;
        request = pair.count > 1 ? pair[1] : nil;
        playbackRequest = YTKACEPlaybackRequests[videoID];
        if (service == nil &&
            [YTKACERequestVideoID(YTKACELastPlayerRequest) isEqualToString:videoID]) {
            service = YTKACELastPlayerService;
            request = YTKACELastPlayerRequest;
            playbackRequest = YTKACELastPlaybackRequest;
        }
    }
    if (service == nil || request == nil) {
        NSError *error = [NSError errorWithDomain:@"YTKACEPlayerPrepare" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube has not created a player request for this video."}];
        completion(nil, error);
        return;
    }
    if (forcePlayerRoute) playbackRequest = nil;
    YTKACESABRSetCurrentVideoID(videoID);
    YTKACEDownloadLog(@"prepare", @"native request video=%@ route=%@", videoID,
        playbackRequest != nil && OriginalMakePlaybackRequest != NULL
            ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            completion(YTKACEHLSOriginalResponse(videoID) ?: playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            completion(nil, error);
        };
        if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service,
                NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                YTKACECopyObject(playbackRequest), response, failure);
        } else if (OriginalMakePlayerRequest != NULL) {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service,
                NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                YTKACECopyObject(request), response, failure);
        } else {
            NSError *error = [NSError errorWithDomain:@"YTKACEPlayerPrepare" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"YouTube's player service is unavailable."}];
            completion(nil, error);
        }
    });
}

void YTKACEPreparePlayer(NSString *videoID,
                         YTKACEPlayerReloadCompletion completion) {
    YTKACEPreparePlayerWithRoute(videoID, NO, completion);
}

static NSURL *YTKACERequestSeedURL(void) {
    return [YTKACEApplicationSupportDirectory()
        URLByAppendingPathComponent:@"player-request.pb"];
}

static void YTKACEPersistPlayerRequest(id request) {
    static NSTimeInterval lastWrite;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - lastWrite < 60.0) return;
    if (![request respondsToSelector:NSSelectorFromString(@"data")]) {
        return;
    }
    NSData *encoded = ((id (*)(id, SEL))objc_msgSend)(
        request, NSSelectorFromString(@"data"));
    if (![encoded isKindOfClass:NSData.class] || encoded.length == 0) return;
    lastWrite = now;
    [encoded writeToURL:YTKACERequestSeedURL() atomically:YES];
}

NSString *YTKACEPlayerOnBehalfOfUser(void) {
    id request = nil;
    @synchronized (YTKACESABRDownloader.class) {
        request = YTKACELastPlayerRequest;
    }
    if (request == nil) return nil;
    @try {
        id value = [request valueForKeyPath:@"context.user.onBehalfOfUser"];
        return [value isKindOfClass:NSString.class] && [value length] != 0 ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

void YTKACEDiscardRestoredRequest(void) {
    BOOL restored = NO;
    @synchronized (YTKACESABRDownloader.class) {
        restored = YTKACEUsingRestoredRequest;
        if (restored) {
            YTKACELastPlayerRequest = nil;
            YTKACEUsingRestoredRequest = NO;
        }
    }
    if (!restored) return;
    [NSFileManager.defaultManager removeItemAtURL:YTKACERequestSeedURL()
                                            error:NULL];
    YTKACEDownloadLog(@"resolve", @"discarded stale player request seed");
}

void YTKACERestorePlayerRequest(void) {
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACELastPlayerRequest != nil) return;
    }
    NSData *encoded = [NSData dataWithContentsOfURL:YTKACERequestSeedURL()];
    if (encoded.length == 0) return;
    Class requestClass = NSClassFromString(@"YTIPlayerRequest");
    SEL parse = NSSelectorFromString(@"parseFromData:error:");
    if (requestClass == Nil || ![requestClass respondsToSelector:parse]) return;
    NSError *error = nil;
    id restored = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        requestClass, parse, encoded, &error);
    if (restored == nil) {
        YTKACEDownloadLog(@"resolve", @"request seed parse failed error=%@",
            error.localizedDescription ?: @"unknown");
        return;
    }
    @synchronized (YTKACESABRDownloader.class) {
        YTKACELastPlayerRequest = restored;
        YTKACEUsingRestoredRequest = YES;
    }
    YTKACEDownloadLog(@"resolve", @"restored player request bytes=%lu",
        (unsigned long)encoded.length);
}

static IMP OriginalOfflineVideoExecute;
static IMP OriginalOfflineVideoExecuteCompletion;

static __weak UIView *YTKACEMenuSourceView;

static void YTKACECaptureMenuSource(id view) {
    if ([view isKindOfClass:UIView.class]) {
        YTKACEMenuSourceView = view;
    }
}

static IMP OriginalShowMenuCompletion;
static IMP OriginalShowMenuSkipCompletion;
static IMP OriginalActionsForRenderersLog;

static void YTKACEShowMenuCompletion(id receiver, SEL selector, id renderer,
                                     id view, id entry, id block, BOOL cancel,
                                     BOOL log, id responder, id completion) {
    YTKACECaptureMenuSource(view);
    if (OriginalShowMenuCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, id, id))
        OriginalShowMenuCompletion)(receiver, selector, renderer, view, entry,
                                    block, cancel, log, responder, completion);
}

static void YTKACEShowMenuSkipCompletion(id receiver, SEL selector, id renderer,
                                         id view, id entry, id block,
                                         BOOL cancel, BOOL log, BOOL skip,
                                         id responder, id completion) {
    YTKACECaptureMenuSource(view);
    if (OriginalShowMenuSkipCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, BOOL, id, id))
        OriginalShowMenuSkipCompletion)(receiver, selector, renderer, view,
                                        entry, block, cancel, log, skip,
                                        responder, completion);
}

static id YTKACEActionsForRenderersLog(id receiver, SEL selector, id renderers,
                                       id view, id entry, BOOL log,
                                       id responder) {
    YTKACEQueuePrepareMenuRenderers(renderers);
    YTKACECaptureMenuSource(view);
    if (OriginalActionsForRenderersLog == NULL) return nil;
    id actions = ((id (*)(id, SEL, id, id, id, BOOL, id))OriginalActionsForRenderersLog)(
        receiver, selector, renderers, view, entry, log, responder);
    YTKACERouteSpeedMenuItem(renderers, actions, view, responder);
    YTKACERouteVOTMenuItem(actions);
    return actions;
}

static UIView *YTKACEOverflowButtonInside(UIView *root) {
    if (root == nil || root.window == nil) return nil;
    NSString *identifier = root.accessibilityIdentifier.lowercaseString ?: @"";
    if ([identifier containsString:@"menu"] ||
        [identifier containsString:@"overflow"] ||
        [identifier containsString:@"action_button"]) {
        CGRect frame = root.bounds;
        if (CGRectGetWidth(frame) > 8.0 && CGRectGetWidth(frame) < 80.0 &&
            CGRectGetHeight(frame) > 8.0) {
            return root;
        }
    }
    for (UIView *child in root.subviews) {
        UIView *found = YTKACEOverflowButtonInside(child);
        if (found != nil) return found;
    }
    return nil;
}

static NSString *YTKACEOfflineCommandVideoID(id command) {
    for (NSString *name in @[@"offlineVideoEndpoint", @"offlineVideoCommand"]) {
        id endpoint = YTKACEGetValue(command, @[name]);
        id value = YTKACEGetValue(endpoint, @[@"videoId", @"videoID"]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id direct = YTKACEGetValue(command, @[@"videoId", @"videoID"]);
    if ([direct isKindOfClass:NSString.class] && [direct length] != 0) {
        return direct;
    }
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:
                @"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match != nil) {
        return [dump substringWithRange:[match rangeAtIndex:1]];
    }
    static NSRegularExpression *packed;
    static dispatch_once_t packedToken;
    dispatch_once(&packedToken, ^{
        packed = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *packedMatch = [packed firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (packedMatch != nil) {
        return [dump substringWithRange:[packedMatch rangeAtIndex:1]];
    }
    YTKACEDownloadLog(@"feed", @"no video id in command dump=%@",
        dump.length > 300 ? [dump substringToIndex:300] : dump);
    return nil;
}

static BOOL YTKACEHandleFeedDownload(id command, id view, id sender) {
    const NSInteger placement = YTKACEDownloadPlacement();
    NSString *videoID = YTKACEOfflineCommandVideoID(command);
    UIView *anchor = [view isKindOfClass:UIView.class] ? view : nil;
    if (anchor.window == nil && [sender isKindOfClass:UIView.class]) {
        anchor = sender;
    }
    if (anchor.window == nil) {
        id senderView = YTKACEGetValue(sender, @[@"view", @"contentView", @"cell", @"_cell"]);
        if ([senderView respondsToSelector:@selector(contentView)] &&
            ![senderView isKindOfClass:UIView.class]) {
            senderView = YTKACEGetValue(senderView, @[@"contentView"]);
        }
        if ([senderView isKindOfClass:UIView.class]) {
            UIView *cell = senderView;
            UIView *overflow = YTKACEOverflowButtonInside(cell);
            anchor = overflow ?: cell;
        }
    }
    if (anchor.window == nil && YTKACEMenuSourceView.window != nil) {
        anchor = YTKACEMenuSourceView;
    }
    if (placement != 2 && placement != 3) return NO;
    if (videoID.length == 0) return NO;
    YTKACEShowNotice(YTKACELocalized(@"Preparing download"));
    YTKACEResolvePlayerResponse(videoID, ^(id response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (response == nil) {
                YTKACEDownloadLog(@"feed", @"resolve failed video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                YTKACEShowNotice(YTKACELocalized(@"Download unavailable"));
                return;
            }
            [YTKACEDownloadCoordinator.sharedCoordinator
                showDownloadMenuForResponse:response
                                 sourceView:anchor];
        });
    });
    return YES;
}

static void YTKACEOfflineVideoExecute(id receiver, SEL selector, id command,
                                      id entry, id view, id sender) {
    if (YTKACEHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static IMP OriginalLegacyOfflineVideoExecute;

static void YTKACELegacyOfflineVideoExecute(id receiver, SEL selector, id command,
                                            id entry, id view, id sender) {
    if (YTKACEHandleFeedDownload(command, view, sender)) return;
    if (OriginalLegacyOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static void YTKACEOfflineVideoExecuteCompletion(id receiver, SEL selector,
                                                id command, id entry, id view,
                                                id sender, id block) {
    if (YTKACEHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalOfflineVideoExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

void YTKACEInstallFeedDownloadHooks(void) {
    YTKACEInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:firstResponder:completion:",
        (IMP)YTKACEShowMenuCompletion, &OriginalShowMenuCompletion);
    YTKACEInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:skipCollapsedState:firstResponder:completion:",
        (IMP)YTKACEShowMenuSkipCompletion, &OriginalShowMenuSkipCompletion);
    YTKACEInstallInstanceHook(@"YTMenuController",
        @"actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:",
        (IMP)YTKACEActionsForRenderersLog, &OriginalActionsForRenderersLog);
    BOOL a = YTKACEInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACEOfflineVideoExecute, &OriginalOfflineVideoExecute);
    BOOL b = YTKACEInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTKACEOfflineVideoExecuteCompletion,
        &OriginalOfflineVideoExecuteCompletion);
    BOOL legacy = NO;
    if (!a) {
        legacy = YTKACEInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandler",
            @"executeWithCommand:entry:fromView:sender:",
            (IMP)YTKACELegacyOfflineVideoExecute, &OriginalLegacyOfflineVideoExecute);
    }
    YTKACEDownloadLog(@"feed", @"hooks execute=%d completion=%d legacy=%d", a, b, legacy);
}

BOOL YTKACEPlaybackTemplateReady(void) {
    @synchronized (YTKACESABRDownloader.class) {
        if (YTKACELastPlayerRequest == nil) return NO;
        if (YTKACELastPlayerService != nil) return YES;
    }
    return NSClassFromString(@"YTPlayerService") != Nil;
}

void YTKACEResolvePlayerResponse(NSString *videoID,
                                 YTKACEPlayerReloadCompletion completion) {
    if (videoID.length == 0) {
        completion(nil, [NSError errorWithDomain:@"YTKACEPlayerResolve" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No video identifier."}]);
        return;
    }
    id cached = YTKACECachedPlayerResponse(videoID);
    if (cached != nil) {
        YTKACEDownloadLog(@"resolve", @"cached video=%@", videoID);
        completion(cached, nil);
        return;
    }
    id service = nil;
    id sourceRequest = nil;
    @synchronized (YTKACESABRDownloader.class) {
        NSArray *pair = YTKACEPlayerRequests[videoID];
        if (pair.count > 1) {
            service = pair[0];
            sourceRequest = pair[1];
        } else {
            service = YTKACELastPlayerService;
            sourceRequest = YTKACELastPlayerRequest;
        }
    }
    if (service == nil) {
        Class serviceClass = NSClassFromString(@"YTPlayerService");
        if (serviceClass != Nil) {
            @try {
                service = [[serviceClass alloc] init];
            } @catch (__unused NSException *exception) {
                service = nil;
            }
            YTKACEDownloadLog(@"resolve", @"constructed player service=%d",
                service != nil);
            if (service != nil) {
                @synchronized (YTKACESABRDownloader.class) {
                    if (YTKACELastPlayerService == nil) {
                        YTKACELastPlayerService = service;
                    }
                }
            }
        }
    }
    if (sourceRequest == nil && YTKACELastInnerTubeContext != nil) {
        id built = [NSClassFromString(@"YTIPlayerRequest") new];
        if (YTKACESetValue(built, @"context",
                           YTKACECopyObject(YTKACELastInnerTubeContext))) {
            sourceRequest = built;
        }
    }
    if (service == nil || sourceRequest == nil || OriginalMakePlayerRequest == NULL) {
        completion(nil, [NSError errorWithDomain:@"YTKACEPlayerResolve" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"No player request template (service=%d context=%d).",
                    service != nil, YTKACELastInnerTubeContext != nil]}]);
        return;
    }
    id request = YTKACECopyObject(sourceRequest);
    if (!YTKACESetValue(request, @"videoId", videoID)) {
        completion(nil, [NSError errorWithDomain:@"YTKACEPlayerResolve" code:3
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's player request could not be retargeted."}]);
        return;
    }
    YTKACESetValue(request, @"playlistId", @"");
    YTKACESetValue(request, @"params", @"");
    YTKACESetValue(request, @"playlistIndex", @0);
    id playback = YTKACEGetValue(request, @[@"playbackContext"]);
    id contentPlayback = YTKACEGetValue(playback, @[@"contentPlaybackContext"]);
    YTKACESetValue(contentPlayback, @"currentUrl", @"");
    YTKACESetValue(contentPlayback, @"referer", @"");
    YTKACEDownloadLog(@"resolve", @"request video=%@", videoID);
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            service,
            NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
            request,
            ^(id receivedResponse, __unused id cacheContext) {
                id playerResponse = YTKACEHLSOriginalResponse(videoID) ?: receivedResponse;
                NSString *resolved = nil;
                id details = YTKACEGetValue(playerResponse, @[@"videoDetails"]);
                id value = YTKACEGetValue(details, @[@"videoId", @"videoID"]);
                if ([value isKindOfClass:NSString.class]) resolved = value;
                id streaming = YTKACEGetValue(playerResponse, @[@"streamingData"]);
                if (streaming == nil) {
                    id nested = YTKACEGetValue(playerResponse, @[@"playerData"]);
                    streaming = YTKACEGetValue(nested, @[@"streamingData"]);
                }
                id ustreamer = YTKACEGetValue(streaming,
                    @[@"mediaUstreamerRequestConfig"]);
                id config = YTKACEGetValue(ustreamer,
                    @[@"videoPlaybackUstreamerConfig"]);
                YTKACEDownloadLog(@"resolve",
                    @"response video=%@ resolved=%@ streaming=%d ustreamer=%d config=%d",
                    videoID, resolved ?: @"none", streaming != nil,
                    ustreamer != nil, config != nil);
                if (playerResponse != nil) {
                    YTKACEStorePlayerResponse(videoID, playerResponse);
                }
                completion(playerResponse, nil);
            },
            ^(NSError *error) {
                YTKACEDownloadLog(@"resolve", @"error video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                completion(nil, error);
            });
    });
}

void YTKACEReloadPlayer(NSString * _Nullable videoID,
                        NSString *token,
                        YTKACEPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (YTKACESABRDownloader.class) {
        NSArray *pair = videoID.length != 0 ? YTKACEPlayerRequests[videoID] : nil;
        service = pair.count > 0 ? pair[0] : YTKACELastPlayerService;
        request = pair.count > 1 ? pair[1] : YTKACELastPlayerRequest;
        playbackRequest = YTKACELastPlaybackRequest;
    }
    if ((OriginalMakePlayerRequest == NULL && OriginalMakePlaybackRequest == NULL) ||
        service == nil || request == nil || token.length == 0) {
        NSError *error = [NSError errorWithDomain:@"YTKACEPlayerReload" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No matching YouTube player request is available."}];
        completion(nil, error);
        return;
    }
    id mutableRequest = YTKACECopyObject(request);
    id playback = YTKACECopyObject(YTKACEGetValue(mutableRequest, @[@"playbackContext"]));
    if (playback == nil) playback = [NSClassFromString(@"YTIPlaybackContext") new];
    id params = [NSClassFromString(@"YTIReloadPlaybackParams") new];
    id reload = [NSClassFromString(@"YTIReloadPlaybackContext") new];
    BOOL configured = YTKACESetValue(params, @"token", token) &&
        YTKACESetValue(reload, @"reloadPlaybackParams", params) &&
        YTKACESetValue(playback, @"reloadPlaybackContext", reload) &&
        YTKACESetValue(mutableRequest, @"playbackContext", playback);
    if (!configured) {
        NSError *error = [NSError errorWithDomain:@"YTKACEPlayerReload" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"YouTube's reload request could not be configured."}];
        completion(nil, error);
        return;
    }
    id routedRequest = nil;
    if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
        Class playbackClass = NSClassFromString(@"YTPlaybackRequest");
        SEL initializer = NSSelectorFromString(
            @"initWithProtoRequest:URLRequestProperties:CPN:QOEController:latencyLogger:streamingWatchEnabled:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:streamingWatchHandlers:");
        id allocated = [playbackClass alloc];
        if ([allocated respondsToSelector:initializer]) {
            BOOL streaming = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"streamingWatchEnabled"));
            BOOL relaxation = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"enablePlayerResponseCacheKeyRelaxation"));
            routedRequest = ((id (*)(id, SEL, id, id, id, id, id, BOOL, BOOL, id, id))objc_msgSend)(
                allocated,
                initializer,
                mutableRequest,
                YTKACEGetValue(playbackRequest, @[@"URLRequestProperties"]),
                YTKACEGetValue(playbackRequest, @[@"CPN"]),
                YTKACEGetValue(playbackRequest, @[@"QOEController"]),
                YTKACEGetValue(playbackRequest, @[@"latencyLogger"]),
                streaming,
                relaxation,
                YTKACEGetValue(playbackRequest, @[@"playerResponseCacheToken"]),
                YTKACEGetValue(playbackRequest, @[@"streamingWatchHandlers"])
            );
        }
    }
    YTKACEDownloadLog(@"reload", @"native request video=%@ token=%lu route=%@",
        videoID ?: @"unknown", (unsigned long)token.length,
        routedRequest != nil ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            YTKACEDownloadLog(@"reload", @"native response video=%@ class=%@",
                videoID ?: @"unknown", NSStringFromClass([playerResponse class]));
            completion(playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            YTKACEDownloadLog(@"reload", @"native error video=%@ error=%@",
                videoID ?: @"unknown", error.localizedDescription ?: @"unknown");
            completion(nil, error);
        };
        if (routedRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service, NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                routedRequest, response, failure
            );
        } else {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service, NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                mutableRequest, response, failure
            );
        }
    });
}

static id YTKACEMintWithVideoID(id receiver, SEL selector, id videoID) {
    if ([videoID isKindOfClass:NSString.class]) YTKACESABRSetCurrentVideoID(videoID);
    id result = nil;
    if (OriginalMintWithVideoID != NULL) {
        result = ((id (*)(id, SEL, id))OriginalMintWithVideoID)(receiver, selector, videoID);
    }
    YTKACESABRSetPoToken(result);
    if ([videoID isKindOfClass:NSString.class]) {
        static NSMutableArray<NSString *> *logged;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableArray array]; });
        BOOL fresh = NO;
        @synchronized (logged) {
            if (![logged containsObject:videoID]) {
                [logged addObject:videoID];
                if (logged.count > 30) [logged removeObjectAtIndex:0];
                fresh = YES;
            }
        }
        if (fresh) {
            YTKACEDownloadLog(@"token", @"video=%@ potoken=%lu", videoID,
                              (unsigned long)YTKACESABRPoTokenLength());
        }
    }
    return result;
}

static void YTKACESetPlayerResponse(id receiver,
                                    SEL selector,
                                    id playerResponse,
                                    id cpn) {
    if (OriginalSetPlayerResponse != NULL) {
        ((void (*)(id, SEL, id, id))OriginalSetPlayerResponse)(
            receiver, selector, playerResponse, cpn
        );
    }
    YTKACEDownloadCoordinator.sharedCoordinator.playerResponse = playerResponse;
}

static void YTKACESetPoToken(id receiver, SEL selector, NSData *token) {
    if (OriginalSetPoToken != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPoToken)(receiver, selector, token);
    }
    YTKACESABRSetPoToken(token);
}

void YTKACEInstallDownloadHooks(void) {
    YTKACEInstallInstanceHook(@"YTProofOfOriginTokenManager",
                              @"mintWithVideoID:",
                              (IMP)YTKACEMintWithVideoID,
                              &OriginalMintWithVideoID);
    YTKACEInstallInstanceHook(@"YTIServiceIntegrityDimensions",
                              @"setPoToken:",
                              (IMP)YTKACESetPoToken,
                              &OriginalSetPoToken);
    YTKACEInstallPlayerServiceHook();
    YTKACEInstallInstanceHook(@"MLOnesieRequestFactory",
                              @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
                              (IMP)YTKACEOnesieRequest,
                              &OriginalOnesieRequest);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPlayerResponse:CPN:",
                              (IMP)YTKACESetPlayerResponse,
                              &OriginalSetPlayerResponse);


    YTKACERegisterOverlayConfigurator(@"downloads", ^(UIView *overlay, UIStackView *stack) {
        (void)overlay;
        UIButton *button = YTKACEOverlayButton(
            stack,
            @"YTKACE Download",
            @"arrow.down.circle.fill",
            YTKACEDownloadCoordinator.sharedCoordinator,
            @selector(showDownloadMenuFromButton:)
        );
        [button setImage:YTKACEDownloadGlyphImage()
                forState:UIControlStateNormal];
        const NSInteger placement = YTKACEDownloadPlacement();
        button.hidden = placement != 1 && placement != 3;
    });
}
