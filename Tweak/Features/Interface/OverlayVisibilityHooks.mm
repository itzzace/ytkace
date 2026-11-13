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
static const void *YTKACETimelyShelfProductAssociation = &YTKACETimelyShelfProductAssociation;
static const NSInteger YTKACETimelyShelfStateHidden = 2;
static IMP OriginalVideoOverlayLayout;
static IMP OriginalShouldHidePreviousButton;
static IMP OriginalShouldHideNextButton;
static IMP OriginalSetPreviousButtonEnabled;
static IMP OriginalSetNextButtonEnabled;
static IMP OriginalDidUpdatePlayerOverlayContent;
static IMP OriginalHasProductsInVideoOverlay;
static IMP OriginalProductsInVideoOverlay;
static IMP OriginalProductPillOverlayDidAddSubview;
static IMP OriginalProductPillControlsDidAddSubview;
static IMP OriginalTimelyShelfDidInsert;
static IMP OriginalTimelyShelfDidUpdate;
static IMP OriginalUpdateTimelyShelfOverlay;
static IMP OriginalUpdateTimelyShelfStateWith;
static IMP OriginalTimelyShelfFrame;
static IMP OriginalTimelyShelfHeightVC;
static IMP OriginalTimelyShelfHeightBar;
static IMP OriginalTimelyShelfHeightInput;
static IMP OriginalPlayerBarShouldShow;
static IMP OriginalAutonavShowEndscreen;
static IMP OriginalWatermarkNodeApply;
static const void *YTKACEWatermarkNodeAssociation = &YTKACEWatermarkNodeAssociation;

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

static UIView *YTKACEOverlayIvarView(id owner, const char *ivarName) {
    Ivar ivar = class_getInstanceVariable(object_getClass(owner), ivarName);
    return object_getIvar(owner, ivar);
}

static void YTKACEApplyPreviousNextVisibility(id controlsOverlay, BOOL hidden) {
    YTKACESetOverlayHidden(
        YTKACEOverlayIvarView(controlsOverlay, "_previousButtonView"), hidden);
    YTKACESetOverlayHidden(
        YTKACEOverlayIvarView(controlsOverlay, "_nextButtonView"), hidden);
    YTKACESetOverlayHidden(
        YTKACEOverlayIvarView(controlsOverlay, "_previousButtonViewFrostedGlassView"),
        hidden);
    YTKACESetOverlayHidden(
        YTKACEOverlayIvarView(controlsOverlay, "_nextButtonViewFrostedGlassView"),
        hidden);
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

static id YTKACETimelyShelfElementsRenderer(id overlay) {
    id controller =
        YTKACEProductOverlayModelValue(overlay, @"elementsOverlayViewController");
    return YTKACEProductOverlayModelValue(controller, @"renderer");
}

static BOOL YTKACETimelyShelfElementsShopping(id overlay) {
    NSData *data = YTKACEProductOverlayModelValue(
        YTKACETimelyShelfElementsRenderer(overlay), @"data");
    if (![data isKindOfClass:NSData.class] || data.length == 0) return NO;
    NSData *marker =
        [@"shopping_timely_shelf" dataUsingEncoding:NSASCIIStringEncoding];
    return [data rangeOfData:marker
                     options:0
                       range:NSMakeRange(0, data.length)].location != NSNotFound;
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
         (renderer != nil && YTKACETimelyShelfShoppingPayloadMatches(renderer)) ||
         YTKACETimelyShelfElementsShopping(overlay))) {
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
    BOOL control = [view isKindOfClass:UIControl.class] ||
        YTKACEOverlayTokenMatches(token, @[@"control", @"button"]);
    BOOL force = (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowPlayPause") && playPause) ||
        (YTKACEOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowControls") && control);
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
        @"featuredChannelWatermarkImageView": @"YTKACE.Preference.Overlay.WatermarkHidden",
        @"endscreenView": @"YTKACE.Preference.Overlay.EndScreenHidden",
        @"creatorEndscreenView": @"YTKACE.Preference.Overlay.EndScreenHidden",
        @"playPauseButton": @"YTKACE.Preference.Overlay.PlayPauseHidden",
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

static id YTKACEElementsValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL YTKACENodeIsInVideoSubtitle(id node) {
    id controller = YTKACEElementsValue(node, @"nodeController");
    for (NSUInteger depth = 0; controller != nil && depth < 8; depth++) {
        id component = YTKACEElementsValue(controller, @"owningComponent");
        if (component != nil) {
            NSString *uri = [YTKACEElementsValue(component, @"templateURI") description];
            return [uri hasPrefix:@"video_subtitle.eml"];
        }
        controller = YTKACEElementsValue(controller, @"parent");
    }
    return NO;
}

static BOOL YTKACESubtitleSeparatorCharacter(unichar character, BOOL *bullet) {
    if (character == 0x2022 || character == 0x00B7) {
        *bullet = YES;
        return YES;
    }
    return [NSCharacterSet.whitespaceCharacterSet characterIsMember:character];
}

static NSArray<NSValue *> *YTKACESubtitleSeparators(NSString *string) {
    NSMutableArray<NSValue *> *separators = [NSMutableArray array];
    NSUInteger length = string.length;
    for (NSUInteger index = 0; index < length;) {
        BOOL bullet = NO;
        NSUInteger start = index;
        while (index < length &&
               YTKACESubtitleSeparatorCharacter([string characterAtIndex:index], &bullet)) {
            index++;
        }
        if (index == start) {
            index++;
            continue;
        }
        if (index - start >= 2 || bullet) {
            [separators addObject:[NSValue valueWithRange:NSMakeRange(start, index - start)]];
        }
    }
    return separators;
}

static BOOL YTKACEIsProductCount(NSString *segment) {
    NSString *text = [segment lowercaseString];
    if (text.length == 0 ||
        ![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[text characterAtIndex:0]] ||
        !YTKACEProductTokenHasBareProduct(text)) {
        return NO;
    }
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    return words.count <= 2;
}

NSAttributedString *YTKACESubtitleWithoutProductCount(id node, NSAttributedString *text) {
    if (![text isKindOfClass:NSAttributedString.class] || text.length == 0 ||
        [text.string rangeOfString:@"product"
                           options:NSCaseInsensitiveSearch].location == NSNotFound ||
        !YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        return text;
    }
    NSString *string = text.string;
    NSArray<NSValue *> *separators = YTKACESubtitleSeparators(string);
    NSMutableArray<NSValue *> *pieces = [NSMutableArray array];
    NSMutableIndexSet *counts = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *gaps = [NSMutableIndexSet indexSet];
    NSUInteger start = 0;
    for (NSUInteger slot = 0; slot <= separators.count; slot++) {
        NSRange separator = slot < separators.count ? separators[slot].rangeValue
                                                    : NSMakeRange(string.length, 0);
        NSRange segment = NSMakeRange(start, separator.location - start);
        if (segment.length != 0) {
            if (YTKACEIsProductCount([string substringWithRange:segment])) {
                [counts addIndex:pieces.count];
            }
            [pieces addObject:[NSValue valueWithRange:segment]];
        }
        if (separator.length != 0) {
            [gaps addIndex:pieces.count];
            [pieces addObject:[NSValue valueWithRange:separator]];
        }
        start = NSMaxRange(separator);
    }
    if (counts.count == 0 || !YTKACENodeIsInVideoSubtitle(node)) return text;

    NSMutableAttributedString *filtered = [NSMutableAttributedString new];
    BOOL leading = separators.count != 0 && separators.firstObject.rangeValue.location == 0;
    BOOL kept = NO;
    NSRange pending = NSMakeRange(NSNotFound, 0);
    for (NSUInteger index = 0; index < pieces.count; index++) {
        NSRange range = pieces[index].rangeValue;
        if ([gaps containsIndex:index]) {
            pending = range;
            continue;
        }
        if ([counts containsIndex:index]) continue;
        if (pending.location != NSNotFound && (kept || leading)) {
            [filtered appendAttributedString:[text attributedSubstringFromRange:pending]];
        }
        [filtered appendAttributedString:[text attributedSubstringFromRange:range]];
        kept = YES;
        pending = NSMakeRange(NSNotFound, 0);
    }
    BOOL trailing = separators.count != 0 &&
        NSMaxRange(separators.lastObject.rangeValue) == string.length;
    if (trailing && pending.location != NSNotFound && (kept || leading)) {
        [filtered appendAttributedString:[text attributedSubstringFromRange:pending]];
    }
    return filtered;
}

static IMP OriginalTextNodeSetNodeController;

static void YTKACETextNodeSetNodeController(id receiver, SEL selector, id controller) {
    if (OriginalTextNodeSetNodeController != NULL) {
        ((void (*)(id, SEL, id))OriginalTextNodeSetNodeController)(receiver, selector,
                                                                   controller);
    }
    NSAttributedString *text = YTKACEElementsValue(receiver, @"attributedText");
    NSAttributedString *filtered = YTKACESubtitleWithoutProductCount(receiver, text);
    if (filtered != text) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            receiver, NSSelectorFromString(@"setAttributedText:"), filtered);
    }
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

static BOOL YTKACETimelyShelfOverlayIsProduct(id overlay) {
    if (overlay == nil) return NO;
    id renderer = YTKACETimelyShelfElementsRenderer(overlay);
    if (renderer == nil) return YTKACEProductOverlayMatches(overlay);
    NSNumber *cached =
        objc_getAssociatedObject(renderer, YTKACETimelyShelfProductAssociation);
    if (cached == nil) {
        cached = @(YTKACEProductOverlayMatches(overlay));
        objc_setAssociatedObject(renderer, YTKACETimelyShelfProductAssociation,
                                 cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cached.boolValue;
}

static BOOL YTKACETimelyShelfShowsProduct(id manager) {
    if (manager == nil) return NO;
    id active =
        YTKACEProductOverlayModelValue(manager, @"activeTimelyShelfOverlay");
    if (active != nil) return YTKACETimelyShelfOverlayIsProduct(active);
    if (YTKACEProductOverlayBoolValue(manager,
                                      @"isIosMultipleTimelyShelvesEnabled")) {
        return NO;
    }
    NSDictionary *shelves =
        YTKACEProductOverlayModelValue(manager, @"timelyShelfDictionary");
    if (![shelves isKindOfClass:NSDictionary.class]) return NO;
    for (id overlay in shelves.allValues) {
        if (YTKACETimelyShelfOverlayIsProduct(overlay)) return YES;
    }
    return NO;
}

static id YTKACETimelyShelfManagerForOwner(id owner) {
    SEL managerSelector = NSSelectorFromString(@"timelyShelfStateManager");
    if (![owner respondsToSelector:managerSelector] &&
        [owner respondsToSelector:@selector(delegate)]) {
        owner = ((id (*)(id, SEL))objc_msgSend)(owner, @selector(delegate));
    }
    if (![owner respondsToSelector:managerSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(owner, managerSelector);
}

static void YTKACEUpdateTimelyShelfStateWith(id receiver, SEL selector,
                                              NSInteger state) {
    if (state != YTKACETimelyShelfStateHidden &&
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACETimelyShelfShowsProduct(receiver)) {
        state = YTKACETimelyShelfStateHidden;
    }
    if (OriginalUpdateTimelyShelfStateWith != NULL) {
        ((void (*)(id, SEL, NSInteger))OriginalUpdateTimelyShelfStateWith)(
            receiver, selector, state);
    }
}

static void YTKACETimelyShelfFrame(id receiver, SEL selector,
                                    id shelf, CGRect overlayBounds) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACETimelyShelfOverlayIsProduct(shelf)) {
        id view = YTKACEProductOverlayModelValue(shelf, @"overlayView");
        if ([view isKindOfClass:UIView.class]) {
            UIView *shelfView = (UIView *)view;
            YTKACEProductHiddenCounted(shelfView, YES);
            YTKACEProductSetHidden(shelfView, YES);
            shelfView.frame = CGRectZero;
        }
        return;
    }
    if (OriginalTimelyShelfFrame != NULL) {
        ((void (*)(id, SEL, id, CGRect))OriginalTimelyShelfFrame)(
            receiver, selector, shelf, overlayBounds);
    }
}

static CGFloat YTKACETimelyShelfHeightHook(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACETimelyShelfShowsProduct(
            YTKACETimelyShelfManagerForOwner(receiver))) {
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

static BOOL YTKACEShouldHidePreviousButton(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    // seeking works without a previous video
    if (YTKACEPreviousNextSeekSeconds() > 0) return NO;
    return OriginalShouldHidePreviousButton == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalShouldHidePreviousButton)(
            receiver, selector);
}

static BOOL YTKACEShouldHideNextButton(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    if (YTKACEPreviousNextSeekSeconds() > 0) return NO;
    return OriginalShouldHideNextButton == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalShouldHideNextButton)(
            receiver, selector);
}

static void YTKACESetPreviousButtonEnabled(id receiver, SEL selector, BOOL enabled) {
    ((void (*)(id, SEL, BOOL))OriginalSetPreviousButtonEnabled)(
        receiver, selector, enabled || YTKACEPreviousNextSeekSeconds() > 0);
    YTKACEApplyPreviousNextVisibility(
        receiver,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
}

static void YTKACESetNextButtonEnabled(id receiver, SEL selector, BOOL enabled) {
    ((void (*)(id, SEL, BOOL))OriginalSetNextButtonEnabled)(
        receiver, selector, enabled || YTKACEPreviousNextSeekSeconds() > 0);
    YTKACEApplyPreviousNextVisibility(
        receiver,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
}

static BOOL YTKACEPlayerBarShouldShow(id receiver, SEL selector, id controller) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProgressAlwaysVisible")) {
        return YES;
    }
    return ((BOOL (*)(id, SEL, id))OriginalPlayerBarShouldShow)(receiver, selector, controller);
}

static BOOL YTKACEAutonavFlag(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void YTKACEAutonavShowEndscreen(id receiver, SEL selector) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.AutoplayPromptHidden")) {
        if (OriginalAutonavShowEndscreen != NULL) {
            ((void (*)(id, SEL))OriginalAutonavShowEndscreen)(receiver, selector);
        }
        return;
    }
    SEL delegateGetter = NSSelectorFromString(@"endscreenDelegate");
    id delegate = [receiver respondsToSelector:delegateGetter] ?
        ((id (*)(id, SEL))objc_msgSend)(receiver, delegateGetter) : nil;
    SEL play = NSSelectorFromString(@"playAutonav");
    if ((YTKACEAutonavFlag(receiver, @"shouldAutonavInBackground") ||
         YTKACEAutonavFlag(receiver, @"shouldStartCountdown")) &&
        !YTKACEAutonavFlag(delegate, @"isVideoInSingleLoop") &&
        [receiver respondsToSelector:play]) {
        ((void (*)(id, SEL))objc_msgSend)(receiver, play);
    }
}

static void YTKACEApplyWatermarkNode(id node) {
    BOOL hide = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.WatermarkHidden");
    if (!hide && objc_getAssociatedObject(node, YTKACEWatermarkNodeAssociation) == nil) return;
    objc_setAssociatedObject(node, YTKACEWatermarkNodeAssociation, hide ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), hide);
}

static void YTKACEWatermarkNodeApply(id receiver, SEL selector) {
    if (OriginalWatermarkNodeApply != NULL) {
        ((void (*)(id, SEL))OriginalWatermarkNodeApply)(receiver, selector);
    }
    SEL getter = NSSelectorFromString(@"accessibilityIdentifier");
    if (![receiver respondsToSelector:getter] ||
        ![receiver respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
        return;
    }
    id identifier = ((id (*)(id, SEL))objc_msgSend)(receiver, getter);
    if (![identifier isKindOfClass:NSString.class] || ![identifier isEqualToString:@"watermark_image"]) return;
    if (NSThread.isMainThread) {
        YTKACEApplyWatermarkNode(receiver);
        return;
    }
    __weak id weakNode = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        id node = weakNode;
        if (node != nil) YTKACEApplyWatermarkNode(node);
    });
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

// Fullscreen bar (under the progress bar): a pill of buttons on the left and
// More videos on the right, both built from Elements nodes. Hidden buttons are
// collapsed to zero width so the pill shrinks to the ones left.
typedef struct { NSInteger unit; CGFloat value; } YTKACEDimension;
static const void *YTKACEFullscreenCollapsedKey = &YTKACEFullscreenCollapsedKey;
static const void *YTKACEFullscreenWidthsKey = &YTKACEFullscreenWidthsKey;

static id YTKACEFullscreenGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void YTKACEFullscreenRelayout(id node) {
    for (id current = node; current != nil; current = YTKACEFullscreenGet(current, @"supernode")) {
        SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
        if ([current respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        SEL needs = NSSelectorFromString(@"setNeedsLayout");
        if ([current respondsToSelector:needs]) ((void (*)(id, SEL))objc_msgSend)(current, needs);
    }
}

static BOOL YTKACEFullscreenCollapse(id node, BOOL collapse) {
    if (node == nil) return NO;
    if ([objc_getAssociatedObject(node, YTKACEFullscreenCollapsedKey) boolValue] == collapse) return NO;
    id style = YTKACEFullscreenGet(node, @"style");
    NSArray<NSString *> *names = @[@"width", @"minWidth", @"maxWidth"];
    if (collapse) {
        NSMutableArray *saved = [NSMutableArray array];
        for (NSString *name in names) {
            SEL getter = NSSelectorFromString(name);
            YTKACEDimension value = {0, 0};
            if ([style respondsToSelector:getter]) {
                value = ((YTKACEDimension (*)(id, SEL))objc_msgSend)(style, getter);
            }
            [saved addObject:[NSValue valueWithBytes:&value objCType:@encode(YTKACEDimension)]];
        }
        objc_setAssociatedObject(node, YTKACEFullscreenWidthsKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray<NSValue *> *saved = objc_getAssociatedObject(node, YTKACEFullscreenWidthsKey);
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *name = names[index];
        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
            [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]]);
        if (![style respondsToSelector:setter]) continue;
        YTKACEDimension value = {1, 0};
        if (!collapse) {
            value = (YTKACEDimension){0, 0};
            if (index < saved.count) [saved[index] getValue:&value];
        }
        ((void (*)(id, SEL, YTKACEDimension))objc_msgSend)(style, setter, value);
    }
    SEL hidden = NSSelectorFromString(@"setHidden:");
    if ([node respondsToSelector:hidden]) ((void (*)(id, SEL, BOOL))objc_msgSend)(node, hidden, collapse);
    objc_setAssociatedObject(node, YTKACEFullscreenCollapsedKey, @(collapse), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static NSString *YTKACEFullscreenID(id node) {
    id value = YTKACEFullscreenGet(node, @"accessibilityIdentifier");
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSArray *YTKACEFullscreenChildren(id node) {
    NSArray *children = YTKACEFullscreenGet(node, @"yogaChildren");
    return [children isKindOfClass:NSArray.class] ? children : @[];
}

// The bar's nodes:
//   root > wrapper > [pill, spacer, More videos]
//   pill > [glass, wrapper > like, wrapper > dislike, ..., wrapper > ⋯]
// Wrappers have no size of their own; each button is the one node inside.
static id YTKACEFullscreenButton(id slot) {
    if (YTKACEFullscreenID(slot).length != 0) return slot;
    for (id child in YTKACEFullscreenChildren(slot)) {
        if (YTKACEFullscreenID(child).length != 0) return child;
    }
    return nil;
}

static BOOL YTKACEFullscreenIsPill(id group) {
    for (id slot in YTKACEFullscreenChildren(group)) {
        if ([YTKACEFullscreenID(YTKACEFullscreenButton(slot)) isEqualToString:@"id.video.like.button"]) return YES;
    }
    return NO;
}

static const void *YTKACEFullscreenNameKey = &YTKACEFullscreenNameKey;

// YTKACE's buttons in the fullscreen zone, as [{id, width}] in their own
// order. Each gets an empty node of that width in YouTube's pill, placed by
// the saved order (which names YouTube's buttons and ours), and
// OverlayButtonHost lays the button over it.
NSArray<NSDictionary *> *YTKACEFullscreenGroups = nil;
static const void *YTKACEFullscreenSpacersKey = &YTKACEFullscreenSpacersKey;
static const void *YTKACEFullscreenSpacerWidthKey = &YTKACEFullscreenSpacerWidthKey;
static NSMapTable<NSString *, id> *YTKACEFullscreenLiveSpacers;

static CGSize YTKACEFullscreenSpacerSize(id receiver, __unused SEL selector, __unused CGSize constrained) {
    return CGSizeMake([objc_getAssociatedObject(receiver, YTKACEFullscreenSpacerWidthKey) doubleValue], 48.0);
}

static Class YTKACEFullscreenSpacerClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASDisplayNode");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "YTKACEFullscreenSpacerNode", 0);
        if (cls == Nil) { cls = NSClassFromString(@"YTKACEFullscreenSpacerNode"); return; }
        class_addMethod(cls, NSSelectorFromString(@"calculateSizeThatFits:"),
                        (IMP)YTKACEFullscreenSpacerSize, "{CGSize=dd}32@0:8{CGSize=dd}16");
        objc_registerClassPair(cls);
    });
    return cls;
}

static __weak id YTKACEFullscreenLivePill;

// Finds element's spot in a layout tree, relative to the tree's node.
static BOOL YTKACEFindInLayout(id layout, id element, CGPoint origin, int depth, CGRect *frame) {
    if (layout == nil || depth > 6) return NO;
    for (id sublayout in YTKACEFullscreenGet(layout, @"sublayouts")) {
        CGPoint position = ((CGPoint (*)(id, SEL))objc_msgSend)(sublayout, NSSelectorFromString(@"position"));
        CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(sublayout, NSSelectorFromString(@"size"));
        CGPoint at = CGPointMake(origin.x + (isfinite(position.x) ? position.x : 0.0),
                                 origin.y + (isfinite(position.y) ? position.y : 0.0));
        if (YTKACEFullscreenGet(sublayout, @"layoutElement") == element) {
            *frame = (CGRect){at, size};
            return YES;
        }
        if (YTKACEFindInLayout(sublayout, element, at, depth + 1, frame)) return YES;
    }
    return NO;
}

// Where the empty node for one of our buttons is, in view's coordinates. The
// pill manages its own subnodes, so the node has no layer; its spot comes
// from the pill's last layout.
BOOL YTKACEFullscreenGroupFrame(NSString *group, UIView *view, CGRect *frame) {
    id spacer = [YTKACEFullscreenLiveSpacers objectForKey:group];
    id pill = YTKACEFullscreenLivePill;
    if (spacer == nil || pill == nil || view == nil) return NO;
    SEL loaded = NSSelectorFromString(@"isNodeLoaded");
    if (![pill respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(pill, loaded)) return NO;
    CALayer *layer = YTKACEFullscreenGet(pill, @"layer");
    if (![layer isKindOfClass:CALayer.class]) return NO;
    BOOL inside = NO;
    for (CALayer *current = layer; current != nil; current = current.superlayer) {
        if (current == view.layer) { inside = YES; break; }
    }
    CGRect local;
    if (!inside || !YTKACEFindInLayout(YTKACEFullscreenGet(pill, @"calculatedLayout"), spacer, CGPointZero, 0, &local) ||
        CGRectGetWidth(local) < 1.0) return NO;
    *frame = [layer convertRect:local toLayer:view.layer];
    return YES;
}

// Makes or resizes the empty nodes. Returns YES when a size changed.
static BOOL YTKACEUpdateFullscreenSpacers(NSMutableDictionary<NSString *, id> *spacers) {
    BOOL changed = NO;
    NSMutableSet *wanted = [NSMutableSet set];
    for (NSDictionary *group in YTKACEFullscreenGroups) {
        NSString *identifier = group[@"id"];
        const CGFloat width = [group[@"width"] doubleValue];
        if (identifier.length == 0 || width <= 0.0) continue;
        [wanted addObject:identifier];
        id spacer = spacers[identifier];
        if (spacer == nil) {
            Class cls = YTKACEFullscreenSpacerClass();
            if (cls == Nil) continue;
            spacer = [cls new];
            ((void (*)(id, SEL))objc_msgSend)(spacer, NSSelectorFromString(@"enableYoga"));
            spacers[identifier] = spacer;
        }
        if ([objc_getAssociatedObject(spacer, YTKACEFullscreenSpacerWidthKey) doubleValue] != width) {
            objc_setAssociatedObject(spacer, YTKACEFullscreenSpacerWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // A style width marks the node for layout again; a measured
            // size alone stays cached.
            id style = YTKACEFullscreenGet(spacer, @"style");
            SEL setWidth = NSSelectorFromString(@"setWidth:");
            if ([style respondsToSelector:setWidth]) {
                ((void (*)(id, SEL, YTKACEDimension))objc_msgSend)(style, setWidth, (YTKACEDimension){1, width});
            }
            SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
            if ([spacer respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(spacer, invalidate);
            changed = YES;
        }
    }
    for (NSString *identifier in spacers.allKeys) {
        if (![wanted containsObject:identifier]) [spacers removeObjectForKey:identifier];
    }
    if (YTKACEFullscreenLiveSpacers == nil) YTKACEFullscreenLiveSpacers = [NSMapTable strongToWeakObjectsMapTable];
    [YTKACEFullscreenLiveSpacers removeAllObjects];
    for (NSString *identifier in spacers) [YTKACEFullscreenLiveSpacers setObject:spacers[identifier] forKey:identifier];
    return changed;
}

// Puts YouTube's buttons and our empty nodes in the saved order. Buttons the
// order doesn't name keep their place after the named ones; ours not named go
// last. Done after the current layout pass.
static void YTKACEOrderFullscreenPill(id pill, NSArray *slots, NSArray<NSString *> *keys,
                                      NSDictionary<NSString *, id> *spacers) {
    NSArray *children = YTKACEFullscreenChildren(pill);
    NSArray *order = YTKACEPreferenceObject(@"YTKACE.Preference.Fullscreen.Order");
    if (![order isKindOfClass:NSArray.class]) order = @[];
    NSMutableArray *sorted = [NSMutableArray array];
    for (id name in order) {
        if (![name isKindOfClass:NSString.class]) continue;
        id item = spacers[name];
        if (item == nil && slots.count == keys.count) {
            NSUInteger index = [keys indexOfObject:name];
            if (index != NSNotFound) item = slots[index];
        }
        if (item != nil && ![sorted containsObject:item]) [sorted addObject:item];
    }
    for (id slot in slots) {
        if (![sorted containsObject:slot]) [sorted addObject:slot];
    }
    for (NSDictionary *group in YTKACEFullscreenGroups) {
        id spacer = spacers[group[@"id"] ?: @""];
        if (spacer != nil && ![sorted containsObject:spacer]) [sorted addObject:spacer];
    }
    // Everything else (the glass) keeps its side of the buttons.
    NSMutableArray *leading = [NSMutableArray array];
    NSMutableArray *trailing = [NSMutableArray array];
    BOOL seen = NO;
    for (id child in children) {
        const BOOL movable = [slots containsObject:child] ||
            [NSStringFromClass([child class]) isEqualToString:@"YTKACEFullscreenSpacerNode"];
        if (movable) seen = YES;
        else [seen ? trailing : leading addObject:child];
    }
    NSMutableArray *next = [leading mutableCopy];
    [next addObjectsFromArray:sorted];
    [next addObjectsFromArray:trailing];
    if ([next isEqualToArray:children]) return;
    __weak id weakPill = pill;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongPill = weakPill;
        if (![YTKACEFullscreenChildren(strongPill) isEqualToArray:children]) return;
        SEL set = NSSelectorFromString(@"setYogaChildren:");
        if (![strongPill respondsToSelector:set]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(strongPill, set, next);
        } @catch (NSException *exception) {
            YTKACEDebugLog(@"fsbar", @"reorder threw %@", exception.reason);
            return;
        }
        YTKACEFullscreenRelayout(strongPill);
    });
}

static void YTKACEApplyFullscreenBar(UIView *bar) {
    id root = nil;
    for (UIView *subview in bar.subviews) {
        root = YTKACEFullscreenGet(subview, @"keepalive_node");
        if (root != nil) break;
    }
    // Step through single-child wrappers to the row of groups.
    NSArray *groups = YTKACEFullscreenChildren(root);
    for (NSUInteger step = 0; groups.count == 1 && step < 3; step++) {
        groups = YTKACEFullscreenChildren(groups.firstObject);
    }
    id pill = nil;
    for (id group in groups) {
        if (YTKACEFullscreenIsPill(group)) pill = group;
    }
    if (pill == nil) return;
    BOOL changed = NO;
    BOOL hideMore = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.MoreVideosHidden");
    for (id group in groups) {
        if (group == pill || YTKACEFullscreenChildren(group).count == 0) continue;
        changed |= YTKACEFullscreenCollapse(group, hideMore);
    }
    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *slots = [NSMutableArray array];
    for (id slot in YTKACEFullscreenChildren(pill)) {
        id button = YTKACEFullscreenButton(slot);
        if (button == nil) continue;
        [buttons addObject:button];
        [slots addObject:slot];
    }
    // Comments, Ask and ⋯ share an id; in YouTube's order Comments follows
    // dislike and ⋯ is last. Each button is named the first time it's seen,
    // before any reordering, and keeps that name.
    NSUInteger last = NSNotFound;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        if ([YTKACEFullscreenID(buttons[index]) isEqualToString:@"id.elements.button"]) last = index;
    }
    BOOL afterDislike = NO;
    NSUInteger shown = 0;
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSUInteger index = 0; index < buttons.count; index++) {
        id button = buttons[index];
        NSString *identifier = YTKACEFullscreenID(button);
        NSString *key = objc_getAssociatedObject(button, YTKACEFullscreenNameKey);
        if (key == nil) {
            if ([identifier isEqualToString:@"id.video.like.button"]) key = @"Like";
            else if ([identifier isEqualToString:@"id.video.dislike.button"]) key = @"Dislike";
            else if ([identifier isEqualToString:@"id.video.add_to.button"]) key = @"Save";
            else if ([identifier isEqualToString:@"id.video.share.button"]) key = @"Share";
            else if ([identifier isEqualToString:@"id.elements.button"]) {
                key = afterDislike ? @"Comments" : (index == last ? @"Overflow" : @"Ask");
            }
            if (key != nil) objc_setAssociatedObject(button, YTKACEFullscreenNameKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        [keys addObject:key ?: @""];
        afterDislike = [identifier isEqualToString:@"id.video.dislike.button"];
        BOOL hide = key != nil && YTKACEFeatureEnabled(
            [NSString stringWithFormat:@"YTKACE.Preference.Fullscreen.%@Hidden", key]);
        changed |= YTKACEFullscreenCollapse(button, hide);
        if (slots[index] != button) changed |= YTKACEFullscreenCollapse(slots[index], hide);
        if (!hide) shown++;
    }
    // Nothing left in the pill: hide its glass too, unless YTKACE's buttons use it.
    changed |= YTKACEFullscreenCollapse(pill, buttons.count != 0 && shown == 0 && YTKACEFullscreenGroups.count == 0);
    NSMutableDictionary *spacers = objc_getAssociatedObject(pill, YTKACEFullscreenSpacersKey);
    if (spacers == nil) {
        spacers = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(pill, YTKACEFullscreenSpacersKey, spacers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    changed |= YTKACEUpdateFullscreenSpacers(spacers);
    YTKACEFullscreenLivePill = pill;
    if (changed) YTKACEFullscreenRelayout(root);
    YTKACEOrderFullscreenPill(pill, slots, keys, spacers);
}

static void YTKACEFullscreenActionsLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenActionsLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenActionsLayout)(receiver, selector);
    }
    YTKACEApplyHidden(receiver, YTKACEFullscreenActionsKey);
    if (!receiver.hidden) {
        YTKACEApplyFullscreenBar(receiver);
        YTKACEFullscreenBarDidLayout(receiver);
    }
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
                                                   CGSize size) {
    CGSize fitted = ((CGSize (*)(id, SEL, CGSize))
        OriginalFullscreenActionsSizeThatFits)(receiver, selector, size);
    if (!YTKACEFeatureEnabled(YTKACEFullscreenActionsKey)) return fitted;
    return CGSizeMake(fitted.width, YTKACEFullscreenActionsReservedHeight);
}

void YTKACEInstallOverlayVisibilityHooks(void) {
    YTKACEInstallInstanceHook(@"ELMTextNode", @"__setNodeController:",
                              (IMP)YTKACETextNodeSetNodeController,
                              &OriginalTextNodeSetNodeController);
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
        YTKACEApplyPreviousNextVisibility(
            overlay,
            YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
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
                              @"shouldHidePreviousButton",
                              (IMP)YTKACEShouldHidePreviousButton,
                              &OriginalShouldHidePreviousButton);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"shouldHideNextButton",
                              (IMP)YTKACEShouldHideNextButton,
                              &OriginalShouldHideNextButton);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setPreviousButtonEnabled:",
                              (IMP)YTKACESetPreviousButtonEnabled,
                              &OriginalSetPreviousButtonEnabled);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setNextButtonEnabled:",
                              (IMP)YTKACESetNextButtonEnabled,
                              &OriginalSetNextButtonEnabled);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerBarControllerShouldShowPlayerBarView:",
                              (IMP)YTKACEPlayerBarShouldShow,
                              &OriginalPlayerBarShouldShow);
    YTKACEInstallInstanceHook(@"YTAutonavEndscreenController",
                              @"showEndscreen",
                              (IMP)YTKACEAutonavShowEndscreen,
                              &OriginalAutonavShowEndscreen);
    YTKACEInstallInstanceHook(@"ELMImageNode",
                              @"controllerDidApplyProperties",
                              (IMP)YTKACEWatermarkNodeApply,
                              &OriginalWatermarkNodeApply);
}
