#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>

static IMP OriginalShouldBlockUpgradeDialog;
static IMP OriginalAdShieldSignals;
static IMP OriginalAdShieldSignalsWithoutIDFA;
static IMP OriginalAdsDecorateContext;
static IMP OriginalAccountAdsDecorateContext;
static IMP OriginalPlayerAdsArray;
static IMP OriginalAdSlotsArray;
static IMP OriginalAdPlacementsArray;
static IMP OriginalAdBreakParams;
static IMP OriginalAdNextParams;
static IMP OriginalAdParams;
static IMP OriginalEnableSkippableAd;
static IMP OriginalMDXSessionImplAdPlaying;
static IMP OriginalIsPlayingAd;
static IMP OriginalIsPlayingAdSurvey;
static IMP OriginalIsPlayingAdIntro;
static IMP OriginalCreateAdsPlaybackCoordinator;
static IMP OriginalReelContentModel;
static IMP OriginalReelShouldDisplay;
static IMP OriginalCompanionAd;
static IMP OriginalHasCompanionAdRenderer;
static IMP OriginalHasAppPromoCompanionAdRenderer;
static IMP OriginalHasShoppingCompanionAdRenderer;
static const void *YTKACEAdObjectAssociation = &YTKACEAdObjectAssociation;
static const void *YTKACESectionContentsAssociation =
    &YTKACESectionContentsAssociation;
static const void *YTKACESectionContentCountAssociation =
    &YTKACESectionContentCountAssociation;
static IMP OriginalURLSessionTaskResume;

static const char * const YTKACEAdMarkers[] = {
    "eml.ad",
    "eml_ad",
    "pagead/",
    "yt-ads-web-view-id",
    "compact_promoted",
    "grid_promoted",
    "promoted_sparkles",
    "promoted_discovery",
    "promoted_15_click",
    "promoted_native_text",
    ".promoted_video",
    "_promoted_video",
    "promoted_app_install",
    "promoted_text_banner",
    "shopping_ad_info_card",
    ".display_ad",
    "_display_ad",
    ".infeed_ad",
    "_infeed_ad",
    ".ad_slot",
    "_ad_slot",
    ".ad_badge",
    "_ad_badge",
    ".native_ad_badge",
    "_native_ad_badge",
    ".simple_ad_badge",
    "_simple_ad_badge",
    "YTIReelNonVideoAdsCustomData",
    "reelNonVideoAdsCustomData",
    "YTIReelNonVideoAdsCustomData_reelNonVideoAdsCustomData",
    "adsVideoWithContext",
    "ads_video_with_context",
    "shorts_ad",
    "shortsAd",
    "reel_ad",
    "reelAd"
};

typedef struct {
    int16_t next[128];
    int16_t fail;
    BOOL terminal;
} YTKACEAdTrieNode;

static YTKACEAdTrieNode YTKACEAdTrie[512];
static int32_t YTKACEAdTrieCount;

static void YTKACEAdTrieReset(int32_t node) {
    for (NSUInteger byte = 0; byte < 128; byte++) {
        YTKACEAdTrie[node].next[byte] = -1;
    }
    YTKACEAdTrie[node].fail = 0;
    YTKACEAdTrie[node].terminal = NO;
}

static void YTKACEAdTrieInsert(const char *marker) {
    int32_t state = 0;
    for (const unsigned char *byte = (const unsigned char *)marker;
         *byte != '\0'; byte++) {
        if (*byte >= 128) return;
        if (YTKACEAdTrie[state].next[*byte] < 0) {
            const int32_t capacity =
                (int32_t)(sizeof(YTKACEAdTrie) / sizeof(YTKACEAdTrie[0]));
            // Out of room: skip the rest of this marker instead of writing
            // past the table.
            if (YTKACEAdTrieCount + 1 >= capacity) return;
            int32_t node = ++YTKACEAdTrieCount;
            YTKACEAdTrieReset(node);
            YTKACEAdTrie[state].next[*byte] = (int16_t)node;
        }
        state = YTKACEAdTrie[state].next[*byte];
    }
    YTKACEAdTrie[state].terminal = YES;
}

static void YTKACEAdTrieBuild(void) {
    YTKACEAdTrieCount = 0;
    YTKACEAdTrieReset(0);
    NSUInteger markerCount = sizeof(YTKACEAdMarkers) / sizeof(YTKACEAdMarkers[0]);
    for (NSUInteger marker = 0; marker < markerCount; marker++) {
        YTKACEAdTrieInsert(YTKACEAdMarkers[marker]);
    }

    int16_t queue[512];
    int32_t head = 0;
    int32_t tail = 0;
    for (NSUInteger byte = 0; byte < 128; byte++) {
        int16_t next = YTKACEAdTrie[0].next[byte];
        if (next < 0) {
            YTKACEAdTrie[0].next[byte] = 0;
        } else {
            queue[tail++] = next;
        }
    }
    while (head < tail) {
        int16_t state = queue[head++];
        int16_t failure = YTKACEAdTrie[state].fail;
        YTKACEAdTrie[state].terminal =
            YTKACEAdTrie[state].terminal || YTKACEAdTrie[failure].terminal;
        for (NSUInteger byte = 0; byte < 128; byte++) {
            int16_t next = YTKACEAdTrie[state].next[byte];
            if (next < 0) {
                YTKACEAdTrie[state].next[byte] =
                    YTKACEAdTrie[failure].next[byte];
            } else {
                YTKACEAdTrie[next].fail =
                    YTKACEAdTrie[failure].next[byte];
                queue[tail++] = next;
            }
        }
    }
}

static BOOL YTKACEAdBytes(NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    int32_t state = 0;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t byte = bytes[index];
        if (byte >= 128) {
            state = 0;
            continue;
        }
        state = YTKACEAdTrie[state].next[byte];
        if (YTKACEAdTrie[state].terminal) return YES;
    }
    return NO;
}

static BOOL YTKACEAdsHostMatches(NSString *host, NSString *suffix) {
    NSUInteger hostLength = host.length;
    NSUInteger suffixLength = suffix.length;
    if (hostLength < suffixLength) return NO;
    if (![host hasSuffix:suffix]) return NO;
    if (hostLength == suffixLength) return YES;
    return [host characterAtIndex:hostLength - suffixLength - 1] == '.';
}

static BOOL YTKACEAdsHostIsBlocked(NSString *host) {
    if (host.length == 0) return NO;
    return YTKACEAdsHostMatches(host, @"doubleclick.net") ||
        YTKACEAdsHostMatches(host, @"googleadservices.com") ||
        YTKACEAdsHostMatches(host, @"googlesyndication.com");
}

static BOOL YTKACEAdsURLIsBlocked(NSURL *URL) {
    NSString *host = URL.host.lowercaseString;
    if (YTKACEAdsHostIsBlocked(host)) return YES;
    if (YTKACEAdsHostMatches(host, @"youtube.com") ||
        YTKACEAdsHostMatches(host, @"google.com")) {
        NSString *path = URL.path.lowercaseString;
        return [path hasPrefix:@"/pagead/"] ||
            [path hasPrefix:@"/ads/"] ||
            [path hasPrefix:@"/api/stats/ads"];
    }
    return NO;
}

static void YTKACEURLSessionTaskResume(NSURLSessionTask *task, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACENoAdsKey)) {
        NSURLRequest *request = task.currentRequest ?: task.originalRequest;
        if (YTKACEAdsURLIsBlocked(request.URL)) {
            [task cancel];
            return;
        }
    }
    if (OriginalURLSessionTaskResume != NULL) {
        ((void (*)(id, SEL))OriginalURLSessionTaskResume)(task, selector);
    }
}

static id YTKACECallObjectGetter(IMP implementation, id receiver, SEL selector) {
    return implementation == NULL
        ? nil
        : ((id (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL YTKACECallBooleanGetter(IMP implementation, id receiver, SEL selector) {
    return implementation != NULL &&
        ((BOOL (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL YTKACEShouldBlockUpgradeDialog(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? YES
        : YTKACECallBooleanGetter(OriginalShouldBlockUpgradeDialog, receiver, selector);
}

static id YTKACEEmptyDictionary(IMP original, id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? @{}
        : YTKACECallObjectGetter(original, receiver, selector);
}

static id YTKACEAdShieldSignals(id receiver, SEL selector) {
    return YTKACEEmptyDictionary(OriginalAdShieldSignals, receiver, selector);
}

static id YTKACEAdShieldSignalsWithoutIDFA(id receiver, SEL selector) {
    return YTKACEEmptyDictionary(OriginalAdShieldSignalsWithoutIDFA, receiver, selector);
}

static void YTKACEAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) && OriginalAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAdsDecorateContext)(receiver, selector, context);
    }
}

static void YTKACEAccountAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) &&
        OriginalAccountAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAccountAdsDecorateContext)(
            receiver,
            selector,
            context
        );
    }
}

static IMP OriginalAccountAdsDecorateService;
static IMP OriginalAdsDecorateService;

static void YTKACECallAdsDecorateService(IMP original,
                                         id receiver,
                                         SEL selector,
                                         id context,
                                         long long type) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) && original != NULL) {
        ((void (*)(id, SEL, id, long long))original)(
            receiver,
            selector,
            context,
            type
        );
    }
}

static void YTKACEAccountAdsDecorateService(id receiver,
                                            SEL selector,
                                            id context,
                                            long long type) {
    YTKACECallAdsDecorateService(OriginalAccountAdsDecorateService,
                                 receiver,
                                 selector,
                                 context,
                                 type);
}

static void YTKACEAdsDecorateService(id receiver,
                                     SEL selector,
                                     id context,
                                     long long type) {
    YTKACECallAdsDecorateService(OriginalAdsDecorateService,
                                 receiver,
                                 selector,
                                 context,
                                 type);
}

static id YTKACEPlayerAdsArray(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? [NSMutableArray array]
        : YTKACECallObjectGetter(OriginalPlayerAdsArray, receiver, selector);
}

static id YTKACEAdSlotsArray(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? [NSMutableArray array]
        : YTKACECallObjectGetter(OriginalAdSlotsArray, receiver, selector);
}

static id YTKACEAdPlacementsArray(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? [NSMutableArray array]
        : YTKACECallObjectGetter(OriginalAdPlacementsArray, receiver, selector);
}

static id YTKACENilParameter(IMP original, id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? nil
        : YTKACECallObjectGetter(original, receiver, selector);
}

static id YTKACEAdBreakParams(id receiver, SEL selector) {
    return YTKACENilParameter(OriginalAdBreakParams, receiver, selector);
}

static id YTKACEAdNextParams(id receiver, SEL selector) {
    return YTKACENilParameter(OriginalAdNextParams, receiver, selector);
}

static id YTKACEAdParams(id receiver, SEL selector) {
    return YTKACENilParameter(OriginalAdParams, receiver, selector);
}

static BOOL YTKACEEnableSkippableAd(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? YES
        : YTKACECallBooleanGetter(OriginalEnableSkippableAd, receiver, selector);
}

static void YTKACEMDXSessionImplAdPlaying(id receiver,
                                          SEL selector,
                                          uintptr_t value) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) &&
        OriginalMDXSessionImplAdPlaying != NULL) {
        ((void (*)(id, SEL, uintptr_t))OriginalMDXSessionImplAdPlaying)(
            receiver,
            selector,
            value
        );
    }
}

static BOOL YTKACENotPlayingAd(IMP original, id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? NO
        : YTKACECallBooleanGetter(original, receiver, selector);
}

static BOOL YTKACEIsPlayingAd(id receiver, SEL selector) {
    return YTKACENotPlayingAd(OriginalIsPlayingAd, receiver, selector);
}

static BOOL YTKACEIsPlayingAdSurvey(id receiver, SEL selector) {
    return YTKACENotPlayingAd(OriginalIsPlayingAdSurvey, receiver, selector);
}

static BOOL YTKACEIsPlayingAdIntro(id receiver, SEL selector) {
    return YTKACENotPlayingAd(OriginalIsPlayingAdIntro, receiver, selector);
}

static id YTKACENoAdsPlaybackCoordinator(id receiver, SEL selector) {
    id coordinator = YTKACECallObjectGetter(
        OriginalCreateAdsPlaybackCoordinator,
        receiver,
        selector
    );
    return YTKACEFeatureEnabled(YTKACENoAdsKey) ? nil : coordinator;
}

static id YTKACEObjectValue(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTKACEObjectHasAd(id object) {
    if (object == nil) return NO;
    NSNumber *cached = objc_getAssociatedObject(object, YTKACEAdObjectAssociation);
    if (cached != nil) return cached.boolValue;
    SEL dataSelector = @selector(data);
    if (![object respondsToSelector:dataSelector]) return NO;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, dataSelector);
    if (![value isKindOfClass:NSData.class]) return NO;
    BOOL ad = YTKACEAdBytes(value);
    objc_setAssociatedObject(object, YTKACEAdObjectAssociation, @(ad),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ad;
}

static BOOL YTKACEObjectBool(id object, NSString *selectorName) {
    if (object == nil) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL YTKACEReelObjectLooksLikeAd(id object, NSUInteger depth) {
    if (object == nil || depth > 3) return NO;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"nonvideoad"] ||
        [className containsString:@"reelad"] ||
        [className containsString:@"adselection"] ||
        [className containsString:@"miniappad"]) {
        return YES;
    }

    for (NSString *selectorName in @[
        @"isAd", @"isAdVideo", @"isVideoAd", @"hasAdLoggingData"
    ]) {
        if (YTKACEObjectBool(object, selectorName)) return YES;
    }

    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    if ([object respondsToSelector:videoTypeSelector]) {
        NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
            object,
            videoTypeSelector
        );
        if (videoType == 3) return YES;
    }

    for (NSString *selectorName in @[
        @"adLoggingData",
        @"adSlotRenderer",
        @"reelNonVideoAdRenderer",
        @"nonVideoAdRenderer",
        @"sequenceItemAdSelectionRenderer"
    ]) {
        if (YTKACEObjectValue(object, selectorName) != nil) return YES;
    }

    for (NSString *selectorName in @[
        @"reelModel", @"command", @"watchModel", @"parentWatchModel"
    ]) {
        id child = YTKACEObjectValue(object, selectorName);
        if (child != object && YTKACEReelObjectLooksLikeAd(child, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEReelShouldDisplay(id receiver, SEL selector) {
    BOOL shouldDisplay = OriginalReelShouldDisplay == NULL ||
        ((BOOL (*)(id, SEL))OriginalReelShouldDisplay)(receiver, selector);
    if (!shouldDisplay || !YTKACEFeatureEnabled(YTKACENoAdsKey)) {
        return shouldDisplay;
    }
    if (YTKACEObjectValue(receiver, @"nonVideoContentModel") != nil) {
        return NO;
    }
    return !YTKACEReelObjectLooksLikeAd(receiver, 0);
}

static BOOL YTKACEShortsAdBytes(NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger index = 0; index + 3 < length; index++) {
        if (bytes[index] != 0x82 || bytes[index + 1] != 0x01) continue;
        NSUInteger cursor = index + 2;
        NSUInteger size = 0;
        NSUInteger shift = 0;
        while (cursor < length && shift < 28) {
            uint8_t byte = bytes[cursor++];
            size |= (NSUInteger)(byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) break;
            shift += 7;
        }
        if (size < 2 || cursor + size > length) continue;
        for (NSUInteger end = cursor + size; cursor + 1 < end; cursor++) {
            if (bytes[cursor] == 0x08 && bytes[cursor + 1] == 0x01) {
                return YES;
            }
        }
    }
    return NO;
}

static id YTKACEReelContentModel(id receiver, SEL selector, id entry) {
    if (YTKACEFeatureEnabled(YTKACENoAdsKey)) {
        NSData *data = ((id (*)(id, SEL))objc_msgSend)(entry, @selector(data));
        if (YTKACEAdBytes(data) || YTKACEShortsAdBytes(data)) {
            return nil;
        }
    }
    return ((id (*)(id, SEL, id))OriginalReelContentModel)(
        receiver,
        selector,
        entry
    );
}

NSArray *YTKACEFilterAdSections(NSArray *sections) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) ||
        ![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < sections.count; index++) {
        id section = sections[index];
        SEL contentsSelector = @selector(contentsArray);
        NSArray *contents = [section respondsToSelector:contentsSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(section, contentsSelector)
            : nil;
        if (![contents isKindOfClass:NSArray.class]) contents = nil;
        if (contents.count == 0) {
            if (YTKACEObjectHasAd(section)) {
                [drop addIndex:index];
            }
            continue;
        }
        NSArray *processedContents = objc_getAssociatedObject(
            section, YTKACESectionContentsAssociation);
        NSNumber *processedCount = objc_getAssociatedObject(
            section, YTKACESectionContentCountAssociation);
        NSUInteger contentCount = contents.count;
        NSUInteger startIndex = 0;
        if (processedContents == contents && processedCount != nil) {
            NSUInteger previousCount = processedCount.unsignedIntegerValue;
            if (previousCount == contentCount) continue;
            if (previousCount < contentCount) startIndex = previousCount;
        }
        NSMutableIndexSet *contentDrop = nil;
        for (NSUInteger contentIndex = startIndex;
             contentIndex < contentCount; contentIndex++) {
            if (YTKACEObjectHasAd(contents[contentIndex])) {
                if (contentDrop == nil) {
                    contentDrop = [NSMutableIndexSet indexSet];
                }
                [contentDrop addIndex:contentIndex];
            }
        }
        if (contentDrop.count != 0) {
            if (![contents isKindOfClass:NSMutableArray.class]) {
                if (contentDrop.count == contentCount) {
                    [drop addIndex:index];
                }
                objc_setAssociatedObject(section,
                                         YTKACESectionContentsAssociation,
                                         contents,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(section,
                                         YTKACESectionContentCountAssociation,
                                         @(contentCount),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                continue;
            }
            [(NSMutableArray *)contents removeObjectsAtIndexes:contentDrop];
        }
        objc_setAssociatedObject(section,
                                 YTKACESectionContentsAssociation,
                                 contents,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(section,
                                 YTKACESectionContentCountAssociation,
                                 @(contents.count),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (contents.count == 0) {
            [drop addIndex:index];
        }
    }
    if (drop.count == 0) {
        return sections;
    }
    NSMutableArray *filtered = [sections mutableCopy];
    [filtered removeObjectsAtIndexes:drop];
    return filtered;
}

static id YTKACENoCompanionAd(id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? nil
        : YTKACECallObjectGetter(OriginalCompanionAd, receiver, selector);
}

static BOOL YTKACENoCompanionFlag(IMP original, id receiver, SEL selector) {
    return YTKACEFeatureEnabled(YTKACENoAdsKey)
        ? NO
        : YTKACECallBooleanGetter(original, receiver, selector);
}

static BOOL YTKACEHasCompanionAdRenderer(id receiver, SEL selector) {
    return YTKACENoCompanionFlag(
        OriginalHasCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL YTKACEHasAppPromoCompanionAdRenderer(id receiver, SEL selector) {
    return YTKACENoCompanionFlag(
        OriginalHasAppPromoCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL YTKACEHasShoppingCompanionAdRenderer(id receiver, SEL selector) {
    return YTKACENoCompanionFlag(
        OriginalHasShoppingCompanionAdRenderer,
        receiver,
        selector
    );
}

static void YTKACEInstallAdsDecorateServiceHook(NSString *className,
                                                IMP replacement,
                                                IMP *originalStorage) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return;

    Method method = class_getInstanceMethod(
        cls,
        NSSelectorFromString(@"decorateContext:serviceType:")
    );
    if (method == NULL) return;

    const char *types = method_getTypeEncoding(method);
    if (types == NULL || strcmp(types, "v32@0:8@16q24") != 0) {
        return;
    }

    YTKACEInstallInstanceHook(className,
                              @"decorateContext:serviceType:",
                              replacement,
                              originalStorage);
}

void YTKACEInstallAdsHooks(void) {
    YTKACEAdTrieBuild();
    YTKACEInstallInstanceHook(@"NSURLSessionTask",
                              @"resume",
                              (IMP)YTKACEURLSessionTaskResume,
                              &OriginalURLSessionTaskResume);
    YTKACEInstallInstanceHook(@"YTGlobalConfig",
                              @"shouldBlockUpgradeDialog",
                              (IMP)YTKACEShouldBlockUpgradeDialog,
                              &OriginalShouldBlockUpgradeDialog);
    YTKACEInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionary",
                           (IMP)YTKACEAdShieldSignals,
                           &OriginalAdShieldSignals);
    YTKACEInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionaryWithoutIDFA",
                           (IMP)YTKACEAdShieldSignalsWithoutIDFA,
                           &OriginalAdShieldSignalsWithoutIDFA);
    YTKACEInstallInstanceHook(@"YTAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTKACEAdsDecorateContext,
                              &OriginalAdsDecorateContext);
    YTKACEInstallInstanceHook(@"YTAccountScopedAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTKACEAccountAdsDecorateContext,
                              &OriginalAccountAdsDecorateContext);
    YTKACEInstallAdsDecorateServiceHook(
        @"YTAccountScopedAdsInnerTubeContextDecorator",
        (IMP)YTKACEAccountAdsDecorateService,
        &OriginalAccountAdsDecorateService
    );
    YTKACEInstallAdsDecorateServiceHook(
        @"YTAdsInnerTubeContextDecoratorImpl",
        (IMP)YTKACEAdsDecorateService,
        &OriginalAdsDecorateService
    );

    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"playerAdsArray",
                              (IMP)YTKACEPlayerAdsArray,
                              &OriginalPlayerAdsArray);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"adSlotsArray",
                              (IMP)YTKACEAdSlotsArray,
                              &OriginalAdSlotsArray);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"adPlacementsArray",
                              (IMP)YTKACEAdPlacementsArray,
                              &OriginalAdPlacementsArray);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"adBreakParams",
                              (IMP)YTKACEAdBreakParams,
                              &OriginalAdBreakParams);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"adNextParams",
                              (IMP)YTKACEAdNextParams,
                              &OriginalAdNextParams);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"adParams",
                              (IMP)YTKACEAdParams,
                              &OriginalAdParams);
    YTKACEInstallInstanceHook(@"YTIClientMdxGlobalConfig",
                              @"enableSkippableAd",
                              (IMP)YTKACEEnableSkippableAd,
                              &OriginalEnableSkippableAd);
    YTKACEInstallInstanceHook(@"MDXSessionImpl",
                              @"adPlaying:",
                              (IMP)YTKACEMDXSessionImplAdPlaying,
                              &OriginalMDXSessionImplAdPlaying);
    YTKACEInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAd",
                              (IMP)YTKACEIsPlayingAd,
                              &OriginalIsPlayingAd);
    YTKACEInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdSurvey",
                              (IMP)YTKACEIsPlayingAdSurvey,
                              &OriginalIsPlayingAdSurvey);
    YTKACEInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdIntro",
                              (IMP)YTKACEIsPlayingAdIntro,
                              &OriginalIsPlayingAdIntro);
    YTKACEInstallInstanceHook(@"YTLocalPlaybackController",
                              @"createAdsPlaybackCoordinator",
                              (IMP)YTKACENoAdsPlaybackCoordinator,
                              &OriginalCreateAdsPlaybackCoordinator);
    YTKACEInstallInstanceHook(@"YTReelDataSource",
                              @"makeContentModelForEntry:",
                              (IMP)YTKACEReelContentModel,
                              &OriginalReelContentModel);
    YTKACEInstallInstanceHook(@"YTReelContentModel",
                              @"shouldDisplay",
                              (IMP)YTKACEReelShouldDisplay,
                              &OriginalReelShouldDisplay);
    YTKACEInstallInstanceHook(@"YTIElementRenderer",
                              @"companionAd",
                              (IMP)YTKACENoCompanionAd,
                              &OriginalCompanionAd);
    YTKACEInstallInstanceHook(@"YTIElementRenderer",
                              @"hasCompanionAdRenderer",
                              (IMP)YTKACEHasCompanionAdRenderer,
                              &OriginalHasCompanionAdRenderer);
    YTKACEInstallInstanceHook(@"YTIElementRenderer",
                              @"hasAppPromoCompanionAdRenderer",
                              (IMP)YTKACEHasAppPromoCompanionAdRenderer,
                              &OriginalHasAppPromoCompanionAdRenderer);
    YTKACEInstallInstanceHook(@"YTIElementRenderer",
                              @"hasShoppingCompanionAdRenderer",
                              (IMP)YTKACEHasShoppingCompanionAdRenderer,
                              &OriginalHasShoppingCompanionAdRenderer);
}
