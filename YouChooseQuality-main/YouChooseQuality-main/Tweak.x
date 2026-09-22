#import <YouTubeHeader/GCKNNetworkReachability.h>
#import <YouTubeHeader/MDXSessionManager.h>
#import <YouTubeHeader/MLAVAssetPlayer.h>
#import <YouTubeHeader/MLAVPlayer.h>
#import <YouTubeHeader/MLHAMPlayerItem.h>
#import <YouTubeHeader/MLQuickMenuVideoQualitySettingFormatConstraint.h>
#import <HBLog.h>
#import "Scenario.h"

extern BOOL IsEnabled();
extern int GetQuality(Scenario scenario);

BOOL isExternal = NO;

static Scenario GetScenario() {
    if ([NSProcessInfo processInfo].lowPowerModeEnabled) return LowPowerMode;
    BOOL isWifi = [[%c(GCKNNetworkReachability) sharedInstance] currentStatus] == 1;
    if (isWifi) return isExternal ? ExternalWifi : Wifi;
    return isExternal ? ExternalCellular : Cellular;
}

static NSString *getClosestQualityLabel(NSArray <MLFormat *> *formats) {
    Scenario scenario = GetScenario();
    int quality = GetQuality(scenario);
    int targetResolution = quality / 100;
    int targetFPS = quality % 100;
    int minDiff = INT_MAX;
    NSString *closestQualityLabel = nil;
    HBLogDebug(@"YCQ - Quality: %d, Scenario: %d, External: %d, Target: Resolution: %d, FPS: %d", quality, scenario, isExternal, targetResolution, targetFPS);
    for (MLFormat *format in formats) {
        int resolution = [format singleDimensionResolution];
        int fps = [format FPS];
        int resolutionDiff = abs(resolution - targetResolution);
        int fpsDiff = abs(fps - targetFPS);
        int totalDiff = resolutionDiff + fpsDiff;
        HBLogDebug(@"YCQ - Available: %@, Resolution: %d, FPS: %d, Codec: %d, Diff: %d (Current: %d)", [format qualityLabel], resolution, fps, [[format MIMEType] videoCodec], totalDiff, minDiff);
        if (totalDiff < minDiff) {
            minDiff = totalDiff;
            closestQualityLabel = [format qualityLabel];
            HBLogDebug(@"YCQ - Selected: %@, Resolution: %d, FPS: %d", closestQualityLabel, resolution, fps);
        }
    }
    return closestQualityLabel;
}

static MLQuickMenuVideoQualitySettingFormatConstraint *getConstraint(NSString *qualityLabel) {
    MLQuickMenuVideoQualitySettingFormatConstraint *constraint;
    @try {
        constraint = [[%c(MLQuickMenuVideoQualitySettingFormatConstraint) alloc] initWithVideoQualitySetting:3 formatSelectionReason:2 qualityLabel:qualityLabel];
    } @catch (id ex) {
        constraint = [[%c(MLQuickMenuVideoQualitySettingFormatConstraint) alloc] initWithVideoQualitySetting:3 formatSelectionReason:2 qualityLabel:qualityLabel resolutionCap:0];
    }
    return constraint;
}

%hook MLHAMPlayerItem

- (void)onSelectableVideoFormats:(NSArray <MLFormat *> *)formats {
    %orig;
    if (!IsEnabled()) return;
    HBLogDebug(@"YCQ - onSelectableVideoFormats called with itemState: %ld, formats count: %lu", (long)self.itemState, (unsigned long)[formats count]);
    NSString *qualityLabel = getClosestQualityLabel(formats);
    MLQuickMenuVideoQualitySettingFormatConstraint *constraint = getConstraint(qualityLabel);
    self.videoFormatConstraint = constraint;
    HBLogDebug(@"YCQ - Set constraint, itemState is now: %ld", (long)self.itemState);

    // For Shorts: if itemState is 0, the constraint won't be applied immediately.
    // Schedule another application after a delay to ensure it gets applied
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HBLogDebug(@"YCQ - After 0.1s delay, itemState: %ld", (long)self.itemState);
        if ([weakSelf isKindOfClass:%c(MLHAMPlayerItem)] && weakSelf.selectableVideoFormats && [weakSelf.selectableVideoFormats count] > 0) {
            HBLogDebug(@"YCQ - Reapplying constraint after delay for Shorts, itemState: %ld", (long)weakSelf.itemState);
            weakSelf.videoFormatConstraint = constraint;
        }
    });
}

%end

%hook MLAVPlayer

- (void)streamSelectorHasSelectableVideoFormats:(NSArray <MLFormat *> *)formats {
    %orig;
    if (!IsEnabled()) return;
    NSString *qualityLabel = getClosestQualityLabel(formats);
    self.videoFormatConstraint = getConstraint(qualityLabel);
}

%end

%hook MLAVAssetPlayer

// The changed value is not reliable but this method gets called whenever AirPlay session is started or stopped
- (void)playerExternalPlaybackActiveDidChange:(NSDictionary *)change {
    %orig;
    BOOL multipleScreens = [UIScreen screens].count > 1;
    if (isExternal != multipleScreens) {
        HBLogDebug(@"YCQ - Has Multiple Screens: %d", multipleScreens);
        isExternal = multipleScreens;
        MLAVPlayer *player = (MLAVPlayer *)self.delegate;
        NSString *qualityLabel = getClosestQualityLabel([player selectableVideoFormats]);
        player.videoFormatConstraint = getConstraint(qualityLabel);
    }
}

%end
