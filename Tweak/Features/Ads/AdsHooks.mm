#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalShouldBlockUpgradeDialog;
static IMP OriginalAdShieldSignals;
static IMP OriginalAdShieldSignalsWithoutIDFA;
static IMP OriginalDataSignals;
static IMP OriginalDataSignalsWithoutIDFA;
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
static IMP OriginalMDXSessionAdPlaying;
static IMP OriginalIsPlayingAd;
static IMP OriginalIsPlayingAdSurvey;
static IMP OriginalIsPlayingAdIntro;
static IMP OriginalCreateAdsPlaybackCoordinator;
static IMP OriginalReelContentModel;
static IMP OriginalInfiniteReelContentModel;
static IMP OriginalReelShouldDisplay;
static IMP OriginalCompanionAd;
static IMP OriginalHasCompanionAdRenderer;
static IMP OriginalHasAppPromoCompanionAdRenderer;
static IMP OriginalHasShoppingCompanionAdRenderer;
static IMP OriginalElementContentsArray;
static IMP OriginalItemSectionContentsArray;
static IMP OriginalAdCellLayout;
static IMP OriginalAdCellReuse;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEPromotedSizeOriginals;
static IMP OriginalVideoNodeSetEntry;
static IMP OriginalVideoNodeHeight;
static IMP OriginalVideoNodeSize;
static IMP OriginalVideoNodeShrink;
static const void *YTKACEAdNodeAssociation = &YTKACEAdNodeAssociation;
static const void *YTKACEAdMatchAssociation = &YTKACEAdMatchAssociation;
static const void *YTKACEAdEmptyAssociation = &YTKACEAdEmptyAssociation;

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

static id YTKACEDataSignals(id receiver, SEL selector) {
    return YTKACEEmptyDictionary(OriginalDataSignals, receiver, selector);
}

static id YTKACEDataSignalsWithoutIDFA(id receiver, SEL selector) {
    return YTKACEEmptyDictionary(OriginalDataSignalsWithoutIDFA, receiver, selector);
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

static void YTKACEAccountAdsDecorateService(id receiver, SEL selector, id context, long long type) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) && OriginalAccountAdsDecorateService != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalAccountAdsDecorateService)(receiver, selector, context, type);
    }
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

static void YTKACEMDXSessionAdPlaying(id receiver,
                                      SEL selector,
                                      uintptr_t value) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) && OriginalMDXSessionAdPlaying != NULL) {
        ((void (*)(id, SEL, uintptr_t))OriginalMDXSessionAdPlaying)(
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

static id YTKACEFilterReelModel(IMP original,
                                id receiver,
                                SEL selector,
                                id entry) {
    if (original == NULL) {
        return nil;
    }
    id model = ((id (*)(id, SEL, id))original)(receiver, selector, entry);
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) || model == nil) {
        return model;
    }
    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    if (![model respondsToSelector:videoTypeSelector]) {
        return model;
    }
    NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
        model,
        videoTypeSelector
    );
    return videoType == 3 ? nil : model;
}

static id YTKACEReelContentModel(id receiver, SEL selector, id entry) {
    return YTKACEFilterReelModel(
        OriginalReelContentModel,
        receiver,
        selector,
        entry
    );
}

static id YTKACEInfiniteReelContentModel(id receiver, SEL selector, id entry) {
    return YTKACEFilterReelModel(
        OriginalInfiniteReelContentModel,
        receiver,
        selector,
        entry
    );
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

static BOOL YTKACEIsAdLayoutIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *normalized = [[identifier lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"-"
                                                        withString:@"_"];
    return [normalized hasPrefix:@"eml_ad_"];
}

static BOOL YTKACEObjectLooksLikeAd(id object) {
    if (object == nil) return NO;
    if ([objc_getAssociatedObject(object, YTKACEAdMatchAssociation) boolValue]) {
        return YES;
    }
    BOOL matched = NO;
    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"adrenderer"] ||
        ([className containsString:@"promoted"] &&
         [className containsString:@"renderer"]) ||
        [className containsString:@"promorenderer"] ||
        [className containsString:@"adslotrenderer"] ||
        [className containsString:@"companionadrenderer"] ||
        [className containsString:@"shoppingadinfocardcontentrenderer"] ||
        [className containsString:@"infeedad"] ||
        [className containsString:@"displayad"]) {
        matched = YES;
    }
    for (NSString *selectorName in @[@"isAdRenderer", @"isAd",
                                      @"hasAdLoggingData",
                                      @"hasAdBadgeRenderer",
                                      @"hasNativeAdBadgeRenderer",
                                      @"hasSimpleAdBadgeRenderer",
                                      @"hasAdSlotRenderer",
                                      @"hasCompanionAdRenderer",
                                      @"hasCompactCompanionAdRenderer",
                                      @"hasMultiItemCompanionAdRenderer",
                                      @"hasAppPromoCompanionAdRenderer",
                                      @"hasShoppingCompanionAdRenderer",
                                      @"hasSuggestedVideosCompanionAdRenderer",
                                      @"hasCompactPromotedBannerRenderer",
                                      @"hasCompactPromotedItemRenderer",
                                      @"hasCompactPromotedVideoRenderer",
                                      @"hasGridPromotedBannerRenderer",
                                      @"hasGridPromotedVideoRenderer",
                                      @"hasPromoted15ClickPtTextCtdWatchRenderer",
                                      @"hasPromoted15ClickPtTextWatchRenderer",
                                      @"hasPromoted15ClickTextCtdWatchRenderer",
                                      @"hasPromoted15ClickTextWatchRenderer",
                                      @"hasPromotedAppInstallRenderer",
                                      @"hasPromotedDiscoveryAppPromoCompactFormRenderer",
                                      @"hasPromotedSparklesTextCtdHomeCompactFormRenderer",
                                      @"hasPromotedSparklesTextCtdHomeRenderer",
                                      @"hasPromotedSparklesTextCtdWatch15ClickRenderer",
                                      @"hasPromotedSparklesTextCtdWatchGridFormRenderer",
                                      @"hasPromotedSparklesTextCtdWatchWideFormRenderer",
                                      @"hasPromotedSparklesTextHomeRenderer",
                                      @"hasPromotedSparklesTextProductHomeRenderer",
                                      @"hasPromotedSparklesTextProductWatchRenderer",
                                      @"hasPromotedSparklesTextSearchRenderer",
                                      @"hasPromotedSparklesTextWatch15ClickRenderer",
                                      @"hasPromotedSparklesTextWatchGridFormRenderer",
                                      @"hasPromotedSparklesTextWatchWideFormRenderer",
                                      @"hasPromotedTextBannerRenderer",
                                      @"hasPromotedVideoInlineMutedRenderer",
                                      @"hasPromotedVideoRenderer",
                                      @"hasShoppingAdInfoCardContentRenderer"]) {
        if (matched) break;
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(object, selector)) {
            matched = YES;
        }
    }
    if (!matched && YTKACEObjectValue(object, @"adLoggingData") != nil) {
        matched = YES;
    }
    for (NSString *selectorName in @[
        @"adBadgeRenderer", @"nativeAdBadgeRenderer",
        @"simpleAdBadgeRenderer"
    ]) {
        if (matched) break;
        id value = YTKACEObjectValue(object, selectorName);
        if (value != nil) {
            matched = YES;
        }
    }
    for (NSString *selectorName in @[
        @"identifier", @"layoutIdentifier", @"elementIdentifier",
        @"accessibilityIdentifier", @"templateIdentifier"
    ]) {
        if (matched) break;
        id value = YTKACEObjectValue(object, selectorName);
        if ([value isKindOfClass:NSString.class] &&
            YTKACEIsAdLayoutIdentifier(value)) {
            matched = YES;
        }
    }
    if (!matched) {
        id options = YTKACEObjectValue(object, @"compatibilityOptions");
        SEL loggingSelector = NSSelectorFromString(@"hasAdLoggingData");
        matched = [options respondsToSelector:loggingSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(options, loggingSelector);
    }
    if (matched) {
        objc_setAssociatedObject(object, YTKACEAdMatchAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return matched;
}

static const void *YTKACEAdCellAssociation = &YTKACEAdCellAssociation;

typedef struct {
    NSUInteger unit;
    CGFloat value;
} YTKACEASDimension;

static void YTKACECollapseCellNode(id node) {
    SEL styleSelector = NSSelectorFromString(@"style");
    if ([node respondsToSelector:styleSelector]) {
        id style = ((id (*)(id, SEL))objc_msgSend)(node, styleSelector);
        YTKACEASDimension zero = {1, 0.0};
        for (NSString *name in @[@"setHeight:", @"setMaxHeight:"]) {
            SEL selector = NSSelectorFromString(name);
            if (![style respondsToSelector:selector]) continue;
            ((void (*)(id, SEL, YTKACEASDimension))objc_msgSend)(
                style, selector, zero);
        }
    }
    for (NSString *name in @[@"invalidateCalculatedLayout", @"setNeedsLayout"]) {
        SEL selector = NSSelectorFromString(name);
        if ([node respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(node, selector);
        }
    }
}

static void YTKACECollapseAdCell(UIView *cell) {
    CGRect frame = cell.frame;
    if (frame.size.height == 0.0 && cell.hidden) return;
    frame.size.height = 0.0;
    cell.frame = frame;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    for (UIView *ancestor = cell.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionView.class]) {
            [((UICollectionView *)ancestor).collectionViewLayout invalidateLayout];
            break;
        }
    }
}

void YTKACEHandleAdCellLayout(UIView *cell) {
    if (![objc_getAssociatedObject(cell, YTKACEAdCellAssociation) boolValue]) return;
    YTKACECollapseAdCell(cell);
}

void YTKACEHandleAdCellReuse(UIView *cell) {
    if (![objc_getAssociatedObject(cell, YTKACEAdCellAssociation) boolValue]) return;
    objc_setAssociatedObject(cell, YTKACEAdCellAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = NO;
    cell.userInteractionEnabled = YES;
}

void YTKACECollapseHostCell(UIView *view) {
    if (view == nil) return;
    UIView *cell = nil;
    for (UIView *ancestor = view; ancestor != nil;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionViewCell.class] ||
            [NSStringFromClass([ancestor class]) hasSuffix:@"CollectionViewCell"]) {
            cell = ancestor;
            break;
        }
    }
    view.hidden = YES;
    if (cell == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        return;
    }
    objc_setAssociatedObject(cell, YTKACEAdCellAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACECollapseAdCell(cell);
    SEL nodeSelector = NSSelectorFromString(@"node");
    if ([cell respondsToSelector:nodeSelector]) {
        id node = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        if (node != nil) {
            objc_setAssociatedObject(node, YTKACEAdNodeAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTKACECollapseCellNode(node);
        }
    }
}

void YTKACEHandleAdDisplayView(UIView *view) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) || view.window == nil) return;
    if (!YTKACEIsAdLayoutIdentifier(view.accessibilityIdentifier)) return;
    YTKACECollapseHostCell(view);
}

static id YTKACEElementRenderer(id object) {
    SEL selector = NSSelectorFromString(@"elementRenderer");
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector)
        : nil;
}

static NSArray *YTKACEFilterAdContents(NSArray *contents, id owner) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) ||
        ![contents isKindOfClass:NSArray.class] || contents.count == 0) {
        return contents;
    }
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:contents.count];
    for (id content in contents) {
        id renderer = YTKACEElementRenderer(content);
        BOOL contentAd = YTKACEObjectLooksLikeAd(content);
        BOOL rendererAd = YTKACEObjectLooksLikeAd(renderer);
        if (!contentAd && !rendererAd) {
            [filtered addObject:content];
        }
    }
    NSUInteger removed = contents.count - filtered.count;
    if (removed == 0) return contents;
    if (filtered.count == 0 && owner != nil) {
        objc_setAssociatedObject(owner, YTKACEAdEmptyAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return filtered;
}

static NSArray *YTKACEElementContentsArray(id receiver, SEL selector) {
    NSArray *contents = OriginalElementContentsArray == NULL ? nil :
        ((id (*)(id, SEL))OriginalElementContentsArray)(receiver, selector);
    return YTKACEFilterAdContents(contents, receiver);
}

static NSArray *YTKACEItemSectionContentsArray(id receiver, SEL selector) {
    NSArray *contents = OriginalItemSectionContentsArray == NULL ? nil :
        ((id (*)(id, SEL))OriginalItemSectionContentsArray)(receiver, selector);
    return YTKACEFilterAdContents(contents, receiver);
}

NSArray *YTKACEFilterAdSections(NSArray *sections) {
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey) ||
        ![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:sections.count];
    for (id section in sections) {
        if (YTKACEObjectLooksLikeAd(section) ||
            YTKACEObjectLooksLikeAd(YTKACEElementRenderer(section))) {
            continue;
        }
        NSArray *contents = YTKACEObjectValue(section, @"contentsArray");
        if ([objc_getAssociatedObject(section, YTKACEAdEmptyAssociation) boolValue] ||
            ([contents isKindOfClass:NSArray.class] && contents.count != 0 &&
             YTKACEFilterAdContents(contents, section).count == 0)) {
            continue;
        }
        [filtered addObject:section];
    }
    return filtered.count == sections.count ? sections : filtered;
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

static void YTKACEInstallObjectHookOrMethod(NSString *className,
                                            NSString *selectorName,
                                            IMP replacement,
                                            IMP *originalStorage) {
    if (!YTKACEInstallInstanceHook(
            className,
            selectorName,
            replacement,
            originalStorage
        )) {
        YTKACEAddInstanceMethod(className, selectorName, replacement, "@@:");
    }
}

static void YTKACEInstallBooleanHookOrMethod(NSString *className,
                                             NSString *selectorName,
                                             IMP replacement,
                                             IMP *originalStorage) {
    if (!YTKACEInstallInstanceHook(
            className,
            selectorName,
            replacement,
            originalStorage
        )) {
        YTKACEAddInstanceMethod(className, selectorName, replacement, "B@:");
    }
}

static void YTKACEAdCellLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalAdCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalAdCellLayout)(receiver, selector);
    }
    YTKACEHandleAdCellLayout(receiver);
}

static void YTKACEAdCellPrepareForReuse(UIView *receiver, SEL selector) {
    YTKACEHandleAdCellReuse(receiver);
    if (OriginalAdCellReuse != NULL) {
        ((void (*)(id, SEL))OriginalAdCellReuse)(receiver, selector);
    }
}

static IMP YTKACEPromotedSizeOriginal(id receiver, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
        NSStringFromClass([receiver class]), NSStringFromSelector(selector)];
    @synchronized (YTKACEPromotedSizeOriginals) {
        return (IMP)[YTKACEPromotedSizeOriginals[key] pointerValue];
    }
}

static CGSize YTKACEPromotedCellSize(id receiver, SEL selector, CGSize size) {
    IMP original = YTKACEPromotedSizeOriginal(receiver, selector);
    CGSize resolved = original == NULL
        ? size
        : ((CGSize (*)(id, SEL, CGSize))original)(receiver, selector, size);
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey)) return resolved;
    return CGSizeMake(resolved.width, 0.0);
}

static CGSize YTKACEPromotedCellSizeInsets(id receiver, SEL selector,
                                           CGSize size, UIEdgeInsets insets) {
    IMP original = YTKACEPromotedSizeOriginal(receiver, selector);
    CGSize resolved = original == NULL
        ? size
        : ((CGSize (*)(id, SEL, CGSize, UIEdgeInsets))original)(
            receiver, selector, size, insets);
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey)) return resolved;
    return CGSizeMake(resolved.width, 0.0);
}

static BOOL YTKACEShouldShowPromotedItems(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACENoAdsKey)) return NO;
    IMP original = YTKACEPromotedSizeOriginal(receiver, selector);
    return original != NULL && ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static void YTKACEInstallPromotedCellHooks(void) {
    YTKACEPromotedSizeOriginals = [NSMutableDictionary dictionary];
    NSArray<NSString *> *classes = @[@"YTCompactPromotedItemCellController",
                                     @"YTCompactPromotedVideoCellController",
                                     @"YTPromotedVideoCellController"];
    NSDictionary<NSString *, NSValue *> *replacements = @{
        @"cellSizeWithSize:": [NSValue valueWithPointer:(void *)YTKACEPromotedCellSize],
        @"cellSizeWithSize:safeAreaInsets:":
            [NSValue valueWithPointer:(void *)YTKACEPromotedCellSizeInsets],
        @"shouldShowPromotedItems":
            [NSValue valueWithPointer:(void *)YTKACEShouldShowPromotedItems]
    };
    for (NSString *className in classes) {
        for (NSString *selectorName in replacements) {
            IMP original = NULL;
            if (!YTKACEInstallInstanceHook(className, selectorName,
                    (IMP)replacements[selectorName].pointerValue, &original)) {
                continue;
            }
            NSString *key = [NSString stringWithFormat:@"%@|%@",
                className, selectorName];
            @synchronized (YTKACEPromotedSizeOriginals) {
                YTKACEPromotedSizeOriginals[key] =
                    [NSValue valueWithPointer:(void *)original];
            }
        }
    }
}

static BOOL YTKACEIsAdNode(id node) {
    return [objc_getAssociatedObject(node, YTKACEAdNodeAssociation) boolValue];
}

static void YTKACEVideoNodeSetEntry(id receiver, SEL selector, id entry) {
    if (OriginalVideoNodeSetEntry != NULL) {
        ((void (*)(id, SEL, id))OriginalVideoNodeSetEntry)(receiver, selector, entry);
    }
    if (!YTKACEFeatureEnabled(YTKACENoAdsKey)) return;
    BOOL isAd = YTKACEObjectLooksLikeAd(entry) ||
        YTKACEObjectLooksLikeAd(YTKACEElementRenderer(entry));
    objc_setAssociatedObject(receiver, YTKACEAdNodeAssociation,
                             isAd ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!isAd) return;
    YTKACECollapseCellNode(receiver);
    SEL overlay = NSSelectorFromString(@"dismissedCellOverlayView");
    SEL setOverlay = NSSelectorFromString(@"setDismissedCellOverlayView:");
    SEL resize = NSSelectorFromString(@"resizeDismissedView");
    if ([receiver respondsToSelector:overlay] &&
        [receiver respondsToSelector:setOverlay] &&
        ((id (*)(id, SEL))objc_msgSend)(receiver, overlay) == nil) {
        UIView *placeholder = [[UIView alloc] initWithFrame:CGRectZero];
        placeholder.hidden = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, setOverlay, placeholder);
    }
    if (![receiver respondsToSelector:resize]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!YTKACEIsAdNode(receiver)) return;
        ((void (*)(id, SEL))objc_msgSend)(receiver, resize);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
        });
    });
}

static BOOL YTKACEVideoNodeShouldShrink(id receiver, SEL selector) {
    if (YTKACEIsAdNode(receiver)) {
        return YES;
    }
    return OriginalVideoNodeShrink != NULL &&
        ((BOOL (*)(id, SEL))OriginalVideoNodeShrink)(receiver, selector);
}

static double YTKACEVideoNodeHeight(id receiver, SEL selector) {
    double height = OriginalVideoNodeHeight == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalVideoNodeHeight)(receiver, selector);
    if (!YTKACEIsAdNode(receiver)) return height;
    return 0.0;
}

static CGSize YTKACEVideoNodeSize(id receiver, SEL selector) {
    CGSize size = OriginalVideoNodeSize == NULL
        ? CGSizeZero
        : ((CGSize (*)(id, SEL))OriginalVideoNodeSize)(receiver, selector);
    if (!YTKACEIsAdNode(receiver)) return size;
    return CGSizeMake(size.width, 0.0);
}

void YTKACEInstallAdsHooks(void) {
    YTKACEInstallInstanceHook(@"YTVideoWithContextNode", @"setEntry:",
                              (IMP)YTKACEVideoNodeSetEntry,
                              &OriginalVideoNodeSetEntry);
    YTKACEInstallInstanceHook(@"YTVideoWithContextNode", @"yt_height",
                              (IMP)YTKACEVideoNodeHeight,
                              &OriginalVideoNodeHeight);
    YTKACEInstallInstanceHook(@"YTVideoWithContextNode", @"yt_size",
                              (IMP)YTKACEVideoNodeSize,
                              &OriginalVideoNodeSize);
    YTKACEInstallInstanceHook(@"YTVideoWithContextNode",
                              @"shouldShrinkDismissalView",
                              (IMP)YTKACEVideoNodeShouldShrink,
                              &OriginalVideoNodeShrink);
    YTKACEInstallPromotedCellHooks();
    YTKACEInstallInstanceHook(@"_ASCollectionViewCell",
                              @"layoutSubviews",
                              (IMP)YTKACEAdCellLayoutSubviews,
                              &OriginalAdCellLayout);
    YTKACEInstallInstanceHook(@"_ASCollectionViewCell",
                              @"prepareForReuse",
                              (IMP)YTKACEAdCellPrepareForReuse,
                              &OriginalAdCellReuse);
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
    YTKACEInstallClassHook(@"YTDataUtils",
                           @"spamSignalsDictionary",
                           (IMP)YTKACEDataSignals,
                           &OriginalDataSignals);
    YTKACEInstallClassHook(@"YTDataUtils",
                           @"spamSignalsDictionaryWithoutIDFA",
                           (IMP)YTKACEDataSignalsWithoutIDFA,
                           &OriginalDataSignalsWithoutIDFA);
    YTKACEInstallInstanceHook(@"YTAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTKACEAdsDecorateContext,
                              &OriginalAdsDecorateContext);
    YTKACEInstallInstanceHook(@"YTAccountScopedAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTKACEAccountAdsDecorateContext,
                              &OriginalAccountAdsDecorateContext);
    Method serviceMethod = class_getInstanceMethod(NSClassFromString(@"YTAccountScopedAdsInnerTubeContextDecorator"),
                                                   NSSelectorFromString(@"decorateContext:serviceType:"));
    const char *serviceTypes = serviceMethod != NULL ? method_getTypeEncoding(serviceMethod) : NULL;
    if (serviceTypes != NULL && strncmp(serviceTypes, "v32@0:8@16q24", 13) == 0) {
        YTKACEInstallInstanceHook(@"YTAccountScopedAdsInnerTubeContextDecorator",
                                  @"decorateContext:serviceType:",
                                  (IMP)YTKACEAccountAdsDecorateService,
                                  &OriginalAccountAdsDecorateService);
    }

    YTKACEInstallObjectHookOrMethod(@"YTIPlayerResponse",
                                    @"playerAdsArray",
                                    (IMP)YTKACEPlayerAdsArray,
                                    &OriginalPlayerAdsArray);
    YTKACEInstallObjectHookOrMethod(@"YTIPlayerResponse",
                                    @"adSlotsArray",
                                    (IMP)YTKACEAdSlotsArray,
                                    &OriginalAdSlotsArray);
    YTKACEInstallObjectHookOrMethod(@"YTIPlayerResponse",
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
    YTKACEInstallBooleanHookOrMethod(@"YTIClientMdxGlobalConfig",
                                     @"enableSkippableAd",
                                     (IMP)YTKACEEnableSkippableAd,
                                     &OriginalEnableSkippableAd);

    YTKACEInstallInstanceHook(@"MDXSessionImpl",
                              @"adPlaying:",
                              (IMP)YTKACEMDXSessionImplAdPlaying,
                              &OriginalMDXSessionImplAdPlaying);
    YTKACEInstallInstanceHook(@"MDXSession",
                              @"adPlaying:",
                              (IMP)YTKACEMDXSessionAdPlaying,
                              &OriginalMDXSessionAdPlaying);
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
    YTKACEInstallInstanceHook(@"YTReelInfinitePlaybackDataSource",
                              @"makeContentModelForEntry:",
                              (IMP)YTKACEInfiniteReelContentModel,
                              &OriginalInfiniteReelContentModel);
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
    YTKACEInstallInstanceHook(@"YTIElementRenderer",
                              @"contentsArray",
                              (IMP)YTKACEElementContentsArray,
                              &OriginalElementContentsArray);
    YTKACEInstallInstanceHook(@"YTIItemSectionRenderer",
                              @"contentsArray",
                              (IMP)YTKACEItemSectionContentsArray,
                              &OriginalItemSectionContentsArray);
}
