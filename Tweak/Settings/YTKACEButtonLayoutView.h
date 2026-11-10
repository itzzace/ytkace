#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Drag the player buttons between YouTube's top row, the row under it, the
// bottom bar, and a tray for hidden ones. Shown inline on the Player page.
@interface YTKACEButtonLayoutView : UIView
// Called after a button moves or the layout is reset.
@property(nonatomic, copy, nullable) void (^changeHandler)(void);
// Called when a toggle elsewhere changes the row's height.
@property(nonatomic, copy, nullable) void (^heightHandler)(void);
- (CGFloat)heightForWidth:(CGFloat)width;
@end

NS_ASSUME_NONNULL_END
