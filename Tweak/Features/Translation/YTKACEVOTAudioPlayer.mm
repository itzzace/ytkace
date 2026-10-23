#import "YTKACEVOTAudioPlayer.h"
#import "YTKACEVOTLog.h"
#import <objc/message.h>
#import <math.h>

typedef struct {
    NSTimeInterval start;
    NSTimeInterval end;
} YTKACESpeechInterval;

@interface YTKACEVOTAudioPlayer ()
@property (nonatomic, strong, nullable) AVPlayer *audioPlayer;
@property (nonatomic, weak, nullable) id ytPlayer;
@property (nonatomic, weak, nullable) id playbackController;
@property (nonatomic, weak, nullable) id singleVideo;
@property (nonatomic, assign) BOOL isDucked;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, assign) float originalVideoVolume;
@property (nonatomic, assign) BOOL hasOriginalVolume;
@property (nonatomic, assign) NSTimeInterval lastSyncCheck;
@property (nonatomic, assign) NSTimeInterval lastObservedVideoTime;
@property (nonatomic, assign) NSTimeInterval lastObservedWallTime;

// Adaptive volume speech intervals and ramping
@property (nonatomic, strong, nullable) NSArray<NSValue *> *speechIntervals;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *speechDownloadTask;
@property (nonatomic, assign) float currentDuckedVolume;
@property (nonatomic, strong, nullable) dispatch_source_t duckRampTimer;

// Pending initial playback state
@property (nonatomic, assign) NSTimeInterval pendingInitialTime;
@property (nonatomic, assign) BOOL pendingAutoPlay;
@property (nonatomic, assign) BOOL isObservingItemStatus;
@property (nonatomic, weak, nullable) AVPlayerItem *observedItem;
@end

@implementation YTKACEVOTAudioPlayer

+ (instancetype)sharedPlayer {
    static YTKACEVOTAudioPlayer *player;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        player = [[YTKACEVOTAudioPlayer alloc] init];
    });
    return player;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _translationVolume = 1.0f;
        _backgroundVolume = 0.20f;
        _originalVideoVolume = 1.0f;
        _hasOriginalVolume = NO;
        _isDucked = NO;
        _adaptiveDuckingEnabled = YES;
        _currentDuckedVolume = 1.0f;
    }
    return self;
}

- (BOOL)isPlaying {
    if (self.audioPlayer == nil) return NO;
    return self.audioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying ||
           (self.audioPlayer.rate > 0.0f && self.audioPlayer.timeControlStatus != AVPlayerTimeControlStatusPaused);
}

- (void)loadURL:(NSURL *)audioURL initialTime:(NSTimeInterval)time rate:(float)rate autoPlay:(BOOL)autoPlay {
    [self stop];

    float safeRate = rate > 0.0f ? rate : 1.0f;
    self.targetRate = safeRate;

    YTKACEVOTLog(@"Player", @"loadURL: %@ (initialTime=%.2fs, rate=%.2f, autoPlay=%d, volume=%.1f%%, adaptiveDucking=%d)", audioURL.absoluteString, time, safeRate, autoPlay, self.translationVolume * 100.0f, self.adaptiveDuckingEnabled);

    // 1. Instant stream via AVPlayer
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:audioURL];
    self.audioPlayer = [AVPlayer playerWithPlayerItem:item];
    self.audioPlayer.volume = self.translationVolume;
    self.audioPlayer.automaticallyWaitsToMinimizeStalling = YES;

    // Observe completion
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];

    if (item.status == AVPlayerItemStatusReadyToPlay) {
        if (time > 0.0) {
            [self seekToTime:time];
            if (autoPlay) {
                [self playAtRate:self.targetRate];
            }
        } else if (autoPlay) {
            [self playAtRate:self.targetRate];
        }
    } else {
        self.pendingInitialTime = time;
        self.pendingAutoPlay = autoPlay;
        if (time > 0.0) {
            self.isSeeking = YES;
        }
        [self addStatusObserverForItem:item];
    }

    // 2. Scan speech intervals asynchronously in background for smart ducking
    if (self.adaptiveDuckingEnabled) {
        [self startBackgroundSpeechScanForURL:audioURL];
    }
}

- (void)addStatusObserverForItem:(AVPlayerItem *)item {
    [self removeStatusObserver];
    if (item == nil) return;
    self.observedItem = item;
    self.isObservingItemStatus = YES;
    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew
              context:nil];
}

- (void)removeStatusObserver {
    if (self.isObservingItemStatus && self.observedItem != nil) {
        @try {
            [self.observedItem removeObserver:self forKeyPath:@"status"];
        } @catch (NSException *e) {
            (void)e;
        }
        self.isObservingItemStatus = NO;
        self.observedItem = nil;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"status"] && [object isKindOfClass:[AVPlayerItem class]]) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        AVPlayerItemStatus status = item.status;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handlePlayerItemStatusChange:status item:item];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)handlePlayerItemStatusChange:(AVPlayerItemStatus)status item:(AVPlayerItem *)item {
    if (self.observedItem != item || self.audioPlayer.currentItem != item) {
        return;
    }

    if (status == AVPlayerItemStatusReadyToPlay) {
        YTKACEVOTLog(@"Player", @"AVPlayerItem became ReadyToPlay");
        [self removeStatusObserver];

        NSTimeInterval initialTime = self.pendingInitialTime;
        BOOL shouldAutoPlay = self.pendingAutoPlay;
        self.pendingInitialTime = 0.0;
        self.pendingAutoPlay = NO;

        NSTimeInterval freshTime = [self currentVideoMediaTime];
        NSTimeInterval targetSeekTime = (freshTime > 0.0) ? freshTime : initialTime;

        if (targetSeekTime > 0.0) {
            self.isSeeking = YES;
            CMTime targetTime = CMTimeMakeWithSeconds(targetSeekTime, NSEC_PER_SEC);
            CMTime tolerance = CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC);
            __weak __typeof__(self) weakSelf = self;
            [self.audioPlayer seekToTime:targetTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
                (void)finished;
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (strongSelf) {
                    strongSelf.isSeeking = NO;
                    strongSelf.lastSyncCheck = [[NSDate date] timeIntervalSince1970] + 0.6;
                    if (shouldAutoPlay) {
                        [strongSelf playAtRate:strongSelf.targetRate];
                    }
                }
            }];
        } else if (shouldAutoPlay) {
            self.isSeeking = NO;
            self.lastSyncCheck = [[NSDate date] timeIntervalSince1970] + 0.6;
            [self playAtRate:self.targetRate];
        }
    } else if (status == AVPlayerItemStatusFailed) {
        YTKACEVOTLog(@"Player", @"AVPlayerItem failed with error: %@", item.error.localizedDescription);
        [self removeStatusObserver];
        self.isSeeking = NO;
        self.pendingInitialTime = 0.0;
        self.pendingAutoPlay = NO;
    }
}

- (void)loadAndPlayURL:(NSURL *)audioURL initialTime:(NSTimeInterval)time rate:(float)rate {
    [self loadURL:audioURL initialTime:time rate:rate autoPlay:YES];
}

- (void)startBackgroundSpeechScanForURL:(NSURL *)audioURL {
    __weak __typeof__(self) weakSelf = self;
    self.speechDownloadTask = [NSURLSession.sharedSession downloadTaskWithURL:audioURL completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        (void)response;
        if (error != nil || location == nil) {
            YTKACEVOTLog(@"Player", @"Speech scan download task failed: %@", error.localizedDescription);
            return;
        }

        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vot_speech_%@.mp3", [[NSUUID UUID] UUIDString]]];
        NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
        NSError *moveError = nil;
        [NSFileManager.defaultManager moveItemAtURL:location toURL:tempURL error:&moveError];
        if (moveError != nil) {
            return;
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf parseSpeechIntervalsFromAudioFile:tempURL];
            }
            [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        });
    }];
    [self.speechDownloadTask resume];
}

- (void)parseSpeechIntervalsFromAudioFile:(NSURL *)fileURL {
    @autoreleasepool {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
        NSError *error = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        if (error != nil || reader == nil) {
            YTKACEVOTLog(@"Player", @"AVAssetReader init failed: %@", error.localizedDescription);
            return;
        }

        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count == 0) return;
        AVAssetTrack *track = tracks.firstObject;

        NSDictionary *outputSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO
        };

        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:outputSettings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return;
        [reader addOutput:output];

        if (![reader startReading]) {
            YTKACEVOTLog(@"Player", @"AVAssetReader startReading failed");
            return;
        }

        NSMutableArray<NSValue *> *intervals = [NSMutableArray array];
        BOOL inSpeech = NO;
        NSTimeInterval speechStart = 0.0;
        NSTimeInterval lastSpeechEnd = 0.0;

        // Speech threshold for 16-bit PCM: ~350 out of 32767 (-39 dBFS)
        const int16_t kSpeechThreshold = 350;
        const NSTimeInterval kMinSilenceToSplit = 0.45; // Group pauses < 450ms as continuous speech

        while (reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
            if (sampleBuffer == NULL) break;

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
            NSTimeInterval chunkStart = CMTimeGetSeconds(pts);
            NSTimeInterval chunkEnd = chunkStart + CMTimeGetSeconds(dur);

            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
            if (blockBuffer != NULL) {
                size_t length = 0;
                char *dataPointer = NULL;
                if (CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &length, &dataPointer) == noErr && dataPointer != NULL) {
                    const int16_t *samples = (const int16_t *)dataPointer;
                    size_t sampleCount = length / sizeof(int16_t);
                    BOOL chunkHasSpeech = NO;

                    // Stride by 8 samples for high throughput
                    for (size_t i = 0; i < sampleCount; i += 8) {
                        int16_t s = samples[i];
                        if (s > kSpeechThreshold || s < -kSpeechThreshold) {
                            chunkHasSpeech = YES;
                            break;
                        }
                    }

                    if (chunkHasSpeech) {
                        if (!inSpeech) {
                            if (intervals.count > 0 && (chunkStart - lastSpeechEnd) < kMinSilenceToSplit) {
                                NSValue *lastVal = intervals.lastObject;
                                YTKACESpeechInterval prev;
                                [lastVal getValue:&prev];
                                speechStart = prev.start;
                                [intervals removeLastObject];
                            } else {
                                speechStart = chunkStart;
                            }
                            inSpeech = YES;
                        }
                        lastSpeechEnd = chunkEnd;
                    } else {
                        if (inSpeech) {
                            if (chunkEnd - lastSpeechEnd >= kMinSilenceToSplit) {
                                YTKACESpeechInterval interval = { speechStart, lastSpeechEnd };
                                [intervals addObject:[NSValue valueWithBytes:&interval objCType:@encode(YTKACESpeechInterval)]];
                                inSpeech = NO;
                            }
                        }
                    }
                }
            }
            CFRelease(sampleBuffer);
        }

        if (inSpeech) {
            YTKACESpeechInterval interval = { speechStart, lastSpeechEnd };
            [intervals addObject:[NSValue valueWithBytes:&interval objCType:@encode(YTKACESpeechInterval)]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.speechIntervals = [NSArray arrayWithArray:intervals];
            YTKACEVOTLog(@"Player", @"Parsed %lu speech intervals for adaptive volume", (unsigned long)intervals.count);
        });
    }
}

- (BOOL)isSpeechActiveAtTime:(NSTimeInterval)time {
    if (self.speechIntervals == nil || self.speechIntervals.count == 0) {
        // While loading or if file has no intervals yet, stay ducked
        return YES;
    }

    for (NSValue *val in self.speechIntervals) {
        YTKACESpeechInterval interval;
        [val getValue:&interval];
        // 100ms lookahead and 300ms hold-over
        if (time >= (interval.start - 0.1) && time <= (interval.end + 0.3)) {
            return YES;
        }
        if (interval.start > (time + 1.0)) {
            break;
        }
    }
    return NO;
}

- (void)startDuckingRampTimer {
    if (self.duckRampTimer != nil) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    self.duckRampTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(self.duckRampTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.04 * NSEC_PER_SEC), (uint64_t)(0.01 * NSEC_PER_SEC));

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(self.duckRampTimer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf updateDuckedVolumeTick];
        }
    });
    dispatch_resume(self.duckRampTimer);
}

- (void)stopDuckingRampTimer {
    if (self.duckRampTimer != nil) {
        dispatch_source_cancel(self.duckRampTimer);
        self.duckRampTimer = nil;
    }
}

- (void)updateDuckedVolumeTick {
    if (!self.isDucked || !self.isPlaying || self.audioPlayer == nil) {
        return;
    }

    float targetVolume;
    if (self.adaptiveDuckingEnabled) {
        NSTimeInterval currentTime = CMTimeGetSeconds(self.audioPlayer.currentTime);
        BOOL isSpeaking = [self isSpeechActiveAtTime:currentTime];
        targetVolume = isSpeaking ? self.backgroundVolume : self.originalVideoVolume;
    } else {
        targetVolume = self.backgroundVolume;
    }

    float current = self.currentDuckedVolume;
    float diff = targetVolume - current;

    if (fabsf(diff) > 0.015f) {
        current += diff * 0.22f;
        self.currentDuckedVolume = current;
        [self setVideoPlayerVolume:current];
    } else if (current != targetVolume) {
        self.currentDuckedVolume = targetVolume;
        [self setVideoPlayerVolume:targetVolume];
    }
}

- (void)setTargetPlaybackRate:(float)rate {
    float safeRate = rate > 0.0f ? rate : 1.0f;
    self.targetRate = safeRate;
    YTKACEVOTLog(@"Player", @"setTargetPlaybackRate: %.2f", safeRate);

    // Reset rate measurement baseline & grant grace period for YouTube clock stabilization
    self.lastObservedWallTime = 0.0;
    self.lastObservedVideoTime = 0.0;
    self.lastSyncCheck = [[NSDate date] timeIntervalSince1970] + 0.6;

    if (self.isPlaying) {
        self.audioPlayer.rate = safeRate;
    }
}

- (void)playAtRate:(float)rate {
    if (self.audioPlayer == nil) return;
    float safeRate = rate > 0.0f ? rate : (self.targetRate > 0.0f ? self.targetRate : 1.0f);
    self.targetRate = safeRate;
    YTKACEVOTLog(@"Player", @"playAtRate: %.2f", safeRate);
    self.audioPlayer.rate = safeRate;
    [self applyDucking:YES];
}

- (void)pause {
    if (self.audioPlayer == nil) return;
    YTKACEVOTLog(@"Player", @"pause");
    [self.audioPlayer pause];
    [self applyDucking:NO];
}

- (void)stop {
    [self removeStatusObserver];
    self.pendingInitialTime = 0.0;
    self.pendingAutoPlay = NO;
    [self stopDuckingRampTimer];
    if (self.speechDownloadTask != nil) {
        [self.speechDownloadTask cancel];
        self.speechDownloadTask = nil;
    }
    self.speechIntervals = nil;

    if (self.audioPlayer != nil) {
        YTKACEVOTLog(@"Player", @"stop");
        [self.audioPlayer pause];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:AVPlayerItemDidPlayToEndTimeNotification
                                                    object:self.audioPlayer.currentItem];
        [self.audioPlayer replaceCurrentItemWithPlayerItem:nil];
        self.audioPlayer = nil;
    }
    self.lastObservedWallTime = 0.0;
    self.lastObservedVideoTime = 0.0;
    self.isSeeking = NO;
    [self applyDucking:NO];
}

- (void)dealloc {
    [self stop];
}

- (void)seekToTime:(NSTimeInterval)time {
    if (self.audioPlayer == nil) return;
    if (self.audioPlayer.currentItem.status != AVPlayerItemStatusReadyToPlay) {
        self.pendingInitialTime = time;
        self.isSeeking = YES;
        YTKACEVOTLog(@"Player", @"seekToTime: %.2fs queued (item status not ReadyToPlay yet)", time);
        return;
    }
    self.isSeeking = YES;
    YTKACEVOTLog(@"Player", @"seekToTime: %.2fs", time);
    CMTime targetTime = CMTimeMakeWithSeconds(time, NSEC_PER_SEC);
    CMTime tolerance = CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC);
    __weak __typeof__(self) weakSelf = self;
    [self.audioPlayer seekToTime:targetTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        (void)finished;
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.isSeeking = NO;
            strongSelf.lastSyncCheck = [[NSDate date] timeIntervalSince1970] + 0.6;
        }
    }];
}

- (void)synchronizeWithVideoTime:(NSTimeInterval)videoTime rate:(float)rate isPlaying:(BOOL)videoIsPlaying {
    if (self.audioPlayer == nil) return;

    if (self.isSeeking) {
        return;
    }

    if (self.audioPlayer.currentItem == nil || self.audioPlayer.currentItem.status != AVPlayerItemStatusReadyToPlay) {
        return;
    }

    if (!videoIsPlaying) {
        if (self.isPlaying) {
            [self pause];
        }
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // Authoritative playback rate directly from YouTube player
    float baseRate = rate > 0.0f ? rate : (self.targetRate > 0.0f ? self.targetRate : 1.0f);
    if (fabsf(self.targetRate - baseRate) > 0.05f) {
        YTKACEVOTLog(@"Player", @"Playback rate synchronized to %.2f", baseRate);
        self.targetRate = baseRate;
        if (self.isPlaying) {
            self.audioPlayer.rate = baseRate;
        }
        self.lastSyncCheck = now + 0.6;
        return;
    }

    self.targetRate = baseRate;

    // Check if player is paused but video is playing
    if (!self.isPlaying && self.audioPlayer.timeControlStatus != AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
        [self playAtRate:baseRate];
        return;
    }

    if (now - self.lastSyncCheck < 0.4) {
        return;
    }
    self.lastSyncCheck = now;

    CMTime currentAudioCM = self.audioPlayer.currentTime;
    NSTimeInterval audioTime = CMTimeGetSeconds(currentAudioCM);
    if (!isfinite(audioTime) || !isfinite(videoTime)) {
        return;
    }

    NSTimeInterval drift = videoTime - audioTime; // positive means audio is behind video

    // 1. Large drift (> 4.5 sec) -> genuine user timeline scrub / jump
    if (fabs(drift) > 4.5) {
        YTKACEVOTLog(@"Player", @"Large scrub drift detected (%.2fs), seeking to %.2fs (rate=%.2f)", drift, videoTime, baseRate);
        [self seekToTime:videoTime];
        self.lastSyncCheck = now + 0.6;
        return;
    }

    // 2. Smooth Phase-Locked Loop (PLL) micro-adjustments without seeking or repeats
    if (drift > 0.06) {
        // Audio is slightly behind: accelerate up to +12%
        float factor = 1.0f + (float)fmin(drift * 0.04, 0.12);
        float adjustedRate = baseRate * factor;
        if (fabsf(self.audioPlayer.rate - adjustedRate) > 0.01f) {
            self.audioPlayer.rate = adjustedRate;
        }
    } else if (drift < -0.06) {
        // Audio is slightly ahead (e.g. video rebuffered): decelerate up to -12%
        float factor = 1.0f - (float)fmin(fabs(drift) * 0.04, 0.12);
        float adjustedRate = baseRate * factor;
        if (fabsf(self.audioPlayer.rate - adjustedRate) > 0.01f) {
            self.audioPlayer.rate = adjustedRate;
        }
    } else {
        // In tight sync: maintain exact baseRate
        if (fabsf(self.audioPlayer.rate - baseRate) > 0.01f) {
            self.audioPlayer.rate = baseRate;
        }
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)note {
    (void)note;
    [self stop];
    if ([self.delegate respondsToSelector:@selector(votAudioPlayerDidReachEnd)]) {
        [self.delegate votAudioPlayerDidReachEnd];
    }
}

#pragma mark - Ducking & Master Player Volume

- (void)attachYouTubePlayer:(id _Nullable)player {
    [self attachYouTubePlayer:player playbackController:nil singleVideo:nil];
}

- (void)attachYouTubePlayer:(id _Nullable)player playbackController:(id _Nullable)playbackController singleVideo:(id _Nullable)singleVideo {
    self.ytPlayer = player;
    self.playbackController = playbackController;
    self.singleVideo = singleVideo;
}

- (void)detachYouTubePlayer {
    [self applyDucking:NO];
    self.ytPlayer = nil;
    self.playbackController = nil;
    self.singleVideo = nil;
    self.hasOriginalVolume = NO;
}

- (void)setTranslationVolume:(float)volume {
    _translationVolume = volume;
    if (self.audioPlayer != nil) {
        self.audioPlayer.volume = volume;
    }
}

- (void)setBackgroundVolume:(float)volume {
    _backgroundVolume = volume;
    if (self.isDucked) {
        [self setVideoPlayerVolume:volume];
    }
}

- (void)applyDucking:(BOOL)duck {
    if (self.ytPlayer == nil && self.singleVideo == nil && self.playbackController == nil) return;
    if (self.isDucked == duck) return;
    self.isDucked = duck;

    if (duck) {
        if (!self.hasOriginalVolume) {
            self.originalVideoVolume = [self getVideoPlayerVolume];
            if (self.originalVideoVolume <= 0.0f) {
                self.originalVideoVolume = 1.0f;
            }
            self.hasOriginalVolume = YES;
        }
        self.currentDuckedVolume = [self getVideoPlayerVolume];
        [self startDuckingRampTimer];
    } else {
        [self stopDuckingRampTimer];
        float restoreVol = self.hasOriginalVolume ? self.originalVideoVolume : 1.0f;
        self.currentDuckedVolume = restoreVol;
        [self setVideoPlayerVolume:restoreVol];
    }
}

- (float)getVideoPlayerVolume {
    for (id target in @[self.singleVideo, self.playbackController, self.ytPlayer]) {
        if (target != nil && [target respondsToSelector:@selector(volume)]) {
            return ((float (*)(id, SEL))objc_msgSend)(target, @selector(volume));
        }
    }
    return 1.0f;
}

- (NSTimeInterval)currentVideoMediaTime {
    for (id target in @[self.singleVideo, self.playbackController, self.ytPlayer]) {
        if (target != nil) {
            for (NSString *sel in @[@"currentVideoMediaTime", @"currentTime", @"mediaTime"]) {
                SEL s = NSSelectorFromString(sel);
                if ([target respondsToSelector:s]) {
                    double t = ((double (*)(id, SEL))objc_msgSend)(target, s);
                    if (isfinite(t) && t > 0.0) {
                        return (NSTimeInterval)t;
                    }
                }
            }
        }
    }
    return 0.0;
}

- (void)setVideoPlayerVolume:(float)volume {
    for (id target in @[self.singleVideo, self.playbackController, self.ytPlayer]) {
        if (target != nil && [target respondsToSelector:@selector(setVolume:)]) {
            ((void (*)(id, SEL, float))objc_msgSend)(target, @selector(setVolume:), volume);
        }
    }
}

@end
