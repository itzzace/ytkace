// Minimal test doubles for running the production copy hooks on macOS.
// No real pasteboard is accessed. Production compilation uses the iOS SDK.
#import <Foundation/Foundation.h>

typedef NSString *UIActivityType;
FOUNDATION_EXPORT UIActivityType const UIActivityTypeCopyToPasteboard;
@interface UIActivityViewController : NSObject
@end
@protocol UIActivityItemSource <NSObject>
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller;
- (id)activityViewController:(UIActivityViewController *)controller
        itemForActivityType:(UIActivityType)activityType;
@end
@interface UIPasteboard : NSObject
+ (UIPasteboard *)generalPasteboard;
@property(nonatomic, copy) NSString *string;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) id lastValue;
@property(nonatomic) NSUInteger contentReads;
@end
