#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTKACESponsorCategoryDefinitions(void);
FOUNDATION_EXPORT NSString *YTKACESponsorBehaviorKey(NSString *category);
FOUNDATION_EXPORT NSString *YTKACESponsorColorKey(NSString *category);
FOUNDATION_EXPORT NSInteger YTKACESponsorCategoryBehavior(NSString *category);
FOUNDATION_EXPORT NSArray<NSString *> *YTKACESponsorEnabledCategories(void);
FOUNDATION_EXPORT UIColor *YTKACESponsorCategoryColor(NSString *category);
FOUNDATION_EXPORT NSInteger YTKACESponsorNotificationMode(void);
FOUNDATION_EXPORT NSTimeInterval YTKACESponsorSkipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval YTKACESponsorUnskipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval YTKACESponsorMinimumSegmentLength(void);

NS_ASSUME_NONNULL_END
