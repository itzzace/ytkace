// An app's own tab bar mirrored into the iPhone Duo's system vertical tab bar,
// and optionally into the system's floating bottom tab bar where the Duo shows
// no vertical bar (unfolded portrait).
//
// iOS 27.1 draws a UITabBarController's tabs in the Duo's vertical bar: a glass
// column beside the status items that expands with labels when held or dragged.
// Apps that draw their own tab bar (Plex 8.45's standalone UITabBar, YouTube's
// floating pivot bar) get none of that. DUOMirroredTabBar hosts a real
// UITabBarController with the same tabs on the window's root view controller.
// Its pages are empty and transparent and its view passes touches through
// except on the system's tab buttons, so only the system's tab bar is visible
// and touchable. Choosing a tab calls the app's handler, which presses the
// app's own tab, so the app's navigation runs unchanged.
//
// Patterns from Plex Reborn (PlexDuoTabBar.m) and YTKACE (DuoTabBar.mm); see
// docs/duo-playbook/tab-bar-on-vertical-bar.md.
#import "DuoKit.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const CGFloat DUOTabIconSide = 24;

@implementation DUOMirroredTab

+ (instancetype)tabWithTitle:(NSString *)title image:(UIImage *)image selectedImage:(UIImage *)selectedImage {
    DUOMirroredTab *tab = [self new];
    tab.title = title ?: @"";
    tab.image = image;
    tab.selectedImage = selectedImage;
    return tab;
}

@end

#pragma mark - Icons

// The system tints tab images; apps draw theirs in their own colors and at
// slightly different sizes, and the vertical bar draws them at natural size.
// Redraw each once as a template in the same square, cached on the source.
static UIImage *DUOSquareTemplate(UIImage *image) {
    if (image == nil) return nil;
    static const void *cacheKey = &cacheKey;
    UIImage *cached = objc_getAssociatedObject(image, cacheKey);
    if (cached) return cached;
    CGSize box = CGSizeMake(DUOTabIconSide, DUOTabIconSide);
    CGFloat scale = MIN(box.width / MAX(image.size.width, 1), box.height / MAX(image.size.height, 1));
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:box];
    UIImage *result = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((box.width - drawn.width) / 2, (box.height - drawn.height) / 2,
                                     drawn.width, drawn.height)];
    }];
    result = [result imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    objc_setAssociatedObject(image, cacheKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

#pragma mark - Pass-through host view

// The tab bar controller covers the whole screen; touches anywhere except its
// tab buttons must reach the app underneath. The full-screen floating bar
// container around the tabs must pass touches through too, or it swallows taps
// on other vertical bar buttons.
static UIView *DUOPassThroughHitTest(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    struct objc_super parent = { self, class_getSuperclass(object_getClass(self)) };
    UIView *hit = ((UIView *(*)(struct objc_super *, SEL, CGPoint, UIEvent *))objc_msgSendSuper)(
        &parent, _cmd, point, event);
    for (UIView *view = hit; view != nil && view != self; view = view.superview) {
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"FloatingBarContainer"] || [name containsString:@"FloatingBarHosting"]) return nil;
        if ([name containsString:@"TabButton"] || [name containsString:@"TabBarItemPlatter"] ||
            [name containsString:@"TabBarExpansion"] || [view isKindOfClass:UITabBar.class]) {
            return hit;
        }
    }
    return nil;
}

static void DUOMakePassThrough(UIView *view) {
    NSString *name = [@"DUOPassThrough_" stringByAppendingString:NSStringFromClass(view.class)];
    Class subclass = NSClassFromString(name);
    if (subclass == Nil) {
        subclass = objc_allocateClassPair(view.class, name.UTF8String, 0);
        Method method = class_getInstanceMethod(UIView.class, @selector(hitTest:withEvent:));
        class_addMethod(subclass, @selector(hitTest:withEvent:), (IMP)DUOPassThroughHitTest,
                        method_getTypeEncoding(method));
        objc_registerClassPair(subclass);
    }
    object_setClass(view, subclass);
}

// The system places the vertical tab bar inside its host's safe area. On the
// unfolded screen the window does not reserve the bar's column (it reports a
// top inset instead), so the tabs would sit flush against the screen edge.
static void DUOReserveColumn(UIViewController *host, UIWindow *window, NSInteger edge) {
    UIEdgeInsets windowSafe = window.safeAreaInsets;
    UIEdgeInsets extra = UIEdgeInsetsZero;
    if (edge == 2) extra.right = MAX(0, DUOVerticalBarColumnWidth - windowSafe.right);
    if (edge == 1) extra.left = MAX(0, DUOVerticalBarColumnWidth - windowSafe.left);
    if (!UIEdgeInsetsEqualToEdgeInsets(host.additionalSafeAreaInsets, extra)) host.additionalSafeAreaInsets = extra;
}

#pragma mark - Mirrored tab bar

@interface DUOMirroredTabBar () <UITabBarControllerDelegate>
@property (nonatomic, strong) UITabBarController *controller;
@property (nonatomic, copy) void (^selectHandler)(NSUInteger index);
@property (nonatomic, copy) NSArray<NSString *> *titles;
@end

@implementation DUOMirroredTabBar

- (instancetype)initWithSelectHandler:(void (^)(NSUInteger))selectHandler {
    if ((self = [super init])) {
        _selectHandler = [selectHandler copy];
        _controller = [UITabBarController new];
        _controller.delegate = self;
        self.tintColor = UIColor.labelColor;
    }
    return self;
}

- (void)setTintColor:(UIColor *)tintColor {
    _tintColor = tintColor;
    // The vertical bar draws the tabs in the controller's view, outside its
    // tabBar, so the view needs the tint too.
    self.controller.tabBar.tintColor = tintColor;
    self.controller.view.tintColor = tintColor;
}

- (BOOL)showing {
    return self.controller.parentViewController != nil && !self.controller.view.hidden;
}

- (UIView *)hostView {
    return self.controller.viewIfLoaded;
}

- (BOOL)showTabs:(NSArray<DUOMirroredTab *> *)tabs selectedIndex:(NSUInteger)selectedIndex inWindow:(UIWindow *)window {
    NSInteger edge = DUOVerticalBarEdge(window);
    UIViewController *root = window.rootViewController;
    if ((edge == 0 && !self.showsBottomBar) || root == nil || tabs.count == 0) {
        [self hide];
        return NO;
    }
    UITabBarController *controller = self.controller;
    if (controller.parentViewController != root) {
        [controller willMoveToParentViewController:nil];
        [controller.view removeFromSuperview];
        [controller removeFromParentViewController];
        [root addChildViewController:controller];
        controller.view.backgroundColor = UIColor.clearColor;
        DUOMakePassThrough(controller.view);
        [root.view addSubview:controller.view];
        [controller didMoveToParentViewController:root];
    }

    NSArray<NSString *> *titles = [tabs valueForKey:@"title"];
    if (![titles isEqualToArray:self.titles]) {
        self.titles = titles;
        NSMutableArray *pages = [NSMutableArray array];
        for (__unused NSString *title in titles) {
            UIViewController *page = [UIViewController new];
            page.view.backgroundColor = UIColor.clearColor;
            page.view.userInteractionEnabled = NO;
            [pages addObject:page];
        }
        controller.viewControllers = pages;
    }
    NSArray<UIViewController *> *pages = controller.viewControllers;
    for (NSUInteger index = 0; index < pages.count && index < tabs.count; index++) {
        DUOMirroredTab *tab = tabs[index];
        UITabBarItem *item = pages[index].tabBarItem;
        UIImage *image = DUOSquareTemplate(tab.image ?: tab.selectedImage);
        UIImage *selected = DUOSquareTemplate(tab.selectedImage ?: tab.image);
        if (![item.title isEqualToString:tab.title]) item.title = tab.title;
        if (item.image != image) item.image = image;
        if (item.selectedImage != selected) item.selectedImage = selected;
        item.accessibilityLabel = tab.accessibilityLabel ?: tab.title;
    }
    if (selectedIndex < pages.count && controller.selectedIndex != selectedIndex) {
        controller.selectedIndex = selectedIndex;
    }

    controller.view.hidden = NO;
    DUOReserveColumn(controller, window, edge);
    if (!CGRectEqualToRect(controller.view.frame, root.view.bounds)) controller.view.frame = root.view.bounds;
    if (root.view.subviews.lastObject != controller.view) [root.view bringSubviewToFront:controller.view];
    return YES;
}

- (void)hide {
    if (self.controller.isViewLoaded) self.controller.view.hidden = YES;
}

- (void)tabBarController:(UITabBarController *)tabBarController
    didSelectViewController:(UIViewController *)viewController {
    NSUInteger index = [tabBarController.viewControllers indexOfObject:viewController];
    if (index != NSNotFound && self.selectHandler) self.selectHandler(index);
}

@end

#pragma mark - Covering the app's own bar

static NSString *const DUOCoverMaskName = @"DUOMirroredTabBarCover";

void DUOSetViewCovered(UIView *view, BOOL covered) {
    BOOL current = [view.layer.mask.name isEqualToString:DUOCoverMaskName];
    if (covered == current) return;
    if (covered) {
        CALayer *mask = [CALayer layer];
        mask.name = DUOCoverMaskName;
        view.layer.mask = mask;
        view.userInteractionEnabled = NO;
    } else {
        view.layer.mask = nil;
        view.userInteractionEnabled = YES;
    }
}
