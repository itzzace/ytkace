#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetActiveCaptionTrack;
static IMP OriginalSetSingleVideoCaptionTrack;
static IMP OriginalSetCaptionError;
static IMP OriginalSetLocalCaptionTrack;
static IMP OriginalSetMDXCaptionTrack;
static BOOL YTKACEHasRememberedSource;
static NSMutableSet<NSString *> *YTKACEAppliedKeys;
static NSMutableDictionary<NSString *, NSNumber *> *YTKACERestoredAt;
static const NSTimeInterval YTKACERestoreWindow = 4.0;
static NSMutableSet<NSString *> *YTKACEFailedKeys;
static NSString *YTKACELastAppliedKey;

static BOOL YTKACECaptionKeyFailed(NSString *key) {
    if (key.length == 0 || YTKACEFailedKeys == nil) return NO;
    @synchronized (YTKACEFailedKeys) {
        return [YTKACEFailedKeys containsObject:key];
    }
}

static void YTKACENoteCaptionFailure(NSString *key) {
    if (key.length == 0) return;
    if (YTKACEFailedKeys == nil) {
        YTKACEFailedKeys = [NSMutableSet set];
    }
    @synchronized (YTKACEFailedKeys) {
        if (YTKACEFailedKeys.count >= 128) {
            [YTKACEFailedKeys removeAllObjects];
        }
        [YTKACEFailedKeys addObject:key];
    }
}

static NSString *YTKACECurrentVideoID(id player) {
    SEL selector = NSSelectorFromString(@"currentVideoID");
    if (![player respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(player, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSTimeInterval YTKACECaptionBackoffUntil;

static __weak id YTKACERememberedTrack;
static NSString *YTKACERememberedVSSID;
static NSString *YTKACERememberedLanguage;
static long long YTKACERememberedSource;
static BOOL YTKACEHasRememberedTrack;

static NSString *YTKACECaptionString(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (track == nil || ![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTKACECaptionValueForKey(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void YTKACERememberTrack(id track, long long source) {
    YTKACERememberedTrack = track;
    YTKACERememberedVSSID = [YTKACECaptionString(track, @"VSSID") copy];
    YTKACERememberedLanguage = [YTKACECaptionString(track, @"languageCode") copy];
    YTKACERememberedSource = source;
    YTKACEHasRememberedSource = YES;
    YTKACEHasRememberedTrack = YES;
}

static void YTKACESetActiveCaptionTrack(id receiver,
                                        SEL selector,
                                        id track,
                                        long long source) {
    YTKACEDownloadLog(@"caption", @"app set track=%@ source=%lld class=%@",
                      YTKACECaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track != nil) {
        YTKACERememberTrack(track, source);
    } else {
        YTKACEHasRememberedTrack = NO;
        YTKACERememberedTrack = nil;
        YTKACERememberedVSSID = nil;
        YTKACERememberedLanguage = nil;
    }
    if (OriginalSetActiveCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetActiveCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTKACESetSingleVideoCaptionTrack(id receiver,
                                             SEL selector,
                                             id track,
                                             long long source) {
    YTKACEDownloadLog(@"caption", @"single set track=%@ source=%lld class=%@",
                      YTKACECaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track != nil) {
        YTKACERememberTrack(track, source);
    }
    if (OriginalSetSingleVideoCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetSingleVideoCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTKACESetCaptionError(id receiver, SEL selector, id error) {
    if (error != nil) {
        NSError *value = [error isKindOfClass:NSError.class] ? error : nil;
        YTKACEDownloadLog(@"caption",
                          @"ERROR domain=%@ code=%ld desc=%@ class=%@",
                          value.domain ?: @"?", (long)value.code,
                          value.localizedDescription ?: [error description],
                          NSStringFromClass(object_getClass(receiver)));
        if (value.code == 429) {
            YTKACENoteCaptionFailure(YTKACELastAppliedKey);
            YTKACECaptionBackoffUntil = CACurrentMediaTime() + 30;
            YTKACEDownloadLog(@"caption",
                              @"429 cooldown 30s blamed=%@",
                              YTKACELastAppliedKey ?: @"nil");
        }
    }
    if (OriginalSetCaptionError != NULL) {
        ((void (*)(id, SEL, id))OriginalSetCaptionError)(receiver, selector,
                                                        error);
    }
}

static void YTKACESetLocalCaptionTrack(id receiver, SEL selector, id track,
                                       long long source) {
    YTKACEDownloadLog(@"caption", @"local set track=%@ source=%lld class=%@",
                      YTKACECaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetLocalCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetLocalCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTKACESetMDXCaptionTrack(id receiver, SEL selector, id track,
                                     long long source) {
    YTKACEDownloadLog(@"caption", @"mdx set track=%@ source=%lld class=%@",
                      YTKACECaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetMDXCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetMDXCaptionTrack)(
            receiver, selector, track, source);
    }
}

static id YTKACEMatchingTrack(id player) {
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id available = YTKACECaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTKACECaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class]) return YTKACERememberedTrack;
    for (id track in (NSArray *)available) {
        NSString *vssID = YTKACECaptionString(track, @"VSSID");
        if (YTKACERememberedVSSID.length != 0 &&
            [vssID isEqualToString:YTKACERememberedVSSID]) {
            return track;
        }
    }
    for (id track in (NSArray *)available) {
        NSString *language = YTKACECaptionString(track, @"languageCode");
        if (YTKACERememberedLanguage.length != 0 &&
            [language isEqualToString:YTKACERememberedLanguage]) {
            return track;
        }
    }
    return YTKACERememberedTrack;
}


static NSString *const YTKACEPreferredLanguageKey =
    @"YTKACE.Preference.Playback.CaptionLanguage";

static NSString *YTKACETrackLanguage(id track) {
    id value = YTKACECaptionValueForKey(track, @"languageCode");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

void YTKACEApplyPreferredCaptionLanguage(id player) {
    if (YTKACECaptionsMode() == 2) return;
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:YTKACEPreferredLanguageKey];
    if (preferred.length == 0) return;

    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id available = YTKACECaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTKACECaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class] || [available count] == 0) {
        return;
    }
    id active = YTKACECaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil &&
        [YTKACETrackLanguage(active) hasPrefix:preferred]) {
        return;
    }

    if (YTKACECaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < YTKACECaptionBackoffUntil) {
        return;
    }

    NSString *videoID = nil;
    SEL videoIDSel = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:videoIDSel]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, videoIDSel);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    NSString *appliedKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, preferred] : nil;
    if (YTKACEAppliedKeys == nil) {
        YTKACEAppliedKeys = [NSMutableSet set];
    }
    if (appliedKey != nil && [YTKACEAppliedKeys containsObject:appliedKey]) {
        return;
    }
    if (YTKACECaptionKeyFailed(appliedKey)) {
        YTKACEDownloadLog(@"caption", @"skip known-failed %@", appliedKey);
        return;
    }

    id exact = nil;
    NSInteger exactRank = NSIntegerMax;
    id prefix = nil;
    NSMutableArray<NSString *> *vssList = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        NSString *code = YTKACETrackLanguage(track);
        if (code.length == 0) continue;
        NSString *vss = YTKACECaptionString(track, @"VSSID") ?: @"";
        if ([code caseInsensitiveCompare:preferred] == NSOrderedSame) {
            [vssList addObject:vss.length != 0 ? vss : @"-"];
            NSInteger rank = 2;
            if ([vss hasPrefix:@"."]) {
                rank = 0;
            } else if ([vss hasPrefix:@"a."]) {
                rank = 1;
            }
            if (rank < exactRank) {
                exactRank = rank;
                exact = track;
            }
            continue;
        }
        if (prefix == nil && [code.lowercaseString
                hasPrefix:preferred.lowercaseString]) {
            prefix = track;
        }
    }
    if (vssList.count > 1) {
        YTKACEDownloadLog(@"caption", @"candidates %@ picked rank=%ld",
                          [vssList componentsJoinedByString:@","],
                          (long)exactRank);
    }
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        [codes addObject:YTKACETrackLanguage(track) ?: @"?"];
    }
    YTKACEDownloadLog(@"caption",
                      @"apply preferred=%@ count=%lu tracks=%@ active=%@ "
                       "haveSource=%d source=%lld",
                      preferred, (unsigned long)[available count],
                      [codes componentsJoinedByString:@","],
                      YTKACETrackLanguage(active) ?: @"nil",
                      YTKACEHasRememberedSource, YTKACERememberedSource);

    id chosen = exact ?: prefix;
    if (chosen == nil) {
        YTKACEDownloadLog(@"caption",
                          @"no usable track for %@ translatedOnly=%@",
                          preferred,
                          vssList.count != 0
                            ? [vssList componentsJoinedByString:@","] : @"-");
        return;
    }
    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (appliedKey != nil) {
        if (YTKACEAppliedKeys.count >= 64) {
            [YTKACEAppliedKeys removeAllObjects];
        }
        [YTKACEAppliedKeys addObject:appliedKey];
        YTKACELastAppliedKey = appliedKey;
    }
    const long long applySource = 3;
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, chosen, applySource);
    YTKACEDownloadLog(@"caption",
                      @"applied preferred=%@ chosen=%@ vss=%@ exact=%d "
                       "source=%lld video=%@",
                      preferred, YTKACETrackLanguage(chosen) ?: @"?",
                      YTKACECaptionString(chosen, @"VSSID") ?: @"-",
                      exact != nil, applySource,
                      videoID ?: @"?");
}

void YTKACECaptionsSnapshot(id player) {
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id active = YTKACECaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil) {
        YTKACERememberTrack(active, YTKACERememberedSource);
    }
}

void YTKACECaptionsRestore(id player) {
    if (!YTKACEHasRememberedTrack) return;
    if (YTKACECaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < YTKACECaptionBackoffUntil) {
        return;
    }
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    if (YTKACECaptionValueForKey(video, @"activeCaptionTrack") != nil) return;

    id track = YTKACEMatchingTrack(player);
    if (track == nil) return;

    NSString *videoID = YTKACECurrentVideoID(player);
    NSString *language = YTKACECaptionString(track, @"languageCode") ?: @"?";
    NSString *restoreKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, language] : nil;
    if (YTKACERestoredAt == nil) {
        YTKACERestoredAt = [NSMutableDictionary dictionary];
    }
    const NSTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRestore = restoreKey != nil ? YTKACERestoredAt[restoreKey] : nil;
    if (lastRestore != nil && now - lastRestore.doubleValue < YTKACERestoreWindow) {
        return;
    }
    if (YTKACECaptionKeyFailed(restoreKey)) return;

    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (restoreKey != nil) {
        if (YTKACERestoredAt.count >= 64) {
            [YTKACERestoredAt removeAllObjects];
        }
        YTKACERestoredAt[restoreKey] = @(now);
        YTKACELastAppliedKey = restoreKey;
    }
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, track, YTKACERememberedSource);
    YTKACEDownloadLog(@"fix", @"captions restored %@ video=%@", language,
                      videoID ?: @"?");
}

void YTKACEInstallCaptionHooks(void) {
    BOOL pvc = YTKACEInstallInstanceHook(@"YTPlayerViewController",
                                        @"setActiveCaptionTrack:source:",
                                        (IMP)YTKACESetActiveCaptionTrack,
                                        &OriginalSetActiveCaptionTrack);
    BOOL svc = YTKACEInstallInstanceHook(
        @"YTSingleVideoController", @"setActiveCaptionTrack:source:",
        (IMP)YTKACESetSingleVideoCaptionTrack,
        &OriginalSetSingleVideoCaptionTrack);
    BOOL err = YTKACEInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"setCaptionError:",
        (IMP)YTKACESetCaptionError, &OriginalSetCaptionError);
    BOOL loc = YTKACEInstallInstanceHook(
        @"YTLocalPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)YTKACESetLocalCaptionTrack, &OriginalSetLocalCaptionTrack);
    BOOL mdx = YTKACEInstallInstanceHook(
        @"MDXPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)YTKACESetMDXCaptionTrack, &OriginalSetMDXCaptionTrack);
    YTKACEDownloadLog(@"caption",
                      @"hooks pvc=%d single=%d error=%d local=%d mdx=%d",
                      pvc, svc, err, loc, mdx);
}
