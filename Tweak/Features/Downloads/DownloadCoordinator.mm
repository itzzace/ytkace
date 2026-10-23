#import "DownloadCoordinator.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../YTKACE.h"
#import "DownloadLog.h"
#import "DownloadSponsor.h"
#import "DownloadProgressView.h"
#import "FFmpegMuxer.h"
#import "SABRDownloader.h"
#import "DirectDownloader.h"
#import <VideoToolbox/VideoToolbox.h>
#import "StreamResolver.h"
#import "../Translation/YTKACEVOTClient.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../Settings/YTKACEDownloadsController.h"
#import "../../Settings/YTKACERootOptionsController.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"

#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface YTKACEDownloadJob : NSObject
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, strong) YTKACESABRTask *sabrTask;
@property(nonatomic, strong) YTKACEDirectTask *directTask;
@property(nonatomic, assign) BOOL useDirect;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *extension;
@property(nonatomic, strong) NSURL *thumbnailURL;
@property(nonatomic, strong) id playerResponse;
@property(nonatomic, strong) YTKACEStreamOption *videoOption;
@property(nonatomic, strong) YTKACEStreamOption *audioOption;
@property(nonatomic, assign) BOOL audioOnly;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, assign) NSInteger fallbackCount;
@property(nonatomic, assign) int64_t audioBytes;
@property(nonatomic, assign) int64_t videoBytes;
@property(nonatomic, strong, nullable) NSURL *savedURL;
@property(nonatomic, assign) BOOL savesToPhotos;
@property(nonatomic, assign) BOOL sharesFile;
@property(nonatomic, strong, nullable) NSURL *captionURL;
@property(nonatomic, copy, nullable) NSString *captionLanguage;
@end

static const void *YTKACEShortsFullscreenKey = &YTKACEShortsFullscreenKey;
static const void *YTKACEShortsFullscreenAlphaKey =
    &YTKACEShortsFullscreenAlphaKey;
static NSInteger const YTKACEShortsDownloadButtonTag = 0x59544B44;

static BOOL YTKACEContainsShortsDownloadButton(UIView *view) {
    if (view.tag == YTKACEShortsDownloadButtonTag) return YES;
    for (UIView *subview in view.subviews) {
        if (YTKACEContainsShortsDownloadButton(subview)) return YES;
    }
    return NO;
}

void YTKACESetShortsOverlayFullscreen(UIView *overlay,
                                      BOOL fullscreen) {
    for (UIView *subview in overlay.subviews) {
        if (YTKACEContainsShortsDownloadButton(subview)) continue;
        if (fullscreen) {
            if (objc_getAssociatedObject(
                    subview, YTKACEShortsFullscreenAlphaKey) == nil) {
                objc_setAssociatedObject(subview,
                    YTKACEShortsFullscreenAlphaKey, @(subview.alpha),
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            subview.alpha = 0.0;
        } else {
            NSNumber *alpha = objc_getAssociatedObject(
                subview, YTKACEShortsFullscreenAlphaKey);
            if (alpha != nil) {
                subview.alpha = alpha.doubleValue;
                objc_setAssociatedObject(subview,
                    YTKACEShortsFullscreenAlphaKey, nil,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void YTKACECollectShortsElements(UIView *view, NSMutableArray<UIView *> *found, NSUInteger depth) {
    if (view == nil || depth > 12) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name isEqualToString:@"YTReelElementAsyncComponentView"] ||
        [name isEqualToString:@"YTReelGradientView"] ||
        [name hasPrefix:@"YTShortsStickersView"]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) YTKACECollectShortsElements(subview, found, depth + 1);
}

void YTKACESetShortsElementsFullscreen(UIView *container, BOOL fullscreen) {
    NSMutableArray<UIView *> *elements = [NSMutableArray array];
    YTKACECollectShortsElements(container, elements, 0);
    for (UIView *element in elements) {
        if (YTKACEContainsShortsDownloadButton(element)) continue;
        if (fullscreen) {
            if (objc_getAssociatedObject(element, YTKACEShortsFullscreenAlphaKey) == nil) {
                objc_setAssociatedObject(element, YTKACEShortsFullscreenAlphaKey, @(element.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            element.alpha = 0.0;
        } else {
            NSNumber *alpha = objc_getAssociatedObject(element, YTKACEShortsFullscreenAlphaKey);
            element.alpha = alpha != nil ? alpha.doubleValue : 1.0;
            objc_setAssociatedObject(element, YTKACEShortsFullscreenAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

UIView *YTKACEShortsContainerForView(UIView *view, UIView *fallbackRoot) {
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    if (containerClass == Nil) return nil;
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:containerClass]) return candidate;
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:fallbackRoot ?: [UIView new]];
    while (stack.count != 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:containerClass] && candidate.window != nil &&
            CGRectIntersectsRect([candidate convertRect:candidate.bounds toView:nil], candidate.window.bounds)) {
            return candidate;
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL YTKACEShortsGlobalFullscreen;
static NSHashTable<UIView *> *YTKACEFadedShortsContainers;
static BOOL YTKACEShortsPivotBypass;

BOOL YTKACEShortsPivotShowBlocked(void) {
    return YTKACEShortsGlobalFullscreen && !YTKACEShortsPivotBypass;
}

BOOL YTKACEShortsNewFullscreenActive(void) {
    return YTKACEShortsGlobalFullscreen;
}

void YTKACEFadeShortsElement(UIView *element) {
    if (element == nil || element.alpha <= 0.01 || YTKACEContainsShortsDownloadButton(element)) return;
    if (objc_getAssociatedObject(element, YTKACEShortsFullscreenAlphaKey) == nil) {
        objc_setAssociatedObject(element, YTKACEShortsFullscreenAlphaKey, @(element.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    element.alpha = 0.0;
}

void YTKACERegisterFadedShortsContainer(UIView *container) {
    if (container == nil) return;
    if (YTKACEFadedShortsContainers == nil) YTKACEFadedShortsContainers = [NSHashTable weakObjectsHashTable];
    [YTKACEFadedShortsContainers addObject:container];
}

void YTKACESetShortsNewFullscreen(UIView *container, BOOL fullscreen) {
    YTKACEShortsGlobalFullscreen = fullscreen;
    SEL pivotSelector = NSSelectorFromString(fullscreen ? @"hidePivotBar" : @"showPivotBar");
    YTKACEShortsPivotBypass = YES;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id root = window.rootViewController;
            if ([root respondsToSelector:pivotSelector]) ((void (*)(id, SEL))objc_msgSend)(root, pivotSelector);
        }
    }
    YTKACEShortsPivotBypass = NO;
    if (fullscreen) {
        if (container == nil) return;
        YTKACERegisterFadedShortsContainer(container);
        [UIView animateWithDuration:0.25 animations:^{
            YTKACESetShortsElementsFullscreen(container, YES);
        }];
        return;
    }
    NSArray<UIView *> *faded = YTKACEFadedShortsContainers.allObjects;
    [YTKACEFadedShortsContainers removeAllObjects];
    [UIView animateWithDuration:0.25 animations:^{
        for (UIView *view in faded) YTKACESetShortsElementsFullscreen(view, NO);
    }];
}

@implementation YTKACEDownloadJob
@end

@interface YTKACEDownloadCoordinator () <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YTKACEDownloadJob *> *jobs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEDownloadJob *> *activeJobs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEDownloadJob *> *retryableJobs;
@property(nonatomic, weak) UIView *downloadSourceView;
@property(nonatomic, strong, nullable) id externalResponse;
@property(nonatomic, weak) UIView *externalSourceView;
@property(nonatomic, assign) BOOL pendingSavesToPhotos;
@property(nonatomic, assign) BOOL pendingSharesFile;
@property(nonatomic, assign) BOOL batchSharing;
@property(nonatomic, strong) NSMutableArray<NSURL *> *batchShareURLs;
@property(nonatomic, copy, nullable) NSArray<YTKACEStreamOption *> *directOptions;
@property(nonatomic, copy, nullable) NSString *directOptionsVideoID;
@property(nonatomic, assign) BOOL forceSABRNext;
- (void)resolveSaveDestinationFromView:(nullable UIView *)sourceView
                                  then:(dispatch_block_t)continuation;
- (void)showAudioLanguagesForVideo:(nullable YTKACEStreamOption *)videoOption
                         audioOnly:(BOOL)audioOnly
                          category:(NSString *)category;
- (void)beginSABRDownloadVideo:(nullable YTKACEStreamOption *)videoOption
                         audio:(YTKACEStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                      category:(NSString *)category;
- (void)presentShareSheetForURL:(NSURL *)url;
- (void)launchJob:(YTKACEDownloadJob *)job;
- (void)retryJobWithIdentifier:(NSString *)identifier;
- (void)resolveAudioDestinationFromView:(nullable UIView *)sourceView
                                   then:(dispatch_block_t)continuation;
- (void)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL
                   job:(YTKACEDownloadJob *)job;
- (void)saveCompletedURL:(NSURL *)URL job:(YTKACEDownloadJob *)job
                extension:(NSString *)extension;
- (void)startSABRJob:(YTKACEDownloadJob *)job;
- (nullable YTKACEStreamOption *)fallbackVideoForJob:(YTKACEDownloadJob *)job;
- (NSString *)safeFilename:(NSString *)filename;
- (NSString *)failureMessageForError:(nullable NSError *)error
                                  job:(nullable YTKACEDownloadJob *)job;
@end

static NSString * const YTKACESaveLocationKey =
    @"YTKACE.Preference.Downloads.SaveLocation";
static NSString * const YTKACEAudioSaveLocationKey =
    @"YTKACE.Preference.Downloads.AudioSaveLocation";

void YTKACESaveVideoToPhotosFile(NSURL *url,
                                 void (^completion)(BOOL, NSError *)) {
    if (url == nil) {
        if (completion != NULL) completion(NO, nil);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSMutableString *codecs = [NSMutableString string];
        for (AVAssetTrack *track in asset.tracks) {
            for (id description in track.formatDescriptions) {
                const FourCharCode subtype = CMFormatDescriptionGetMediaSubType(
                    (CMFormatDescriptionRef)description);
                [codecs appendFormat:@"%c%c%c%c ",
                 (char)((subtype >> 24) & 0xFF), (char)((subtype >> 16) & 0xFF),
                 (char)((subtype >> 8) & 0xFF), (char)(subtype & 0xFF)];
            }
        }
        YTKACEDownloadLog(@"photos", @"save %@ bytes=%@ codecs=[%@]",
                          url.lastPathComponent, size, codecs);

        void (^save)(void) = ^{
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            } completionHandler:^(BOOL success, NSError *error) {
                if (!success) {
                    YTKACEDownloadLog(@"photos", @"failed domain=%@ code=%ld",
                                      error.domain, (long)error.code);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion != NULL) completion(success, error);
                });
            }];
        };

        void (^afterAuthorization)(PHAuthorizationStatus) =
            ^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized ||
                status == PHAuthorizationStatusLimited) {
                save();
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                YTKACEShowNotice(YTKACELocalized(
                    @"YouTube needs permission to add to Photos."));
                if (completion != NULL) completion(NO, nil);
            });
        };

        if (@available(iOS 14.0, *)) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                       handler:afterAuthorization];
        } else {
            [PHPhotoLibrary requestAuthorization:afterAuthorization];
        }
    });
}

@implementation YTKACEDownloadCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACEDownloadCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTKACEDownloadCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _jobs = [NSMutableDictionary dictionary];
        _activeJobs = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 60.0 * 60.0;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 3;
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:queue];
        __weak YTKACEDownloadCoordinator *weakSelf = self;
        YTKACEDownloadProgressView.sharedView.retryHandler = ^(NSString *identifier) {
            [weakSelf retryJobWithIdentifier:identifier];
        };
        YTKACEDownloadProgressView.sharedView.cancelHandler = ^(NSString *identifier) {
            YTKACEDownloadJob *job = weakSelf.activeJobs[identifier];
            if (job != nil && job.sabrTask == nil && job.task == nil && job.directTask == nil) {
                job.cancelled = YES;
                [YTKACEDownloadProgressView.sharedView finishJob:identifier
                    success:NO message:YTKACELocalized(@"Cancelled")];
                [weakSelf.activeJobs removeObjectForKey:identifier];
                YTKACEDownloadLog(identifier, @"cancelled before start");
                return;
            }
            [job.sabrTask cancel];
            [job.directTask cancel];
            YTKACEFFmpegCancelConversion(identifier);
        };
    }
    return self;
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSString *notice = title.length != 0 && message.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", title, message]
        : (title.length != 0 ? title : message);
    [self showCompactNotice:notice];
}

- (NSString *)failureMessageForError:(NSError *)error
                                  job:(YTKACEDownloadJob *)job {
    NSString *detail = error.localizedDescription ?: YTKACELocalized(@"The download did not complete.");
    if (error.code == NSURLErrorCancelled) return YTKACELocalized(@"The download was cancelled.");
    if ([error.domain isEqualToString:@"YTKACESABR"]) {
        switch (error.code) {
            case 1:
            case 2:
                return YTKACELocalized(@"No usable download session came back. Start the video briefly so a fresh one is issued, then try again.");
            case 4:
                return YTKACELocalized(@"The stream request was turned down. Close and reopen the video, let it play for a moment, then try again.");
            case 5:
            case 8:
                return YTKACELocalized(@"The transfer ended early. Try once more, or drop to a lower quality.");
            case 6:
                return YTKACELocalized(@"This format is not permitted on this device. Pick a different quality.");
            case 9:
                return YTKACELocalized(@"The high-resolution stream could not be refreshed. Give the video a moment of playback and try again.");
            case 10:
                return YTKACELocalized(@"This video has not been set up for streaming yet. Start playing it for a second or two, then try the download again.");
            default:
                break;
        }
    }
    if ([error.domain isEqualToString:@"YTKACEFFmpeg"]) {
        NSString *quality = job.videoOption.qualityLabel.length != 0
            ? job.videoOption.qualityLabel : YTKACELocalized(@"selected quality");
        return [NSString stringWithFormat:
            YTKACELocalized(@"%@ downloaded, but its video and audio could not be merged. Try another %@ format.\n%@"),
            quality, quality, detail];
    }
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        if (error.code == NSURLErrorNotConnectedToInternet) {
            return YTKACELocalized(@"The network connection is offline. Reconnect and retry.");
        }
        if (error.code == NSURLErrorTimedOut) {
            return YTKACELocalized(@"The download timed out. Retry on a stable connection.");
        }
    }
    return detail;
}

- (id)findPlayerResponseFromObject:(id)object
                           visited:(NSHashTable *)visited
                             depth:(NSUInteger)depth
                             trace:(BOOL)trace {
    if (object == nil || depth > 14 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    SEL dataSelector = NSSelectorFromString(@"playerData");
    if ([object respondsToSelector:dataSelector]) {
        id data = ((id (*)(id, SEL))objc_msgSend)(object, dataSelector);
        if (data != nil) {
            return object;
        }
    }
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse",
                              @"_youtubeiOSPlayerViewController",
                              @"parentViewController", @"eventsDelegate",
                              @"parentResponder", @"playbackController"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id related = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        id response = [self findPlayerResponseFromObject:related
                                                 visited:visited
                                                   depth:depth + 1
                                                   trace:trace];
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return [self findPlayerResponseFromObject:
            ((UIResponder *)object).nextResponder visited:visited
                                                   depth:depth + 1
                                                   trace:trace];
    }
    return nil;
}

- (id)playerResponseFromView:(UIView *)view {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return [self findPlayerResponseFromObject:view visited:visited depth:0 trace:NO];
}

- (id)tracedPlayerResponseFromView:(UIView *)view {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return [self findPlayerResponseFromObject:view visited:visited depth:0 trace:NO];
}

- (id)videoOverlayControllerFromView:(UIView *)view {
    UIResponder *current = view;
    Class overlayClass = NSClassFromString(
        @"YTMainAppVideoPlayerOverlayViewController");
    for (NSUInteger depth = 0; current != nil && depth < 24; depth++) {
        if (overlayClass != Nil && [current isKindOfClass:overlayClass]) {
            return current;
        }
        current = current.nextResponder;
    }
    return nil;
}

- (id)videoPlayerResponseFromView:(UIView *)view {
    id overlay = [self videoOverlayControllerFromView:view];
    SEL parentSelector = NSSelectorFromString(@"parentViewController");
    id playerController = [overlay respondsToSelector:parentSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(overlay, parentSelector) : nil;
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse"]) {
        SEL selector = NSSelectorFromString(name);
        if ([playerController respondsToSelector:selector]) {
            id response = ((id (*)(id, SEL))objc_msgSend)(playerController, selector);
            if (response != nil) {
                return response;
            }
        }
    }
    return [self playerResponseFromView:view];
}

- (UIImage *)menuIcon:(NSString *)symbol {
    NSDictionary<NSString *, NSString *> *assets = @{
        @"play": @"ig_icon_play_outline_24_Normal",
        @"music.note": @"yt_outline_music_24pt",
        @"play.circle": @"play_arrow_circle_24pt_3x_Normal",
        @"photo": @"youtube_outline_image_24pt",
        @"doc.on.doc": @"yt_outline_copy_24pt",
        @"chevron.right": @"yt_outline_chevron_right_24pt_2x_Normal",
        @"arrow.up.left.and.arrow.down.right": @"ic_fullscreen_3x_Normal",
        @"arrow.down.right.and.arrow.up.left": @"ic_fullscreen_exit_3x_Normal",
        @"ytkace.system": @"ig_icon_play_outline_24_Normal",
        @"ytkace.infuse": @"play.tv",
        @"ytkace.vlc": @"play.circle"
    };
    UIImage *image = YTKACEAssetImage(assets[symbol] ?: @"", symbol);
    if (image != nil) {
        if ([symbol isEqualToString:@"ytkace.infuse"])
            return [[UIImage systemImageNamed:@"play.tv"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if ([symbol isEqualToString:@"ytkace.vlc"])
            return [[UIImage systemImageNamed:@"play.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                        weight:UIImageSymbolWeightRegular];
    return [[UIImage systemImageNamed:symbol withConfiguration:configuration]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)presentNativeSheetWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                         sourceView:(UIView *)sourceView
                            actions:(NSArray<NSDictionary *> *)actions {

    id presenter = [self topViewController];
    UIResponder *responder = sourceView;
    id sourceController = nil;
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            sourceController = (UIViewController *)responder;
        }
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([responder respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(responder, eventsSelector);
            if (events != nil) {
                sourceController = events;
                break;
            }
        }
        responder = responder.nextResponder;
    }
    presenter = sourceController ?: presenter;
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeDetailed = NSSelectorFromString(
        @"actionWithTitle:iconImage:secondaryIconImage:accessibilityIdentifier:handler:");
    SEL makeSimple = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    id sheet = actionClass != Nil
        ? YTKACEMakeSheet(title.length != 0 ? title : nil, subtitle.length != 0 ? subtitle : nil)
        : nil;
    if (sheet != nil) {
        if (title.length != 0 || subtitle.length != 0) {
            @try {
                id header = [sheet valueForKey:@"_headerView"];
                SEL divider = NSSelectorFromString(@"showHeaderDivider");
                if ([header respondsToSelector:divider]) {
                    ((void (*)(id, SEL))objc_msgSend)(header, divider);
                }
            } @catch (__unused NSException *exception) {
            }
        }
        for (NSDictionary *item in actions) {
            dispatch_block_t handler = item[@"handler"];
            UIImage *icon = item[@"icon"];
            UIImage *secondary = item[@"secondary"];
            id action = nil;
            if (secondary != nil && [actionClass respondsToSelector:makeDetailed]) {
                action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                    actionClass, makeDetailed, item[@"title"], icon, secondary, nil,
                    handler);
            } else if ([actionClass respondsToSelector:makeSimple]) {
                action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                    actionClass, makeSimple, item[@"title"], icon, 0, handler);
            }
            if (action != nil && [sheet respondsToSelector:NSSelectorFromString(@"addAction:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    sheet, NSSelectorFromString(@"addAction:"), action);
            }
        }
        YTKACEShowSheet(sheet, presenter);
        return;
    }
    [self showCompactNotice:YTKACELocalized(@"YouTube menu unavailable")];
}

- (NSDictionary *)sheetAction:(NSString *)title
                          icon:(NSString *)icon
                     secondary:(UIImage *)secondary
                       handler:(dispatch_block_t)handler {
    NSMutableDictionary *item = [@{
        @"title": title,
        @"icon": [self menuIcon:icon] ?: [UIImage new],
        @"handler": [handler copy]
    } mutableCopy];
    if (secondary != nil) {
        item[@"secondary"] = secondary;
    }
    return item;
}

- (void)resolveSaveDestinationFromView:(UIView *)sourceView
                                  then:(dispatch_block_t)continuation {
    const NSInteger mode = [NSUserDefaults.standardUserDefaults
        integerForKey:YTKACESaveLocationKey];
    YTKACEDownloadLog(@"save", @"destination mode=%ld", (long)mode);
    if (mode != 2) {
        self.pendingSavesToPhotos = mode == 1;
        self.pendingSharesFile = mode == 3;
        if (continuation != NULL) continuation();
        return;
    }
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTKACELocalized(@"YTKACE Library") icon:@"arrow.down.circle"
            secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTKACELocalized(@"Photos") icon:@"photo.on.rectangle"
            secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = YES;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTKACELocalized(@"Share Sheet")
            icon:@"square.and.arrow.up" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = YES;
                if (continuation != NULL) continuation();
            }]
    ];
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (void)resolveAudioDestinationFromView:(UIView *)sourceView
                                   then:(dispatch_block_t)continuation {
    const NSInteger mode = [NSUserDefaults.standardUserDefaults
        integerForKey:YTKACEAudioSaveLocationKey];
    YTKACEDownloadLog(@"save", @"audio destination mode=%ld", (long)mode);
    if (mode != 2) {
        self.pendingSavesToPhotos = mode == 1;
        self.pendingSharesFile = mode == 3;
        if (continuation != NULL) continuation();
        return;
    }
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTKACELocalized(@"YTKACE Library")
            icon:@"arrow.down.circle" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTKACELocalized(@"Photos")
            icon:@"photo.on.rectangle" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = YES;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTKACELocalized(@"Share Sheet")
            icon:@"square.and.arrow.up" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = YES;
                if (continuation != NULL) continuation();
            }]
    ];
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (void)showDownloadMenu {
    [self showDownloadMenuFromButton:nil];
}

- (UIView *)sheetAnchorForView:(UIView *)source {
    UIViewController *top = [self topViewController];
    UIView *host = top.viewIfLoaded;
    if (host == nil || host.window == nil) return source;
    if (source != nil && source.window != nil &&
        [source isDescendantOfView:host]) {
        return source;
    }
    static UIView *anchor;
    if (anchor == nil) {
        anchor = [[UIView alloc] initWithFrame:CGRectZero];
        anchor.userInteractionEnabled = NO;
        anchor.backgroundColor = UIColor.clearColor;
        anchor.accessibilityIdentifier = @"YTKACE Sheet Anchor";
    }
    if (anchor.superview != host) {
        [anchor removeFromSuperview];
        [host addSubview:anchor];
    }
    CGRect frame;
    if (source != nil && source.window != nil) {
        frame = [source convertRect:source.bounds toView:host];
    } else {
        frame = CGRectMake(CGRectGetWidth(host.bounds) - 60.0,
                           CGRectGetHeight(host.bounds) * 0.5, 44.0, 44.0);
    }
    anchor.frame = frame;
    [host sendSubviewToBack:anchor];
    return anchor;
}

- (void)showDownloadMenuForResponse:(id)response sourceView:(UIView *)sourceView {
    sourceView = [self sheetAnchorForView:sourceView];
    self.externalResponse = response;
    self.externalSourceView = sourceView;
    [self showDownloadMenuFromButton:nil];
    self.externalResponse = nil;
    self.externalSourceView = nil;
}

- (void)showDownloadMenuFromButton:(UIButton *)button {
    if (!YTKACEDownloadsEnabled()) {
        return;
    }
    UIView *anchor = self.externalSourceView ?: button;
    id currentResponse = self.externalResponse
        ? self.externalResponse : [self videoPlayerResponseFromView:button];
    if (currentResponse != nil) {
        self.playerResponse = currentResponse;
    }
    if (self.playerResponse == nil) {
        [self showAlertWithTitle:@"YTKACE" message:YTKACELocalized(@"No active video was found.")];
        return;
    }
    self.downloadSourceView = anchor;

    __weak YTKACEDownloadCoordinator *weakSelf = self;
    UIImage *chevron = [self menuIcon:@"chevron.right"];
    NSMutableArray *actions = [NSMutableArray arrayWithArray:@[
        [self sheetAction:YTKACELocalized(@"Download Video") icon:@"play"
            secondary:chevron handler:^{
                [weakSelf resolveSaveDestinationFromView:anchor then:^{
                    [weakSelf startVideoDownloadForCategory:@"Video"];
                }];
            }],
        [self sheetAction:YTKACELocalized(@"Download Audio") icon:@"music.note"
            secondary:chevron handler:^{
                [weakSelf resolveAudioDestinationFromView:anchor then:^{
                    [weakSelf startAudioDownload];
                }];
            }]
    ]];

    BOOL votEnabled = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.VOT.Enabled"]
        ? [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.VOT.Enabled"]
        : YES;
    if (votEnabled) {
        [actions addObject:[self sheetAction:YTKACELocalized(@"Download Voice-Over") icon:@"waveform.badge.magnifyingglass"
            secondary:nil handler:^{
                [weakSelf downloadVoiceOverAudioFromView:anchor];
            }]];
    }

    [actions addObjectsFromArray:@[
        [self sheetAction:YTKACELocalized(@"Play in External Player") icon:@"play.circle"
            secondary:chevron handler:^{ [weakSelf showExternalPlayerMenuFromView:anchor]; }],
        [self sheetAction:YTKACELocalized(@"Save Image") icon:@"photo"
            secondary:nil handler:^{ [weakSelf saveThumbnail]; }],
        [self sheetAction:YTKACELocalized(@"Copy Information") icon:@"doc.on.doc"
            secondary:chevron handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf showCopyInformationMenuFromView:anchor];
                    });
            }]
    ]];
    [self presentNativeSheetWithTitle:
        [YTKACEStreamResolver authorFromPlayerResponse:self.playerResponse]
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:anchor actions:actions];
}


- (void)downloadVoiceOverAudioFromView:(nullable UIView *)sourceView {
    NSString *videoID = [YTKACEStreamResolver videoIDFromPlayerResponse:self.playerResponse] ?: YTKACELastVideoID();
    if (videoID.length == 0) {
        [self showAlertWithTitle:@"YTKACE" message:YTKACELocalized(@"No active video was found.")];
        return;
    }

    NSString *title = [YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse] ?: videoID;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *targetLang = [defaults stringForKey:@"YTKACE.Preference.VOT.TargetLanguage"] ?: @"ru";

    [self showCompactNotice:YTKACELocalized(@"Requesting translation...")];

    __weak __typeof__(self) weakSelf = self;
    [YTKACEVOTClient.sharedClient requestTranslationForVideoID:videoID
                                                      duration:0
                                                    sourceLang:nil
                                                    targetLang:targetLang
                                                    completion:^(YTKACEVOTResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil || response == nil) {
                [weakSelf showCompactNotice:YTKACELocalized(@"Translation failed")];
                return;
            }

            if ((response.status == YTKACEVOTStatusFinished || response.status == YTKACEVOTStatusPartContent) && response.audioURL.length > 0) {
                [weakSelf showCompactNotice:YTKACELocalized(@"Downloading voice-over...")];
                NSURL *remoteURL = [NSURL URLWithString:response.audioURL];
                if (remoteURL == nil) {
                    [weakSelf showCompactNotice:YTKACELocalized(@"Translation failed")];
                    return;
                }

                NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:remoteURL completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable resp, NSError * _Nullable dlError) {
                    if (dlError != nil || location == nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCompactNotice:YTKACELocalized(@"Voice-over download failed")];
                        });
                        return;
                    }

                    NSMutableCharacterSet *illegal = [[NSCharacterSet alphanumericCharacterSet] invertedSet].mutableCopy;
                    [illegal removeCharactersInString:@" -_()[]"];
                    NSString *safeTitle = [[title componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@" "];
                    if (safeTitle.length == 0) safeTitle = videoID;
                    NSString *filename = [NSString stringWithFormat:@"%@ (%@ - VOT).mp3", safeTitle, targetLang.uppercaseString];
                    NSURL *destURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
                    [NSFileManager.defaultManager removeItemAtURL:destURL error:nil];
                    [NSFileManager.defaultManager moveItemAtURL:location toURL:destURL error:nil];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[destURL] applicationActivities:nil];
                        UIViewController *presenter = [weakSelf topViewController];
                        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && sourceView != nil) {
                            activity.popoverPresentationController.sourceView = sourceView;
                            activity.popoverPresentationController.sourceRect = sourceView.bounds;
                        }
                        [presenter presentViewController:activity animated:YES completion:nil];
                        [weakSelf showCompactNotice:YTKACELocalized(@"Voice-over saved successfully")];
                    });
                }];
                [task resume];
            } else if (response.status == YTKACEVOTStatusWaiting || response.status == YTKACEVOTStatusLongWaiting) {
                NSInteger sec = response.remainingTime > 0 ? response.remainingTime : 10;
                NSString *msg = [NSString stringWithFormat:YTKACELocalized(@"Wait %ld sec..."), (long)sec];
                [weakSelf showCompactNotice:msg];
            } else {
                [weakSelf showCompactNotice:YTKACELocalized(@"Translation failed")];
            }
        });
    }];
}

- (void)showCompactNotice:(NSString *)message {
    YTKACEShowNotice(message);
}

- (void)showCopyInformationMenuFromView:(UIView *)sourceView {
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTKACELocalized(@"Copy Title") icon:@"textformat"
            secondary:nil handler:^{
                UIPasteboard.generalPasteboard.string =
                    [YTKACEStreamResolver titleFromPlayerResponse:weakSelf.playerResponse];
                [weakSelf showCompactNotice:YTKACELocalized(@"Title copied")];
            }],
        [self sheetAction:YTKACELocalized(@"Copy Description") icon:@"line.3.horizontal"
            secondary:nil handler:^{
                NSString *description = [YTKACEStreamResolver
                    descriptionFromPlayerResponse:weakSelf.playerResponse];
                if (description.length == 0) {
                    [weakSelf showCompactNotice:YTKACELocalized(@"No description found")];
                } else {
                    UIPasteboard.generalPasteboard.string = description;
                    [weakSelf showCompactNotice:YTKACELocalized(@"Description copied")];
                }
            }]
    ];
    [self presentNativeSheetWithTitle:nil subtitle:nil
        sourceView:sourceView actions:actions];
}

- (void)showExternalPlayerMenuFromView:(UIView *)sourceView {
    YTKACEStreamOption *option =
        [YTKACEStreamResolver bestPiPVideoFromPlayerResponse:self.playerResponse];
    if (option.URL == nil) {
        [self showAlertWithTitle:YTKACELocalized(@"External Player")
                         message:YTKACELocalized(@"No playable stream is available.")];
        return;
    }
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSString *escaped = [option.URL.absoluteString
        stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet];
    NSArray *actions = @[
        [self sheetAction:YTKACELocalized(@"System Player") icon:@"ytkace.system"
            secondary:nil handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf playInSystemPlayer:option.URL sourceView:sourceView];
                    });
            }],
        [self sheetAction:YTKACELocalized(@"Infuse") icon:@"ytkace.infuse"
            secondary:nil handler:^{
                NSURL *url = [NSURL URLWithString:[NSString
                    stringWithFormat:@"infuse://x-callback-url/play?url=%@",
                    escaped ?: @""]];
                [UIApplication.sharedApplication openURL:url options:@{}
                    completionHandler:^(BOOL success) {
                        if (!success) {
                            [weakSelf showAlertWithTitle:YTKACELocalized(@"Infuse")
                                message:YTKACELocalized(@"Infuse is not installed.")];
                        }
                    }];
            }],
        [self sheetAction:YTKACELocalized(@"VLC") icon:@"ytkace.vlc"
            secondary:nil handler:^{
                NSURL *url = [NSURL URLWithString:[NSString
                    stringWithFormat:@"vlc-x-callback://x-callback-url/stream?url=%@",
                    escaped ?: @""]];
                [UIApplication.sharedApplication openURL:url options:@{}
                    completionHandler:^(BOOL success) {
                        if (!success) {
                            [weakSelf showAlertWithTitle:YTKACELocalized(@"VLC")
                                message:YTKACELocalized(@"VLC is not installed.")];
                        }
                    }];
            }]
    ];
    [self presentNativeSheetWithTitle:YTKACELocalized(@"External Player") subtitle:nil
        sourceView:sourceView actions:actions];
}

- (double)mediaTimeFromObject:(id)object {
    for (NSString *name in @[@"currentVideoMediaTime", @"currentVideoTime",
                              @"currentMediaTime", @"mediaTime"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([object class], selector);
        if (method == NULL) {
            continue;
        }
        char type[16] = {};
        method_getReturnType(method, type, sizeof(type));
        if (strcmp(type, @encode(double)) == 0) {
            return ((double (*)(id, SEL))objc_msgSend)(object, selector);
        }
        if (strcmp(type, @encode(float)) == 0) {
            return ((float (*)(id, SEL))objc_msgSend)(object, selector);
        }
    }
    return 0.0;
}

- (void)playInSystemPlayer:(NSURL *)URL sourceView:(UIView *)sourceView {
    if (URL == nil) {
        return;
    }
    double mediaTime = 0.0;
    UIViewController *presenter = nil;
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 20; depth++) {
        if (mediaTime <= 0.0) {
            mediaTime = [self mediaTimeFromObject:current];
        }
        for (NSString *name in @[@"pauseVideo", @"pausePlayback", @"pause"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod([current class], selector);
            if (method != NULL && method_getNumberOfArguments(method) == 2) {
                ((void (*)(id, SEL))objc_msgSend)(current, selector);
                break;
            }
        }
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([current respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(current, eventsSelector);
            if (mediaTime <= 0.0) {
                mediaTime = [self mediaTimeFromObject:events];
                SEL parentSelector = NSSelectorFromString(@"parentResponder");
                if ([events respondsToSelector:parentSelector]) {
                    id parent = ((id (*)(id, SEL))objc_msgSend)(events, parentSelector);
                    mediaTime = MAX(mediaTime, [self mediaTimeFromObject:parent]);
                }
            }
            if ([events isKindOfClass:UIViewController.class]) {
                presenter = events;
            }
        }
        if (presenter == nil && [current isKindOfClass:UIViewController.class]) {
            presenter = (UIViewController *)current;
        }
        current = current.nextResponder;
    }
    presenter = presenter ?: [self topViewController];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    if (![NSUserDefaults.standardUserDefaults
            boolForKey:@"YTKACE.Preference.Downloads.SubtitlesHidden"]) {
        NSString *key = @"availableMediaCharacteristicsWithMediaSelectionOptions";
        [asset loadValuesAsynchronouslyForKeys:@[key] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                AVMediaSelectionGroup *group = [asset
                    mediaSelectionGroupForMediaCharacteristic:
                        AVMediaCharacteristicLegible];
                if (group == nil) {
                    YTKACEDownloadLog(@"subs", @"default player no legible group");
                    return;
                }
                for (AVMediaSelectionOption *option in group.options) {
                    if (option.displayName.length == 0) continue;
                    if ([option hasMediaCharacteristic:
                            AVMediaCharacteristicContainsOnlyForcedSubtitles]) {
                        continue;
                    }
                    [item selectMediaOption:option inMediaSelectionGroup:group];
                    YTKACEDownloadLog(@"subs", @"default player selected %@",
                                      option.displayName);
                    return;
                }
                YTKACEDownloadLog(@"subs", @"default player %lu options, none used",
                                  (unsigned long)group.options.count);
            });
        }];
    }
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    AVPlayerViewController *controller = [AVPlayerViewController new];
    controller.player = player;
    controller.showsPlaybackControls = YES;
    controller.allowsPictureInPicturePlayback = YES;
    if (mediaTime > 0.0) {
        [player seekToTime:CMTimeMakeWithSeconds(mediaTime, NSEC_PER_SEC)
           toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    [presenter presentViewController:controller animated:YES completion:^{
        [player play];
    }];
}

- (void)saveThumbnail {
    NSURL *url = [YTKACEStreamResolver thumbnailURLFromPlayerResponse:self.playerResponse];
    if (url == nil) {
        [self showAlertWithTitle:YTKACELocalized(@"Save Image") message:YTKACELocalized(@"No thumbnail is available.")];
        return;
    }
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            UIImage *image = error == nil ? [UIImage imageWithData:data] : nil;
            if (image == nil) {
                [weakSelf showAlertWithTitle:YTKACELocalized(@"Save Image")
                    message:error.localizedDescription ?: YTKACELocalized(@"The image could not be loaded.")];
                return;
            }
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            } completionHandler:^(BOOL success, NSError *saveError) {
                if (success) {
                    [weakSelf showCompactNotice:YTKACELocalized(@"Image saved")];
                } else {
                    [weakSelf showAlertWithTitle:YTKACELocalized(@"Save Image")
                        message:saveError.localizedDescription ?:
                            YTKACELocalized(@"The image could not be saved.")];
                }
            }];
        }];
    [task resume];
}

- (UIViewController *)shortsControllerFromView:(UIView *)sourceView {
    UIResponder *responder = sourceView.nextResponder;
    UIViewController *controller = nil;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller = (UIViewController *)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    while (controller != nil) {
        if (shortsClass != Nil && [controller isKindOfClass:shortsClass]) {
            return controller;
        }
        controller = controller.parentViewController;
    }
    return nil;
}

- (void)toggleShortsFullscreenFromView:(UIView *)sourceView {
    UIViewController *controller = [self shortsControllerFromView:sourceView];
    if (controller == nil) {
        UIView *container = YTKACEShortsContainerForView(sourceView, sourceView.window);
        if (container == nil) return;
        YTKACESetShortsNewFullscreen(container, !YTKACEShortsGlobalFullscreen);
        return;
    }
    if (controller != nil) {
            BOOL fullscreen = [objc_getAssociatedObject(
                controller, YTKACEShortsFullscreenKey) boolValue];
            id pivotController = controller.navigationController.parentViewController;
            SEL pivotSelector = NSSelectorFromString(
                fullscreen ? @"showPivotBar" : @"hidePivotBar");
            if ([pivotController respondsToSelector:pivotSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(pivotController, pivotSelector);
            }
            id shortsView = controller.view;
            SEL overlaySelector = NSSelectorFromString(@"playbackOverlay");
            id overlay = [shortsView respondsToSelector:overlaySelector]
                ? ((id (*)(id, SEL))objc_msgSend)(shortsView, overlaySelector) : nil;
            UIView *container = [overlay isKindOfClass:UIView.class]
                ? nil : YTKACEShortsContainerForView(sourceView, controller.view);
            [UIView animateWithDuration:0.3 animations:^{
                if ([overlay isKindOfClass:UIView.class]) {
                    YTKACESetShortsOverlayFullscreen(
                        (UIView *)overlay, !fullscreen);
                } else if (container != nil) {
                    YTKACESetShortsElementsFullscreen(container, !fullscreen);
                }
            }];
            objc_setAssociatedObject(controller, YTKACEShortsFullscreenKey, @(!fullscreen),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (NSNumber *delay in @[@0.05, @0.20]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [controller.view setNeedsLayout];
                        [controller.view layoutIfNeeded];
                    });
            }
            return;
    }
}

- (void)presentShortsDownloadMenuFromView:(UIView *)sourceView
                                  response:(id)response {
    if (!YTKACEDownloadsEnabled() || response == nil) {
        [self showAlertWithTitle:@"YTKACE" message:YTKACELocalized(@"No active Short was found.")];
        return;
    }
    self.playerResponse = response;
    self.downloadSourceView = sourceView;
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    UIImage *chevron = [self menuIcon:@"chevron.right"];
    BOOL autoSkip = YTKACEFeatureEnabled(@"autoSkipShorts");
    UIViewController *shortsController = [self shortsControllerFromView:sourceView];
    BOOL fullscreen = shortsController != nil
        ? [objc_getAssociatedObject(shortsController, YTKACEShortsFullscreenKey) boolValue]
        : YTKACEShortsGlobalFullscreen;
    NSString *fullscreenTitle = fullscreen ? YTKACELocalized(@"Exit Fullscreen") : YTKACELocalized(@"Fullscreen");
    NSString *fullscreenIcon = fullscreen
        ? @"arrow.down.right.and.arrow.up.left"
        : @"arrow.up.left.and.arrow.down.right";
    NSArray *actions = @[
        [self sheetAction:YTKACELocalized(@"Download Video") icon:@"play"
            secondary:chevron handler:^{
                [weakSelf resolveSaveDestinationFromView:sourceView then:^{
                    [weakSelf startVideoDownloadForCategory:@"Shorts"];
                }];
            }],
        [self sheetAction:YTKACELocalized(@"Download Audio") icon:@"music.note"
            secondary:chevron handler:^{
                [weakSelf resolveAudioDestinationFromView:sourceView then:^{
                    [weakSelf startAudioDownload];
                }];
            }],
        [self sheetAction:fullscreenTitle icon:fullscreenIcon
            secondary:chevron handler:^{
                [weakSelf toggleShortsFullscreenFromView:sourceView];
            }],
        [self sheetAction:YTKACELocalized(@"Auto-Skip") icon:@"forward.end.fill"
            secondary:[self menuIcon:autoSkip ? @"checkmark.square" : @"square"]
            handler:^{ YTKACESetPreference(@"autoSkipShorts", !autoSkip); }]
    ];
    [self presentNativeSheetWithTitle:
        [YTKACEStreamResolver authorFromPlayerResponse:self.playerResponse]
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:sourceView actions:actions];
}

- (NSString *)activeReelVideoIDFromView:(UIView *)sourceView {
    SEL activeSelector = NSSelectorFromString(@"activeReelPlaybackVideoID");
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 16; depth++) {
        if ([current respondsToSelector:activeSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(current, activeSelector);
            if ([value isKindOfClass:NSString.class] && [value length] != 0) {
                return value;
            }
        }
        current = current.nextResponder;
    }
    return nil;
}

- (id)reelModelFromView:(UIView *)sourceView {
    SEL contentModel = NSSelectorFromString(@"contentModel");
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 14; depth++) {
        if ([current respondsToSelector:contentModel]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(current, contentModel);
            if (model != nil) return model;
        }
        current = current.nextResponder;
    }
    return nil;
}

- (void)showShortsDownloadMenuFromView:(UIView *)sourceView {
    id currentResponse = [self tracedPlayerResponseFromView:sourceView];
    if (currentResponse != nil) {
        [self presentShortsDownloadMenuFromView:sourceView
                                       response:currentResponse];
        return;
    }

    id reel = [self reelModelFromView:sourceView];
    NSString *reelID = nil;
    SEL videoSelector = NSSelectorFromString(@"videoId");
    if ([reel respondsToSelector:videoSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(reel, videoSelector);
        if ([value isKindOfClass:NSString.class]) reelID = value;
    }
    NSString *activeID = [self activeReelVideoIDFromView:sourceView];
    NSString *videoID = activeID.length != 0 ? activeID : reelID;

    id cached = YTKACECachedPlayerResponse(videoID);
    if (cached != nil) {
        [self presentShortsDownloadMenuFromView:sourceView response:cached];
        return;
    }

    SEL overrideSelector = NSSelectorFromString(@"playerResponseOverride");
    BOOL reelIsCurrent = reelID.length != 0 &&
        (activeID.length == 0 || [reelID isEqualToString:activeID]);
    if (reelIsCurrent && [reel respondsToSelector:overrideSelector]) {
        id override = ((id (*)(id, SEL))objc_msgSend)(reel, overrideSelector);
        if (override != nil) {
            [self presentShortsDownloadMenuFromView:sourceView response:override];
            return;
        }
    }
    if (videoID.length == 0) {
        [self presentShortsDownloadMenuFromView:sourceView response:nil];
        return;
    }

    __weak YTKACEDownloadCoordinator *weakSelf = self;
    __weak UIView *weakSource = sourceView;
    YTKACEPreparePlayerWithRoute(videoID, NO, ^(id playerResponse,
                                                __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEDownloadCoordinator *strongSelf = weakSelf;
            UIView *strongSource = weakSource;
            if (strongSelf == nil || strongSource == nil) return;
            NSString *resolvedID = [YTKACEStreamResolver
                videoIDFromPlayerResponse:playerResponse];
            BOOL matched = playerResponse != nil &&
                (resolvedID.length == 0 ||
                 [resolvedID isEqualToString:videoID]);
            if (matched) {
                YTKACEStorePlayerResponse(videoID, playerResponse);
                [strongSelf presentShortsDownloadMenuFromView:strongSource
                    response:playerResponse];
                return;
            }
            YTKACEPreparePlayerWithRoute(videoID, YES, ^(id retryResponse,
                                                        __unused NSError *retryError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    YTKACEDownloadCoordinator *retrySelf = weakSelf;
                    UIView *retrySource = weakSource;
                    if (retrySelf == nil || retrySource == nil) return;
                    NSString *retryID = [YTKACEStreamResolver
                        videoIDFromPlayerResponse:retryResponse];
                    BOOL retryMatched = retryResponse != nil &&
                        (retryID.length == 0 ||
                         [retryID isEqualToString:videoID]);
                    if (retryMatched) {
                        YTKACEStorePlayerResponse(videoID, retryResponse);
                    }
                    [retrySelf presentShortsDownloadMenuFromView:retrySource
                        response:retryMatched ? retryResponse : nil];
                });
            });
        });
    });
}

- (BOOL)loadDirectOptionsThen:(dispatch_block_t)continuation {
    if (!YTKACEDirectDownloadsEnabled()) {
        self.directOptions = nil;
        return NO;
    }
    NSString *videoID = [YTKACEStreamResolver videoIDFromPlayerResponse:self.playerResponse];
    if (videoID.length != 0 && [videoID isEqualToString:self.directOptionsVideoID]) return NO;
    self.directOptionsVideoID = videoID;
    self.directOptions = nil;
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    [YTKACEDirectDownloader fetchOptionsForVideoID:videoID completion:^(NSArray *options) {
        weakSelf.directOptions = options;
        continuation();
    }];
    return YES;
}

- (BOOL)isStableVolumeOption:(YTKACEStreamOption *)option {
    if (option.xtags.length == 0) return NO;
    NSString *padded = [option.xtags stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    padded = [padded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (padded.length % 4 != 0) padded = [padded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:padded options:0];
    NSString *text = data == nil ? nil :
        [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    return [text containsString:@"drc"];
}

- (NSString *)sizeTextForOption:(YTKACEStreamOption *)option {
    return option.contentLength > 0
        ? [NSByteCountFormatter stringFromByteCount:option.contentLength
            countStyle:NSByteCountFormatterCountStyleFile] : YTKACELocalized(@"Unknown size");
}

- (void)presentDirectVideoMenuForCategory:(NSString *)category {
    NSArray<NSString *> *codecOrder = @[@"H.264", @"VP9", @"AV1"];
    NSMutableArray<YTKACEStreamOption *> *videos = [NSMutableArray array];
    BOOL vp9 = VTIsHardwareDecodeSupported('vp09');
    BOOL av1 = VTIsHardwareDecodeSupported('av01');
    for (YTKACEStreamOption *option in self.directOptions) {
        if (option.audioOnly || option.height <= 0) continue;
        NSString *codec = [YTKACEDirectDownloader codecNameForOption:option];
        if ([codec isEqualToString:@"VP9"] && !vp9) continue;
        if ([codec isEqualToString:@"AV1"] && !av1) continue;
        [videos addObject:option];
    }
    [videos sortUsingComparator:^NSComparisonResult(YTKACEStreamOption *left,
                                                    YTKACEStreamOption *right) {
        if (left.height != right.height) {
            return left.height > right.height ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL leftHigh = [left.qualityLabel hasSuffix:@"60"];
        BOOL rightHigh = [right.qualityLabel hasSuffix:@"60"];
        if (leftHigh != rightHigh) return leftHigh ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger leftCodec = [codecOrder indexOfObject:[YTKACEDirectDownloader codecNameForOption:left]];
        NSUInteger rightCodec = [codecOrder indexOfObject:[YTKACEDirectDownloader codecNameForOption:right]];
        return leftCodec < rightCodec ? NSOrderedAscending :
            (leftCodec > rightCodec ? NSOrderedDescending : NSOrderedSame);
    }];
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTKACEStreamOption *option in videos) {
        NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
            option.qualityLabel.length != 0 ? option.qualityLabel
                : [NSString stringWithFormat:@"%ldp", (long)option.height],
            [YTKACEDirectDownloader codecNameForOption:option], [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"play" secondary:nil handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [weakSelf showAudioLanguagesForVideo:option audioOnly:NO category:category];
                });
        }]];
    }
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Video Quality")
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)presentDirectAudioMenuForVideo:(YTKACEStreamOption *)videoOption
                             audioOnly:(BOOL)audioOnly
                              category:(NSString *)category {
    NSMutableArray<YTKACEStreamOption *> *audios = [NSMutableArray array];
    for (YTKACEStreamOption *option in self.directOptions) {
        if (option.audioOnly) [audios addObject:option];
    }
    [audios sortUsingComparator:^NSComparisonResult(YTKACEStreamOption *left,
                                                    YTKACEStreamOption *right) {
        if (left.isDefaultAudio != right.isDefaultAudio) {
            return left.isDefaultAudio ? NSOrderedAscending : NSOrderedDescending;
        }
        NSComparisonResult language = [left.languageLabel compare:right.languageLabel];
        if (language != NSOrderedSame) return language;
        BOOL leftStable = [self isStableVolumeOption:left];
        BOOL rightStable = [self isStableVolumeOption:right];
        if (leftStable != rightStable) return leftStable ? NSOrderedDescending : NSOrderedAscending;
        return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
    }];
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTKACEStreamOption *option in audios) {
        NSString *stable = [self isStableVolumeOption:option]
            ? [@" · " stringByAppendingString:YTKACELocalized(@"Stable volume")] : @"";
        NSString *title = [NSString stringWithFormat:@"%@ · %@ %ld kbps%@ · %@",
            option.languageLabel, [YTKACEDirectDownloader codecNameForOption:option],
            (long)(option.bitrate / 1000), stable, [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"music.note" secondary:nil handler:^{
            [weakSelf beginSABRDownloadVideo:videoOption audio:option
                                   audioOnly:audioOnly category:category];
        }]];
    }
    NSMutableSet<NSString *> *directLanguages = [NSMutableSet set];
    for (YTKACEStreamOption *option in audios) {
        [directLanguages addObject:option.languageLabel.lowercaseString ?: @""];
    }
    for (YTKACEStreamOption *option in
         [YTKACEStreamResolver audioOptionsFromPlayerResponse:self.playerResponse]) {
        NSString *language = option.languageLabel.lowercaseString ?: @"";
        BOOL covered = NO;
        for (NSString *direct in directLanguages) {
            if ([direct isEqualToString:language] ||
                (direct.length != 0 && language.length != 0 &&
                 ([direct hasPrefix:language] || [language hasPrefix:direct]))) {
                covered = YES;
                break;
            }
        }
        if (covered) continue;
        NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
            option.languageLabel, YTKACELocalized(@"via SABR"), [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"music.note" secondary:nil handler:^{
            weakSelf.forceSABRNext = YES;
            [weakSelf beginSABRDownloadVideo:videoOption audio:option
                                   audioOnly:audioOnly category:category];
        }]];
    }
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Audio Language")
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)startVideoDownloadForCategory:(NSString *)category {
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    if ([self loadDirectOptionsThen:^{ [weakSelf startVideoDownloadForCategory:category]; }]) {
        return;
    }
    if (self.directOptions.count != 0) {
        [self presentDirectVideoMenuForCategory:category];
        return;
    }
    NSArray<YTKACEStreamOption *> *options =
        [YTKACEStreamResolver videoOptionsFromPlayerResponse:self.playerResponse];
    YTKACEDownloadLog(@"resolver", @"video menu count=%lu category=%@",
        (unsigned long)options.count, category);
    if (options.count == 0) {
        [self showAlertWithTitle:YTKACELocalized(@"Download unavailable")
                         message:YTKACELocalized(@"No compatible video formats were found.")];
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (YTKACEStreamOption *option in options) {
        NSString *size = option.contentLength > 0
            ? [NSByteCountFormatter stringFromByteCount:option.contentLength
                countStyle:NSByteCountFormatterCountStyleFile] : YTKACELocalized(@"Unknown size");
        NSString *title = [NSString stringWithFormat:@"%@ (mp4) · %@",
            option.qualityLabel.length != 0 ? option.qualityLabel : YTKACELocalized(@"Video"), size];
        [actions addObject:[self sheetAction:title icon:@"play"
            secondary:nil handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf showAudioLanguagesForVideo:option audioOnly:NO
                            category:category];
                    });
            }]];
    }
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Video Quality")
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)startAudioDownload {
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    if ([self loadDirectOptionsThen:^{ [weakSelf startAudioDownload]; }]) return;
    [self showAudioLanguagesForVideo:nil audioOnly:YES category:@"Audio"];
}

- (void)showAudioLanguagesForVideo:(YTKACEStreamOption *)videoOption
                         audioOnly:(BOOL)audioOnly
                          category:(NSString *)category {
    if (self.directOptions.count != 0) {
        [self presentDirectAudioMenuForVideo:videoOption audioOnly:audioOnly category:category];
        return;
    }
    NSArray<YTKACEStreamOption *> *options =
        [YTKACEStreamResolver audioOptionsFromPlayerResponse:self.playerResponse];
    if (options.count == 0) {
        [self showAlertWithTitle:YTKACELocalized(@"Download unavailable")
                         message:YTKACELocalized(@"No compatible audio formats were found.")];
        return;
    }
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTKACEStreamOption *option in options) {
        NSString *size = option.contentLength > 0
            ? [NSByteCountFormatter stringFromByteCount:option.contentLength
                countStyle:NSByteCountFormatterCountStyleFile] : YTKACELocalized(@"Unknown size");
        NSString *defaultText = option.isDefaultAudio ? YTKACELocalized(@" (Default)") : @"";
        NSString *title = [NSString stringWithFormat:@"%@%@ · %@",
            option.languageLabel, defaultText, size];
        [actions addObject:[self sheetAction:title icon:@"music.note"
            secondary:nil handler:^{
                [weakSelf beginSABRDownloadVideo:videoOption
                    audio:option audioOnly:audioOnly category:category];
            }]];
    }
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Audio Language")
        subtitle:[YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)beginSABRDownloadVideo:(YTKACEStreamOption *)videoOption
                         audio:(YTKACEStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                      category:(NSString *)category {
    if (videoOption == nil) {
        videoOption = [YTKACEStreamResolver
            videoOptionsFromPlayerResponse:self.playerResponse].firstObject;
    }
    if (videoOption == nil || audioOption == nil) {
        [self showAlertWithTitle:YTKACELocalized(@"Download unavailable")
                         message:YTKACELocalized(@"The selected formats are unavailable.")];
        return;
    }
    id response = self.playerResponse;
    YTKACEDownloadJob *job = [YTKACEDownloadJob new];
    job.identifier = NSUUID.UUID.UUIDString;
    job.title = [self safeFilename:
        [YTKACEStreamResolver titleFromPlayerResponse:response]];
    job.author = [YTKACEStreamResolver authorFromPlayerResponse:response];
    job.videoID = [YTKACEStreamResolver videoIDFromPlayerResponse:response] ?: @"";
    job.thumbnailURL = [YTKACEStreamResolver thumbnailURLFromPlayerResponse:response];
    job.category = audioOnly ? @"Audio" : category;
    job.playerResponse = response;
    job.videoOption = videoOption;
    job.audioOption = audioOption;
    job.audioOnly = audioOnly;
    job.savesToPhotos = self.pendingSavesToPhotos;
    job.sharesFile = self.pendingSharesFile;
    job.useDirect = YTKACEDirectDownloadsEnabled() && !self.forceSABRNext;
    self.forceSABRNext = NO;
    if (!job.useDirect && self.directOptions.count != 0 &&
        ![self prepareSABRFallbackForJob:job]) {
        [self showAlertWithTitle:YTKACELocalized(@"Download unavailable")
                         message:YTKACELocalized(@"The selected formats are unavailable.")];
        return;
    }
    YTKACEDownloadLog(job.identifier, @"destination photos=%d share=%d",
        job.savesToPhotos, job.sharesFile);
    [self chooseCaptionsForJob:job then:^{
        [self launchJob:job];
    }];
}

- (void)launchJob:(YTKACEDownloadJob *)job {
    {
        if (self.retryableJobs == nil) self.retryableJobs = [NSMutableDictionary dictionary];
        if (self.retryableJobs.count >= 24) [self.retryableJobs removeAllObjects];
        self.retryableJobs[job.identifier] = job;
        self.activeJobs[job.identifier] = job;
        [YTKACEDownloadProgressView.sharedView beginJob:job.identifier
            title:job.title thumbnailURL:job.thumbnailURL];
        YTKACEDownloadLog(job.identifier,
            @"queued title=%@ author=%@ category=%@ audioOnly=%d active=%lu",
            job.title, job.author, job.category, job.audioOnly,
            (unsigned long)self.activeJobs.count);
        [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTKACELocalized(@"Preparing download") progress:0.0 downloadedBytes:0 totalBytes:0];
        if (job.useDirect) {
            [self startDirectJob:job];
        } else {
            [self startSABRJob:job];
        }
    }
}

- (void)retryJobWithIdentifier:(NSString *)identifier {
    YTKACEDownloadJob *old = self.retryableJobs[identifier];
    if (old == nil) {
        YTKACEShowNotice(YTKACELocalized(@"Download unavailable"));
        return;
    }
    [self.retryableJobs removeObjectForKey:identifier];
    YTKACEDownloadJob *job = [YTKACEDownloadJob new];
    job.identifier = NSUUID.UUID.UUIDString;
    job.title = old.title;
    job.author = old.author;
    job.videoID = old.videoID;
    job.thumbnailURL = old.thumbnailURL;
    job.category = old.category;
    job.playerResponse = old.playerResponse;
    job.videoOption = old.videoOption;
    job.audioOption = old.audioOption;
    job.audioOnly = old.audioOnly;
    job.savesToPhotos = old.savesToPhotos;
    job.sharesFile = old.sharesFile;
    job.useDirect = old.useDirect;
    job.captionURL = old.captionURL;
    job.captionLanguage = old.captionLanguage;
    YTKACEDownloadLog(job.identifier, @"retry of %@", identifier);
    [self launchJob:job];
}

- (void)chooseCaptionsForJob:(YTKACEDownloadJob *)job
                        then:(dispatch_block_t)handler {
    if (job.audioOnly ||
        !YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.Subtitles")) {
        handler();
        return;
    }
    NSArray<NSDictionary *> *choices =
        YTKACECaptionChoicesForResponse(job.playerResponse);
    if (choices.count == 0) {
        YTKACEDownloadLog(@"subs", @"no caption tracks for %@", job.videoID);
        handler();
        return;
    }
    if (choices.count == 1) {
        job.captionURL = choices.firstObject[@"url"];
        job.captionLanguage = choices.firstObject[@"language"];
        handler();
        return;
    }
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    for (NSDictionary *choice in choices) {
        [actions addObject:@{
            @"title": choice[@"label"],
            @"handler": ^{
                job.captionURL = choice[@"url"];
                job.captionLanguage = choice[@"language"];
                handler();
            }
        }];
    }
    [actions addObject:@{
        @"title": YTKACELocalized(@"No Subtitles"),
        @"handler": ^{ handler(); }
    }];
    UIView *anchor = self.downloadSourceView ?: self.externalSourceView;
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Subtitles")
                             subtitle:YTKACELocalized(@"Choose a caption track")
                           sourceView:[self sheetAnchorForView:anchor]
                              actions:actions];
}

- (NSDictionary *)nativeSheetAction:(NSString *)title
                               icon:(NSString *)icon
                            handler:(dispatch_block_t)handler {
    return [self sheetAction:title icon:icon secondary:nil handler:handler];
}

- (void)presentPlaylistSheetWithTitle:(NSString *)title
                             subtitle:(NSString *)subtitle
                           sourceView:(UIView *)sourceView
                              actions:(NSArray<NSDictionary *> *)actions {
    [self presentNativeSheetWithTitle:title subtitle:subtitle
                           sourceView:sourceView actions:actions];
}

- (NSUInteger)activeJobCount {
    return self.activeJobs.count;
}

- (void)resolvePlaylistDestinationFromView:(UIView *)sourceView
                                 audioOnly:(BOOL)audioOnly
                                      then:(void (^)(BOOL, BOOL))handler {
    NSString *key = audioOnly ? YTKACEAudioSaveLocationKey
                              : YTKACESaveLocationKey;
    const NSInteger mode =
        [NSUserDefaults.standardUserDefaults integerForKey:key];
    YTKACEDownloadLog(@"save", @"playlist destination mode=%ld audio=%d",
        (long)mode, audioOnly);
    if (mode != 2) {
        handler(mode == 1, mode == 3);
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[self sheetAction:YTKACELocalized(@"YTKACE Library")
        icon:@"arrow.down.circle" secondary:nil
        handler:^{ handler(NO, NO); }]];
    [actions addObject:[self sheetAction:YTKACELocalized(@"Photos")
        icon:@"photo.on.rectangle" secondary:nil
        handler:^{ handler(YES, NO); }]];
    [actions addObject:[self sheetAction:YTKACELocalized(@"Share Sheet")
        icon:@"square.and.arrow.up" secondary:nil
        handler:^{ handler(NO, YES); }]];
    [self presentNativeSheetWithTitle:YTKACELocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (BOOL)enqueueDownloadForResponse:(id)response
                           quality:(NSInteger)quality
                         audioOnly:(BOOL)audioOnly
                     savesToPhotos:(BOOL)savesToPhotos
                        sharesFile:(BOOL)sharesFile {
    if (response == nil) return NO;
    YTKACEStreamOption *audio =
        [YTKACEStreamResolver audioOptionsFromPlayerResponse:response].firstObject;
    if (audio == nil) return NO;
    YTKACEStreamOption *video = nil;
    if (!audioOnly) {
        NSArray<YTKACEStreamOption *> *options =
            [YTKACEStreamResolver videoOptionsFromPlayerResponse:response];
        if (options.count == 0) return NO;
        if (quality > 0) {
            for (YTKACEStreamOption *option in options) {
                if (option.height <= quality) {
                    video = option;
                    break;
                }
            }
        }
        if (video == nil) video = options.firstObject;
    }
    id previousResponse = self.playerResponse;
    BOOL previousPhotos = self.pendingSavesToPhotos;
    BOOL previousShare = self.pendingSharesFile;
    self.playerResponse = response;
    self.pendingSavesToPhotos = savesToPhotos;
    self.pendingSharesFile = sharesFile;
    [self beginSABRDownloadVideo:video audio:audio audioOnly:audioOnly
                        category:audioOnly ? @"Audio" : @"Video"];
    self.playerResponse = previousResponse;
    self.pendingSavesToPhotos = previousPhotos;
    self.pendingSharesFile = previousShare;
    return YES;
}

- (YTKACEStreamOption *)fallbackVideoForJob:(YTKACEDownloadJob *)job {
    if (job.fallbackCount >= 3) return nil;
    NSArray<YTKACEStreamOption *> *options =
        [YTKACEStreamResolver videoOptionsFromPlayerResponse:job.playerResponse];
    NSInteger currentIndex = NSNotFound;
    for (NSUInteger index = 0; index < options.count; index++) {
        YTKACEStreamOption *option = options[index];
        if (option.itag == job.videoOption.itag &&
            [option.xtags isEqualToString:job.videoOption.xtags]) {
            currentIndex = (NSInteger)index;
            break;
        }
    }
    if (currentIndex == NSNotFound) return nil;
    for (NSUInteger index = (NSUInteger)currentIndex + 1; index < options.count; index++) {
        YTKACEStreamOption *option = options[index];
        if (option.itag != job.videoOption.itag) return option;
    }
    return nil;
}

- (void)reportProgressForJob:(YTKACEDownloadJob *)job
               audioProgress:(double)audioProgress
               videoProgress:(double)videoProgress
                  audioBytes:(int64_t)audioBytes
                  videoBytes:(int64_t)videoBytes
                       phase:(NSInteger)mediaPhase {
    job.audioBytes = audioBytes;
    job.videoBytes = videoBytes;
    int64_t audioTotal = MAX((int64_t)job.audioOption.contentLength, 0);
    int64_t videoTotal = job.audioOnly ? 0 :
        MAX((int64_t)job.videoOption.contentLength, 0);
    int64_t downloaded = audioBytes + (job.audioOnly ? 0 : videoBytes);
    int64_t total = audioTotal + videoTotal;
    double transferProgress = 0.0;
    if (total > 0) {
        transferProgress = (double)downloaded / (double)total;
    } else if (job.audioOnly) {
        transferProgress = audioProgress;
    } else {
        transferProgress = audioProgress * 0.08 + videoProgress * 0.92;
    }
    transferProgress = MIN(MAX(transferProgress, 0.0), 1.0);
    NSString *stage = job.audioOnly || mediaPhase == 1
        ? YTKACELocalized(@"Downloading audio") : YTKACELocalized(@"Downloading video");
    [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
        stage:stage progress:transferProgress * 0.95
        downloadedBytes:downloaded totalBytes:total];
}

- (void)completeJob:(YTKACEDownloadJob *)job
           videoURL:(NSURL *)videoURL
           audioURL:(NSURL *)audioURL {
    if (job.audioOnly) {
        if (videoURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:videoURL error:nil];
        }
        [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTKACELocalized(@"Finalizing") progress:0.96
            downloadedBytes:job.audioBytes totalBytes:job.audioBytes];
        NSURL *output = [audioURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:@"final.m4a"];
        YTKACEDownloadLog(job.identifier, @"audio remux start");
        [YTKACEFFmpegMuxer remuxAudioURL:audioURL outputURL:output
            completion:^(NSError *remuxError) {
                if (remuxError != nil) {
                    [YTKACEDownloadProgressView.sharedView
                        finishJob:job.identifier success:NO message:YTKACELocalized(@"Failed")];
                    YTKACEDownloadLog(job.identifier,
                        @"audio remux failed error=%@",
                        remuxError.localizedDescription);
                    [NSFileManager.defaultManager
                        removeItemAtURL:audioURL.URLByDeletingLastPathComponent
                        error:nil];
                    [self showAlertWithTitle:YTKACELocalized(@"Download failed")
                        message:[self failureMessageForError:remuxError
                            job:job]];
                    [self.activeJobs removeObjectForKey:job.identifier];
                    return;
                }
                [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
                YTKACEDownloadLog(job.identifier, @"audio remux complete");
                [self saveCompletedURL:output job:job extension:@"m4a"];
            }];
        return;
    }
    [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
        stage:YTKACELocalized(@"Merging") progress:0.96
        downloadedBytes:job.audioBytes + job.videoBytes
        totalBytes:job.audioBytes + job.videoBytes];
    [self mergeVideoURL:videoURL audioURL:audioURL job:job];
}

- (BOOL)prepareSABRFallbackForJob:(YTKACEDownloadJob *)job {
    NSArray<YTKACEStreamOption *> *audios =
        [YTKACEStreamResolver audioOptionsFromPlayerResponse:job.playerResponse];
    YTKACEStreamOption *audio = nil;
    for (YTKACEStreamOption *option in audios) {
        if ([option.languageLabel isEqualToString:job.audioOption.languageLabel]) {
            audio = option;
            break;
        }
    }
    audio = audio ?: audios.firstObject;
    if (audio == nil) return NO;
    YTKACEStreamOption *video = nil;
    if (!job.audioOnly) {
        NSArray<YTKACEStreamOption *> *videos =
            [YTKACEStreamResolver videoOptionsFromPlayerResponse:job.playerResponse];
        for (YTKACEStreamOption *option in videos) {
            if (option.height <= job.videoOption.height) {
                video = option;
                break;
            }
        }
        video = video ?: videos.lastObject;
        if (video == nil) return NO;
    }
    job.audioOption = audio;
    job.videoOption = video ?: job.videoOption;
    return YES;
}

- (void)startDirectJob:(YTKACEDownloadJob *)job {
    if (job.cancelled) return;
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    job.directTask = [YTKACEDirectDownloader downloadVideoID:job.videoID
        videoOption:job.audioOnly ? nil : job.videoOption audioOption:job.audioOption
        audioOnly:job.audioOnly identifier:job.identifier
        progress:^(double audioProgress, double videoProgress,
                   int64_t audioBytes, int64_t videoBytes, NSInteger mediaPhase) {
            [weakSelf reportProgressForJob:job audioProgress:audioProgress
                videoProgress:videoProgress audioBytes:audioBytes
                videoBytes:videoBytes phase:mediaPhase];
        }
        completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
            job.directTask = nil;
            YTKACEDownloadCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (error == nil && audioURL != nil && (job.audioOnly || videoURL != nil)) {
                [strongSelf completeJob:job videoURL:videoURL audioURL:audioURL];
                return;
            }
            if ([error.domain isEqualToString:NSURLErrorDomain] &&
                error.code == NSURLErrorCancelled) {
                [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTKACELocalized(@"Cancelled")];
                [strongSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            YTKACEDownloadLog(job.identifier, @"direct failed error=%@ fallback=sabr",
                error.localizedDescription ?: @"incomplete");
            if (![strongSelf prepareSABRFallbackForJob:job]) {
                [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTKACELocalized(@"Failed")];
                [strongSelf showAlertWithTitle:YTKACELocalized(@"Download failed")
                    message:[strongSelf failureMessageForError:error job:job]];
                [strongSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            job.useDirect = NO;
            [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
                stage:YTKACELocalized(@"Preparing download") progress:0.0
                downloadedBytes:0 totalBytes:0];
            [strongSelf startSABRJob:job];
        }];
}

- (void)startSABRJob:(YTKACEDownloadJob *)job {
    if (job.cancelled) return;
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    job.sabrTask = [YTKACESABRDownloader downloadPlayerResponse:job.playerResponse
        videoOption:job.videoOption audioOption:job.audioOption audioOnly:job.audioOnly
        videoID:job.videoID identifier:job.identifier
        progress:^(double audioProgress, double videoProgress,
                   int64_t audioBytes, int64_t videoBytes,
                   NSInteger mediaPhase) {
            [weakSelf reportProgressForJob:job audioProgress:audioProgress
                videoProgress:videoProgress audioBytes:audioBytes
                videoBytes:videoBytes phase:mediaPhase];
        }
        completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
            if (error != nil || audioURL == nil || (!job.audioOnly && videoURL == nil)) {
                YTKACEStreamOption *fallback = nil;
                if ([error.domain isEqualToString:@"YTKACESABR"] &&
                    error.code == 8) {
                    fallback = [weakSelf fallbackVideoForJob:job];
                }
                if (fallback != nil) {
                    NSInteger previous = job.videoOption.itag;
                    job.videoOption = fallback;
                    job.fallbackCount += 1;
                    YTKACEDownloadLog(job.identifier,
                        @"fallback video itag=%ld to=%ld attempt=%ld",
                        (long)previous, (long)fallback.itag,
                        (long)job.fallbackCount);
                    [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
                        stage:YTKACELocalized(@"Retrying lower quality") progress:0.0
                        downloadedBytes:0 totalBytes:job.audioOption.contentLength +
                            (job.audioOnly ? 0 : job.videoOption.contentLength)];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [weakSelf startSABRJob:job];
                        });
                    return;
                }
                NSString *message = error.code == NSURLErrorCancelled
                    ? YTKACELocalized(@"Cancelled") : YTKACELocalized(@"Failed");
                [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:message];
                YTKACEDownloadLog(job.identifier, @"job failed error=%@",
                    error.localizedDescription ?: @"incomplete stream");
                if (error.code != NSURLErrorCancelled) {
                    [weakSelf showAlertWithTitle:YTKACELocalized(@"Download failed")
                        message:[weakSelf failureMessageForError:error job:job]];
                }
                [weakSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            [weakSelf completeJob:job videoURL:videoURL audioURL:audioURL];
        }];
}

- (NSString *)safeFilename:(NSString *)filename {
    NSCharacterSet *invalid =
        [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [parts componentsJoinedByString:@"-"];
    if (safe.length > 120) {
        safe = [safe substringToIndex:120];
    }
    return safe.length == 0 ? YTKACELocalized(@"YouTube Video") : safe;
}

- (NSURL *)destinationForTitle:(NSString *)title
                       category:(NSString *)category
                      extension:(NSString *)extension {
    NSURL *downloads = [YTKACEApplicationSupportDirectory()
        URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSURL *directory = [downloads URLByAppendingPathComponent:category isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", title, extension]];
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        destination = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ %ld.%@", title, (long)suffix++, extension]];
    }
    return destination;
}

- (void)writeMetadataForJob:(YTKACEDownloadJob *)job
                destination:(NSURL *)destination {
    NSURL *base = [destination URLByDeletingPathExtension];
    NSString *videoID = job.videoID;
    NSString *author = job.author;
    YTKACEAttachSponsorSegments(destination, videoID, author);
    if (job.thumbnailURL == nil) return;
    NSURL *imageURL = [base URLByAppendingPathExtension:@"jpg"];
    NSString *identifier = job.identifier;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:job.thumbnailURL completionHandler:^(NSData *data,
            NSURLResponse *response, NSError *error) {
        (void)response;
        if (error == nil && data.length != 0) {
            UIImage *image = [UIImage imageWithData:data];
            NSData *artwork = image == nil ? data : UIImageJPEGRepresentation(image, 0.9);
            [artwork writeToURL:imageURL atomically:YES];
            YTKACEDownloadLog(identifier, @"thumbnail saved bytes=%lu",
                (unsigned long)artwork.length);
            [YTKACEFFmpegMuxer embedArtworkData:artwork mediaURL:destination
                completion:^(NSError *embedError) {
                    if (embedError == nil) {
                        [NSFileManager.defaultManager removeItemAtURL:imageURL error:nil];
                        YTKACEDownloadLog(identifier, @"thumbnail embedded");
                    } else {
                        YTKACEDownloadLog(identifier, @"thumbnail sidecar kept error=%@",
                            embedError.localizedDescription);
                    }
                    YTKACEAttachSponsorSegments(destination, videoID, author);
                    [NSNotificationCenter.defaultCenter
                        postNotificationName:@"YTKACEDownloadLibraryChanged" object:nil];
                }];
        } else {
            YTKACEDownloadLog(identifier, @"thumbnail failed error=%@",
                error.localizedDescription ?: @"empty response");
            YTKACEAttachSponsorSegments(destination, videoID, author);
        }
    }];
    [task resume];
}

- (void)attachSubtitlesForJob:(YTKACEDownloadJob *)job
                  destination:(NSURL *)destination
                         then:(dispatch_block_t)handler {
    if (job.audioOnly ||
        !YTKACEFeatureEnabled(@"YTKACE.Preference.Downloads.Subtitles")) {
        handler();
        return;
    }
    if (job.captionURL == nil) {
        handler();
        return;
    }
    NSString *language = job.captionLanguage;
    YTKACEFetchCuesForURL(job.captionURL, ^(NSArray<NSDictionary *> *cues) {
        if (cues.count == 0) {
            YTKACEDownloadLog(@"subs", @"no captions for %@", job.identifier);
            handler();
            return;
        }
        NSURL *staging = [destination.URLByDeletingPathExtension
            URLByAppendingPathExtension:@"subs.mp4"];
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        [YTKACEFFmpegMuxer muxSubtitlesIntoURL:destination
                                          cues:cues
                                      language:language
                                     outputURL:staging
                                    completion:^(NSError *muxError) {
            if (muxError == nil &&
                [NSFileManager.defaultManager fileExistsAtPath:staging.path]) {
                [NSFileManager.defaultManager removeItemAtURL:destination
                                                        error:nil];
                [NSFileManager.defaultManager moveItemAtURL:staging
                                                      toURL:destination
                                                      error:nil];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            }
            handler();
        }];
    });
}

- (void)saveCompletedURL:(NSURL *)URL
                      job:(YTKACEDownloadJob *)job
                extension:(NSString *)extension {
    NSURL *destination = [self destinationForTitle:job.title
        category:job.category extension:extension];
    NSError *error = nil;
    [NSFileManager.defaultManager moveItemAtURL:URL toURL:destination error:&error];
    NSURL *temporaryDirectory = URL.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager removeItemAtURL:temporaryDirectory error:nil];
    if (error != nil) {
        [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
            success:NO message:YTKACELocalized(@"Failed")];
        YTKACEDownloadLog(job.identifier, @"save failed error=%@",
            error.localizedDescription);
        [self showAlertWithTitle:YTKACELocalized(@"Save failed")
            message:[self failureMessageForError:error job:job]];
    } else {
        __weak YTKACEDownloadCoordinator *weakSelf = self;
        [self attachSubtitlesForJob:job destination:destination then:^{
            YTKACEDownloadCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (job.savesToPhotos) {
                YTKACEDownloadLog(job.identifier, @"saved path=%@ pending photos",
                    destination.path);
                [strongSelf prepareForPhotosJob:job destination:destination
                                           then:^(NSURL *ready) {
                    [strongSelf deliverToPhotosJob:job importURL:ready
                                        libraryURL:destination];
                }];
            } else {
                [strongSelf writeMetadataForJob:job destination:destination];
                [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
                    success:YES message:YTKACELocalized(@"Complete")];
                YTKACEDownloadLog(job.identifier, @"saved path=%@",
                                  destination.path);
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"YTKACEDownloadLibraryChanged"
                                  object:nil];
                if (job.sharesFile) {
                    [strongSelf presentShareSheetForURL:destination];
                }
            }
            [strongSelf.activeJobs removeObjectForKey:job.identifier];
        }];
        return;
    }
    [self.activeJobs removeObjectForKey:job.identifier];
}

- (void)squareArtworkForJob:(YTKACEDownloadJob *)job
                       then:(void (^)(NSData *artwork))handler {
    if (job.thumbnailURL == nil) {
        handler(nil);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:job.thumbnailURL
      completionHandler:^(NSData *data, __unused NSURLResponse *response,
                          __unused NSError *error) {
        UIImage *image = data.length != 0 ? [UIImage imageWithData:data] : nil;
        if (image == nil) {
            YTKACEDownloadLog(job.identifier, @"artwork decode failed bytes=%lu",
                (unsigned long)data.length);
            handler(nil);
            return;
        }
        const CGFloat side = 720.0;
        UIGraphicsImageRendererFormat *format =
            [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1.0;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)
                                                   format:format];
        UIImage *square = [renderer imageWithActions:
            ^(UIGraphicsImageRendererContext *context) {
            [UIColor.blackColor setFill];
            [context fillRect:CGRectMake(0, 0, side, side)];
            const CGFloat scale = MIN(side / image.size.width,
                                      side / image.size.height);
            const CGSize target = CGSizeMake(image.size.width * scale,
                                             image.size.height * scale);
            [image drawInRect:CGRectMake((side - target.width) / 2.0,
                                         (side - target.height) / 2.0,
                                         target.width, target.height)];
        }];
        NSData *jpeg = UIImageJPEGRepresentation(square, 0.9);
        YTKACEDownloadLog(job.identifier, @"artwork ready bytes=%lu",
            (unsigned long)jpeg.length);
        handler(jpeg);
    }];
    [task resume];
}

- (void)prepareForPhotosJob:(YTKACEDownloadJob *)job
                destination:(NSURL *)destination
                       then:(void (^)(NSURL *ready))handler {
    NSURL *converted = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"photos-%@.mp4",
            job.identifier]];
    void (^report)(double) = ^(double fraction) {
        [YTKACEDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTKACELocalized(@"Converting") progress:fraction
            downloadedBytes:0 totalBytes:0];
    };
    if (job.audioOnly) {
        [self squareArtworkForJob:job then:^(NSData *artwork) {
            [YTKACEFFmpegMuxer videoFromAudioURL:destination artworkData:artwork
                outputURL:converted progress:report completion:^(NSError *error) {
                handler(error == nil ? converted : destination);
            }];
        }];
        return;
    }
    handler(destination);
}

- (void)deliverToPhotosJob:(YTKACEDownloadJob *)job
                 importURL:(NSURL *)importURL
                libraryURL:(NSURL *)libraryURL {
    {
        [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
            success:YES message:YTKACELocalized(@"Complete")];
        __weak YTKACEDownloadCoordinator *weakSelf = self;
        const BOOL converted = ![importURL isEqual:libraryURL];
        YTKACESaveVideoToPhotosFile(importURL, ^(BOOL success, NSError *error) {
            if (success) {
                [NSFileManager.defaultManager removeItemAtURL:importURL error:nil];
                if (converted) {
                    [NSFileManager.defaultManager removeItemAtURL:libraryURL
                        error:nil];
                }
                YTKACEDownloadLog(job.identifier, @"moved to photos converted=%d",
                    converted);
                YTKACEShowNotice(YTKACELocalized(@"Saved to Photos"));
            } else {
                if (converted) {
                    [NSFileManager.defaultManager removeItemAtURL:importURL
                        error:nil];
                }
                [weakSelf writeMetadataForJob:job destination:libraryURL];
                if (error.code == 3302 &&
                    [error.domain isEqualToString:PHPhotosErrorDomain]) {
                    YTKACEShowNotice(YTKACELocalized(
                        @"Photos cannot import this format. Kept in the YTKACE "
                        @"library instead."));
                } else if (error != nil) {
                    YTKACEShowNotice(YTKACELocalized(
                        @"Could not add to Photos. Kept in the YTKACE library "
                        @"instead."));
                }
            }
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"YTKACEDownloadLibraryChanged" object:nil];
        });
    }
}

- (void)beginBatchSharing {
    self.batchSharing = YES;
    self.batchShareURLs = [NSMutableArray array];
}

- (void)flushBatchSharingFromView:(UIView *)sourceView {
    NSArray<NSURL *> *urls = [self.batchShareURLs copy];
    self.batchSharing = NO;
    self.batchShareURLs = nil;
    if (urls.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (top == nil) return;
        UIActivityViewController *controller =
            [[UIActivityViewController alloc] initWithActivityItems:urls
                                             applicationActivities:nil];
        UIView *anchor = [self sheetAnchorForView:sourceView];
        controller.popoverPresentationController.sourceView = anchor;
        controller.popoverPresentationController.sourceRect = anchor.bounds;
        YTKACEDownloadLog(@"save", @"share sheet batch count=%lu",
            (unsigned long)urls.count);
        [top presentViewController:controller animated:YES completion:nil];
    });
}

- (void)presentShareSheetForURL:(NSURL *)url {
    if (url == nil) return;
    if (self.batchSharing) {
        [self.batchShareURLs addObject:url];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (top == nil) return;
        UIActivityViewController *controller =
            [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                             applicationActivities:nil];
        UIView *anchor = [self sheetAnchorForView:self.downloadSourceView];
        controller.popoverPresentationController.sourceView = anchor;
        controller.popoverPresentationController.sourceRect = anchor.bounds;
        YTKACEDownloadLog(@"save", @"share sheet path=%@", url.lastPathComponent);
        [top presentViewController:controller animated:YES completion:nil];
    });
}

- (void)mergeVideoURL:(NSURL *)videoURL
              audioURL:(NSURL *)audioURL
                   job:(YTKACEDownloadJob *)job {
    NSURL *output = [videoURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"merged.mp4"];
    YTKACEDownloadLog(job.identifier, @"merge start video=%@ audio=%@",
        videoURL.lastPathComponent, audioURL.lastPathComponent);
    __weak YTKACEDownloadCoordinator *weakSelf = self;
    [YTKACEFFmpegMuxer remuxVideoURL:videoURL audioURL:audioURL
        outputURL:output completion:^(NSError *error) {
            if (error != nil) {
                [YTKACEDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTKACELocalized(@"Failed")];
                YTKACEDownloadLog(job.identifier, @"merge failed error=%@",
                    error.localizedDescription);
                [weakSelf showAlertWithTitle:YTKACELocalized(@"Merge failed")
                    message:[weakSelf failureMessageForError:error job:job]];
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                [NSFileManager.defaultManager
                    removeItemAtURL:videoURL.URLByDeletingLastPathComponent error:nil];
                [weakSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            [NSFileManager.defaultManager removeItemAtURL:videoURL error:nil];
            [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
            YTKACEDownloadLog(job.identifier, @"merge complete");
            [weakSelf saveCompletedURL:output job:job extension:@"mp4"];
        }];
}

- (void)startDownload:(NSURL *)url
              category:(NSString *)category
             extension:(NSString *)extension {
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
    YTKACEDownloadJob *job = [YTKACEDownloadJob new];
    job.task = task;
    job.title = [self safeFilename:
        [YTKACEStreamResolver titleFromPlayerResponse:self.playerResponse]];
    job.category = category;
    job.extension = extension;
    @synchronized (self.jobs) {
        self.jobs[@(task.taskIdentifier)] = job;
    }

    [self showCompactNotice:YTKACELocalized(@"Download started")];
    [task resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)bytesWritten;
    YTKACEDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(downloadTask.taskIdentifier)];
    }
    if (job == nil || totalBytesExpectedToWrite <= 0) {
        return;
    }
    (void)totalBytesWritten;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    YTKACEDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(downloadTask.taskIdentifier)];
    }
    if (job == nil) {
        return;
    }

    NSURL *downloads = [YTKACEApplicationSupportDirectory()
        URLByAppendingPathComponent:@"Downloads"
                        isDirectory:YES];
    NSURL *directory = [downloads URLByAppendingPathComponent:job.category isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    NSString *filename =
        [NSString stringWithFormat:@"%@.%@", job.title, job.extension];
    NSURL *destination = [directory URLByAppendingPathComponent:filename];
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        filename = [NSString stringWithFormat:@"%@ %ld.%@",
                    job.title,
                    (long)suffix++,
                    job.extension];
        destination = [directory URLByAppendingPathComponent:filename];
    }

    NSError *error = nil;
    [NSFileManager.defaultManager moveItemAtURL:location
                                         toURL:destination
                                         error:&error];
    if (error == nil) {
        job.savedURL = destination;
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    YTKACEDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(task.taskIdentifier)];
    }
    if (job == nil) {
        return;
    }
    @synchronized (self.jobs) {
        [self.jobs removeObjectForKey:@(task.taskIdentifier)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (error != nil) {
            if (error.code != NSURLErrorCancelled) {
                [self showAlertWithTitle:YTKACELocalized(@"Download failed")
                                 message:error.localizedDescription ?: YTKACELocalized(@"Unknown error")];
            }
        } else if (job.savedURL != nil) {
            [self showAlertWithTitle:YTKACELocalized(@"Download complete")
                             message:job.savedURL.lastPathComponent];
        } else {
            [self showAlertWithTitle:YTKACELocalized(@"Download failed")
                             message:YTKACELocalized(@"The file could not be saved.")];
        }
    });
}

@end
