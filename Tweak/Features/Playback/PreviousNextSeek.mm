#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Previous and next skip back and forward instead of changing video.
static NSString *const YTKACEPreviousNextSeekKey = @"YTKACE.Preference.Overlay.PreviousNextSeek";
static const void *YTKACESeekOriginalImageAssociation = &YTKACESeekOriginalImageAssociation;
static const void *YTKACESeekAppliedImageAssociation = &YTKACESeekAppliedImageAssociation;
static NSMutableDictionary<NSString *, NSValue *> *YTKACESeekOriginals;

NSInteger YTKACEPreviousNextSeekSeconds(void) {
    if (!YTKACEMasterEnabled()) return 0;
    const NSInteger seconds = [YTKACEPreferenceObject(YTKACEPreviousNextSeekKey) integerValue];
    return seconds == 5 || seconds == 10 || seconds == 15 || seconds == 30 ? seconds : 0;
}

static id YTKACESeekGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTKACESeekDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

// The player behind an overlay view controller or overlay view.
static id YTKACESeekPlayer(id receiver) {
    for (id candidate = receiver; candidate != nil;) {
        if ([NSStringFromClass([candidate class]) isEqualToString:@"YTPlayerViewController"]) return candidate;
        id parent = YTKACESeekGet(candidate, @"parentViewController");
        if (parent == nil && [candidate isKindOfClass:UIResponder.class]) parent = [candidate nextResponder];
        candidate = parent;
    }
    return nil;
}

static void YTKACESeekBy(id receiver, NSInteger direction) {
    id player = YTKACESeekPlayer(receiver);
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:seek]) {
        YTKACEDebugLog(@"prevnext", @"no player for %@", NSStringFromClass([receiver class]));
        return;
    }
    const double total = YTKACESeekDouble(player, @"currentVideoTotalMediaTime");
    double time = YTKACESeekDouble(player, @"currentVideoMediaTime") +
        (double)(direction * YTKACEPreviousNextSeekSeconds());
    time = MAX(0.0, total > 1.0 ? MIN(total - 0.5, time) : time);
    ((void (*)(id, SEL, double))objc_msgSend)(player, seek, time);
    YTKACEDebugLog(@"prevnext", @"seek %+ld to %.1f", (long)(direction * YTKACEPreviousNextSeekSeconds()), time);
}

static IMP YTKACESeekOriginal(id receiver, SEL selector) {
    for (Class cls = [receiver class]; cls != Nil; cls = class_getSuperclass(cls)) {
        NSValue *value = YTKACESeekOriginals[[NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls), NSStringFromSelector(selector)]];
        if (value != nil) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void YTKACESeekPressed(id receiver, SEL selector, NSInteger direction, id argument, BOOL takesArgument) {
    if (YTKACEPreviousNextSeekSeconds() > 0) {
        YTKACESeekBy(receiver, direction);
        return;
    }
    IMP original = YTKACESeekOriginal(receiver, selector);
    if (original == NULL) return;
    if (takesArgument) ((void (*)(id, SEL, id))original)(receiver, selector, argument);
    else ((void (*)(id, SEL))original)(receiver, selector);
}

static void YTKACESeekPreviousArg(id receiver, SEL selector, id argument) {
    YTKACESeekPressed(receiver, selector, -1, argument, YES);
}

static void YTKACESeekNextArg(id receiver, SEL selector, id argument) {
    YTKACESeekPressed(receiver, selector, 1, argument, YES);
}

static void YTKACESeekPrevious(id receiver, SEL selector) {
    YTKACESeekPressed(receiver, selector, -1, nil, NO);
}

static void YTKACESeekNext(id receiver, SEL selector) {
    YTKACESeekPressed(receiver, selector, 1, nil, NO);
}

static UIButton *YTKACESeekButtonIn(UIView *view) {
    if ([view isKindOfClass:UIButton.class]) return (UIButton *)view;
    for (UIView *subview in view.subviews) {
        UIButton *button = YTKACESeekButtonIn(subview);
        if (button != nil) return button;
    }
    return nil;
}

// gobackward.10 / goforward.10 while seeking, YouTube's own icons otherwise.
// YouTube can set its icon again at any time, so compare what is shown.
static void YTKACESeekStyleButton(UIView *container, BOOL forward) {
    UIButton *button = YTKACESeekButtonIn(container);
    if (button == nil) return;
    const NSInteger seconds = YTKACEPreviousNextSeekSeconds();
    UIImage *current = [button imageForState:UIControlStateNormal];
    UIImage *applied = objc_getAssociatedObject(button, YTKACESeekAppliedImageAssociation);
    if (seconds == 0) {
        UIImage *saved = objc_getAssociatedObject(button, YTKACESeekOriginalImageAssociation);
        if (applied != nil && current == applied && saved != nil) {
            [button setImage:saved forState:UIControlStateNormal];
        }
        objc_setAssociatedObject(button, YTKACESeekOriginalImageAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, YTKACESeekAppliedImageAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *symbol = [NSString stringWithFormat:@"%@.%ld", forward ? @"goforward" : @"gobackward", (long)seconds];
    if (applied != nil && current == applied && [applied.accessibilityIdentifier isEqualToString:symbol]) return;
    if (current != nil && current != applied) {
        objc_setAssociatedObject(button, YTKACESeekOriginalImageAssociation, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    const CGFloat size = MAX(18.0, MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds)) * 0.5);
    UIImage *image = [[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold]]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (image == nil) return;
    image.accessibilityIdentifier = symbol;
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    objc_setAssociatedObject(button, YTKACESeekAppliedImageAssociation, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *YTKACESeekIvar(id owner, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(owner), name);
    id value = ivar != NULL ? object_getIvar(owner, ivar) : nil;
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static void YTKACESeekHook(NSString *className, NSString *selector, IMP replacement) {
    IMP original = NULL;
    if (!YTKACEInstallInstanceHook(className, selector, replacement, &original) || original == NULL) return;
    YTKACESeekOriginals[[NSString stringWithFormat:@"%@|%@", className, selector]] =
        [NSValue valueWithPointer:(void *)original];
    YTKACEDebugLog(@"prevnext", @"hook %@ %@", className, selector);
}

void YTKACEInstallPreviousNextSeekHooks(void) {
    YTKACESeekOriginals = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"YTMainAppVideoPlayerOverlayViewController", @"YTMainAppControlsOverlayView"]) {
        YTKACESeekHook(name, @"didPressPrevious:", (IMP)YTKACESeekPreviousArg);
        YTKACESeekHook(name, @"didPressNext:", (IMP)YTKACESeekNextArg);
        YTKACESeekHook(name, @"didPressPrevious", (IMP)YTKACESeekPrevious);
        YTKACESeekHook(name, @"didPressNext", (IMP)YTKACESeekNext);
    }
    YTKACERegisterOverlayConfigurator(@"prevnextseek", ^(UIView *overlay, __unused UIStackView *stack) {
        YTKACESeekStyleButton(YTKACESeekIvar(overlay, "_previousButtonView"), NO);
        YTKACESeekStyleButton(YTKACESeekIvar(overlay, "_nextButtonView"), YES);
    });
}
