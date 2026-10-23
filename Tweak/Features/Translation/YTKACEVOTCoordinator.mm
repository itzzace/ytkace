#import <objc/message.h>
#import "YTKACEVOTCoordinator.h"
#import "YTKACEVOTClient.h"
#import "YTKACEVOTAudioPlayer.h"
#import "YTKACEVOTLog.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "../../UI/Assets.h"
#import "../../YTKACE.h"

NSString * const YTKACEVOTStateDidChangeNotification = @"YTKACEVOTStateDidChangeNotification";

static NSString * const kYTKACEVOTEnabledKey = @"YTKACE.Preference.VOT.Enabled";
static NSString * const kYTKACEVOTAutoTranslateKey = @"YTKACE.Preference.VOT.AutoTranslate";
static NSString * const kYTKACEVOTTargetLangKey = @"YTKACE.Preference.VOT.TargetLanguage";
static NSString * const kYTKACEVOTBgVolumeKey = @"YTKACE.Preference.VOT.BackgroundVolume";
static NSString * const kYTKACEVOTTransVolumeKey = @"YTKACE.Preference.VOT.TranslationVolume";
static NSString * const kYTKACEVOTAdaptiveVolumeKey = @"YTKACE.Preference.VOT.AdaptiveVolume";

@interface YTKACEVOTCoordinator () <YTKACEVOTAudioPlayerDelegate>
@property (nonatomic, assign) YTKACEVOTState currentState;
@property (nonatomic, copy, nullable) NSString *currentVideoID;
@property (nonatomic, assign) double currentVideoDuration;
@property (nonatomic, copy, nullable) NSString *statusMessage;
@property (nonatomic, strong, nullable) NSTimer *retryTimer;
@end

@implementation YTKACEVOTCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACEVOTCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[YTKACEVOTCoordinator alloc] init];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentState = YTKACEVOTStateIdle;
        _lastPlaybackRate = 1.0f;
        YTKACEVOTAudioPlayer.sharedPlayer.delegate = self;
        [self reloadPreferences];

        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(handlePreferencesChanged)
                                                   name:YTKACEPreferencesDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)handlePreferencesChanged {
    [self reloadPreferences];
    [self updateOverlayButton];
}

- (void)reloadPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    float bgVal = [defaults objectForKey:kYTKACEVOTBgVolumeKey] ? [defaults floatForKey:kYTKACEVOTBgVolumeKey] : 20.0f;
    float transVal = [defaults objectForKey:kYTKACEVOTTransVolumeKey] ? [defaults floatForKey:kYTKACEVOTTransVolumeKey] : 100.0f;

    if (bgVal > 0.0f && bgVal <= 1.0f) {
        bgVal *= 100.0f;
        [defaults setFloat:bgVal forKey:kYTKACEVOTBgVolumeKey];
    }
    if (transVal > 0.0f && transVal <= 1.0f) {
        transVal *= 100.0f;
        [defaults setFloat:transVal forKey:kYTKACEVOTTransVolumeKey];
    }

    float bgVol = bgVal / 100.0f;
    float transVol = transVal / 100.0f;

    BOOL adaptive = [defaults objectForKey:kYTKACEVOTAdaptiveVolumeKey] ? [defaults boolForKey:kYTKACEVOTAdaptiveVolumeKey] : YES;

    YTKACEVOTAudioPlayer.sharedPlayer.backgroundVolume = bgVol;
    YTKACEVOTAudioPlayer.sharedPlayer.translationVolume = transVol;
    YTKACEVOTAudioPlayer.sharedPlayer.adaptiveDuckingEnabled = adaptive;
}

- (void)setState:(YTKACEVOTState)state {
    _currentState = state;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayButton];
        [NSNotificationCenter.defaultCenter postNotificationName:YTKACEVOTStateDidChangeNotification object:self];
    });
}

#pragma mark - Video Lifecycle Events

- (void)videoDidActivateWithID:(NSString *)videoID duration:(double)duration player:(id _Nullable)player {
    [self videoDidActivateWithID:videoID duration:duration player:player playbackController:nil singleVideo:nil];
}

- (void)videoDidActivateWithID:(NSString *)videoID duration:(double)duration player:(id _Nullable)player playbackController:(id _Nullable)playbackController singleVideo:(id _Nullable)singleVideo {
    [self stopTranslation];
    [self.retryTimer invalidate];
    self.retryTimer = nil;

    YTKACEVOTLog(@"Coordinator", @"videoDidActivateWithID: %@, duration=%.1fs, player=%@", videoID, duration, player ? NSStringFromClass([player class]) : @"nil");

    self.currentVideoID = videoID;
    self.currentVideoDuration = duration;

    double detectedTime = 0.0;
    NSArray *timeSources = @[player ?: [NSNull null], singleVideo ?: [NSNull null], playbackController ?: [NSNull null]];
    for (id obj in timeSources) {
        if (!obj || obj == [NSNull null]) continue;
        for (NSString *selName in @[@"currentVideoMediaTime", @"currentTime", @"mediaTime"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([obj respondsToSelector:sel]) {
                double t = ((double (*)(id, SEL))objc_msgSend)(obj, sel);
                if (isfinite(t) && t > 0.0) {
                    detectedTime = t;
                    break;
                }
            }
        }
        if (detectedTime > 0.0) break;
    }
    self.lastPlaybackTime = detectedTime;

    float detectedRate = 0.0f;
    if (singleVideo && [singleVideo respondsToSelector:NSSelectorFromString(@"playbackRate")]) {
        detectedRate = ((float (*)(id, SEL))objc_msgSend)(singleVideo, NSSelectorFromString(@"playbackRate"));
    } else if (playbackController && [playbackController respondsToSelector:NSSelectorFromString(@"currentPlaybackRate")]) {
        detectedRate = ((float (*)(id, SEL))objc_msgSend)(playbackController, NSSelectorFromString(@"currentPlaybackRate"));
    }
    if (detectedRate < 0.25f || detectedRate > 5.0f) {
        float saved = [NSUserDefaults.standardUserDefaults floatForKey:@"YTKACE.Preference.Player.SavedRate"];
        if (saved >= 0.25f && saved <= 5.0f) {
            detectedRate = saved;
        }
    }
    if (detectedRate >= 0.25f && detectedRate <= 5.0f) {
        self.lastPlaybackRate = detectedRate;
    } else if (self.lastPlaybackRate < 0.25f || self.lastPlaybackRate > 5.0f) {
        self.lastPlaybackRate = 1.0f;
    }

    [YTKACEVOTAudioPlayer.sharedPlayer attachYouTubePlayer:player playbackController:playbackController singleVideo:singleVideo];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults objectForKey:kYTKACEVOTEnabledKey] ? [defaults boolForKey:kYTKACEVOTEnabledKey] : YES;
    if (!enabled) {
        self.state = YTKACEVOTStateDisabled;
        return;
    }

    self.state = YTKACEVOTStateIdle;
    self.statusMessage = nil;

    BOOL autoTranslate = [defaults boolForKey:kYTKACEVOTAutoTranslateKey];
    if (autoTranslate && videoID.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([self.currentVideoID isEqualToString:videoID] && self.currentState == YTKACEVOTStateIdle) {
                [self startTranslation];
            }
        });
    }
}

- (void)videoPlaybackStateDidChangeIsPlaying:(BOOL)isPlaying rate:(float)rate time:(NSTimeInterval)time {
    self.lastVideoWasPlaying = isPlaying;
    self.lastPlaybackRate = rate > 0.0f ? rate : 1.0f;
    self.lastPlaybackTime = time;

    if (self.currentState == YTKACEVOTStatePlaying || self.currentState == YTKACEVOTStatePaused) {
        [YTKACEVOTAudioPlayer.sharedPlayer synchronizeWithVideoTime:time rate:self.lastPlaybackRate isPlaying:isPlaying];
        self.state = isPlaying ? YTKACEVOTStatePlaying : YTKACEVOTStatePaused;
    }
}

- (void)videoMediaStateDidChangeFromState:(NSInteger)fromState toState:(NSInteger)toState stoppageReason:(int)reason {
    YTKACEVOTLog(@"Coordinator", @"mediaStateDidChange: %ld -> %ld (reason: %d)", (long)fromState, (long)toState, reason);

    // YouTube YTSingleVideoMediaState: 3 = Playing
    if (toState == 3) {
        self.lastVideoWasPlaying = YES;
        if (self.currentState == YTKACEVOTStatePaused) {
            self.state = YTKACEVOTStatePlaying;
            [YTKACEVOTAudioPlayer.sharedPlayer playAtRate:self.lastPlaybackRate];
        }
    }
    // YouTube YTSingleVideoMediaState: 2 = Paused, 4 = Buffering, 5 = Seeking, 6 = Suspended
    else if (toState == 2 || toState == 4 || toState == 5 || toState == 6) {
        self.lastVideoWasPlaying = NO;
        if (self.currentState == YTKACEVOTStatePlaying) {
            self.state = YTKACEVOTStatePaused;
            [YTKACEVOTAudioPlayer.sharedPlayer pause];
        }
    }
    // YouTube YTSingleVideoMediaState: 1 = Ended / Unstarted
    else if (toState == 1) {
        self.lastVideoWasPlaying = NO;
        if (self.currentState == YTKACEVOTStatePlaying || self.currentState == YTKACEVOTStatePaused) {
            [self stopTranslation];
        }
    }
}

- (void)videoPlaybackRateDidChange:(float)rate {
    float safeRate = rate > 0.0f ? rate : 1.0f;
    YTKACEVOTLog(@"Coordinator", @"videoPlaybackRateDidChange: %.2f", safeRate);
    self.lastPlaybackRate = safeRate;
    [YTKACEVOTAudioPlayer.sharedPlayer setTargetPlaybackRate:safeRate];
}

- (void)videoDidSeekToTime:(NSTimeInterval)time {
    self.lastPlaybackTime = time;
    YTKACEVOTLog(@"Coordinator", @"videoDidSeekToTime: %.2fs", time);
    if (self.currentState == YTKACEVOTStatePlaying || self.currentState == YTKACEVOTStatePaused) {
        [YTKACEVOTAudioPlayer.sharedPlayer seekToTime:time];
    }
}

- (void)videoDidDeactivate {
    YTKACEVOTLog(@"Coordinator", @"videoDidDeactivate (was %@)", self.currentVideoID);
    [self.retryTimer invalidate];
    self.retryTimer = nil;
    [self stopTranslation];
    [YTKACEVOTAudioPlayer.sharedPlayer detachYouTubePlayer];
    self.currentVideoID = nil;
    self.state = YTKACEVOTStateIdle;
}

#pragma mark - Translation Actions

- (void)toggleTranslation {
    if (self.currentState == YTKACEVOTStatePlaying || self.currentState == YTKACEVOTStatePaused || self.currentState == YTKACEVOTStateLoading) {
        [self stopTranslation];
    } else {
        [self startTranslation];
    }
}

- (void)startTranslation {
    if (self.currentVideoID.length == 0) {
        self.currentVideoID = YTKACELastVideoID();
    }
    if (self.currentVideoID.length == 0) {
        YTKACEVOTLog(@"Coordinator", @"startTranslation called with no active video ID");
        YTKACEShowNotice(YTKACELocalized(@"No active video"));
        return;
    }

    [self.retryTimer invalidate];
    self.retryTimer = nil;

    self.state = YTKACEVOTStateLoading;
    self.statusMessage = YTKACELocalized(@"Translating...");
    YTKACEShowNotice(YTKACELocalized(@"Translating..."));

    NSString *videoID = self.currentVideoID;
    double duration = self.currentVideoDuration;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *targetLang = [defaults stringForKey:kYTKACEVOTTargetLangKey] ?: @"ru";
    NSString *voiceType = [defaults stringForKey:kYTKACEVOTVoiceTypeKey] ?: @"standard";

    YTKACEVOTLog(@"Coordinator", @"startTranslation: videoID=%@, duration=%.1fs, targetLang=%@, voiceType=%@", videoID, duration, targetLang, voiceType);

    [YTKACEVOTClient.sharedClient requestTranslationForVideoID:videoID
                                                      duration:duration
                                                    sourceLang:nil
                                                    targetLang:targetLang
                                                     voiceType:voiceType
                                                    completion:^(YTKACEVOTResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.currentVideoID isEqualToString:videoID]) {
                YTKACEVOTLog(@"Coordinator", @"Video changed during translation request (was %@, now %@)", videoID, self.currentVideoID);
                return; // Video changed
            }

            if (error != nil || response == nil) {
                self.state = YTKACEVOTStateError;
                self.statusMessage = error.localizedDescription ?: YTKACELocalized(@"Translation failed");
                YTKACEVOTLog(@"Coordinator", @"Translation request error: %@", self.statusMessage);
                YTKACEShowNotice(self.statusMessage);
                return;
            }

            YTKACEVOTLog(@"Coordinator", @"Translation status result: status=%ld, audioURL=%@, remTime=%ld, msg=%@", (long)response.status, response.audioURL ?: @"-", (long)response.remainingTime, response.message ?: @"-");

            if ((response.status == YTKACEVOTStatusFinished || response.status == YTKACEVOTStatusPartContent) && response.audioURL.length > 0) {
                NSURL *url = [NSURL URLWithString:response.audioURL];
                if (url != nil) {
                    self.statusMessage = YTKACELocalized(@"Translation ready");
                    YTKACEVOTLog(@"Coordinator", @"Loading audio URL (autoPlay=%d): %@", self.lastVideoWasPlaying, response.audioURL);
                    [YTKACEVOTAudioPlayer.sharedPlayer loadURL:url initialTime:self.lastPlaybackTime rate:self.lastPlaybackRate autoPlay:self.lastVideoWasPlaying];
                    self.state = self.lastVideoWasPlaying ? YTKACEVOTStatePlaying : YTKACEVOTStatePaused;
                    YTKACEShowNotice(YTKACELocalized(@"Voice-over active"));
                } else {
                    self.state = YTKACEVOTStateError;
                    self.statusMessage = YTKACELocalized(@"Invalid audio link");
                    YTKACEVOTLog(@"Coordinator", @"Invalid audio URL string: %@", response.audioURL);
                    YTKACEShowNotice(self.statusMessage);
                }
            } else if (response.status == YTKACEVOTStatusWaiting ||
                       response.status == YTKACEVOTStatusLongWaiting ||
                       response.status == YTKACEVOTStatusPartContent ||
                       response.status == YTKACEVOTStatusAudioRequested) {
                NSInteger waitSeconds = response.remainingTime > 0 ? response.remainingTime : 10;
                NSInteger pollInterval = MIN(MAX(waitSeconds, 3), 6);
                self.statusMessage = [NSString stringWithFormat:YTKACELocalized(@"Wait %ld sec..."), (long)waitSeconds];
                YTKACEVOTLog(@"Coordinator", @"Translation in progress (%ld sec remaining, next poll in %ld sec). Scheduling retry timer...", (long)waitSeconds, (long)pollInterval);
                YTKACEShowNotice(self.statusMessage);

                self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)pollInterval
                                                                   repeats:NO
                                                                     block:^(NSTimer * _Nonnull timer) {
                    (void)timer;
                    if ([self.currentVideoID isEqualToString:videoID]) {
                        YTKACEVOTLog(@"Coordinator", @"Retry timer fired for videoID=%@. Re-querying translation...", videoID);
                        [self startTranslation];
                    }
                }];
            } else if (response.status == YTKACEVOTStatusSessionRequired) {
                self.state = YTKACEVOTStateError;
                self.statusMessage = YTKACELocalized(@"Yandex account required for this video");
                YTKACEVOTLog(@"Coordinator", @"Translation requires Yandex session (status 7)");
                YTKACEShowNotice(self.statusMessage);
            } else {
                self.state = YTKACEVOTStateError;
                self.statusMessage = response.message.length > 0 ? response.message : YTKACELocalized(@"Translation unavailable");
                YTKACEVOTLog(@"Coordinator", @"Translation unavailable or failed: %@", self.statusMessage);
                YTKACEShowNotice(self.statusMessage);
            }
        });
    }];
}

- (void)stopTranslation {
    YTKACEVOTLog(@"Coordinator", @"stopTranslation called");
    [self.retryTimer invalidate];
    self.retryTimer = nil;
    [YTKACEVOTAudioPlayer.sharedPlayer stop];
    self.state = YTKACEVOTStateIdle;
    self.statusMessage = nil;
}

#pragma mark - YTKACEVOTAudioPlayerDelegate

- (void)votAudioPlayerDidReachEnd {
    self.state = YTKACEVOTStateIdle;
}

#pragma mark - UI Update

- (void)updateOverlayButton {
    UIButton *btn = self.overlayButton;
    if (btn == nil) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults objectForKey:kYTKACEVOTEnabledKey] ? [defaults boolForKey:kYTKACEVOTEnabledKey] : YES;
    NSInteger placement = [defaults integerForKey:@"YTKACE.Preference.VOT.Placement"]; // 0=overlay, 1=menu, 2=both

    if (!enabled || placement == 1) {
        btn.hidden = YES;
        return;
    }

    btn.hidden = NO;

    if (@available(iOS 13.0, *)) {
        switch (self.currentState) {
            case YTKACEVOTStateLoading:
                [btn setImage:[UIImage systemImageNamed:@"hourglass"] forState:UIControlStateNormal];
                [btn setTitle:nil forState:UIControlStateNormal];
                [btn setTintColor:UIColor.systemYellowColor];
                break;
            case YTKACEVOTStatePlaying:
            case YTKACEVOTStatePaused:
                [btn setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal];
                [btn setTitle:nil forState:UIControlStateNormal];
                [btn setTintColor:UIColor.systemGreenColor];
                break;
            default:
                [btn setImage:[UIImage systemImageNamed:@"waveform.badge.magnifyingglass"] forState:UIControlStateNormal];
                [btn setTitle:nil forState:UIControlStateNormal];
                [btn setTintColor:UIColor.whiteColor];
                break;
        }
    }
}

@end
