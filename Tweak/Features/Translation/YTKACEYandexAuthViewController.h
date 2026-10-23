#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEYandexAuthCompletion)(BOOL success, NSString * _Nullable login, NSString * _Nullable errorMessage);

@interface YTKACEYandexAuthViewController : UIViewController

@property (nonatomic, copy, nullable) YTKACEYandexAuthCompletion completion;

+ (void)presentFromViewController:(UIViewController *)viewController
                       completion:(nullable YTKACEYandexAuthCompletion)completion;

+ (void)openSafariAuth;

@end

NS_ASSUME_NONNULL_END
