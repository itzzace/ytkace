#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// In landscape fullscreen, YouTube sizes the video to the whole screen, so a
// wide video (about 2:1 and up) runs under the notch or Dynamic Island. This
// narrows the video view to the safe area while it would be covered. Zooming
// to fill still fills the whole screen.

static NSString *const YTKACENotchSafeKey = @"YTKACE.Preference.Player.NotchSafeVideo";

// The safe area is wider than the notch itself; this much of it is still
// clear of the Dynamic Island, so the video can use it.
static const CGFloat YTKACENotchSlack = 21.5;

static IMP OriginalPlayerLayout;
static IMP OriginalPlayerSetAspectRatio;
static IMP OriginalFreeZoomPinch;
static IMP OriginalFreeZoomSnapLabel;
static IMP OriginalHAMPinchBegan;
static IMP OriginalAVPinchBegan;

static char YTKACEAspectKey;
static char YTKACEBaseFrameKey;
static char YTKACEFittedKey;

// Set while the user has zoomed with a pinch. Cleared when YouTube snaps back
// to the original size or a new video starts.
static BOOL YTKACEUserZoomed;
static __weak UIView *YTKACEActivePlayer;

static id YTKACENotchValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL YTKACENotchBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL YTKACEFramesMatch(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 && fabs(a.origin.y - b.origin.y) < 0.5 &&
        fabs(a.size.width - b.size.width) < 0.5 && fabs(a.size.height - b.size.height) < 0.5;
}

static UIView *YTKACEPlayerForVideo(UIView *video) {
    UIView *view = video.superview;
    for (int depth = 0; view != nil && depth < 3; depth++, view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"YTPlayerView"]) return view;
    }
    return nil;
}

// The frame to use instead of the one YouTube gives the video, or the same
// frame when the video isn't covered.
static CGRect YTKACENotchFrame(UIView *player, UIView *video, CGRect base) {
    if (player == nil || !YTKACEFeatureEnabled(YTKACENotchSafeKey)) return base;
    UIWindow *window = player.window;
    if (window == nil || YTKACEUserZoomed || YTKACENotchBool(player, @"zoomToFill") ||
        !CGAffineTransformIsIdentity(video.transform)) {
        return base;
    }
    CGRect inWindow = [player convertRect:player.bounds toView:nil];
    UIEdgeInsets safe = player.safeAreaInsets;
    CGFloat side = MAX(safe.left, safe.right);
    double aspect = [objc_getAssociatedObject(player, &YTKACEAspectKey) doubleValue];
    // Fullscreen landscape only: with a side panel open the player is narrower.
    if (player.bounds.size.width <= player.bounds.size.height ||
        !YTKACEFramesMatch(inWindow, window.bounds) ||
        side <= 0.0 || aspect <= 0.0 || base.size.height <= 0.0) {
        return base;
    }
    // YouTube zooms by growing this frame; only the normal, unzoomed frame
    // fills the player exactly.
    UIView *container = video.superview;
    if (container == nil || !YTKACEFramesMatch(base, container.bounds)) return base;
    CGFloat width = base.size.width - 2.0 * side + YTKACENotchSlack;
    CGFloat shown = MIN(base.size.width, aspect * base.size.height);
    if (shown <= width + 0.5) return base;
    return CGRectMake(CGRectGetMidX(base) - width / 2.0, base.origin.y, width, base.size.height);
}

static NSMapTable<Class, NSValue *> *YTKACEVideoSetFrameOriginals;

static void YTKACEVideoSetFrame(UIView *video, SEL selector, CGRect frame) {
    IMP original = NULL;
    for (Class cls = object_getClass(video); cls != Nil && original == NULL; cls = class_getSuperclass(cls)) {
        original = (IMP)[[YTKACEVideoSetFrameOriginals objectForKey:cls] pointerValue];
    }
    if (original == NULL) return;
    UIView *player = YTKACEPlayerForVideo(video);
    CGRect adjusted = YTKACENotchFrame(player, video, frame);
    BOOL fitted = !YTKACEFramesMatch(adjusted, frame);
    BOOL wasFitted = objc_getAssociatedObject(video, &YTKACEFittedKey) != nil;
    objc_setAssociatedObject(video, &YTKACEBaseFrameKey, [NSValue valueWithCGRect:frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(video, &YTKACEFittedKey, fitted ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (fitted) YTKACEActivePlayer = player;
    if (fitted != wasFitted) {
        YTKACEDebugLog(@"notch", @"%@ video frame=%@ base=%@", fitted ? @"fitted" : @"restored",
                       NSStringFromCGRect(adjusted), NSStringFromCGRect(frame));
    }
    ((void (*)(id, SEL, CGRect))original)(video, selector, adjusted);
}

// Hooks setFrame: on the class YouTube uses for the video, the first time it
// shows up. YouTube sets that frame from more than one place.
static void YTKACEHookVideoClass(Class cls) {
    if (cls == Nil) return;
    if (YTKACEVideoSetFrameOriginals == nil) {
        YTKACEVideoSetFrameOriginals = [NSMapTable strongToStrongObjectsMapTable];
    }
    if ([YTKACEVideoSetFrameOriginals objectForKey:cls] != nil) return;
    SEL selector = @selector(setFrame:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, (IMP)YTKACEVideoSetFrame, method_getTypeEncoding(method))) {
        Method own = class_getInstanceMethod(cls, selector);
        if (method_getImplementation(own) == (IMP)YTKACEVideoSetFrame) return;
        method_setImplementation(own, (IMP)YTKACEVideoSetFrame);
    }
    [YTKACEVideoSetFrameOriginals setObject:[NSValue valueWithPointer:(const void *)original] forKey:cls];
    YTKACEDebugLog(@"notch", @"hooked %@", NSStringFromClass(cls));
}

// Runs the video's frame through the check again, from the frame YouTube
// last gave it.
static void YTKACERefitVideo(UIView *player) {
    UIView *video = YTKACENotchValue(player, @"renderingView");
    if (![video isKindOfClass:UIView.class]) return;
    YTKACEHookVideoClass(object_getClass(video));
    NSValue *base = objc_getAssociatedObject(video, &YTKACEBaseFrameKey);
    video.frame = base != nil ? base.CGRectValue : video.frame;
}

static void YTKACEPlayerLayout(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalPlayerLayout)(receiver, selector);
    if (YTKACEFeatureEnabled(YTKACENotchSafeKey) || YTKACEVideoSetFrameOriginals.count != 0) {
        YTKACERefitVideo(receiver);
    }
}

static void YTKACEPlayerSetAspectRatio(UIView *receiver, SEL selector, CGFloat aspectRatio) {
    ((void (*)(id, SEL, CGFloat))OriginalPlayerSetAspectRatio)(receiver, selector, aspectRatio);
    NSNumber *previous = objc_getAssociatedObject(receiver, &YTKACEAspectKey);
    if (previous == nil || fabs(previous.doubleValue - aspectRatio) > 0.001) {
        // A new video starts at its normal size.
        YTKACEUserZoomed = NO;
    }
    objc_setAssociatedObject(receiver, &YTKACEAspectKey, @(aspectRatio),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [receiver setNeedsLayout];
}

static void YTKACEStartUserZoom(void) {
    if (YTKACEUserZoomed) return;
    YTKACEUserZoomed = YES;
    UIView *player = YTKACEActivePlayer;
    if (player != nil) YTKACERefitVideo(player);
}

static void YTKACEFreeZoomPinch(id receiver, SEL selector, id recognizer) {
    if (YTKACEFeatureEnabled(YTKACENotchSafeKey)) YTKACEStartUserZoom();
    ((void (*)(id, SEL, id))OriginalFreeZoomPinch)(receiver, selector, recognizer);
}

static void YTKACEFreeZoomSnapLabel(id receiver, SEL selector, NSInteger state) {
    if (state == 0 && YTKACEUserZoomed) {
        // Back to the original size.
        YTKACEUserZoomed = NO;
        UIView *player = YTKACEActivePlayer;
        if (player != nil) YTKACERefitVideo(player);
    }
    ((void (*)(id, SEL, NSInteger))OriginalFreeZoomSnapLabel)(receiver, selector, state);
}

static void YTKACEHAMPinchBegan(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACENotchSafeKey)) YTKACEStartUserZoom();
    ((void (*)(id, SEL))OriginalHAMPinchBegan)(receiver, selector);
}

static void YTKACEAVPinchBegan(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACENotchSafeKey)) YTKACEStartUserZoom();
    ((void (*)(id, SEL))OriginalAVPinchBegan)(receiver, selector);
}

__attribute__((constructor)) static void YTKACEInstallNotchSafeVideo(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;
    YTKACEInstallInstanceHook(@"YTPlayerView", @"layoutSubviews",
                              (IMP)YTKACEPlayerLayout, &OriginalPlayerLayout);
    YTKACEInstallInstanceHook(@"YTPlayerView", @"setAspectRatio:",
                              (IMP)YTKACEPlayerSetAspectRatio, &OriginalPlayerSetAspectRatio);
    YTKACEInstallInstanceHook(@"YTVideoFreeZoomOverlayView", @"didRecognizePinch:",
                              (IMP)YTKACEFreeZoomPinch, &OriginalFreeZoomPinch);
    YTKACEInstallInstanceHook(@"YTVideoFreeZoomOverlayView", @"showLabelForSnapState:",
                              (IMP)YTKACEFreeZoomSnapLabel, &OriginalFreeZoomSnapLabel);
    YTKACEInstallInstanceHook(@"MLHAMSBDLSampleBufferRenderingView", @"handlePinchBegan",
                              (IMP)YTKACEHAMPinchBegan, &OriginalHAMPinchBegan);
    YTKACEInstallInstanceHook(@"MLAVPlayerLayerView", @"handlePinchBegan",
                              (IMP)YTKACEAVPinchBegan, &OriginalAVPinchBegan);
}
