#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTKACEVOTState) {
    YTKACEVOTStateDisabled = 0,
    YTKACEVOTStateIdle = 1,
    YTKACEVOTStateLoading = 2,
    YTKACEVOTStatePlaying = 3,
    YTKACEVOTStatePaused = 4,
    YTKACEVOTStateError = 5
};

FOUNDATION_EXPORT NSString * const YTKACEVOTStateDidChangeNotification;

@interface YTKACEVOTCoordinator : NSObject

+ (instancetype)sharedCoordinator;

@property (nonatomic, readonly) YTKACEVOTState currentState;
@property (nonatomic, copy, readonly, nullable) NSString *currentVideoID;
@property (nonatomic, assign, readonly) double currentVideoDuration;
@property (nonatomic, copy, readonly, nullable) NSString *statusMessage;

@property (nonatomic, weak, nullable) UIButton *overlayButton;
@property (nonatomic, assign) BOOL lastVideoWasPlaying;
@property (nonatomic, assign) float lastPlaybackRate;
@property (nonatomic, assign) NSTimeInterval lastPlaybackTime;

- (void)videoDidActivateWithID:(NSString *)videoID duration:(double)duration player:(id _Nullable)player;
- (void)videoDidActivateWithID:(NSString *)videoID duration:(double)duration player:(id _Nullable)player playbackController:(id _Nullable)playbackController singleVideo:(id _Nullable)singleVideo;
- (void)videoPlaybackStateDidChangeIsPlaying:(BOOL)isPlaying rate:(float)rate time:(NSTimeInterval)time;
- (void)videoMediaStateDidChangeFromState:(NSInteger)fromState toState:(NSInteger)toState stoppageReason:(int)reason;
- (void)videoPlaybackRateDidChange:(float)rate;
- (void)videoDidSeekToTime:(NSTimeInterval)time;
- (void)videoDidDeactivate;

- (void)toggleTranslation;
- (void)startTranslation;
- (void)stopTranslation;
- (void)updateOverlayButton;

@end

NS_ASSUME_NONNULL_END
