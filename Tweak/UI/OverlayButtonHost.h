#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEOverlayConfigurator)(UIView *overlay, UIStackView *stack);

FOUNDATION_EXPORT void YTKACERegisterOverlayConfigurator(
    NSString *identifier,
    YTKACEOverlayConfigurator configurator
);

FOUNDATION_EXPORT UIButton *YTKACEOverlayButton(
    UIStackView *stack,
    NSString *identifier,
    NSString *symbolName,
    id target,
    SEL action
);

// A button's size changed (a new title): lay its row out again so the room
// made for it in YouTube's bars fits.
FOUNDATION_EXPORT void YTKACEOverlayButtonResized(UIButton *_Nullable button);
FOUNDATION_EXPORT void YTKACEFullscreenBarDidLayout(UIView *actions);

FOUNDATION_EXPORT void YTKACEPresentNativeSheet(
    NSString *_Nullable title,
    NSString *_Nullable subtitle,
    UIView *_Nullable sourceView,
    NSArray<NSDictionary *> *actions
);

FOUNDATION_EXPORT id _Nullable YTKACEMakeSheet(NSString *_Nullable title, NSString *_Nullable subtitle);

FOUNDATION_EXPORT BOOL YTKACEShowSheet(id _Nullable sheet, UIViewController *_Nullable presenter);

NS_ASSUME_NONNULL_END
