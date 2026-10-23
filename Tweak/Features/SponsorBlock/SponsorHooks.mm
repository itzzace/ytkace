#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "../Translation/YTKACEVOTHooks.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"
#import "../../UI/Assets.h"

#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static IMP OriginalDidActivateVideo;
static IMP OriginalSingleVideoTimeChanged;
static IMP OriginalMutatedVideoTimeChanged;
static IMP OriginalPlayerBarLayout;
static IMP OriginalMiniplayerBarLayout;

static const void *YTKACESponsorSegmentsAssociation = &YTKACESponsorSegmentsAssociation;
static const void *YTKACESponsorVideoAssociation = &YTKACESponsorVideoAssociation;
static const void *YTKACESponsorSkippedAssociation = &YTKACESponsorSkippedAssociation;
static const void *YTKACESponsorMarkerAssociation = &YTKACESponsorMarkerAssociation;
static const void *YTKACESponsorRenderedSegmentsAssociation = &YTKACESponsorRenderedSegmentsAssociation;
static const void *YTKACESponsorMarkerBoundsAssociation = &YTKACESponsorMarkerBoundsAssociation;
static const void *YTKACESponsorMarkerDurationAssociation = &YTKACESponsorMarkerDurationAssociation;
static __weak id YTKACECurrentSponsorController;
static NSHashTable<UIView *> *YTKACESponsorBars;
static BOOL YTKACESponsorTimeUpdatesEnabled;
static BOOL YTKACEPlaybackTimeNotificationsNeeded;
static id YTKACEPlaybackPreferenceObserver;

static void YTKACERefreshPlaybackTimePreferenceState(void) {
    YTKACESponsorTimeUpdatesEnabled =
        YTKACEFeatureEnabled(YTKACESponsorBlockKey);
    YTKACEPlaybackTimeNotificationsNeeded =
        YTKACEFeatureEnabled(@"shortsProgress") ||
        YTKACEFeatureEnabled(@"autoSkipShorts") ||
        YTKACEFeatureEnabled(YTKACESpeedKey) ||
        YTKACEFeatureEnabled(YTKACESleepTimerKey) ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.LocalQueue");
}

static void YTKACEPublishPlaybackTime(id receiver, double time) {
    if (!YTKACEPlaybackTimeNotificationsNeeded) return;
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTKACEPlaybackTimeDidChange"
        object:receiver
        userInfo:@{@"time": @(time)}];
}

static id YTKACEObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver == nil || ![receiver respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static double YTKACEDoubleMessage(id receiver, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static NSString *YTKACEVideoIDFromObject(id object) {
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    for (NSString *selector in @[@"videoID", @"videoId", @"currentVideoID", @"identifier"]) {
        id value = YTKACEObjectMessage(object, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id details = YTKACEObjectMessage(object, @"videoDetails");
    if (details != nil && details != object) {
        return YTKACEVideoIDFromObject(details);
    }
    return nil;
}

static BOOL YTKACESponsorFeedbackEnabled(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.SponsorBlock.AudioFeedback");
}

static NSString *YTKACESponsorCategoryTitle(NSString *category) {
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return YTKACELocalized(@"Sponsor");
}

static UIViewController *YTKACETopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void YTKACESeekToTime(id controller, double time) {
    SEL selector = NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(controller, selector, time);
    }
}

static UIVisualEffectView *YTKACESponsorBannerGlass(UIView *banner) {
    for (UIView *subview in banner.subviews) {
        if ([subview isKindOfClass:UIVisualEffectView.class]) return (UIVisualEffectView *)subview;
    }
    return nil;
}

static const void *YTKACESponsorBannerExpired = &YTKACESponsorBannerExpired;

static void YTKACEFadeOutSponsorBanner(UIView *banner) {
    if (banner == nil || banner.superview == nil) return;
    for (UIGestureRecognizer *gesture in banner.gestureRecognizers) {
        if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
            objc_setAssociatedObject(banner, YTKACESponsorBannerExpired, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    }
    UIVisualEffectView *glass = YTKACESponsorBannerGlass(banner);
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformScale(banner.transform, 0.96, 0.96);
        glass.effect = nil;
    } completion:^(__unused BOOL finished) {
        [banner removeFromSuperview];
    }];
}

static void YTKACEFadeInSponsorBanner(UIView *banner) {
    UIVisualEffectView *glass = YTKACESponsorBannerGlass(banner);
    UIVisualEffect *effect = glass.effect;
    [banner.superview layoutIfNeeded];
    banner.alpha = 0.0;
    banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
    glass.effect = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
            glass.effect = effect;
        } completion:nil];
    });
}

@interface YTKACESponsorBannerSwipe : NSObject
+ (instancetype)shared;
- (void)panned:(UIPanGestureRecognizer *)pan;
@end

@implementation YTKACESponsorBannerSwipe
+ (instancetype)shared {
    static YTKACESponsorBannerSwipe *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [YTKACESponsorBannerSwipe new]; });
    return shared;
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    UIView *banner = pan.view;
    CGPoint move = [pan translationInView:banner.superview];
    CGFloat dx = move.x;
    CGFloat dy = MAX(move.y, 0.0);
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGFloat distance = MAX(fabs(dx), dy);
        banner.transform = CGAffineTransformMakeTranslation(dx, dy);
        banner.alpha = MAX(0.2, 1.0 - distance / 160.0);
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
    CGPoint velocity = [pan velocityInView:banner.superview];
    BOOL sideways = fabs(dx) > 70.0 || fabs(velocity.x) > 600.0;
    BOOL down = dy > 30.0 || velocity.y > 400.0;
    if (pan.state == UIGestureRecognizerStateEnded && (sideways || down)) {
        CGAffineTransform away = sideways
            ? CGAffineTransformMakeTranslation((dx < 0 ? -1.0 : 1.0) * banner.superview.bounds.size.width, dy)
            : CGAffineTransformMakeTranslation(dx, dy + 120.0);
        banner.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            banner.transform = away;
            banner.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [banner removeFromSuperview];
        }];
        return;
    }
    if ([objc_getAssociatedObject(banner, YTKACESponsorBannerExpired) boolValue]) {
        YTKACEFadeOutSponsorBanner(banner);
        return;
    }
    [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.75 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        banner.transform = CGAffineTransformIdentity;
        banner.alpha = 1.0;
    } completion:nil];
}
@end

static void YTKACEAddSponsorBannerSwipe(UIView *banner) {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:YTKACESponsorBannerSwipe.shared action:@selector(panned:)];
    pan.cancelsTouchesInView = YES;
    [banner addGestureRecognizer:pan];
}

@interface YTKACESponsorUndoTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, weak) UIView *banner;
- (void)unskip;
@end

@implementation YTKACESponsorUndoTarget
+ (instancetype)sharedTarget {
    static YTKACESponsorUndoTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACESponsorUndoTarget new]; });
    return target;
}
- (void)unskip {
    id controller = self.controller;
    if (controller != nil) {
        YTKACESeekToTime(controller, self.startTime);
    }
    YTKACEFadeOutSponsorBanner(self.banner);
}
@end

static void YTKACEShowSponsorSkippedHUD(id controller, double start, NSString *category) {
    NSInteger notificationMode = YTKACESponsorNotificationMode();
    if (notificationMode == 2) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTKACETopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTKACESponsorUndoTarget *target = YTKACESponsorUndoTarget.sharedTarget;
        YTKACEFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ %@",
                      YTKACESponsorCategoryTitle(category),
                      YTKACELocalized(@"segment skipped")];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
        [undo setTitle:YTKACELocalized(@"Unskip") forState:UIControlStateNormal];
        [undo setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        undo.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [undo addTarget:target action:@selector(unskip)
            forControlEvents:UIControlEventTouchUpInside];
        NSArray *views = notificationMode == 0 ? @[label, undo] : @[label];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:views];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTKACEApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.banner = banner;
        YTKACEAddSponsorBannerSwipe(banner);
        YTKACEFadeInSponsorBanner(banner);
        NSTimeInterval duration = notificationMode == 0
            ? YTKACESponsorUnskipAlertDuration()
            : YTKACESponsorSkipAlertDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(duration * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    YTKACEFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void YTKACEPerformSponsorSkip(id controller, double start, double end,
                                     NSString *category) {
    YTKACESeekToTime(controller, end);
    YTKACEShowSponsorSkippedHUD(controller, start, category);
    if (YTKACESponsorFeedbackEnabled()) {
        AudioServicesPlaySystemSound(1057);
        UINotificationFeedbackGenerator *feedback =
            [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

@interface YTKACESponsorSkipTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, assign) double endTime;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, weak) UIView *banner;
- (void)skip;
@end

@implementation YTKACESponsorSkipTarget
+ (instancetype)sharedTarget {
    static YTKACESponsorSkipTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACESponsorSkipTarget new]; });
    return target;
}
- (void)skip {
    id controller = self.controller;
    [self.banner removeFromSuperview];
    if (controller != nil) {
        YTKACEPerformSponsorSkip(controller, self.startTime, self.endTime, self.category);
    }
}
@end

static void YTKACEAskToSkipSponsor(id controller, double start, double end,
                                   NSString *category) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTKACETopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTKACESponsorSkipTarget *target = YTKACESponsorSkipTarget.sharedTarget;
        YTKACEFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ segment detected",
                      YTKACESponsorCategoryTitle(category)];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
        [skip setTitle:YTKACELocalized(@"Skip") forState:UIControlStateNormal];
        [skip setTitleColor:YTKACEAccentColor() forState:UIControlStateNormal];
        skip.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [skip addTarget:target action:@selector(skip)
            forControlEvents:UIControlEventTouchUpInside];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
            label, skip
        ]];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTKACEApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.endTime = end;
        target.category = category;
        target.banner = banner;
        YTKACEAddSponsorBannerSwipe(banner);
        YTKACEFadeInSponsorBanner(banner);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(YTKACESponsorSkipAlertDuration() * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    YTKACEFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void YTKACEEvaluateSponsorTime(id controller, double time) {
    if (!YTKACESponsorBlockEnabled()) {
        return;
    }

    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation);
    NSMutableSet<NSNumber *> *skipped =
        objc_getAssociatedObject(controller, YTKACESponsorSkippedAssociation);
    if (skipped == nil) {
        skipped = [NSMutableSet set];
        objc_setAssociatedObject(controller,
                                 YTKACESponsorSkippedAssociation,
                                 skipped,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, BOOL *stop) {
            double start = [segment[@"start"] doubleValue];
            double end = [segment[@"end"] doubleValue];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            NSInteger behavior = YTKACESponsorCategoryBehavior(category);
            if (behavior == 2 || behavior == 3) return;
            NSNumber *token = @(index);
            if (time < start - 1.0) {
                [skipped removeObject:token];
            }
            if (time >= start && time < end - 0.25 && ![skipped containsObject:token]) {
                [skipped addObject:token];
                if (behavior == 1) {
                    YTKACEAskToSkipSponsor(controller, start, end, category);
                } else {
                    YTKACEPerformSponsorSkip(controller, start, end, category);
                }
                *stop = YES;
            }
        }];
}

static __weak id YTKACELastPlayerController;

void YTKACEPauseYouTubePlayer(void) {
    id controller = YTKACELastPlayerController;
    SEL pause = NSSelectorFromString(@"pause");
    if ([controller respondsToSelector:pause]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, pause);
    }
}

static void YTKACEDidActivateVideo(id receiver,
                                   SEL selector,
                                   id playbackController,
                                   id video,
                                   id playbackData) {
    if (OriginalDidActivateVideo != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalDidActivateVideo)(
            receiver, selector, playbackController, video, playbackData
        );
    }

    YTKACEOpenPausedVideoActivated(receiver);
    YTKACELastPlayerController = receiver;
    YTKACEVOTNotifyDidActivateVideo(receiver, playbackController, video, playbackData);

    if (!YTKACESponsorBlockEnabled()) {
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorSegmentsAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *videoID =
        YTKACEVideoIDFromObject(receiver) ?:
        YTKACEVideoIDFromObject(video) ?:
        YTKACEVideoIDFromObject(playbackData);
    if (videoID.length == 0) {
        return;
    }

    objc_setAssociatedObject(receiver,
                             YTKACESponsorVideoAssociation,
                             videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorSegmentsAssociation,
                             @[],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorSkippedAssociation,
                             [NSMutableSet set],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACECurrentSponsorController = receiver;

    __weak id weakReceiver = receiver;
    [YTKACESponsorClient.sharedClient segmentsForVideoID:videoID
                                             completion:^(NSArray *segments) {
        id strongReceiver = weakReceiver;
        NSString *current =
            objc_getAssociatedObject(strongReceiver, YTKACESponsorVideoAssociation);
        if (strongReceiver == nil || ![current isEqualToString:videoID]) {
            return;
        }
        objc_setAssociatedObject(strongReceiver,
                                 YTKACESponsorSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *bar in YTKACESponsorBars.allObjects) {
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
        }
    }];
}

static void YTKACESingleVideoTimeChanged(id receiver,
                                         SEL selector,
                                         id video,
                                         double time) {
    if (OriginalSingleVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalSingleVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = YTKACEDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (YTKACESponsorTimeUpdatesEnabled) {
        YTKACEEvaluateSponsorTime(receiver, resolved);
    }
    YTKACEPublishPlaybackTime(receiver, resolved);
    YTKACEVOTNotifyTimeDidChange(receiver, resolved);
}

static void YTKACEMutatedVideoTimeChanged(id receiver,
                                          SEL selector,
                                          id video,
                                          double time) {
    if (OriginalMutatedVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalMutatedVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = YTKACEDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (YTKACESponsorTimeUpdatesEnabled) {
        YTKACEEvaluateSponsorTime(receiver, resolved);
    }
    YTKACEPublishPlaybackTime(receiver, resolved);
    YTKACEVOTNotifyTimeDidChange(receiver, resolved);
}

static BOOL YTKACETrackGeometry(UIView *target, CGFloat *thickness,
                                CGFloat *offset) {
    CGFloat width = CGRectGetWidth(target.bounds);
    if (width <= 0.0) return NO;
    CGFloat bestWidth = 0.0;
    CGFloat bestHeight = 0.0;
    CGFloat bestY = 0.0;
    BOOL found = NO;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:target];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 60) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (node != target && !node.hidden && node.alpha > 0.05) {
            CGRect frame = [node convertRect:node.bounds toView:target];
            CGFloat nodeWidth = CGRectGetWidth(frame);
            CGFloat nodeHeight = CGRectGetHeight(frame);
            if (nodeWidth >= width * 0.55 && nodeHeight > 0.5 && nodeHeight <= 16.0) {
                BOOL better = !found;
                if (!better && nodeWidth > bestWidth + 2.0) better = YES;
                else if (!better && nodeWidth >= bestWidth - 2.0) {
                    if (CGRectGetMinY(frame) > bestY + 0.5) better = YES;
                    else if (fabs(CGRectGetMinY(frame) - bestY) <= 0.5 &&
                             nodeHeight > bestHeight) better = YES;
                }
                if (better) {
                    bestWidth = nodeWidth;
                    bestHeight = nodeHeight;
                    bestY = CGRectGetMinY(frame);
                    found = YES;
                }
            }
        }
        [pending addObjectsFromArray:node.subviews];
    }
    if (!found) return NO;
    *thickness = bestHeight;
    *offset = bestY;
    return YES;
}

static void YTKACERenderSponsorMarkers(UIView *receiver, UIView *target,
                                       BOOL fullHeight) {
    CAShapeLayer *container =
        objc_getAssociatedObject(receiver, YTKACESponsorMarkerAssociation);
    if (container == nil) {
        container = [CAShapeLayer layer];
        container.name = @"YTKACESponsorMarkers";
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorMarkerAssociation,
                                 container,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL reattached = NO;
    if (container.superlayer != target.layer) {
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
        reattached = YES;
    }
    container.frame = target.bounds;
    container.zPosition = 10000.0;

    id controller = YTKACECurrentSponsorController;
    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTKACESponsorSegmentsAssociation);
    double duration = YTKACEDoubleMessage(
        controller,
        @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
          @"currentVideoDuration", @"totalMediaTime"]
    );
    BOOL enabled = YTKACESponsorBlockEnabled() && duration > 0.0 && segments.count != 0;
    container.hidden = !enabled;
    if (!enabled) return;

    CGFloat width = CGRectGetWidth(target.bounds);
    CGFloat height = CGRectGetHeight(target.bounds);
    NSArray *renderedSegments = objc_getAssociatedObject(
        receiver, YTKACESponsorRenderedSegmentsAssociation);
    BOOL rebuild = renderedSegments != segments || container.sublayers.count != segments.count;
    if (rebuild) {
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary<NSString *, id> *segment in segments) {
            CALayer *marker = [CALayer layer];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            marker.backgroundColor = YTKACESponsorCategoryColor(category).CGColor;
            marker.zPosition = 1.0;
            [container addSublayer:marker];
        }
        objc_setAssociatedObject(receiver,
                                 YTKACESponsorRenderedSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat trackThickness = 2.0;
    CGFloat trackOffset = MAX(0.0, height - 2.0);
    if (!fullHeight) {
        CGFloat measured = 0.0;
        CGFloat measuredOffset = 0.0;
        if (YTKACETrackGeometry(target, &measured, &measuredOffset)) {
            trackThickness = measured;
            trackOffset = measuredOffset;
        }
    }
    CGRect previousBounds = [objc_getAssociatedObject(
        receiver, YTKACESponsorMarkerBoundsAssociation) CGRectValue];
    double previousDuration = [objc_getAssociatedObject(
        receiver, YTKACESponsorMarkerDurationAssociation) doubleValue];
    CGRect signature = CGRectMake(CGRectGetWidth(target.bounds),
                                  CGRectGetHeight(target.bounds),
                                  trackThickness, trackOffset);
    if (!rebuild && !reattached && CGRectEqualToRect(previousBounds, signature) &&
        fabs(previousDuration - duration) < 0.001) return;
    objc_setAssociatedObject(receiver,
                             YTKACESponsorMarkerBoundsAssociation,
                             [NSValue valueWithCGRect:signature],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTKACESponsorMarkerDurationAssociation,
                             @(duration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, __unused BOOL *stop) {
        double start = [segment[@"start"] doubleValue];
        double end = MIN([segment[@"end"] doubleValue], duration);
        CALayer *marker = container.sublayers[index];
        marker.hidden = end <= start;
        if (marker.hidden) return;
        CGFloat markerHeight = fullHeight ? MAX(height, 1.0) : trackThickness;
        marker.frame = CGRectMake((CGFloat)(start / duration) * width,
                                  fullHeight ? 0.0 : trackOffset,
                                  MAX(1.0, (CGFloat)((end - start) / duration) * width),
                                  markerHeight);
    }];
    [CATransaction commit];
}

static void YTKACEPlayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPlayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPlayerBarLayout)(receiver, selector);
    }

    YTKACEConfigureTapToSeek(receiver);

    [YTKACESponsorBars addObject:receiver];
    UIView *target = receiver;
    for (UIView *subview in receiver.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTModularPlayerBarView"]) {
            target = subview;
            break;
        }
    }
    YTKACERenderSponsorMarkers(receiver, target, NO);
}

static void YTKACEMiniplayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalMiniplayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerBarLayout)(receiver, selector);
    }
    [YTKACESponsorBars addObject:receiver];
    YTKACEApplyProgressStyleToBar(receiver);
    YTKACERenderSponsorMarkers(receiver, receiver, YES);
}

void YTKACEInstallSponsorBlockHooks(void) {
    if (YTKACESponsorBars == nil) {
        YTKACESponsorBars = [NSHashTable weakObjectsHashTable];
    }
    YTKACERefreshPlaybackTimePreferenceState();
    if (YTKACEPlaybackPreferenceObserver == nil) {
        YTKACEPlaybackPreferenceObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:YTKACEPreferencesDidChangeNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                YTKACERefreshPlaybackTimePreferenceState();
            }];
    }
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didActivateVideo:withPlaybackData:",
                              (IMP)YTKACEDidActivateVideo,
                              &OriginalDidActivateVideo);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:currentVideoTimeDidChange:",
                              (IMP)YTKACESingleVideoTimeChanged,
                              &OriginalSingleVideoTimeChanged);
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:",
                              (IMP)YTKACEMutatedVideoTimeChanged,
                              &OriginalMutatedVideoTimeChanged);
    YTKACEInstallInstanceHook(@"YTInlinePlayerBarContainerView",
                              @"layoutSubviews",
                              (IMP)YTKACEPlayerBarLayout,
                              &OriginalPlayerBarLayout);
    YTKACEInstallInstanceHook(@"YTWatchFloatingMiniplayerProgressBarView",
                              @"layoutSubviews",
                              (IMP)YTKACEMiniplayerBarLayout,
                              &OriginalMiniplayerBarLayout);
}
