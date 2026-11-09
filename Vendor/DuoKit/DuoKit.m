// Helpers shared by the DuoKit modules.
//
// iOS 27 APIs are reached by name, so DuoKit also builds against older SDKs
// (Theos tweaks often build with one) and does nothing on older systems.
#import "DuoKit.h"
#import <objc/message.h>
#import <sys/sysctl.h>

BOOL DUOIsDuo(void) {
    static BOOL duo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *model = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
        if (model.length == 0) {
            char buffer[64] = {0};
            size_t size = sizeof(buffer) - 1;
            if (sysctlbyname("hw.machine", buffer, &size, NULL, 0) == 0) {
                model = [NSString stringWithUTF8String:buffer];
            }
        }
        // iPhone19,4 is the iPhone Duo. A hinge seen on an earlier launch
        // covers models added later.
        duo = [model isEqualToString:@"iPhone19,4"] || DUOHasHinge();
    });
    return duo;
}

NSInteger DUOVerticalBarEdge(UIWindow *window) {
    UITraitCollection *traits = window.traitCollection;
    SEL selector = NSSelectorFromString(@"verticalBarEdge");
    if (traits == nil || ![traits respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(traits, selector);
}

BOOL DUOVerticalBarRegionInsets(UIView *view, UIRectEdge edge, UIEdgeInsets *insets) {
    Class regionClass = NSClassFromString(@"UIViewLayoutRegion");
    SEL insetsSelector = NSSelectorFromString(@"edgeInsetsForLayoutRegion:");
    SEL defaultSelector = NSSelectorFromString(@"layoutRegionForBarOnEdge:");
    SEL extentSelector = NSSelectorFromString(@"layoutRegionForBarOnEdge:extent:");
    if (regionClass == Nil || ![view respondsToSelector:insetsSelector]) return NO;
    id region = nil;
    if ([regionClass respondsToSelector:defaultSelector]) {
        region = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(regionClass, defaultSelector, edge);
    } else if ([regionClass respondsToSelector:extentSelector]) {
        // iOS 27.1 has only the explicit form; 48 pt is the system bar's width.
        region = ((id (*)(id, SEL, NSUInteger, CGFloat))objc_msgSend)(regionClass, extentSelector, edge, 48.0);
    }
    if (region == nil) return NO;
    if (insets) *insets = ((UIEdgeInsets (*)(id, SEL, id))objc_msgSend)(view, insetsSelector, region);
    return YES;
}

CGFloat DUOListTrailingInsetBesideVerticalBar(UIView *view, CGFloat listTop) {
    UIEdgeInsets bar = UIEdgeInsetsZero;
    if (!DUOVerticalBarRegionInsets(view, UIRectEdgeRight, &bar)) return 0;
    // A bar region narrower than the safe area means the column is there; its
    // top is where the status items end.
    BOOL column = view.safeAreaInsets.right - bar.right > 1 && bar.top > 0;
    return column && listTop >= bar.top - 8 ? bar.right : 0;
}

BOOL DUOViewShowing(UIView *view) {
    UIWindow *window = view.window;
    if (window == nil) return NO;
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGRect visible = CGRectIntersection(frame, window.bounds);
    if (CGRectIsNull(visible)) return NO;
    return CGRectGetWidth(visible) * CGRectGetHeight(visible) >=
        0.5 * CGRectGetWidth(frame) * CGRectGetHeight(frame);
}

CGRect DUOStatusItemsFrame(UIView *view) {
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    NSInteger edge = DUOVerticalBarEdge(window);
    if (edge == 0) return CGRectNull;
    UIEdgeInsets bar = UIEdgeInsetsZero;
    if (!DUOVerticalBarRegionInsets(window, edge == 1 ? UIRectEdgeLeft : UIRectEdgeRight, &bar) || bar.top <= 0) {
        return CGRectNull;
    }
    CGRect bounds = window.bounds;
    CGFloat x = edge == 1 ? CGRectGetMinX(bounds) : CGRectGetMaxX(bounds) - DUOVerticalBarColumnWidth;
    CGRect area = CGRectMake(x, CGRectGetMinY(bounds), DUOVerticalBarColumnWidth, bar.top);
    return [window convertRect:area toView:view];
}
