#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEOpenPausedKey =
    @"YTKACE.Preference.Playback.OpenPaused";
static NSString *const YTKACEAutoplayOffKey =
    @"YTKACE.Preference.Playback.AutoplayDisabled";

static IMP OriginalPlayAutoplay;
static IMP OriginalTriggerPendingAutoplay;
static IMP OriginalAdvanceToNext;
static IMP OriginalShouldAutonav;
static IMP OriginalSetWatchTransitionStartup;
static IMP OriginalInsertOrUpdateSingle;
static IMP OriginalSetSingleWatchTransition;


static NSString *YTKACELastPausedVideo;

static NSTimeInterval YTKACELastTouchTime;
static NSTimeInterval YTKACEUserNextTime;
static NSString *YTKACEUserNextOrigin;
static IMP OriginalSendEvent;


static int YTKACETransitionInt(id transition, NSString *name);

static void YTKACEPauseNow(id player) {
    if (player == nil) return;
    SEL pause = NSSelectorFromString(@"pause");
    if (![player respondsToSelector:pause]) return;
    ((void (*)(id, SEL))objc_msgSend)(player, pause);
}

void YTKACEOpenPausedVideoActivated(id player) {
    YTKACEApplyPreferredCaptionLanguage(player);
    if (!YTKACEFeatureEnabled(YTKACEOpenPausedKey)) return;
    NSString *videoID = nil;
    SEL getter = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:getter]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, getter);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    if (videoID.length != 0 &&
        [videoID isEqualToString:YTKACELastPausedVideo]) {
        return;
    }
    YTKACELastPausedVideo = [videoID copy];

    __weak id weakPlayer = player;
    YTKACEPauseNow(player);
    const double delays[] = { 0.0, 0.15, 0.4, 0.8, 1.4 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTKACEPauseNow(weakPlayer);
        });
    }
}

static BOOL YTKACEAutoplaySuppressed(void) {
    return YTKACEFeatureEnabled(YTKACEAutoplayOffKey);
}

static void YTKACEPlayAutoplay(id receiver, SEL selector) {
    if (YTKACEAutoplaySuppressed()) return;
    if (OriginalPlayAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalPlayAutoplay)(receiver, selector);
    }
}

static void YTKACETriggerPendingAutoplay(id receiver, SEL selector) {
    if (YTKACEAutoplaySuppressed()) return;
    if (OriginalTriggerPendingAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalTriggerPendingAutoplay)(receiver, selector);
    }
}

static void YTKACEAdvanceToNext(id receiver, SEL selector, BOOL autoplay,
                                BOOL internalTransition, id unplayableVideoID) {
    if (YTKACEAutoplaySuppressed() && autoplay) return;
    if (OriginalAdvanceToNext != NULL) {
        ((void (*)(id, SEL, BOOL, BOOL, id))OriginalAdvanceToNext)(
            receiver, selector, autoplay, internalTransition, unplayableVideoID);
    }
}








static BOOL YTKACEShouldAutonav(id receiver, SEL selector) {
    if (YTKACEAutoplaySuppressed()) return NO;
    return OriginalShouldAutonav != NULL
        ? ((BOOL (*)(id, SEL))OriginalShouldAutonav)(receiver, selector) : NO;
}


static int YTKACETransitionInt(id transition, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![transition respondsToSelector:selector]) return -999;
    return ((int (*)(id, SEL))objc_msgSend)(transition, selector);
}





static void YTKACESendEvent(id receiver, SEL selector, UIEvent *event) {
    if (event.type == UIEventTypeTouches) {
        YTKACELastTouchTime = CACurrentMediaTime();
    }
    if (OriginalSendEvent != NULL) {
        ((void (*)(id, SEL, id))OriginalSendEvent)(receiver, selector, event);
    }
}

static const int YTKACEAutoAdvanceSource = 6;
static const NSTimeInterval YTKACEUserNextWindow = 2.0;
static const NSTimeInterval YTKACETouchGraceWindow = 0.6;

static void YTKACENoteUserNextRequiringTouch(NSString *origin,
                                            BOOL requiresTouch) {
    const NSTimeInterval now = CACurrentMediaTime();
    if (requiresTouch &&
        (YTKACELastTouchTime == 0 || now - YTKACELastTouchTime > 1.5)) {
        return;
    }
    YTKACEUserNextTime = now;
    YTKACEUserNextOrigin = origin;
}

static void YTKACENoteUserNext(NSString *origin) {
    YTKACENoteUserNextRequiringTouch(origin, NO);
}

static BOOL YTKACEShouldDropTransition(id transition) {
    if (transition == nil) return NO;
    const int source = YTKACETransitionInt(transition, @"watchEndpointSource");
    const NSTimeInterval now = CACurrentMediaTime();
    const NSTimeInterval sinceTouch =
        YTKACELastTouchTime != 0 ? now - YTKACELastTouchTime : -1;
    const NSTimeInterval sinceUserNext =
        YTKACEUserNextTime != 0 ? now - YTKACEUserNextTime : -1;

    const BOOL userAsked =
        (sinceUserNext >= 0 && sinceUserNext <= YTKACEUserNextWindow) ||
        (sinceTouch >= 0 && sinceTouch <= YTKACETouchGraceWindow);
    return YTKACEAutoplaySuppressed() &&
        source == YTKACEAutoAdvanceSource && !userAsked;
}

static void YTKACESetWatchTransitionStartup(id receiver, SEL selector,
                                            id transition, BOOL onAppStartup) {
    if (!onAppStartup &&
        YTKACEShouldDropTransition(transition)) {
        return;
    }
    if (OriginalSetWatchTransitionStartup != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalSetWatchTransitionStartup)(
            receiver, selector, transition, onAppStartup);
    }
}

static void YTKACEInsertOrUpdateSingle(id receiver, SEL selector,
                                       id transition) {
    if (YTKACEShouldDropTransition(transition)) return;
    if (OriginalInsertOrUpdateSingle != NULL) {
        ((void (*)(id, SEL, id))OriginalInsertOrUpdateSingle)(
            receiver, selector, transition);
    }
}

static void YTKACESetSingleWatchTransition(id receiver, SEL selector,
                                           id transition) {
    if (YTKACEShouldDropTransition(transition)) return;
    if (OriginalSetSingleWatchTransition != NULL) {
        ((void (*)(id, SEL, id))OriginalSetSingleWatchTransition)(
            receiver, selector, transition);
    }
}

static IMP OriginalUserNext[8];

static long long YTKACEUserNextRemote(id receiver, SEL selector, id command) {
    YTKACENoteUserNext(@"remoteNextTrack");
    return OriginalUserNext[7] != NULL
        ? ((long long (*)(id, SEL, id))OriginalUserNext[7])(receiver, selector,
                                                            command)
        : 0;
}

static void YTKACEUserNextSender0(id receiver, SEL selector, id sender) {
    YTKACENoteUserNext(@"overlayNext");
    if (OriginalUserNext[0] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[0])(receiver, selector, sender);
    }
}

static void YTKACEUserNextSender1(id receiver, SEL selector, id sender) {
    YTKACENoteUserNext(@"controlsNext");
    if (OriginalUserNext[1] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[1])(receiver, selector, sender);
    }
}

static void YTKACEUserNextVoid5(id receiver, SEL selector) {
    YTKACENoteUserNext(@"playerBarNext");
    if (OriginalUserNext[5] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[5])(receiver, selector);
    }
}

static void YTKACEUserNextVoid6(id receiver, SEL selector) {
    YTKACENoteUserNext(@"lockscreenNext");
    if (OriginalUserNext[6] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[6])(receiver, selector);
    }
}

static void YTKACEUserNextVoid2(id receiver, SEL selector) {
    YTKACENoteUserNext(@"miniplayerNext");
    if (OriginalUserNext[2] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[2])(receiver, selector);
    }
}

static void YTKACEUserNextPanel(id receiver, SEL selector,
                                unsigned long long index) {
    YTKACENoteUserNextRequiringTouch(@"panelSelect", YES);
    if (OriginalUserNext[3] != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalUserNext[3])(
            receiver, selector, index);
    }
}

static void YTKACEUserNextEndpoint(id receiver, SEL selector, id endpoint) {
    YTKACENoteUserNext(@"nextFromEndpoint");
    if (OriginalUserNext[4] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[4])(receiver, selector,
                                                     endpoint);
    }
}

// Videos playing in the feed while scrolling or when a finger rests on a
// thumbnail (YouTube's "Playback in feeds").
static NSString *const YTKACEFeedPreviewsKey = @"YTKACE.Preference.Feed.InlinePlaybackDisabled";
static IMP OriginalInlineMutedEnabled;
static IMP OriginalInlineMutedPlaybackEnabled;

static BOOL YTKACEInlineMutedEnabled(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEFeedPreviewsKey)) return NO;
    return OriginalInlineMutedEnabled != NULL &&
        ((BOOL (*)(id, SEL))OriginalInlineMutedEnabled)(receiver, selector);
}

static BOOL YTKACEInlineMutedPlaybackEnabled(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEFeedPreviewsKey)) return NO;
    return OriginalInlineMutedPlaybackEnabled != NULL &&
        ((BOOL (*)(id, SEL))OriginalInlineMutedPlaybackEnabled)(receiver, selector);
}

void YTKACEInstallAutoplayHooks(void) {
    YTKACEInstallInstanceHook(@"YTHotConfig", @"isInlineMutedEnabled",
                              (IMP)YTKACEInlineMutedEnabled, &OriginalInlineMutedEnabled);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackContainerController", @"isInlineMutedPlayBackEnabled",
                              (IMP)YTKACEInlineMutedPlaybackEnabled, &OriginalInlineMutedPlaybackEnabled);
    YTKACEInstallInstanceHook(@"YTWatchFlowController", @"playAutoplay",
                              (IMP)YTKACEPlayAutoplay, &OriginalPlayAutoplay);
    YTKACEInstallInstanceHook(@"YTQueueController", @"triggerPendingAutoplay",
                              (IMP)YTKACETriggerPendingAutoplay,
                              &OriginalTriggerPendingAutoplay);
    YTKACEInstallInstanceHook(
        @"YTQueueController",
        @"advanceToNextWithAutoplay:isPlaybackControllerInternalTransition:"
         "unplayableVideoID:",
        (IMP)YTKACEAdvanceToNext, &OriginalAdvanceToNext);
    YTKACEInstallInstanceHook(@"YTWatchPlaybackController",
                              @"shouldAutonavToNextVideo",
                              (IMP)YTKACEShouldAutonav, &OriginalShouldAutonav);

    NSString *const layer = @"YTWatchLayerViewController";
    YTKACEInstallInstanceHook(layer, @"setWatchTransition:onAppStartup:",
                              (IMP)YTKACESetWatchTransitionStartup,
                              &OriginalSetWatchTransitionStartup);
    YTKACEInstallInstanceHook(layer, @"insertOrUpdateSingleWatchTransition:",
                              (IMP)YTKACEInsertOrUpdateSingle,
                              &OriginalInsertOrUpdateSingle);
    YTKACEInstallInstanceHook(layer, @"setSingleWatchTransition:",
                              (IMP)YTKACESetSingleWatchTransition,
                              &OriginalSetSingleWatchTransition);
    YTKACEInstallInstanceHook(@"UIApplication", @"sendEvent:",
                              (IMP)YTKACESendEvent, &OriginalSendEvent);

    YTKACEInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressNext:",
        (IMP)YTKACEUserNextSender0, &OriginalUserNext[0]);
    YTKACEInstallInstanceHook(
        @"YTMainAppControlsOverlayView", @"didPressNext:",
        (IMP)YTKACEUserNextSender1, &OriginalUserNext[1]);
    YTKACEInstallInstanceHook(
        @"YTWatchFloatingMiniplayerViewController", @"didTapNext",
        (IMP)YTKACEUserNextVoid2, &OriginalUserNext[2]);
    YTKACEInstallInstanceHook(
        @"YTPlaylistPanelController", @"didSelectEntryAtIndex:",
        (IMP)YTKACEUserNextPanel, &OriginalUserNext[3]);
    YTKACEInstallInstanceHook(
        @"YTWatchPreviousController",
        @"handleNextButtonWithFromNavigationEndpoint:",
        (IMP)YTKACEUserNextEndpoint, &OriginalUserNext[4]);
    YTKACEInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressPlayerBarNext",
        (IMP)YTKACEUserNextVoid5, &OriginalUserNext[5]);
    YTKACEInstallInstanceHook(
        @"YTWatchController", @"didPressNextTrackLockscreenButton",
        (IMP)YTKACEUserNextVoid6, &OriginalUserNext[6]);
    YTKACEInstallInstanceHook(
        @"YTRemoteCommandHandler", @"handleNextTrackCommand:",
        (IMP)YTKACEUserNextRemote, &OriginalUserNext[7]);
}
