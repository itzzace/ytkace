#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const YTKACERemoteSkipKey = @"YTKACE.Preference.Playback.RemoteSkip";
static NSString *const YTKACENowPlayingScrubKey = @"YTKACE.Preference.Playback.NowPlayingScrubDisabled";
static IMP OriginalRemoteSetEnabled;
static BOOL YTKACERemoteTargetsAdded;

static NSInteger YTKACERemoteSkipInterval(void) {
    if (!YTKACEMasterEnabled()) return 0;
    NSInteger value = [YTKACEPreferenceObject(YTKACERemoteSkipKey) integerValue];
    return value > 0 ? value : 0;
}

static id YTKACERemotePlayer(UIViewController *controller, NSUInteger depth) {
    if (controller == nil || depth > 14) return nil;
    if ([NSStringFromClass(controller.class) isEqualToString:@"YTPlayerViewController"]) {
        SEL current = NSSelectorFromString(@"currentVideoID");
        id value = [controller respondsToSelector:current]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, current) : nil;
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = YTKACERemotePlayer(child, depth + 1);
        if (found != nil) return found;
    }
    return YTKACERemotePlayer(controller.presentedViewController, depth + 1);
}

static MPRemoteCommandHandlerStatus YTKACERemoteSkip(double direction) {
    NSInteger interval = YTKACERemoteSkipInterval();
    if (interval <= 0) return MPRemoteCommandHandlerStatusCommandFailed;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id player = YTKACERemotePlayer(window.rootViewController, 0);
            SEL timeSel = NSSelectorFromString(@"currentVideoMediaTime");
            SEL totalSel = NSSelectorFromString(@"currentVideoTotalMediaTime");
            SEL seekSel = NSSelectorFromString(@"seekToTime:");
            if (player == nil || ![player respondsToSelector:timeSel] || ![player respondsToSelector:seekSel]) continue;
            double time = ((double (*)(id, SEL))objc_msgSend)(player, timeSel) + direction * (double)interval;
            double total = [player respondsToSelector:totalSel]
                ? ((double (*)(id, SEL))objc_msgSend)(player, totalSel) : 0.0;
            if (total > 1.0) time = MIN(time, total - 0.5);
            ((void (*)(id, SEL, double))objc_msgSend)(player, seekSel, MAX(0.0, time));
            return MPRemoteCommandHandlerStatusSuccess;
        }
    }
    return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
}

static BOOL YTKACEIsTrackCommand(id command) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    return command == center.nextTrackCommand || command == center.previousTrackCommand;
}

// Lock screen and Control Center scrubbing, off so it can't be dragged by accident.
static BOOL YTKACENowPlayingScrubOff(void) {
    return YTKACEFeatureEnabled(YTKACENowPlayingScrubKey);
}

// True while the downloads player owns the lock screen controls.
static BOOL YTKACEDownloadRemoteActive;

static void YTKACERemoteSetEnabled(id receiver, SEL selector, BOOL enabled) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    BOOL skipCommand = receiver == center.skipForwardCommand || receiver == center.skipBackwardCommand;
    if (YTKACENowPlayingScrubOff() && receiver == center.changePlaybackPositionCommand) {
        enabled = NO;
    }
    if (YTKACERemoteSkipInterval() > 0) {
        if (YTKACEIsTrackCommand(receiver)) enabled = NO;
        else if (skipCommand) enabled = YES;
    } else if (YTKACEDownloadRemoteActive) {
        // Skip buttons replace next and previous, so keep them off unless
        // Lock Screen Skip is on.
        if (YTKACEIsTrackCommand(receiver)) enabled = YES;
        else if (skipCommand) enabled = NO;
    }
    ((void (*)(id, SEL, BOOL))OriginalRemoteSetEnabled)(receiver, selector, enabled);
}

static void YTKACEConfigureRemoteSkip(void) {
    NSInteger interval = YTKACERemoteSkipInterval();
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    if (YTKACENowPlayingScrubOff()) center.changePlaybackPositionCommand.enabled = NO;
    if (interval > 0 && !YTKACERemoteTargetsAdded) {
        YTKACERemoteTargetsAdded = YES;
        [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return YTKACERemoteSkip(1.0);
        }];
        [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return YTKACERemoteSkip(-1.0);
        }];
    }
    if (!YTKACERemoteTargetsAdded) return;
    center.skipForwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipBackwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipForwardCommand.enabled = interval > 0;
    center.skipBackwardCommand.enabled = interval > 0;
    if (interval > 0) {
        center.nextTrackCommand.enabled = NO;
        center.previousTrackCommand.enabled = NO;
    }
}

static BOOL YTKACERemoteHookInstalled;

static void YTKACEEnsureRemoteHook(void) {
    if (YTKACERemoteHookInstalled) return;
    YTKACERemoteHookInstalled = YES;
    YTKACEInstallInstanceHook(@"MPRemoteCommand", @"setEnabled:",
                              (IMP)YTKACERemoteSetEnabled, &OriginalRemoteSetEnabled);
}

extern "C" void YTKACESetDownloadRemoteActive(BOOL active) {
    YTKACEDownloadRemoteActive = active;
    if (!active) return;
    YTKACEEnsureRemoteHook();
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    NSInteger interval = YTKACERemoteSkipInterval();
    if (interval > 0) {
        center.skipForwardCommand.preferredIntervals = @[@(interval)];
        center.skipBackwardCommand.preferredIntervals = @[@(interval)];
    }
    // The hook picks the right state for each of these.
    center.skipForwardCommand.enabled = YES;
    center.skipBackwardCommand.enabled = YES;
    center.nextTrackCommand.enabled = YES;
    center.previousTrackCommand.enabled = YES;
    center.changePlaybackPositionCommand.enabled = YES;
}

__attribute__((constructor)) static void YTKACEInstallRemoteSkip(void) {
    void (^install)(void) = ^{
        if (!YTKACERemoteHookInstalled &&
            YTKACERemoteSkipInterval() <= 0 && !YTKACENowPlayingScrubOff()) return;
        YTKACEEnsureRemoteHook();
        YTKACEConfigureRemoteSkip();
    };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:YTKACEPreferencesDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        install();
    }];
}
