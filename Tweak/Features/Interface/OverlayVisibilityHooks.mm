#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"

#import <objc/message.h>
#import "../Downloads/DownloadLog.h"
#import <objc/runtime.h>
#import <math.h>

static const void *YTKACEOverlayHiddenAssociation = &YTKACEOverlayHiddenAssociation;
static const void *YTKACEOverlayForcedAssociation = &YTKACEOverlayForcedAssociation;
static const void *YTKACEOverlayEnabledAssociation = &YTKACEOverlayEnabledAssociation;
static const void *YTKACEOverlayTransformAssociation = &YTKACEOverlayTransformAssociation;
static const void *YTKACEDoubleTapAssociation = &YTKACEDoubleTapAssociation;
static const void *YTKACEPrevNextParentAssociation = &YTKACEPrevNextParentAssociation;
static const void *YTKACEProductHiddenAssociation = &YTKACEProductHiddenAssociation;
static IMP OriginalVideoOverlayLayout;
static IMP OriginalForceHidePreviousNext;
static IMP OriginalPreviousButtonShouldHide;
static IMP OriginalNextButtonShouldHide;
static IMP OriginalRemoveNextPaddle;
static IMP OriginalRemovePreviousPaddle;
static IMP OriginalDidUpdatePlayerOverlayContent;
static IMP OriginalHasProductsInVideoOverlay;
static IMP OriginalProductsInVideoOverlay;
static IMP OriginalProductPillOverlayDidAddSubview;
static IMP OriginalProductPillControlsDidAddSubview;
static IMP OriginalTimelyShelfDidInsert;
static IMP OriginalTimelyShelfDidUpdate;
static IMP OriginalUpdateTimelyShelfOverlay;
static IMP OriginalUpdateTimelyShelfState;
static IMP OriginalUpdateTimelyShelfStateWith;
static IMP OriginalTimelyShelfFrame;
static IMP OriginalTimelyShelfHeightVC;
static IMP OriginalTimelyShelfHeightBar;
static IMP OriginalTimelyShelfHeightInput;

static NSUInteger YTKACEProductHiddenCount = 0;

static void YTKACESweepProductViews(UIView *root, BOOL hide);
static void YTKACEApplyProductVisibility(UIView *root);

static BOOL YTKACEOverlayPreference(NSString *key) {
    return YTKACEFeatureEnabled(key);
}

static NSString *YTKACEOverlayToken(UIView *view) {
    return [[NSString stringWithFormat:@"%@ %@ %@",
             NSStringFromClass(view.class),
             view.accessibilityIdentifier ?: @"",
             view.accessibilityLabel ?: @""] lowercaseString];
}

static BOOL YTKACEOverlayTokenMatches(NSString *token,
                                      NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *YTKACEPreviousNextTokens(void) {
    return @[
        @"id.player.previous.button", @"id.player.next.button",
        @"previous.button", @"next.button",
        @"previousbutton", @"nextbutton", @"previous_button", @"next_button",
        @"previous button", @"next button", @"skipprevious", @"skipnext",
        @"replaynextbutton", @"replay_next_button"
    ];
}

static void YTKACESetPreviousNextContainerEnabled(UIView *view, BOOL enabled) {
    if (view == nil) return;
    NSDictionary *baseline = objc_getAssociatedObject(view,
                                                       YTKACEPrevNextParentAssociation);
    if (!enabled) {
        if (baseline == nil) {
            baseline = @{@"interaction": @(view.userInteractionEnabled),
                         @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view, YTKACEPrevNextParentAssociation,
                                     baseline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.userInteractionEnabled = NO;
        view.alpha = 0.35;
    } else if (baseline != nil) {
        view.userInteractionEnabled = [baseline[@"interaction"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view, YTKACEPrevNextParentAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACESetControlTreeEnabled(UIView *view, BOOL enabled) {
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        control.enabled = enabled;
        control.userInteractionEnabled = enabled;
        control.alpha = enabled ? 1.0 : 0.35;
    }
    for (UIView *subview in view.subviews) {
        YTKACESetControlTreeEnabled(subview, enabled);
    }
}

static void YTKACESetOverlayHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"YTKACE"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        YTKACEOverlayHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     YTKACEOverlayHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 YTKACEOverlayHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTKACEIsDarkOverlayView(UIView *view) {
    UIView *root = view.superview;
    if (view.class != UIView.class ||
        ![NSStringFromClass(root.class)
            isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
        fabs(CGRectGetWidth(view.bounds) - CGRectGetWidth(root.bounds)) >= 2.0 ||
        fabs(CGRectGetHeight(view.bounds) - CGRectGetHeight(root.bounds)) >= 2.0) {
        return NO;
    }
    NSUInteger index = [root.subviews indexOfObjectIdenticalTo:view];
    if (index == NSNotFound || index + 1 >= root.subviews.count) return NO;
    return [NSStringFromClass(root.subviews[index + 1].class)
        isEqualToString:@"YTMainAppVideoOverlayAccessibilityGlassContainerView"];
}

static BOOL YTKACEMatchesAncestorButton(UIView *view, NSString *accessor) {
    SEL selector = NSSelectorFromString(accessor);
    for (UIView *ancestor = view.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if (![ancestor respondsToSelector:selector]) continue;
        UIView *button = ((id (*)(id, SEL))objc_msgSend)(ancestor, selector);
        if (![button isKindOfClass:UIView.class]) return NO;
        return button == view || [view isDescendantOfView:button];
    }
    return NO;
}

static BOOL YTKACEOverlayShouldHide(UIView *view) {
    NSString *token = YTKACEOverlayToken(view);
    if (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.DimmingRemoved") &&
        YTKACEIsDarkOverlayView(view)) {
        return YES;
    }
    if (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.QuickActionsHidden") &&
        YTKACEOverlayTokenMatches(token, @[
            @"quickaction", @"quick_action", @"actionbar", @"action_bar"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") &&
        YTKACEOverlayTokenMatches(token, @[
            @"continuewatching", @"continue_watching"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.RelatedVideosHidden") &&
        YTKACEOverlayTokenMatches(token, @[
            @"relatedvideo", @"related_video", @"morevideos", @"more_videos"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.AutoplayHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"autoplay", @"autonav"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CaptionsButtonHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"caption", @"subtitle", @"closedcaption"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CastHidden") &&
        (YTKACEOverlayTokenMatches(token, @[@"cast", @"airplay", @"routebutton"]) ||
         YTKACEMatchesAncestorButton(view, @"playbackRouteButton"))) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.WatermarkHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"watermark", @"branding"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.InfoCardsHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"infocard", @"info_card", @"cardsbutton"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.EndScreenHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"endscreen", @"end_screen"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PlayPauseHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"playpause", @"play_pause"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.MoreButtonHidden") &&
        YTKACEOverlayTokenMatches(token, @[@"overflowbutton", @"settingsbutton", @"morebutton"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden") &&
        YTKACEOverlayTokenMatches(token, YTKACEPreviousNextTokens())) {
        return YES;
    }
    return NO;
}

static id YTKACEProductOverlayModelValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTKACEProductOverlayBoolValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return NO;
    @try {
        return [[object valueForKey:key] boolValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL YTKACEIsProductOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_product_in_video"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"product"]) {
        return YES;
    }
    return NO;
}

static BOOL YTKACEIsTimelyShelfOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_timely_shelf"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"timely_shelf"]) {
        return YES;
    }
    return NO;
}

static BOOL YTKACEProductPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    for (NSString *key in @[@"productsInVideoOverlayRenderer",
                            @"productsInVideoEntity",
                            @"productsInVideoEntityModel",
                            @"productCard",
                            @"shoppingAdInfoCardContentRenderer",
                            @"infoCardProduct"]) {
        if (YTKACEProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (YTKACEProductOverlayBoolValue(object, @"hasProductCard")) {
        return YES;
    }
    if (YTKACEProductOverlayBoolValue(
            object, @"hasShoppingAdInfoCardContentRenderer")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"productsinvideo"] ||
         [classToken containsString:@"productinvideo"] ||
         [classToken containsString:@"infocardproduct"] ||
         [classToken containsString:@"shoppingadinfocard"])) {
        return YES;
    }
    return NO;
}

static BOOL YTKACETimelyShelfShoppingPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    if (YTKACEProductPayloadMatches(object)) return YES;
    for (NSString *key in @[@"taggedProducts",
                            @"creatorProduct",
                            @"shoppingData"]) {
        if (YTKACEProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (YTKACEProductOverlayBoolValue(object, @"hasTaggedProducts")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"shopping"] ||
         [classToken containsString:@"taggedproduct"] ||
         [classToken containsString:@"creatorproduct"] ||
         [classToken containsString:@"merchandise"])) {
        return YES;
    }
    for (NSString *key in @[@"overlayIdentifier", @"elementIdentifier"]) {
        id raw = YTKACEProductOverlayModelValue(object, key);
        if ([raw isKindOfClass:NSString.class] &&
            [[raw lowercaseString] containsString:@"shopping"]) {
            return YES;
        }
    }
    return NO;
}

BOOL YTKACEProductOverlayMatches(id overlay) {
    if (overlay == nil) return NO;
    NSString *identifier =
        YTKACEProductOverlayModelValue(overlay, @"overlayIdentifier");
    if ([identifier isKindOfClass:NSString.class] &&
        YTKACEIsProductOverlayIdentifier(identifier)) {
        return YES;
    }
    if (YTKACEProductPayloadMatches(overlay)) return YES;
    id renderer = YTKACEProductOverlayModelValue(overlay, @"renderer");
    if (renderer == overlay) renderer = nil;
    NSString *rendererIdentifier = nil;
    if (renderer != nil) {
        rendererIdentifier =
            YTKACEProductOverlayModelValue(renderer, @"overlayIdentifier");
        if ([rendererIdentifier isKindOfClass:NSString.class] &&
            YTKACEIsProductOverlayIdentifier(rendererIdentifier)) {
            return YES;
        }
        if (YTKACEProductPayloadMatches(renderer)) return YES;
    }
    BOOL timely =
        ([identifier isKindOfClass:NSString.class] &&
         YTKACEIsTimelyShelfOverlayIdentifier(identifier)) ||
        ([rendererIdentifier isKindOfClass:NSString.class] &&
         YTKACEIsTimelyShelfOverlayIdentifier(rendererIdentifier));
    if (timely &&
        (YTKACETimelyShelfShoppingPayloadMatches(overlay) ||
         (renderer != nil && YTKACETimelyShelfShoppingPayloadMatches(renderer)))) {
        return YES;
    }
    return NO;
}

static BOOL YTKACEShouldDropProductOverlay(id overlay) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACEProductOverlayMatches(overlay);
}

static void YTKACEForwardProductOverlay(id receiver, SEL selector,
                                         id provider, id overlay,
                                         IMP original) {
    if (YTKACEShouldDropProductOverlay(overlay)) return;
    if (original != NULL) {
        ((void (*)(id, SEL, id, id))original)(
            receiver, selector, provider, overlay);
    }
}

static void YTKACEProductPillDidAddSubviewHook(UIView *receiver, SEL selector,
                                                UIView *subview) {
    static Class controlsClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controlsClass = NSClassFromString(@"YTMainAppControlsOverlayView");
    });
    IMP original = (controlsClass != Nil &&
                    [receiver isKindOfClass:controlsClass])
        ? OriginalProductPillControlsDidAddSubview
        : OriginalProductPillOverlayDidAddSubview;
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, subview);
    }
    YTKACEApplyProductVisibility(subview);
}

static NSArray<NSString *> *YTKACEProductPillTokens(void) {
    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[
            @"product_in_video", @"products_in_video",
            @"tagged_product", @"creator_product",
            @"shopping", @"merchandise",
            @"products", @"tagged"
        ];
    });
    return tokens;
}

static BOOL YTKACEProductTokenHasBareProduct(NSString *token) {
    if ([token containsString:@"product"] == NO) return NO;
    for (NSString *exclusion in @[@"production", @"producer",
                                  @"productivity"]) {
        if ([token containsString:exclusion]) return NO;
    }
    return YES;
}

static BOOL YTKACEViewLooksLikeProductPill(UIView *view) {
    if (view == nil) return NO;
    NSString *token = YTKACEOverlayToken(view);
    return YTKACEOverlayTokenMatches(token, YTKACEProductPillTokens()) ||
        YTKACEProductTokenHasBareProduct(token);
}

static void YTKACEProductHiddenCounted(UIView *view, BOOL willHide) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, YTKACEProductHiddenAssociation);
    if (willHide) {
        if (baseline == nil && !view.hidden) YTKACEProductHiddenCount++;
    } else if (baseline != nil) {
        if (YTKACEProductHiddenCount > 0) YTKACEProductHiddenCount--;
    }
}

static BOOL YTKACEProductTokenInString(NSString *string) {
    if (string.length == 0) return NO;
    NSString *token = [string lowercaseString];
    return YTKACEOverlayTokenMatches(token, YTKACEProductPillTokens()) ||
        YTKACEProductTokenHasBareProduct(token);
}

static void YTKACEProductSetHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"YTKACE"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        YTKACEProductHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     YTKACEProductHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 YTKACEProductHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *YTKACEFindForeignTextExcept(UIView *view, UIView *skip,
                                               NSUInteger depth) {
    if (view == nil || view == skip || depth > 4) return nil;
    if (view.hidden) return nil;
    if (depth == 0) {
        if (!YTKACEProductTokenInString(view.accessibilityLabel) &&
            view.accessibilityLabel.length > 1) {
            return view;
        }
    } else {
        if (YTKACEProductTokenInString(view.accessibilityLabel)) {
            return nil;
        }
        if (view.accessibilityLabel.length > 1) return view;
    }
    if (depth > 0) {
        if ([view isKindOfClass:UILabel.class]) {
            if (!YTKACEProductTokenInString(((UILabel *)view).text) &&
                ((UILabel *)view).text.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            if (!YTKACEProductTokenInString(button.currentTitle) &&
                button.currentTitle.length > 1) {
                return view;
            }
            if (!YTKACEProductTokenInString(button.accessibilityIdentifier) &&
                button.accessibilityIdentifier.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIControl.class]) {
            if (!YTKACEProductTokenInString(view.accessibilityIdentifier) &&
                view.accessibilityIdentifier.length > 1) {
                return view;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        UIView *found = YTKACEFindForeignTextExcept(subview, skip, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void YTKACEHideProductPill(UIView *pill, BOOL hide) {
    YTKACEProductHiddenCounted(pill, hide);
    YTKACEProductSetHidden(pill, hide);
    if (!hide) return;
    UIView *child = pill;
    for (NSUInteger level = 0; level < 4; level++) {
        UIView *parent = child.superview;
        if (parent == nil || parent == child) break;
        NSString *parentClass = NSStringFromClass(parent.class);
        if ([parentClass containsString:@"VideoPlayerOverlay"] ||
            [parentClass containsString:@"ControlsOverlay"]) {
            break;
        }
        CGFloat h = CGRectGetHeight(parent.bounds);
        if (h <= 0.5 || h > 320.0) {
            if (!YTKACEViewLooksLikeProductPill(parent)) break;
        }
        if (YTKACEFindForeignTextExcept(parent, child, 0) != nil) break;
        YTKACEProductHiddenCounted(parent, YES);
        YTKACEProductSetHidden(parent, YES);
        child = parent;
    }
    if (child.superview != nil) {
        [child.superview setNeedsLayout];
    }
}

static void YTKACESetOverlayForcedVisible(UIView *view, BOOL forced) {
    NSDictionary *baseline = objc_getAssociatedObject(
        view,
        YTKACEOverlayForcedAssociation
    );
    if (forced) {
        if (baseline == nil) {
            baseline = @{@"hidden": @(view.hidden), @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view,
                                     YTKACEOverlayForcedAssociation,
                                     baseline,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = NO;
        view.alpha = 1.0;
    } else if (baseline != nil) {
        view.hidden = [baseline[@"hidden"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view,
                                 YTKACEOverlayForcedAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACEApplyOverlayBehavior(UIView *view) {
    NSString *token = YTKACEOverlayToken(view);
    BOOL playPause = YTKACEOverlayTokenMatches(token, @[
        @"playpause", @"play_pause", @"playbackbutton"
    ]);
    BOOL progress = YTKACEOverlayTokenMatches(token, @[
        @"progress", @"scrubber", @"playerbar", @"player_bar"
    ]);
    BOOL control = [view isKindOfClass:UIControl.class] ||
        YTKACEOverlayTokenMatches(token, @[@"control", @"button"]);
    BOOL force = (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowPlayPause") && playPause) ||
        (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowControls") && control) ||
        (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProgressAlwaysVisible") && progress);
    YTKACESetOverlayForcedVisible(view, force);

    BOOL previousNext = YTKACEOverlayTokenMatches(
        token, YTKACEPreviousNextTokens());
    BOOL disablePreviousNext = YTKACEOverlayPreference(
        @"YTKACE.Preference.Overlay.PreviousNextDisabled");
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *controlView = (UIControl *)view;
        NSNumber *baseline = objc_getAssociatedObject(
            view,
            YTKACEOverlayEnabledAssociation
        );
        if (disablePreviousNext && previousNext) {
            if (baseline == nil) {
                objc_setAssociatedObject(view,
                                         YTKACEOverlayEnabledAssociation,
                                         @(controlView.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controlView.enabled = NO;
            controlView.alpha = 0.35;
        } else if (baseline != nil) {
            controlView.enabled = baseline.boolValue;
            controlView.alpha = 1.0;
            objc_setAssociatedObject(view,
                                     YTKACEOverlayEnabledAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (previousNext) {
        UIView *container = view.superview;
        if ([NSStringFromClass(container.class)
                containsString:@"TransportControlsButtonView"]) {
            YTKACESetPreviousNextContainerEnabled(container,
                                                   !disablePreviousNext);
        }
    }

    NSValue *transform = objc_getAssociatedObject(
        view,
        YTKACEOverlayTransformAssociation
    );
    if (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.CompactPreviousNext") && previousNext) {
        if (transform == nil) {
            objc_setAssociatedObject(view,
                                     YTKACEOverlayTransformAssociation,
                                     [NSValue valueWithCGAffineTransform:view.transform],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.transform = CGAffineTransformScale(
            transform != nil ? transform.CGAffineTransformValue : view.transform,
            0.78,
            0.78
        );
    } else if (transform != nil) {
        view.transform = transform.CGAffineTransformValue;
        objc_setAssociatedObject(view,
                                 YTKACEOverlayTransformAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] ||
            ((UITapGestureRecognizer *)recognizer).numberOfTapsRequired < 2) {
            continue;
        }
        NSNumber *baseline = objc_getAssociatedObject(
            recognizer,
            YTKACEDoubleTapAssociation
        );
        if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.DoubleTapDisabled")) {
            if (baseline == nil) {
                objc_setAssociatedObject(recognizer,
                                         YTKACEDoubleTapAssociation,
                                         @(recognizer.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            recognizer.enabled = NO;
        } else if (baseline != nil) {
            recognizer.enabled = baseline.boolValue;
            objc_setAssociatedObject(recognizer,
                                     YTKACEDoubleTapAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void YTKACEApplyOverlayTree(UIView *view) {
    YTKACEApplyOverlayBehavior(view);
    YTKACESetOverlayHidden(view, YTKACEOverlayShouldHide(view));
    for (UIView *subview in view.subviews) {
        YTKACEApplyOverlayTree(subview);
    }
}

static void YTKACEApplyOverlaySelectors(id overlay) {
    NSDictionary<NSString *, NSString *> *selectors = @{
        @"autoplaySwitch": @"YTKACE.Preference.Overlay.AutoplayHidden",
        @"autoplayButton": @"YTKACE.Preference.Overlay.AutoplayHidden",
        @"captionsButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"closedCaptionsButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"castButton": @"YTKACE.Preference.Overlay.CastHidden",
        @"playbackRouteButton": @"YTKACE.Preference.Overlay.CastHidden",
        @"closedCaptionsOrSubtitlesButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"infoCardButton": @"YTKACE.Preference.Overlay.InfoCardsHidden",
        @"watermarkView": @"YTKACE.Preference.Overlay.WatermarkHidden",
        @"endscreenView": @"YTKACE.Preference.Overlay.EndScreenHidden",
        @"playPauseButton": @"YTKACE.Preference.Overlay.PlayPauseHidden",
        @"previousButton": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"nextButton": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"previousButtonView": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"nextButtonView": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"minimizedPanelPreviousButton": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"minimizedPanelNextButton": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"replayNextButton": @"YTKACE.Preference.Overlay.PreviousNextHidden",
        @"overflowButton": @"YTKACE.Preference.Overlay.MoreButtonHidden",
        @"settingsButton": @"YTKACE.Preference.Overlay.MoreButtonHidden"
    };
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if (![overlay respondsToSelector:selector]) {
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(overlay, selector);
        if ([value isKindOfClass:UIView.class]) {
            YTKACESetOverlayHidden(value,
                                   YTKACEFeatureEnabled(selectors[name]));
            if ([name.lowercaseString containsString:@"previous"] ||
                [name.lowercaseString containsString:@"next"]) {
                BOOL disabled = YTKACEOverlayPreference(
                    @"YTKACE.Preference.Overlay.PreviousNextDisabled");
                YTKACESetControlTreeEnabled(value, !disabled);
            }
        }
    }
}

static void YTKACESweepProductViews(UIView *root, BOOL hide) {
    if (root == nil) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden &&
            objc_getAssociatedObject(view,
                                     YTKACEProductHiddenAssociation) != nil) {
            if (!hide) {
                YTKACEProductHiddenCounted(view, NO);
                YTKACEProductSetHidden(view, NO);
            } else {
                continue;
            }
        }
        if (hide && YTKACEViewLooksLikeProductPill(view)) {
            YTKACEHideProductPill(view, YES);
            continue;
        }
        if (!hide &&
            objc_getAssociatedObject(view,
                                     YTKACEProductHiddenAssociation) != nil) {
            YTKACEProductHiddenCounted(view, NO);
            YTKACEProductSetHidden(view, NO);
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void YTKACEApplyProductVisibility(UIView *root) {
    if (root == nil) return;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        YTKACESweepProductViews(root, YES);
    } else if (YTKACEProductHiddenCount > 0) {
        YTKACESweepProductViews(root, NO);
        if (YTKACEProductHiddenCount > 0) {
            YTKACEProductHiddenCount = 0;
        }
    }
}

BOOL YTKACEProductIdentifierMatches(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return YTKACEProductTokenInString(identifier);
}

BOOL YTKACEViewIsInsidePlayerOverlay(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *node = view; node != nil && depth < 12;
         node = node.superview, depth++) {
        NSString *className = NSStringFromClass(node.class);
        if ([className isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
            [className isEqualToString:@"YTMainAppControlsOverlayView"]) {
            return YES;
        }
    }
    return NO;
}

void YTKACEHideProductSubtree(UIView *root) {
    if (root == nil || !YTKACEViewIsInsidePlayerOverlay(root)) return;
    YTKACESweepProductViews(root, YES);
}

static void YTKACEVideoOverlayLayout(UIView *receiver, SEL selector) {
    if (OriginalVideoOverlayLayout != NULL) {
        ((void (*)(id, SEL))OriginalVideoOverlayLayout)(receiver, selector);
    }
    YTKACEApplyOverlaySelectors(receiver);
    YTKACEApplyProductVisibility(receiver);
    if (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.DimmingRemoved")) {
        for (UIView *subview in receiver.subviews) {
            if (YTKACEIsDarkOverlayView(subview)) {
                YTKACESetOverlayHidden(subview, YES);
            }
        }
    }
}

static void YTKACEDidUpdatePlayerOverlayContent(id receiver, SEL selector,
                                                 id provider, id overlay) {
    YTKACEForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalDidUpdatePlayerOverlayContent);
}

static BOOL YTKACEHasProductsInVideoOverlay(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) return NO;
    return OriginalHasProductsInVideoOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasProductsInVideoOverlay)(receiver, selector);
}

static id YTKACEProductsInVideoOverlay(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) return nil;
    return OriginalProductsInVideoOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalProductsInVideoOverlay)(receiver, selector);
}

static void YTKACETimelyShelfDidInsert(id receiver, SEL selector,
                                         id provider, id overlay) {
    YTKACEForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidInsert);
}

static void YTKACETimelyShelfDidUpdate(id receiver, SEL selector,
                                        id provider, id overlay) {
    YTKACEForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidUpdate);
}

static void YTKACEUpdateTimelyShelfOverlay(id receiver, SEL selector,
                                            id overlay) {
    if (YTKACEShouldDropProductOverlay(overlay)) {
        return;
    }
    if (OriginalUpdateTimelyShelfOverlay != NULL) {
        ((void (*)(id, SEL, id))OriginalUpdateTimelyShelfOverlay)(
            receiver, selector, overlay);
    }
}

static void YTKACEUpdateTimelyShelfState(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        return;
    }
    if (OriginalUpdateTimelyShelfState != NULL) {
        ((void (*)(id, SEL))OriginalUpdateTimelyShelfState)(
            receiver, selector);
    }
}

static void YTKACEUpdateTimelyShelfStateWith(id receiver, SEL selector,
                                              NSInteger state) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        return;
    }
    if (OriginalUpdateTimelyShelfStateWith != NULL) {
        ((void (*)(id, SEL, NSInteger))OriginalUpdateTimelyShelfStateWith)(
            receiver, selector, state);
    }
}

static void YTKACETimelyShelfFrame(id receiver, SEL selector,
                                    id shelf, CGRect overlayBounds) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        if ([shelf isKindOfClass:UIView.class]) {
            UIView *shelfView = (UIView *)shelf;
            YTKACEProductHiddenCounted(shelfView, YES);
            YTKACEProductSetHidden(shelfView, YES);
            shelfView.frame = CGRectZero;
            [shelfView.superview setNeedsLayout];
        }
        return;
    }
    if (OriginalTimelyShelfFrame != NULL) {
        ((void (*)(id, SEL, id, CGRect))OriginalTimelyShelfFrame)(
            receiver, selector, shelf, overlayBounds);
    }
}

static CGFloat YTKACETimelyShelfHeightHook(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        return 0.0;
    }
    static Class barClass;
    static Class inputClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        barClass = NSClassFromString(@"YTPlayerBarController");
        inputClass = NSClassFromString(@"YTPlayerBarLayoutInput");
    });
    IMP original = OriginalTimelyShelfHeightVC;
    if (barClass != Nil && [receiver isKindOfClass:barClass]) {
        original = OriginalTimelyShelfHeightBar;
    } else if (inputClass != Nil && [receiver isKindOfClass:inputClass]) {
        original = OriginalTimelyShelfHeightInput;
    }
    return original == NULL ? 0.0 :
        ((CGFloat (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTKACEForceHidePreviousNext(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalForceHidePreviousNext == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalForceHidePreviousNext)(
            receiver, selector);
}

static BOOL YTKACEPreviousButtonShouldHide(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalPreviousButtonShouldHide == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalPreviousButtonShouldHide)(
            receiver, selector);
}

static BOOL YTKACENextButtonShouldHide(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalNextButtonShouldHide == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalNextButtonShouldHide)(
            receiver, selector);
}

static BOOL YTKACERemoveNextPaddle(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalRemoveNextPaddle != NULL &&
        ((BOOL (*)(id, SEL))OriginalRemoveNextPaddle)(receiver, selector);
}

static BOOL YTKACERemovePreviousPaddle(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalRemovePreviousPaddle != NULL &&
        ((BOOL (*)(id, SEL))OriginalRemovePreviousPaddle)(receiver, selector);
}

static NSString *const YTKACEFullscreenActionsKey =
    @"YTKACE.Preference.Overlay.FullscreenActionsHidden";

static CGFloat const YTKACEFullscreenActionsReservedHeight = 34.0;

static IMP OriginalFullscreenActionsLayout;
static IMP OriginalFullscreenEngagementLayout;
static IMP OriginalFullscreenActionBarHeight;
static IMP OriginalFullscreenActionsSizeThatFits;
static void YTKACEApplyHidden(UIView *view, NSString *key) {
    const BOOL hidden = YTKACEFeatureEnabled(key);
    if (view.hidden != hidden) view.hidden = hidden;
}

static void YTKACEFullscreenActionsLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenActionsLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenActionsLayout)(receiver, selector);
    }
    YTKACEApplyHidden(receiver, YTKACEFullscreenActionsKey);
}

static void YTKACEFullscreenEngagementLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenEngagementLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenEngagementLayout)(receiver, selector);
    }
    YTKACEApplyHidden(receiver, YTKACEFullscreenActionsKey);
}

static CGFloat YTKACEFullscreenActionBarHeight(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEFullscreenActionsKey)) return 0.0;
    return ((CGFloat (*)(id, SEL))OriginalFullscreenActionBarHeight)(
        receiver, selector);
}

static CGSize YTKACEFullscreenActionsSizeThatFits(id receiver, SEL selector,
                                                   CGRect size) {
    CGSize fitted = ((CGSize (*)(id, SEL, CGRect))
        OriginalFullscreenActionsSizeThatFits)(receiver, selector, size);
    if (!YTKACEFeatureEnabled(YTKACEFullscreenActionsKey)) return fitted;
    return CGSizeMake(fitted.width, YTKACEFullscreenActionsReservedHeight);
}

void YTKACEInstallOverlayVisibilityHooks(void) {
    YTKACEInstallInstanceHook(@"YTFullscreenActionsView", @"layoutSubviews",
                              (IMP)YTKACEFullscreenActionsLayout,
                              &OriginalFullscreenActionsLayout);
    YTKACEInstallInstanceHook(@"YTFullscreenEngagementActionBarView",
                              @"layoutSubviews",
                              (IMP)YTKACEFullscreenEngagementLayout,
                              &OriginalFullscreenEngagementLayout);
    YTKACEInstallInstanceHook(@"YTFullscreenEngagementActionBarView",
                              @"actionBarHeight",
                              (IMP)YTKACEFullscreenActionBarHeight,
                              &OriginalFullscreenActionBarHeight);
    YTKACEInstallInstanceHook(@"YTFullscreenActionsView",
                              @"sizeThatFits:",
                              (IMP)YTKACEFullscreenActionsSizeThatFits,
                              &OriginalFullscreenActionsSizeThatFits);
    YTKACERegisterOverlayConfigurator(@"visibility", ^(UIView *overlay,
                                                        UIStackView *stack) {
        for (UIView *subview in overlay.subviews) {
            if (subview != stack) {
                YTKACEApplyOverlayTree(subview);
            }
        }
        YTKACEApplyOverlaySelectors(overlay);
        YTKACEApplyProductVisibility(overlay);
    });
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"layoutSubviews",
                              (IMP)YTKACEVideoOverlayLayout,
                              &OriginalVideoOverlayLayout);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)YTKACEDidUpdatePlayerOverlayContent,
                              &OriginalDidUpdatePlayerOverlayContent);
    YTKACEInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"hasProductsInVideoOverlayRenderer",
                              (IMP)YTKACEHasProductsInVideoOverlay,
                              &OriginalHasProductsInVideoOverlay);
    YTKACEInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"productsInVideoOverlayRenderer",
                              (IMP)YTKACEProductsInVideoOverlay,
                              &OriginalProductsInVideoOverlay);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"didAddSubview:",
                              (IMP)YTKACEProductPillDidAddSubviewHook,
                              &OriginalProductPillOverlayDidAddSubview);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"didAddSubview:",
                              (IMP)YTKACEProductPillDidAddSubviewHook,
                              &OriginalProductPillControlsDidAddSubview);
    YTKACEInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)YTKACETimelyShelfDidInsert,
                              &OriginalTimelyShelfDidInsert);
    YTKACEInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)YTKACETimelyShelfDidUpdate,
                              &OriginalTimelyShelfDidUpdate);
    YTKACEInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfOverlay:",
                              (IMP)YTKACEUpdateTimelyShelfOverlay,
                              &OriginalUpdateTimelyShelfOverlay);
    YTKACEInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfState",
                              (IMP)YTKACEUpdateTimelyShelfState,
                              &OriginalUpdateTimelyShelfState);
    YTKACEInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfState:",
                              (IMP)YTKACEUpdateTimelyShelfStateWith,
                              &OriginalUpdateTimelyShelfStateWith);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setTimelyShelfFrame:fromOverlayBounds:",
                              (IMP)YTKACETimelyShelfFrame,
                              &OriginalTimelyShelfFrame);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"timelyShelfHeight",
                              (IMP)YTKACETimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightVC);
    YTKACEInstallInstanceHook(@"YTPlayerBarController",
                              @"timelyShelfHeight",
                              (IMP)YTKACETimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightBar);
    YTKACEInstallInstanceHook(@"YTPlayerBarLayoutInput",
                              @"timelyShelfHeight",
                              (IMP)YTKACETimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightInput);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"forceHidePreviousAndNextButtons",
                              (IMP)YTKACEForceHidePreviousNext,
                              &OriginalForceHidePreviousNext);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"previousButtonShouldHide",
                              (IMP)YTKACEPreviousButtonShouldHide,
                              &OriginalPreviousButtonShouldHide);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"nextButtonShouldHide",
                              (IMP)YTKACENextButtonShouldHide,
                              &OriginalNextButtonShouldHide);
    YTKACEInstallInstanceHook(@"YTColdConfig",
                              @"removeNextPaddleForSingletonVideos",
                              (IMP)YTKACERemoveNextPaddle,
                              &OriginalRemoveNextPaddle);
    YTKACEInstallInstanceHook(@"YTColdConfig",
                              @"removePreviousPaddleForSingletonVideos",
                              (IMP)YTKACERemovePreviousPaddle,
                              &OriginalRemovePreviousPaddle);
}
