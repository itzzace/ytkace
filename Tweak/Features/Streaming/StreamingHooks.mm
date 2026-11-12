#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <CoreGraphics/CoreGraphics.h>

static IMP OriginalLegacyQuality;
static IMP OriginalSetUserSelectableFormats;
static IMP OriginalDidLoadContentPlaybackData;
static IMP OriginalQualityHandleTap;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEStreamingOriginals;
static const void *YTKACERedesignedQualityControllerKey =
    &YTKACERedesignedQualityControllerKey;

static NSString *YTKACEStreamingKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEStreamingOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP value = (IMP)[YTKACEStreamingOriginals[
            YTKACEStreamingKey(cls, selector)] pointerValue];
        if (value != NULL) {
            return value;
        }
    }
    return NULL;
}

static BOOL YTKACELegacyQuality(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.LegacyQualityMenu")) {
        return NO;
    }
    return OriginalLegacyQuality != NULL
        ? ((BOOL (*)(id, SEL))OriginalLegacyQuality)(receiver, selector)
        : NO;
}

static id YTKACEValue(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<NSString *> *YTKACEQualityLabels(void) {
    return @[@"", @"2160p60", @"2160p", @"1440p60", @"1440p",
             @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
             @"360p", @"240p", @"144p"];
}

// AirPlay video, AirPlay audio or a mirrored screen.
static BOOL YTKACEExternalPlayback(void) {
    if (UIScreen.screens.count > 1) return YES;
    for (AVAudioSessionPortDescription *output in
         AVAudioSession.sharedInstance.currentRoute.outputs) {
        if ([output.portType isEqualToString:AVAudioSessionPortAirPlay]) return YES;
    }
    return NO;
}

static NSInteger YTKACEQualityIndex(void) {
    SCNetworkReachabilityRef reachability =
        SCNetworkReachabilityCreateWithName(NULL, "youtube.com");
    SCNetworkReachabilityFlags flags = 0;
    BOOL hasFlags = reachability != NULL &&
        SCNetworkReachabilityGetFlags(reachability, &flags);
    if (reachability != NULL) {
        CFRelease(reachability);
    }
    BOOL onCellular = hasFlags &&
        (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;
    BOOL onWiFi = !onCellular;
    NSString *key = onWiFi ? @"YTKACE.Preference.Playback.WiFiQuality" : @"YTKACE.Preference.Playback.CellularQuality";
    NSInteger count = (NSInteger)YTKACEQualityLabels().count;
    // Low Power Mode, then AirPlay, then the network. -1 (Off) falls through.
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (NSProcessInfo.processInfo.lowPowerModeEnabled) {
        [keys addObject:@"YTKACE.Preference.Playback.LowPowerQuality"];
    }
    if (YTKACEExternalPlayback()) {
        [keys addObject:onWiFi ? @"YTKACE.Preference.Playback.AirPlayWiFiQuality"
                               : @"YTKACE.Preference.Playback.AirPlayCellularQuality"];
    }
    [keys addObject:key];
    for (NSString *candidate in keys) {
        id value = YTKACEPreferenceObject(candidate);
        NSInteger index = [value respondsToSelector:@selector(integerValue)]
            ? [value integerValue] : (candidate == key ? 0 : -1);
        if (index < 0 && candidate != key) continue;
        return index >= 0 && index < count ? index : 0;
    }
    return 0;
}

static NSInteger YTKACEResolution(NSString *label) {
    NSScanner *scanner = [NSScanner scannerWithString:label ?: @""];
    NSInteger value = 0;
    return [scanner scanInteger:&value] ? value : 0;
}

static NSString *YTKACETargetQualityLabel(NSArray *formats, NSString *target) {
    NSString *nearest = nil;
    NSInteger nearestDistance = NSIntegerMax;
    NSInteger targetResolution = YTKACEResolution(target);
    for (id format in formats) {
        id value = YTKACEValue(format, @"qualityLabel");
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *label = value;
        if ([label isEqualToString:target]) {
            return label;
        }
        if ([label rangeOfString:@"Premium"
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }
        NSInteger resolution = YTKACEResolution(label);
        NSInteger distance = labs(resolution - targetResolution);
        if (resolution > 0 && distance < nearestDistance) {
            nearest = label;
            nearestDistance = distance;
        }
    }
    return nearest;
}

static __weak id YTKACEQualityController;

static void YTKACEApplyPreferredQuality(id controller) {
    NSInteger index = YTKACEQualityIndex();
    if (index == 0) {
        return;
    }
    id activeVideo = YTKACEValue(controller, @"activeVideo");
    id formats = YTKACEValue(activeVideo, @"selectableVideoFormats");
    if (![formats isKindOfClass:NSArray.class] || [formats count] == 0) {
        return;
    }
    NSString *label = YTKACETargetQualityLabel(formats, YTKACEQualityLabels()[index]);
    Class constraintClass = NSClassFromString(
        @"MLQuickMenuVideoQualitySettingFormatConstraint");
    SEL initializer = NSSelectorFromString(
        @"initWithVideoQualitySetting:formatSelectionReason:qualityLabel:");
    SEL setter = NSSelectorFromString(@"setVideoFormatConstraint:");
    if (label.length == 0 || constraintClass == Nil ||
        ![activeVideo respondsToSelector:setter]) {
        return;
    }
    id allocated = [constraintClass alloc];
    if (![allocated respondsToSelector:initializer]) {
        return;
    }
    id constraint = ((id (*)(id, SEL, NSInteger, NSInteger, id))objc_msgSend)(
        allocated, initializer, 3, 2, label);
    if (constraint != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(activeVideo, setter, constraint);
    }
}

BOOL YTKACEPlayerIsShorts(id player) {
    SEL parentSelector = NSSelectorFromString(@"parentViewController");
    id current = player;
    for (NSUInteger depth = 0; current != nil && depth < 6; depth++) {
        NSString *name = NSStringFromClass(object_getClass(current));
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"]) {
            return YES;
        }
        if (![current respondsToSelector:parentSelector]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSelector);
    }
    return NO;
}

static void YTKACEDidLoadContentPlaybackData(id receiver,
                                              SEL selector,
                                              id playbackController,
                                              id playbackData) {
    if (OriginalDidLoadContentPlaybackData != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidLoadContentPlaybackData)(
            receiver, selector, playbackController, playbackData);
    }
    if (playbackController == nil || playbackData == nil ||
        YTKACEQualityIndex() == 0) {
        return;
    }
    if (YTKACEPlayerIsShorts(receiver)) {
        return;
    }
    YTKACEQualityController = receiver;
    __weak id weakReceiver = receiver;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        YTKACEApplyPreferredQuality(weakReceiver);
    });
}

// AirPlay or Low Power Mode changed during a video.
static void YTKACEQualityScenarioChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSInteger lastIndex = -1;
        NSInteger index = YTKACEQualityIndex();
        if (index == lastIndex) return;
        BOOL first = lastIndex == -1;
        lastIndex = index;
        id controller = YTKACEQualityController;
        if (!first && index != 0 && controller != nil) YTKACEApplyPreferredQuality(controller);
    });
}

static void YTKACEObserveQualityScenario(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[AVAudioSessionRouteChangeNotification,
                                      UIScreenDidConnectNotification,
                                      UIScreenDidDisconnectNotification,
                                      NSProcessInfoPowerStateDidChangeNotification]) {
        [center addObserverForName:name object:nil queue:nil
                        usingBlock:^(__unused NSNotification *note) {
            YTKACEQualityScenarioChanged();
        }];
    }
    YTKACEQualityScenarioChanged();
}




static IMP OriginalAVEligibleForHDR;
static IMP OriginalAVAvailableHDRModes;

static BOOL YTKACECallerIsYouTube(const void *address) {
    static const void *mainBase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (uint32_t index = 0; index < _dyld_image_count(); index++) {
            const struct mach_header *header = _dyld_get_image_header(index);
            if (header != NULL && header->filetype == MH_EXECUTE) {
                mainBase = header;
                break;
            }
        }
    });
    Dl_info info;
    return address != NULL && mainBase != NULL &&
        dladdr(address, &info) != 0 && info.dli_fbase == mainBase;
}

static BOOL YTKACEHDRSuppressed(const void *caller) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.HDRDisabled") &&
        YTKACECallerIsYouTube(caller);
}

static BOOL YTKACEAVEligibleForHDR(id receiver, SEL selector) {
    if (YTKACEHDRSuppressed(__builtin_return_address(0))) return NO;
    return OriginalAVEligibleForHDR != NULL
        ? ((BOOL (*)(id, SEL))OriginalAVEligibleForHDR)(receiver, selector) : NO;
}

static NSInteger YTKACEAVAvailableHDRModes(id receiver, SEL selector) {
    if (YTKACEHDRSuppressed(__builtin_return_address(0))) return 0;
    return OriginalAVAvailableHDRModes != NULL
        ? ((NSInteger (*)(id, SEL))OriginalAVAvailableHDRModes)(receiver, selector) : 0;
}


static NSArray *YTKACEFormatsWithoutPremium(NSArray *formats) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.PremiumQualityHidden") ||
        ![formats isKindOfClass:NSArray.class]) {
        return formats;
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (id format in formats) {
        id label = YTKACEValue(format, @"qualityLabel");
        if ([label isKindOfClass:NSString.class] &&
            [label rangeOfString:@"Premium"
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }
        [kept addObject:format];
    }
    return kept.count != 0 ? kept : formats;
}

static IMP OriginalRedesignedSetFormats;

static void YTKACERedesignedSetFormats(id receiver, SEL selector, NSArray *formats) {
    NSArray *selected = YTKACEFormatsWithoutPremium(formats);
    if (OriginalRedesignedSetFormats != NULL) {
        ((void (*)(id, SEL, id))OriginalRedesignedSetFormats)(receiver, selector,
                                                              selected);
    }
}

static void YTKACESetUserSelectableFormats(id receiver,
                                            SEL selector,
                                            NSArray *formats) {
    NSArray *selectedFormats = formats;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.LegacyQualityMenu")) {
        id redesigned = objc_getAssociatedObject(
            receiver, YTKACERedesignedQualityControllerKey);
        if (redesigned == nil) {
            Class controllerClass = NSClassFromString(
                @"YTVideoQualitySwitchRedesignedController");
            SEL initializer = NSSelectorFromString(
                @"initWithServiceRegistryScope:parentResponder:");
            id allocated = [controllerClass alloc];
            if ([allocated respondsToSelector:initializer]) {
                redesigned = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    allocated, initializer, nil, nil);
                objc_setAssociatedObject(receiver,
                    YTKACERedesignedQualityControllerKey,
                    redesigned,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        id video = YTKACEValue(receiver, @"_video");
        if (redesigned != nil && video != nil) {
            @try {
                [redesigned setValue:video forKey:@"_video"];
            } @catch (__unused NSException *exception) {
            }
        }
        SEL restrictSelector = NSSelectorFromString(@"addRestrictedFormats:");
        if ([redesigned respondsToSelector:restrictSelector]) {
            id restricted = ((id (*)(id, SEL, id))objc_msgSend)(
                redesigned, restrictSelector, formats);
            if ([restricted isKindOfClass:NSArray.class]) {
                selectedFormats = restricted;
            }
        }
    }
    selectedFormats = YTKACEFormatsWithoutPremium(selectedFormats);
    if (OriginalSetUserSelectableFormats != NULL) {
        ((void (*)(id, SEL, id))OriginalSetUserSelectableFormats)(
            receiver, selector, selectedFormats);
    }
}

static void YTKACEQualityHandleTap(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.LegacyQualityMenu")) {
        id controller = YTKACEValue(receiver, @"_controller");
        id node = YTKACEValue(controller, @"node");
        SEL identifierSelector = NSSelectorFromString(@"accessibilityIdentifier");
        SEL labelSelector = NSSelectorFromString(@"accessibilityLabel");
        NSString *identifier = [node respondsToSelector:identifierSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, identifierSelector) : nil;
        NSString *label = [node respondsToSelector:labelSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, labelSelector) : nil;
        NSRegularExpression *quality = [NSRegularExpression
            regularExpressionWithPattern:@"\\d+p" options:0 error:nil];
        BOOL qualityRow = [identifier hasPrefix:
            @"id.elements.components.overflow_menu_item_"] &&
            [label isKindOfClass:NSString.class] &&
            [quality firstMatchInString:label options:0
                range:NSMakeRange(0, label.length)] != nil;
        SEL closestSelector = NSSelectorFromString(@"closestViewController");
        id sheet = qualityRow && [node respondsToSelector:closestSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, closestSelector) : nil;
        Class sheetClass = NSClassFromString(@"YTActionSheetDialogViewController");
        Class bottomSheetClass = NSClassFromString(@"YTBottomSheetController");
        SEL parentSelector = NSSelectorFromString(@"parentViewController");
        id parent = [sheet respondsToSelector:parentSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(sheet, parentSelector) : nil;
        if (sheetClass != Nil && bottomSheetClass != Nil &&
            [sheet isKindOfClass:sheetClass] && [parent isKindOfClass:bottomSheetClass]) {
            id delegate = YTKACEValue(sheet, @"delegate");
            id overlay = YTKACEValue(delegate, @"parentResponder");
            Class overlayClass = NSClassFromString(
                @"YTMainAppVideoPlayerOverlayViewController");
            SEL qualitySelector = NSSelectorFromString(@"didPressVideoQuality:");
            if (overlayClass != Nil && [overlay isKindOfClass:overlayClass] &&
                [overlay respondsToSelector:qualitySelector]) {
                __weak id weakOverlay = overlay;
                SEL dismissSelector = NSSelectorFromString(
                    @"dismissViewControllerAnimated:completion:");
                void (^completion)(void) = ^{
                    id strongOverlay = weakOverlay;
                    if ([strongOverlay respondsToSelector:qualitySelector]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(
                            strongOverlay, qualitySelector, nil);
                    }
                };
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
                    overlay, dismissSelector, YES, completion);
                return;
            }
        }
    }
    if (OriginalQualityHandleTap != NULL) {
        ((void (*)(id, SEL))OriginalQualityHandleTap)(receiver, selector);
    }
}

static BOOL YTKACEAutoplayIsQueueConfig(id receiver) {
    NSString *name = NSStringFromClass(object_getClass(receiver));
    return [name containsString:@"QueueConfig"] ||
        [name containsString:@"GaplessPlaybackCoordinator"];
}

static BOOL YTKACEAutoplayValue(id receiver, SEL selector) {
    const BOOL disabled =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.AutoplayDisabled");
    BOOL result;
    if (disabled) {
        result = NO;
    } else if (YTKACEQueueHasItems() && YTKACEQueueOwnsCurrentVideo() &&
               !YTKACEAutoplayIsQueueConfig(receiver)) {
        result = NO;
    } else {
        IMP original = YTKACEStreamingOriginal(receiver, selector);
        result = original != NULL
            ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    }

    return result;
}

static void YTKACEAutoplaySetter(id receiver, SEL selector, BOOL enabled) {
    IMP original = YTKACEStreamingOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(
            receiver,
            selector,
            YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.AutoplayDisabled") ? NO : enabled
        );
    }
}

static BOOL YTKACECellularQualityValue(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.HDOnCellular")) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        BOOL limiter = [name containsString:@"limit"] ||
            [name containsString:@"restrict"] ||
            [name containsString:@"datasaver"] ||
            [name containsString:@"data_saver"];
        return !limiter;
    }
    IMP original = YTKACEStreamingOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static void YTKACEStoreStreamingOriginal(NSString *className,
                                         NSString *selectorName,
                                         IMP original) {
    if (original == NULL) {
        return;
    }
    Class cls = NSClassFromString(className);
    if (cls != Nil) {
        YTKACEStreamingOriginals[YTKACEStreamingKey(cls,
            NSSelectorFromString(selectorName))] =
            [NSValue valueWithPointer:(const void *)original];
    }
}

static BOOL YTKACEInstallBoolGetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return NO;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return NO;
    }
    IMP original = NULL;
    if (!YTKACEInstallInstanceHook(className, selectorName, replacement, &original)) {
        return NO;
    }
    YTKACEStoreStreamingOriginal(className, selectorName, original);
    return YES;
}

static BOOL YTKACEInstallBoolSetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return NO;
    }
    IMP original = NULL;
    if (!YTKACEInstallInstanceHook(className, selectorName, replacement, &original)) {
        return NO;
    }
    YTKACEStoreStreamingOriginal(className, selectorName, original);
    return YES;
}

void YTKACEInstallStreamingHooks(void) {
    if (YTKACEStreamingOriginals == nil) {
        YTKACEStreamingOriginals = [NSMutableDictionary dictionary];
    }
    YTKACEInstallClassHook(@"AVPlayer", @"eligibleForHDRPlayback",
                           (IMP)YTKACEAVEligibleForHDR, &OriginalAVEligibleForHDR);
    YTKACEInstallClassHook(@"AVPlayer", @"availableHDRModes",
                           (IMP)YTKACEAVAvailableHDRModes, &OriginalAVAvailableHDRModes);
    YTKACEInstallInstanceHook(
        @"YTVideoQualitySwitchRedesignedController", @"setUserSelectableFormats:",
        (IMP)YTKACERedesignedSetFormats, &OriginalRedesignedSetFormats);

    Class qualityClass = NSClassFromString(@"YTIMediaQualitySettingsHotConfig");
    Method qualityMethod = qualityClass == Nil ? NULL : class_getInstanceMethod(
        qualityClass,
        NSSelectorFromString(@"enableQuickMenuVideoQualitySettings")
    );
    if (qualityMethod != NULL) {
        YTKACEInstallInstanceHook(@"YTIMediaQualitySettingsHotConfig",
                                  @"enableQuickMenuVideoQualitySettings",
                                  (IMP)YTKACELegacyQuality,
                                  &OriginalLegacyQuality);
    } else {
        YTKACEAddInstanceMethod(@"YTIMediaQualitySettingsHotConfig",
                                @"enableQuickMenuVideoQualitySettings",
                                (IMP)YTKACELegacyQuality,
                                "B@:");
    }

    YTKACEInstallInstanceHook(@"YTVideoQualitySwitchOriginalController",
                              @"setUserSelectableFormats:",
                              (IMP)YTKACESetUserSelectableFormats,
                              &OriginalSetUserSelectableFormats);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didLoadContentPlaybackData:",
                              (IMP)YTKACEDidLoadContentPlaybackData,
                              &OriginalDidLoadContentPlaybackData);
    YTKACEObserveQualityScenario();
    YTKACEInstallInstanceHook(@"ELMTouchCommandPropertiesHandler",
                              @"handleTap",
                              (IMP)YTKACEQualityHandleTap,
                              &OriginalQualityHandleTap);

    NSArray<NSString *> *autoplayClasses = @[
        @"YTDefaultQueueConfig",
        @"YTGaplessPlaybackCoordinator",
        @"YTAdsControlFlowPlaybackCoordinator",
        @"YTSettings",
        @"YTSettingsImpl",
        @"YTUserDefaults",
        @"YTAutonavEndscreenController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTOverflowMenuView",
        @"YTOverflowMenuViewController",
        @"YTWatchFloatingMiniplayerViewController",
        @"YTWatchMiniBarViewController",
        @"YTAutoplayAutonavWatchFeedLayoutController",
        @"YTAutoplayAutonavController",
        @"YTAutonavController",
        @"YTLocalPlaybackController",
        @"YTPlayerViewController"
    ];
    NSArray<NSString *> *autoplayGetters = @[
        @"isAutonavEnabled",
        @"autonavEnabled",
        @"isAutoplayEnabled",
        @"autoplayEnabled",
        @"isAutoplayEnabledForContent",
        @"shouldAutoplay",
        @"shouldStartAutoplay"
    ];
    NSArray<NSString *> *autoplaySetters = @[
        @"setAutonavEnabled:",
        @"setAutoplayEnabled:",
        @"setIsAutoplayEnabled:"
    ];
    NSUInteger autoplayBound = 0;
    for (NSString *className in autoplayClasses) {
        if (NSClassFromString(className) == Nil) continue;
        for (NSString *selectorName in autoplayGetters) {
            if (YTKACEInstallBoolGetter(className, selectorName,
                                        (IMP)YTKACEAutoplayValue)) {
                autoplayBound++;
            }
        }
        for (NSString *selectorName in autoplaySetters) {
            if (YTKACEInstallBoolSetter(className, selectorName,
                                        (IMP)YTKACEAutoplaySetter)) {
                autoplayBound++;
            }
        }
    }
    YTKACEDownloadLog(@"autoplay", @"bound %lu hooks",
                      (unsigned long)autoplayBound);

    NSArray<NSString *> *qualityClasses = @[
        @"YTUserDefaults",
        @"YTPlaybackConfig",
        @"YTIPlayerConfig",
        @"YTIMediaQualitySettingsHotConfig"
    ];
    NSArray<NSString *> *qualitySelectors = @[
        @"isHDOnCellularEnabled",
        @"allowHDOnCellular",
        @"allowsHDOnCellular",
        @"isHighDefinitionOnCellularEnabled",
        @"shouldLimitVideoQualityOnCellular",
        @"isDataSaverEnabled"
    ];
    for (NSString *className in qualityClasses) {
        for (NSString *selectorName in qualitySelectors) {
            YTKACEInstallBoolGetter(className,
                                    selectorName,
                                    (IMP)YTKACECellularQualityValue);
        }
    }
}
