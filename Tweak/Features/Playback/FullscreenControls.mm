#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const YTKACEAutoFullscreenKey = @"YTKACE.Preference.Player.AutoFullscreen";
static NSString *const YTKACEExitFullscreenKey = @"YTKACE.Preference.Player.ExitFullscreenAtEnd";

static NSString *YTKACEFullscreenEnteredVideo;
static NSString *YTKACEFullscreenExitedVideo;

static IMP OriginalAllowedFullscreenOrientations;
static IMP OriginalWatchSupportedOrientations;
static IMP OriginalLegacyUpdateOrientations;
static IMP OriginalRequestFullscreenGeometry;
static IMP OriginalCompleteFullscreenPresentation;

static UIInterfaceOrientation YTKACEPreferredFullscreenOrientation(void) {
    if (!YTKACEMasterEnabled()) return UIInterfaceOrientationUnknown;

    id value = YTKACEPreferenceObject(YTKACEFullscreenOrientationKey);
    if ([value isEqual:@(YTKACEFullscreenOrientationLeft)]) return UIInterfaceOrientationLandscapeLeft;
    if ([value isEqual:@(YTKACEFullscreenOrientationRight)]) return UIInterfaceOrientationLandscapeRight;
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientationMask YTKACEFullscreenMask(UIInterfaceOrientation orientation) {
    return (UIInterfaceOrientationMask)(1UL << orientation);
}

static UIInterfaceOrientationMask YTKACEConstrainFullscreenLandscape(UIInterfaceOrientationMask mask) {
    if (!(mask & UIInterfaceOrientationMaskLandscape)) return mask;

    UIInterfaceOrientation preferred = YTKACEPreferredFullscreenOrientation();
    if (preferred == UIInterfaceOrientationUnknown) return mask;
    return (mask & ~UIInterfaceOrientationMaskLandscape) | YTKACEFullscreenMask(preferred);
}

// Keep YouTube's choice (vertical videos stay portrait) and only pick the
// landscape side.
static UIInterfaceOrientationMask YTKACEAllowedFullscreenOrientations(id receiver, SEL selector) {
    UIInterfaceOrientationMask mask =
        ((UIInterfaceOrientationMask (*)(id, SEL))OriginalAllowedFullscreenOrientations)(receiver, selector);
    return YTKACEConstrainFullscreenLandscape(mask);
}

static BOOL YTKACEWatchIsFullscreen(id receiver) {
    SEL selector = NSSelectorFromString(@"isWatchFullScreen");
    return [receiver respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL YTKACEWatchHasLensOverlay(id receiver) {
    Ivar lens = class_getInstanceVariable(object_getClass(receiver), "_lensPostCaptureViewController");
    return lens != NULL && ivar_getTypeEncoding(lens)[0] == '@' && object_getIvar(receiver, lens) != nil;
}

static UIInterfaceOrientationMask YTKACEWatchSupportedOrientations(id receiver, SEL selector) {
    UIInterfaceOrientationMask mask =
        ((UIInterfaceOrientationMask (*)(id, SEL))OriginalWatchSupportedOrientations)(receiver, selector);
    // The watch layer also handles fullscreen without presenting a separate controller.
    if ((mask == UIInterfaceOrientationMaskLandscape || YTKACEWatchIsFullscreen(receiver)) &&
        !YTKACEWatchHasLensOverlay(receiver)) {
        return YTKACEConstrainFullscreenLandscape(mask);
    }
    return mask;
}

static void YTKACELegacyUpdateOrientations(id receiver, SEL selector, UIInterfaceOrientation orientation) {
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        UIInterfaceOrientation preferred = YTKACEPreferredFullscreenOrientation();
        if (preferred != UIInterfaceOrientationUnknown) orientation = preferred;
    }
    ((void (*)(id, SEL, UIInterfaceOrientation))OriginalLegacyUpdateOrientations)(receiver, selector, orientation);
}

static void YTKACERequestFullscreenGeometry(id receiver, SEL selector, UIInterfaceOrientationMask mask,
                                           void (^errorHandler)(NSError *)) {
    ((void (*)(id, SEL, UIInterfaceOrientationMask, void (^)(NSError *)))OriginalRequestFullscreenGeometry)(
        receiver, selector, YTKACEConstrainFullscreenLandscape(mask), errorHandler);
}

static void YTKACECompleteFullscreenPresentation(UIViewController *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalCompleteFullscreenPresentation)(receiver, selector);
    UIInterfaceOrientation preferred = YTKACEPreferredFullscreenOrientation();
    if (preferred == UIInterfaceOrientationUnknown || !YTKACEWatchIsFullscreen(receiver) ||
        YTKACEWatchHasLensOverlay(receiver)) return;

    if (@available(iOS 16.0, *)) {
        // YouTube can skip its geometry request when the scene is already in landscape.
        // Only the side: a vertical video in portrait fullscreen stays portrait.
        UIWindowScene *scene = receiver.viewIfLoaded.window.windowScene;
        if (scene == nil || scene.interfaceOrientation == preferred ||
            !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) return;
        YTKACEDebugLog(@"fullscreen", @"turning to side %ld from %ld", (long)preferred,
                       (long)scene.interfaceOrientation);

        [receiver setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowSceneGeometryPreferencesIOS *geometry = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:YTKACEFullscreenMask(preferred)];
        [scene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError *error) {
            YTKACEDebugLog(@"fullscreen", @"preferred landscape request failed: %@", error.localizedDescription);
        }];
    }
}

static id YTKACEFullscreenGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTKACEFullscreenDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *YTKACEFullscreenVideoID(id player) {
    id value = YTKACEFullscreenGet(player, @"currentVideoID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Only the watch page player, not feed previews or Shorts.
static id YTKACEMainOverlay(id player) {
    id overlay = YTKACEFullscreenGet(player, @"activeVideoPlayerOverlay");
    Class main = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    return main != Nil && [overlay isKindOfClass:main] ? overlay : nil;
}

static BOOL YTKACEPlayerIsFullscreen(id overlay) {
    SEL selector = NSSelectorFromString(@"isFullscreen");
    return [overlay respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(overlay, selector);
}

// The miniplayer and a backgrounded app shouldn't jump into fullscreen.
static BOOL YTKACEPlayerOnScreen(id player) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIView *view = [player isKindOfClass:UIViewController.class] ? ((UIViewController *)player).view : nil;
    UIWindow *window = view.window;
    if (window == nil || view.hidden || CGRectIsEmpty(window.bounds)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    return CGRectGetWidth(frame) >= CGRectGetWidth(window.bounds) * 0.5;
}

// The overlay has the toggle on new versions, the player on older ones.
static void YTKACEToggleFullscreen(id player, NSString *stage) {
    SEL toggle = NSSelectorFromString(@"didPressToggleFullscreen");
    id overlay = YTKACEMainOverlay(player);
    id target = [overlay respondsToSelector:toggle] ? overlay
        : [player respondsToSelector:toggle] ? player : nil;
    if (target == nil) {
        YTKACEDebugLog(@"fullscreen", @"%@ toggle unavailable", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, toggle);
    YTKACEDebugLog(@"fullscreen", @"%@ toggled on %@", stage, NSStringFromClass([target class]));
}

void YTKACEFullscreenVideoActivated(id player) {
    if (!YTKACEFeatureEnabled(YTKACEAutoFullscreenKey) || YTKACEMainOverlay(player) == nil) return;
    NSString *videoID = YTKACEFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:YTKACEFullscreenEnteredVideo]) return;
    YTKACEFullscreenEnteredVideo = [videoID copy];
    __weak id weakPlayer = player;
    // wait for the watch page to finish opening
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakPlayer;
        id overlay = YTKACEMainOverlay(strong);
        if (overlay == nil || ![YTKACEFullscreenVideoID(strong) isEqualToString:videoID]) return;
        if (YTKACEPlayerIsFullscreen(overlay)) return;
        if (!YTKACEPlayerOnScreen(strong)) {
            YTKACEDebugLog(@"fullscreen", @"auto skipped video=%@ not on screen", videoID);
            return;
        }
        YTKACEToggleFullscreen(strong, @"auto");
    });
}

static BOOL YTKACELoopOn(void) {
    return YTKACEFeatureEnabled(YTKACELoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

@interface YTKACEFullscreenObserver : NSObject
@end

@implementation YTKACEFullscreenObserver

- (void)timeChanged:(NSNotification *)notification {
    if (!YTKACEFeatureEnabled(YTKACEExitFullscreenKey)) return;
    id player = notification.object;
    id overlay = YTKACEMainOverlay(player);
    if (overlay == nil) return;
    const double time = [notification.userInfo[@"time"] doubleValue];
    const double total = YTKACEFullscreenDouble(player, @"currentVideoTotalMediaTime");
    if (total <= 1.0 || time < total - 0.35) return;
    NSString *videoID = YTKACEFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:YTKACEFullscreenExitedVideo]) return;
    YTKACEFullscreenExitedVideo = [videoID copy];
    if (!YTKACEPlayerIsFullscreen(overlay) || YTKACELoopOn() || YTKACEQueueVideoIsLive(videoID, player)) return;
    YTKACEToggleFullscreen(player, @"end");
}

@end

void YTKACEInstallFullscreenHooks(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        NSString *watchLayer = @"YTWatchLayerViewController";
        YTKACEInstallInstanceHook(@"YTWatchViewController", @"allowedFullScreenOrientations",
                                  (IMP)YTKACEAllowedFullscreenOrientations, &OriginalAllowedFullscreenOrientations);
        YTKACEInstallInstanceHook(watchLayer, @"supportedInterfaceOrientations",
                                  (IMP)YTKACEWatchSupportedOrientations, &OriginalWatchSupportedOrientations);
        YTKACEInstallInstanceHook(watchLayer, @"updateSupportedInterfaceOrientations:",
                                  (IMP)YTKACELegacyUpdateOrientations, &OriginalLegacyUpdateOrientations);
        YTKACEInstallInstanceHook(watchLayer, @"requestGeometryUpdateWithInterfaceOrientationMask:errorHandler:",
                                  (IMP)YTKACERequestFullscreenGeometry, &OriginalRequestFullscreenGeometry);
        YTKACEInstallInstanceHook(watchLayer, @"didCompleteFullscreenPresentAnimation",
                                  (IMP)YTKACECompleteFullscreenPresentation, &OriginalCompleteFullscreenPresentation);
    }

    static YTKACEFullscreenObserver *observer;
    observer = [YTKACEFullscreenObserver new];
    [NSNotificationCenter.defaultCenter addObserver:observer
                                           selector:@selector(timeChanged:)
                                               name:@"YTKACEPlaybackTimeDidChange"
                                             object:nil];
}
