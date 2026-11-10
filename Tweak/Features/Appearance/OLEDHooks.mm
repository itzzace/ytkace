#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Interface/NavigationVisibility.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableDictionary<NSString *, NSValue *> *YTKACEOLEDOriginals;
static IMP OriginalQualitySheetDidAppear;
static IMP OriginalAppTraitChanged;
static IMP OriginalAppStatusBarStyle;

static NSValue *YTKACEOLEDValue(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP YTKACEOLEDImplementation(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static NSString *YTKACEOLEDOriginalKey(id receiver, SEL selector) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? receiver : [receiver class];
    return [NSString stringWithFormat:@"%@|%@|%@",
            classMethod ? @"+" : @"-",
            NSStringFromClass(cls),
            NSStringFromSelector(selector)];
}

static UIColor *YTKACEOLEDColor(id receiver, SEL selector) {
    IMP original = YTKACEOLEDImplementation(
        YTKACEOLEDOriginals[YTKACEOLEDOriginalKey(receiver, selector)]
    );
    UIColor *base = original == NULL
        ? nil
        : ((id (*)(id, SEL))original)(receiver, selector);
    if (!YTKACEFeatureEnabled(YTKACEOLEDKey)) return base;
    // light mode: leave YouTube's colors alone
    if (!YTKACEOLEDActive(nil)) return base;
    __weak id weakReceiver = receiver;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (YTKACEOLEDActive(traits)) return UIColor.blackColor;
        id target = weakReceiver;
        UIColor *current = target == nil || original == NULL
            ? base
            : ((id (*)(id, SEL))original)(target, selector);
        return current == nil ? [UIColor.systemBackgroundColor
            resolvedColorWithTraitCollection:traits]
            : [current resolvedColorWithTraitCollection:traits];
    }];
}

static void YTKACERefreshStatusBars(UIViewController *controller) {
    if (controller == nil) return;
    [controller setNeedsStatusBarAppearanceUpdate];
    if ([controller isKindOfClass:UINavigationController.class]) {
        YTKACERefreshStatusBars(((UINavigationController *)controller).visibleViewController);
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        YTKACERefreshStatusBars(((UITabBarController *)controller).selectedViewController);
    }
    YTKACERefreshStatusBars(controller.presentedViewController);
}

static NSInteger YTKACEAppStatusBarStyle(UIViewController *receiver,
                                         SEL selector) {
    NSInteger original = OriginalAppStatusBarStyle == NULL
        ? UIStatusBarStyleDefault
        : ((NSInteger (*)(id, SEL))OriginalAppStatusBarStyle)(receiver, selector);
    if (!YTKACEFeatureEnabled(YTKACEOLEDKey)) return original;
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    NSInteger result = style == UIUserInterfaceStyleDark
        ? UIStatusBarStyleLightContent
        : UIStatusBarStyleDarkContent;
    return result;
}

static void YTKACEAppTraitChanged(UIViewController *receiver,
                                  SEL selector,
                                  UITraitCollection *previous) {
    if (OriginalAppTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalAppTraitChanged)(receiver, selector, previous);
    }
    if (previous != nil &&
        ![receiver.traitCollection
            hasDifferentColorAppearanceComparedToTraitCollection:previous]) return;
    if (!YTKACEFeatureEnabled(YTKACEOLEDKey)) return;
    [receiver setNeedsStatusBarAppearanceUpdate];
    [receiver.view setNeedsLayout];
    YTKACERefreshNavigationAppearance();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                YTKACERefreshStatusBars(window.rootViewController);
                [window setNeedsLayout];
            }
        }
        YTKACERefreshNavigationAppearance();
    });
}

static void YTKACEInstallColorHook(NSString *className,
                                   NSString *selectorName,
                                   BOOL classMethod) {
    IMP original = NULL;
    BOOL installed = classMethod
        ? YTKACEInstallClassHook(className,
                                selectorName,
                                (IMP)YTKACEOLEDColor,
                                &original)
        : YTKACEInstallInstanceHook(className,
                                   selectorName,
                                   (IMP)YTKACEOLEDColor,
                                   &original);
    if (!installed || original == NULL) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     classMethod ? @"+" : @"-",
                     className,
                     selectorName];
    if (YTKACEOLEDOriginals[key] == nil) {
        YTKACEOLEDOriginals[key] = YTKACEOLEDValue(original);
    }
}

static void YTKACECollectQualityLabels(UIView *view,
                                       NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text ?: @"";
        NSRegularExpression *pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^\\s*\\d{3,4}p(?:60)?" options:0 error:nil];
        if ([text localizedCaseInsensitiveContainsString:@"quality"] ||
            [pattern firstMatchInString:text options:0
                range:NSMakeRange(0, text.length)] != nil) {
            [labels addObject:label];
        }
    }
    for (UIView *child in view.subviews) {
        YTKACECollectQualityLabels(child, labels);
    }
}

static UIView *YTKACECommonAncestor(NSArray<UIView *> *views, UIView *limit) {
    UIView *candidate = views.firstObject;
    while (candidate != nil && candidate != limit.superview) {
        BOOL containsAll = YES;
        for (UIView *view in views) {
            if (view != candidate && ![view isDescendantOfView:candidate]) {
                containsAll = NO;
                break;
            }
        }
        if (containsAll) return candidate;
        candidate = candidate.superview;
    }
    return nil;
}

static void YTKACEBlackenQualitySurface(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effect = (UIVisualEffectView *)view;
        effect.effect = nil;
        effect.contentView.backgroundColor = UIColor.blackColor;
    }
    UIColor *background = view.backgroundColor;
    CGFloat alpha = background == nil ? 0.0 : CGColorGetAlpha(background.CGColor);
    if (alpha > 0.01 || [view isKindOfClass:UITableView.class] ||
        [view isKindOfClass:UICollectionView.class]) {
        view.backgroundColor = UIColor.blackColor;
    }
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = UIColor.whiteColor;
    }
    for (UIView *child in view.subviews) {
        YTKACEBlackenQualitySurface(child);
    }
}

static void YTKACEQualitySheetDidAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalQualitySheetDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalQualitySheetDidAppear)(
            receiver, selector, animated);
    }
    if (![receiver isKindOfClass:UIViewController.class] ||
        !YTKACEOLEDActive(((UIViewController *)receiver).traitCollection)) return;
    if (YTKACELiquidGlassAvailable() && YTKACEFeatureEnabled(@"YTKACE.Preference.Glass.Menus")) return;
    UIView *root = ((UIViewController *)receiver).view;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        YTKACECollectQualityLabels(root, labels);
        NSUInteger qualityRows = 0;
        for (UILabel *label in labels) {
            if ([label.text rangeOfString:@"p"].location != NSNotFound) qualityRows++;
        }
        if (qualityRows < 2) return;
        UIView *surface = YTKACECommonAncestor(labels, root);
        if (surface == nil || surface == root) {
            for (UIView *child in root.subviews) {
                NSUInteger count = 0;
                for (UILabel *label in labels) {
                    if ([label isDescendantOfView:child]) count++;
                }
                if (count == labels.count) {
                    surface = child;
                    break;
                }
            }
        }
        if (surface != nil && surface != root) {
            surface.backgroundColor = UIColor.blackColor;
            YTKACEBlackenQualitySurface(surface);
        }
    });
}

void YTKACEInstallOLEDHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEOLEDOriginals = [NSMutableDictionary dictionary];
    });

    for (NSString *selector in @[@"black0", @"black1", @"black2", @"black3", @"black4"]) {
        YTKACEInstallColorHook(@"YTColor", selector, YES);
    }

    NSArray<NSString *> *paletteSelectors = @[
        @"baseBackground",
        @"brandBackgroundPrimary",
        @"brandBackgroundSecondary",
        @"brandBackgroundSolid",
        @"brandSurfaceContainer",
        @"brandSurfaceContainerHigh",
        @"brandSurfaceContainerHighest",
        @"raisedBackground",
        @"staticBrandBlack",
        @"generalBackgroundA",
        @"generalBackgroundB",
        @"generalBackgroundC",
        @"menuBackground",
        @"dialogBackgroundColor",
        @"elevatedBackgroundColor"
    ];
    for (NSString *selector in paletteSelectors) {
        YTKACEInstallColorHook(@"YTCommonColorPalette", selector, NO);
        YTKACEInstallColorHook(@"YTCommonColorPalette", selector, YES);
    }

    YTKACEInstallInstanceHook(@"YTActionSheetDialogViewController",
                              @"viewDidAppear:",
                              (IMP)YTKACEQualitySheetDidAppear,
                              &OriginalQualitySheetDidAppear);
    YTKACEInstallInstanceHook(@"YTAppViewController",
                              @"traitCollectionDidChange:",
                              (IMP)YTKACEAppTraitChanged,
                              &OriginalAppTraitChanged);
    YTKACEInstallInstanceHook(@"YTAppViewController",
                              @"preferredStatusBarStyle",
                              (IMP)YTKACEAppStatusBarStyle,
                              &OriginalAppStatusBarStyle);

}
