#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Drag the buttons under the video into order, or into a tray to hide them.
// Drawn like the bar this device gets: the iPhone row of icons next to
// Subscribe, or the row of chips with the like/dislike pill.
@interface YTKACEActionBarLayoutView : UIView
// Called after a button moves or the order is reset.
@property(nonatomic, copy, nullable) void (^changeHandler)(void);
// Called when the view's height changes.
@property(nonatomic, copy, nullable) void (^heightHandler)(void);
- (CGFloat)heightForWidth:(CGFloat)width;
@end

NS_ASSUME_NONNULL_END
