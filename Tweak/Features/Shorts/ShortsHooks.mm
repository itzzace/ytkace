#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSHashTable<UIView *> *YTKACEReelViews;
static NSMutableDictionary<NSString *, NSValue *> *YTKACEShortsOriginals;
static NSMutableSet<NSString *> *YTKACEShortsInstalledHooks;
static const void *YTKACEShortsTrackAssociation = &YTKACEShortsTrackAssociation;
static const void *YTKACEShortsFillAssociation = &YTKACEShortsFillAssociation;
static const void *YTKACEShortsSkipAssociation = &YTKACEShortsSkipAssociation;
static const void *YTKACEShortsLastTimeAssociation = &YTKACEShortsLastTimeAssociation;
static const void *YTKACEShortsDownloadAssociation = &YTKACEShortsDownloadAssociation;
static const void *YTKACEShortsHiddenAssociation = &YTKACEShortsHiddenAssociation;
static const void *YTKACEShortsDownloadConstraintsAssociation =
    &YTKACEShortsDownloadConstraintsAssociation;
static const void *YTKACEShortsDownloadAnchoredAssociation =
    &YTKACEShortsDownloadAnchoredAssociation;
static const void *YTKACEShortsRailTransformAssociation =
    &YTKACEShortsRailTransformAssociation;
static const void *YTKACEShortsInitialRefreshAssociation =
    &YTKACEShortsInitialRefreshAssociation;
static NSInteger const YTKACEShortsDownloadTag = 0x59544B44;
static double YTKACELastShortsTime;
static double YTKACELastShortsDuration;
static id YTKACELatestShortsPlayerResponse;

static void YTKACEReelLayout(UIView *receiver, SEL selector);
static void YTKACEReelOverlayLayout(UIView *receiver, SEL selector);
static void YTKACEShortsControllerLayout(UIViewController *receiver,
                                         SEL selector);
static void YTKACEPausedLayout(UIView *receiver, SEL selector);
static void YTKACEInteractiveStickerLayout(UIView *receiver, SEL selector);
static NSArray<NSArray<NSString *> *> *YTKACEShortsRules(void);

static void YTKACESetShortsHidden(UIView *view, BOOL hidden) {
    NSNumber *owned = objc_getAssociatedObject(
        view, YTKACEShortsHiddenAssociation);
    if (hidden) {
        if (owned == nil) {
            objc_setAssociatedObject(view, YTKACEShortsHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (owned != nil) {
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, YTKACEShortsHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTKACEAnyShortsActionHidden(void) {
    for (NSArray<NSString *> *rule in YTKACEShortsRules()) {
        if (YTKACEFeatureEnabled(rule.firstObject)) return YES;
    }
    return NO;
}

static NSArray<NSArray<NSString *> *> *YTKACEShortsRules(void) {
    static NSArray<NSArray<NSString *> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"YTKACE.Preference.Shorts.RemixHidden", @"id.reel_remix_button"],
            @[@"YTKACE.Preference.Shorts.SoundHidden", @"id.reel_pivot_button"],
            @[@"YTKACE.Preference.Shorts.ShareHidden", @"id.reel_share_button"],
            @[@"YTKACE.Preference.Shorts.CommentsHidden", @"id.reel_comment_button"],
            @[@"YTKACE.Preference.Shorts.LikeHidden", @"id.reel_like_button"],
            @[@"YTKACE.Preference.Shorts.SaveHidden"]
        ];
    });
    return rules;
}

typedef struct {
    CGFloat minX;
    CGFloat width;
    CGFloat height;
    BOOL valid;
} YTKACERailMetrics;

static BOOL YTKACEIsIdentifiedRailButton(NSString *identifier) {
    return [identifier hasPrefix:@"id.reel_"] &&
        [identifier hasSuffix:@"_button"];
}

static void YTKACECollectRailMetrics(UIView *view,
                                     UIView *root,
                                     YTKACERailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (YTKACEIsIdentifiedRailButton(identifier)) {
        CGRect frame = [view convertRect:view.bounds toView:root];
        if (CGRectGetWidth(frame) > 32.0 && CGRectGetHeight(frame) > 32.0) {
            metrics->minX = CGRectGetMinX(frame);
            metrics->width = CGRectGetWidth(frame);
            metrics->height = CGRectGetHeight(frame);
            metrics->valid = YES;
        }
    }
    for (UIView *child in view.subviews) {
        YTKACECollectRailMetrics(child, root, metrics);
    }
}

static BOOL YTKACEShortsIsSaveButton(UIView *view,
                                     UIView *root,
                                     const YTKACERailMetrics *metrics) {
    if (metrics == NULL || !metrics->valid) return NO;
    if (view.accessibilityIdentifier.length != 0) return NO;
    if (view.accessibilityLabel.length == 0) return NO;
    if (view.tag == YTKACEShortsDownloadTag) return NO;
    CGRect frame = [view convertRect:view.bounds toView:root];
    return fabs(CGRectGetMinX(frame) - metrics->minX) < 6.0 &&
        fabs(CGRectGetWidth(frame) - metrics->width) < 8.0 &&
        fabs(CGRectGetHeight(frame) - metrics->height) < 14.0;
}

static BOOL YTKACEShortsActionHidden(UIView *view,
                                     UIView *root,
                                     const YTKACERailMetrics *metrics) {
    if (view.tag == YTKACEShortsDownloadTag ||
        [view.accessibilityIdentifier hasPrefix:@"YTKACE"]) {
        return NO;
    }
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    BOOL actionable = [view isKindOfClass:UIControl.class] ||
        view.accessibilityIdentifier.length != 0 ||
        view.accessibilityLabel.length != 0;
    if (!actionable) return NO;
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SaveHidden") &&
        YTKACEShortsIsSaveButton(view, root, metrics)) {
        return YES;
    }
    for (NSArray<NSString *> *rule in YTKACEShortsRules()) {
        if (!YTKACEFeatureEnabled(rule.firstObject)) continue;
        for (NSUInteger index = 1; index < rule.count; index++) {
            NSString *needle = rule[index];
            if (identifier.length != 0 && [identifier containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}

static void YTKACEApplyShortsVisibilityWalk(UIView *view,
                                            UIView *root,
                                            const YTKACERailMetrics *metrics) {
    YTKACESetShortsHidden(view, YTKACEShortsActionHidden(view, root, metrics));
    for (UIView *subview in view.subviews) {
        YTKACEApplyShortsVisibilityWalk(subview, root, metrics);
    }
}

static void YTKACEApplyShortsActionVisibility(UIView *view) {
    YTKACERailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTKACECollectRailMetrics(view, view, &metrics);
    YTKACEApplyShortsVisibilityWalk(view, view, &metrics);
}

static BOOL YTKACEIsShortsActionIdentifier(NSString *identifier) {
    return [identifier isEqualToString:@"id.reel_like_button"] ||
        [identifier isEqualToString:@"id.reel_comment_button"] ||
        [identifier isEqualToString:@"id.reel_share_button"] ||
        [identifier isEqualToString:@"id.reel_remix_button"] ||
        [identifier isEqualToString:@"id.reel_pivot_button"];
}

static BOOL YTKACEIsShortsActionView(UIView *view, UIView *root,
                                     const YTKACERailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (identifier.length != 0) {
        return YTKACEIsShortsActionIdentifier(identifier);
    }
    return YTKACEShortsIsSaveButton(view, root, metrics);
}

static BOOL YTKACEActionIsFullyVisible(UIView *view, UIView *root) {
    CGRect frame = [view convertRect:view.bounds toView:root];
    return CGRectGetWidth(frame) > 20.0 &&
        CGRectGetHeight(frame) > 20.0 &&
        CGRectGetMidX(frame) > CGRectGetWidth(root.bounds) * 0.55 &&
        CGRectGetMinY(frame) >= 0.0 &&
        CGRectGetMaxY(frame) <= CGRectGetHeight(root.bounds);
}

static UIView *YTKACEShortsPlaybackOverlay(UIView *view, UIView *root) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                containsString:@"ReelWatchPlaybackOverlayView"]) {
            return candidate;
        }
        if (candidate == root) break;
    }
    CGSize full = root.bounds.size;
    for (UIView *candidate = view.superview; candidate != nil && candidate != root;
         candidate = candidate.superview) {
        CGSize size = candidate.bounds.size;
        if (size.width >= full.width * 0.9 && size.height >= full.height * 0.6) return candidate;
    }
    return nil;
}

static void YTKACECollectShortsActionsWalk(UIView *view,
                                           UIView *root,
                                           BOOL includeHidden,
                                           const YTKACERailMetrics *metrics,
                                           NSMutableArray<UIView *> *views) {
    if (view.tag != YTKACEShortsDownloadTag &&
        (includeHidden || (!view.hidden && view.alpha > 0.05)) &&
        YTKACEIsShortsActionView(view, root, metrics) &&
        YTKACEActionIsFullyVisible(view, root)) {
        [views addObject:view];
    }
    for (UIView *subview in view.subviews) {
        YTKACECollectShortsActionsWalk(subview, root, includeHidden, metrics, views);
    }
}

static void YTKACECollectShortsActions(UIView *view,
                                       UIView *root,
                                       BOOL includeHidden,
                                       NSMutableArray<UIView *> *views) {
    YTKACERailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTKACECollectRailMetrics(root, root, &metrics);
    YTKACECollectShortsActionsWalk(view, root, includeHidden, &metrics, views);
}

static UIView *YTKACEVisibleShortsAction(UIView *root) {
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, NO, actions);
    NSString *expected = nil;
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LikeHidden")) {
        expected = @"id.reel_like_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.CommentsHidden")) {
        expected = @"id.reel_comment_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.ShareHidden")) {
        expected = @"id.reel_share_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.RemixHidden")) {
        expected = @"id.reel_remix_button";
    } else if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SoundHidden")) {
        expected = @"id.reel_pivot_button";
    }
    if (expected == nil) return nil;
    for (UIView *action in actions) {
        if (YTKACEShortsPlaybackOverlay(action, root) == nil) continue;
        if ([action.accessibilityIdentifier.lowercaseString
                isEqualToString:expected]) {
            return action;
        }
    }
    return nil;
}

static UIView *YTKACEVisibleShortsPlaybackOverlay(UIView *root) {
    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"ReelWatchPlaybackOverlayView"] &&
        root.window != nil && !root.hidden && root.alpha > 0.05 &&
        CGRectGetWidth(root.bounds) > 200.0 &&
        CGRectGetHeight(root.bounds) > 300.0) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *overlay = YTKACEVisibleShortsPlaybackOverlay(subview);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static UIView *YTKACECurrentShortsPlaybackOverlay(UIView *root) {
    UIView *visibleOverlay = YTKACEVisibleShortsPlaybackOverlay(root);
    if (visibleOverlay != nil) return visibleOverlay;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        UIView *overlay = YTKACEShortsPlaybackOverlay(action, root);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static void YTKACECompactShortsRail(UIView *root) {
    if (!YTKACEAnyShortsActionHidden()) return;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTKACECollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTKACEShortsRailTransformAssociation);
        if (baselineValue == nil) {
            baselineValue = [NSValue valueWithCGAffineTransform:action.transform];
            objc_setAssociatedObject(action,
                YTKACEShortsRailTransformAssociation, baselineValue,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        action.transform = baselineValue.CGAffineTransformValue;
    }
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTKACEShortsRailTransformAssociation);
        CGFloat offset = 0.0;
        if (!action.hidden) {
            CGFloat actionY = CGRectGetMinY(
                [action convertRect:action.bounds toView:root]);
            for (UIView *candidate in actions) {
                if (!candidate.hidden) continue;
                CGFloat hiddenY = CGRectGetMinY(
                    [candidate convertRect:candidate.bounds toView:root]);
                if (hiddenY > actionY) {
                    offset += 64.0;
                }
            }
        }
        action.transform = CGAffineTransformTranslate(
            baselineValue.CGAffineTransformValue, 0.0, offset);
    }
}

static void YTKACEPositionShortsDownload(UIView *host,
                                         UIView *action,
                                         UIButton *download) {
    NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(
        download, YTKACEShortsDownloadConstraintsAssociation);
    NSInteger position = [NSUserDefaults.standardUserDefaults
        integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"];
    BOOL legacyHost = [NSStringFromClass(host.class) containsString:@"ReelWatchPlaybackOverlayView"];
    if (position == 0 && !legacyHost) {
        if (constraints.count != 0) [NSLayoutConstraint deactivateConstraints:constraints];
        download.translatesAutoresizingMaskIntoConstraints = YES;
        UIEdgeInsets safe = host.safeAreaInsets;
        download.frame = CGRectMake(round(CGRectGetWidth(host.bounds) - safe.right - 12.0 - 36.0),
                                    round(safe.top + 65.0), 36.0, 36.0);
        download.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        return;
    }
    if (position == 0) {
        if (download.translatesAutoresizingMaskIntoConstraints) {
            download.translatesAutoresizingMaskIntoConstraints = NO;
        }
        if (constraints == nil) {
            constraints = @[
                [download.widthAnchor constraintEqualToConstant:36.0],
                [download.heightAnchor constraintEqualToConstant:36.0],
                [download.trailingAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
                [download.topAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.topAnchor constant:65.0]
            ];
            objc_setAssociatedObject(download,
                YTKACEShortsDownloadConstraintsAssociation,
                constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [host layoutIfNeeded];
        return;
    }

    if (constraints.count != 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    download.translatesAutoresizingMaskIntoConstraints = YES;
    CGFloat centerX = CGRectGetWidth(host.bounds) - 32.0;
    CGFloat top = host.safeAreaInsets.top + 65.0;
    if (action == nil && !CGRectIsEmpty(download.frame) &&
        CGRectGetWidth(download.frame) >= 35.0) {
        return;
    }
    if (action != nil) {
        CGRect frame = [action convertRect:action.bounds toView:host];
        centerX = CGRectGetMidX(frame);
        top = CGRectGetMinY(frame) - 48.0;
    }
    top = MAX(host.safeAreaInsets.top + 52.0, top);
    download.frame = CGRectMake(round(centerX - 18.0), round(top), 36.0, 36.0);
    download.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
}

static NSString *YTKACEShortsHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEShortsOriginal(id receiver, SEL selector,
                                NSUInteger ordinal) {
    NSUInteger candidate = 0;
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTKACEShortsOriginals[
            YTKACEShortsHookKey(cls, selector)] pointerValue];
        if (original != NULL &&
            original != (IMP)YTKACEReelLayout &&
            original != (IMP)YTKACEReelOverlayLayout &&
            original != (IMP)YTKACEShortsControllerLayout &&
            original != (IMP)YTKACEPausedLayout &&
            original != (IMP)YTKACEInteractiveStickerLayout) {
            if (candidate == ordinal) {
                return original;
            }
            candidate++;
        }
    }
    return NULL;
}

static void YTKACEInvokeShortsOriginal(id receiver, SEL selector) {
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSString *depthKey = [NSString stringWithFormat:
        @"YTKACE.Shorts.%p.%@", receiver, NSStringFromSelector(selector)];
    NSUInteger depth = [threadState[depthKey] unsignedIntegerValue];
    IMP original = YTKACEShortsOriginal(receiver, selector, depth);
    if (original == NULL) return;

    threadState[depthKey] = @(depth + 1);
    @try {
        ((void (*)(id, SEL))original)(receiver, selector);
    } @finally {
        if (depth == 0) {
            [threadState removeObjectForKey:depthKey];
        } else {
            threadState[depthKey] = @(depth);
        }
    }
}

static Method YTKACEShortsDirectMethod(Class cls, SEL selector) {
    if (cls == Nil) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL YTKACEShortsIsReplacement(IMP implementation) {
    return implementation == (IMP)YTKACEReelLayout ||
        implementation == (IMP)YTKACEReelOverlayLayout ||
        implementation == (IMP)YTKACEShortsControllerLayout ||
        implementation == (IMP)YTKACEPausedLayout ||
        implementation == (IMP)YTKACEInteractiveStickerLayout;
}

static id YTKACEShortsObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static id YTKACEShortsResponseFromObject(id object,
                                         NSHashTable *visited,
                                         NSUInteger depth) {
    if (object == nil || depth > 7 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id response = YTKACEShortsObject(object, @"contentPlayerResponse") ?:
        YTKACEShortsObject(object, @"playerResponse");
    if (response != nil) {
        return response;
    }
    for (NSString *name in @[@"_youtubeiOSPlayerViewController", @"parentResponder",
                              @"parentViewController", @"eventsDelegate",
                              @"playbackController", @"activeVideoPlayerOverlay"]) {
        id related = YTKACEShortsObject(object, name);
        response = YTKACEShortsResponseFromObject(related, visited, depth + 1);
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return YTKACEShortsResponseFromObject(
            ((UIResponder *)object).nextResponder, visited, depth + 1);
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSNumber *> *YTKACEShortsBarrenClasses;

static id YTKACEShortsPlayerResponseFromObject(id object) {
    if (object == nil) return nil;
    NSString *name = NSStringFromClass([object class]);
    if (YTKACEShortsBarrenClasses == nil) {
        YTKACEShortsBarrenClasses = [NSMutableDictionary dictionary];
    }
    if (YTKACEShortsBarrenClasses[name].integerValue >= 3) return nil;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    id result = YTKACEShortsResponseFromObject(object, visited, 0);
    if (result != nil) {
        [YTKACEShortsBarrenClasses removeObjectForKey:name];
    } else {
        YTKACEShortsBarrenClasses[name] =
            @(YTKACEShortsBarrenClasses[name].integerValue + 1);
    }
    return result;
}

@interface YTKACEShortsDownloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation YTKACEShortsDownloadTarget
+ (instancetype)sharedTarget {
    static YTKACEShortsDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEShortsDownloadTarget new]; });
    return target;
}
- (void)downloadTapped:(UIButton *)sender {
    [YTKACEShortsBarrenClasses removeAllObjects];
    id fromView = YTKACEShortsPlayerResponseFromObject(sender);
    id response = fromView ?: YTKACELatestShortsPlayerResponse;
    YTKACEDownloadCoordinator.sharedCoordinator.playerResponse = response;
    [YTKACEDownloadCoordinator.sharedCoordinator
        showShortsDownloadMenuFromView:sender];
}
@end

static double YTKACEShortsDouble(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static id YTKACEShortsParent(id receiver) {
    SEL selector = NSSelectorFromString(@"parentViewController");
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static id YTKACEFindShortsController(id receiver) {
    id current = receiver;
    for (NSInteger index = 0; current != nil && index < 10; index++) {
        NSString *name = NSStringFromClass([current class]).lowercaseString;
        if ([name containsString:@"shorts"] || [name containsString:@"reel"]) {
            return current;
        }
        id parent = YTKACEShortsParent(current);
        if (parent != nil && parent != current) {
            current = parent;
        } else if ([current isKindOfClass:UIResponder.class]) {
            current = ((UIResponder *)current).nextResponder;
        } else {
            break;
        }
    }
    return nil;
}

static BOOL YTKACEAdvanceShort(id controller, id sender) {
    for (NSString *name in @[
        @"reelContentViewRequestsAdvanceToNextVideo:",
        @"advanceToNextVideo:",
        @"advanceToNextVideo",
        @"scrollToNextVideo"
    ]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([controller class], selector);
        if (method == NULL) {
            continue;
        }
        if (method_getNumberOfArguments(method) == 3) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, sender);
        } else {
            ((void (*)(id, SEL))objc_msgSend)(controller, selector);
        }
        return YES;
    }
    SEL reelAdvance = NSSelectorFromString(@"advanceToNextReelWithTransitionType:");
    id current = controller;
    for (NSInteger depth = 0; current != nil && depth < 8; depth++) {
        Method method = class_getInstanceMethod([current class], reelAdvance);
        if (method != NULL) {
            char type[8] = {0};
            method_getArgumentType(method, 2, type, sizeof(type));
            if (strchr("qQiIlL", type[0]) != NULL && type[1] == 0) {
                ((void (*)(id, SEL, long long))objc_msgSend)(current, reelAdvance, 0);
                return YES;
            }
        }
        id parent = YTKACEShortsParent(current);
        current = parent != nil && parent != current ? parent
            : ([current isKindOfClass:UIResponder.class] ? ((UIResponder *)current).nextResponder : nil);
    }
    UIView *view = [controller isKindOfClass:UIViewController.class] ? ((UIViewController *)controller).view : nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *pager = (UIScrollView *)candidate;
        CGFloat page = CGRectGetHeight(pager.bounds);
        if (page < 100.0 || page < CGRectGetHeight(view.bounds) * 0.9) continue;
        CGFloat next = round(pager.contentOffset.y / page) * page + page;
        if (next > pager.contentSize.height - page + 1.0) break;
        [pager setContentOffset:CGPointMake(pager.contentOffset.x, next) animated:YES];
        return YES;
    }
    return NO;
}

static void YTKACEUpdateShortsProgress(void) {
    BOOL enabled = YTKACEFeatureEnabled(@"shortsProgress");
    CGFloat ratio = YTKACELastShortsDuration > 0.0
        ? (CGFloat)MIN(1.0, MAX(0.0, YTKACELastShortsTime / YTKACELastShortsDuration))
        : 0.0;
    for (UIView *view in YTKACEReelViews.allObjects) {
        CALayer *track = objc_getAssociatedObject(view, YTKACEShortsTrackAssociation);
        CALayer *fill = objc_getAssociatedObject(view, YTKACEShortsFillAssociation);
        track.hidden = !enabled;
        fill.hidden = !enabled;
        if (enabled) {
            CGFloat height = 3.0;
            track.frame = CGRectMake(0.0,
                                     MAX(0.0, CGRectGetHeight(view.bounds) - height),
                                     CGRectGetWidth(view.bounds),
                                     height);
            fill.frame = CGRectMake(0.0, 0.0,
                                    CGRectGetWidth(track.bounds) * ratio,
                                    height);
            YTKACEStyleProgressLayer(fill, CGRectGetWidth(track.bounds));
        }
    }
}

@interface YTKACEShortsPinchTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTKACEShortsPinchTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if ([other isKindOfClass:UIPinchGestureRecognizer.class]) return NO;
    if ([other.view isKindOfClass:UIScrollView.class] &&
        other == ((UIScrollView *)other.view).panGestureRecognizer) return NO;
    return YES;
}

- (void)stopPagerUnder:(UIView *)view {
    UIScrollView *pager = nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) {
            pager = (UIScrollView *)candidate;
            break;
        }
    }
    if (pager == nil) return;
    CGFloat page = CGRectGetHeight(pager.bounds);
    CGPoint offset = pager.contentOffset;
    pager.panGestureRecognizer.enabled = NO;
    pager.panGestureRecognizer.enabled = YES;
    if (page > 1.0) {
        CGFloat snapped = round(offset.y / page) * page;
        if (fabs(snapped - offset.y) > 0.5) [pager setContentOffset:CGPointMake(offset.x, snapped) animated:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (![other isKindOfClass:UIPinchGestureRecognizer.class] || other == gesture) return NO;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PinchFullscreen");
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        [self stopPagerUnder:pinch.view];
        return;
    }
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    BOOL active = YTKACEShortsNewFullscreenActive();
    if (pinch.scale > 1.0 && !active) {
        YTKACESetShortsNewFullscreen(pinch.view, YES);
    } else if (pinch.scale < 1.0 && active) {
        YTKACESetShortsNewFullscreen(pinch.view, NO);
    }
}
@end

static const void *YTKACEShortsPinchAssociation = &YTKACEShortsPinchAssociation;
static const void *YTKACEShortsRetryAssociation = &YTKACEShortsRetryAssociation;
static void YTKACEConfigureReelView(UIView *receiver, BOOL showDownload);
static IMP OriginalReelElementLayout;

static void YTKACEReelElementLayout(UIView *receiver, SEL selector) {
    if (OriginalReelElementLayout != NULL) ((void (*)(id, SEL))OriginalReelElementLayout)(receiver, selector);
    if (!YTKACEShortsNewFullscreenActive() || receiver.alpha <= 0.01 || receiver.window == nil) return;
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    UIView *container = receiver.superview;
    for (NSUInteger depth = 0; container != nil && depth < 8 && ![container isKindOfClass:containerClass]; depth++) {
        container = container.superview;
    }
    if (![container isKindOfClass:containerClass]) return;
    YTKACERegisterFadedShortsContainer(container);
    YTKACEFadeShortsElement(receiver);
}

static void YTKACEPrepareNewShortsContainer(UIView *receiver) {
    if (![NSStringFromClass(receiver.class) isEqualToString:@"YTReelContainerView"]) return;
    if (objc_getAssociatedObject(receiver, YTKACEShortsPinchAssociation) == nil) {
        static YTKACEShortsPinchTarget *target;
        if (target == nil) target = [YTKACEShortsPinchTarget new];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:target
                                                                                    action:@selector(pinched:)];
        pinch.delegate = target;
        pinch.cancelsTouchesInView = NO;
        [receiver addGestureRecognizer:pinch];
        objc_setAssociatedObject(receiver, YTKACEShortsPinchAssociation, pinch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACEConfigureReelView(UIView *receiver, BOOL showDownload) {
    [YTKACEReelViews addObject:receiver];
    YTKACEPrepareNewShortsContainer(receiver);
    CALayer *track = objc_getAssociatedObject(receiver, YTKACEShortsTrackAssociation);
    CALayer *fill = objc_getAssociatedObject(receiver, YTKACEShortsFillAssociation);
    if (track == nil) {
        track = [CALayer layer];
        track.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.55].CGColor;
        track.zPosition = 10000.0;
        fill = [CALayer layer];
        fill.backgroundColor = UIColor.redColor.CGColor;
        objc_setAssociatedObject(receiver, YTKACEShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [track addSublayer:fill];
        [receiver.layer addSublayer:track];
        objc_setAssociatedObject(receiver, YTKACEShortsTrackAssociation,
                                 track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(receiver, YTKACEShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (showDownload) {
        YTKACEApplyShortsActionVisibility(receiver);
        YTKACECompactShortsRail(receiver);
    }
    BOOL visibleHost = receiver.window != nil && !receiver.hidden &&
        receiver.alpha > 0.05 && CGRectGetWidth(receiver.bounds) > 200.0 &&
        CGRectGetHeight(receiver.bounds) > 300.0;
    UIView *action = showDownload && visibleHost
        ? YTKACEVisibleShortsAction(receiver)
        : nil;
    UIView *downloadHost = action == nil
        ? YTKACECurrentShortsPlaybackOverlay(receiver)
        : YTKACEShortsPlaybackOverlay(action, receiver);
    if (![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) {
        Class containerClass = NSClassFromString(@"YTReelContainerView");
        UIView *container = nil;
        for (UIView *candidate = action ?: receiver; candidate != nil; candidate = candidate.superview) {
            if (containerClass != Nil && [candidate isKindOfClass:containerClass]) {
                container = candidate;
                break;
            }
        }
        if (container == nil && containerClass != Nil && [receiver isKindOfClass:containerClass]) container = receiver;
        if (container != nil && showDownload && visibleHost) downloadHost = container;
        else if (container == nil && downloadHost != nil &&
                 ![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) downloadHost = nil;
    }
    UIButton *download = objc_getAssociatedObject(
        downloadHost, YTKACEShortsDownloadAssociation);
    if (showDownload && visibleHost && downloadHost != nil &&
        download == nil) {
        download = [UIButton buttonWithType:UIButtonTypeSystem];
        download.tag = YTKACEShortsDownloadTag;
        download.accessibilityIdentifier = @"YTKACE Shorts Download";
        download.accessibilityLabel = YTKACELocalized(@"Download Short");
        download.tintColor = UIColor.whiteColor;
        [download setImage:YTKACEDownloadGlyphImage()
                  forState:UIControlStateNormal];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                            weight:UIImageSymbolWeightMedium];
        [download setPreferredSymbolConfiguration:configuration
                                  forImageInState:UIControlStateNormal];
        download.layer.shadowColor = UIColor.blackColor.CGColor;
        download.layer.shadowOpacity = 0.55;
        download.layer.shadowRadius = 4.0;
        download.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        download.translatesAutoresizingMaskIntoConstraints = NO;
        [download addTarget:YTKACEShortsDownloadTarget.sharedTarget
                     action:@selector(downloadTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [downloadHost addSubview:download];
        objc_setAssociatedObject(downloadHost, YTKACEShortsDownloadAssociation,
            download, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (download != nil && download.superview == downloadHost) {
        if (action != nil) {
            objc_setAssociatedObject(download,
                YTKACEShortsDownloadAnchoredAssociation, @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL railMode = [NSUserDefaults.standardUserDefaults
            integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"] != 0;
        BOOL anchored = [objc_getAssociatedObject(download,
            YTKACEShortsDownloadAnchoredAssociation) boolValue];
        BOOL legacyHost = [NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"];
        download.hidden = !YTKACEDownloadsEnabled() ||
            (railMode && !anchored && (legacyHost || !YTKACEShortsNewFullscreenActive()));
        YTKACEPositionShortsDownload(downloadHost, action, download);
        [downloadHost bringSubviewToFront:download];
        NSMutableArray<UIView *> *stack =
            [NSMutableArray arrayWithObject:downloadHost];
        NSUInteger duplicates = 0;
        while (stack.count != 0) {
            UIView *candidate = stack.lastObject;
            [stack removeLastObject];
            for (UIView *subview in candidate.subviews) {
                if (subview.tag == YTKACEShortsDownloadTag &&
                    subview != download) {
                    duplicates++;
                    [subview removeFromSuperview];
                } else {
                    [stack addObject:subview];
                }
            }
        }
        (void)duplicates;
    }
    if (showDownload && download != nil && download.hidden && YTKACEDownloadsEnabled() && action == nil &&
        downloadHost != nil) {
        NSUInteger retries = [objc_getAssociatedObject(downloadHost, YTKACEShortsRetryAssociation) unsignedIntegerValue];
        if (retries < 4) {
            objc_setAssociatedObject(downloadHost, YTKACEShortsRetryAssociation, @(retries + 1),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static const double delays[] = {0.3, 0.7, 1.5, 3.0};
            __weak UIView *weakReceiver = receiver;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[retries] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *strongReceiver = weakReceiver;
                if (strongReceiver.window != nil) YTKACEConfigureReelView(strongReceiver, YES);
            });
        }
    } else if (download != nil && !download.hidden) {
        objc_setAssociatedObject(downloadHost, YTKACEShortsRetryAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    static NSTimeInterval lastResolve = 0.0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (YTKACELatestShortsPlayerResponse == nil || now - lastResolve > 0.5) {
        lastResolve = now;
        id response = YTKACEShortsPlayerResponseFromObject(receiver);
        if (response != nil) {
            YTKACELatestShortsPlayerResponse = response;
        }
    }
    YTKACEUpdateShortsProgress();
}

static void YTKACEReelLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver, NO);
}

static void YTKACEReelOverlayLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver, YES);
}

static void YTKACEShortsControllerLayout(UIViewController *receiver,
                                         SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    YTKACEConfigureReelView(receiver.view, YES);
    if (![objc_getAssociatedObject(receiver,
            YTKACEShortsInitialRefreshAssociation) boolValue]) {
        objc_setAssociatedObject(receiver,
            YTKACEShortsInitialRefreshAssociation, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIViewController *weakReceiver = receiver;
        for (NSNumber *delay in @[@0.08, @0.30]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    UIViewController *controller = weakReceiver;
                    if (controller.view.window != nil) {
                        YTKACEConfigureReelView(controller.view, YES);
                    }
                });
        }
    }
}

static void YTKACEPausedLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    BOOL hidden = YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden");
    YTKACESetShortsHidden(receiver, hidden);
}

static void YTKACEInteractiveStickerLayout(UIView *receiver, SEL selector) {
    YTKACEInvokeShortsOriginal(receiver, selector);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class).lowercaseString,
        receiver.accessibilityIdentifier.lowercaseString ?: @"",
        receiver.description.lowercaseString ?: @""];
    BOOL product = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        ([token containsString:@"product"] ||
         [token containsString:@"shopping"]);
    BOOL stickerAd = YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden") &&
        (([token containsString:@"sticker"] &&
          ([token containsString:@"sponsor"] ||
           [token containsString:@"promot"] ||
           [token containsString:@"brand"] ||
           [token containsString:@"product"])) ||
         [token containsString:@"shorts_ads_shopping"]);
    YTKACESetShortsHidden(receiver, product || stickerAd);
}

static void YTKACEInstallShortsLayout(NSString *className, IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = @selector(layoutSubviews);
    if (YTKACEShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTKACEShortsHookKey(cls, selector);
    if ([YTKACEShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTKACEShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className, @"layoutSubviews",
                                  replacement, &original) &&
        original != NULL && !YTKACEShortsIsReplacement(original)) {
        YTKACEShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTKACEShortsInstalledHooks addObject:key];
    }
}

static void YTKACEInstallShortsController(NSString *className) {
    SEL selector = @selector(viewDidLayoutSubviews);
    Class cls = NSClassFromString(className);
    if (YTKACEShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTKACEShortsHookKey(cls, selector);
    if ([YTKACEShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTKACEShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className,
                                  NSStringFromSelector(selector),
                                  (IMP)YTKACEShortsControllerLayout,
                                  &original) && original != NULL &&
        !YTKACEShortsIsReplacement(original)) {
        YTKACEShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTKACEShortsInstalledHooks addObject:key];
    }
}

static const void *YTKACEShortsLoopAssociation = &YTKACEShortsLoopAssociation;

static void YTKACEShortsTimeChanged(NSNotification *notification) {
    id player = notification.object;
    id shorts = YTKACEFindShortsController(player);
    if (shorts == nil) {
        return;
    }
    static CFTimeInterval lastLookup = 0.0;
    if (YTKACELatestShortsPlayerResponse == nil ||
        CACurrentMediaTime() - lastLookup > 1.0) {
        lastLookup = CACurrentMediaTime();
        id response = YTKACEShortsPlayerResponseFromObject(player) ?:
            YTKACEShortsPlayerResponseFromObject(shorts);
        if (response != nil) {
            YTKACELatestShortsPlayerResponse = response;
        }
    }
    double time = [notification.userInfo[@"time"] doubleValue];
    double duration = YTKACEShortsDouble(player, @[
        @"currentVideoTotalMediaTime",
        @"currentVideoTotalTime",
        @"currentVideoDuration",
        @"totalMediaTime"
    ]);
    YTKACELastShortsTime = time;
    YTKACELastShortsDuration = duration;
    YTKACEUpdateShortsProgress();

    if (YTKACEShortsLimitReached()) {
        return;
    }
    if (!YTKACEFeatureEnabled(@"autoSkipShorts") && YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled") &&
        duration > 1.0) {
        if (time < duration * 0.5) {
            objc_setAssociatedObject(shorts, YTKACEShortsLoopAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (time >= duration - 0.3 &&
                   ![objc_getAssociatedObject(shorts, YTKACEShortsLoopAssociation) boolValue]) {
            objc_setAssociatedObject(shorts, YTKACEShortsLoopAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL pause = NSSelectorFromString(@"pause");
            if ([player respondsToSelector:pause]) ((void (*)(id, SEL))objc_msgSend)(player, pause);
        }
        return;
    }
    if (!YTKACEFeatureEnabled(@"autoSkipShorts") || duration <= 1.0) {
        return;
    }
    const double previous =
        [objc_getAssociatedObject(shorts, YTKACEShortsLastTimeAssociation) doubleValue];
    objc_setAssociatedObject(shorts, YTKACEShortsLastTimeAssociation, @(time),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Wait for the real end: either the last frames, or the jump back to the
    // start when the Short loops.
    const BOOL ended = time >= duration - 0.08 ||
        (previous >= duration - 1.0 && time < 1.0);
    if (!ended) {
        if (time < duration * 0.5 && time >= 1.0) {
            objc_setAssociatedObject(shorts, YTKACEShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if ([objc_getAssociatedObject(shorts, YTKACEShortsSkipAssociation) boolValue]) {
        return;
    }
    objc_setAssociatedObject(shorts, YTKACEShortsSkipAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id delayValue = YTKACEPreferenceObject(@"YTKACE.Preference.Shorts.AutoScrollDelay");
    const double delay = [delayValue respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, MIN([delayValue doubleValue], 5.0)) : 0.0;
    if (delay <= 0.0) {
        if (!YTKACEAdvanceShort(shorts, player)) {
            objc_setAssociatedObject(shorts, YTKACEShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    __weak id weakShorts = shorts;
    __weak id weakPlayer = player;
    SEL videoGetter = NSSelectorFromString(@"currentVideoID");
    id videoID = [player respondsToSelector:videoGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(player, videoGetter) : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongShorts = weakShorts;
        id strongPlayer = weakPlayer;
        if (strongShorts == nil || strongPlayer == nil ||
            !YTKACEFeatureEnabled(@"autoSkipShorts")) {
            return;
        }
        // Skip if the user already moved to another Short.
        id nowID = [strongPlayer respondsToSelector:videoGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(strongPlayer, videoGetter) : nil;
        if (videoID != nil && ![videoID isEqual:nowID]) return;
        if (!YTKACEAdvanceShort(strongShorts, strongPlayer)) {
            objc_setAssociatedObject(strongShorts, YTKACEShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

void YTKACEInstallShortsHooks(void) {
    if (YTKACEReelViews == nil) {
        YTKACEReelViews = [NSHashTable weakObjectsHashTable];
        YTKACEShortsOriginals = [NSMutableDictionary dictionary];
        YTKACEShortsInstalledHooks = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"YTKACEPlaybackTimeDidChange"
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                YTKACEShortsTimeChanged(notification);
            }];
    }
    for (NSString *className in @[
        @"YTReelContentView",
        @"YTReelPlayerView",
        @"YTShortsPlayerView",
        @"YTShortsPlayerViewControllerView",
        @"YTShortsPlayerViewSwift"
    ]) {
        YTKACEInstallShortsLayout(className, (IMP)YTKACEReelLayout);
    }
    YTKACEInstallInstanceHook(@"YTReelElementAsyncComponentView", @"layoutSubviews",
                              (IMP)YTKACEReelElementLayout, &OriginalReelElementLayout);
    YTKACEInstallShortsLayout(@"YTReelWatchPlaybackOverlayView",
                              (IMP)YTKACEReelOverlayLayout);
    for (NSString *className in @[
        @"YTAppReelWatchRootViewController",
        @"YTReelWatchRootViewController",
        @"YTReelContainerViewController",
        @"YTReelPlaybackViewController",
        @"YTReelPlayerViewController",
        @"YTShortsPlayerViewController"
    ]) {
        YTKACEInstallShortsController(className);
    }
    for (NSString *className in @[
        @"YTReelPausedStateCarouselView",
        @"YTReelPlayerPausedStateView"
    ]) {
        YTKACEInstallShortsLayout(className, (IMP)YTKACEPausedLayout);
    }
    for (NSString *className in @[
        @"YTReelInteractiveStickerView",
        @"YTShortsStickersView",
        @"YTShortsStickersViewSwift"
    ]) {
        YTKACEInstallShortsLayout(className,
                                  (IMP)YTKACEInteractiveStickerLayout);
    }
}
