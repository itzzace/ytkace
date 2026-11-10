/*
 * Playback error recovery adapted from YTPlaybackFix by Mark02.
 * https://github.com/Mark02-2012/YTPlaybackFix
 *
 * Copyright (c) 2026 Mark02
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPlaybackFixKey = @"YTKACE.Preference.Playback.Fix";
static const NSTimeInterval YTKACEStallGrace = 0.8;
static const double YTKACEProgressEpsilon = 0.15;

static NSString *const YTKACEPlaybackErrorDomain =
    @"com.google.ios.youtube.ErrorDomain.playback";

static double gLatestTime = 0.0;
static BOOL gIsTimeToRetry = NO;
static bool gEmergencyCheckRunning = false;

static IMP OriginalCurrentVideoMediaTime;
static IMP OriginalSeekToTime;
static IMP OriginalHandleError;

NSInteger YTKACEPlaybackFixMode(void) {
    if (!YTKACEMasterEnabled()) return 0;
    id stored = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.FixMode");
    if ([stored respondsToSelector:@selector(integerValue)]) {
        const NSInteger mode = [stored integerValue];
        return mode >= 0 && mode <= 2 ? mode : 0;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.HLSMode")) return 2;
    return YTKACEFeatureEnabled(YTKACEPlaybackFixKey) ? 1 : 0;
}

static BOOL YTKACEPlaybackFixEnabled(void) {
    return YTKACEPlaybackFixMode() == 1;
}

static id YTKACEParentResponder(id overlay) {
    SEL responderGetter = NSSelectorFromString(@"parentResponder");
    if (![overlay respondsToSelector:responderGetter]) {
        YTKACEDownloadLog(@"fix", @"parentResponder unavailable");
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(overlay, responderGetter);
}

static void YTKACESendRetryEvent(id overlay, NSString *stage) {
    id responder = YTKACEParentResponder(overlay);
    if (responder == nil) {
        YTKACEDownloadLog(@"fix", @"%@ no responder", stage);
        return;
    }
    Class eventClass = NSClassFromString(@"YTPlayerTapToRetryResponderEvent");
    SEL factory = NSSelectorFromString(@"eventWithFirstResponder:");
    if (eventClass == Nil || ![eventClass respondsToSelector:factory]) {
        YTKACEDownloadLog(@"fix", @"%@ event class missing", stage);
        return;
    }
    id event = ((id (*)(Class, SEL, id))objc_msgSend)(eventClass, factory,
                                                      responder);
    SEL send = NSSelectorFromString(@"send");
    if (event == nil || ![event respondsToSelector:send]) {
        YTKACEDownloadLog(@"fix", @"%@ event not created", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(event, send);
    YTKACEDownloadLog(@"fix", @"%@ retry event sent to %@", stage,
                      NSStringFromClass([responder class]));
}

static BOOL YTKACEReloadPlayer(id pvc, NSString *stage) {
    SEL activeGetter = NSSelectorFromString(@"activeVideo");
    if (pvc == nil || ![pvc respondsToSelector:activeGetter]) return NO;
    id video = ((id (*)(id, SEL))objc_msgSend)(pvc, activeGetter);
    SEL reloadSel = NSSelectorFromString(@"player:reloadWithContext:");
    SEL mediaGetter = NSSelectorFromString(@"mediaPlayer");
    Class contextClass = NSClassFromString(@"MLPlayerReloadContext");
    SEL contextInit = NSSelectorFromString(
        @"initWithStartPlayback:refreshStreamingData:");
    if (video == nil || contextClass == Nil ||
        ![video respondsToSelector:reloadSel] ||
        ![video respondsToSelector:mediaGetter]) {
        YTKACEDownloadLog(@"fix", @"%@ player reload unavailable on %@", stage,
                          video == nil ? @"nil" : NSStringFromClass([video class]));
        YTKACEDebugLog(@"fix", @"%@ reload pvc=%@ video=%@ reload=%d media=%d context=%d", stage,
                       NSStringFromClass([pvc class]), video ? NSStringFromClass([video class]) : @"nil",
                       [video respondsToSelector:reloadSel], [video respondsToSelector:mediaGetter],
                       contextClass != Nil);
        return NO;
    }
    id allocated = [contextClass alloc];
    if (![allocated respondsToSelector:contextInit]) return NO;
    id context = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
        allocated, contextInit, YES, YES);
    if (context == nil) return NO;
    id media = ((id (*)(id, SEL))objc_msgSend)(video, mediaGetter);
    ((void (*)(id, SEL, id, id))objc_msgSend)(video, reloadSel, media, context);
    YTKACEDownloadLog(@"fix", @"%@ player reload on %@", stage,
                      NSStringFromClass([video class]));
    return YES;
}

static void YTKACESeek(id player, double position, NSString *stage) {
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:seek]) {
        YTKACEDownloadLog(@"fix", @"%@ seek unavailable", stage);
        return;
    }
    ((void (*)(id, SEL, double))objc_msgSend)(player, seek, position);
    YTKACEDownloadLog(@"fix", @"%@ seek %.2f", stage, position);
}


static void YTKACEScheduleCaptionRestore(id player) {
    __weak id weakPlayer = player;
    const double delays[] = { 0.6, 1.5, 3.0 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTKACECaptionsRestore(weakPlayer);
        });
    }
}

static double YTKACEPosition(id player) {
    SEL time = NSSelectorFromString(@"currentVideoMediaTime");
    if (![player respondsToSelector:time]) return -1.0;
    return ((double (*)(id, SEL))objc_msgSend)(player, time);
}

static double YTKACECurrentVideoMediaTime(id receiver, SEL selector) {
    const double value = OriginalCurrentVideoMediaTime == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalCurrentVideoMediaTime)(receiver, selector);
    gLatestTime = value;
    return value;
}

static void YTKACESeekToTime(id receiver, SEL selector, double time) {
    gLatestTime = time;
    if (OriginalSeekToTime != NULL) {
        ((void (*)(id, SEL, double))OriginalSeekToTime)(receiver, selector, time);
    }
}

static void YTKACECallOriginalHandleError(id receiver, SEL selector, id error) {
    if (OriginalHandleError != NULL) {
        ((void (*)(id, SEL, id))OriginalHandleError)(receiver, selector, error);
    }
}

static id YTKACEFixValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

// currentVideoID can be nil while the player is in an error state
static NSString *YTKACEPlayerVideoID(id pvc) {
    NSArray<NSArray<NSString *> *> *paths = @[
        @[@"currentVideoID"], @[@"contentVideoID"], @[@"activeVideo", @"videoID"],
        @[@"contentPlayerResponse", @"playerData", @"videoDetails", @"videoId"],
        @[@"playerResponse", @"playerData", @"videoDetails", @"videoId"]
    ];
    for (NSArray<NSString *> *path in paths) {
        id value = pvc;
        for (NSString *name in path) value = YTKACEFixValue(value, name);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            YTKACEDebugLog(@"hls", @"video id from %@", [path componentsJoinedByString:@"."]);
            return value;
        }
    }
    return nil;
}

static void YTKACEHandleError(id receiver, SEL selector, id error) {
    if (YTKACEPlaybackFixMode() == 2) {
        NSError *hlsError = [error isKindOfClass:NSError.class] ? error : nil;
        YTKACEDownloadLog(@"hls", @"player error domain=%@ code=%ld", hlsError.domain ?: @"-",
                          (long)hlsError.code);
        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter) : nil;
        NSString *videoID = YTKACEPlayerVideoID(pvc);
        const double savedTime = YTKACEPosition(pvc);
        __weak id weakReceiver = receiver;
        __weak id weakPlayer = pvc;
        const BOOL started = YTKACEHLSBeginFallback(videoID, ^(BOOL available) {
                id strongReceiver = weakReceiver;
                id strongPlayer = weakPlayer;
                BOOL switched = NO;
                if (available && strongPlayer != nil) YTKACECaptionsSnapshot(strongPlayer);
                if (available && strongPlayer != nil && YTKACEReloadPlayer(strongPlayer, @"hls fallback")) {
                    YTKACEDownloadLog(@"hls", @"fallback to vision at %.2f", savedTime);
                    switched = YES;
                } else if (available && strongReceiver != nil) {
                    YTKACESendRetryEvent(strongReceiver, @"hls fallback");
                    YTKACEDownloadLog(@"hls", @"fallback to vision at %.2f retry", savedTime);
                    switched = YES;
                }
                if (switched) {
                    // pick up where the failed stream stopped
                    if (strongPlayer != nil && savedTime > 1.0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            YTKACESeek(weakPlayer, savedTime, @"hls fallback");
                            YTKACEScheduleCaptionRestore(weakPlayer);
                        });
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            const double now = YTKACEPosition(weakPlayer);
                            YTKACEDownloadLog(@"hls", @"fallback verify saved=%.2f now=%.2f", savedTime, now);
                            if (now >= 0 && now < savedTime - 2.0) YTKACESeek(weakPlayer, savedTime, @"hls verify");
                        });
                    }
                    return;
                }
                YTKACEDownloadLog(@"hls", @"fallback unavailable video=%@", videoID);
                if (strongReceiver != nil) YTKACECallOriginalHandleError(strongReceiver, selector, error);
            });
        if (started) return;
        YTKACECallOriginalHandleError(receiver, selector, error);
        return;
    }
    if (!YTKACEPlaybackFixEnabled()) {
        YTKACECallOriginalHandleError(receiver, selector, error);
        return;
    }

    if (gIsTimeToRetry) {
        YTKACEDownloadLog(@"fix", @"retry already in flight, passing through");
        YTKACECallOriginalHandleError(receiver, selector, error);
        return;
    }

    NSError *failure = [error isKindOfClass:NSError.class] ? (NSError *)error : nil;
    if (failure != nil) {
        YTKACEDownloadLog(@"fix", @"handleError domain=%@ code=%ld",
                          failure.domain, (long)failure.code);
    } else {
        YTKACEDownloadLog(@"fix", @"handleError non-NSError %@",
                          NSStringFromClass([error class]));
    }

    if (failure != nil &&
        [failure.domain isEqualToString:YTKACEPlaybackErrorDomain] &&
        (failure.code == 14 || failure.code == 0)) {
        gIsTimeToRetry = YES;

        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter)
            : nil;
        const double savedTime = gLatestTime;
        YTKACEDownloadLog(@"fix", @"intercepted code=%ld at %.2f parent=%@",
                          (long)failure.code, savedTime,
                          pvc == nil ? @"nil" : NSStringFromClass([pvc class]));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(YTKACEStallGrace * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            const double moved = YTKACEPosition(pvc);
            if (moved > savedTime + YTKACEProgressEpsilon) {
                gIsTimeToRetry = NO;
                YTKACEDownloadLog(@"fix", @"still playing %.2f -> %.2f, no retry",
                                  savedTime, moved);
                return;
            }
            YTKACEDownloadLog(@"fix", @"stalled at %.2f, retrying", savedTime);
            YTKACECaptionsSnapshot(pvc);
            if (!YTKACEReloadPlayer(pvc, @"primary")) {
                YTKACESendRetryEvent(receiver, @"primary");
            }

            if (pvc) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.20 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    YTKACESeek(pvc, savedTime, @"primary");

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.10 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        YTKACEScheduleCaptionRestore(pvc);

                        if (!gEmergencyCheckRunning) {
                            gEmergencyCheckRunning = true;

                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(3.00 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                const double currentTime = YTKACEPosition(pvc);
                                YTKACEDownloadLog(@"fix",
                                    @"verify saved=%.2f now=%.2f", savedTime,
                                    currentTime);

                                if (currentTime <= savedTime + 0.05) {
                                    YTKACEDownloadLog(@"fix", @"still stalled");
                                    if (!YTKACEReloadPlayer(pvc, @"emergency")) {
                                        YTKACESendRetryEvent(receiver, @"emergency");
                                    }
                                    YTKACESeek(pvc, savedTime, @"emergency");

                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                                 (int64_t)(0.20 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        YTKACEScheduleCaptionRestore(pvc);
                                        gIsTimeToRetry = NO;
                                        YTKACEDownloadLog(@"fix", @"emergency done");
                                    });
                                } else {
                                    gIsTimeToRetry = NO;
                                    YTKACEDownloadLog(@"fix", @"recovered");
                                }

                                gEmergencyCheckRunning = false;
                            });
                        } else {
                            YTKACEDownloadLog(@"fix", @"emergency check busy");
                        }
                    });
                });
            } else {
                gIsTimeToRetry = NO;
                YTKACEDownloadLog(@"fix", @"no parent view controller");
            }
        });

        return;
    }

    YTKACECallOriginalHandleError(receiver, selector, error);
}

void YTKACEInstallPlaybackFixHooks(void) {
    const BOOL time = YTKACEInstallInstanceHook(
        @"YTPlayerViewController", @"currentVideoMediaTime",
        (IMP)YTKACECurrentVideoMediaTime, &OriginalCurrentVideoMediaTime);
    const BOOL seek = YTKACEInstallInstanceHook(
        @"YTPlayerViewController", @"seekToTime:",
        (IMP)YTKACESeekToTime, &OriginalSeekToTime);
    const BOOL handle = YTKACEInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"handleError:",
        (IMP)YTKACEHandleError, &OriginalHandleError);
    YTKACEDownloadLog(@"fix", @"hooks time=%d seek=%d handle=%d enabled=%d",
                      time, seek, handle, YTKACEPlaybackFixEnabled());
}
