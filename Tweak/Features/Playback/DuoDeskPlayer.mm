// Desk (laptop) posture on the iPhone Duo: the video on the half above the
// crease and the controls on the half below, the way Netflix and the TV app
// lay out. YouTube centers its full-screen video on the whole screen, which
// puts the picture and the play controls across the crease.
//
// After YouTube lays out its player, the video container stops at the crease
// and the half below shows a mirrored, slightly soft live copy of the picture
// (DuoKit's DUOUpdateDeskReflectionBelowPicture), with the glass control panel
// of DuoDeskPanel.mm on top of it. While the panel steps aside (during an ad),
// YouTube's own controls stay: after it lays them out, the top row moves to just
// below the crease and the play row to the middle of the space between the
// crease and the progress bar. Only a player that spans the crease changes; book
// posture, flat and closed keep YouTube's layout.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

NSString * const YTKACEDuoDeskSplitKey = @"YTKACE.Preference.Player.DuoDeskSplit";
// Declared in YTKACE.h, because DuoDeskPanel.mm reads it too.
NSString * const YTKACEDuoDeskFillKey = @"YTKACE.Preference.Player.DuoDeskFill";

// The frame this code last gave the video container, while the split is on.
static const void *YTKACEDeskFrameKey = &YTKACEDeskFrameKey;

// The crease in `view`'s coordinates when the split applies to it: desk
// posture, the setting on, and the view spanning the crease.
static CGRect YTKACEDeskFold(UIView *view) {
    if (!YTKACEFeatureEnabled(YTKACEDuoDeskSplitKey)) return CGRectNull;
    CGRect fold = DUODeskPostureFold(view);
    if (CGRectIsNull(fold)) return CGRectNull;
    CGRect bounds = view.bounds;
    BOOL spans = CGRectGetMinY(fold) > CGRectGetMinY(bounds) + 100.0 &&
                 CGRectGetMaxY(fold) < CGRectGetMaxY(bounds) - 100.0;
    return spans ? fold : CGRectNull;
}

#pragma mark - Views

static UIView *YTKACEEnclosingPlayer(UIView *view) {
    static Class playerClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        playerClass = NSClassFromString(@"YTPlayerView");
    });
    while (view != nil && ![view isKindOfClass:playerClass]) view = view.superview;
    return view;
}

// The first descendant within `depth` levels that `match` accepts, nearest
// levels first.
static UIView *YTKACEFindDescendant(UIView *root, NSInteger depth, BOOL (^match)(UIView *)) {
    if (root == nil || depth < 0) return nil;
    for (UIView *subview in root.subviews) {
        if (match(subview)) return subview;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = YTKACEFindDescendant(subview, depth - 1, match);
        if (found != nil) return found;
    }
    return nil;
}

static UIView *YTKACEFindView(UIView *root, NSString *className, NSInteger depth) {
    return YTKACEFindDescendant(root, depth, ^BOOL(UIView *view) {
        return [NSStringFromClass(view.class) isEqualToString:className];
    });
}

// The first responder up the chain from `responder` that is a `className`.
static UIResponder *YTKACEResponderOfClass(UIResponder *responder, NSString *className) {
    Class cls = NSClassFromString(className);
    while (responder != nil && ![responder isKindOfClass:cls]) responder = responder.nextResponder;
    return responder;
}

#pragma mark - Video

// The first layer in the tree under `layer` (itself included) that `match` accepts.
static CALayer *YTKACEFindLayer(CALayer *layer, BOOL (^match)(CALayer *)) {
    if (match(layer)) return layer;
    for (CALayer *sublayer in layer.sublayers) {
        CALayer *found = YTKACEFindLayer(sublayer, match);
        if (found != nil) return found;
    }
    return nil;
}

// The empty strips (letterbox bars) above and below the picture inside the video
// container, from where the video layer draws the picture. 0 for both when the
// picture fills the container or is not known.
static void YTKACEPictureInsets(UIView *container, CGFloat *top, CGFloat *bottom) {
    *top = 0.0;
    *bottom = 0.0;
    AVPlayerLayer *playerLayer = (AVPlayerLayer *)YTKACEFindLayer(container.layer, ^BOOL(CALayer *layer) {
        return [layer isKindOfClass:AVPlayerLayer.class];
    });
    const CGRect picture = playerLayer.videoRect;
    if (CGRectGetHeight(picture) < 1.0) return;
    *top = MAX(0.0, CGRectGetMinY(picture));
    *bottom = MAX(0.0, CGRectGetHeight(container.bounds) - CGRectGetMaxY(picture));
}

static const void *YTKACEDeskGravityKey = &YTKACEDeskGravityKey;

// Fill crops the picture to the container; otherwise the gravity YouTube had
// is put back, so a zoom of its own is not undone.
static void YTKACEDeskApplyFill(UIView *container, BOOL fill) {
    // The layer that draws the picture takes a videoGravity (AVPlayerLayer and
    // AVSampleBufferDisplayLayer both do).
    CALayer *layer = YTKACEFindLayer(container.layer, ^BOOL(CALayer *candidate) {
        return [candidate respondsToSelector:@selector(setVideoGravity:)];
    });
    if (layer == nil) return;
    NSString *original = objc_getAssociatedObject(layer, YTKACEDeskGravityKey);
    NSString *current = [layer valueForKey:@"videoGravity"];
    if (fill) {
        if (original == nil) objc_setAssociatedObject(layer, YTKACEDeskGravityKey, current, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (![current isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
            [layer setValue:AVLayerVideoGravityResizeAspectFill forKey:@"videoGravity"];
        }
    } else if (original != nil) {
        [layer setValue:original forKey:@"videoGravity"];
        objc_setAssociatedObject(layer, YTKACEDeskGravityKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static const void *YTKACEDeskBackdropKey = &YTKACEDeskBackdropKey;

// The renderer paints black behind and around the picture (the letterbox bars),
// which hides YouTube's Ambient mode, a full-screen layer under the player, in
// the half above the crease. While the split is on that black is cleared so the
// ambient glow reaches the top of the screen too; the original colors are put
// back afterwards. The player's own black behind it stays, so with Ambient mode
// off nothing changes.
static void YTKACEDeskClearBackdrop(UIView *container, BOOL clear) {
    // Layer to its original color. The layers are held weakly: YouTube can free
    // one while the split is on, and a freed layer is simply not restored.
    NSMapTable<CALayer *, id> *saved = objc_getAssociatedObject(container, YTKACEDeskBackdropKey);
    if (!clear) {
        for (CALayer *layer in saved.keyEnumerator.allObjects) {
            layer.backgroundColor = (__bridge CGColorRef)[saved objectForKey:layer];
        }
        objc_setAssociatedObject(container, YTKACEDeskBackdropKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (saved == nil) {
        saved = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(container, YTKACEDeskBackdropKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:container.layer];
    while (layers.count > 0) {
        CALayer *layer = layers.lastObject;
        [layers removeLastObject];
        if (layer.backgroundColor != NULL) {
            if ([saved objectForKey:layer] == nil) [saved setObject:(__bridge id)layer.backgroundColor forKey:layer];
            layer.backgroundColor = NULL;
        }
        [layers addObjectsFromArray:layer.sublayers ?: @[]];
    }
}

static BOOL YTKACEIsRenderer(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"RenderingView"] || [name containsString:@"PlayerLayerView"];
}

// The player's subview that holds the video renderer; the controls overlay is
// a later sibling. YouTube's renderingView first (the class and how deep it
// sits change between versions), else a search by class name.
static UIView *YTKACEVideoContainer(UIView *player) {
    UIView *renderer = nil;
    static SEL renderingView;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        renderingView = NSSelectorFromString(@"renderingView");
    });
    if ([player respondsToSelector:renderingView]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, renderingView);
        if ([value isKindOfClass:UIView.class]) renderer = value;
    }
    if (renderer == nil || ![renderer isDescendantOfView:player]) renderer = YTKACEFindDescendant(player, 4, ^BOOL(UIView *view) { return YTKACEIsRenderer(view); });
    for (UIView *view = renderer; view != nil; view = view.superview) {
        if (view.superview == player) return view;
    }
    return nil;
}

// Swiping down on full-screen video leaves full screen. YouTube's own swipe
// drags the video with the finger and animates it back into the watch page,
// which fights the split in the laptop posture (the picture jumped around on
// release). In that posture a downward swipe anywhere on the player presses
// YouTube's exit-full-screen button instead, and YouTube's drag is held back:
// every other pan on the player waits for this one to fail, and it fails at
// once unless the swipe is downward and the split applies.
static UIControl *YTKACEExitFullscreenButton(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTEnterExitFullscreenButtonView"]) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:view];
        while (queue.count) {
            UIView *current = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([current isKindOfClass:UIControl.class]) return (UIControl *)current;
            [queue addObjectsFromArray:current.subviews];
        }
        return nil;
    }
    for (UIView *subview in view.subviews) {
        UIControl *button = YTKACEExitFullscreenButton(subview);
        if (button != nil) return button;
    }
    return nil;
}

@interface YTKACEDeskSwipe : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTKACEDeskSwipe
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    if (CGRectIsNull(YTKACEDeskFold(pan.view))) return NO;
    CGPoint velocity = [pan velocityInView:pan.view];
    return velocity.y > 0.0 && velocity.y > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [other isKindOfClass:UIPanGestureRecognizer.class];
}

- (void)swiped:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateBegan) return;
    UIControl *button = YTKACEExitFullscreenButton(pan.view);
    YTKACEDebugLog(@"duo-desk", @"swipe down: exit button %@", button != nil ? @"pressed" : @"not found");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

static const void *YTKACEDeskSwipeKey = &YTKACEDeskSwipeKey;

static void YTKACEInstallDeskSwipe(UIView *player) {
    if (objc_getAssociatedObject(player, YTKACEDeskSwipeKey) != nil) return;
    static YTKACEDeskSwipe *handler;
    if (handler == nil) handler = [YTKACEDeskSwipe new];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(swiped:)];
    pan.delegate = handler;
    pan.maximumNumberOfTouches = 1;
    [player addGestureRecognizer:pan];
    objc_setAssociatedObject(player, YTKACEDeskSwipeKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTKACESetVideoFrame(UIView *container, CGRect frame) {
    if (!CGRectEqualToRect(container.frame, frame)) container.frame = frame;
    // The renderer itself, when YouTube puts it straight in the player.
    if (YTKACEIsRenderer(container)) return;
    for (UIView *renderer in container.subviews) {
        if (!CGRectEqualToRect(renderer.frame, container.bounds)) renderer.frame = container.bounds;
    }
}

// Logs the decision when it changes, so a layout that does not split can be
// diagnosed from the debug log.
static void YTKACELogDesk(UIView *player, UIView *container, NSString *decision) {
    if (!YTKACEDebugLogsEnabled()) return;
    static NSString *last;
    NSString *line = [NSString stringWithFormat:@"%@ player=%@ container=%@ %@ inner=%@",
        decision, NSStringFromCGRect(player.bounds),
        container != nil ? NSStringFromClass(container.class) : @"nil",
        container != nil ? NSStringFromCGRect(container.frame) : @"",
        container.subviews.count ? NSStringFromClass(container.subviews.firstObject.class) : @"-"];
    if ([line isEqualToString:last]) return;
    last = line;
    YTKACEDebugLog(@"duo-desk", @"%@", line);
}

// The division regions UIKit reports for `view`, for the debug log.
static NSString *YTKACEDescribeDivisions(UIView *view) {
    Class kindClass = NSClassFromString(@"UIViewReservedRegionKind");
    SEL kindSelector = NSSelectorFromString(@"divisionRegionKind");
    SEL regionsSelector = NSSelectorFromString(@"reservedRegionsOfKind:");
    if (kindClass == Nil || ![kindClass respondsToSelector:kindSelector] ||
        ![view respondsToSelector:regionsSelector]) {
        return @"division regions unavailable";
    }
    id kind = ((id (*)(id, SEL))objc_msgSend)(kindClass, kindSelector);
    NSArray *regions = ((NSArray *(*)(id, SEL, id))objc_msgSend)(view, regionsSelector, kind);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id region in regions) {
        BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"isActive"));
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"frame"));
        [parts addObject:[NSString stringWithFormat:@"%@ active=%d", NSStringFromCGRect(frame), active]];
    }
    return [NSString stringWithFormat:@"%lu regions [%@]", (unsigned long)regions.count,
            [parts componentsJoinedByString:@", "]];
}

void YTKACEDuoStatusBarPlayerLayout(UIView *player);
static void YTKACEDuoDeskFitCaptions(UIView *view);
static void YTKACEDeskShowControls(UIView *player);
static void YTKACEDeskFitScrim(UIView *player, BOOL split);

// Takes the reflection and the control panel away.
static void YTKACEDeskHideLowerHalf(UIView *player, UIView *container) {
    DUOUpdateDeskReflection(player, container, CGRectNull);
    YTKACEDuoDeskPanelUpdate(player, CGRectNull);
}

// Called last from NotchSafeVideo.mm's layoutSubviews hook on YTPlayerView
// (YTKACE hooks a method once), after YouTube has laid out the player.
void YTKACEDuoPlayerLayout(UIView *self) {
    if (!DUOIsDuo()) return;
    YTKACEDuoStatusBarPlayerLayout(self);
    DUOObserveHinge(self);
    UIView *container = YTKACEVideoContainer(self);
    CGRect fold = YTKACEDeskFold(self);
    YTKACEDeskFitScrim(self, !CGRectIsNull(fold));
    if (CGRectIsNull(fold) && YTKACEDebugLogsEnabled() && self.window != nil &&
        YTKACEFeatureEnabled(YTKACEDuoDeskSplitKey)) {
        YTKACELogDesk(self, container, [NSString stringWithFormat:@"no crease: %@",
                                        YTKACEDescribeDivisions(self)]);
    }
    if (container == nil) {
        if (!CGRectIsNull(fold)) YTKACELogDesk(self, nil, @"no video container");
        YTKACEDuoDeskPanelUpdate(self, CGRectNull);
        return;
    }
    NSValue *ours = objc_getAssociatedObject(container, YTKACEDeskFrameKey);
    if (CGRectIsNull(fold)) {
        if (ours != nil) {
            YTKACESetVideoFrame(container, self.bounds);
            objc_setAssociatedObject(container, YTKACEDeskFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        YTKACEDeskApplyFill(container, NO);
        YTKACEDeskClearBackdrop(container, NO);
        YTKACEDeskHideLowerHalf(self, container);
        YTKACEDuoDeskFitCaptions(self);
        return;
    }
    YTKACEInstallDeskSwipe(self);
    if (ours == nil) YTKACEDeskShowControls(self);
    CGRect bounds = self.bounds;
    CGRect top = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), CGRectGetMinY(fold));
    CGRect frame = container.frame;
    // YouTube either fills the player with the container (the renderer
    // letterboxes inside it) or sizes the container to the picture and centers
    // it. Either way the video goes in the half above the crease.
    BOOL fills = fabs(CGRectGetMinX(frame)) < 0.5 && fabs(CGRectGetMinY(frame)) < 0.5;
    BOOL centered = fabs(CGRectGetMidY(frame) - CGRectGetMidY(bounds)) < 1.0 &&
                    fabs(CGRectGetMidX(frame) - CGRectGetMidX(bounds)) < 1.0;
    BOOL unchanged = ours != nil && CGRectEqualToRect(frame, ours.CGRectValue);
    if (!fills && !centered && !unchanged) {
        // YouTube is moving the video (leaving full screen): leave it.
        YTKACELogDesk(self, container, @"youtube moving");
        YTKACEDeskHideLowerHalf(self, container);
        return;
    }
    CGRect target = top;
    if (!fills && CGRectGetWidth(frame) > 0.0 && CGRectGetHeight(frame) > 0.0) {
        // Picture-sized container: keep its shape, fit it into the top half.
        CGFloat scale = MIN(1.0, MIN(CGRectGetWidth(top) / CGRectGetWidth(frame),
                                     CGRectGetHeight(top) / CGRectGetHeight(frame)));
        CGSize size = CGSizeMake(CGRectGetWidth(frame) * scale, CGRectGetHeight(frame) * scale);
        target = CGRectMake(CGRectGetMidX(top) - size.width * 0.5, CGRectGetMidY(top) - size.height * 0.5,
                            size.width, size.height);
    }
    YTKACESetVideoFrame(container, target);
    YTKACEDeskApplyFill(container, YTKACEFeatureEnabled(YTKACEDuoDeskFillKey));
    YTKACEDeskClearBackdrop(container, YES);
    objc_setAssociatedObject(container, YTKACEDeskFrameKey, [NSValue valueWithCGRect:container.frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACELogDesk(self, container, fills ? @"split (filled)" : @"split (fitted)");
    CGFloat pictureTop, pictureBottom;
    YTKACEPictureInsets(container, &pictureTop, &pictureBottom);
    DUOUpdateDeskReflectionBelowPicture(self, container, fold, pictureTop, pictureBottom);
    YTKACEDuoDeskPanelUpdate(self, fold);
    YTKACEDuoDeskFitCaptions(self);
}

#pragma mark - Captions

static const void *YTKACEDeskCaptionsKey = &YTKACEDeskCaptionsKey;

// YouTube places captions a padding above the bottom of the whole player,
// which in the laptop posture is below the crease. While the split applies,
// the padding YouTube sets on its caption overlay (view or controller, it
// uses both) is raised to clear the half below the crease; otherwise
// YouTube's value goes through unchanged.
static double YTKACEDeskCaptionPadding(id target, double requested) {
    UIView *overlay = [target isKindOfClass:UIView.class] ? target
        : ([target isKindOfClass:UIViewController.class] && [target isViewLoaded]) ? [target view] : nil;
    UIView *player = YTKACEEnclosingPlayer(overlay);
    CGRect fold = player != nil ? YTKACEDeskFold(player) : CGRectNull;
    if (CGRectIsNull(fold)) return requested;
    const CGFloat below = CGRectGetMaxY(overlay.bounds) - CGRectGetMinY([player convertRect:fold toView:overlay]);
    return below > 0.0 ? MAX(requested, below + 12.0) : requested;
}

// The view's original setter is at 0, the controller's at 1.
static IMP YTKACEOrigSetCaptionPadding[2];

static NSUInteger YTKACECaptionIndex(id target) {
    return [target isKindOfClass:UIViewController.class] ? 1 : 0;
}

static void YTKACESetCaptionPadding(id self, SEL _cmd, double requested) {
    IMP original = YTKACEOrigSetCaptionPadding[YTKACECaptionIndex(self)];
    if (original == NULL) return;
    objc_setAssociatedObject(self, YTKACEDeskCaptionsKey, @(requested), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, double))original)(self, _cmd, YTKACEDeskCaptionPadding(self, requested));
}

// The posture changes without YouTube setting the padding again, so the
// player's and the controls' layout send YouTube's last value back through
// the setter above.
static void YTKACEFitCaptionPadding(id target) {
    if (YTKACEOrigSetCaptionPadding[YTKACECaptionIndex(target)] == NULL ||
        ![target respondsToSelector:NSSelectorFromString(@"captionsBottomPadding")]) {
        return;
    }
    const double current = [[target valueForKey:@"captionsBottomPadding"] doubleValue];
    NSNumber *requested = objc_getAssociatedObject(target, YTKACEDeskCaptionsKey);
    const double base = requested != nil ? requested.doubleValue : current;
    const double wanted = YTKACEDeskCaptionPadding(target, base);
    if (fabs(current - wanted) < 0.5) return;
    YTKACEDebugLog(@"duo-desk", @"captions padding %@ %.0f -> %.0f", NSStringFromClass([target class]), current, wanted);
    [target setValue:@(base) forKey:@"captionsBottomPadding"];
}

static void YTKACEDuoDeskFitCaptions(UIView *view) {
    if (!DUOIsDuo()) return;
    UIView *overlay = YTKACEFindView(YTKACEEnclosingPlayer(view), @"YTVRCaptionOverlayView", 3);
    if (overlay == nil) return;
    YTKACEFitCaptionPadding(overlay);
    UIResponder *controller = YTKACEResponderOfClass(overlay.nextResponder, @"YTVRCaptionOverlayViewController");
    if (controller != nil) YTKACEFitCaptionPadding(controller);
}

#pragma mark - Scrub preview

// While scrubbing, YouTube shows the frame under the finger in a big board
// overlay the size of the whole player, which centers it across the crease.
// While the split applies, a full-player frame becomes the half above the
// crease, where the video is.
static CGRect YTKACEBigBoardFrame(UIView *view, CGRect frame) {
    UIView *player = YTKACEEnclosingPlayer(view.superview);
    if (player == nil) return frame;
    CGRect fold = YTKACEDeskFold(player);
    if (CGRectIsNull(fold)) return frame;
    CGRect full = [player convertRect:player.bounds toView:view.superview];
    if (CGRectGetHeight(frame) < CGRectGetHeight(full) - 1.0) return frame;
    return [player convertRect:CGRectMake(0.0, 0.0, CGRectGetWidth(player.bounds), CGRectGetMinY(fold))
                        toView:view.superview];
}

static IMP YTKACEOrigBigBoardSetFrame;
static IMP YTKACEOrigBigBoardLayout;

static void YTKACEBigBoardSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))YTKACEOrigBigBoardSetFrame)(self, _cmd, YTKACEBigBoardFrame(self, frame));
}

static void YTKACEBigBoardLayout(UIView *self, SEL _cmd) {
    // The posture can change without YouTube setting the frame again.
    CGRect frame = YTKACEBigBoardFrame(self, self.frame);
    if (!CGRectEqualToRect(frame, self.frame)) {
        ((void (*)(id, SEL, CGRect))YTKACEOrigBigBoardSetFrame)(self, @selector(setFrame:), frame);
    }
    ((void (*)(id, SEL))YTKACEOrigBigBoardLayout)(self, _cmd);
}

#pragma mark - Controls

static const void *YTKACEDeskScrimKey = &YTKACEDeskScrimKey;

// YouTube darkens the video under its controls with a gradient scrim the size
// of the whole player (the overlay's _backgroundView), dark at the top where
// its top row sits. In the laptop layout that row is below the crease and the
// controls stay up, so the scrim would dim the picture for good. It is hidden
// while the split applies (YouTube only animates its alpha) and shown again
// after.
static void YTKACEDeskFitScrim(UIView *player, BOOL split) {
    if (!split && objc_getAssociatedObject(player, YTKACEDeskScrimKey) == nil) return;
    UIView *overlay = YTKACEFindView(player, @"YTMainAppVideoPlayerOverlayView", 3);
    Ivar ivar = overlay != nil ? class_getInstanceVariable(object_getClass(overlay), "_backgroundView") : NULL;
    id scrim = ivar != NULL && ivar_getTypeEncoding(ivar)[0] == '@' ? object_getIvar(overlay, ivar) : nil;
    if (![scrim isKindOfClass:UIView.class]) return;
    [scrim setHidden:split];
    YTKACEDebugLog(@"duo-desk", @"controls scrim %@", split ? @"hidden" : @"restored");
    objc_setAssociatedObject(player, YTKACEDeskScrimKey, split ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The controls stay up while the split applies (the panel replaces them, and
// YouTube's own stay up for the cases where it steps aside, such as an ad).
// YouTube's overlay controller hides them with a timed action it
// starts whenever it shows them (and restarts on interaction), and a tap on
// the video toggles them. While the split applies the timed action is
// stopped as soon as it starts, and a tap only shows them.
static IMP YTKACEOrigShowPlayerControls;
static IMP YTKACEOrigResetAutoHide;
static IMP YTKACEOrigResetAutoHideAfterDelay;
static IMP YTKACEOrigBackgroundTap;

static BOOL YTKACEDeskControllerSplit(UIViewController *controller) {
    if (!YTKACEFeatureEnabled(YTKACEDuoDeskSplitKey)) return NO;
    UIView *player = YTKACEEnclosingPlayer(controller.isViewLoaded ? controller.view : nil);
    return player != nil && !CGRectIsNull(YTKACEDeskFold(player));
}

static void YTKACEStopAutoHide(id controller) {
    SEL stop = NSSelectorFromString(@"stopPlayerControlsAutohideTimedAction");
    if ([controller respondsToSelector:stop]) ((void (*)(id, SEL))objc_msgSend)(controller, stop);
}

static void YTKACEShowPlayerControls(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))YTKACEOrigShowPlayerControls)(self, _cmd, animated);
    if (YTKACEDeskControllerSplit(self)) YTKACEStopAutoHide(self);
}

static void YTKACEResetAutoHide(UIViewController *self, SEL _cmd) {
    if (YTKACEDeskControllerSplit(self)) {
        YTKACEStopAutoHide(self);
        return;
    }
    ((void (*)(id, SEL))YTKACEOrigResetAutoHide)(self, _cmd);
}

static void YTKACEResetAutoHideAfterDelay(UIViewController *self, SEL _cmd, double delay) {
    if (YTKACEDeskControllerSplit(self)) {
        YTKACEStopAutoHide(self);
        return;
    }
    ((void (*)(id, SEL, double))YTKACEOrigResetAutoHideAfterDelay)(self, _cmd, delay);
}

static void YTKACEBackgroundTap(UIViewController *self, SEL _cmd) {
    if (YTKACEDeskControllerSplit(self)) {
        SEL show = NSSelectorFromString(@"showPlayerControlsAnimated:");
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, show, YES);
        return;
    }
    ((void (*)(id, SEL))YTKACEOrigBackgroundTap)(self, _cmd);
}

// Shows the controls when the split starts, if YouTube had already hidden
// them; the hook above then stops the auto-hide.
static void YTKACEDeskShowControls(UIView *player) {
    UIView *overlay = YTKACEFindView(player, @"YTMainAppVideoPlayerOverlayView", 3);
    UIResponder *controller = YTKACEResponderOfClass(overlay, @"YTMainAppVideoPlayerOverlayViewController");
    SEL show = NSSelectorFromString(@"showPlayerControlsAnimated:");
    if (YTKACEOrigShowPlayerControls == NULL || ![controller respondsToSelector:show]) return;
    YTKACEDebugLog(@"duo-desk", @"controls shown for the split");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, show, YES);
}

// Top of YouTube's progress bar in `view`'s coordinates, or the view's bottom.
static CGFloat YTKACEPlayerBarTop(UIView *view) {
    UIView *overlay = view.superview;
    for (UIView *sibling in overlay.subviews) {
        if ([NSStringFromClass(sibling.class) isEqualToString:@"YTInlinePlayerBarContainerView"] && !sibling.hidden) {
            return CGRectGetMinY([overlay convertRect:sibling.frame toView:view]);
        }
    }
    return CGRectGetMaxY(view.bounds);
}

// Called last from OverlayButtonHost.mm's layoutSubviews hook on the controls
// overlay (YTKACE hooks a method once).
void YTKACEDuoDeskControlsLayout(UIView *self) {
    if (!DUOIsDuo()) return;
    DUOObserveHinge(self);
    YTKACEDuoDeskFitCaptions(self);
    CGRect fold = YTKACEDeskFold(self);
    if (CGRectIsNull(fold)) return;
    // YouTube lays these out again on its next pass, so they are moved on
    // every pass while the posture lasts.
    CGFloat lowerTop = CGRectGetMaxY(fold);
    CGFloat lowerBottom = MAX(lowerTop + 60.0, YTKACEPlayerBarTop(self));
    CGFloat middle = CGRectGetMidY(self.bounds);
    // The top row and title move just below the crease; the play row is then
    // centered in the space left between them and the progress bar.
    CGFloat contentTop = lowerTop;
    NSMutableArray<UIView *> *playRow = [NSMutableArray array];
    for (UIView *subview in self.subviews) {
        CGRect frame = subview.frame;
        BOOL fullSize = CGRectGetWidth(frame) >= CGRectGetWidth(self.bounds) &&
                        CGRectGetHeight(frame) >= CGRectGetHeight(self.bounds);
        if (CGRectIsEmpty(frame) || fullSize) {
            continue;
        }
        if (CGRectGetMinY(frame) >= lowerTop) continue;
        if (fabs(CGRectGetMidY(frame) - middle) < 80.0) {
            [playRow addObject:subview];
        } else if (CGRectGetMaxY(frame) <= CGRectGetMinY(fold)) {
            frame.origin.y += lowerTop;
            subview.frame = frame;
            if (!subview.hidden && subview.alpha > 0.01) {
                contentTop = MAX(contentTop, CGRectGetMaxY(frame));
            }
        }
    }
    if (contentTop > lowerBottom - 60.0) contentTop = lowerTop;
    for (UIView *subview in playRow) {
        CGRect frame = subview.frame;
        frame.origin.y = (contentTop + lowerBottom - CGRectGetHeight(frame)) * 0.5;
        subview.frame = frame;
    }
}

void YTKACEInstallDuoDeskPlayerHooks(void) {
    if (!DUOIsDuo()) return;
    YTKACEInstallDuoDeskPanelHooks();
    NSString *overlayController = @"YTMainAppVideoPlayerOverlayViewController";
    if ([NSClassFromString(overlayController)
            instancesRespondToSelector:NSSelectorFromString(@"stopPlayerControlsAutohideTimedAction")]) {
        YTKACEInstallInstanceHook(overlayController, @"showPlayerControlsAnimated:",
                                  (IMP)YTKACEShowPlayerControls, &YTKACEOrigShowPlayerControls);
        YTKACEInstallInstanceHook(overlayController, @"resetAutoHideTimer",
                                  (IMP)YTKACEResetAutoHide, &YTKACEOrigResetAutoHide);
        YTKACEInstallInstanceHook(overlayController, @"resetAutoHideTimerAfterDelay:",
                                  (IMP)YTKACEResetAutoHideAfterDelay, &YTKACEOrigResetAutoHideAfterDelay);
        YTKACEInstallInstanceHook(overlayController, @"updateControlsVisibilityOnBackgroundTap",
                                  (IMP)YTKACEBackgroundTap, &YTKACEOrigBackgroundTap);
    }
    YTKACEInstallInstanceHook(@"YTBigBoardOverlayView", @"setFrame:",
                              (IMP)YTKACEBigBoardSetFrame, &YTKACEOrigBigBoardSetFrame);
    if (YTKACEOrigBigBoardSetFrame != NULL) {
        YTKACEInstallInstanceHook(@"YTBigBoardOverlayView", @"layoutSubviews",
                                  (IMP)YTKACEBigBoardLayout, &YTKACEOrigBigBoardLayout);
    }
    NSArray<NSString *> *captionClasses = @[@"YTVRCaptionOverlayView", @"YTVRCaptionOverlayViewController"];
    for (NSUInteger index = 0; index < captionClasses.count; index++) {
        Method method = class_getInstanceMethod(NSClassFromString(captionClasses[index]),
                                                NSSelectorFromString(@"setCaptionsBottomPadding:"));
        char type[8] = {0};
        if (method != NULL) method_getArgumentType(method, 2, type, sizeof(type));
        // Only a double setter is handled, as on the YouTube versions checked.
        if (type[0] != 'd') continue;
        const BOOL hooked = YTKACEInstallInstanceHook(captionClasses[index], @"setCaptionsBottomPadding:",
                                                      (IMP)YTKACESetCaptionPadding, &YTKACEOrigSetCaptionPadding[index]);
        YTKACEDebugLog(@"duo-desk", @"captions hook %@ %@", captionClasses[index], hooked ? @"installed" : @"failed");
    }
}
