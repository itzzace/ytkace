#import "YTKACEDownloadPlayerController.h"
#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Hooking.h"
#import "MediaArtwork.h"
#import "DownloadSponsor.h"
#import "GlobalDownloadMiniPlayer.h"
#import "DownloadLog.h"
#import "../SponsorBlock/SponsorPreferences.h"
#import "../../Settings/YTKACESettingsPages.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

NSNotificationName const YTKACEDownloadPlaybackDidChangeNotification =
    @"YTKACEDownloadPlaybackDidChangeNotification";
NSNotificationName const YTKACEDownloadPlaybackDidStopNotification =
    @"YTKACEDownloadPlaybackDidStopNotification";
NSNotificationName const YTKACEDownloadSponsorDidSkipNotification =
    @"YTKACEDownloadSponsorDidSkipNotification";
NSNotificationName const YTKACEDownloadSponsorPromptNotification =
    @"YTKACEDownloadSponsorPromptNotification";
NSNotificationName const YTKACELibraryPiPDidChangeNotification =
    @"YTKACELibraryPiPDidChangeNotification";
NSNotificationName const YTKACELibraryFullPlayerWillShowNotification =
    @"YTKACELibraryFullPlayerWillShowNotification";
NSNotificationName const YTKACELibraryFullPlayerWillHideNotification =
    @"YTKACELibraryFullPlayerWillHideNotification";

static NSString *YTKACEPlayerTimeText(NSTimeInterval duration) {
    if (!isfinite(duration) || duration < 0.0) {
        return @"0:00";
    }
    NSInteger seconds = (NSInteger)floor(duration);
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    NSInteger remainder = seconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
            (long)hours, (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)minutes, (long)remainder];
}

@interface YTKACESubtitleCue : NSObject
@property(nonatomic, assign) NSTimeInterval start;
@property(nonatomic, assign) NSTimeInterval end;
@property(nonatomic, copy) NSString *text;
@end

@implementation YTKACESubtitleCue
@end

static NSTimeInterval YTKACESubtitleTime(NSString *value) {
    NSString *clean = [[value stringByReplacingOccurrencesOfString:@"," withString:@"."]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 +
            parts[2].doubleValue;
    }
    if (parts.count == 2) return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    return clean.doubleValue;
}

static NSArray<YTKACESubtitleCue *> *YTKACEReadSubtitles(NSURL *mediaURL) {
    NSURL *base = mediaURL.URLByDeletingPathExtension;
    NSURL *subtitleURL = nil;
    for (NSString *extension in @[@"srt", @"vtt"]) {
        NSURL *candidate = [base URLByAppendingPathExtension:extension];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path]) {
            subtitleURL = candidate;
            break;
        }
    }
    if (subtitleURL == nil) return @[];
    NSString *contents = [NSString stringWithContentsOfURL:subtitleURL
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (contents.length == 0) return @[];
    contents = [[contents stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSRegularExpression *blankLines = [NSRegularExpression
        regularExpressionWithPattern:@"\\n[ \\t]*\\n" options:0 error:nil];
    contents = [blankLines stringByReplacingMatchesInString:contents options:0
        range:NSMakeRange(0, contents.length) withTemplate:@"\n\n"];
    NSMutableArray<YTKACESubtitleCue *> *cues = [NSMutableArray array];
    for (NSString *block in [contents componentsSeparatedByString:@"\n\n"]) {
        NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
        NSUInteger timingIndex = NSNotFound;
        for (NSUInteger index = 0; index < lines.count; index++) {
            if ([lines[index] containsString:@"-->"]) {
                timingIndex = index;
                break;
            }
        }
        if (timingIndex == NSNotFound) continue;
        NSArray<NSString *> *times = [lines[timingIndex] componentsSeparatedByString:@"-->"];
        if (times.count != 2) continue;
        NSArray<NSString *> *endParts = [times[1]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *endValue = nil;
        for (NSString *part in endParts) {
            if (part.length != 0) {
                endValue = part;
                break;
            }
        }
        NSMutableArray<NSString *> *textLines = [NSMutableArray array];
        for (NSUInteger index = timingIndex + 1; index < lines.count; index++) {
            NSString *line = [lines[index] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length != 0) [textLines addObject:line];
        }
        if (endValue.length == 0 || textLines.count == 0) continue;
        YTKACESubtitleCue *cue = [YTKACESubtitleCue new];
        cue.start = YTKACESubtitleTime(times[0]);
        cue.end = YTKACESubtitleTime(endValue);
        cue.text = [textLines componentsJoinedByString:@"\n"];
        if (cue.end > cue.start) [cues addObject:cue];
    }
    return cues;
}

@interface YTKACEDownloadPlaybackSession ()
@property(nonatomic, strong, readwrite) AVPlayer *player;
@property(nonatomic, strong) id resumeObserver;
@property(nonatomic, copy, readwrite, nullable) NSURL *currentURL;
@property(nonatomic, copy, readwrite) NSArray<NSURL *> *playlist;
@property(nonatomic, assign, readwrite) NSInteger currentIndex;
@property(nonatomic, assign) BOOL continueInBackground;
@property(nonatomic, strong) id sponsorObserver;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary<NSString *, id> *> *sponsorSegments;
@property(nonatomic, copy, readwrite, nullable) NSDictionary<NSString *, id> *promptedSegment;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *handledSegments;
@property(nonatomic, strong, nullable) NSArray *remoteTargets;
@end

@implementation YTKACEDownloadPlaybackSession

static YTKACEDownloadPlaybackSession *YTKACESharedPlaybackSession;

+ (instancetype)sharedSession {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACESharedPlaybackSession = [YTKACEDownloadPlaybackSession new];
    });
    return YTKACESharedPlaybackSession;
}

+ (instancetype)existingSession {
    return YTKACESharedPlaybackSession;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    self.player = [AVPlayer new];
    self.playlist = @[];
    self.sponsorSegments = @[];
    self.handledSegments = [NSMutableSet set];
    self.currentIndex = NSNotFound;
    self.autoplayEnabled = YES;
    self.gesturesEnabled = NO;
    self.repeatEnabled = NO;
    double defaultRate = YTKACEStartPlaybackRate();
    self.playbackRate = defaultRate >= 0.25 ? (float)defaultRate : 1.0f;
    self.player.allowsExternalPlayback = YES;
    self.player.appliesMediaSelectionCriteriaAutomatically = NO;
    if (@available(iOS 15.0, *)) {
        self.player.audiovisualBackgroundPlaybackPolicy =
            AVPlayerAudiovisualBackgroundPlaybackPolicyContinuesIfPossible;
    }
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(itemDidEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadInfoChanged:)
        name:YTKACEDownloadInfoDidChangeNotification object:nil];
    return self;
}

- (void)downloadInfoChanged:(NSNotification *)notification {
    NSURL *URL = notification.object;
    if (![URL isKindOfClass:NSURL.class] || self.currentURL == nil ||
        ![URL.path isEqualToString:self.currentURL.path]) {
        return;
    }
    NSArray *stored = YTKACEStoredSponsorSegments(self.currentURL);
    if ([stored isEqualToArray:self.sponsorSegments]) return;
    self.sponsorSegments = stored;
    [self.handledSegments removeAllObjects];
    [self notifyChange];
}

static NSString * const YTKACEResumeKey = @"YTKACE.Preference.Downloads.ResumePositions";

static NSString *YTKACEResumeIdentifier(NSURL *URL) {
    if (URL == nil) return @"";
    NSString *path = URL.URLByStandardizingPath.path;
    NSString *root = YTKACEApplicationSupportDirectory()
        .URLByStandardizingPath.path;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (path.length != 0 && [path hasPrefix:prefix]) {
        return [@"v2|" stringByAppendingString:
            [path substringFromIndex:prefix.length]];
    }
    NSString *identity = path.length != 0 ? path : URL.absoluteString;
    return [@"v2|external|" stringByAppendingString:identity ?: @""];
}

static NSString *YTKACELegacyResumeIdentifier(NSURL *URL) {
    NSString *name = URL.lastPathComponent;
    return name.length != 0 ? name : URL.absoluteString;
}

static void YTKACEWriteResumeTable(NSUserDefaults *defaults,
                                   NSDictionary *table) {
    [defaults setObject:table forKey:YTKACEResumeKey];
}

static NSDictionary *YTKACEValidatedResumeRecord(NSURL *URL,
                                                  double *legacyPosition) {
    if (legacyPosition != NULL) *legacyPosition = 0.0;
    if (URL == nil) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy];
    if (table == nil) return nil;
    NSString *identifier = YTKACEResumeIdentifier(URL);
    NSString *legacyIdentifier = YTKACELegacyResumeIdentifier(URL);
    NSString *sourceIdentifier = identifier;
    id value = table[identifier];
    if (value == nil && legacyIdentifier.length != 0) {
        sourceIdentifier = legacyIdentifier;
        value = table[legacyIdentifier];
    }
    if (value == nil) return nil;

    if (![value isKindOfClass:NSDictionary.class]) {
        double position = [value respondsToSelector:@selector(doubleValue)]
            ? [value doubleValue] : NAN;
        if (!isfinite(position) || position <= 0.0) {
            [table removeObjectForKey:sourceIdentifier];
            YTKACEWriteResumeTable(defaults, table);
            return nil;
        }
        if (legacyPosition != NULL) *legacyPosition = position;
        return nil;
    }

    NSDictionary *record = (NSDictionary *)value;
    id positionValue = record[@"t"];
    id durationValue = record[@"d"];
    if (![positionValue respondsToSelector:@selector(doubleValue)] ||
        ![durationValue respondsToSelector:@selector(doubleValue)]) {
        [table removeObjectForKey:sourceIdentifier];
        YTKACEWriteResumeTable(defaults, table);
        return nil;
    }
    double position = [positionValue doubleValue];
    double duration = [durationValue doubleValue];
    BOOL completed = [record[@"c"] respondsToSelector:@selector(boolValue)] &&
        [record[@"c"] boolValue];
    BOOL valid = isfinite(position) && isfinite(duration) &&
        duration > 0.0 && position >= 0.0 && position <= duration &&
        (completed || position > 0.0);
    if (!valid) {
        [table removeObjectForKey:sourceIdentifier];
        YTKACEWriteResumeTable(defaults, table);
        return nil;
    }

    NSDictionary *normalized = @{
        @"t": @(completed ? 0.0 : position),
        @"d": @(duration),
        @"c": @(completed),
        @"v": @2
    };
    if (![sourceIdentifier isEqualToString:identifier] ||
        ![normalized isEqualToDictionary:record]) {
        [table removeObjectForKey:sourceIdentifier];
        if (legacyIdentifier.length != 0 &&
            ![legacyIdentifier isEqualToString:identifier]) {
            [table removeObjectForKey:legacyIdentifier];
        }
        table[identifier] = normalized;
        YTKACEWriteResumeTable(defaults, table);
    }
    return normalized;
}

static NSTimeInterval YTKACEStoredResume(NSURL *URL) {
    double legacyPosition = 0.0;
    NSDictionary *record =
        YTKACEValidatedResumeRecord(URL, &legacyPosition);
    if (record == nil) return legacyPosition;
    if ([record[@"c"] boolValue]) return 0.0;
    double position = [record[@"t"] doubleValue];
    return isfinite(position) && position > 0.0 ? position : 0.0;
}

CGFloat YTKACEDownloadProgressRatio(NSURL *URL) {
    NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
    if (record == nil) return 0.0;
    if ([record[@"c"] boolValue]) return 1.0;
    double position = [record[@"t"] doubleValue];
    double duration = [record[@"d"] doubleValue];
    if (!isfinite(position) || !isfinite(duration) || duration <= 0.0 ||
        position < 0.0 || position > duration) return 0.0;
    double ratio = position / duration;
    if (!isfinite(ratio)) return 0.0;
    return (CGFloat)MAX(0.0, MIN(1.0, ratio));
}

static void YTKACEStoreResume(NSURL *URL, NSTimeInterval seconds,
                              NSTimeInterval duration, BOOL completed) {
    if (URL == nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    NSString *identifier = YTKACEResumeIdentifier(URL);
    NSString *legacyIdentifier = YTKACELegacyResumeIdentifier(URL);
    if (legacyIdentifier.length != 0 &&
        ![legacyIdentifier isEqualToString:identifier]) {
        [table removeObjectForKey:legacyIdentifier];
    }
    BOOL validDuration = isfinite(duration) && duration > 0.0;
    BOOL validPosition = isfinite(seconds) && seconds >= 0.0 &&
        validDuration && seconds <= duration;
    if (!validDuration || (!completed && (!validPosition || seconds <= 0.0))) {
        [table removeObjectForKey:identifier];
    } else {
        table[identifier] = @{
            @"t": @(completed ? 0.0 : seconds),
            @"d": @(duration),
            @"c": @(completed),
            @"v": @2
        };
        if (table.count > 300) {
            NSArray *keys = table.allKeys;
            for (NSUInteger i = 0; i + 200 < keys.count; i++) {
                [table removeObjectForKey:keys[i]];
            }
        }
    }
    YTKACEWriteResumeTable(defaults, table);
}

static void YTKACERemoveResume(NSURL *URL) {
    if (URL == nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy];
    if (table == nil) return;
    [table removeObjectForKey:YTKACEResumeIdentifier(URL)];
    [table removeObjectForKey:YTKACELegacyResumeIdentifier(URL)];
    YTKACEWriteResumeTable(defaults, table);
}

static BOOL YTKACEStoredResumeIsCompleted(NSURL *URL) {
    NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
    return [record[@"c"] boolValue];
}

static void YTKACEStoreCompleted(NSURL *URL, NSTimeInterval duration,
                                 NSTimeInterval fallbackDuration) {
    NSTimeInterval total = duration;
    if (!isfinite(total) || total <= 0.0) total = fallbackDuration;
    if (!isfinite(total) || total <= 0.0) {
        NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
        total = [record[@"d"] doubleValue];
    }
    if (isfinite(total) && total > 0.0) {
        YTKACEStoreResume(URL, 0.0, total, YES);
    }
}

- (void)rememberPosition {
    AVPlayerItem *item = self.player.currentItem;
    if (self.currentURL == nil || item == nil) return;
    NSTimeInterval position = CMTimeGetSeconds(item.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(position) || position < 0.0) return;
    if (!isfinite(duration) || duration <= 0.0 || position > duration) {
        return;
    }
    if (position < 5.0) {
        if (!YTKACEStoredResumeIsCompleted(self.currentURL)) {
            YTKACERemoveResume(self.currentURL);
        }
        return;
    }
    if (position >= MAX(0.0, duration - 10.0)) {
        YTKACEStoreCompleted(self.currentURL, duration, position);
        return;
    }
    YTKACEStoreResume(self.currentURL, position, duration, NO);
}

- (void)configureAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeMoviePlayback
                 options:0 error:nil];
    [session setActive:YES error:nil];
}

- (void)configureRemoteCommands {
    if (self.remoteTargets != nil) return;
    [UIApplication.sharedApplication beginReceivingRemoteControlEvents];
    MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
    __weak YTKACEDownloadPlaybackSession *weakSelf = self;
    NSMutableArray *targets = [NSMutableArray array];
    void (^add)(MPRemoteCommand *, void (^)(YTKACEDownloadPlaybackSession *)) =
        ^(MPRemoteCommand *command, void (^action)(YTKACEDownloadPlaybackSession *)) {
        id target = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            YTKACEDownloadPlaybackSession *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.currentURL == nil) {
                return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
            }
            action(strongSelf);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [targets addObject:@[command, target]];
    };
    add(commands.playCommand, ^(YTKACEDownloadPlaybackSession *session) { [session play]; });
    add(commands.pauseCommand, ^(YTKACEDownloadPlaybackSession *session) { [session pause]; });
    add(commands.togglePlayPauseCommand, ^(YTKACEDownloadPlaybackSession *session) { [session togglePlayback]; });
    add(commands.nextTrackCommand, ^(YTKACEDownloadPlaybackSession *session) { [session playNext]; });
    add(commands.previousTrackCommand, ^(YTKACEDownloadPlaybackSession *session) { [session playPrevious]; });
    self.remoteTargets = targets;
    YTKACEDownloadLog(@"library", @"remote commands attached");
}

- (void)releaseRemoteCommands {
    if (self.remoteTargets == nil) return;
    for (NSArray *pair in self.remoteTargets) [(MPRemoteCommand *)pair[0] removeTarget:pair[1]];
    self.remoteTargets = nil;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    YTKACEDownloadLog(@"library", @"remote commands released");
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    self.continueInBackground = self.player.rate != 0.0f;
    [self rememberPosition];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    if (!self.continueInBackground || self.currentURL == nil) return;
    [self configureAudioSession];
    [self.player play];
    self.player.rate = self.playbackRate;
    [self updateNowPlayingInfo];
}

- (void)dealloc {
    [self rememberPosition];
    if (self.resumeObserver != nil) {
        [self.player removeTimeObserver:self.resumeObserver];
        self.resumeObserver = nil;
    }
    if (self.sponsorObserver != nil) {
        [self.player removeTimeObserver:self.sponsorObserver];
        self.sponsorObserver = nil;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)loadURL:(NSURL *)URL
       playlist:(NSArray<NSURL *> *)playlist
          index:(NSInteger)index {
    self.playlist = playlist ?: @[];
    self.currentIndex = index;
    if (URL == nil) {
        return;
    }
    if (![self.currentURL isEqual:URL]) {
        [self rememberPosition];
        self.currentURL = URL;
        [self.player replaceCurrentItemWithPlayerItem:
            [AVPlayerItem playerItemWithURL:URL]];
        [self loadSponsorSegmentsForURL:URL];
        NSTimeInterval resume = YTKACEStoredResume(URL);
        if (resume > 0.0) {
            [self.player seekToTime:CMTimeMakeWithSeconds(resume, 600)
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];
        }
    }
    [self play];
    [self notifyChange];
}

- (void)updatePlaylist:(NSArray<NSURL *> *)playlist {
    self.playlist = playlist ?: @[];
    NSUInteger index = self.currentURL == nil
        ? NSNotFound : [self.playlist indexOfObject:self.currentURL];
    self.currentIndex = index == NSNotFound ? NSNotFound : (NSInteger)index;
    [self notifyChange];
}

- (void)loadSponsorSegmentsForURL:(NSURL *)URL {
    [self.handledSegments removeAllObjects];
    [self setPrompt:nil];
    self.sponsorSegments = YTKACEStoredSponsorSegments(URL);
    __weak YTKACEDownloadPlaybackSession *weakSelf = self;
    YTKACERefreshSponsorSegments(URL, ^(NSArray<NSDictionary<NSString *, id> *> *segments) {
        YTKACEDownloadPlaybackSession *strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf.currentURL isEqual:URL]) return;
        strongSelf.sponsorSegments = segments;
        [strongSelf.handledSegments removeAllObjects];
        [strongSelf notifyChange];
    });
}

- (void)setPrompt:(NSDictionary<NSString *, id> *)segment {
    if (segment == self.promptedSegment ||
        [segment isEqualToDictionary:self.promptedSegment]) {
        return;
    }
    self.promptedSegment = segment;
    [NSNotificationCenter.defaultCenter
        postNotificationName:YTKACEDownloadSponsorPromptNotification object:self];
}

- (void)evaluateSponsorSegmentsAtTime:(NSTimeInterval)time {
    if (!YTKACESponsorBlockEnabled() || self.sponsorSegments.count == 0 ||
        !isfinite(time)) {
        [self setPrompt:nil];
        return;
    }
    NSDictionary<NSString *, id> *prompt = nil;
    for (NSUInteger index = 0; index < self.sponsorSegments.count; index++) {
        NSDictionary<NSString *, id> *segment = self.sponsorSegments[index];
        double start = [segment[@"start"] doubleValue];
        double end = [segment[@"end"] doubleValue];
        NSInteger behavior = YTKACESponsorCategoryBehavior(segment[@"category"]);
        if (behavior == 2 || behavior == 3) continue;
        NSNumber *token = @(index);
        if (time < start - 1.0) [self.handledSegments removeObject:token];
        BOOL inside = time >= start && time < end - 0.25;
        if (!inside) continue;
        if (behavior == 1) {
            if (![self.handledSegments containsObject:token]) prompt = segment;
            continue;
        }
        if ([self.handledSegments containsObject:token]) continue;
        [self.handledSegments addObject:token];
        [self skipSegment:segment];
        break;
    }
    [self setPrompt:prompt];
}

- (void)skipSegment:(NSDictionary<NSString *, id> *)segment {
    NSUInteger index = [self.sponsorSegments indexOfObject:segment];
    if (index != NSNotFound) [self.handledSegments addObject:@(index)];
    [self setPrompt:nil];
    [self seekToTime:[segment[@"end"] doubleValue]];
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.SponsorBlock.AudioFeedback")) {
        [[UINotificationFeedbackGenerator new]
            notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:YTKACEDownloadSponsorDidSkipNotification
                      object:self userInfo:@{@"segment": segment}];
}

- (void)seekToTime:(NSTimeInterval)seconds {
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval target = MAX(0.0, isfinite(seconds) ? seconds : 0.0);
    if (isfinite(duration) && duration > 0.0) target = MIN(target, duration);
    [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
            toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self notifyChange];
}

- (void)beginTrackingPosition {
    if (self.sponsorObserver == nil) {
        __weak YTKACEDownloadPlaybackSession *weakSelf = self;
        self.sponsorObserver = [self.player
            addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.3, 600)
                                         queue:dispatch_get_main_queue()
                                    usingBlock:^(CMTime time) {
            YTKACEDownloadPlaybackSession *strongSelf = weakSelf;
            if (strongSelf.player.rate == 0.0f) return;
            [strongSelf evaluateSponsorSegmentsAtTime:CMTimeGetSeconds(time)];
        }];
    }
    if (self.resumeObserver != nil) return;
    __weak YTKACEDownloadPlaybackSession *weakSelf = self;
    self.resumeObserver = [self.player
        addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(5.0, 600)
                                     queue:dispatch_get_main_queue()
                                usingBlock:^(__unused CMTime time) {
        YTKACEDownloadPlaybackSession *strongSelf = weakSelf;
        if (strongSelf.player.rate != 0.0f) [strongSelf rememberPosition];
    }];
}

- (void)play {
    YTKACEPauseYouTubePlayer();
    [self configureAudioSession];
    [self configureRemoteCommands];
    [self beginTrackingPosition];
    [self.player play];
    self.player.rate = MAX(0.25f, MIN(self.playbackRate, 5.0f));
    if ([YTKACELibraryPiP sharedPiP].automatic) [[YTKACELibraryPiP sharedPiP] silenceOtherControllers];
    [self notifyChange];
}

- (void)pause {
    [self rememberPosition];
    [self.player pause];
    [self notifyChange];
}

- (void)togglePlayback {
    self.player.rate == 0.0f ? [self play] : [self pause];
}

- (void)setPlaybackRate:(float)playbackRate {
    _playbackRate = MAX(0.25f, MIN(playbackRate, 5.0f));
    if (self.player.rate != 0.0f) {
        self.player.rate = _playbackRate;
    }
    [self notifyChange];
}

- (void)seekBy:(NSTimeInterval)seconds {
    NSTimeInterval current = CMTimeGetSeconds(self.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (!isfinite(current)) {
        current = 0.0;
    }
    NSTimeInterval target = MAX(0.0, current + seconds);
    if (isfinite(duration) && duration > 0.0) {
        target = MIN(target, duration);
    }
    [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
            toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)playNext {
    if (self.playlist.count == 0 || self.currentIndex == NSNotFound) {
        return;
    }
    NSInteger next = self.currentIndex + 1;
    if (next >= (NSInteger)self.playlist.count) {
        next = self.autoplayEnabled ? 0 : NSNotFound;
    }
    if (next != NSNotFound) {
        [self loadURL:self.playlist[(NSUInteger)next]
             playlist:self.playlist index:next];
    }
}

- (void)playPrevious {
    NSTimeInterval current = CMTimeGetSeconds(self.player.currentTime);
    if (isfinite(current) && current > 5.0) {
        [self.player seekToTime:kCMTimeZero];
        return;
    }
    if (self.playlist.count == 0 || self.currentIndex == NSNotFound) {
        return;
    }
    NSInteger previous = self.currentIndex - 1;
    if (previous < 0) {
        previous = self.autoplayEnabled ? (NSInteger)self.playlist.count - 1 : NSNotFound;
    }
    if (previous != NSNotFound) {
        [self loadURL:self.playlist[(NSUInteger)previous]
             playlist:self.playlist index:previous];
    }
}

- (void)stop {
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentURL = nil;
    self.playlist = @[];
    self.sponsorSegments = @[];
    [self setPrompt:nil];
    self.currentIndex = NSNotFound;
    [[YTKACELibraryPiP sharedPiP] stop];
    [self releaseRemoteCommands];
    [NSNotificationCenter.defaultCenter
        postNotificationName:YTKACEDownloadPlaybackDidStopNotification object:self];
}

- (void)itemDidEnd:(NSNotification *)notification {
    if (notification.object != self.player.currentItem) {
        return;
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval position = CMTimeGetSeconds(self.player.currentTime);
    YTKACEStoreCompleted(self.currentURL, duration, position);
    if (self.pauseAtEnd) {
        self.pauseAtEnd = NO;
        [self pause];
    } else if (self.repeatEnabled) {
        [self.player seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [self play];
        }];
    } else if (self.autoplayEnabled) {
        [self playNext];
    } else {
        [self pause];
    }
}

- (void)notifyChange {
    [self updateNowPlayingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTKACEDownloadPlaybackDidChangeNotification object:self];
    });
}

- (void)updateNowPlayingInfo {
    if (self.currentURL == nil) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] =
        self.currentURL.lastPathComponent.stringByDeletingPathExtension ?: @"YTKACE";
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval elapsed = CMTimeGetSeconds(self.player.currentTime);
    if (isfinite(duration) && duration > 0.0) info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    if (isfinite(elapsed) && elapsed >= 0.0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    UIImage *image = YTKACEMediaArtworkImage(self.currentURL);
    if (image != nil) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc]
            initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size) {
                (void)size;
                return image;
            }];
        info[MPMediaItemPropertyArtwork] = artwork;
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

@end

static NSHashTable<AVPictureInPictureController *> *YTKACEAllPiPControllers(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static IMP YTKACEOrigPiPInitLayer;
static IMP YTKACEOrigPiPInitSource;
static IMP YTKACEOrigPiPSetAuto;

static id YTKACEPiPInitLayer(id self, SEL _cmd, id layer) {
    id result = ((id (*)(id, SEL, id))YTKACEOrigPiPInitLayer)(self, _cmd, layer);
    if (result != nil) [YTKACEAllPiPControllers() addObject:result];
    return result;
}

static id YTKACEPiPInitSource(id self, SEL _cmd, id source) {
    id result = ((id (*)(id, SEL, id))YTKACEOrigPiPInitSource)(self, _cmd, source);
    if (result != nil) [YTKACEAllPiPControllers() addObject:result];
    return result;
}

static BOOL YTKACELibraryClaimsPiP(void);
static AVPictureInPictureController *YTKACELibraryPiPController(void);

static void YTKACEPiPSetAuto(id self, SEL _cmd, BOOL value) {
    if (value && self != YTKACELibraryPiPController() && YTKACELibraryClaimsPiP()) value = NO;
    ((void (*)(id, SEL, BOOL))YTKACEOrigPiPSetAuto)(self, _cmd, value);
}

__attribute__((constructor)) static void YTKACEInstallPiPTracking(void) {
    YTKACEInstallInstanceHook(@"AVPictureInPictureController", @"initWithPlayerLayer:",
        (IMP)YTKACEPiPInitLayer, &YTKACEOrigPiPInitLayer);
    YTKACEInstallInstanceHook(@"AVPictureInPictureController", @"initWithContentSource:",
        (IMP)YTKACEPiPInitSource, &YTKACEOrigPiPInitSource);
    YTKACEInstallInstanceHook(@"AVPictureInPictureController",
        @"setCanStartPictureInPictureAutomaticallyFromInline:",
        (IMP)YTKACEPiPSetAuto, &YTKACEOrigPiPSetAuto);
}

@interface YTKACELibraryPiP () <AVPictureInPictureControllerDelegate>
@property(nonatomic, strong, nullable) AVPictureInPictureController *controller;
@property(nonatomic, weak) AVPlayerLayer *layer;
@property(nonatomic, weak) UIView *owner;
@property(nonatomic, strong, nullable) UIView *retainedOwner;
@property(nonatomic, assign) BOOL startWhenPossible;
@property(nonatomic, assign, readwrite) BOOL active;
@end

static NSString * const YTKACELibraryAutoPiPKey = @"YTKACE.Preference.Downloads.AutoPiP";

static BOOL YTKACELibraryClaimsPiP(void) {
    YTKACEDownloadPlaybackSession *session = YTKACEDownloadPlaybackSession.sharedSession;
    return [YTKACELibraryPiP sharedPiP].automatic && session.currentURL != nil &&
        session.player.rate != 0.0f;
}

static AVPictureInPictureController *YTKACELibraryPiPController(void) {
    return [[YTKACELibraryPiP sharedPiP] valueForKey:@"controller"];
}

@implementation YTKACELibraryPiP

+ (instancetype)sharedPiP {
    static YTKACELibraryPiP *pip;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ pip = [YTKACELibraryPiP new]; });
    return pip;
}

- (void)useLayer:(AVPlayerLayer *)layer owner:(UIView *)owner {
    if (layer == nil || self.active || (layer == self.layer && self.controller != nil)) return;
    if (![AVPictureInPictureController isPictureInPictureSupported]) return;
    [self detachController];
    self.layer = layer;
    self.owner = owner;
    AVPictureInPictureController *controller =
        [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
    controller.delegate = self;
    if (@available(iOS 14.2, *)) {
        controller.canStartPictureInPictureAutomaticallyFromInline = self.automatic;
    }
    [controller addObserver:self forKeyPath:@"pictureInPicturePossible"
                    options:NSKeyValueObservingOptionNew context:NULL];
    self.controller = controller;
    static BOOL observing;
    if (!observing) {
        observing = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:
            UIApplicationWillResignActiveNotification object:nil queue:nil
            usingBlock:^(__unused NSNotification *note) {
                [[YTKACELibraryPiP sharedPiP] startForBackground];
            }];
    }
}

- (void)detachController {
    if (self.controller == nil) return;
    [self.controller removeObserver:self forKeyPath:@"pictureInPicturePossible"];
    self.controller.delegate = nil;
    self.controller = nil;
}

- (BOOL)automatic {
    return [NSUserDefaults.standardUserDefaults boolForKey:YTKACELibraryAutoPiPKey];
}

- (void)setAutomatic:(BOOL)automatic {
    [NSUserDefaults.standardUserDefaults setBool:automatic forKey:YTKACELibraryAutoPiPKey];
    if (@available(iOS 14.2, *)) {
        self.controller.canStartPictureInPictureAutomaticallyFromInline = automatic;
    }
}

- (BOOL)isUsingLayer:(AVPlayerLayer *)layer {
    return layer != nil && layer == self.layer && self.controller != nil;
}

- (void)start {
    if (self.controller == nil || self.active) return;
    if (self.controller.isPictureInPicturePossible) {
        self.startWhenPossible = NO;
        [self.controller startPictureInPicture];
    } else {
        self.startWhenPossible = YES;
    }
}

- (NSHashTable<AVPictureInPictureController *> *)silenced {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

- (void)silenceOtherControllers {
    if (@available(iOS 14.2, *)) {
        for (AVPictureInPictureController *controller in YTKACEAllPiPControllers().allObjects) {
            if (controller == self.controller) continue;
            if (controller.canStartPictureInPictureAutomaticallyFromInline) {
                ((void (*)(id, SEL, BOOL))YTKACEOrigPiPSetAuto)(controller,
                    @selector(setCanStartPictureInPictureAutomaticallyFromInline:), NO);
                [self.silenced addObject:controller];
            }
        }
    }
}

- (void)restoreOtherControllers {
    if (@available(iOS 14.2, *)) {
        for (AVPictureInPictureController *controller in self.silenced.allObjects) {
            ((void (*)(id, SEL, BOOL))YTKACEOrigPiPSetAuto)(controller,
                @selector(setCanStartPictureInPictureAutomaticallyFromInline:), YES);
        }
        [self.silenced removeAllObjects];
    }
}

- (void)startForBackground {
    AVPlayerLayer *layer = self.layer;
    if (YTKACELibraryClaimsPiP()) {
        [self silenceOtherControllers];
    } else {
        [self restoreOtherControllers];
    }
    if (!self.automatic || self.active || self.controller == nil ||
        layer.player == nil || layer.player.rate == 0.0f || self.owner.window == nil ||
        !self.controller.isPictureInPicturePossible) {
        return;
    }
    [self.controller startPictureInPicture];
}

- (void)stop {
    self.startWhenPossible = NO;
    if (self.controller.isPictureInPictureActive) {
        [self.controller stopPictureInPicture];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)keyPath;
    (void)change;
    (void)context;
    if (object != self.controller || !self.startWhenPossible) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.startWhenPossible && self.controller.isPictureInPicturePossible) {
            self.startWhenPossible = NO;
            [self.controller startPictureInPicture];
        }
    });
}

- (void)postChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTKACELibraryPiPDidChangeNotification object:self];
    });
}

- (void)pictureInPictureControllerWillStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    self.active = YES;
    self.retainedOwner = self.owner;
    [self postChange];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
    (void)pictureInPictureController;
    (void)error;
    self.active = NO;
    self.retainedOwner = nil;
    [self postChange];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    self.active = NO;
    self.retainedOwner = nil;
    [self postChange];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:
        (void (^)(BOOL restored))completionHandler {
    (void)pictureInPictureController;
    void (^handler)(UIView *) = self.restoreHandler;
    if (handler != nil) handler(self.retainedOwner);
    completionHandler(YES);
}

@end

@interface YTKACEPlayerSurface : UIView
@property(nonatomic, strong) AVPlayer *player;
@end

@implementation YTKACEPlayerSurface
+ (Class)layerClass { return AVPlayerLayer.class; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
- (void)setPlayer:(AVPlayer *)player {
    _player = player;
    self.playerLayer.player = player;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
}
@end

UIView *YTKACELibraryVideoView(void) {
    static YTKACEPlayerSurface *view;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        view = [YTKACEPlayerSurface new];
        view.backgroundColor = UIColor.blackColor;
        view.userInteractionEnabled = NO;
        view.player = YTKACEDownloadPlaybackSession.sharedSession.player;
    });
    return view;
}

AVPlayerLayer *YTKACELibraryVideoLayer(void) {
    return (AVPlayerLayer *)YTKACELibraryVideoView().layer;
}

static NSString *YTKACELibrarySponsorTitle(NSString *category) {
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return YTKACELocalized(@"Sponsor");
}

static UIImage *YTKACEScrubberThumb(CGFloat diameter, UIColor *color) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(diameter, diameter)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(0.0, 0.0, diameter, diameter)] fill];
    }];
}

@interface YTKACESegmentMarksView : UIView
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *segments;
@property(nonatomic, assign) NSTimeInterval duration;
@property(nonatomic, assign) CGFloat progress;
@end

@implementation YTKACESegmentMarksView

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    [[UIColor colorWithWhite:1.0 alpha:0.3] setFill];
    UIRectFill(self.bounds);
    CGFloat playedWidth = width * MAX(0.0, MIN(1.0, self.progress));
    if (playedWidth > 0.0) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSaveGState(context);
        UIRectClip(CGRectMake(0.0, 0.0, playedWidth, height));
        [YTKACEProgressFillImage(width, height) drawInRect:CGRectMake(0.0, 0.0, width, height)];
        CGContextRestoreGState(context);
    }
    if (!isfinite(self.duration) || self.duration <= 0.0 || !YTKACESponsorBlockEnabled()) {
        return;
    }
    for (NSDictionary<NSString *, id> *segment in self.segments) {
        NSString *category = segment[@"category"];
        if (YTKACESponsorCategoryBehavior(category) == 2) continue;
        CGFloat start = (CGFloat)([segment[@"start"] doubleValue] / self.duration) * width;
        CGFloat end = (CGFloat)([segment[@"end"] doubleValue] / self.duration) * width;
        start = MAX(0.0, MIN(width, start));
        end = MAX(start + 1.0, MIN(width, end));
        [YTKACESponsorCategoryColor(category) setFill];
        UIRectFill(CGRectMake(start, 0.0, end - start, height));
    }
}

@end

@interface YTKACESegmentSlider : UISlider
@property(nonatomic, strong) YTKACESegmentMarksView *marksView;
- (void)updateProgress;
@end

@implementation YTKACESegmentSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.marksView = [YTKACESegmentMarksView new];
    self.marksView.backgroundColor = UIColor.clearColor;
    self.marksView.userInteractionEnabled = NO;
    [self insertSubview:self.marksView atIndex:0];
    UIImage *clear = [UIImage new];
    [self setMinimumTrackImage:clear forState:UIControlStateNormal];
    [self setMaximumTrackImage:clear forState:UIControlStateNormal];
    return self;
}

- (CGRect)trackRectForBounds:(CGRect)bounds {
    CGRect rect = [super trackRectForBounds:bounds];
    rect.size.height = 3.0;
    rect.origin.y = CGRectGetMidY(bounds) - 1.5;
    return rect;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect track = [self trackRectForBounds:self.bounds];
    if (!CGRectEqualToRect(self.marksView.frame, track)) {
        self.marksView.frame = track;
        [self.marksView setNeedsDisplay];
    }
    [self sendSubviewToBack:self.marksView];
    [self updateProgress];
}

- (void)updateProgress {
    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat progress = range > 0.0 ? (self.value - self.minimumValue) / range : 0.0;
    if (fabs(progress - self.marksView.progress) < 0.0005) return;
    self.marksView.progress = progress;
    [self.marksView setNeedsDisplay];
}

- (void)setValue:(float)value animated:(BOOL)animated {
    [super setValue:value animated:animated];
    [self updateProgress];
}

- (void)setValue:(float)value {
    [super setValue:value];
    [self updateProgress];
}

- (void)setSegments:(NSArray *)segments duration:(NSTimeInterval)duration {
    if ([self.marksView.segments isEqualToArray:segments] &&
        self.marksView.duration == duration) {
        return;
    }
    self.marksView.segments = segments;
    self.marksView.duration = duration;
    [self.marksView setNeedsDisplay];
}

@end

@interface YTKACEPlayerTransition : NSObject <UIViewControllerAnimatedTransitioning>
@property(nonatomic, assign) BOOL presenting;
@property(nonatomic, assign) CGRect miniFrame;
@end

@implementation YTKACEPlayerTransition

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context {
    (void)context;
    return 0.34;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIView *container = context.containerView;
    UIViewController *player = [context viewControllerForKey:self.presenting
        ? UITransitionContextToViewControllerKey : UITransitionContextFromViewControllerKey];
    UIView *view = player.view;
    CGRect full = [context finalFrameForViewController:player];
    if (CGRectIsEmpty(full)) full = container.bounds;
    CGRect mini = CGRectIsNull(self.miniFrame) || CGRectIsEmpty(self.miniFrame)
        ? CGRectNull : [container convertRect:self.miniFrame fromView:nil];
    CGRect offscreen = CGRectOffset(full, 0.0, CGRectGetHeight(full));
    CGRect collapsed = CGRectIsNull(mini) ? offscreen : mini;
    UIView *controls = [player valueForKey:@"controlsView"];
    view.clipsToBounds = YES;
    if (!self.presenting) {
        UIView *below = [context viewForKey:UITransitionContextToViewKey];
        UIViewController *belowController =
            [context viewControllerForKey:UITransitionContextToViewControllerKey];
        if (below != nil && below.superview == nil) {
            below.frame = [context finalFrameForViewController:belowController];
            [container insertSubview:below atIndex:0];
        }
    }
    if (self.presenting) {
        [container addSubview:view];
        view.frame = collapsed;
        view.layer.cornerRadius = CGRectIsNull(mini) ? 0.0 : 12.0;
        controls.alpha = 0.0;
        [view layoutIfNeeded];
    }
    CGRect target = self.presenting ? full : collapsed;
    CGFloat radius = self.presenting || CGRectIsNull(mini) ? 0.0 : 12.0;
    if (!self.presenting) controls.alpha = 0.0;
    [UIView animateWithDuration:[self transitionDuration:context] delay:0.0
         usingSpringWithDamping:0.9 initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseInOut animations:^{
        view.frame = target;
        view.layer.cornerRadius = radius;
        [view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        BOOL cancelled = context.transitionWasCancelled;
        if (self.presenting) {
            view.layer.cornerRadius = 0.0;
            [UIView animateWithDuration:0.18 animations:^{ controls.alpha = 1.0; }];
        } else if (!cancelled) {
            [NSNotificationCenter.defaultCenter
                postNotificationName:YTKACELibraryFullPlayerWillHideNotification object:player];
            [view removeFromSuperview];
        }
        [context completeTransition:!cancelled];
    }];
}

@end

@interface YTKACEDownloadPlayerController () <UIGestureRecognizerDelegate,
                                              UIViewControllerTransitioningDelegate>
@property(nonatomic, strong) YTKACEDownloadPlaybackSession *session;
@property(nonatomic, strong) YTKACEPlayerSurface *playerSurface;
@property(nonatomic, strong) UIView *controlsView;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *repeatButton;
@property(nonatomic, strong) UIButton *pipButton;
@property(nonatomic, strong) UIButton *aspectButton;
@property(nonatomic, strong) UIButton *rotateButton;
@property(nonatomic, assign) UIInterfaceOrientationMask orientationLock;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *channelLabel;
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) YTKACESegmentSlider *slider;
@property(nonatomic, strong) UIView *optionsView;
@property(nonatomic, strong) UIView *optionsCard;
@property(nonatomic, strong) UILabel *speedDetail;
@property(nonatomic, strong) UILabel *sleepDetail;
@property(nonatomic, strong) UILabel *gesturesDetail;
@property(nonatomic, strong) UILabel *autoplayDetail;
@property(nonatomic, strong) NSTimer *hideTimer;
@property(nonatomic, strong) NSTimer *sleepTimer;
@property(nonatomic, assign) NSInteger sleepMinutes;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, copy) NSArray<YTKACESubtitleCue *> *subtitleCues;
@property(nonatomic, copy) NSString *subtitleMediaPath;
@property(nonatomic, copy) NSString *channelMediaPath;
@property(nonatomic, strong) AVMediaSelectionGroup *captionGroup;
@property(nonatomic, copy) NSArray *captionChoices;
@property(nonatomic, copy) NSArray<NSString *> *captionTitles;
@property(nonatomic, assign) NSUInteger captionIndex;
@property(nonatomic, strong) UIButton *captionButton;
@property(nonatomic, assign) BOOL subtitlesEnabled;
@property(nonatomic, assign) BOOL scrubbing;
@property(nonatomic, assign) BOOL aspectFill;
@property(nonatomic, assign) CGPoint panStart;
@property(nonatomic, strong) UILabel *seekIndicator;
@property(nonatomic, strong) NSLayoutConstraint *seekIndicatorX;
@property(nonatomic, assign) NSInteger seekTotal;
@property(nonatomic, strong) NSTimer *seekIndicatorTimer;
@property(nonatomic, strong) UIButton *skipButton;
@property(nonatomic, strong) UIView *skippedBanner;
@property(nonatomic, assign) NSTimeInterval skippedStart;
@property(nonatomic, assign) BOOL minimizing;
@end

static BOOL YTKACECanForceOrientation(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}

@implementation YTKACEDownloadPlayerController

- (instancetype)initWithSession:(YTKACEDownloadPlaybackSession *)session {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        self.session = session;
        self.sourceFrame = CGRectNull;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.transitioningDelegate = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter
        postNotificationName:YTKACELibraryFullPlayerWillShowNotification object:self];
    self.view.backgroundColor = UIColor.blackColor;
    [self buildPlayer];
    [self buildOptions];
    [self observePlayback];
    [self refreshControls];
    [self scheduleControlsHide];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.session play];
    [[YTKACELibraryPiP sharedPiP] useLayer:self.playerSurface.playerLayer
                                     owner:self.playerSurface];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[YTKACELibraryPiP sharedPiP] useLayer:self.playerSurface.playerLayer
                                     owner:self.playerSurface];
    [self refreshRotateButtonForSize:self.view.bounds.size];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self refreshRotateButtonForSize:size];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.hideTimer invalidate];
}

- (void)dealloc {
    [self.hideTimer invalidate];
    [self.sleepTimer invalidate];
    [self.seekIndicatorTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.timeObserver != nil) {
        [self.session.player removeTimeObserver:self.timeObserver];
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.orientationLock != 0 ? self.orientationLock
                                     : UIInterfaceOrientationMaskAllButUpsideDown;
}
- (BOOL)shouldAutorotate { return YES; }

- (id<UIViewControllerAnimatedTransitioning>)
    animationControllerForPresentedController:(UIViewController *)presented
                         presentingController:(UIViewController *)presenting
                             sourceController:(UIViewController *)source {
    (void)presented;
    (void)presenting;
    (void)source;
    YTKACEPlayerTransition *transition = [YTKACEPlayerTransition new];
    transition.presenting = YES;
    transition.miniFrame = self.sourceFrame;
    return transition;
}

- (id<UIViewControllerAnimatedTransitioning>)
    animationControllerForDismissedController:(UIViewController *)dismissed {
    (void)dismissed;
    YTKACEPlayerTransition *transition = [YTKACEPlayerTransition new];
    transition.presenting = NO;
    transition.miniFrame = self.minimizing ? YTKACEMiniPlayerTargetFrame() : CGRectNull;
    return transition;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol
                          size:(CGFloat)size
                        action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
             forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)addGlassToButton:(UIButton *)button side:(CGFloat)side {
    if (!YTKACELiquidGlassAvailable() || !YTKACEFeatureEnabled(@"YTKACE.Preference.Glass.Player")) return;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 1)
        : [effectClass new];
    if (effect == nil) return;
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.clipsToBounds = YES;
    glass.layer.cornerRadius = side * 0.5;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.layer.zPosition = -1.0;
    [button insertSubview:glass atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [glass.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [glass.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [glass.widthAnchor constraintEqualToConstant:side],
        [glass.heightAnchor constraintEqualToConstant:side],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:side],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:side]
    ]];
}

- (void)setSymbol:(NSString *)symbol size:(CGFloat)size forButton:(UIButton *)button {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
}

- (void)addPlayerGesturesToView:(UIView *)view {
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    [view addGestureRecognizer:doubleTap];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleControls)];
    tap.delegate = self;
    [tap requireGestureRecognizerToFail:doubleTap];
    [view addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [view addGestureRecognizer:pan];
}

- (void)buildPlayer {
    self.playerSurface = (YTKACEPlayerSurface *)YTKACELibraryVideoView();
    [self.playerSurface removeFromSuperview];
    self.playerSurface.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerSurface.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view addSubview:self.playerSurface];
    UIView *gestureView = [UIView new];
    gestureView.backgroundColor = UIColor.clearColor;
    gestureView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:gestureView];
    [self addPlayerGesturesToView:gestureView];
    [NSLayoutConstraint activateConstraints:@[
        [gestureView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [gestureView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [gestureView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [gestureView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.controlsView = [UIView new];
    self.controlsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    self.controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.controlsView];
    [self addPlayerGesturesToView:self.controlsView];

    UIButton *minimize = [self buttonWithSymbol:@"chevron.down" size:20.0
                                          action:@selector(minimizePlayer)];
    self.titleLabel = [UILabel new];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.channelLabel = [UILabel new];
    self.channelLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    self.channelLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    self.channelLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.titleLabel, self.channelLabel
    ]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 1.0;
    [titleStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    self.captionButton = [self buttonWithSymbol:@"captions.bubble" size:19.0
                                         action:@selector(toggleSubtitles)];
    self.pipButton = [self buttonWithSymbol:@"pip.enter" size:19.0
                                     action:@selector(toggleAutoPictureInPicture)];
    self.pipButton.hidden = ![AVPictureInPictureController isPictureInPictureSupported];
    UIButton *more = [self buttonWithSymbol:@"gearshape" size:19.0
                                      action:@selector(showOptions)];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        minimize, titleStack, self.captionButton, self.pipButton, more
    ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 6.0;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[minimize, self.captionButton, self.pipButton, more]) {
        [button.widthAnchor constraintEqualToConstant:44.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:44.0].active = YES;
    }
    [top setCustomSpacing:10.0 afterView:minimize];
    [top setCustomSpacing:12.0 afterView:titleStack];
    [self.controlsView addSubview:top];

    UIButton *previous = [self buttonWithSymbol:@"backward.end.fill" size:26.0
                                          action:@selector(previousItem)];
    self.playButton = [self buttonWithSymbol:@"pause.fill" size:40.0
                                      action:@selector(togglePlayback)];
    UIButton *next = [self buttonWithSymbol:@"forward.end.fill" size:26.0
                                      action:@selector(nextItem)];
    [self addGlassToButton:previous side:48.0];
    [self addGlassToButton:self.playButton side:64.0];
    [self addGlassToButton:next side:48.0];
    UIStackView *center = [[UIStackView alloc] initWithArrangedSubviews:@[
        previous, self.playButton, next
    ]];
    center.axis = UILayoutConstraintAxisHorizontal;
    center.alignment = UIStackViewAlignmentCenter;
    center.spacing = 56.0;
    center.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[previous, next]) {
        [button.widthAnchor constraintEqualToConstant:56.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:56.0].active = YES;
    }
    [self.playButton.widthAnchor constraintEqualToConstant:76.0].active = YES;
    [self.playButton.heightAnchor constraintEqualToConstant:76.0].active = YES;
    self.playButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    self.playButton.layer.cornerRadius = 38.0;
    [self.controlsView addSubview:center];

    self.timeLabel = [UILabel new];
    self.timeLabel.textColor = UIColor.whiteColor;
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0
                                                           weight:UIFontWeightMedium];
    self.timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.repeatButton = [self buttonWithSymbol:@"repeat" size:18.0
                                        action:@selector(toggleRepeat)];
    self.aspectButton = [self buttonWithSymbol:@"arrow.up.left.and.arrow.down.right"
                                          size:18.0 action:@selector(toggleAspect)];
    self.rotateButton = [self buttonWithSymbol:@"rectangle.landscape.rotate"
                                          size:18.0 action:@selector(toggleOrientation)];
    self.rotateButton.hidden = !YTKACECanForceOrientation();
    UIStackView *bottomButtons = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.repeatButton, self.aspectButton, self.rotateButton
    ]];
    bottomButtons.axis = UILayoutConstraintAxisHorizontal;
    bottomButtons.spacing = 4.0;
    bottomButtons.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[self.repeatButton, self.aspectButton, self.rotateButton]) {
        [button.widthAnchor constraintEqualToConstant:40.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
    }

    UIColor *accent = YTKACEProgressScrubberTint();
    self.slider = [YTKACESegmentSlider new];
    [self.slider setThumbImage:YTKACEScrubberThumb(13.0, accent) forState:UIControlStateNormal];
    [self.slider setThumbImage:YTKACEScrubberThumb(20.0, accent)
                      forState:UIControlStateHighlighted];
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.slider addTarget:self action:@selector(sliderStarted)
          forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged)
          forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderEnded)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel];
    [self.controlsView addSubview:self.timeLabel];
    [self.controlsView addSubview:bottomButtons];
    [self.controlsView addSubview:self.slider];

    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    self.subtitleLabel.textColor = UIColor.whiteColor;
    self.subtitleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.numberOfLines = 3;
    self.subtitleLabel.layer.cornerRadius = 5.0;
    self.subtitleLabel.layer.masksToBounds = YES;
    self.subtitleLabel.hidden = YES;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.subtitleLabel];

    self.seekIndicator = [UILabel new];
    self.seekIndicator.textColor = UIColor.whiteColor;
    self.seekIndicator.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.seekIndicator.textAlignment = NSTextAlignmentCenter;
    self.seekIndicator.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.seekIndicator.layer.cornerRadius = 22.0;
    self.seekIndicator.layer.masksToBounds = YES;
    self.seekIndicator.alpha = 0.0;
    self.seekIndicator.userInteractionEnabled = NO;
    self.seekIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.seekIndicator];

    self.skipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.skipButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.9];
    self.skipButton.layer.cornerRadius = 18.0;
    self.skipButton.layer.borderWidth = 1.0;
    self.skipButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.skipButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [self.skipButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.skipButton.hidden = YES;
    self.skipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.skipButton addTarget:self action:@selector(skipPromptedSegment)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.skipButton];

    UILayoutGuide *safe = self.controlsView.safeAreaLayoutGuide;
    self.seekIndicatorX = [self.seekIndicator.centerXAnchor
        constraintEqualToAnchor:self.view.leadingAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.playerSurface.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.playerSurface.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.playerSurface.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.playerSurface.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.controlsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.controlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.controlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.controlsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6.0],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [center.centerXAnchor constraintEqualToAnchor:self.controlsView.centerXAnchor],
        [center.centerYAnchor constraintEqualToAnchor:self.controlsView.centerYAnchor],
        [self.slider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [self.slider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [self.slider.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10.0],
        [self.slider.heightAnchor constraintEqualToConstant:30.0],
        [self.timeLabel.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [self.timeLabel.centerYAnchor constraintEqualToAnchor:bottomButtons.centerYAnchor],
        [bottomButtons.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor
                                                     constant:6.0],
        [bottomButtons.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor],
        [self.skipButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                       constant:-18.0],
        [self.skipButton.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor
                                                     constant:-52.0],
        [self.skipButton.heightAnchor constraintEqualToConstant:36.0],
        [self.skipButton.widthAnchor constraintEqualToAnchor:self.skipButton.titleLabel.widthAnchor
                                                    constant:32.0],
        [self.subtitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.subtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                                      constant:30.0],
        [self.subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                                       constant:-30.0],
        [self.subtitleLabel.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor
                                                         constant:-48.0],
        self.seekIndicatorX,
        [self.seekIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.seekIndicator.heightAnchor constraintEqualToConstant:44.0],
        [self.seekIndicator.widthAnchor constraintEqualToConstant:112.0]
    ]];
}

- (void)buildOptions {
    self.optionsView = [UIView new];
    self.optionsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.optionsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsView.hidden = YES;
    [self.view addSubview:self.optionsView];
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideOptions)];
    dismiss.delegate = self;
    dismiss.cancelsTouchesInView = NO;
    [self.optionsView addGestureRecognizer:dismiss];

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.98];
    card.layer.cornerRadius = 22.0;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsCard = card;
    [self.optionsView addSubview:card];

    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:rows];
    [rows addArrangedSubview:[self optionRow:@"speedometer"
        title:YTKACELocalized(@"Playback Speed") selector:@selector(selectSpeed) detail:&_speedDetail]];
    [rows addArrangedSubview:[self optionRow:@"moon.zzz.fill"
        title:YTKACELocalized(@"Sleep Timer") selector:@selector(selectSleepTimer) detail:&_sleepDetail]];
    [rows addArrangedSubview:[self optionRow:@"hand.draw"
        title:YTKACELocalized(@"Gestures") selector:@selector(toggleGestures) detail:&_gesturesDetail]];
    [rows addArrangedSubview:[self optionRow:@"forward.end.fill"
        title:YTKACELocalized(@"AutoPlay") selector:@selector(toggleAutoplay) detail:&_autoplayDetail]];
    [rows addArrangedSubview:[self optionRow:@"text.line.first.and.arrowtriangle.forward"
        title:YTKACELocalized(@"Play Next") selector:@selector(nextItem) detail:NULL]];
    [rows addArrangedSubview:[self optionRow:@"xmark"
        title:YTKACELocalized(@"Close") selector:@selector(hideOptions) detail:NULL]];
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.optionsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.optionsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.optionsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.optionsView.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.optionsView.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:520.0],
        [card.widthAnchor constraintEqualToAnchor:self.optionsView.widthAnchor multiplier:0.62],
        [card.heightAnchor constraintEqualToConstant:390.0],
        [rows.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0]
    ]];
}

- (UIView *)optionRow:(NSString *)symbol
                title:(NSString *)title
             selector:(SEL)selector
               detail:(UILabel * __strong *)detailOutput {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.whiteColor;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.whiteColor;
    name.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    UILabel *detail = [UILabel new];
    detail.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    detail.font = [UIFont systemFontOfSize:19.0];
    if (detailOutput != NULL) {
        *detailOutput = detail;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, name, detail, [UIView new]
    ]];
    stack.userInteractionEnabled = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 14.0;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:26.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:26.0].active = YES;
    [button addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:button.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-8.0],
        [stack.bottomAnchor constraintEqualToAnchor:button.bottomAnchor]
    ]];
    return button;
}

- (void)observePlayback {
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    self.timeObserver = [self.session.player addPeriodicTimeObserverForInterval:
        CMTimeMakeWithSeconds(0.25, 600) queue:dispatch_get_main_queue()
        usingBlock:^(__unused CMTime time) {
            [weakSelf refreshControls];
        }];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidChangeNotification object:self.session];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(sponsorPromptChanged:)
        name:YTKACEDownloadSponsorPromptNotification object:self.session];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(sponsorSkipped:)
        name:YTKACEDownloadSponsorDidSkipNotification object:self.session];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(pictureInPictureChanged:)
        name:YTKACELibraryPiPDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadInfoChanged:)
        name:YTKACEDownloadInfoDidChangeNotification object:nil];
}

- (void)downloadInfoChanged:(NSNotification *)notification {
    (void)notification;
    self.channelMediaPath = nil;
    [self refreshControls];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshControls];
}

- (void)refreshControls {
    NSURL *currentURL = self.session.currentURL;
    self.titleLabel.text = currentURL.lastPathComponent.stringByDeletingPathExtension;
    if (![self.channelMediaPath isEqualToString:currentURL.path]) {
        self.channelMediaPath = currentURL.path;
        self.channelLabel.text = currentURL == nil ? nil : YTKACEStoredChannelName(currentURL);
        self.channelLabel.hidden = self.channelLabel.text.length == 0;
    }
    if (![self.subtitleMediaPath isEqualToString:currentURL.path]) {
        self.subtitleMediaPath = currentURL.path;
        self.subtitleCues = currentURL == nil ? @[] : YTKACEReadSubtitles(currentURL);
        self.subtitlesEnabled = NO;
        self.captionGroup = nil;
        self.captionChoices = @[];
        self.captionTitles = @[];
        self.captionIndex = 0;
        if (currentURL != nil) [self loadCaptionsForURL:currentURL];
    }
    NSTimeInterval elapsed = CMTimeGetSeconds(self.session.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.session.player.currentItem.duration);
    if (!self.scrubbing) {
        self.slider.minimumValue = 0.0f;
        self.slider.maximumValue = isfinite(duration) && duration > 0.0
            ? (float)duration : 1.0f;
        self.slider.value = isfinite(elapsed) ? (float)elapsed : 0.0f;
        self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@",
            YTKACEPlayerTimeText(elapsed), YTKACEPlayerTimeText(duration)];
    }
    [self.slider setSegments:self.session.sponsorSegments duration:duration];
    NSString *playSymbol = self.session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self setSymbol:playSymbol size:40.0 forButton:self.playButton];
    self.repeatButton.tintColor = self.session.repeatEnabled
        ? UIColor.systemRedColor : UIColor.whiteColor;
    self.pipButton.tintColor = [YTKACELibraryPiP sharedPiP].automatic
        ? UIColor.systemRedColor : UIColor.whiteColor;
    self.captionButton.hidden = self.captionChoices.count <= 1;
    self.captionButton.tintColor = self.captionIndex != 0
        ? UIColor.systemRedColor : UIColor.whiteColor;
    self.speedDetail.text = [NSString stringWithFormat:@"· %.2gx", self.session.playbackRate];
    if (self.session.pauseAtEnd) {
        self.sleepDetail.text = YTKACELocalized(@"· End of track");
    } else if (self.sleepTimer.isValid) {
        self.sleepDetail.text = [NSString stringWithFormat:@"· %ldm",
            (long)self.sleepMinutes];
    } else {
        self.sleepDetail.text = YTKACELocalized(@"· Off");
    }
    self.gesturesDetail.text = self.session.gesturesEnabled ? YTKACELocalized(@"· On") : YTKACELocalized(@"· Off");
    self.autoplayDetail.text = self.session.autoplayEnabled ? YTKACELocalized(@"· On") : YTKACELocalized(@"· Off");
    YTKACESubtitleCue *activeCue = nil;
    for (YTKACESubtitleCue *cue in self.subtitleCues) {
        if (elapsed >= cue.start && elapsed <= cue.end) {
            activeCue = cue;
            break;
        }
        if (cue.start > elapsed) break;
    }
    self.subtitleLabel.text = activeCue.text;
    self.subtitleLabel.hidden = activeCue == nil || !self.subtitlesEnabled;
}

- (void)togglePlayback { [self.session togglePlayback]; [self scheduleControlsHide]; }
- (void)previousItem { [self.session playPrevious]; [self scheduleControlsHide]; }
- (void)nextItem { [self.session playNext]; [self hideOptions]; [self scheduleControlsHide]; }

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    if (!self.optionsView.hidden) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat x = [gesture locationInView:self.view].x;
    NSInteger direction = x < width / 3.0 ? -1 : (x > width * 2.0 / 3.0 ? 1 : 0);
    if (direction == 0) {
        [self togglePlayback];
        return;
    }
    if (self.seekTotal != 0 && (self.seekTotal > 0) != (direction > 0)) self.seekTotal = 0;
    self.seekTotal += direction * 10;
    [self.session seekBy:direction * 10.0];
    self.seekIndicator.text = direction > 0
        ? [NSString stringWithFormat:@"+%lds  »", (long)self.seekTotal]
        : [NSString stringWithFormat:@"«  %lds", (long)self.seekTotal];
    self.seekIndicatorX.constant = direction > 0 ? width * 0.8 : width * 0.2;
    [self.view layoutIfNeeded];
    self.seekIndicator.alpha = 1.0;
    [self.seekIndicatorTimer invalidate];
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    self.seekIndicatorTimer = [NSTimer scheduledTimerWithTimeInterval:0.9 repeats:NO
        block:^(__unused NSTimer *timer) {
            weakSelf.seekTotal = 0;
            [UIView animateWithDuration:0.2 animations:^{
                weakSelf.seekIndicator.alpha = 0.0;
            }];
        }];
}

- (void)loadCaptionsForURL:(NSURL *)URL {
    AVPlayerItem *item = self.session.player.currentItem;
    AVAsset *asset = item.asset;
    NSString *key = @"availableMediaCharacteristicsWithMediaSelectionOptions";
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[key] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEDownloadPlayerController *strongSelf = weakSelf;
            if (strongSelf == nil || ![strongSelf.session.currentURL isEqual:URL]) return;
            AVMediaSelectionGroup *group =
                [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
            NSMutableArray *choices = [NSMutableArray arrayWithObject:NSNull.null];
            NSMutableArray<NSString *> *titles =
                [NSMutableArray arrayWithObject:YTKACELocalized(@"Off")];
            NSUInteger preferred = 0;
            if (strongSelf.subtitleCues.count != 0) {
                [choices addObject:@"file"];
                [titles addObject:YTKACELocalized(@"Captions")];
                preferred = 1;
            }
            NSUInteger fileTracks = [asset tracksWithMediaType:AVMediaTypeSubtitle].count +
                [asset tracksWithMediaType:AVMediaTypeText].count;
            for (AVMediaSelectionOption *option in group.options) {
                if ([option hasMediaCharacteristic:AVMediaCharacteristicContainsOnlyForcedSubtitles]) {
                    continue;
                }
                if (preferred == 0 && fileTracks != 0) preferred = choices.count;
                [choices addObject:option];
                NSString *name = option.displayName;
                if (name.length == 0 && option.extendedLanguageTag.length != 0) {
                    name = [NSLocale.currentLocale
                        localizedStringForLanguageCode:option.extendedLanguageTag];
                }
                [titles addObject:name.length != 0 ? name : YTKACELocalized(@"Captions")];
            }
            YTKACEDownloadLog(@"subs", @"player captions file=%lu tracks=%lu [%@]",
                (unsigned long)strongSelf.subtitleCues.count, (unsigned long)fileTracks,
                [titles componentsJoinedByString:@", "]);
            strongSelf.captionGroup = group;
            strongSelf.captionChoices = choices;
            strongSelf.captionTitles = titles;
            BOOL hidden = [NSUserDefaults.standardUserDefaults
                boolForKey:@"YTKACE.Preference.Downloads.SubtitlesHidden"];
            [strongSelf selectCaptionIndex:hidden ? 0 : preferred];
        });
    }];
}

- (void)selectCaptionIndex:(NSUInteger)index {
    if (index >= self.captionChoices.count) index = 0;
    self.captionIndex = index;
    id choice = self.captionChoices.count != 0 ? self.captionChoices[index] : NSNull.null;
    AVPlayerItem *item = self.session.player.currentItem;
    if (self.captionGroup != nil) {
        [item selectMediaOption:[choice isKindOfClass:AVMediaSelectionOption.class] ? choice : nil
          inMediaSelectionGroup:self.captionGroup];
    }
    self.subtitlesEnabled = [choice isEqual:@"file"];
    if (!self.subtitlesEnabled) self.subtitleLabel.hidden = YES;
    [self refreshControls];
}

- (void)toggleSubtitles {
    if (self.captionChoices.count <= 1) return;
    [self.hideTimer invalidate];
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    YTKACEPresentSelectionMenu(self, self.captionButton, YTKACELocalized(@"Captions"),
        self.captionTitles, self.captionIndex, ^(NSUInteger index) {
            [NSUserDefaults.standardUserDefaults setBool:index == 0
                forKey:@"YTKACE.Preference.Downloads.SubtitlesHidden"];
            [weakSelf selectCaptionIndex:index];
            [weakSelf scheduleControlsHide];
        });
}

- (void)toggleRepeat {
    self.session.repeatEnabled = !self.session.repeatEnabled;
    [self refreshControls];
    [self scheduleControlsHide];
}

- (void)toggleAspect {
    self.aspectFill = !self.aspectFill;
    self.playerSurface.playerLayer.videoGravity = self.aspectFill
        ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    [self setSymbol:self.aspectFill ? @"arrow.down.right.and.arrow.up.left"
                                    : @"arrow.up.left.and.arrow.down.right"
               size:18.0 forButton:self.aspectButton];
    [self scheduleControlsHide];
}

- (void)toggleOrientation {
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene == nil) return;
        BOOL landscape = CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds);
        self.orientationLock = landscape ? UIInterfaceOrientationMaskPortrait
                                         : UIInterfaceOrientationMaskLandscape;
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:self.orientationLock];
        [scene requestGeometryUpdateWithPreferences:preferences
                                       errorHandler:^(NSError *error) {
            YTKACEDownloadLog(@"library", @"rotate failed %@", error.localizedDescription);
        }];
    }
    [self scheduleControlsHide];
}

- (void)refreshRotateButtonForSize:(CGSize)size {
    [self setSymbol:size.width > size.height ? @"rectangle.portrait.rotate"
                                             : @"rectangle.landscape.rotate"
               size:18.0 forButton:self.rotateButton];
}

- (void)toggleAutoPictureInPicture {
    YTKACELibraryPiP *pip = [YTKACELibraryPiP sharedPiP];
    pip.automatic = !pip.automatic;
    [pip useLayer:self.playerSurface.playerLayer owner:self.playerSurface];
    [self showHUD:[NSString stringWithFormat:@"%@ %@", YTKACELocalized(@"Picture in Picture"),
        pip.automatic ? YTKACELocalized(@"· On") : YTKACELocalized(@"· Off")]];
    [self refreshControls];
    [self scheduleControlsHide];
}

- (void)showHUD:(NSString *)text {
    UILabel *hud = [UILabel new];
    hud.text = [NSString stringWithFormat:@"   %@   ", text];
    hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    hud.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.9];
    hud.layer.cornerRadius = 16.0;
    hud.layer.masksToBounds = YES;
    hud.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hud];
    [NSLayoutConstraint activateConstraints:@[
        [hud.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hud.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                      constant:64.0],
        [hud.heightAnchor constraintEqualToConstant:32.0]
    ]];
    [UIView animateWithDuration:0.25 delay:1.4 options:0 animations:^{
        hud.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [hud removeFromSuperview];
    }];
}

- (void)pictureInPictureChanged:(NSNotification *)notification {
    (void)notification;
    YTKACELibraryPiP *pip = [YTKACELibraryPiP sharedPiP];
    if (pip.active) return;
    if (self.view.window != nil) {
        [pip useLayer:self.playerSurface.playerLayer owner:self.playerSurface];
    }
}

- (void)sponsorPromptChanged:(NSNotification *)notification {
    (void)notification;
    NSDictionary<NSString *, id> *segment = self.session.promptedSegment;
    if (segment != nil) {
        [self.skipButton setTitle:[NSString stringWithFormat:@"%@ %@",
            YTKACELocalized(@"Skip"), YTKACELibrarySponsorTitle(segment[@"category"])]
                         forState:UIControlStateNormal];
    }
    self.skipButton.hidden = segment == nil;
}

- (void)skipPromptedSegment {
    NSDictionary<NSString *, id> *segment = self.session.promptedSegment;
    if (segment != nil) [self.session skipSegment:segment];
}

- (void)sponsorSkipped:(NSNotification *)notification {
    NSDictionary<NSString *, id> *segment = notification.userInfo[@"segment"];
    NSInteger mode = YTKACESponsorNotificationMode();
    if (segment == nil || mode == 2) return;
    [self.skippedBanner removeFromSuperview];
    self.skippedStart = [segment[@"start"] doubleValue];
    UIView *banner = [UIView new];
    banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    banner.layer.cornerRadius = 12.0;
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = [NSString stringWithFormat:@"%@ %@",
        YTKACELibrarySponsorTitle(segment[@"category"]), YTKACELocalized(@"segment skipped")];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:label];
    if (mode == 0) {
        UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
        [undo setTitle:YTKACELocalized(@"Unskip") forState:UIControlStateNormal];
        [undo setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        undo.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [undo addTarget:self action:@selector(unskipSegment)
       forControlEvents:UIControlEventTouchUpInside];
        [views addObject:undo];
    }
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:views];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 18.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addSubview:content];
    [self.view addSubview:banner];
    [NSLayoutConstraint activateConstraints:@[
        [banner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [banner.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor constant:-52.0],
        [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
        [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
        [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0]
    ]];
    self.skippedBanner = banner;
    NSTimeInterval duration = mode == 0
        ? YTKACESponsorUnskipAlertDuration() : YTKACESponsorSkipAlertDuration();
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (weakSelf.skippedBanner == banner) {
                [banner removeFromSuperview];
                weakSelf.skippedBanner = nil;
            }
        });
}

- (void)unskipSegment {
    [self.session seekToTime:self.skippedStart];
    [self.skippedBanner removeFromSuperview];
    self.skippedBanner = nil;
}

- (void)sliderStarted { self.scrubbing = YES; [self.hideTimer invalidate]; }
- (void)sliderChanged {
    [self.slider updateProgress];
    NSTimeInterval duration = CMTimeGetSeconds(self.session.player.currentItem.duration);
    self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@",
        YTKACEPlayerTimeText(self.slider.value), YTKACEPlayerTimeText(duration)];
}
- (void)sliderEnded {
    self.scrubbing = NO;
    [self.session seekToTime:self.slider.value];
    [self scheduleControlsHide];
}

- (void)toggleControls {
    if (!self.optionsView.hidden) {
        return;
    }
    BOOL show = self.controlsView.alpha < 0.5;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsView.alpha = show ? 1.0 : 0.0;
    }];
    show ? [self scheduleControlsHide] : [self.hideTimer invalidate];
}

- (void)scheduleControlsHide {
    [self.hideTimer invalidate];
    if (self.session.player.rate == 0.0f || !self.optionsView.hidden) {
        return;
    }
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
        target:self selector:@selector(hideControls)
        userInfo:nil repeats:NO];
}

- (void)hideControls {
    [UIView animateWithDuration:0.25 animations:^{
        self.controlsView.alpha = 0.0;
    }];
}

- (void)showOptions {
    [self.hideTimer invalidate];
    [self refreshControls];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightRegular];
    UIImage *(^icon)(NSString *) = ^UIImage *(NSString *name) {
        return [[UIImage systemImageNamed:name withConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    };
    NSString *(^value)(UILabel *) = ^NSString *(UILabel *label) {
        NSString *text = label.text ?: @"";
        return [text hasPrefix:@"· "] ? [text substringFromIndex:2] : text;
    };
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    NSArray<NSDictionary *> *actions = @[
        @{@"title": YTKACELocalized(@"Playback Speed"), @"subtitle": value(self.speedDetail),
          @"icon": icon(@"speedometer"), @"handler": ^{ [weakSelf selectSpeed]; }},
        @{@"title": YTKACELocalized(@"Sleep Timer"), @"subtitle": value(self.sleepDetail),
          @"icon": icon(@"moon.zzz"), @"handler": ^{ [weakSelf selectSleepTimer]; }},
        @{@"title": YTKACELocalized(@"Gestures"), @"subtitle": value(self.gesturesDetail),
          @"icon": icon(@"hand.draw"), @"handler": ^{ [weakSelf toggleGestures]; }},
        @{@"title": YTKACELocalized(@"AutoPlay"), @"subtitle": value(self.autoplayDetail),
          @"icon": icon(@"forward.end"), @"handler": ^{ [weakSelf toggleAutoplay]; }},
        @{@"title": YTKACELocalized(@"Play Next"),
          @"icon": icon(@"text.line.first.and.arrowtriangle.forward"), @"handler": ^{ [weakSelf nextItem]; }}
    ];
    YTKACEPresentNativeSheet(nil, nil, self.view, actions);
    [self scheduleControlsHide];
}

- (void)hideOptions {
    [UIView animateWithDuration:0.18 animations:^{ self.optionsView.alpha = 0.0; }
        completion:^(__unused BOOL finished) {
            self.optionsView.hidden = YES;
            [self scheduleControlsHide];
        }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer.view == self.optionsView) {
        return ![touch.view isDescendantOfView:self.optionsCard];
    }
    return ![touch.view isKindOfClass:UIControl.class];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) {
        return self.session.gesturesEnabled && self.optionsView.hidden;
    }
    return YES;
}

- (void)selectSpeed {
    NSArray<NSNumber *> *speeds = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75,
                                    @2.0, @2.5, @3.0, @4.0, @5.0];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSUInteger selected = 0;
    for (NSUInteger index = 0; index < speeds.count; index++) {
        NSNumber *speed = speeds[index];
        [titles addObject:[NSString stringWithFormat:@"%.2gx", speed.floatValue]];
        if (fabs(speed.floatValue - self.session.playbackRate) < 0.01) {
            selected = index;
        }
    }
    YTKACEPresentSelectionMenu(self, self.view, YTKACELocalized(@"Playback Speed"), titles,
        selected, ^(NSUInteger index) {
            self.session.playbackRate = speeds[index].floatValue;
            [self refreshControls];
        });
}

- (void)selectSleepTimer {
    NSArray<NSString *> *titles = @[
        YTKACELocalized(@"Off"), YTKACELocalized(@"End of track"),
        YTKACELocalized(@"15 Minutes"), YTKACELocalized(@"30 Minutes"),
        YTKACELocalized(@"45 Minutes"), YTKACELocalized(@"60 Minutes")
    ];
    NSArray<NSNumber *> *minutes = @[@0, @0, @15, @30, @45, @60];
    NSUInteger selected = self.session.pauseAtEnd ? 1 : 0;
    if (self.sleepTimer.isValid) {
        NSUInteger match = [minutes indexOfObject:@(self.sleepMinutes)];
        if (match != NSNotFound) selected = match;
    }
    YTKACEPresentSelectionMenu(self, self.view, YTKACELocalized(@"Sleep Timer"), titles,
        selected, ^(NSUInteger index) {
            [self.sleepTimer invalidate];
            self.sleepTimer = nil;
            self.sleepMinutes = 0;
            self.session.pauseAtEnd = index == 1;
            NSInteger minute = minutes[index].integerValue;
            if (minute > 0) {
                self.sleepMinutes = minute;
                self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:
                    minute * 60.0 target:self selector:@selector(sleepTimerFired)
                    userInfo:nil repeats:NO];
            }
            [self refreshControls];
        });
}

- (void)sleepTimerFired {
    [self.session pause];
    self.sleepTimer = nil;
    self.sleepMinutes = 0;
    [self refreshControls];
}

- (void)toggleGestures {
    self.session.gesturesEnabled = !self.session.gesturesEnabled;
    [self refreshControls];
}

- (void)toggleAutoplay {
    self.session.autoplayEnabled = !self.session.autoplayEnabled;
    [self refreshControls];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!self.session.gesturesEnabled || !self.optionsView.hidden) {
        return;
    }
    CGPoint translation = [gesture translationInView:self.view];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.panStart = translation;
        [self.hideTimer invalidate];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = translation.x - self.panStart.x;
        CGFloat dy = translation.y - self.panStart.y;
        if (fabs(dx) > fabs(dy) && fabs(dx) > 24.0) {
            [self.session seekBy:dx / 18.0];
            self.panStart = translation;
        } else if (fabs(dy) > 18.0) {
            CGFloat change = -dy / MAX(180.0, CGRectGetHeight(self.view.bounds));
            CGPoint location = [gesture locationInView:self.view];
            if (location.x < CGRectGetMidX(self.view.bounds)) {
                UIScreen.mainScreen.brightness = MAX(0.0,
                    MIN(1.0, UIScreen.mainScreen.brightness + change));
            } else {
                MPVolumeView *volumeView = [MPVolumeView new];
                UISlider *volumeSlider = nil;
                for (UIView *view in volumeView.subviews) {
                    if ([view isKindOfClass:UISlider.class]) {
                        volumeSlider = (UISlider *)view;
                        break;
                    }
                }
                [volumeSlider setValue:MAX(0.0, MIN(1.0, volumeSlider.value + change)) animated:NO];
                [volumeSlider sendActionsForControlEvents:UIControlEventValueChanged];
            }
            self.panStart = translation;
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self scheduleControlsHide];
    }
}

- (void)minimizePlayer {
    dispatch_block_t handler = self.minimizeHandler;
    self.minimizing = YES;
    [self dismissViewControllerAnimated:YES completion:handler];
}

@end
