#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const YTKACEHapticsDisabledKey = @"YTKACE.Preference.App.HapticsDisabled";
static NSMutableDictionary<NSString *, NSValue *> *YTKACEHapticOriginals;

static IMP YTKACEHapticOriginal(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEHapticsDisabledKey)) return NULL;
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(selector)];
        IMP original = (IMP)[YTKACEHapticOriginals[key] pointerValue];
        if (original != NULL) return original;
    }
    return NULL;
}

static void YTKACEHapticPlain(id receiver, SEL selector) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL))original)(receiver, selector);
}

static void YTKACEHapticIntensity(id receiver, SEL selector, CGFloat intensity) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, CGFloat))original)(receiver, selector, intensity);
}

static void YTKACEHapticLocation(id receiver, SEL selector, CGPoint location) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, CGPoint))original)(receiver, selector, location);
}

static void YTKACEHapticIntensityLocation(id receiver, SEL selector, CGFloat intensity, CGPoint location) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, CGFloat, CGPoint))original)(receiver, selector, intensity, location);
    }
}

static void YTKACEHapticType(id receiver, SEL selector, NSInteger type) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, NSInteger))original)(receiver, selector, type);
}

static void YTKACEHapticTypeLocation(id receiver, SEL selector, NSInteger type, CGPoint location) {
    IMP original = YTKACEHapticOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, NSInteger, CGPoint))original)(receiver, selector, type, location);
    }
}

static BOOL YTKACEInstallHapticHook(NSString *className, NSString *selectorName, IMP replacement) {
    IMP original = NULL;
    if (!YTKACEInstallInstanceHook(className, selectorName, replacement, &original) || original == NULL) {
        return NO;
    }
    YTKACEHapticOriginals[[NSString stringWithFormat:@"%@|%@", className, selectorName]] =
        [NSValue valueWithPointer:(const void *)original];
    return YES;
}

void YTKACEInstallHapticHooks(void) {
    if (YTKACEHapticOriginals == nil) YTKACEHapticOriginals = [NSMutableDictionary dictionary];
    NSString *impact = @"UIImpactFeedbackGenerator";
    NSString *selection = @"UISelectionFeedbackGenerator";
    NSString *notification = @"UINotificationFeedbackGenerator";
    NSString *canvas = @"UICanvasFeedbackGenerator";
    BOOL impactPlain = YTKACEInstallHapticHook(impact, @"impactOccurred", (IMP)YTKACEHapticPlain);
    BOOL impactIntensity = YTKACEInstallHapticHook(impact, @"impactOccurredWithIntensity:",
                                                   (IMP)YTKACEHapticIntensity);
    BOOL impactLocation = YTKACEInstallHapticHook(impact, @"impactOccurredAtLocation:",
                                                  (IMP)YTKACEHapticLocation);
    BOOL impactBoth = YTKACEInstallHapticHook(impact, @"impactOccurredWithIntensity:atLocation:",
                                              (IMP)YTKACEHapticIntensityLocation);
    BOOL selectionPlain = YTKACEInstallHapticHook(selection, @"selectionChanged", (IMP)YTKACEHapticPlain);
    BOOL selectionLocation = YTKACEInstallHapticHook(selection, @"selectionChangedAtLocation:",
                                                     (IMP)YTKACEHapticLocation);
    BOOL notificationPlain = YTKACEInstallHapticHook(notification, @"notificationOccurred:",
                                                     (IMP)YTKACEHapticType);
    BOOL notificationLocation = YTKACEInstallHapticHook(notification, @"notificationOccurred:atLocation:",
                                                        (IMP)YTKACEHapticTypeLocation);
    BOOL canvasAlignment = YTKACEInstallHapticHook(canvas, @"alignmentOccurredAtLocation:",
                                                   (IMP)YTKACEHapticLocation);
    BOOL canvasPath = YTKACEInstallHapticHook(canvas, @"pathCompletedAtLocation:", (IMP)YTKACEHapticLocation);
    YTKACEDownloadLog(@"haptics", @"hooks impact=%d/%d/%d/%d selection=%d/%d notification=%d/%d canvas=%d/%d",
                      impactPlain, impactIntensity, impactLocation, impactBoth, selectionPlain, selectionLocation,
                      notificationPlain, notificationLocation, canvasAlignment, canvasPath);
}
