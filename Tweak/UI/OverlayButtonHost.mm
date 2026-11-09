#import "OverlayButtonHost.h"
#import "../YTKACE.h"
#import "../Runtime/Hooking.h"
#import "../Runtime/Preferences.h"

#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP OriginalControlsOverlayLayout;
static IMP OriginalControlsSetOverlayVisible;
static IMP OriginalControlsSetControlsVisible;
static IMP OriginalVideoSetOverlayVisible;
static IMP OriginalVideoSetControlsVisible;
static IMP OriginalControlsSetHidden;
static const void *YTKACEOverlayStackAssociation = &YTKACEOverlayStackAssociation;
static const void *YTKACEOverlayTrailingAssociation = &YTKACEOverlayTrailingAssociation;
static const void *YTKACEOverlayAlignmentAssociation = &YTKACEOverlayAlignmentAssociation;
static NSMutableArray<NSDictionary *> *YTKACEOverlayConfigurators;
static BOOL YTKACENativeControlsVisible = YES;

static void YTKACEFindSettingsControlInView(UIView *view,
                                            UIView *excluded,
                                            UIView *coordinateView,
                                            UIView **best,
                                            CGFloat *bestScore) {
    if (view == excluded || [view isDescendantOfView:excluded] ||
        view.hidden || view.alpha < 0.05) {
        return;
    }
    NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @"",
        NSStringFromClass(view.class)] lowercaseString];
    if (([view isKindOfClass:UIControl.class] ||
         [view isKindOfClass:UIImageView.class]) &&
        ([hint containsString:@"settings"] || [hint containsString:@"gear"]) &&
        !CGRectIsEmpty(view.bounds)) {
        CGRect frame = [view convertRect:view.bounds toView:coordinateView];
        CGFloat width = CGRectGetWidth(coordinateView.bounds);
        CGFloat height = CGRectGetHeight(coordinateView.bounds);
        CGFloat centerX = CGRectGetMidX(frame);
        CGFloat centerY = CGRectGetMidY(frame);
        if (isfinite(centerX) && isfinite(centerY) &&
            centerX > width * 0.55 && centerY < height * 0.35 &&
            CGRectIntersectsRect(frame, coordinateView.bounds)) {
            CGFloat score = centerX - centerY * 0.2;
            if (*best == nil || score > *bestScore) {
                *best = view;
                *bestScore = score;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        YTKACEFindSettingsControlInView(subview, excluded, coordinateView,
                                        best, bestScore);
    }
}

static BOOL YTKACEIsTopTrailingControl(UIView *view, UIView *overlay) {
    CGRect frame = [view convertRect:view.bounds toView:overlay];
    CGFloat width = CGRectGetWidth(overlay.bounds);
    CGFloat height = CGRectGetHeight(overlay.bounds);
    CGFloat centerX = CGRectGetMidX(frame);
    CGFloat centerY = CGRectGetMidY(frame);
    return isfinite(centerX) && isfinite(centerY) &&
        centerX > width * 0.55 && centerY < height * 0.35 &&
        CGRectIntersectsRect(frame, overlay.bounds);
}

static UIView *YTKACEOverflowControl(UIView *overlay) {
    SEL selector = NSSelectorFromString(@"overflowButton");
    if (![overlay respondsToSelector:selector]) return nil;
    UIView *button = ((id (*)(id, SEL))objc_msgSend)(overlay, selector);
    if (![button isKindOfClass:UIView.class] || button.hidden ||
        button.alpha < 0.05 || CGRectIsEmpty(button.bounds)) {
        return nil;
    }
    return YTKACEIsTopTrailingControl(button, overlay) ? button : nil;
}

static UIView *YTKACEFindSettingsControl(UIView *overlay, UIView *excluded) {
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    YTKACEFindSettingsControlInView(overlay, excluded, overlay,
                                    &best, &bestScore);
    if (best == nil && overlay.window != nil) {
        YTKACEFindSettingsControlInView(overlay.window, excluded, overlay,
                                        &best, &bestScore);
    }
    return best;
}

static NSMutableDictionary *YTKACEAlignmentState(UIView *overlay) {
    NSMutableDictionary *state = objc_getAssociatedObject(
        overlay, YTKACEOverlayAlignmentAssociation);
    if (state == nil) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(overlay, YTKACEOverlayAlignmentAssociation,
                                 state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL YTKACEAlignOverlayStack(UIView *overlay, UIStackView *stack) {
    NSLayoutConstraint *trailing = objc_getAssociatedObject(
        overlay, YTKACEOverlayTrailingAssociation);
    if (trailing == nil) return NO;

    NSMutableDictionary *state = YTKACEAlignmentState(overlay);
    CGSize size = overlay.bounds.size;
    CGSize oldSize = [state[@"size"] CGSizeValue];
    if (fabs(size.width - oldSize.width) > 1.0 ||
        fabs(size.height - oldSize.height) > 1.0) {
        [state removeAllObjects];
        state[@"size"] = [NSValue valueWithCGSize:size];
    }
    UIWindow *window = overlay.window;
    CGSize windowSize = window != nil ? window.bounds.size : CGSizeZero;
    BOOL fillsLandscapeWindow = windowSize.width > windowSize.height &&
        CGRectGetWidth(overlay.bounds) >= windowSize.width * 0.94;
    CGFloat constant = fillsLandscapeWindow ? -20.0 : -8.0;
    NSNumber *previous = state[@"constant"];
    BOOL hasGearAlignment = [state[@"hasGearAlignment"] boolValue];
    UIView *gear = YTKACEOverflowControl(overlay) ?:
        YTKACEFindSettingsControl(overlay, stack);
    if (gear != nil) {
        CGRect frame = [gear.superview convertRect:gear.frame toView:overlay];
        CGFloat safeTrailing = CGRectGetMaxX(overlay.safeAreaLayoutGuide.layoutFrame);
        CGFloat center = CGRectGetMidX(frame);
        if (isfinite(center) && center > 0.0 && safeTrailing > 0.0) {
            constant = MIN(20.0, MAX(-160.0,
                center + 20.0 - safeTrailing));
            hasGearAlignment = YES;
            state[@"hasGearAlignment"] = @YES;
        }
    } else if (hasGearAlignment && previous != nil) {
        constant = previous.doubleValue;
    }

    NSUInteger stable = [state[@"stable"] unsignedIntegerValue];
    if (previous != nil && fabs(previous.doubleValue - constant) < 0.5) {
        stable += 1;
    } else {
        stable = 1;
    }
    state[@"constant"] = @(constant);
    state[@"stable"] = @(stable);
    [UIView performWithoutAnimation:^{
        trailing.constant = constant;
    }];

    BOOL ready = hasGearAlignment || stable >= 2;
    state[@"ready"] = @(ready);
    if (!ready) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [overlay setNeedsLayout];
        });
    }
    return ready;
}

static BOOL YTKACEKeepControlsVisible(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.AlwaysShowControls") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.AlwaysShowControls");
}

static void YTKACESetHostedControlsHidden(UIView *view, BOOL hidden) {
    if ([view.accessibilityIdentifier isEqualToString:@"YTKACEOverlayControls"]) {
        BOOL visible = !hidden;
        view.userInteractionEnabled = visible;
        if (visible) {
            [view.superview setNeedsLayout];
        }
        NSTimeInterval duration = [UIView inheritedAnimationDuration];
        if (duration <= 0.0 || duration > 1.0) duration = 0.20;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseInOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            view.alpha = visible ? 1.0 : 0.0;
        } completion:nil];
        return;
    }
    for (UIView *subview in view.subviews) {
        YTKACESetHostedControlsHidden(subview, hidden);
    }
}

static void YTKACEUpdateHostedVisibility(UIView *receiver, BOOL visible) {
    YTKACENativeControlsVisible = visible;
    YTKACESetHostedControlsHidden(receiver, !visible);
}

static void YTKACEControlsSetOverlayVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || YTKACEKeepControlsVisible();
    if (OriginalControlsSetOverlayVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetOverlayVisible)(receiver, selector, visible);
    }
    YTKACEUpdateHostedVisibility(receiver, visible);
}

static void YTKACEControlsSetControlsVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || YTKACEKeepControlsVisible();
    if (OriginalControlsSetControlsVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetControlsVisible)(receiver, selector, visible);
    }
    YTKACEUpdateHostedVisibility(receiver, visible);
}

static void YTKACEVideoSetOverlayVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || YTKACEKeepControlsVisible();
    if (OriginalVideoSetOverlayVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalVideoSetOverlayVisible)(receiver, selector, visible);
    }
    YTKACEUpdateHostedVisibility(receiver, visible);
}

static void YTKACEVideoSetControlsVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || YTKACEKeepControlsVisible();
    if (OriginalVideoSetControlsVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalVideoSetControlsVisible)(receiver, selector, visible);
    }
    YTKACEUpdateHostedVisibility(receiver, visible);
}

static void YTKACEControlsSetHidden(UIView *receiver, SEL selector, BOOL hidden) {
    hidden = hidden && !YTKACEKeepControlsVisible();
    if (OriginalControlsSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetHidden)(receiver, selector, hidden);
    }
    YTKACEUpdateHostedVisibility(receiver, !hidden);
}

static UIStackView *YTKACEStackForOverlay(UIView *overlay) {
    UIStackView *stack = objc_getAssociatedObject(overlay, YTKACEOverlayStackAssociation);
    if (stack != nil) {
        return stack;
    }

    stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 7.0;
    stack.layoutMargins = UIEdgeInsetsZero;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.backgroundColor = UIColor.clearColor;
    stack.alpha = YTKACENativeControlsVisible ? 1.0 : 0.0;
    stack.userInteractionEnabled = YTKACENativeControlsVisible;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.accessibilityIdentifier = @"YTKACEOverlayControls";

    [overlay addSubview:stack];
    NSLayoutConstraint *trailing =
        [stack.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor
                                             constant:-10.0];
    [NSLayoutConstraint activateConstraints:@[
        trailing,
        [stack.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:50.0],
        [stack.heightAnchor constraintEqualToConstant:40.0]
    ]];
    objc_setAssociatedObject(overlay, YTKACEOverlayTrailingAssociation,
                             trailing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay,
                             YTKACEOverlayStackAssociation,
                             stack,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return stack;
}

UIButton *YTKACEOverlayButton(UIStackView *stack,
                              NSString *identifier,
                              NSString *symbolName,
                              id target,
                              SEL action) {
    for (UIView *view in stack.arrangedSubviews) {
        if ([view.accessibilityIdentifier isEqualToString:identifier] &&
            [view isKindOfClass:UIButton.class]) {
            return (UIButton *)view;
        }
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = identifier;
    button.tintColor = UIColor.whiteColor;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        [button setPreferredSymbolConfiguration:configuration
                                forImageInState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:symbolName
                                  withConfiguration:configuration]
                forState:UIControlStateNormal];
    }
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:40.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
    [stack addArrangedSubview:button];
    return button;
}

void YTKACEDuoDeskControlsLayout(UIView *controls);

static void YTKACEControlsOverlayLayout(UIView *receiver, SEL selector) {
    if (OriginalControlsOverlayLayout != NULL) {
        ((void (*)(id, SEL))OriginalControlsOverlayLayout)(receiver, selector);
    }

    UIStackView *stack = YTKACEStackForOverlay(receiver);
    NSArray<NSDictionary *> *configurators = nil;
    @synchronized (YTKACEOverlayConfigurators) {
        configurators = [YTKACEOverlayConfigurators copy];
    }
    for (NSDictionary *entry in configurators) {
        YTKACEOverlayConfigurator configurator = entry[@"block"];
        configurator(receiver, stack);
    }
    BOOL aligned = YTKACEAlignOverlayStack(receiver, stack);

    BOOL visible = NO;
    for (UIView *view in stack.arrangedSubviews) {
        if (!view.hidden) {
            visible = YES;
            break;
        }
    }
    stack.hidden = !visible || !aligned;
    // Last, so the laptop-posture split moves the final positions.
    YTKACEDuoDeskControlsLayout(receiver);
}

void YTKACERegisterOverlayConfigurator(NSString *identifier,
                                       YTKACEOverlayConfigurator configurator) {
    if (identifier.length == 0 || configurator == nil) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEOverlayConfigurators = [NSMutableArray array];
    });

    @synchronized (YTKACEOverlayConfigurators) {
        for (NSDictionary *entry in YTKACEOverlayConfigurators) {
            if ([entry[@"identifier"] isEqualToString:identifier]) {
                return;
            }
        }
        [YTKACEOverlayConfigurators addObject:@{
            @"identifier": identifier,
            @"block": [configurator copy]
        }];
    }

    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"layoutSubviews",
                              (IMP)YTKACEControlsOverlayLayout,
                              &OriginalControlsOverlayLayout);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setOverlayVisible:",
                              (IMP)YTKACEControlsSetOverlayVisible,
                              &OriginalControlsSetOverlayVisible);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setControlsOverlayVisible:",
                              (IMP)YTKACEControlsSetControlsVisible,
                              &OriginalControlsSetControlsVisible);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setOverlayVisible:",
                              (IMP)YTKACEVideoSetOverlayVisible,
                              &OriginalVideoSetOverlayVisible);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setControlsOverlayVisible:",
                              (IMP)YTKACEVideoSetControlsVisible,
                              &OriginalVideoSetControlsVisible);
    YTKACEInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setHidden:",
                              (IMP)YTKACEControlsSetHidden,
                              &OriginalControlsSetHidden);
}

static UIViewController *YTKACESheetPresenter(UIView *sourceView) {
    UIResponder *responder = sourceView;
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([responder respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(responder, eventsSelector);
            if (events != nil) return events;
        }
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController != nil && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

id YTKACEMakeSheet(NSString *title, NSString *subtitle) {
    Class sheetClass = NSClassFromString(@"YTDefaultSheetController");
    if (sheetClass == Nil) return nil;
    SEL init = NSSelectorFromString(
        @"initWithSheetStyle:headerTitle:headerSubtitle:shouldDisableLogging:delegate:parentResponder:");
    if ([sheetClass instancesRespondToSelector:init]) {
        return ((id (*)(id, SEL, NSInteger, id, id, BOOL, id, id))objc_msgSend)(
            [sheetClass alloc], init, 2, title, subtitle, NO, nil, nil);
    }
    SEL makeSheet = NSSelectorFromString(@"sheetControllerWithMessage:subMessage:delegate:parentResponder:");
    if (![sheetClass respondsToSelector:makeSheet]) return nil;
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(sheetClass, makeSheet, title, subtitle, nil, nil);
}

BOOL YTKACEShowSheet(id sheet, UIViewController *presenter) {
    SEL present = NSSelectorFromString(@"presentFromViewController:animated:completion:");
    if (sheet == nil || presenter == nil || ![sheet respondsToSelector:present]) return NO;
    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(sheet, present, presenter, YES, nil);
    return YES;
}

void YTKACEPresentNativeSheet(NSString *title,
                              NSString *subtitle,
                              UIView *sourceView,
                              NSArray<NSDictionary *> *actions) {
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeSimple = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    SEL makeDetailed = NSSelectorFromString(
        @"actionWithTitle:iconImage:secondaryIconImage:accessibilityIdentifier:handler:");
    SEL makeValued = NSSelectorFromString(
        @"actionWithTitle:currentValue:iconImage:accessibilityIdentifier:handler:");
    SEL makeSelectable = NSSelectorFromString(
        @"actionWithTitle:subtitle:iconImage:visiblySelected:accessibilityLabel:"
        @"accessibilityIdentifier:handler:");
    SEL makeSubtitled = NSSelectorFromString(
        @"actionWithTitle:subtitle:iconImage:accessibilityIdentifier:handler:");
    SEL addAction = NSSelectorFromString(@"addAction:");
    if (actionClass == Nil ||
        ![actionClass respondsToSelector:makeSimple]) {
        return;
    }
    id sheet = YTKACEMakeSheet(title.length != 0 ? title : nil, subtitle.length != 0 ? subtitle : nil);
    if (sheet == nil || ![sheet respondsToSelector:addAction]) return;

    for (NSDictionary *item in actions) {
        dispatch_block_t handler = item[@"handler"];
        UIImage *secondary = item[@"secondary"];
        NSString *value = item[@"value"];
        NSString *subtitle = item[@"subtitle"];
        id action = nil;
        BOOL checked = [item[@"check"] boolValue];
        if ((checked || value.length != 0) && [actionClass respondsToSelector:makeValued]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeValued, item[@"title"], value ?: @"", item[@"icon"], nil, handler);
            UIImage *mark = checked ? (secondary ?: [[UIImage systemImageNamed:@"checkmark"]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]) : secondary;
            SEL setSecondary = NSSelectorFromString(@"setSecondaryIconImage:");
            if (mark != nil && [action respondsToSelector:setSecondary]) {
                ((void (*)(id, SEL, id))objc_msgSend)(action, setSecondary, mark);
            }
        } else if ([actionClass respondsToSelector:makeSelectable]) {
            action = ((id (*)(id, SEL, id, id, id, BOOL, id, id, id))objc_msgSend)(
                actionClass, makeSelectable, item[@"title"], subtitle,
                item[@"icon"], [item[@"selected"] boolValue], nil, nil, handler);
        } else if (subtitle.length != 0 &&
                   [actionClass respondsToSelector:makeSubtitled]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeSubtitled, item[@"title"], subtitle,
                item[@"icon"], nil, handler);
        } else if (value.length != 0 && [actionClass respondsToSelector:makeValued]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeValued, item[@"title"], value, item[@"icon"],
                nil, handler);
            SEL setSecondary = NSSelectorFromString(@"setSecondaryIconImage:");
            if (secondary != nil && [action respondsToSelector:setSecondary]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    action, setSecondary, secondary);
            }
        } else if (secondary != nil && [actionClass respondsToSelector:makeDetailed]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeDetailed, item[@"title"], item[@"icon"],
                secondary, nil, handler);
        } else {
            action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeSimple, item[@"title"], item[@"icon"], 0, handler);
        }
        if (action != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
        }
    }

    YTKACEShowSheet(sheet, YTKACESheetPresenter(sourceView));
}
