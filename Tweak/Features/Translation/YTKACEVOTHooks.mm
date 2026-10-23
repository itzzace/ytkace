#import "YTKACEVOTHooks.h"
#import "YTKACEVOTCoordinator.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../Runtime/Localization.h"
#import "../../YTKACE.h"

#import <objc/message.h>

static id YTKACEVOTObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver == nil || ![receiver respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSString *YTKACEVOTVideoIDFromObject(id object) {
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    for (NSString *selector in @[@"videoID", @"videoId", @"currentVideoID", @"identifier"]) {
        id value = YTKACEVOTObjectMessage(object, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id details = YTKACEVOTObjectMessage(object, @"videoDetails");
    if (details != nil && details != object) {
        return YTKACEVOTVideoIDFromObject(details);
    }
    return nil;
}

static double YTKACEVOTDurationFromObject(id object) {
    for (NSString *selector in @[@"totalMediaTime", @"duration", @"videoDuration", @"mediaTime"]) {
        SEL sel = NSSelectorFromString(selector);
        if ([object respondsToSelector:sel]) {
            return ((double (*)(id, SEL))objc_msgSend)(object, sel);
        }
    }
    return 0.0;
}

void YTKACEVOTNotifyDidActivateVideo(id receiver, id playbackController, id video, id playbackData) {
    NSString *videoID = YTKACEVOTVideoIDFromObject(receiver) ?:
                        YTKACEVOTVideoIDFromObject(video) ?:
                        YTKACEVOTVideoIDFromObject(playbackData) ?:
                        YTKACELastVideoID();
    
    double duration = YTKACEVOTDurationFromObject(video) ?:
                      YTKACEVOTDurationFromObject(playbackData) ?:
                      YTKACEVOTDurationFromObject(receiver);

    if (videoID.length > 0) {
        [YTKACEVOTCoordinator.sharedCoordinator videoDidActivateWithID:videoID
                                                              duration:duration
                                                                player:receiver
                                                    playbackController:playbackController
                                                           singleVideo:video];
    }
}

static IMP OriginalSingleVideoMediaState;
static void YTKACEVOTSingleVideoMediaState(id receiver, SEL selector, id singleVideo, NSInteger fromState, NSInteger toState, int reason) {
    if (OriginalSingleVideoMediaState != NULL) {
        ((void (*)(id, SEL, id, NSInteger, NSInteger, int))OriginalSingleVideoMediaState)(
            receiver, selector, singleVideo, fromState, toState, reason
        );
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoMediaStateDidChangeFromState:fromState toState:toState stoppageReason:reason];
}

static IMP OriginalMutatedSingleVideoMediaState;
static void YTKACEVOTMutatedSingleVideoMediaState(id receiver, SEL selector, id singleVideo, NSInteger fromState, NSInteger toState, int reason) {
    if (OriginalMutatedSingleVideoMediaState != NULL) {
        ((void (*)(id, SEL, id, NSInteger, NSInteger, int))OriginalMutatedSingleVideoMediaState)(
            receiver, selector, singleVideo, fromState, toState, reason
        );
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoMediaStateDidChangeFromState:fromState toState:toState stoppageReason:reason];
}

static IMP OriginalSingleVideoPlaybackRate;
static void YTKACEVOTSingleVideoPlaybackRate(id receiver, SEL selector, id singleVideo, float rate) {
    if (OriginalSingleVideoPlaybackRate != NULL) {
        ((void (*)(id, SEL, id, float))OriginalSingleVideoPlaybackRate)(
            receiver, selector, singleVideo, rate
        );
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoPlaybackRateDidChange:rate];
}

static IMP OriginalDidDeactivateVideo;
static void YTKACEVOTDidDeactivateVideo(id receiver, SEL selector, id playbackController, id video) {
    if (OriginalDidDeactivateVideo != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidDeactivateVideo)(receiver, selector, playbackController, video);
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoDidDeactivate];
}

static IMP OriginalDidStopPlayback;
static void YTKACEVOTDidStopPlayback(id receiver, SEL selector, id playbackController, int reason) {
    if (OriginalDidStopPlayback != NULL) {
        ((void (*)(id, SEL, id, int))OriginalDidStopPlayback)(receiver, selector, playbackController, reason);
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoDidDeactivate];
}

static IMP OriginalMiniplayerDidTapClose;
static void YTKACEVOTMiniplayerDidTapClose(id receiver, SEL selector) {
    if (OriginalMiniplayerDidTapClose != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerDidTapClose)(receiver, selector);
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoDidDeactivate];
}

static IMP OriginalMiniplayerDidPressClose;
static void YTKACEVOTMiniplayerDidPressClose(id receiver, SEL selector) {
    if (OriginalMiniplayerDidPressClose != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerDidPressClose)(receiver, selector);
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoDidDeactivate];
}

static IMP OriginalMiniBarDidTapClose;
static void YTKACEVOTMiniBarDidTapClose(id receiver, SEL selector) {
    if (OriginalMiniBarDidTapClose != NULL) {
        ((void (*)(id, SEL))OriginalMiniBarDidTapClose)(receiver, selector);
    }
    [YTKACEVOTCoordinator.sharedCoordinator videoDidDeactivate];
}

void YTKACEVOTNotifyTimeDidChange(id receiver, double time) {
    (void)receiver;
    YTKACEVOTCoordinator *coord = YTKACEVOTCoordinator.sharedCoordinator;
    float rate = coord.lastPlaybackRate;
    if (rate < 0.25f || rate > 5.0f) {
        float saved = [NSUserDefaults.standardUserDefaults floatForKey:@"YTKACE.Preference.Player.SavedRate"];
        if (saved >= 0.25f && saved <= 5.0f) {
            rate = saved;
        } else {
            rate = 1.0f;
        }
        coord.lastPlaybackRate = rate;
    }
    BOOL isPlaying = coord.lastVideoWasPlaying;
    [coord videoPlaybackStateDidChangeIsPlaying:isPlaying rate:rate time:time];
}

void YTKACERouteVOTMenuItem(id actions) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults objectForKey:@"YTKACE.Preference.VOT.Enabled"] ? [defaults boolForKey:@"YTKACE.Preference.VOT.Enabled"] : YES;
    NSInteger placement = [defaults integerForKey:@"YTKACE.Preference.VOT.Placement"]; // 0=overlay, 1=menu, 2=both
    if (!enabled || placement == 0) return;

    if (![actions isKindOfClass:NSMutableArray.class]) return;
    NSMutableArray *actionList = (NSMutableArray *)actions;

    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeSimple = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    if (actionClass == Nil || ![actionClass respondsToSelector:makeSimple]) return;

    // Prevent duplicate entries
    for (id act in actionList) {
        NSString *actTitle = nil;
        if ([act respondsToSelector:NSSelectorFromString(@"title")]) {
            actTitle = ((NSString * (*)(id, SEL))objc_msgSend)(act, NSSelectorFromString(@"title"));
        } else {
            @try {
                actTitle = [act valueForKey:@"title"];
            } @catch (__unused NSException *e) {}
        }
        if ([actTitle containsString:YTKACELocalized(@"Voice-Over Translation")] ||
            [actTitle containsString:YTKACELocalized(@"Disable Translation")]) {
            return;
        }
    }

    UIImage *icon = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightRegular];
        UIImage *rawIcon = [UIImage systemImageNamed:@"waveform.badge.magnifyingglass" withConfiguration:config];
        if (rawIcon == nil) {
            rawIcon = [UIImage systemImageNamed:@"globe" withConfiguration:config];
        }
        if (rawIcon != nil) {
            CGSize targetSize = CGSizeMake(24.0, 24.0);
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = [UIScreen mainScreen].scale;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
            icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                CGFloat scale = MIN(targetSize.width / rawIcon.size.width, targetSize.height / rawIcon.size.height);
                CGFloat w = rawIcon.size.width * scale;
                CGFloat h = rawIcon.size.height * scale;
                CGFloat x = (targetSize.width - w) / 2.0;
                CGFloat y = (targetSize.height - h) / 2.0;
                [rawIcon drawInRect:CGRectMake(x, y, w, h)];
            }];
            icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }

    YTKACEVOTCoordinator *coord = YTKACEVOTCoordinator.sharedCoordinator;
    NSString *title;
    if (coord.currentState == YTKACEVOTStatePlaying || coord.currentState == YTKACEVOTStatePaused) {
        title = YTKACELocalized(@"Disable Translation");
    } else {
        NSString *target = [defaults stringForKey:@"YTKACE.Preference.VOT.TargetLanguage"] ?: @"ru";
        if ([target isEqualToString:@"en"]) {
            title = [NSString stringWithFormat:@"%@ (ENG)", YTKACELocalized(@"Voice-Over Translation")];
        } else if ([target isEqualToString:@"kk"]) {
            title = [NSString stringWithFormat:@"%@ (ҚАЗ)", YTKACELocalized(@"Voice-Over Translation")];
        } else {
            title = [NSString stringWithFormat:@"%@ (РУС)", YTKACELocalized(@"Voice-Over Translation")];
        }
    }

    id votAction = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, makeSimple, title, icon, 0, ^{
            [coord toggleTranslation];
        }
    );
    if (votAction != nil) {
        // Place above "More" / "Ещё"
        NSUInteger insertIndex = actionList.count > 0 ? (actionList.count - 1) : 0;
        for (NSUInteger i = 0; i < actionList.count; i++) {
            id act = actionList[i];
            NSString *actTitle = nil;
            if ([act respondsToSelector:NSSelectorFromString(@"title")]) {
                actTitle = ((NSString * (*)(id, SEL))objc_msgSend)(act, NSSelectorFromString(@"title"));
            } else {
                @try {
                    actTitle = [act valueForKey:@"title"];
                } @catch (__unused NSException *e) {}
            }

            NSString *ident = nil;
            if ([act respondsToSelector:NSSelectorFromString(@"accessibilityIdentifier")]) {
                ident = ((NSString * (*)(id, SEL))objc_msgSend)(act, NSSelectorFromString(@"accessibilityIdentifier"));
            } else {
                @try {
                    ident = [act valueForKey:@"accessibilityIdentifier"];
                } @catch (__unused NSException *e) {}
            }

            NSString *combined = [NSString stringWithFormat:@"%@ %@", actTitle ?: @"", ident ?: @""].lowercaseString;
            if ([combined containsString:@"ещё"] ||
                [combined containsString:@"еще"] ||
                [combined containsString:@"more"] ||
                [combined containsString:@"дополнительно"] ||
                [combined containsString:@"тағы"] ||
                [combined containsString:@"більше"] ||
                [combined containsString:@"mehr"] ||
                [combined containsString:@"plus"] ||
                [combined containsString:@"más"] ||
                [combined containsString:@"mas"]) {
                insertIndex = i;
                break;
            }
        }
        [actionList insertObject:votAction atIndex:insertIndex];
    }
}

void YTKACEInstallTranslationHooks(void) {
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:mediaStateDidChangeFromState:toState:stoppageReason:",
                              (IMP)YTKACEVOTSingleVideoMediaState,
                              &OriginalSingleVideoMediaState);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"potentiallyMutatedSingleVideo:mediaStateDidChangeFromState:toState:stoppageReason:",
                              (IMP)YTKACEVOTMutatedSingleVideoMediaState,
                              &OriginalMutatedSingleVideoMediaState);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:playbackRateDidChange:",
                              (IMP)YTKACEVOTSingleVideoPlaybackRate,
                              &OriginalSingleVideoPlaybackRate);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didDeactivateVideo:",
                              (IMP)YTKACEVOTDidDeactivateVideo,
                              &OriginalDidDeactivateVideo);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didStopPlaybackWithReason:",
                              (IMP)YTKACEVOTDidStopPlayback,
                              &OriginalDidStopPlayback);

    // Miniplayer / Watch dismiss hooks
    YTKACEInstallInstanceHook(@"YTWatchFloatingMiniplayerViewController",
                              @"didTapClose",
                              (IMP)YTKACEVOTMiniplayerDidTapClose,
                              &OriginalMiniplayerDidTapClose);
    YTKACEInstallInstanceHook(@"YTWatchFloatingMiniplayerViewController",
                              @"didPressClose",
                              (IMP)YTKACEVOTMiniplayerDidPressClose,
                              &OriginalMiniplayerDidPressClose);
    YTKACEInstallInstanceHook(@"YTWatchMiniBarViewController",
                              @"didTapClose",
                              (IMP)YTKACEVOTMiniBarDidTapClose,
                              &OriginalMiniBarDidTapClose);

    // Register overlay button in player controls stack
    YTKACERegisterOverlayConfigurator(@"vot", ^(UIView *overlay, UIStackView *stack) {
        (void)overlay;
        YTKACEVOTCoordinator *coordinator = YTKACEVOTCoordinator.sharedCoordinator;
        UIButton *button = YTKACEOverlayButton(
            stack,
            @"YTKACE Translation",
            @"waveform.badge.magnifyingglass",
            coordinator,
            @selector(toggleTranslation)
        );
        coordinator.overlayButton = button;
        [coordinator updateOverlayButton];
    });
}
