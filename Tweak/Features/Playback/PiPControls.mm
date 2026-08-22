#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/StreamResolver.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <math.h>
#import <objc/message.h>

@interface YTKACEPiPCoordinator : NSObject <AVPictureInPictureControllerDelegate>
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, strong) AVPictureInPictureController *controller;
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerItem *playerItem;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) UIView *playerView;
@property(nonatomic, strong) UIView *loadingView;
@property(nonatomic, strong) id youtubePlayer;
@property(nonatomic, assign) BOOL observingItem;
@property(nonatomic, assign) BOOL polling;
- (void)togglePiP;
@end

@implementation YTKACEPiPCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACEPiPCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTKACEPiPCoordinator new];
    });
    return coordinator;
}

- (AVPlayerLayer *)playerLayerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        return (AVPlayerLayer *)layer;
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayerLayer *result = [self playerLayerInLayer:child];
        if (result != nil) {
            return result;
        }
    }
    return nil;
}

- (AVPlayerLayer *)activePlayerLayer {
    UIView *root = self.overlay;
    while (root.superview != nil) {
        root = root.superview;
    }
    return [self playerLayerInLayer:root.layer];
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            UIWindow *window = ((UIWindowScene *)scene).windows.firstObject;
            if (window != nil) {
                return window;
            }
        }
    }
    return nil;
}

- (id)currentPlayerResponse {
    id player = [self activeYouTubePlayer];
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse"]) {
        SEL selector = NSSelectorFromString(name);
        if ([player respondsToSelector:selector]) {
            id response = ((id (*)(id, SEL))objc_msgSend)(player, selector);
            if (response != nil) {
                return response;
            }
        }
    }
    return YTKACEDownloadCoordinator.sharedCoordinator.playerResponse;
}

- (id)activeYouTubePlayer {
    Class overlayClass = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    UIResponder *responder = self.overlay;
    while (responder != nil) {
        if (overlayClass != Nil && [responder isKindOfClass:overlayClass]) {
            SEL selector = NSSelectorFromString(@"parentViewController");
            if ([responder respondsToSelector:selector]) {
                return ((id (*)(id, SEL))objc_msgSend)(responder, selector);
            }
        }
        responder = responder.nextResponder;
    }
    return nil;
}

- (NSTimeInterval)currentVideoTime {
    id player = self.youtubePlayer ?: [self activeYouTubePlayer];
    for (id target in @[player ?: NSNull.null, self.overlay ?: NSNull.null]) {
        SEL selector = NSSelectorFromString(@"currentVideoMediaTime");
        if (target != NSNull.null && [target respondsToSelector:selector]) {
            double time = ((double (*)(id, SEL))objc_msgSend)(target, selector);
            if (isfinite(time) && time > 0.0) {
                return time;
            }
        }
    }
    return 0.0;
}

- (void)pauseYouTubePlayer {
    self.youtubePlayer = [self activeYouTubePlayer];
    for (NSString *name in @[@"pause", @"suspendPlayback"]) {
        SEL selector = NSSelectorFromString(name);
        if ([self.youtubePlayer respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(self.youtubePlayer, selector);
        }
    }
}

- (void)resumeYouTubePlayer {
    for (NSString *name in @[@"play", @"resumePlayback"]) {
        SEL selector = NSSelectorFromString(name);
        if ([self.youtubePlayer respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(self.youtubePlayer, selector);
        }
    }
    self.youtubePlayer = nil;
}

- (void)showLoading {
    [self hideLoading];
    UIWindow *window = [self keyWindow];
    if (window == nil) {
        return;
    }
    UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 154.0, 92.0)];
    hud.center = window.center;
    hud.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    hud.layer.cornerRadius = 14.0;
    UIActivityIndicatorViewStyle style = UIActivityIndicatorViewStyleLarge;
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
    spinner.frame = CGRectMake(57.0, 12.0, 40.0, 40.0);
    [spinner startAnimating];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 56.0, 138.0, 24.0)];
    label.text = YTKACELocalized(@"Loading PiP");
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    [hud addSubview:spinner];
    [hud addSubview:label];
    [window addSubview:hud];
    self.loadingView = hud;
}

- (void)hideLoading {
    [self.loadingView removeFromSuperview];
    self.loadingView = nil;
}

- (void)showError:(NSString *)message {
    [self hideLoading];
    Class alertClass = NSClassFromString(@"YTAlertView");
    SEL infoDialog = NSSelectorFromString(@"infoDialog");
    if (alertClass != Nil && [alertClass respondsToSelector:infoDialog]) {
        id alert = ((id (*)(id, SEL))objc_msgSend)(alertClass, infoDialog);
        SEL setTitle = NSSelectorFromString(@"setTitle:");
        SEL setSubtitle = NSSelectorFromString(@"setSubtitle:");
        SEL show = NSSelectorFromString(@"show");
        if ([alert respondsToSelector:setTitle] &&
            [alert respondsToSelector:setSubtitle] &&
            [alert respondsToSelector:show]) {
            ((void (*)(id, SEL, id))objc_msgSend)(alert, setTitle, @"Picture in Picture");
            ((void (*)(id, SEL, id))objc_msgSend)(alert, setSubtitle, message);
            ((void (*)(id, SEL))objc_msgSend)(alert, show);
            return;
        }
    }
    YTKACEShowNotice([NSString stringWithFormat:@"Picture in Picture\n%@", message]);
}

- (void)stopObservingItem {
    if (self.observingItem && self.playerItem != nil) {
        @try {
            [self.playerItem removeObserver:self forKeyPath:@"status"];
        } @catch (__unused NSException *exception) {
        }
    }
    self.observingItem = NO;
}

- (void)clearPlayer {
    self.polling = NO;
    [self stopObservingItem];
    [self.player pause];
    [self.playerView removeFromSuperview];
    self.playerView = nil;
    self.playerLayer = nil;
    self.playerItem = nil;
    self.player = nil;
}

- (void)togglePiP {
    if (!YTKACEFeatureEnabled(YTKACEPiPKey)) {
        return;
    }
    if (self.controller.isPictureInPictureActive) {
        [self.controller stopPictureInPicture];
        return;
    }
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        [self showError:@"PiP is not supported on this device."];
        return;
    }
    [self showLoading];
    [self resumeYouTubePlayer];
    [self clearPlayer];
    self.youtubePlayer = [self activeYouTubePlayer];
    NSTimeInterval currentTime = [self currentVideoTime];
    YTKACEStreamOption *option = [YTKACEStreamResolver
        bestPiPVideoFromPlayerResponse:[self currentPlayerResponse]];
    if (option != nil) {
        [self pauseYouTubePlayer];
        self.playerItem = [AVPlayerItem playerItemWithURL:option.URL];
        self.player = [AVPlayer playerWithPlayerItem:self.playerItem];
        self.player.volume = 0.0;
        self.player.allowsExternalPlayback = YES;
        self.player.automaticallyWaitsToMinimizeStalling = YES;
        self.playerView = [[UIView alloc]
            initWithFrame:CGRectMake(-1000.0, -1000.0, 400.0, 300.0)];
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        self.playerLayer.frame = self.playerView.bounds;
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        [self.playerView.layer addSublayer:self.playerLayer];
        [[self keyWindow] addSubview:self.playerView];
        AVAudioSession *session = AVAudioSession.sharedInstance;
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];
        self.controller = [[AVPictureInPictureController alloc]
            initWithPlayerLayer:self.playerLayer];
        self.controller.delegate = self;
        self.observingItem = YES;
        [self.playerItem addObserver:self
                         forKeyPath:@"status"
                            options:NSKeyValueObservingOptionInitial |
                                NSKeyValueObservingOptionNew
                            context:NULL];
        if (currentTime > 0.0) {
            CMTime time = CMTimeMakeWithSeconds(currentTime, 1000000000);
            [self.player seekToTime:time
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];
        }
        self.polling = YES;
        [self startPiPWithAttempts:10];
    } else {
        AVPlayerLayer *activeLayer = [self activePlayerLayer];
        if (activeLayer != nil) {
            self.controller = [[AVPictureInPictureController alloc]
                initWithPlayerLayer:activeLayer];
            self.controller.delegate = self;
            self.polling = YES;
            [self startPiPWithAttempts:10];
            return;
        }
        [self showError:@"No playable video stream is available."];
        return;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)change;
    (void)context;
    if (object != self.playerItem || ![keyPath isEqualToString:@"status"]) {
        return;
    }
    if (self.playerItem.status == AVPlayerItemStatusReadyToPlay) {
        if (!self.polling) {
            self.polling = YES;
            [self startPiPWithAttempts:10];
        }
    } else if (self.playerItem.status == AVPlayerItemStatusFailed) {
        NSString *reason = self.playerItem.error.localizedDescription ?: @"Playback failed.";
        [self showError:reason];
        [self clearPlayer];
        [self resumeYouTubePlayer];
    }
}

- (void)startPiPWithAttempts:(NSInteger)attempts {
    if (self.controller.isPictureInPicturePossible) {
        self.polling = NO;
        [self hideLoading];
        self.player.volume = 1.0;
        [self.player play];
        [self.controller startPictureInPicture];
        return;
    }
    if (attempts <= 0) {
        self.polling = NO;
        [self showError:@"PiP is not available for this video."];
        [self clearPlayer];
        [self resumeYouTubePlayer];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startPiPWithAttempts:attempts - 1];
    });
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    [self hideLoading];
}

- (void)pictureInPictureController:
    (AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
    (void)pictureInPictureController;
    [self showError:error.localizedDescription ?: @"PiP failed to start."];
    [self clearPlayer];
    [self resumeYouTubePlayer];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    [self hideLoading];
    [self clearPlayer];
    [self resumeYouTubePlayer];
}

@end

void YTKACEInstallPiPHooks(void) {
    YTKACERegisterOverlayConfigurator(@"pip", ^(UIView *overlay, UIStackView *stack) {
        YTKACEPiPCoordinator.sharedCoordinator.overlay = overlay;
        UIButton *button = YTKACEOverlayButton(
            stack,
            @"YTKACE PiP",
            @"pip",
            YTKACEPiPCoordinator.sharedCoordinator,
            @selector(togglePiP)
        );
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        [button setImage:[[YTKACEAssetImage(@"picture_in_picture_24pt_3x_Normal", @"pip")
            imageByApplyingSymbolConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                  forState:UIControlStateNormal];
        button.hidden = !YTKACEFeatureEnabled(YTKACEPiPKey);
    });
}
