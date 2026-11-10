#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalControlSendAction;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEStatusOriginals;
static BOOL YTKACECastBypass;

static BOOL YTKACEIsCastControl(UIControl *control, SEL action, id target) {
    (void)target;
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@ %@",
        NSStringFromClass(control.class),
        control.accessibilityIdentifier ?: @"",
        control.accessibilityLabel ?: @"",
        NSStringFromSelector(action)]
        lowercaseString];
    return [token containsString:@"cast"] ||
        [token containsString:@"airplay"] ||
        [token containsString:@"routebutton"] ||
        [token containsString:@"mdx"];
}

static void YTKACEControlSendAction(UIControl *receiver,
                                    SEL selector,
                                    SEL action,
                                    id target,
                                    UIEvent *event) {
    if (OriginalControlSendAction == NULL) {
        return;
    }
    BOOL castControl = YTKACEIsCastControl(receiver, action, target);
    if (castControl) {
        YTKACEStartCastDiscovery();
    }
    if (YTKACECastBypass ||
        !YTKACEFeatureEnabled(@"YTKACE.Preference.Navigation.CastConfirmation") ||
        !castControl) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
        return;
    }
    __weak UIControl *weakReceiver = receiver;
    __weak id weakTarget = target;
    BOOL shown = YTKACEShowYouTubeConfirmation(
        YTKACELocalized(@"Connect to a device?"),
        YTKACELocalized(@"YouTube is about to open the Cast menu."),
        YTKACELocalized(@"Continue"),
        ^{
            UIControl *strongReceiver = weakReceiver;
            if (strongReceiver == nil) {
                return;
            }
            YTKACECastBypass = YES;
            ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
                strongReceiver, selector, action, weakTarget, event
            );
            YTKACECastBypass = NO;
        }
    );
    if (!shown) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
    }
}

static NSString *YTKACEStatusKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEStatusOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTKACEStatusOriginals[
            YTKACEStatusKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL YTKACEPrefersStatusHidden(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Navigation.StatusBarHidden")) {
        return YES;
    }
    NSString *name = NSStringFromClass([receiver class]).lowercaseString;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.StatusBarVisible") &&
        ([name containsString:@"player"] || [name containsString:@"watch"])) {
        return NO;
    }
    IMP original = YTKACEStatusOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

void YTKACEInstallNavigationBehaviorHooks(void) {
    if (YTKACEStatusOriginals == nil) {
        YTKACEStatusOriginals = [NSMutableDictionary dictionary];
    }
    YTKACEInstallInstanceHook(@"UIControl",
                              @"sendAction:to:forEvent:",
                              (IMP)YTKACEControlSendAction,
                              &OriginalControlSendAction);
    for (NSString *className in @[
        @"YTAppViewController",
        @"YTWatchViewController",
        @"YTWatchLayerViewController",
        @"YTPlayerViewController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTShortsPlayerViewController"
    ]) {
        IMP original = NULL;
        if (YTKACEInstallInstanceHook(className,
                                      @"prefersStatusBarHidden",
                                      (IMP)YTKACEPrefersStatusHidden,
                                      &original) && original != NULL) {
            Class cls = NSClassFromString(className);
            YTKACEStatusOriginals[YTKACEStatusKey(
                cls,
                NSSelectorFromString(@"prefersStatusBarHidden")
            )] = [NSValue valueWithPointer:(const void *)original];
        }
    }
}
