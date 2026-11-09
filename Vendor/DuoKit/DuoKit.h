// DuoKit: reusable patches that make older iPhone apps behave natively on
// current iPhones, with the iPhone Duo's layouts first. See toolkit/README.md.
//
// Each module is opt-in: the app's add-on calls the install function it needs,
// once, from its own constructor. Nothing installs itself.
#import <UIKit/UIKit.h>

// Functions are FOUNDATION_EXPORT (extern "C" in C++) so Objective-C++ callers,
// such as Theos tweaks written in .mm files, link against them.

NS_ASSUME_NONNULL_BEGIN

// Width of the Duo's vertical bar column: 12 pt padding, 48 pt bar, 24 pt to
// the screen edge. The folded screen reserves it as a safe-area inset; the
// unfolded screen does not.
static const CGFloat DUOVerticalBarColumnWidth = 84;

// Which edge the Duo's vertical bar is on for this window: 0 none, 1 left,
// 2 right (UITraitCollection.verticalBarEdge, iOS 27.1). 0 on every other iPhone.
FOUNDATION_EXPORT NSInteger DUOVerticalBarEdge(UIWindow *_Nullable window);

// The vertical bar's layout region on `edge` (UIRectEdgeLeft or Right) as
// insets of `view`: where bar items and tabs go. Its top inset is where the
// status items above it end. Measured: folded portrait {174, 394, 34, 24} in a
// 466 x 678 view; unfolded landscape {124, 879, 34, 24} in 951 x 669.
// Returns NO before iOS 27.1.
FOUNDATION_EXPORT BOOL DUOVerticalBarRegionInsets(UIView *view, UIRectEdge edge, UIEdgeInsets *_Nullable insets);

// For a screen that puts nothing in the vertical bar: the safe area reserves
// the bar's whole column, but only the status items at its top use it. A list
// whose top (in `view` coordinates) is below them may run into the column; this
// returns how far its right edge must stay from the view's (24 pt), or 0 when
// the list should keep to the safe area. Pair it with the list's
// insetsLayoutMarginsFromSafeArea = NO, or its rows still stop at the safe area.
FOUNDATION_EXPORT CGFloat DUOListTrailingInsetBesideVerticalBar(UIView *view, CGFloat listTop);

// The area the status items (camera, clock, Wi-Fi, Live Activities) take at
// the top of the Duo's vertical bar column, in `view`'s coordinates, or
// CGRectNull without a vertical bar. While the status bar is hidden only the
// camera is left, so the area shrinks (174 to 82 pt measured folded); callers
// that hide the status bar should remember the area from while it showed.
FOUNDATION_EXPORT CGRect DUOStatusItemsFrame(UIView *_Nullable view);

#pragma mark - Desk (laptop) posture

// The crease's frame in `view`'s coordinates while the Duo is half open with
// the crease running across the screen (desk or laptop posture), else
// CGRectNull (flat, closed, book posture, or no hinge). Video players put the
// picture above it and the controls below it.
FOUNDATION_EXPORT CGRect DUODeskPostureFold(UIView *_Nullable view);

// Folding without rotating leaves a view's size unchanged, so layout would not
// re-run. Adds a hinge listener (once) that asks `view` and its superview for
// layout whenever the posture changes.
FOUNDATION_EXPORT void DUOObserveHinge(UIView *_Nullable view);

// Whether a hinge listener added with DUOObserveHinge has heard from a hinge:
// YES on an iPhone Duo once the first update has arrived in this or an earlier
// launch (the listener's view re-runs layout then), NO before that and on every
// other iPhone. A flat Duo
// reports no crease region, so this is how to tell it from other iPhones.
FOUNDATION_EXPORT BOOL DUOHasHinge(void);

// Whether this is an iPhone Duo, from the model identifier (iPhone19,4) or a
// hinge seen on an earlier launch. Cached after the first call.
FOUNDATION_EXPORT BOOL DUOIsDuo(void);

// Fills `host` below the crease with a live, mirrored, blurred and darkened
// copy of `source` (the video's view), behind the controls, the way Netflix
// fills the lower half. Pass CGRectNull for `fold` to hide it. Call from the
// host's layout. Uses UIKit's private _UIPortalView; does nothing without it.
FOUNDATION_EXPORT void DUOUpdateDeskReflection(UIView *_Nullable host, UIView *_Nullable source, CGRect fold);

// One tab of an app's own tab bar, as the system's vertical tab bar shows it.
// Images may be any size or color; they are redrawn as same-size templates.
// An app that swaps in a filled icon for the selected tab passes both.
@interface DUOMirroredTab : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, strong, nullable) UIImage *selectedImage;
@property (nonatomic, copy, nullable) NSString *accessibilityLabel;
+ (instancetype)tabWithTitle:(NSString *)title image:(nullable UIImage *)image selectedImage:(nullable UIImage *)selectedImage;
@end

// Mirrors an app's own tab bar into the Duo's system vertical tab bar, which
// expands with labels when held. The app keeps its own bar and navigation: call
// showTabs: whenever its bar lays out or its selection changes, and press the
// app's own tab in the select handler. Without a vertical bar, showTabs: hides
// the mirror and returns NO, and the app's bar should show as usual, unless
// showsBottomBar is set.
@interface DUOMirroredTabBar : NSObject
- (instancetype)initWithSelectHandler:(void (^)(NSUInteger index))selectHandler;
// Shows these tabs in `window`'s vertical bar, hosted on its root view
// controller. Returns NO (and hides) when the window has no vertical bar.
- (BOOL)showTabs:(NSArray<DUOMirroredTab *> *)tabs selectedIndex:(NSUInteger)selectedIndex inWindow:(UIWindow *)window;
- (void)hide;
@property (nonatomic, readonly) BOOL showing;
// The view the system tabs are drawn in, for apps that need to measure them.
@property (nonatomic, readonly, nullable) UIView *hostView;
// Without a vertical bar (iPhone Duo unfolded portrait), show the system's
// floating bottom tab bar instead of hiding, so the app's tabs look and behave
// the same in every pose. Default NO: showTabs: then hides and returns NO.
@property (nonatomic) BOOL showsBottomBar;
// Selected tab color. Default labelColor, the way most apps mark the selected tab.
@property (nonatomic, strong) UIColor *tintColor;
@end

// Whether the app means `view` to be on screen: in a window, not hidden or
// transparent anywhere up its superview chain, and at least half inside the
// window. Apps hide bars in each of these ways; YouTube slides its tab column
// past the screen edge on the watch page without changing alpha or hidden.
FOUNDATION_EXPORT BOOL DUOViewShowing(UIView *_Nullable view);

// Hides an app's own bar while the mirror shows, without touching its alpha or
// hidden state, which apps use to show and hide their bar: an empty layer mask
// and no touches. Read the bar's alpha and hidden to learn whether the app
// wants it on screen, and hide the mirror when it does not.
FOUNDATION_EXPORT void DUOSetViewCovered(UIView *view, BOOL covered);

NS_ASSUME_NONNULL_END
