// iPhone Duo: the status items (camera, clock, Wi-Fi, Live Activities) sit at
// the top of the vertical bar column, and YouTube's watch page runs its video
// under them, so they cover the picture's top corner. While the watch page's
// video is under them, the watch page hides the status bar the way video apps
// do in full screen; the video keeps its full width and only the camera is
// left over it. Hiding the status bar does not change the window's safe area.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

NSString * const YTKACEDuoStatusBarHiddenKey = @"YTKACE.Preference.Player.DuoStatusBarHidden";

static BOOL YTKACEStatusHidden;
// Where the status items end while they show. Hidden, only the camera is left
// and the area shrinks, which would otherwise bring the status bar back.
static CGFloat YTKACEStatusBottom;

static UIViewController *YTKACEWatchLayer(UIView *view) {
    Class watchClass = NSClassFromString(@"YTWatchLayerViewController");
    for (UIResponder *current = view; current != nil; current = current.nextResponder) {
        if (watchClass != Nil && [current isKindOfClass:watchClass]) return (UIViewController *)current;
    }
    return nil;
}

// Called from DuoDeskPlayer.mm's layoutSubviews hook on YTPlayerView (YTKACE
// hooks a method once).
void YTKACEDuoStatusBarPlayerLayout(UIView *player) {
    UIViewController *watch = YTKACEWatchLayer(player);
    if (watch == nil) return;
    BOOL hide = NO;
    UIWindow *window = player.window;
    CGRect items = YTKACEFeatureEnabled(YTKACEDuoStatusBarHiddenKey) ? DUOStatusItemsFrame(window) : CGRectNull;
    if (!CGRectIsNull(items)) {
        if (!YTKACEStatusHidden) YTKACEStatusBottom = CGRectGetMaxY(items);
        CGRect video = [player convertRect:player.bounds toView:window];
        BOOL besideColumn = CGRectGetMaxX(video) > CGRectGetMinX(items) && CGRectGetMinX(video) < CGRectGetMaxX(items);
        hide = besideColumn && CGRectGetMinY(video) < YTKACEStatusBottom && CGRectGetMaxY(video) > 0.0;
    }
    if (hide == YTKACEStatusHidden) return;
    YTKACEStatusHidden = hide;
    [UIView animateWithDuration:0.2 animations:^{
        [watch setNeedsStatusBarAppearanceUpdate];
        [window.rootViewController setNeedsStatusBarAppearanceUpdate];
    }];
}

static IMP YTKACEOrigWatchStatusHidden;

static BOOL YTKACEWatchStatusHidden(UIViewController *self, SEL _cmd) {
    if (YTKACEStatusHidden) return YES;
    return ((BOOL (*)(id, SEL))YTKACEOrigWatchStatusHidden)(self, _cmd);
}

void YTKACEInstallDuoStatusBarHooks(void) {
    if (!DUOIsDuo()) return;
    YTKACEInstallInstanceHook(@"YTWatchLayerViewController", @"prefersStatusBarHidden",
                              (IMP)YTKACEWatchStatusHidden, &YTKACEOrigWatchStatusHidden);
}
