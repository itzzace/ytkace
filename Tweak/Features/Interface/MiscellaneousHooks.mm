#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

static IMP OriginalAddInteraction;
static IMP OriginalSemanticContent;
static IMP OriginalSetSemanticContent;
static IMP OriginalCaptionControllerAlloc;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEMiscOriginals;
static const void *YTKACECaptionTracksAssociation =
    &YTKACECaptionTracksAssociation;
static const void *YTKACELastCaptionTrackAssociation =
    &YTKACELastCaptionTrackAssociation;
static const void *YTKACEAppliedCaptionAssociation =
    &YTKACEAppliedCaptionAssociation;
static NSHashTable *YTKACECaptionControllers;

static NSString *YTKACECaptionTrackKey(id track) {
    if (track == nil) {
        return nil;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"languageCode", @"displayName", @"vssId",
                             @"kind"]) {
        @try {
            id value = [track valueForKey:key];
            if (value != nil) {
                [parts addObject:[value description]];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return parts.count != 0 ? [parts componentsJoinedByString:@"|"] :
        [NSString stringWithFormat:@"%p", (__bridge void *)track];
}

static BOOL YTKACECaptionRequestReceiver(id receiver, SEL selector) {
    NSString *className = NSStringFromClass([receiver class]).lowercaseString;
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    return [className containsString:@"request"] ||
        [className containsString:@"params"] ||
        [className containsString:@"config"] ||
        [name containsString:@"requested"] ||
        [name containsString:@"devicecaptions"] ||
        [name containsString:@"persistence"] ||
        [name containsString:@"respectdevice"] ||
        [name containsString:@"hiddenonstart"];
}

static NSString *YTKACEMiscKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEMiscOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTKACEMiscOriginals[
            YTKACEMiscKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL YTKACEMiniPlayerEnabled(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.KidsMiniPlayer");
}

static NSString *const YTKACELayoutIdiomKey = @"YTKACE.Preference.App.LayoutIdiom";

static BOOL YTKACEIdiomForced;
static UIUserInterfaceIdiom YTKACEForcedIdiom;
static UIUserInterfaceIdiom YTKACERealIdiom;
static IMP OriginalDeviceIdiom;

typedef struct {
    uintptr_t start;
    uintptr_t end;
} YTKACETextRange;

static YTKACETextRange YTKACEIdiomRanges[2];
static NSUInteger YTKACEIdiomRangeCount;

static void YTKACEAddTextRange(const struct mach_header *header) {
    if (header == NULL || YTKACEIdiomRangeCount >= 2) return;
    unsigned long size = 0;
    const uint8_t *text = getsectiondata(
        (const struct mach_header_64 *)header, "__TEXT", "__text", &size);
    if (text == NULL || size == 0) return;
    YTKACEIdiomRanges[YTKACEIdiomRangeCount].start = (uintptr_t)text;
    YTKACEIdiomRanges[YTKACEIdiomRangeCount].end = (uintptr_t)text + size;
    YTKACEIdiomRangeCount++;
}

static void YTKACEComputeIdiomRanges(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header == NULL) continue;
        if (header->filetype != MH_EXECUTE) continue;
        YTKACEAddTextRange(header);
        break;
    }
    Dl_info info;
    if (dladdr((const void *)&YTKACEComputeIdiomRanges, &info) != 0) {
        YTKACEAddTextRange((const struct mach_header *)info.dli_fbase);
    }
}

static inline BOOL YTKACECallerIsApp(uintptr_t caller) {
    for (NSUInteger index = 0; index < YTKACEIdiomRangeCount; index++) {
        if (caller >= YTKACEIdiomRanges[index].start &&
            caller < YTKACEIdiomRanges[index].end) {
            return YES;
        }
    }
    return NO;
}

NSInteger YTKACERealUserInterfaceIdiom(void) {
    if (YTKACEIdiomForced) {
        return (NSInteger)YTKACERealIdiom;
    }
    return (NSInteger)UIDevice.currentDevice.userInterfaceIdiom;
}

static UIUserInterfaceIdiom YTKACEUserInterfaceIdiom(id receiver, SEL selector) {
    if (YTKACEIdiomForced &&
        YTKACECallerIsApp((uintptr_t)__builtin_return_address(0))) {
        return YTKACEForcedIdiom;
    }
    return OriginalDeviceIdiom != NULL
        ? ((UIUserInterfaceIdiom (*)(id, SEL))OriginalDeviceIdiom)(receiver,
                                                                   selector)
        : YTKACERealIdiom;
}

static void YTKACEResolveForcedIdiom(void) {
    UIUserInterfaceIdiom actual = UIDevice.currentDevice.userInterfaceIdiom;
    id stored = YTKACEPreferenceObject(YTKACELayoutIdiomKey);
    NSInteger choice = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    if (choice == 0 &&
        YTKACEFeatureEnabled(@"YTKACE.Preference.App.iPadLayout")) {
        choice = 2;
    }
    UIUserInterfaceIdiom desired;
    if (choice == 1) {
        desired = UIUserInterfaceIdiomPhone;
    } else if (choice == 2) {
        desired = UIUserInterfaceIdiomPad;
    } else {
        return;
    }
    if (desired == actual) return;
    YTKACERealIdiom = actual;
    YTKACEForcedIdiom = desired;
    YTKACEIdiomForced = YES;
}

static BOOL YTKACEForcedIsIPad(__unused id receiver, __unused SEL selector) {
    return YTKACEForcedIdiom == UIUserInterfaceIdiomPad;
}

static void YTKACEAddInteraction(UIView *receiver, SEL selector, id interaction) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.App.DragDropDisabled") &&
        ([interaction isKindOfClass:UIDragInteraction.class] ||
         [interaction isKindOfClass:UIDropInteraction.class])) {
        return;
    }
    if (OriginalAddInteraction != NULL) {
        ((void (*)(id, SEL, id))OriginalAddInteraction)(receiver, selector, interaction);
    }
}

static UISemanticContentAttribute YTKACESemanticContent(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.App.RTLDisabled")) {
        return UISemanticContentAttributeForceLeftToRight;
    }
    return OriginalSemanticContent != NULL
        ? ((UISemanticContentAttribute (*)(id, SEL))OriginalSemanticContent)(receiver, selector)
        : UISemanticContentAttributeUnspecified;
}

static void YTKACESetSemanticContent(id receiver,
                                     SEL selector,
                                     UISemanticContentAttribute value) {
    if (OriginalSetSemanticContent != NULL) {
        ((void (*)(id, SEL, UISemanticContentAttribute))OriginalSetSemanticContent)(
            receiver,
            selector,
            YTKACEFeatureEnabled(@"YTKACE.Preference.App.RTLDisabled")
                ? UISemanticContentAttributeForceLeftToRight
                : value
        );
    }
}

static BOOL YTKACEMiniPlayerValue(id receiver, SEL selector) {
    if (YTKACEMiniPlayerEnabled()) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return !([name containsString:@"disable"] ||
                 [name containsString:@"unavailable"] ||
                 [name containsString:@"blocked"] ||
                 [name containsString:@"prevent"] ||
                 [name containsString:@"hide"] ||
                 [name containsString:@"onlywhenplaying"]);
    }
    IMP original = YTKACEMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL YTKACEMiniPlayerPauseOnlyValue(id receiver, SEL selector) {
    if (YTKACEMiniPlayerEnabled()) {
        return NO;
    }
    IMP original = YTKACEMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL YTKACEAgeValue(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Content.AgeGateBypass")) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return [name containsString:@"verified"] ||
            [name containsString:@"allowed"];
    }
    IMP original = YTKACEMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

NSInteger YTKACECaptionsMode(void) {
    if (!YTKACEMasterEnabled()) return 0;
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Playback.CaptionsMode"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CaptionsDisabled")) return 2;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.CaptionsAlwaysOn")) return 1;
    return 0;
}

static BOOL YTKACECaptionValue(id receiver, SEL selector) {
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    if ((YTKACECaptionsMode() == 2) && YTKACECaptionRequestReceiver(receiver, selector)) {
        return negative;
    }
    if ((YTKACECaptionsMode() == 1)) {
        if (!YTKACECaptionRequestReceiver(receiver, selector)) {
            IMP original = YTKACEMiscOriginal(receiver, selector);
            return original != NULL
                ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
        }
        if ([name containsString:@"respectdevicecaption"] ||
            [name containsString:@"hiddenonstart"]) {
            return NO;
        }
        return !negative;
    }
    IMP original = YTKACEMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static void YTKACECaptionSetter(id receiver, SEL selector, BOOL enabled) {
    IMP original = YTKACEMiscOriginal(receiver, selector);
    if (original == NULL) {
        return;
    }
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    BOOL value = enabled;
    if ((YTKACECaptionsMode() == 2) && YTKACECaptionRequestReceiver(receiver, selector)) {
        value = negative;
    } else if ((YTKACECaptionsMode() == 1) &&
               YTKACECaptionRequestReceiver(receiver, selector)) {
        value = !negative;
    }
    ((void (*)(id, SEL, BOOL))original)(receiver, selector, value);
}

static id YTKACEFirstCaptionTrack(id tracks) {
    if ([tracks isKindOfClass:NSArray.class]) {
        return [tracks firstObject];
    }
    if ([tracks respondsToSelector:@selector(allObjects)]) {
        id objects = ((id (*)(id, SEL))objc_msgSend)(tracks,
                                                     @selector(allObjects));
        return [objects isKindOfClass:NSArray.class] ? [objects firstObject] : nil;
    }
    return nil;
}

static NSString *YTKACETrackText(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTKACEBestCaptionTrackForLanguage(NSArray *tracks, NSString *language) {
    if (language.length == 0) return nil;
    NSString *base = [[language.lowercaseString componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    id best = nil;
    NSInteger bestRank = NSIntegerMax;
    for (id track in tracks) {
        NSString *code = YTKACETrackText(track, @"languageCode").lowercaseString;
        if (code.length == 0) continue;
        NSString *codeBase = [[code componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
        if (![code isEqualToString:language.lowercaseString] && ![codeBase isEqualToString:base]) continue;
        NSString *vss = YTKACETrackText(track, @"VSSID") ?: @"";
        NSInteger rank = [vss hasPrefix:@"."] ? 0 : ([vss hasPrefix:@"a."] ? 1 : 2);
        if (rank < bestRank) {
            bestRank = rank;
            best = track;
        }
    }
    return best;
}

static id YTKACEPreferredCaptionTrack(id tracks) {
    id first = YTKACEFirstCaptionTrack(tracks);
    if (first == nil) return nil;
    NSArray *list = [tracks isKindOfClass:NSArray.class] ? tracks
        : ([tracks respondsToSelector:@selector(allObjects)]
            ? ((id (*)(id, SEL))objc_msgSend)(tracks, @selector(allObjects)) : nil);
    if (![list isKindOfClass:NSArray.class]) return first;
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:@"YTKACE.Preference.Playback.CaptionLanguage"];
    id match = YTKACEBestCaptionTrackForLanguage(list, preferred);
    for (NSString *language in NSLocale.preferredLanguages) {
        if (match != nil) break;
        match = YTKACEBestCaptionTrackForLanguage(list, language);
    }
    if (match != nil) return match;
    for (id track in list) {
        if (![[YTKACETrackText(track, @"VSSID") ?: @"" lowercaseString] hasPrefix:@"t"]) return track;
    }
    return first;
}

static void YTKACEScheduleCaptionSelection(id track) {
    if (track == nil || !(YTKACECaptionsMode() == 1)) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *key = YTKACECaptionTrackKey(track);
        NSArray *controllers = nil;
        @synchronized (YTKACECaptionControllers) {
            controllers = YTKACECaptionControllers.allObjects;
        }
        for (id controller in controllers) {
            NSString *applied = objc_getAssociatedObject(
                controller, YTKACEAppliedCaptionAssociation);
            if ([applied isEqualToString:key]) {
                continue;
            }
            SEL selector = NSSelectorFromString(
                @"setSelectedCaptionTrack:selectionReason:");
            if (![controller respondsToSelector:selector]) {
                continue;
            }
            objc_setAssociatedObject(controller,
                YTKACEAppliedCaptionAssociation, key,
                OBJC_ASSOCIATION_COPY_NONATOMIC);
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(
                controller, selector, track, 1);
        }
    });
}

static id YTKACECaptionControllerAlloc(id receiver, SEL selector, NSZone *zone) {
    id result = OriginalCaptionControllerAlloc != NULL
        ? ((id (*)(id, SEL, NSZone *))OriginalCaptionControllerAlloc)(
            receiver, selector, zone) : nil;
    if (result != nil) {
        @synchronized (YTKACECaptionControllers) {
            [YTKACECaptionControllers addObject:result];
        }
    }
    return result;
}

static id YTKACECaptionControllerInit(id receiver, SEL selector) {
    IMP original = YTKACEMiscOriginal(receiver, selector);
    id result = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector) : receiver;
    if (result != nil) {
        @synchronized (YTKACECaptionControllers) {
            [YTKACECaptionControllers addObject:result];
        }
    }
    return result;
}

static void YTKACECaptionTracksSetter(id receiver, SEL selector, id tracks) {
    IMP original = YTKACEMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, tracks);
    }
    id track = YTKACEPreferredCaptionTrack(tracks);
    id previousTrack = objc_getAssociatedObject(
        receiver, YTKACELastCaptionTrackAssociation);
    if (previousTrack != track) {
        objc_setAssociatedObject(receiver, YTKACELastCaptionTrackAssociation,
                                 track, OBJC_ASSOCIATION_ASSIGN);
        YTKACEScheduleCaptionSelection(track);
    }
    if (track == nil) {
        return;
    }
    objc_setAssociatedObject(receiver,
                             YTKACECaptionTracksAssociation,
                             tracks,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTKACECaptionTrackSetter(id receiver, SEL selector, id track) {
    IMP original = YTKACEMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, track);
    }
}

static void YTKACECaptionSelectedTrackSetter(id receiver,
                                             SEL selector,
                                             id track,
                                             NSInteger reason) {
    IMP original = YTKACEMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id, NSInteger))original)(receiver,
                                                      selector,
                                                      track,
                                                      reason);
    }
}

static void YTKACEHUDMessage(id receiver, SEL selector, id message) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.App.HUDAlertsHidden")) {
        return;
    }
    NSString *text = nil;
    if ([message isKindOfClass:NSString.class]) {
        text = message;
    } else if ([message isKindOfClass:NSAttributedString.class]) {
        text = [(NSAttributedString *)message string];
    } else {
        for (NSString *name in @[@"text", @"message", @"title"]) {
            SEL valueSelector = NSSelectorFromString(name);
            if (![message respondsToSelector:valueSelector]) {
                continue;
            }
            id value = ((id (*)(id, SEL))objc_msgSend)(message,
                                                       valueSelector);
            if ([value isKindOfClass:NSString.class]) {
                text = value;
                break;
            }
            if ([value isKindOfClass:NSAttributedString.class]) {
                text = [(NSAttributedString *)value string];
                break;
            }
        }
    }
    NSString *lower = text.lowercaseString;
    if (YTKACEMiniPlayerEnabled() &&
        [lower containsString:@"miniplayer"] &&
        [lower containsString:@"kids"]) {
        return;
    }
    IMP original = YTKACEMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, message);
    }
}

static void YTKACEStoreMiscOriginal(NSString *className,
                                    NSString *selectorName,
                                    IMP original) {
    Class cls = NSClassFromString(className);
    if (cls != Nil && original != NULL) {
        YTKACEMiscOriginals[YTKACEMiscKey(
            cls,
            NSSelectorFromString(selectorName)
        )] = [NSValue valueWithPointer:(const void *)original];
    }
}

static void YTKACEInstallMiscBool(NSString *className,
                                  NSString *selectorName,
                                  IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return;
    }
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, selectorName, replacement, &original)) {
        YTKACEStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTKACEInstallMiscSetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, selectorName, replacement, &original)) {
        YTKACEStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTKACEInstallMiscObjectSetter(NSString *className,
                                          NSString *selectorName,
                                          IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, selectorName,
                                  replacement, &original)) {
        YTKACEStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTKACEInstallCaptionSelectedSetter(NSString *className) {
    NSString *selectorName = @"setSelectedCaptionTrack:selectionReason:";
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, selectorName,
                                  (IMP)YTKACECaptionSelectedTrackSetter,
                                  &original)) {
        YTKACEStoreMiscOriginal(className, selectorName, original);
    }
}

static BOOL YTKACEClassNameMatches(NSString *className,
                                   NSArray<NSString *> *tokens) {
    NSString *lower = className.lowercaseString;
    for (NSString *token in tokens) {
        if ([lower containsString:token]) {
            return YES;
        }
    }
    return NO;
}

static NSString *YTKACEMiscDiscoveryCacheKey(void) {
    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    return [@"YTKACEMiscHookTargets." stringByAppendingString:version];
}

static void YTKACEApplyMiscDiscoveryTarget(NSString *target) {
    NSArray<NSString *> *parts = [target componentsSeparatedByString:@"|"];
    if (parts.count != 3) return;
    NSString *kind = parts[0];
    NSString *className = parts[1];
    NSString *selectorName = parts[2];
    if ([kind isEqualToString:@"mini"]) {
        YTKACEInstallMiscBool(className, selectorName,
                              (IMP)YTKACEMiniPlayerValue);
    } else if ([kind isEqualToString:@"miniPause"]) {
        YTKACEInstallMiscBool(className, selectorName,
                              (IMP)YTKACEMiniPlayerPauseOnlyValue);
    } else if ([kind isEqualToString:@"captionBool"]) {
        YTKACEInstallMiscBool(className, selectorName,
                              (IMP)YTKACECaptionValue);
    } else if ([kind isEqualToString:@"captionSetter"]) {
        YTKACEInstallMiscSetter(className, selectorName,
                                (IMP)YTKACECaptionSetter);
    } else if ([kind isEqualToString:@"captionTracks"]) {
        YTKACEInstallMiscObjectSetter(className, selectorName,
                                      (IMP)YTKACECaptionTracksSetter);
    } else if ([kind isEqualToString:@"captionTrack"]) {
        YTKACEInstallMiscObjectSetter(className, selectorName,
                                      (IMP)YTKACECaptionTrackSetter);
    } else if ([kind isEqualToString:@"captionSelected"]) {
        YTKACEInstallCaptionSelectedSetter(className);
    }
}

static void YTKACEApplyCachedMiscDiscovery(void) {
    NSArray<NSString *> *targets = [NSUserDefaults.standardUserDefaults
        arrayForKey:YTKACEMiscDiscoveryCacheKey()];
    for (NSString *target in targets) {
        YTKACEApplyMiscDiscoveryTarget(target);
    }
}

static void YTKACEDiscoverMiscHooks(void) {
    NSSet<NSString *> *miniSelectors = [NSSet setWithArray:@[
        @"isPlayableInMiniPlayer", @"isPlayableInMiniplayer",
        @"miniplayerEnabled", @"isMiniplayerDisabled",
        @"miniPlayerDisabled", @"isMiniplayerUnavailable",
        @"enableIosFloatingMiniplayer", @"enableMiniPlayerOnlyWhenPlaying",
        @"disableMiniPlayerWhenPaused", @"disableIphoneMiniplayerTransitionFix",
        @"enableIosFloatingMiniplayerTransitionBugFix",
        @"enableMiniplayerErrorFix", @"enableMiniplayerChangesPostCairo",
        @"shouldOpenMiniplayerOnStateChange", @"shouldShowMiniPlayer",
        @"hasShouldShowMiniPlayer", @"hasDisplayMiniPlayer",
        @"hasMiniplayer", @"isMiniplayer", @"allowDockingForMiniplayer",
        @"blockedForKidsContent", @"hasBlockedForKidsContent"
    ]];
    NSSet<NSString *> *captionGetters = [NSSet setWithArray:@[
        @"captionsEnabled", @"areCaptionsEnabled", @"captionEnabled",
        @"isCaptionEnabled", @"closedCaptionsEnabled",
        @"closedCaptioningEnabled", @"captionsEnabledWhenAvailable",
        @"shouldShowCaptions", @"captionsActive", @"captionVisible",
        @"captionsVisible", @"captionsRequested", @"deviceCaptionsOn",
        @"captionsDisabled", @"captionsHidden",
        @"captionVisibilityPersistenceEnabled",
        @"captionLanguagePersistenceEnabled", @"respectDeviceCaptionSetting",
        @"inlinePlaybackCaptionHiddenOnStartEnabled"
    ]];
    NSSet<NSString *> *captionSetters = [NSSet setWithArray:@[
        @"setCaptionsEnabled:", @"setClosedCaptionsEnabled:",
        @"setCaptionEnabled:", @"setIsCaptionEnabled:",
        @"setCaptionsActive:", @"setCaptionVisible:",
        @"setCaptionsVisible:", @"setCaptionsRequested:",
        @"setDeviceCaptionsOn:", @"setCaptionsDisabled:",
        @"setCaptionsHidden:", @"setPersistentUserCaptionVisibility:",
        @"setUserPreferredCaptionVisibilityAsHidden:"
    ]];
    NSSet<NSString *> *trackLists = [NSSet setWithArray:@[
        @"setAvailableCaptionTracks:", @"setCaptionTrackArray:",
        @"setUserVisibleCaptionTracks:", @"setTracklistCaptionTracks:"
    ]];
    NSSet<NSString *> *trackSetters = [NSSet setWithArray:@[
        @"setActiveCaptionTrack:", @"setCaptionTrack:"
    ]];
    NSArray<NSString *> *miniTokens = @[
        @"mini", @"playability", @"playerresponse",
        @"watch", @"playerhotconfig", @"globalconfig"
    ];
    NSArray<NSString *> *captionTokens = @[
        @"caption", @"player", @"playback", @"watch", @"globalconfig"
    ];
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *className in YTKACEAppClassNames()) {
        BOOL mini = YTKACEClassNameMatches(className, miniTokens);
        BOOL caption = YTKACEClassNameMatches(className, captionTokens);
        if (!mini && !caption) continue;
        Class cls = NSClassFromString(className);
        if (cls == Nil) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            NSString *selectorName = NSStringFromSelector(
                method_getName(methods[methodIndex])
            );
            NSString *kind = nil;
            if (mini && [selectorName isEqualToString:
                         @"isMiniplayerRendererPlaybackModePauseOnly"]) {
                kind = @"miniPause";
            } else if (mini && [miniSelectors containsObject:selectorName]) {
                kind = @"mini";
            } else if (caption &&
                       [captionGetters containsObject:selectorName]) {
                kind = @"captionBool";
            } else if (caption &&
                       [captionSetters containsObject:selectorName]) {
                kind = @"captionSetter";
            } else if (caption &&
                       [trackLists containsObject:selectorName]) {
                kind = @"captionTracks";
            } else if (caption &&
                       [trackSetters containsObject:selectorName]) {
                kind = @"captionTrack";
            } else if (caption && [selectorName isEqualToString:
                       @"setSelectedCaptionTrack:selectionReason:"]) {
                kind = @"captionSelected";
            }
            if (kind != nil) {
                [targets addObject:[NSString stringWithFormat:@"%@|%@|%@",
                    kind, className, selectorName]];
            }
        }
        free(methods);
    }

    NSArray<NSString *> *result = targets.array;
    [NSUserDefaults.standardUserDefaults setObject:result
                                    forKey:YTKACEMiscDiscoveryCacheKey()];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *target in result) {
            YTKACEApplyMiscDiscoveryTarget(target);
        }
    });
}

void YTKACEInstallMiscellaneousHooks(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"YTKACE.Preference.Playback.CaptionsMode"] == nil) {
        NSInteger legacy = [defaults boolForKey:@"YTKACE.Preference.Playback.CaptionsDisabled"] ? 2
            : ([defaults boolForKey:@"YTKACE.Preference.Playback.CaptionsAlwaysOn"] ? 1 : 0);
        if (legacy != 0) [defaults setInteger:legacy forKey:@"YTKACE.Preference.Playback.CaptionsMode"];
    }
    if (YTKACEMiscOriginals == nil) {
        YTKACEMiscOriginals = [NSMutableDictionary dictionary];
        YTKACECaptionControllers = [NSHashTable weakObjectsHashTable];
    }
    YTKACEResolveForcedIdiom();
    if (YTKACEIdiomForced) {
        YTKACEComputeIdiomRanges();
        for (NSString *name in @[@"YTCommonUtils", @"OGLMetrics"]) {
            YTKACEInstallClassHook(name, @"isIPad",
                                   (IMP)YTKACEForcedIsIPad, NULL);
        }
        YTKACEInstallInstanceHook(@"UIDevice", @"userInterfaceIdiom",
                                  (IMP)YTKACEUserInterfaceIdiom,
                                  &OriginalDeviceIdiom);
    }
    YTKACEInstallInstanceHook(@"UIView", @"addInteraction:",
                              (IMP)YTKACEAddInteraction,
                              &OriginalAddInteraction);
    YTKACEInstallInstanceHook(@"UIView", @"semanticContentAttribute",
                              (IMP)YTKACESemanticContent,
                              &OriginalSemanticContent);
    YTKACEInstallInstanceHook(@"UIView", @"setSemanticContentAttribute:",
                              (IMP)YTKACESetSemanticContent,
                              &OriginalSetSemanticContent);
    NSArray<NSString *> *miniClasses = @[
        @"YTIPlayabilityStatus",
        @"YTPlayerResponse",
        @"YTIPlayerResponse",
        @"YTMiniplayerController"
    ];
    NSArray<NSString *> *miniSelectors = @[
        @"isPlayableInMiniPlayer",
        @"isPlayableInMiniplayer",
        @"miniplayerEnabled",
        @"isMiniplayerDisabled",
        @"miniPlayerDisabled",
        @"isMiniplayerUnavailable"
    ];
    for (NSString *className in miniClasses) {
        YTKACEInstallMiscBool(className,
            @"isMiniplayerRendererPlaybackModePauseOnly",
            (IMP)YTKACEMiniPlayerPauseOnlyValue);
        for (NSString *selectorName in miniSelectors) {
            YTKACEInstallMiscBool(className, selectorName, (IMP)YTKACEMiniPlayerValue);
        }
    }

    for (NSString *className in @[@"YTIPlayabilityStatus", @"YTPlayerResponse"] ) {
        for (NSString *selectorName in @[
            @"isAgeRestricted",
            @"requiresAgeVerification",
            @"shouldShowAgeGate",
            @"ageGateRequired",
            @"isAgeVerified",
            @"isAgeAllowed"
        ]) {
            YTKACEInstallMiscBool(className, selectorName, (IMP)YTKACEAgeValue);
        }
    }

    NSArray<NSString *> *captionClasses = @[
        @"YTPlayerViewController",
        @"YTLocalPlaybackController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTCaptionController"
    ];
    for (NSString *className in captionClasses) {
        for (NSString *selectorName in @[
            @"captionsEnabled",
            @"areCaptionsEnabled",
            @"isCaptionTrackSelected",
            @"closedCaptionsEnabled",
            @"captionsDisabled"
        ]) {
            YTKACEInstallMiscBool(className, selectorName, (IMP)YTKACECaptionValue);
        }
        for (NSString *selectorName in @[
            @"setCaptionsEnabled:",
            @"setClosedCaptionsEnabled:"
        ]) {
            YTKACEInstallMiscSetter(className, selectorName, (IMP)YTKACECaptionSetter);
        }
    }

    NSString *controllerClass = @"MLInnerTubeCaptionController";
    YTKACEInstallClassHook(controllerClass, @"allocWithZone:",
                          (IMP)YTKACECaptionControllerAlloc,
                          &OriginalCaptionControllerAlloc);
    IMP controllerOriginal = NULL;
    if (YTKACEInstallInstanceHook(controllerClass, @"init",
                                  (IMP)YTKACECaptionControllerInit,
                                  &controllerOriginal)) {
        YTKACEStoreMiscOriginal(controllerClass, @"init",
                                controllerOriginal);
    }
    YTKACEApplyCachedMiscDiscovery();
    static dispatch_once_t discoveryObserverToken;
    dispatch_once(&discoveryObserverToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            if ([NSUserDefaults.standardUserDefaults
                    arrayForKey:YTKACEMiscDiscoveryCacheKey()].count != 0) {
                return;
            }
            static dispatch_once_t discoveryToken;
            dispatch_once(&discoveryToken, ^{
                for (NSNumber *delay in @[@0.5, @5.0]) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            YTKACEDiscoverMiscHooks();
                        }
                    );
                }
            });
        }];
    });

    for (NSString *selectorName in @[@"showMessageMainThread:", @"showMessage:"]) {
        IMP original = NULL;
        if (YTKACEInstallInstanceHook(@"GOOHUDManagerInternal",
                                      selectorName,
                                      (IMP)YTKACEHUDMessage,
                                      &original)) {
            YTKACEStoreMiscOriginal(@"GOOHUDManagerInternal", selectorName, original);
        }
    }
}
