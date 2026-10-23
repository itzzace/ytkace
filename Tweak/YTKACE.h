#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

@class UIView;
@class CALayer;
@class UIImage;
@class UIColor;

NS_ASSUME_NONNULL_BEGIN

void YTKACERouteSpeedMenuItem(id _Nullable renderers, id _Nullable actions, UIView *_Nullable view, id _Nullable responder);

FOUNDATION_EXPORT NSString * const YTKACEVersion;

void YTKACEInstallAdsHooks(void);
void YTKACEHandleAdDisplayView(UIView *view);
void YTKACECollapseHostCell(UIView *view);
void YTKACEHandleAdCellLayout(UIView *cell);
void YTKACEHandleAdCellReuse(UIView *cell);
NSArray *YTKACEFilterAdSections(NSArray *sections);
void YTKACEInstallPromoHooks(void);
void YTKACEInstallSponsorBlockHooks(void);
void YTKACEInstallDownloadHooks(void);
void YTKACEInstallQueueHooks(void);
void YTKACEQueuePrepareMenuRenderers(id _Nullable renderers);
BOOL YTKACEQueueHasItems(void);
BOOL YTKACEQueueOwnsCurrentVideo(void);
NSString * _Nullable YTKACELastVideoID(void);
void YTKACEInstallGlobalDownloadMiniPlayer(void);
void YTKACEInstallOLEDHooks(void);
void YTKACEInstallStartupHooks(void);
void YTKACEInstallPremiumLogoHooks(void);
void YTKACEInstallBackgroundPlaybackHooks(void);
void YTKACEInstallPiPHooks(void);
void YTKACEInstallSpeedHooks(void);
double YTKACEStartPlaybackRate(void);
void YTKACEInstallLoopHooks(void);
void YTKACEInstallAutoplayHooks(void);
void YTKACEOpenPausedVideoActivated(id player);
void YTKACEInstallCaptionHooks(void);
void YTKACEInstallTranscriptHooks(void);
NSArray<NSDictionary *> *_Nullable YTKACEParseCaptionCues(NSData *data);
NSArray *_Nullable YTKACECaptionTracksForResponse(id playerResponse);
NSArray<NSDictionary *> *_Nullable YTKACECaptionChoicesForResponse(id playerResponse);
NSString *YTKACECaptionTrackLabel(id track);
NSString *_Nullable YTKACECaptionTrackLanguage(id track);
NSURL *_Nullable YTKACECaptionTrackURL(id track);
void YTKACEFetchCuesForURL(NSURL *_Nullable url,
                           void (^completion)(NSArray<NSDictionary *> *_Nullable cues));
void YTKACEFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *_Nullable cues,
                                               NSString *_Nullable language));
void YTKACECaptionsSnapshot(id player);
void YTKACECaptionsRestore(id player);
void YTKACEApplyPreferredCaptionLanguage(id player);
void YTKACEInstallSleepTimerHooks(void);
void YTKACEInstallDoubleTapHooks(void);
void YTKACEInstallVideoZoomHooks(void);
void YTKACEPauseYouTubePlayer(void);
void YTKACEConfigureTapToSeek(UIView *view);
void YTKACEInstallShortsLimitHooks(void);
void YTKACEInstallShortsStartupHooks(void);
void YTKACEInstallShortsPinchHooks(void);
void YTKACEInstallShortsPiPHooks(void);
void YTKACESetShortsOverlayFullscreen(UIView *overlay, BOOL fullscreen);
void YTKACESetShortsElementsFullscreen(UIView *container, BOOL fullscreen);
UIView *YTKACEShortsContainerForView(UIView *view, UIView *fallbackRoot);
BOOL YTKACEShortsNewFullscreenActive(void);
void YTKACERegisterFadedShortsContainer(UIView *container);
void YTKACEFadeShortsElement(UIView *element);
BOOL YTKACEShortsPivotShowBlocked(void);
void YTKACESetShortsNewFullscreen(UIView *_Nullable container, BOOL fullscreen);
BOOL YTKACEShortsLimitReached(void);
BOOL YTKACEPlayerIsShorts(id player);
NSInteger YTKACERealUserInterfaceIdiom(void);
void YTKACEInstallProgressBarHooks(void);
void YTKACEApplyProgressStyleToBar(UIView *bar);
void YTKACEStyleProgressLayer(CALayer *layer, CGFloat trackWidth);
UIImage *YTKACEProgressFillImage(CGFloat width, CGFloat height);
UIColor *YTKACEProgressScrubberTint(void);
void YTKACEInstallStreamingHooks(void);
void YTKACEInstallHLSPlaybackHooks(void);
NSInteger YTKACEPlaybackFixMode(void);
id _Nullable YTKACEHLSOriginalResponse(NSString * _Nullable videoID);
BOOL YTKACEHLSBeginFallback(NSString * _Nullable videoID, void (^ _Nonnull ready)(BOOL available));
void YTKACEInstallShortsHooks(void);
void YTKACEInstallSideloadCompatibilityHooks(void);
void YTKACEInstallCastCompatibilityHooks(void);
void YTKACEStartCastDiscovery(void);
void YTKACEInstallTabBarHooks(void);
void YTKACERefreshPivotBarBackground(void);
BOOL YTKACELiquidGlassAvailable(void);
NSInteger YTKACETabBarGlassMode(void);
BOOL YTKACETabBarOwnGlass(void);
NSInteger YTKACEFrostedTabBarMode(void);
void YTKACEApplyTopNavigationGlass(UIView *container);
UIView *YTKACEMakeSettingsGlass(void);
void YTKACEInstallNavigationBehaviorHooks(void);
void YTKACEInstallPlayerGestureHooks(void);
void YTKACEInstallSettingsEntryHooks(void);
void YTKACEInstallNativeSettingsHooks(void);
void YTKACEInstallOverlayVisibilityHooks(void);
void YTKACEInstallContentVisibilityHooks(void);
void YTKACEInstallNavigationVisibilityHooks(void);
void YTKACEInstallMiscellaneousHooks(void);
void YTKACEInstallCopyCommentHooks(void);
void YTKACEInstallProfilePictureHooks(void);
void YTKACEInstallPostImageSaverHooks(void);
void YTKACEInstallPlaylistDownloaderHooks(void);
BOOL YTKACEProductIdentifierMatches(NSString * _Nullable identifier);
BOOL YTKACEViewIsInsidePlayerOverlay(UIView *view);
void YTKACEHideProductSubtree(UIView *view);
BOOL YTKACEProductOverlayMatches(id overlay);
void YTKACEInstallNativeShareHooks(void);
void YTKACEProfileConsiderDisplayView(UIView *view, id node);
void YTKACEScheduleFirstLaunch(void);

NS_ASSUME_NONNULL_END
void YTKACEInstallPlaybackFixHooks(void);
NSDictionary<NSString *, NSString *> * _Nullable YTKACESolveChallenges(NSString * _Nullable playerID,
    NSString * _Nullable playerJS, NSString * _Nonnull type, NSArray<NSString *> * _Nonnull challenges);
NSData * _Nonnull YTKACETVClientInfo(void);
NSDictionary<NSString *, NSString *> * _Nonnull YTKACETVHeaders(NSString * _Nullable visitor);
void YTKACETVFetchPlayerResponse(NSString * _Nonnull videoID,
    void (^ _Nonnull completion)(id _Nullable response, NSString * _Nullable visitor, NSError * _Nullable error));
NSString * _Nonnull YTKACESolveURLParameterN(NSString * _Nullable playerID, NSString * _Nullable playerJS,
    NSString * _Nonnull URLString);
