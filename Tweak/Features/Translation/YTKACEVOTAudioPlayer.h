#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YTKACEVOTAudioPlayerDelegate <NSObject>
@optional
- (void)votAudioPlayerDidReachEnd;
- (void)votAudioPlayerDidFailWithError:(NSError *)error;
@end

@interface YTKACEVOTAudioPlayer : NSObject

+ (instancetype)sharedPlayer;

@property (nonatomic, weak, nullable) id<YTKACEVOTAudioPlayerDelegate> delegate;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, assign) float targetRate;
@property (nonatomic, assign) float translationVolume; // 0.0 .. 1.0
@property (nonatomic, assign) float backgroundVolume;  // 0.0 .. 1.0
@property (nonatomic, assign) BOOL adaptiveDuckingEnabled;

- (void)loadURL:(NSURL *)audioURL initialTime:(NSTimeInterval)time rate:(float)rate autoPlay:(BOOL)autoPlay;
- (void)loadAndPlayURL:(NSURL *)audioURL initialTime:(NSTimeInterval)time rate:(float)rate;
- (void)playAtRate:(float)rate;
- (void)setTargetPlaybackRate:(float)rate;
- (void)pause;
- (void)stop;
- (void)seekToTime:(NSTimeInterval)time;
- (void)synchronizeWithVideoTime:(NSTimeInterval)videoTime rate:(float)rate isPlaying:(BOOL)videoIsPlaying;

// Video player ducking
- (void)attachYouTubePlayer:(id _Nullable)player;
- (void)attachYouTubePlayer:(id _Nullable)player playbackController:(id _Nullable)playbackController singleVideo:(id _Nullable)singleVideo;
- (void)detachYouTubePlayer;

@end

NS_ASSUME_NONNULL_END
