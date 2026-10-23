#import "YTKACE.h"
#import "Features/Downloads/SABRDownloader.h"
#import "Features/Downloads/DownloadLog.h"
#import "Features/SponsorBlock/DeArrow.h"
#import "Features/Translation/YTKACEVOTHooks.h"
#import "Runtime/Preferences.h"

#import <UIKit/UIKit.h>

#ifndef YTKACE_COMBINED_SABR
#define YTKACE_COMBINED_SABR 0
#endif

NSString * const YTKACEVersion = @YTKACE_VERSION_STRING;

static void YTKACEInstallModules(void) {
    YTKACEInstallSideloadCompatibilityHooks();
    YTKACEInstallCastCompatibilityHooks();
    YTKACEInstallAdsHooks();
    YTKACEInstallPromoHooks();
    YTKACEInstallSponsorBlockHooks();
    YTKACEInstallDeArrow();
    YTKACEInstallOLEDHooks();
    YTKACEInstallStartupHooks();
    YTKACEInstallPremiumLogoHooks();
    YTKACEInstallBackgroundPlaybackHooks();
    YTKACEInstallSpeedHooks();
    YTKACEInstallLoopHooks();
    YTKACEInstallAutoplayHooks();
    YTKACEInstallCaptionHooks();
    YTKACEInstallTranscriptHooks();
    YTKACEInstallSleepTimerHooks();
    YTKACEInstallPiPHooks();
    YTKACEInstallPlaybackFixHooks();
    YTKACEInstallDownloadHooks();
    YTKACESABRRestoreSeed();
    YTKACERestorePlayerRequest();
    YTKACEInstallPlaylistDownloaderHooks();
    YTKACEInstallFeedDownloadHooks();
    YTKACEInstallQueueHooks();
    YTKACEInstallGlobalDownloadMiniPlayer();
    YTKACEInstallDoubleTapHooks();
    YTKACEInstallVideoZoomHooks();
    YTKACEInstallShortsLimitHooks();
    YTKACEInstallShortsStartupHooks();
    YTKACEInstallShortsPinchHooks();
    YTKACEInstallShortsPiPHooks();
    YTKACEInstallProgressBarHooks();
    YTKACEInstallStreamingHooks();
    YTKACEInstallHLSPlaybackHooks();
    YTKACEInstallShortsHooks();
    YTKACEInstallTabBarHooks();
    YTKACEInstallNavigationBehaviorHooks();
    YTKACEInstallPlayerGestureHooks();
    YTKACEInstallOverlayVisibilityHooks();
    YTKACEInstallContentVisibilityHooks();
    YTKACEInstallNavigationVisibilityHooks();
    YTKACEInstallMiscellaneousHooks();
    YTKACEInstallCopyCommentHooks();
    YTKACEInstallProfilePictureHooks();
    YTKACEInstallPostImageSaverHooks();
    YTKACEInstallNativeShareHooks();
    YTKACEInstallSettingsEntryHooks();
    YTKACEInstallNativeSettingsHooks();
    YTKACEInstallTranslationHooks();
}

__attribute__((constructor))
static void YTKACEEntryPoint(void) {
    @autoreleasepool {
        YTKACEClearDownloadLog();
        YTKACERegisterDefaults();
        YTKACEScheduleFirstLaunch();
        YTKACEInstallModules();
    }
}
