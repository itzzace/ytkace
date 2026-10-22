#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIViewController *YTKACEMakeSettingsPage(NSString *pageID);
FOUNDATION_EXPORT NSArray<NSDictionary *> *YTKACESettingsMenu(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeVOTController(void);
FOUNDATION_EXPORT NSDictionary *YTKACEVOTDefinition(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakePlayerControlsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeSponsorBlockController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeTabBarOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeOverlayOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeStreamingOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeNavigationOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeShortsOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeGlassOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeMiscOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeGestureOptionsController(void);
FOUNDATION_EXPORT void YTKACEStartupDestinations(
    NSArray<NSString *> * _Nullable * _Nullable titles,
    NSArray<NSString *> * _Nullable * _Nullable values);
FOUNDATION_EXPORT UIViewController *YTKACEMakeStartupPickerController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeWiFiQualityController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeCellularQualityController(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeCreditsController(void);
FOUNDATION_EXPORT NSString *YTKACEPickerSummary(NSString *key,
                                                NSArray<NSString *> *titles,
                                                NSArray *values,
                                                NSUInteger defaultIndex);
FOUNDATION_EXPORT void YTKACEShowRestartNotice(UIViewController *controller);
FOUNDATION_EXPORT BOOL YTKACEPreferenceNeedsRestart(NSString *key);
typedef void (^YTKACEChoiceHandler)(NSUInteger index);
FOUNDATION_EXPORT void YTKACEPresentSelectionMenu(UIViewController *presenter,
                                                  UIView *sourceView,
                                                  NSString *title,
                                                  NSArray<NSString *> *titles,
                                                  NSUInteger selectedIndex,
                                                  YTKACEChoiceHandler handler);
FOUNDATION_EXPORT void YTKACEPresentChoiceMenu(UIViewController *presenter,
                                               UIView *sourceView,
                                               NSString *title,
                                               NSArray<NSString *> *titles,
                                               NSArray *values,
                                               NSString *key,
                                               NSUInteger defaultIndex,
                                               YTKACEChoiceHandler handler);

FOUNDATION_EXPORT NSArray<NSDictionary *> *YTKACEAllPageDefinitions(void);
FOUNDATION_EXPORT UIViewController *YTKACEMakeSettingsResultsController(
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);
FOUNDATION_EXPORT void YTKACEUpdateSettingsResultsController(
    UIViewController *controller,
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);

NS_ASSUME_NONNULL_END
