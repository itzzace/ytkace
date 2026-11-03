#import "../YTKACE.h"
#import "../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static NSString *const YTKACEExtraDimKey = @"YTKACE.Preference.Appearance.ExtraDim";
static UIWindow *YTKACEDimWindow;

// The dim window sits above the app, so iOS asks it for orientation and
// status bar. Pass those through to the app's own window.
static UIViewController *YTKACEAppViewController(UIWindow *dimWindow) {
    UIWindow *appWindow = nil;
    for (UIWindow *window in dimWindow.windowScene.windows) {
        if (window == dimWindow || window.hidden || window.rootViewController == nil) continue;
        if (window.isKeyWindow) { appWindow = window; break; }
        if (appWindow == nil) appWindow = window;
    }
    UIViewController *controller = appWindow.rootViewController;
    while (controller.presentedViewController != nil &&
           !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@interface YTKACEDimWindowController : UIViewController
@end

@implementation YTKACEDimWindowController
- (UIViewController *)ytkace_appController {
    return YTKACEAppViewController(self.view.window);
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *app = [self ytkace_appController];
    return app != nil ? app.supportedInterfaceOrientations : UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate {
    UIViewController *app = [self ytkace_appController];
    return app != nil ? app.shouldAutorotate : YES;
}
- (UIViewController *)childViewControllerForStatusBarHidden {
    return [self ytkace_appController];
}
- (UIViewController *)childViewControllerForStatusBarStyle {
    return [self ytkace_appController];
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return [self ytkace_appController];
}
@end

@interface YTKACEDimOverlayWindow : UIWindow
@end

@implementation YTKACEDimOverlayWindow
- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
- (BOOL)_canBecomeKeyWindow {
    return NO;
}
@end

static UIWindowScene *YTKACEActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void YTKACEUpdateExtraDim(void) {
    double percent = YTKACEMasterEnabled() ? [YTKACEPreferenceObject(YTKACEExtraDimKey) doubleValue] : 0.0;
    CGFloat alpha = (CGFloat)MAX(0.0, MIN(85.0, percent)) / 100.0;
    if (alpha <= 0.001) {
        YTKACEDimWindow.hidden = YES;
        return;
    }
    UIWindowScene *scene = YTKACEActiveScene();
    if (scene == nil) return;
    if (YTKACEDimWindow == nil || YTKACEDimWindow.windowScene != scene) {
        YTKACEDimWindow = [[YTKACEDimOverlayWindow alloc] initWithWindowScene:scene];
        YTKACEDimWindow.rootViewController = [YTKACEDimWindowController new];
        YTKACEDimWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
        YTKACEDimWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        YTKACEDimWindow.userInteractionEnabled = NO;
    }
    YTKACEDimWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    YTKACEDimWindow.hidden = NO;
}

__attribute__((constructor)) static void YTKACEInstallExtraDim(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       YTKACEPreferencesDidChangeNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            YTKACEUpdateExtraDim();
        }];
    }
}
