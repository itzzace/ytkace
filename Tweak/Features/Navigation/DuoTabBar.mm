// YouTube's tabs in the iPhone Duo's system vertical tab bar.
//
// On the Duo (iOS 27.1 and later) the system draws a tab bar controller's tabs
// in the vertical bar beside the status items: a glass column that expands
// with labels when held or dragged. YouTube's Duo layout draws its own floating
// column instead (YTFloatingPivotBarView), which has none of that behavior.
//
// While the vertical bar shows, YouTube's tabs are mirrored into the system bar
// with DuoKit's DUOMirroredTabBar (Vendor/DuoKit). Choosing a tab presses
// YouTube's own tab, so YouTube's navigation runs unchanged; YouTube's column
// stays laid out but is not drawn or touchable. Unfolded portrait has no
// vertical bar, so there the tabs go to the system's floating bottom tab bar.
// On other iPhones nothing changes.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

void YTKACESelectPivotItem(UIView *item);

NSString * const YTKACEDuoNativeTabBarKey = @"YTKACE.Preference.Tabs.DuoNativeBar";

// YTKACE draws some tabs' icons and labels in its own views, with YouTube's
// button image and title hidden or empty (TabBarHooks.mm): its own tab with
// the first pair of tags, and added tabs such as History with the second.
static const NSInteger YTKACETabIconTags[] = {0x59414345, 0x59414349};
static const NSInteger YTKACETabLabelTags[] = {0x59414347, 0x5941434A};

#pragma mark - Reading YouTube's tabs

static void YTKACECollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    for (UIView *subview in view.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTPivotBarItemView"]) {
            if (!subview.hidden && CGRectGetWidth(subview.bounds) > 0.0) [items addObject:subview];
            continue;
        }
        YTKACECollectItems(subview, items);
    }
}

static NSArray<UIView *> *YTKACEBarItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTKACECollectItems(bar, items);
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGRect fa = [a convertRect:a.bounds toView:bar];
        CGRect fb = [b convertRect:b.bounds toView:bar];
        if (fabs(CGRectGetMinY(fa) - CGRectGetMinY(fb)) > 1.0) {
            return CGRectGetMinY(fa) < CGRectGetMinY(fb) ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMinX(fa) < CGRectGetMinX(fb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

static UIButton *YTKACEItemButton(UIView *item) {
    SEL selector = NSSelectorFromString(@"navigationButton");
    id button = [item respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(item, selector) : nil;
    return [button isKindOfClass:UIButton.class] ? button : nil;
}

static NSString *YTKACEItemTitle(UIView *item) {
    for (NSInteger tag : YTKACETabLabelTags) {
        UILabel *custom = (UILabel *)[item viewWithTag:tag];
        if ([custom isKindOfClass:UILabel.class] && custom.text.length) return custom.text;
    }
    NSString *title = YTKACEItemButton(item).titleLabel.text;
    if (title.length) return title;
    for (UIView *subview in item.subviews) {
        if (subview.accessibilityLabel.length) return subview.accessibilityLabel;
    }
    return item.accessibilityLabel ?: @"";
}

static UIImage *YTKACEItemImage(UIView *item) {
    for (NSInteger tag : YTKACETabIconTags) {
        UIImageView *custom = (UIImageView *)[item viewWithTag:tag];
        if ([custom isKindOfClass:UIImageView.class] && !custom.hidden && custom.image) return custom.image;
    }
    UIButton *button = YTKACEItemButton(item);
    return button.imageView.image ?: button.currentImage;
}

static BOOL YTKACEItemSelected(UIView *item) {
    SEL selector = NSSelectorFromString(@"isSelected");
    if ([item respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(item, selector)) return YES;
    return (item.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
}

#pragma mark - Mirroring

static DUOMirroredTabBar *YTKACEDuoTabs;
static __weak UIView *YTKACEDuoBar;
static NSPointerArray *YTKACEDuoItems;
// YouTube shows a filled icon on the selected tab only, so each tab's outline
// and filled icons are remembered by title as they appear.
static NSMutableDictionary<NSString *, UIImage *> *YTKACEDuoIcons;
static NSMutableDictionary<NSString *, UIImage *> *YTKACEDuoSelectedIcons;

// With YTKACE's debug logs on, records each change in what one bar decided
// and why, so a case seen only on a phone can be read back from its log.
static void YTKACELogDuoDecision(UIView *bar, NSString *decision) {
    static NSMapTable<UIView *, NSString *> *last;
    if (last == nil) last = [NSMapTable weakToStrongObjectsMapTable];
    if ([[last objectForKey:bar] isEqualToString:decision]) return;
    [last setObject:decision forKey:bar];
    YTKACEDebugLog(@"duo-tabs", @"bar %p %@ frame=%@ window=%@ %@", bar, decision,
                   NSStringFromCGRect([bar convertRect:bar.bounds toView:nil]),
                   NSStringFromClass(bar.window.class), NSStringFromCGRect(bar.window.bounds));
}

static void YTKACEUpdateDuoTabs(UIView *bar) {
    BOOL enabled = YTKACEFeatureEnabled(YTKACEDuoNativeTabBarKey);
    BOOL showing = DUOViewShowing(bar);
    NSArray<UIView *> *items = enabled && showing ? YTKACEBarItems(bar) : @[];
    NSInteger edge = DUOVerticalBarEdge(bar.window);
    // Unfolded portrait has no vertical bar; on a Duo the system's floating
    // bottom tab bar takes YouTube's tabs there, so every pose has the same
    // bar. Other iPhones keep YouTube's own bar.
    DUOObserveHinge(bar);
    BOOL bottomBar = DUOIsDuo();
    if (items.count == 0 || (edge == 0 && !bottomBar)) {
        YTKACELogDuoDecision(bar, [NSString stringWithFormat:@"youtube column: enabled=%d showing=%d items=%lu edge=%ld alpha=%.2f hidden=%d",
                                   enabled, showing, (unsigned long)items.count, (long)edge, bar.alpha, bar.hidden]);
        if (YTKACEDuoBar == bar || YTKACEDuoBar == nil) [YTKACEDuoTabs hide];
        DUOSetViewCovered(bar, NO);
        return;
    }
    if (YTKACEDuoTabs == nil) {
        YTKACEDuoIcons = [NSMutableDictionary dictionary];
        YTKACEDuoSelectedIcons = [NSMutableDictionary dictionary];
        YTKACEDuoTabs = [[DUOMirroredTabBar alloc] initWithSelectHandler:^(NSUInteger index) {
            UIView *item = index < YTKACEDuoItems.count
                ? (__bridge UIView *)[YTKACEDuoItems pointerAtIndex:index] : nil;
            if (item != nil) YTKACESelectPivotItem(item);
        }];
    }
    YTKACEDuoBar = bar;
    YTKACEDuoItems = [NSPointerArray weakObjectsPointerArray];
    NSMutableArray<DUOMirroredTab *> *tabs = [NSMutableArray array];
    NSUInteger selectedIndex = NSNotFound;
    for (UIView *item in items) {
        NSString *title = YTKACEItemTitle(item);
        BOOL selected = YTKACEItemSelected(item);
        if (selected) selectedIndex = tabs.count;
        UIImage *image = YTKACEItemImage(item);
        if (image != nil) (selected ? YTKACEDuoSelectedIcons : YTKACEDuoIcons)[title] = image;
        [tabs addObject:[DUOMirroredTab tabWithTitle:title
                                               image:YTKACEDuoIcons[title]
                                       selectedImage:YTKACEDuoSelectedIcons[title]]];
        [YTKACEDuoItems addPointer:(__bridge void *)item];
    }
    YTKACEDuoTabs.showsBottomBar = bottomBar;
    BOOL shown = [YTKACEDuoTabs showTabs:tabs selectedIndex:selectedIndex inWindow:bar.window];
    YTKACELogDuoDecision(bar, [NSString stringWithFormat:@"%@: %lu tabs, edge=%ld",
                               shown ? @"system bar" : @"youtube column (system bar refused)",
                               (unsigned long)tabs.count, (long)edge]);
    DUOSetViewCovered(bar, shown);
}

// Layout runs often; update once per run loop turn.
static void YTKACEScheduleDuoTabs(UIView *bar) {
    static NSHashTable<UIView *> *pending;
    if (pending == nil) pending = [NSHashTable weakObjectsHashTable];
    if ([pending containsObject:bar]) return;
    [pending addObject:bar];
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (strongBar == nil) return;
        [pending removeObject:strongBar];
        YTKACEUpdateDuoTabs(strongBar);
    });
}

static UIView *YTKACEFloatingBarAncestor(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) isEqualToString:@"YTFloatingPivotBarView"]) return current;
    }
    return nil;
}

#pragma mark - Hooks

static IMP YTKACEOrigFloatingLayout;
static IMP YTKACEOrigFloatingMoveToWindow;

static void YTKACEFloatingLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTKACEOrigFloatingLayout)(self, _cmd);
    YTKACEScheduleDuoTabs(self);
}

static void YTKACEFloatingMoveToWindow(UIView *self, SEL _cmd) {
    if (YTKACEOrigFloatingMoveToWindow) ((void (*)(id, SEL))YTKACEOrigFloatingMoveToWindow)(self, _cmd);
    YTKACEScheduleDuoTabs(self);
}

// Called from TabBarHooks.mm's setSelected: hook (a method is hooked once).
void YTKACEDuoTabsSelectionChanged(UIView *item) {
    if (!DUOIsDuo()) return;
    UIView *bar = YTKACEFloatingBarAncestor(item);
    if (bar != nil) YTKACEScheduleDuoTabs(bar);
}

void YTKACEInstallDuoTabBarHooks(void) {
    if (!DUOIsDuo()) return;
    if (NSClassFromString(@"YTFloatingPivotBarView") == Nil) return;
    YTKACEInstallInstanceHook(@"YTFloatingPivotBarView", @"layoutSubviews",
                              (IMP)YTKACEFloatingLayout, &YTKACEOrigFloatingLayout);
    YTKACEInstallInstanceHook(@"YTFloatingPivotBarView", @"didMoveToWindow",
                              (IMP)YTKACEFloatingMoveToWindow, &YTKACEOrigFloatingMoveToWindow);
}
