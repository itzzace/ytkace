#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "AiSList.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static BOOL YTKACEShortsSuggestionPillHidden(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Shorts.SuggestionPillHidden"];
    if (stored == nil) {
        BOOL legacy = [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Overlay.CommentPreviewsHidden"];
        [NSUserDefaults.standardUserDefaults setBool:legacy forKey:@"YTKACE.Preference.Shorts.SuggestionPillHidden"];
    }
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SuggestionPillHidden");
}

static IMP OriginalDisplayViewDidMove;
static IMP OriginalActionCellPrepareForReuse;
static IMP OriginalFixedBarLayout;
static IMP OriginalDisplayViewSetIdentifier;
static IMP OriginalAddSections;
static IMP OriginalSectionControllers;
static IMP OriginalEnableSubheaderBar;
static IMP OriginalChipBarUpdate;
static IMP OriginalChipCloudSetEntry;
static IMP OriginalSubsChipFilter;
static IMP OriginalChipCloudLayout;
static IMP OriginalFeedHeaderScrollMode;
static IMP OriginalSubsSetChipFilterView;
static IMP OriginalMaximumSubheaderHeight;
static IMP OriginalMaximumSubheaderHeightGetter;
static IMP OriginalSubheaderDefaultHeight;
static IMP OriginalSetHeaderHeights;
static IMP OriginalShouldHideSubheader;
static IMP OriginalPaidContentLayout;
static IMP OriginalPaidContentDidAppear;
static IMP OriginalPaidContentPlaybackStarted;
static IMP OriginalSetPaidContentPlayerData;
static IMP OriginalSetPaidContentRenderer;
static IMP OriginalHasPaidContentOverlay;
static IMP OriginalPaidContentOverlay;
static IMP OriginalOverlayPaidContentPlayerData;
static IMP OriginalInlinePaidContentPlayerData;
static IMP OriginalDidInsertPlayerOverlay;
static IMP OriginalScrollableActionButtonsArray;
static IMP OriginalScrollableActionBarButtonsArray;
static IMP OriginalScrollableButtonsArray;
static IMP OriginalScrollableActionsArray;
static IMP OriginalActionButtonsArray;
static IMP OriginalActionBarButtonsArray;
static IMP OriginalButtonsArray;
static IMP OriginalActionsArray;
static IMP OriginalActionViewDidMove;
static IMP OriginalActionsViewDidMove;
static IMP OriginalActionCellDidMove;
static IMP OriginalCreateActionViews;
static IMP OriginalActionCellControllerInit;
static IMP OriginalActionCellSize;
static IMP OriginalActionCellSizeWithInsets;
static IMP OriginalASCollectionViewLayout;
static const void *YTKACEContentHiddenAssociation = &YTKACEContentHiddenAssociation;
static NSString *YTKACENormalizedDescription(id object);
static const void *YTKACEActionCellPreferenceAssociation =
    &YTKACEActionCellPreferenceAssociation;
static const void *YTKACEActionLayoutRefreshAssociation =
    &YTKACEActionLayoutRefreshAssociation;
static const void *YTKACEActionGroupCompactAssociation =
    &YTKACEActionGroupCompactAssociation;
static BOOL YTKACEContentContains(NSString *token,
                                  NSArray<NSString *> *needles);
static id YTKACEContentValue(id object, NSString *key);
static NSArray<NSString *> *YTKACEProductsMarkers(void);
static BOOL YTKACEHideTopics(void);
static BOOL YTKACEEnsureStructuralActionHook(void);
static BOOL YTKACEEnsureActionCellControllerHooks(void);
static BOOL YTKACEEnsureActionCollectionLayoutHook(void);

static BOOL YTKACEViewIsInsideWatchActionBar(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        NSString *identifier = [candidate.accessibilityIdentifier lowercaseString] ?: @"";
        NSString *className = NSStringFromClass(candidate.class) ?: @"";
        if ([identifier containsString:@"scrollable_action_bar"] ||
            [className containsString:@"SlimVideoScrollableDetailsActionsView"] ||
            [className containsString:@"SlimVideoScrollableActionBarCell"]) {
            return YES;
        }
        if ([candidate isKindOfClass:UICollectionView.class] &&
            CGRectGetHeight(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) > 0.0) {
            return YES;
        }
    }
    return NO;
}

static NSString *YTKACEActionPreference(id item) {
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass([item class]), YTKACENormalizedDescription(item)] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTKACE.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static BOOL YTKACEAnyActionPreferenceEnabled(void) {
    for (NSString *key in @[
        @"YTKACE.Preference.ActionBar.LikeHidden",
        @"YTKACE.Preference.ActionBar.DislikeHidden",
        @"YTKACE.Preference.ActionBar.ShareHidden",
        @"YTKACE.Preference.ActionBar.DownloadHidden",
        @"YTKACE.Preference.ActionBar.SaveHidden",
        @"YTKACE.Preference.ActionBar.ClipHidden",
        @"YTKACE.Preference.ActionBar.RemixHidden",
        @"YTKACE.Preference.ActionBar.ThanksHidden",
        @"YTKACE.Preference.ActionBar.HypeHidden",
        @"YTKACE.Preference.ActionBar.ReportHidden",
        @"YTKACE.Preference.ActionBar.AskHidden",
        @"YTKACE.Preference.ActionBar.OverflowHidden"
    ]) {
        if (YTKACEFeatureEnabled(key)) return YES;
    }
    return NO;
}

static NSString *YTKACEActionPreferenceForView(UIView *view) {
    if (view == nil || !YTKACEViewIsInsideWatchActionBar(view)) return nil;
    for (NSString *name in @[@"entry", @"renderer", @"buttonRenderer",
                             @"model", @"elementRenderer"]) {
        SEL selector = NSSelectorFromString(name);
        if (![view respondsToSelector:selector]) continue;
        id related = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if (related == nil || [related isKindOfClass:UIView.class]) continue;
        NSString *preference = YTKACEActionPreference(related);
        if (preference.length != 0) {
            return preference;
        }
    }
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass(view.class), view.accessibilityIdentifier ?: @""]
        lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *wide = [[NSString stringWithFormat:@"%@ %@", token,
        view.accessibilityLabel ?: @""] lowercaseString];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"id_video_dislike_button", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"id_video_share_button", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"id_video_like_button", @"like"]
    ];
    BOOL dislikeToken = [token containsString:@"dislike"] ||
        [wide containsString:@"dislike"];
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTKACE.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) {
                return rule.firstObject;
            }
        }
    }
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTKACE.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([wide containsString:rule[index]]) {
                NSMutableArray<NSString *> *shape = [NSMutableArray array];
                NSMutableArray<UIView *> *pending =
                    [NSMutableArray arrayWithObject:view];
                NSUInteger seen = 0;
                while (pending.count != 0 && seen < 40) {
                    UIView *node = pending.firstObject;
                    [pending removeObjectAtIndex:0];
                    seen++;
                    NSMutableString *entry = [NSMutableString stringWithString:
                        NSStringFromClass([node class])];
                    if (node.accessibilityIdentifier.length != 0) {
                        [entry appendFormat:@"#%@", node.accessibilityIdentifier];
                    }
                    for (NSString *probe in @[@"iconType", @"icon", @"image",
                                              @"renderer", @"entry", @"model"]) {
                        SEL selector = NSSelectorFromString(probe);
                        if (![node respondsToSelector:selector]) continue;
                        [entry appendFormat:@" %@?", probe];
                    }
                    [shape addObject:entry];
                    [pending addObjectsFromArray:node.subviews];
                }
                return rule.firstObject;
            }
        }
    }
    return nil;
}

static void YTKACECreateActionViews(id receiver, SEL selector,
                                    NSArray *renderers) {
    NSArray *filtered = renderers;
    if ([renderers isKindOfClass:NSArray.class]) {
        static NSUInteger rendererLogged = 0;
        if (rendererLogged < 3) {
            rendererLogged++;
            NSMutableArray<NSString *> *shape = [NSMutableArray array];
            for (id renderer in renderers) {
                NSString *match = YTKACEActionPreference(renderer);
                NSMutableString *entry = [NSMutableString stringWithString:
                    NSStringFromClass([renderer class])];
                for (NSString *probe in @[@"likeButton", @"dislikeButton",
                                          @"segmentedLikeDislikeButton",
                                          @"buttonRenderer", @"targetId",
                                          @"trackingParams"]) {
                    SEL selector = NSSelectorFromString(probe);
                    if ([renderer respondsToSelector:selector]) {
                        [entry appendFormat:@" %@?", probe];
                    }
                }
                if (match.length != 0) {
                    [entry appendFormat:@" ->%@",
                        [match componentsSeparatedByString:@"."].lastObject];
                }
                [shape addObject:entry];
            }
        }
    }
    if ([renderers isKindOfClass:NSArray.class] &&
        renderers.count != 0 && YTKACEAnyActionPreferenceEnabled()) {
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:renderers.count];
        for (id renderer in renderers) {
            NSString *preference = YTKACEActionPreference(renderer);
            if (preference.length != 0 && YTKACEFeatureEnabled(preference)) {
                continue;
            }
            [kept addObject:renderer];
        }
        if (kept.count != renderers.count) filtered = kept;
    }
    if (OriginalCreateActionViews != NULL) {
        ((void (*)(id, SEL, id))OriginalCreateActionViews)(
            receiver, selector, filtered);
    }
}

static void YTKACEEnsureActionCellReuseHook(void);

static BOOL YTKACEEnsureStructuralActionHook(void) {
    YTKACEEnsureActionCellReuseHook();
    if (OriginalCreateActionViews != NULL) return YES;

    BOOL installed = YTKACEInstallInstanceHook(
        @"YTSlimVideoScrollableDetailsActionsView",
        @"createActionViewsFromSupportedRenderers:",
        (IMP)YTKACECreateActionViews,
        &OriginalCreateActionViews
    );
    if (installed && OriginalCreateActionViews != NULL) return YES;
    return NO;
}

static NSString *YTKACEActionPreferenceForController(id controller) {
    NSString *cached = objc_getAssociatedObject(
        controller, YTKACEActionCellPreferenceAssociation);
    if (cached.length != 0) return cached;

    for (Class cls = [controller class]; cls != Nil; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            const char *name = ivar_getName(ivars[index]);
            if (type == NULL || type[0] != '@' || name == NULL) continue;
            NSString *ivarName = [[NSString stringWithUTF8String:name] lowercaseString];
            if (![ivarName containsString:@"entry"] &&
                ![ivarName containsString:@"render"] &&
                ![ivarName containsString:@"button"] &&
                ![ivarName containsString:@"cell"]) {
                continue;
            }
            id value = object_getIvar(controller, ivars[index]);
            if (value == nil) continue;
            NSString *preference = [value isKindOfClass:UIView.class]
                ? YTKACEActionPreferenceForView(value)
                : YTKACEActionPreference(value);
            if (preference.length == 0) continue;
            free(ivars);
            objc_setAssociatedObject(controller,
                                     YTKACEActionCellPreferenceAssociation,
                                     preference,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return preference;
        }
        free(ivars);
    }
    return nil;
}

static id YTKACEActionCellControllerInit(id receiver, SEL selector,
                                          id entry, id parentResponder) {
    id result = OriginalActionCellControllerInit == NULL ? receiver :
        ((id (*)(id, SEL, id, id))OriginalActionCellControllerInit)(
            receiver, selector, entry, parentResponder);
    NSString *preference = YTKACEActionPreference(entry);
    if (result != nil && preference.length != 0) {
        objc_setAssociatedObject(result,
                                 YTKACEActionCellPreferenceAssociation,
                                 preference,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return result;
}

static NSArray<NSString *> *YTKACEActionButtonIdentifiers(UIView *view);
static BOOL YTKACEIsActionButtonIdentifier(NSString *identifier);

static NSString *YTKACEPreferenceForButtonIdentifier(NSString *identifier) {
    NSString *token = [[identifier lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (token.length == 0) return nil;
    if ([token containsString:@"dislike"]) {
        return @"YTKACE.Preference.ActionBar.DislikeHidden";
    }
    if ([token containsString:@"like"]) {
        return @"YTKACE.Preference.ActionBar.LikeHidden";
    }
    if ([token containsString:@"share"]) {
        return @"YTKACE.Preference.ActionBar.ShareHidden";
    }
    if ([token containsString:@"offline"] || [token containsString:@"download"]) {
        return @"YTKACE.Preference.ActionBar.DownloadHidden";
    }
    if ([token containsString:@"add_to"] || [token containsString:@"save"]) {
        return @"YTKACE.Preference.ActionBar.SaveHidden";
    }
    if ([token containsString:@"clip"]) {
        return @"YTKACE.Preference.ActionBar.ClipHidden";
    }
    if ([token containsString:@"remix"]) {
        return @"YTKACE.Preference.ActionBar.RemixHidden";
    }
    if ([token containsString:@"thanks"]) {
        return @"YTKACE.Preference.ActionBar.ThanksHidden";
    }
    if ([token containsString:@"hype"]) {
        return @"YTKACE.Preference.ActionBar.HypeHidden";
    }
    return nil;
}

static NSArray<NSString *> *YTKACEControllerButtonIdentifiers(id controller) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    for (Class cls = [controller class]; cls != Nil;
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(controller, ivars[index]);
            if (![value isKindOfClass:UIView.class]) continue;
            [found addObjectsFromArray:
                YTKACEActionButtonIdentifiers((UIView *)value)];
        }
        free(ivars);
    }
    return found.array;
}

static BOOL YTKACEControllerCellCollapsed(id receiver) {
    static NSUInteger logged = 0;
    NSString *preference = YTKACEActionPreferenceForController(receiver);
    NSArray<NSString *> *identifiers = YTKACEControllerButtonIdentifiers(receiver);
    BOOL collapsed = preference.length != 0 && YTKACEFeatureEnabled(preference);
    if (identifiers.count > 1) {
        collapsed = YES;
        for (NSString *identifier in identifiers) {
            NSString *key = YTKACEPreferenceForButtonIdentifier(identifier);
            if (key.length == 0 || !YTKACEFeatureEnabled(key)) {
                collapsed = NO;
                break;
            }
        }
    }
    if (logged < 60) {
        logged++;
    }
    return collapsed;
}

static CGSize YTKACEActionCellSize(id receiver, SEL selector, CGSize size) {
    CGSize result = OriginalActionCellSize == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize))OriginalActionCellSize)(
            receiver, selector, size);
    if (YTKACEControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static CGSize YTKACEActionCellSizeWithInsets(id receiver, SEL selector,
                                               CGSize size,
                                               UIEdgeInsets insets) {
    CGSize result = OriginalActionCellSizeWithInsets == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize, UIEdgeInsets))
            OriginalActionCellSizeWithInsets)(receiver, selector, size, insets);
    if (YTKACEControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static BOOL YTKACEEnsureActionCellControllerHooks(void) {
    if (OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL) return YES;

    YTKACEInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"initWithEntry:parentResponder:",
        (IMP)YTKACEActionCellControllerInit,
        &OriginalActionCellControllerInit);
    YTKACEInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:",
        (IMP)YTKACEActionCellSize,
        &OriginalActionCellSize);
    YTKACEInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:safeAreaInsets:",
        (IMP)YTKACEActionCellSizeWithInsets,
        &OriginalActionCellSizeWithInsets);
    return OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL;
}

static NSSet<NSString *> *YTKACEActionPreferencesInCell(UIView *cell) {
    NSMutableSet<NSString *> *preferences = [NSMutableSet set];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 120) {
        UIView *candidate = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = candidate.accessibilityIdentifier ?: @"";
        NSString *label = candidate.accessibilityLabel ?: @"";
        if (identifier.length != 0 || label.length != 0) {
            NSString *preference = YTKACEActionPreference(
                [NSString stringWithFormat:@"%@ %@", identifier, label]);
            if (preference.length != 0) [preferences addObject:preference];
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return preferences;
}

static void YTKACEHiddenActionWidths(UIView *cell,
                                     CGFloat *outTotal,
                                     CGFloat *outLeading,
                                     NSUInteger *outVisible,
                                     CGFloat *outVisibleRight,
                                     CGFloat *outInset) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (YTKACEIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [buttons addObject:node];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    buttons = [[buttons sortedArrayUsingComparator:
        ^NSComparisonResult(UIView *left, UIView *right) {
            CGFloat leftX = [left convertPoint:CGPointZero toView:cell].x;
            CGFloat rightX = [right convertPoint:CGPointZero toView:cell].x;
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }] mutableCopy];

    CGFloat separators = 0.0;
    UIView *group = buttons.firstObject.superview;
    for (UIView *child in group.subviews) {
        CGFloat width = CGRectGetWidth(child.bounds);
        if (width > 0.0 && width <= 3.0 &&
            CGRectGetHeight(child.bounds) >= 6.0) {
            separators += width;
        }
    }

    CGFloat total = 0.0;
    CGFloat leading = 0.0;
    NSUInteger visible = 0;
    CGFloat visibleRight = 0.0;
    BOOL seenVisible = NO;
    for (UIView *button in buttons) {
        NSString *key = YTKACEPreferenceForButtonIdentifier(
            button.accessibilityIdentifier);
        BOOL hidden = key.length != 0 && YTKACEFeatureEnabled(key);
        CGFloat width = CGRectGetWidth(button.bounds);
        if (!hidden) {
            visible++;
            seenVisible = YES;
            CGRect inCell = [button convertRect:button.bounds toView:cell];
            visibleRight = MAX(visibleRight, CGRectGetMaxX(inCell));
            continue;
        }
        total += width;
        if (!seenVisible) leading += width;
    }
    CGFloat inset = 0.0;
    if (group != nil) {
        inset = MAX(0.0, CGRectGetMinX([group convertRect:group.bounds
                                                  toView:cell]));
    }
    if (outVisibleRight != NULL) *outVisibleRight = visibleRight;
    if (outInset != NULL) *outInset = inset;
    if (total > 0.0) total += separators;
    if (leading > 0.0) leading += separators;
    if (outTotal != NULL) *outTotal = total;
    if (outLeading != NULL) *outLeading = leading;
    if (outVisible != NULL) *outVisible = visible;
}

static void YTKACEASCollectionViewLayout(UICollectionView *receiver,
                                          SEL selector) {
    if (OriginalASCollectionViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalASCollectionViewLayout)(receiver, selector);
    }
    if (!YTKACEAnyActionPreferenceEnabled() || receiver.window == nil) return;
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;

    NSArray<UICollectionViewCell *> *visible = [receiver.visibleCells
        sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *left,
                                                       UICollectionViewCell *right) {
            NSIndexPath *leftPath = [receiver indexPathForCell:left];
            NSIndexPath *rightPath = [receiver indexPathForCell:right];
            if (leftPath != nil && rightPath != nil) {
                return [leftPath compare:rightPath];
            }
            CGFloat leftX = CGRectGetMinX(left.frame);
            CGFloat rightX = CGRectGetMinX(right.frame);
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    if (visible.count == 0) return;

    static NSUInteger layoutLogged = 0;
    CGFloat removedWidth = 0.0;
    NSUInteger matchedCells = 0;
    for (UICollectionViewCell *cell in visible) {
        CGRect frame = cell.frame;
        NSArray<NSString *> *cellButtons = YTKACEActionButtonIdentifiers(cell);
        if (layoutLogged < 80 && cellButtons.count != 0) {
            layoutLogged++;
        }
        frame.origin.x -= removedWidth;
        NSSet<NSString *> *preferences = YTKACEActionPreferencesInCell(cell);
        if (preferences.count != 0) {
            matchedCells++;
            NSUInteger hiddenCount = 0;
            for (NSString *preference in preferences) {
                if (YTKACEFeatureEnabled(preference)) hiddenCount++;
            }
            if (hiddenCount != 0) {
                CGFloat oldWidth = CGRectGetWidth(frame);
                CGFloat measuredTotal = 0.0;
                CGFloat measuredLeading = 0.0;
                NSUInteger visibleButtons = 0;
                YTKACEHiddenActionWidths(cell, &measuredTotal,
                                         &measuredLeading, &visibleButtons,
                                         NULL, NULL);
                CGFloat newWidth = oldWidth;
                BOOL collapse = visibleButtons == 0;
                BOOL trailingOnly = measuredLeading <= 0.5 &&
                    measuredTotal > 0.5;
                if (collapse) {
                    newWidth = 0.0;
                } else if (trailingOnly) {
                    newWidth = floor(MAX(0.0, oldWidth - measuredTotal));
                }
                if (layoutLogged < 80) {
                    layoutLogged++;
                }
                removedWidth += oldWidth - newWidth;
                frame.size.width = newWidth;
                cell.hidden = collapse;
                cell.userInteractionEnabled = !collapse;
                cell.clipsToBounds = trailingOnly && !collapse;
                cell.contentView.clipsToBounds = cell.clipsToBounds;
                cell.contentView.transform = CGAffineTransformIdentity;
            } else {
                cell.hidden = NO;
                cell.userInteractionEnabled = YES;
                cell.clipsToBounds = NO;
                cell.contentView.clipsToBounds = NO;
                cell.contentView.transform = CGAffineTransformIdentity;
            }
        }
        cell.frame = frame;
    }
    if (matchedCells == 0 || removedWidth <= 0.0) return;

    CGSize contentSize = receiver.contentSize;
    contentSize.width = MAX(CGRectGetWidth(receiver.bounds),
                            contentSize.width - removedWidth);
    receiver.contentSize = contentSize;
}

static BOOL YTKACEEnsureActionCollectionLayoutHook(void) {
    if (OriginalASCollectionViewLayout != NULL) return YES;
    BOOL installed = YTKACEInstallInstanceHook(
        @"ASCollectionView", @"layoutSubviews",
        (IMP)YTKACEASCollectionViewLayout,
        &OriginalASCollectionViewLayout);
    if (installed && OriginalASCollectionViewLayout != NULL) return YES;
    return NO;
}

static void YTKACEScheduleStructuralActionHook(void) {
    NSArray<NSNumber *> *delays =
        @[@0.0, @0.5, @1.5, @3.0, @6.0, @9.0, @12.0, @18.0];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                YTKACEEnsureStructuralActionHook();
                YTKACEEnsureActionCellControllerHooks();
                YTKACEEnsureActionCollectionLayoutHook();
            }
        );
    }
}

static UICollectionView *YTKACEActionCollectionView(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UICollectionView.class]) {
            return (UICollectionView *)candidate;
        }
    }
    return nil;
}

static void YTKACERefreshActionCollection(UIView *view) {
    if (!YTKACEEnsureActionCellControllerHooks()) return;
    UICollectionView *collectionView = YTKACEActionCollectionView(view);
    if (collectionView == nil || objc_getAssociatedObject(
            collectionView, YTKACEActionLayoutRefreshAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(collectionView,
                             YTKACEActionLayoutRefreshAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        [collectionView.collectionViewLayout invalidateLayout];
        [collectionView reloadData];
        [collectionView layoutIfNeeded];
    });
}

static BOOL YTKACEIsActionButtonIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *lower = identifier.lowercaseString;
    if (![lower hasPrefix:@"id."]) return NO;
    return [lower containsString:@"button"];
}

static NSArray<NSString *> *YTKACEActionButtonIdentifiers(UIView *view) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:view];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (YTKACEIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [found addObject:node.accessibilityIdentifier];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    return found.array;
}

static void YTKACERestoreHiddenView(UIView *view) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, YTKACEContentHiddenAssociation);
    if (baseline == nil) return;
    view.hidden = NO;
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view,
                             YTKACEContentHiddenAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSUInteger YTKACESizableChildCount(UIView *view) {
    NSUInteger count = 0;
    for (UIView *child in view.subviews) {
        if (child.hidden) continue;
        if (CGRectGetWidth(child.bounds) >= 40.0 &&
            CGRectGetHeight(child.bounds) >= 28.0) {
            count++;
        }
    }
    return count;
}

static void YTKACEActionCellPrepareForReuse(UIView *receiver, SEL selector) {
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, YTKACEContentHiddenAssociation);
    if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 YTKACEContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (OriginalActionCellPrepareForReuse != NULL) {
        ((void (*)(id, SEL))OriginalActionCellPrepareForReuse)(receiver, selector);
    }
}

static NSString *YTKACEBarSlotPreference(UIView *slot) {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:slot];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 40) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = node.accessibilityIdentifier;
        if (YTKACEIsActionButtonIdentifier(identifier)) {
            NSString *preference =
                YTKACEPreferenceForButtonIdentifier(identifier);
            if (preference.length != 0) return preference;
        }
        if (node.accessibilityLabel.length != 0) {
            [labels addObject:node.accessibilityLabel.lowercaseString];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    NSString *joined = [labels componentsJoinedByString:@" "];
    if (joined.length == 0) return nil;
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask"],
        @[@"YTKACE.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([joined containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static void YTKACEFixedBarLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalFixedBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalFixedBarLayout)(receiver, selector);
    }
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;
    NSArray<UIView *> *slots = receiver.subviews;
    if (slots.count < 3 || slots.count > 10) return;
    NSString *identifier = receiver.accessibilityIdentifier;
    if (![identifier containsString:@"non_scrollable_action_bar"]) return;
    if (!YTKACEAnyActionPreferenceEnabled()) return;

    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    if (barWidth <= 0.0) return;
    CGFloat naturalSlot = barWidth / (CGFloat)slots.count;
    NSMutableArray<UIView *> *keep = [NSMutableArray array];
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    for (UIView *slot in slots) {
        NSString *preference = YTKACEBarSlotPreference(slot);
        BOOL hidden = preference.length != 0 &&
            YTKACEFeatureEnabled(preference);
        [trace addObject:[NSString stringWithFormat:@"%@%@",
            preference.length == 0 ? @"-"
                : [preference componentsSeparatedByString:@"."].lastObject,
            hidden ? @"!" : @""]];
        if (!hidden) [keep addObject:slot];
    }
    if (keep.count == 0 || keep.count == slots.count) return;

    CGFloat share = barWidth / (CGFloat)keep.count;
    NSUInteger position = 0;
    for (UIView *slot in keep) {
        CGRect frame = slot.frame;
        frame.size.width = naturalSlot;
        frame.origin.x = (CGFloat)position * share +
            (share - naturalSlot) / 2.0;
        slot.frame = frame;
        position++;
    }

    static NSTimeInterval lastLog = 0.0;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - lastLog > 2.0) {
        lastLog = now;
    }
}

static void YTKACEEnsureFixedBarHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEInstallInstanceHook(
            @"_ASDisplayView",
            @"layoutSubviews",
            (IMP)YTKACEFixedBarLayoutSubviews,
            &OriginalFixedBarLayout
        );
    });
}

static void YTKACEEnsureActionCellReuseHook(void) {
    YTKACEEnsureFixedBarHook();
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEInstallInstanceHook(
            @"_ASCollectionViewCell",
            @"prepareForReuse",
            (IMP)YTKACEActionCellPrepareForReuse,
            &OriginalActionCellPrepareForReuse
        );
    });
}

static UIView *YTKACEActionContainer(UIView *view) {
    if (YTKACEIsActionButtonIdentifier(view.accessibilityIdentifier)) {
        return view;
    }
    UIView *candidate = view;
    UIView *best = view;
    for (NSUInteger index = 0; candidate.superview != nil && index < 7; index++) {
        UIView *parent = candidate.superview;
        NSArray<NSString *> *buttons = YTKACEActionButtonIdentifiers(parent);
        NSUInteger sizable = YTKACESizableChildCount(parent);
        if ([parent isKindOfClass:UIStackView.class]) {
            YTKACERestoreHiddenView(parent);
            best = candidate;
            break;
        }
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        if (width <= 0.0 || height <= 0.0) {
            break;
        }
        if (width > 180.0 || height > 130.0) {
            break;
        }
        if (buttons.count > 1 || sizable > 1) {
            YTKACERestoreHiddenView(parent);
            break;
        }
        best = parent;
        candidate = parent;
    }
    return best;
}

static void YTKACECompactFixedActionGroup(UIView *target) {
    UIView *group = target.superview;
    if (group == nil || CGRectGetHeight(group.bounds) < 40.0 ||
        CGRectGetHeight(group.bounds) > 56.0 ||
        CGRectGetWidth(group.bounds) < 160.0 ||
        CGRectGetWidth(group.bounds) > 260.0) {
        return;
    }
    if (objc_getAssociatedObject(group,
            YTKACEActionGroupCompactAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(group,
                             YTKACEActionGroupCompactAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakGroup = group;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongGroup = weakGroup;
        if (strongGroup == nil) return;
        NSArray<UIView *> *slots = [strongGroup.subviews
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(UIView *view, __unused NSDictionary *bindings) {
                    CGFloat width = CGRectGetWidth(view.frame);
                    CGFloat height = CGRectGetHeight(view.frame);
                    return width >= 32.0 && width <= 56.0 &&
                           height >= 40.0 && height <= 56.0;
                }]];
        slots = [slots sortedArrayUsingComparator:
            ^NSComparisonResult(UIView *left, UIView *right) {
                CGFloat leftX = CGRectGetMinX(left.frame);
                CGFloat rightX = CGRectGetMinX(right.frame);
                if (leftX < rightX) return NSOrderedAscending;
                if (leftX > rightX) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        if (slots.count < 3) {
            objc_setAssociatedObject(strongGroup,
                                     YTKACEActionGroupCompactAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        CGFloat cursor = CGRectGetMinX(slots.firstObject.frame);
        for (UIView *slot in slots) {
            if (slot.hidden || slot.alpha <= 0.01) continue;
            CGRect frame = slot.frame;
            frame.origin.x = cursor;
            slot.frame = frame;
            cursor += CGRectGetWidth(frame);
        }
        objc_setAssociatedObject(strongGroup,
                                 YTKACEActionGroupCompactAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static NSArray *YTKACEFilterActionButtons(id receiver, SEL selector,
                                           IMP original) {
    NSArray *items = original == NULL ? nil :
        ((id (*)(id, SEL))original)(receiver, selector);
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return items;
    if (!YTKACEAnyActionPreferenceEnabled()) return items;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *preference = YTKACEActionPreference(item);
        if (preference.length != 0 && YTKACEFeatureEnabled(preference)) continue;
        [filtered addObject:item];
    }
    return filtered.count == items.count ? items : filtered;
}

static void YTKACEActionViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionViewDidMove)(receiver, selector);
    }
}

static void YTKACEActionsViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionsViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionsViewDidMove)(receiver, selector);
    }
}

static void YTKACEActionCellDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionCellDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionCellDidMove)(receiver, selector);
    }
}

#define YTKACE_ACTION_WRAPPER(name, storage) \
static NSArray *name(id receiver, SEL selector) { \
    return YTKACEFilterActionButtons(receiver, selector, storage); \
}

YTKACE_ACTION_WRAPPER(YTKACEScrollableActionButtonsArray, OriginalScrollableActionButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEScrollableActionBarButtonsArray, OriginalScrollableActionBarButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEScrollableButtonsArray, OriginalScrollableButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEScrollableActionsArray, OriginalScrollableActionsArray)
YTKACE_ACTION_WRAPPER(YTKACEActionButtonsArray, OriginalActionButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEActionBarButtonsArray, OriginalActionBarButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEButtonsArray, OriginalButtonsArray)
YTKACE_ACTION_WRAPPER(YTKACEActionsArray, OriginalActionsArray)

static id YTKACEContentValue(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return nil;
    }
    @try {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTKACEClassContains(id object, NSArray<NSString *> *needles);


/// Field names on `cls` whose name matches something we filter, paired with the
/// generated -has<Field> selector. Computed once per class.



static const void *YTKACEStructuralTokenAssociation =
    &YTKACEStructuralTokenAssociation;




static const void *YTKACEClassTokenAssociation = &YTKACEClassTokenAssociation;

static NSString *YTKACEClassToken(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(object,
                                                YTKACEClassTokenAssociation);
    if (cached != nil) return cached;
    NSString *value = NSStringFromClass([object class]).lowercaseString;
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, YTKACEClassTokenAssociation, value,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return value;
}

__attribute__((unused))
static BOOL YTKACEClassLooksLikeContainer(id object) {
    NSString *token = YTKACEClassToken(object);
    return [token containsString:@"shelfrenderer"] ||
           [token containsString:@"richsectionrenderer"] ||
           [token containsString:@"itemsectionrenderer"] ||
           [token containsString:@"richshelfrenderer"] ||
           [token containsString:@"sectionrenderer"] ||
           [token containsString:@"elementrenderer"];
}

static BOOL YTKACEClassContains(id object, NSArray<NSString *> *needles) {
    NSString *token = YTKACEClassToken(object);
    if (token.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([token containsString:needle]) return YES;
    }
    return NO;
}

__attribute__((unused))
static BOOL YTKACEChildClassContains(id section, NSArray<NSString *> *needles) {
    NSArray *entries = YTKACEContentValue(section, @"contentsArray");
    if ([entries isKindOfClass:NSArray.class]) {
        for (id entry in entries) {
            if (YTKACEClassContains(entry, needles)) return YES;
        }
    }
    return NO;
}

static const NSUInteger YTKACEFeedChildScanLimit = 64;

static _Atomic BOOL YTKACEFeedHideShorts = NO;
static _Atomic BOOL YTKACEFeedKeepHomeShorts = NO;
static _Atomic BOOL YTKACEFeedKeepSubsShorts = NO;
static _Atomic BOOL YTKACEFeedKeepSearchShorts = NO;
static _Atomic BOOL YTKACEFeedKeepChannelShorts = NO;
static _Atomic BOOL YTKACEFeedHideProducts = NO;
static _Atomic BOOL YTKACEFeedHideCommunity = NO;
static _Atomic BOOL YTKACEFeedHideHorizontalShelves = NO;
static _Atomic BOOL YTKACEFeedHideMixes = NO;
static _Atomic BOOL YTKACEFeedHidePlayables = NO;
static _Atomic BOOL YTKACEFeedHideAIBlock = NO;
static _Atomic BOOL YTKACEFeedHideAIWarn = NO;
static _Atomic BOOL YTKACEFeedHideAny = NO;
static _Atomic BOOL YTKACEFeedActionHideAny = NO;
static _Atomic BOOL YTKACEContentHideAny = NO;

static void YTKACEFeedRefreshFlags(void) {
    BOOL hideShorts =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.FeedHidden");
    BOOL hideProducts =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden");
    BOOL hideCommunity =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.CommunityPostsHidden");
    BOOL hideHorizontalShelves =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.HorizontalShelvesHidden");
    BOOL hideMixes =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.MixesHidden");
    BOOL hidePlayables =
        YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.PlayablesHidden");
    BOOL hideAIBlock = YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.AIChannelsHidden");
    BOOL hideAIWarn = YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.SuspectedAIChannelsHidden");
    if (hideAIBlock || hideAIWarn) YTKACEAiSListRefreshIfStale();
    BOOL hideAny = (hideShorts || hideProducts ||
        hideCommunity || hideHorizontalShelves || hideMixes || hidePlayables || hideAIBlock || hideAIWarn);
    BOOL actionHideAny = YTKACEAnyActionPreferenceEnabled();
    BOOL contentHideAny = (hideAny ||
        actionHideAny ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentsHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentPreviewsHidden") ||
        YTKACEShortsSuggestionPillHidden() ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Privacy.SearchHistoryDisabled") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.App.UpdatePromptHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.SuggestedVideosHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden") ||
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden"));
    atomic_store(&YTKACEFeedHideShorts, hideShorts);
    atomic_store(&YTKACEFeedKeepHomeShorts,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.HomeKept"));
    atomic_store(&YTKACEFeedKeepSubsShorts,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SubscriptionsKept"));
    atomic_store(&YTKACEFeedKeepSearchShorts,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.SearchKept"));
    atomic_store(&YTKACEFeedKeepChannelShorts,
        YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.ChannelsKept"));
    atomic_store(&YTKACEFeedHideProducts, hideProducts);
    atomic_store(&YTKACEFeedHideCommunity, hideCommunity);
    atomic_store(&YTKACEFeedHideHorizontalShelves, hideHorizontalShelves);
    atomic_store(&YTKACEFeedHideMixes, hideMixes);
    atomic_store(&YTKACEFeedHidePlayables, hidePlayables);
    atomic_store(&YTKACEFeedHideAIBlock, hideAIBlock);
    atomic_store(&YTKACEFeedHideAIWarn, hideAIWarn);
    atomic_store(&YTKACEFeedHideAny, hideAny);
    atomic_store(&YTKACEFeedActionHideAny, actionHideAny);
    atomic_store(&YTKACEContentHideAny, contentHideAny);
}

static void YTKACEFeedScheduleRefresh(void) {
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        YTKACEFeedRefreshFlags();
    });
}

static void YTKACEFeedEnsureFlagObserver(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEFeedRefreshFlags();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:YTKACEPreferencesDidChangeNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            YTKACEFeedScheduleRefresh();
                        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            YTKACEFeedScheduleRefresh();
                        }];
    });
}

static SEL YTKACESelContentsArray;
static SEL YTKACESelItemsArray;
static SEL YTKACESelContent;
static SEL YTKACESelElementRenderer;
static SEL YTKACESelShelfRenderer;
static SEL YTKACESelHorizontalListRenderer;
static SEL YTKACESelItemSectionRenderer;
static SEL YTKACESelExpandedShelfContentsRenderer;
static SEL YTKACESelElementIdentifier;
static SEL YTKACESelSharedElementIdentifier;
static SEL YTKACESelData;
static SEL YTKACESelHasReelItemRenderer;
static SEL YTKACESelHasMerchShelfRenderer;
static SEL YTKACESelHasMerchItemRenderer;
static SEL YTKACESelHasCommunity[5];
static SEL YTKACESelHasGame[2];
static SEL YTKACEFeedContainerSels[8];

static void YTKACEFeedInitSels(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACESelContentsArray = @selector(contentsArray);
        YTKACESelItemsArray = @selector(itemsArray);
        YTKACESelContent = @selector(content);
        YTKACESelElementRenderer = @selector(elementRenderer);
        YTKACESelShelfRenderer = @selector(shelfRenderer);
        YTKACESelHorizontalListRenderer = @selector(horizontalListRenderer);
        YTKACESelItemSectionRenderer = @selector(itemSectionRenderer);
        YTKACESelExpandedShelfContentsRenderer =
            @selector(expandedShelfContentsRenderer);
        YTKACESelElementIdentifier = @selector(elementIdentifier);
        YTKACESelSharedElementIdentifier = @selector(sharedElementIdentifier);
        YTKACESelData = @selector(data);
        YTKACESelHasReelItemRenderer = @selector(hasReelItemRenderer);
        YTKACESelHasMerchShelfRenderer =
            @selector(hasMerchandiseShelfRenderer);
        YTKACESelHasMerchItemRenderer =
            @selector(hasMerchandiseItemRenderer);
        YTKACESelHasCommunity[0] =
            @selector(hasCommunityPostSectionRenderer);
        YTKACESelHasCommunity[1] = @selector(hasCommunityPost);
        YTKACESelHasCommunity[2] =
            @selector(hasBackstagePostElementRenderer);
        YTKACESelHasCommunity[3] = @selector(hasPostsContainerRenderer);
        YTKACESelHasCommunity[4] =
            @selector(hasChannelPostBulletinRenderer);
        YTKACESelHasGame[0] = @selector(hasGameCardRenderer);
        YTKACESelHasGame[1] = @selector(hasGameDetailsRenderer);
        YTKACEFeedContainerSels[0] = YTKACESelContentsArray;
        YTKACEFeedContainerSels[1] = YTKACESelItemsArray;
        YTKACEFeedContainerSels[2] = YTKACESelContent;
        YTKACEFeedContainerSels[3] = YTKACESelElementRenderer;
        YTKACEFeedContainerSels[4] = YTKACESelShelfRenderer;
        YTKACEFeedContainerSels[5] = YTKACESelHorizontalListRenderer;
        YTKACEFeedContainerSels[6] = YTKACESelItemSectionRenderer;
        YTKACEFeedContainerSels[7] =
            YTKACESelExpandedShelfContentsRenderer;
    });
}

static inline BOOL YTKACEFastHasSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return NO;
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static inline BOOL YTKACEFastHasAnySel(id object, SEL *selectors,
                                       NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (YTKACEFastHasSel(object, selectors[i])) return YES;
    }
    return NO;
}

static inline id YTKACEFastChildSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *YTKACEFastContents(id object) {
    if (object == nil) return nil;
    YTKACEFeedInitSels();
    id value = YTKACEFastChildSel(object, YTKACESelContentsArray);
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static BOOL YTKACEFastEntryMatchesSel(id entry,
                                      SEL *flags, NSUInteger flagCount,
                                      NSArray<NSString *> *classes) {
    if (entry == nil) return NO;
    if (classes != nil && YTKACEClassContains(entry, classes)) return YES;
    if (flags != NULL && flagCount != 0 &&
        YTKACEFastHasAnySel(entry, flags, flagCount)) {
        return YES;
    }
    id nested = YTKACEFastChildSel(entry, YTKACESelElementRenderer);
    if (nested != nil && nested != entry) {
        if (classes != nil && YTKACEClassContains(nested, classes)) return YES;
        if (flags != NULL && flagCount != 0 &&
            YTKACEFastHasAnySel(nested, flags, flagCount)) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEFastIdentifierMatches(id object,
                                         NSArray<NSString *> *markers) {
    if (object == nil || markers == nil || markers.count == 0) return NO;
    YTKACEFeedInitSels();
    SEL keys[2] = { YTKACESelElementIdentifier,
                    YTKACESelSharedElementIdentifier };
    for (NSUInteger k = 0; k < 2; k++) {
        id value = YTKACEFastChildSel(object, keys[k]);
        if (![value isKindOfClass:NSString.class] ||
            ((NSString *)value).length == 0) {
            continue;
        }
        NSString *valueStr = (NSString *)value;
        if ([valueStr rangeOfString:@"."].location == NSNotFound &&
            [valueStr canBeConvertedToEncoding:NSASCIIStringEncoding]) {
            for (NSString *marker in markers) {
                if (marker.length != 0 &&
                    [valueStr rangeOfString:marker
                                    options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            }
        } else {
            NSString *token = [[valueStr lowercaseString]
                stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            for (NSString *marker in markers) {
                if (marker.length != 0 && [token containsString:marker]) return YES;
            }
        }
    }
    return NO;
}

typedef NS_OPTIONS(NSUInteger, YTKACEFeedKind) {
    YTKACEFeedKindShorts    = 1 << 0,
    YTKACEFeedKindProducts  = 1 << 1,
    YTKACEFeedKindCommunity = 1 << 2,
    YTKACEFeedKindPlayable  = 1 << 3,
    YTKACEFeedKindHorizontalShelves = 1 << 4,
};

static NSArray<NSString *> *YTKACEShortsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"reelitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTKACEShortsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"shorts_shelf", @"reel_shelf",
        @"shorts_lockup", @"shortslockup",
        @"shorts_video_cell", @"reelwatchendpoint"]; });
    return v;
}
static NSArray<NSString *> *YTKACEProductsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandiseshelfrenderer",
        @"merchandiseitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTKACEProductsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"product_in_video", @"products_in_video",
        @"promoted_sparkles_text_product"]; });
    return v;
}
static NSArray<NSString *> *YTKACECommunityClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"communitypostsectionrenderer",
        @"postscontainerrenderer", @"communitypostrenderer",
        @"backstagepostrenderer", @"backstageimagerenderer",
        @"sharedpostrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTKACECommunityIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"community_post", @"communitypost",
        @"backstage"]; });
    return v;
}
static NSArray<NSString *> *YTKACEPlayableClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playablesshelfrenderer",
        @"playableitemrenderer", @"compactboxgamerenderer",
        @"playablegamerenderer", @"gamecardrenderer",
        @"gamedetailsrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTKACEPlayableIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"horizontal_gaming_shelf", @"mini_game_card"]; });
    return v;
}

static BOOL YTKACEFastShouldDescend(id object) {
    if (object == nil) return NO;
    if ([object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSValue.class] ||
        [object isKindOfClass:NSURL.class]) {
        return NO;
    }
    return YES;
}

static inline YTKACEFeedKind YTKACEFeedKindForNode(id node,
                                                  YTKACEFeedKind wanted) {
    YTKACEFeedKind found = 0;
    if (wanted & YTKACEFeedKindShorts) {
        if (YTKACEClassContains(node, YTKACEShortsClasses()) ||
            YTKACEFastHasSel(node, YTKACESelHasReelItemRenderer) ||
            YTKACEFastIdentifierMatches(node, YTKACEShortsIdentifiers())) {
            found |= YTKACEFeedKindShorts;
        } else {
            id nested = YTKACEFastChildSel(node, YTKACESelElementRenderer);
            if (nested != nil && nested != node &&
                (YTKACEClassContains(nested, YTKACEShortsClasses()) ||
                 YTKACEFastHasSel(nested, YTKACESelHasReelItemRenderer))) {
                found |= YTKACEFeedKindShorts;
            }
        }
    }
    if ((wanted & YTKACEFeedKindProducts) && !(found & YTKACEFeedKindProducts)) {
        SEL f[2] = { YTKACESelHasMerchShelfRenderer,
                     YTKACESelHasMerchItemRenderer };
        if (YTKACEFastEntryMatchesSel(node, f, 2,
                                      YTKACEProductsClasses()) ||
            YTKACEFastIdentifierMatches(node,
                                        YTKACEProductsIdentifiers())) {
            found |= YTKACEFeedKindProducts;
        }
    }
    if ((wanted & YTKACEFeedKindCommunity) &&
        !(found & YTKACEFeedKindCommunity)) {
        if (YTKACEFastEntryMatchesSel(node, YTKACESelHasCommunity, 5,
                                      YTKACECommunityClasses()) ||
            YTKACEFastIdentifierMatches(node,
                                        YTKACECommunityIdentifiers())) {
            found |= YTKACEFeedKindCommunity;
        }
    }
    if ((wanted & YTKACEFeedKindPlayable) &&
        !(found & YTKACEFeedKindPlayable)) {
        if (YTKACEFastEntryMatchesSel(node, YTKACESelHasGame, 2,
                                      YTKACEPlayableClasses()) ||
            YTKACEFastIdentifierMatches(node,
                                        YTKACEPlayableIdentifiers())) {
            found |= YTKACEFeedKindPlayable;
        }
    }
    return found;
}

static YTKACEFeedKind YTKACEFeedKindStructural(id section,
                                              YTKACEFeedKind wanted,
                                              BOOL *outTruncated) {
    if (outTruncated != NULL) *outTruncated = NO;
    if (section == nil || wanted == 0) return 0;
    YTKACEFeedInitSels();
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsWeakMemory];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:section];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    YTKACEFeedKind found = 0;
    NSUInteger scanned = 0;
    while (pending.count != 0 && pending.count < 4096) {
        if (scanned >= YTKACEFeedChildScanLimit) {
            if (outTruncated != NULL) *outTruncated = YES;
            break;
        }
        id node = pending.lastObject;
        [pending removeLastObject];
        NSNumber *depth = depths.lastObject;
        [depths removeLastObject];
        if (node == nil || [visited containsObject:node]) continue;
        [visited addObject:node];
        scanned++;
        found |= YTKACEFeedKindForNode(node, wanted & ~found);
        if ((found & wanted) == wanted) return found;
        if (depth.unsignedIntegerValue >= 3) continue;
        NSNumber *next = @(depth.unsignedIntegerValue + 1);
        if ([node isKindOfClass:NSArray.class]) {
            for (id child in (NSArray *)node) {
                if (!YTKACEFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
            continue;
        }
        if (!YTKACEFastShouldDescend(node)) continue;
        for (NSUInteger i = 0; i < 8; i++) {
            id child = YTKACEFastChildSel(node, YTKACEFeedContainerSels[i]);
            if (child == nil || child == node) continue;
            if ([child isKindOfClass:NSArray.class]) {
                for (id grand in (NSArray *)child) {
                    if (!YTKACEFastShouldDescend(grand)) continue;
                    if ([visited containsObject:grand]) continue;
                    [pending addObject:grand];
                    [depths addObject:next];
                }
            } else {
                if (!YTKACEFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
        }
    }
    return found;
}

static BOOL YTKACEFastEntryIsReel(id entry) {
    if (entry == nil) return NO;
    YTKACEFeedInitSels();
    if (YTKACEClassContains(entry, YTKACEShortsClasses())) return YES;
    if (YTKACEFastHasSel(entry, YTKACESelHasReelItemRenderer)) return YES;
    id nested = YTKACEFastChildSel(entry, YTKACESelElementRenderer);
    if (nested != nil && nested != entry) {
        if (YTKACEClassContains(nested, YTKACEShortsClasses())) return YES;
        if (YTKACEFastHasSel(nested, YTKACESelHasReelItemRenderer)) return YES;
    }
    return NO;
}

static BOOL YTKACEFastAllChildrenReel(id section) {
    NSArray *entries = YTKACEFastContents(section);
    if (![entries isKindOfClass:NSArray.class] || entries.count == 0) return NO;
    for (id entry in entries) {
        if (!YTKACEFastEntryIsReel(entry)) return NO;
    }
    return YES;
}



static const void *YTKACENormalizedDescriptionAssociation =
    &YTKACENormalizedDescriptionAssociation;

static NSString *YTKACENormalizedDescription(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(
        object, YTKACENormalizedDescriptionAssociation);
    if (cached != nil) return cached;
    NSString *value = [[[object description] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, YTKACENormalizedDescriptionAssociation, value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return value;
}

static const void *YTKACESectionBytesAssociation =
    &YTKACESectionBytesAssociation;

static NSData *YTKACESectionBytes(id section) {
    if (section == nil) return nil;
    NSData *cached = objc_getAssociatedObject(section,
                                              YTKACESectionBytesAssociation);
    if (cached != nil) {
        return cached.length == 0 ? nil : cached;
    }
    YTKACEFeedInitSels();
    id data = YTKACEFastChildSel(section, YTKACESelData);
    if (![data isKindOfClass:NSData.class]) data = nil;
    objc_setAssociatedObject(section, YTKACESectionBytesAssociation,
                             data ?: [NSData data],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data;
}

static NSData *YTKACEDescendantBytes(id section) {
    YTKACEFeedInitSels();
    NSMutableData *combined = nil;
    for (NSUInteger i = 0; i < 8; i++) {
        id child = YTKACEFastChildSel(section, YTKACEFeedContainerSels[i]);
        if (child == nil) continue;
        NSArray *entries = [child isKindOfClass:NSArray.class]
            ? (NSArray *)child : @[child];
        NSUInteger taken = 0;
        for (id entry in entries) {
            if (taken >= 12) break;
            taken++;
            NSData *bytes = YTKACESectionBytes(entry);
            if (bytes.length == 0) continue;
            if (combined == nil) combined = [NSMutableData data];
            [combined appendData:bytes];
        }
    }
    return combined;
}


static BOOL YTKACEBytesContain(NSData *haystack, NSArray<NSString *> *needles) {
    if (haystack.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([needle containsString:@"renderer"] &&
            ![needle containsString:@"_"]) {
            continue;  // class-name style marker, never present in the wire form
        }
        NSData *pattern = [needle dataUsingEncoding:NSASCIIStringEncoding];
        if (pattern.length == 0) continue;
        if ([haystack rangeOfData:pattern
                           options:0
                             range:NSMakeRange(0, haystack.length)].location
                != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *YTKACEProductsMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"promoted_sparkles_text_product_watch",
        @"product_in_video", @"products_in_video"
    ]; });
    return v;
}

static NSArray<NSString *> *YTKACEShortsBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"/oar2.jpg", @"reel_shelf", @"reelwatchendpoint",
        @"shorts_lockup", @"shorts_shelf", @"shorts_video_cell",
        @"shortslockup", @"shortslockupviewmodel", @"shortsshelfeml"
    ]; });
    return v;
}
static NSArray<NSString *> *YTKACECommunityBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"backstage_post",
        @"community_post",
        @"community_post_section",
        @"id.ui.backstage.original_post",
        @"id.ui.backstage.post",
        @"id.ui.backstage.post_menu_button",
        @"id_ui_backstage_original_post",
        @"image_post_root.eml",
        @"images_post_responsive_root",
        @"images_post_root",
        @"images_post_root.eml",
        @"images_post_root_slim",
        @"images_post_root_slim.eml",
        @"images_post_slim",
        @"options_post_responsive_root",
        @"options_post_root",
        @"poll_post_responsive_root",
        @"poll_post_root",
        @"post_base_wrapper",
        @"post_base_wrapper.eml",
        @"post_base_wrapper_slim",
        @"post_base_wrapper_slim.eml",
        @"post_shelf",
        @"post_shelf_slim",
        @"shared_post_responsive_root",
        @"shared_post_root",
        @"text_post_responsive_root",
        @"text_post_root",
        @"text_post_root.eml",
        @"text_post_root_slim",
        @"videos_post_responsive_root",
        @"videos_post_root"
    ]; });
    return v;
}
static NSArray<NSString *> *YTKACEMixBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"&list=RD"
    ]; });
    return v;
}
static NSArray<NSString *> *YTKACEPlayableBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"playables.shelf", @"playable.game",
        @".com/playables/", @"playables_shelf.eml",
        @"playable_card.eml",
        @"horizontal_gaming_shelf", @"mini_game_card"
    ]; });
    return v;
}

static NSArray<NSString *> *YTKACEHorizontalShelfBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"horizontal_shelf.eml",
    ]; });
    return v;
}

static const void *YTKACEFeedKindKey = &YTKACEFeedKindKey;
static const void *YTKACEFeedSearchedKey = &YTKACEFeedSearchedKey;


static YTKACEFeedKind YTKACEFeedKindForSection(id section,
                                              YTKACEFeedKind wanted) {
    if (section == nil || wanted == 0) return 0;
    if ([NSStringFromClass([section class])
            isEqualToString:@"YTIFeedFilterChipBarRenderer"]) {
        return 0;
    }
    NSNumber *memo = objc_getAssociatedObject(section, YTKACEFeedKindKey);
    YTKACEFeedKind cached = memo.unsignedIntegerValue;
    YTKACEFeedKind searched = [objc_getAssociatedObject(
        section, YTKACEFeedSearchedKey) unsignedIntegerValue];
    if (memo != nil && ((searched & wanted) == wanted)) {
        return cached & wanted;
    }
    BOOL truncated = NO;
    YTKACEFeedKind structural = YTKACEFeedKindStructural(
        section, wanted & ~YTKACEFeedKindHorizontalShelves, &truncated);
    if ((wanted & YTKACEFeedKindShorts) &&
        !(structural & YTKACEFeedKindShorts)) {
        if (YTKACEFastAllChildrenReel(section)) {
            structural |= YTKACEFeedKindShorts;
        }
    }
    YTKACEFeedKind missing = wanted & ~structural;
    if (missing != 0) {
        NSData *bytes = YTKACESectionBytes(section);
        if (bytes.length == 0) bytes = YTKACEDescendantBytes(section);
        if (bytes.length != 0) {
            if ((missing & YTKACEFeedKindShorts) &&
                YTKACEBytesContain(bytes, YTKACEShortsBytesMarkers())) {
                structural |= YTKACEFeedKindShorts;
            }
            if ((missing & YTKACEFeedKindProducts) &&
                YTKACEBytesContain(bytes, YTKACEProductsMarkers())) {
                structural |= YTKACEFeedKindProducts;
            }
            if ((missing & YTKACEFeedKindCommunity) &&
                YTKACEBytesContain(bytes, YTKACECommunityBytesMarkers())) {
                structural |= YTKACEFeedKindCommunity;
            }
            if ((missing & YTKACEFeedKindPlayable) &&
                YTKACEBytesContain(bytes, YTKACEPlayableBytesMarkers())) {
                structural |= YTKACEFeedKindPlayable;
            }
            if ((missing & YTKACEFeedKindHorizontalShelves) &&
                YTKACEBytesContain(bytes,
                                   YTKACEHorizontalShelfBytesMarkers())) {
                structural |= YTKACEFeedKindHorizontalShelves;
            }
        }
    }
    objc_setAssociatedObject(section, YTKACEFeedKindKey, @(structural),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const YTKACEFeedKind settled =
        truncated ? (searched | (wanted & structural)) : (searched | wanted);
    objc_setAssociatedObject(section, YTKACEFeedSearchedKey, @(settled),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return structural & wanted;
}

static BOOL YTKACEIsGuidelinesSection(id section);

typedef NS_ENUM(NSUInteger, YTKACEFeedSurface) {
    YTKACEFeedSurfaceUnknown = 0,
    YTKACEFeedSurfaceHome,
    YTKACEFeedSurfaceSubscriptions,
    YTKACEFeedSurfaceSearch,
    YTKACEFeedSurfaceChannel,
};

static NSString *YTKACEBrowseID(id object) {
    if (object == nil) return nil;
    static SEL browseSel;
    if (browseSel == NULL) browseSel = NSSelectorFromString(@"browseID");
    static SEL identifierSel;
    if (identifierSel == NULL) {
        identifierSel = NSSelectorFromString(@"browseIdentifier");
    }
    for (NSUInteger index = 0; index < 2; index++) {
        SEL selector = index == 0 ? browseSel : identifierSel;
        if (selector == NULL || ![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:NSString.class] && ((NSString *)value).length != 0) {
            return (NSString *)value;
        }
    }
    return nil;
}

static BOOL YTKACEIsChannelBrowseID(NSString *browseID) {
    if ([browseID hasPrefix:@"UC"] || [browseID hasPrefix:@"@"]) return YES;
    NSRange slash = [browseID rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return NO;
    static NSSet<NSString *> *tabs;
    if (tabs == nil) {
        tabs = [NSSet setWithArray:@[@"videos", @"shorts", @"streams", @"live",
            @"community", @"playlists", @"featured", @"home"]];
    }
    NSString *tab = [[browseID substringFromIndex:slash.location + 1]
        lowercaseString];
    return [tabs containsObject:tab];
}

static YTKACEFeedSurface YTKACESurfaceForBrowseID(NSString *browseID) {
    if (browseID.length == 0) return YTKACEFeedSurfaceUnknown;
    if ([browseID isEqualToString:@"FEwhat_to_watch"]) {
        return YTKACEFeedSurfaceHome;
    }
    if ([browseID isEqualToString:@"FEsubscriptions"]) {
        return YTKACEFeedSurfaceSubscriptions;
    }
    if (YTKACEIsChannelBrowseID(browseID)) {
        return YTKACEFeedSurfaceChannel;
    }
    return YTKACEFeedSurfaceUnknown;
}

static id YTKACESurfaceAncestor(id receiver, NSString *className) {
    if (receiver == nil || className.length == 0) return nil;
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    SEL parentSel = NSSelectorFromString(@"parentViewController");
    id walk = receiver;
    for (NSUInteger depth = 0; walk != nil && depth < 12; depth++) {
        if ([walk isKindOfClass:cls]) return walk;
        id parent = [walk respondsToSelector:parentSel]
            ? ((id (*)(id, SEL))objc_msgSend)(walk, parentSel) : nil;
        if (parent == nil && [walk isKindOfClass:UIResponder.class]) {
            parent = ((UIResponder *)walk).nextResponder;
        }
        if (parent == walk) break;
        walk = parent;
    }
    return nil;
}

static const void *YTKACEFeedSurfaceAssociation = &YTKACEFeedSurfaceAssociation;

static YTKACEFeedSurface YTKACEShortsSurface(id receiver) {
    if (receiver == nil) return YTKACEFeedSurfaceUnknown;
    NSNumber *memo = objc_getAssociatedObject(receiver, YTKACEFeedSurfaceAssociation);
    if (memo != nil) return (YTKACEFeedSurface)memo.unsignedIntegerValue;

    YTKACEFeedSurface surface = YTKACESurfaceForBrowseID(YTKACEBrowseID(receiver));
    if (surface == YTKACEFeedSurfaceUnknown) {
        if (YTKACESurfaceAncestor(receiver, @"YTSearchResultsViewController") != nil) {
            surface = YTKACEFeedSurfaceSearch;
        }
    }
    if (surface == YTKACEFeedSurfaceUnknown) {
        surface = YTKACESurfaceForBrowseID(
            YTKACEBrowseID(YTKACESurfaceAncestor(receiver, @"YTBrowseViewController")));
    }
    if (surface != YTKACEFeedSurfaceUnknown) {
        objc_setAssociatedObject(receiver, YTKACEFeedSurfaceAssociation,
                                 @(surface), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return surface;
}

static BOOL YTKACEKeepsShortsInFeed(id receiver) {
    NSString *browseID = YTKACEBrowseID(receiver);
    static NSSet<NSString *> *personal;
    if (personal == nil) {
        personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary",
            @"FEplaylist_aggregation"]];
    }
    if ([personal containsObject:browseID]) return YES;
    YTKACEFeedSurface surface = YTKACEShortsSurface(receiver);
    BOOL keep = NO;
    switch (surface) {
        case YTKACEFeedSurfaceHome:
            keep = atomic_load(&YTKACEFeedKeepHomeShorts);
            break;
        case YTKACEFeedSurfaceSubscriptions:
            keep = atomic_load(&YTKACEFeedKeepSubsShorts);
            break;
        case YTKACEFeedSurfaceSearch:
            keep = atomic_load(&YTKACEFeedKeepSearchShorts);
            break;
        case YTKACEFeedSurfaceChannel:
            keep = atomic_load(&YTKACEFeedKeepChannelShorts);
            break;
        case YTKACEFeedSurfaceUnknown:
            break;
    }
    static NSString *const names[] = { @"unknown", @"home", @"subscriptions",
        @"search", @"channel" };
    YTKACEDebugLog(@"shorts", @"surface=%@ browse=%@ keep=%@ class=%@",
        names[surface], browseID.length == 0 ? @"-" : browseID,
        keep ? @"yes" : @"no", NSStringFromClass([receiver class]));
    return keep;
}

static BOOL YTKACEKeepsShelvesInFeed(id receiver) {
    static NSSet<NSString *> *personal;
    if (personal == nil) personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary"]];
    return [personal containsObject:YTKACEBrowseID(receiver)];
}

static const void *YTKACEAIChannelKey = &YTKACEAIChannelKey;

static BOOL YTKACESectionIsAIChannel(id receiver, id section, BOOL blocklist, BOOL warnlist) {
    NSString *mode = blocklist && warnlist ? @"both" : blocklist ? @"block" : @"warn";
    NSString *memo = objc_getAssociatedObject(section, YTKACEAIChannelKey);
    if ([memo hasPrefix:mode]) return memo.length > mode.length;
    if (!YTKACEAiSListReady()) return NO;
    NSData *bytes = YTKACESectionBytes(section);
    if (bytes.length == 0) bytes = YTKACEDescendantBytes(section);
    NSString *matched = nil;
    BOOL hit = YTKACEAiSListMatches(bytes, blocklist, warnlist, &matched);
    objc_setAssociatedObject(section, YTKACEAIChannelKey, hit ? [mode stringByAppendingString:matched] : mode,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!hit) {
        YTKACEFeedInitSels();
        id contents = YTKACEFastChildSel(section, YTKACESelContentsArray);
        if ([contents isKindOfClass:NSMutableArray.class] && [contents count] > 1) {
            NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            [(NSArray *)contents enumerateObjectsUsingBlock:^(id entry, NSUInteger index, __unused BOOL *stop) {
                NSString *entryMatch = nil;
                if (YTKACEAiSListMatches(YTKACESectionBytes(entry), blocklist, warnlist, &entryMatch)) {
                    [drop addIndex:index];
                    [names addObject:entryMatch];
                }
            }];
            if (drop.count != 0 && drop.count < [contents count]) {
                [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
                YTKACEDebugLog(@"aislist", @"hid %lu of %lu items [%@] class=%@", (unsigned long)drop.count,
                                  (unsigned long)([contents count] + drop.count), [names componentsJoinedByString:@","],
                                  NSStringFromClass([section class]));
            } else if (drop.count != 0) {
                hit = YES;
                matched = names.firstObject;
                objc_setAssociatedObject(section, YTKACEAIChannelKey, [mode stringByAppendingString:matched],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (hit) {
        YTKACEDebugLog(@"aislist", @"hid %@ in %@ (%@) class=%@", matched,
                          YTKACEBrowseID(receiver) ?: @"-",
                          NSStringFromClass([receiver class]), NSStringFromClass([section class]));
    }
    return hit;
}

static BOOL YTKACEEntryIsMix(id entry) {
    NSData *bytes = YTKACESectionBytes(entry);
    if (bytes.length == 0) return NO;
    return YTKACEBytesContain(bytes, YTKACEMixBytesMarkers());
}

static BOOL YTKACEMixFilteredEntries(id section) {
    YTKACEFeedInitSels();
    NSData *bytes = YTKACESectionBytes(section);
    if (bytes.length != 0 &&
        !YTKACEBytesContain(bytes, YTKACEMixBytesMarkers())) {
        return NO;
    }
    id contents = YTKACEFastChildSel(section, YTKACESelContentsArray);
    if (![contents isKindOfClass:NSMutableArray.class]) return NO;
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    [(NSArray *)contents enumerateObjectsUsingBlock:^(id entry, NSUInteger index,
                                                      __unused BOOL *stop) {
        if (YTKACEEntryIsMix(entry)) [drop addIndex:index];
    }];
    if (drop.count == 0) return NO;
    [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
    return [(NSArray *)contents count] == 0;
}

static NSArray *YTKACEMixFilteredFeedSections(NSArray *sections) {
    if (!atomic_load(&YTKACEFeedHideMixes)) return sections;
    if (![sections isKindOfClass:NSArray.class]) return sections;
    NSMutableIndexSet *empty = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < sections.count; index++) {
        if (YTKACEMixFilteredEntries(sections[index])) {
            [empty addIndex:index];
        }
    }
    if (empty.count == 0) return sections;
    NSMutableArray *kept = [sections mutableCopy];
    [kept removeObjectsAtIndexes:empty];
    return kept;
}

static NSArray *YTKACEFilteredFeedSections(id receiver, NSArray *sections) {
    YTKACEFeedEnsureFlagObserver();
    NSArray *adFiltered = YTKACEMixFilteredFeedSections(
        YTKACEFilterAdSections(sections));
    if ([adFiltered isKindOfClass:NSArray.class] && adFiltered.count != 0 &&
        YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden")) {
        NSIndexSet *guidelines = [adFiltered indexesOfObjectsPassingTest:
            ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
            return YTKACEIsGuidelinesSection(section);
        }];
        if (guidelines.count != 0) {
            NSMutableArray *kept = [adFiltered mutableCopy];
            [kept removeObjectsAtIndexes:guidelines];
            adFiltered = kept;
        }
    }
    if (!atomic_load(&YTKACEFeedHideAny) ||
        ![adFiltered isKindOfClass:NSArray.class]) {
        return adFiltered;
    }
    BOOL hideShorts = atomic_load(&YTKACEFeedHideShorts) && !YTKACEKeepsShortsInFeed(receiver);
    BOOL hideProducts = atomic_load(&YTKACEFeedHideProducts);
    BOOL hideCommunity = atomic_load(&YTKACEFeedHideCommunity);
    BOOL hideHorizontalShelves = atomic_load(&YTKACEFeedHideHorizontalShelves) &&
        !YTKACEKeepsShelvesInFeed(receiver);
    BOOL hidePlayables = atomic_load(&YTKACEFeedHidePlayables);
    YTKACEFeedKind wanted = 0;
    if (hideShorts) wanted |= YTKACEFeedKindShorts;
    if (hideProducts) wanted |= YTKACEFeedKindProducts;
    if (hideCommunity) wanted |= YTKACEFeedKindCommunity;
    if (hidePlayables) wanted |= YTKACEFeedKindPlayable;
    if (hideHorizontalShelves) wanted |= YTKACEFeedKindHorizontalShelves;
    BOOL hideAIBlock = atomic_load(&YTKACEFeedHideAIBlock);
    BOOL hideAIWarn = atomic_load(&YTKACEFeedHideAIWarn);
    if (wanted == 0 && !hideAIBlock && !hideAIWarn) return adFiltered;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:adFiltered.count];
    for (id section in adFiltered) {
        YTKACEFeedKind kind = wanted != 0 ? YTKACEFeedKindForSection(section, wanted) : 0;
        NSString *cut = nil;
        if ((hideAIBlock || hideAIWarn) && YTKACESectionIsAIChannel(receiver, section, hideAIBlock, hideAIWarn)) {
            continue;
        }
        if (hideShorts && (kind & YTKACEFeedKindShorts)) cut = @"shorts";
        else if (hideProducts && (kind & YTKACEFeedKindProducts)) cut = @"products";
        else if (hideCommunity && (kind & YTKACEFeedKindCommunity)) cut = @"community";
        else if (hidePlayables && (kind & YTKACEFeedKindPlayable)) cut = @"playables";
        else if (hideHorizontalShelves &&
            (kind & YTKACEFeedKindHorizontalShelves)) cut = @"shelves";
        if (cut != nil) {
            continue;
        }
        [filtered addObject:section];
    }
    return filtered;
}

static id YTKACESectionControllers(id receiver, SEL selector,
                                   NSArray *sections, id reloadMap) {
    if (OriginalSectionControllers == NULL) return nil;
    YTKACEEnsureStructuralActionHook();
    NSArray *filtered = YTKACEFilteredFeedSections(receiver, sections);
    return ((id (*)(id, SEL, id, id))OriginalSectionControllers)(
        receiver, selector, filtered, reloadMap);
}

static BOOL YTKACEContentContains(NSString *token,
                                  NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEViewInsideReelOverlay(UIView *view);

static BOOL YTKACEContentShouldHide(UIView *view, BOOL *hideSuperview) {
    NSString *identifier = [view.accessibilityIdentifier.lowercaseString
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                       identifier ?: @"",
                       view.accessibilityLabel.lowercaseString ?: @"",
                       NSStringFromClass(view.class).lowercaseString];

    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentsHidden")) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"]) {
            if (hideSuperview != NULL) {
                *hideSuperview = YES;
            }
            return YES;
        }
        if (YTKACEContentContains(token, @[
            @"id_ui_comments_composite_entry_point_teaser",
            @"id_ui_comments_entry_point_teaser",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container"
        ])) {
            return YES;
        }
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentPreviewsHidden") &&
        [identifier isEqualToString:@"id_ui_comments_entry_point_teaser"]) {
        return YES;
    }
    if (YTKACEShortsSuggestionPillHidden() &&
        [identifier isEqualToString:
            @"id_elements_components_suggested_action"] &&
        YTKACEViewInsideReelOverlay(view)) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden") &&
        YTKACEContentContains(token, @[
            @"id_comment_guidelines_text",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container",
            @"channel_guidelines_entry_banner",
            @"community_guidelines",
            @"viewer_engagement_message"
        ])) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"] &&
            hideSuperview != NULL) {
            *hideSuperview = YES;
        }
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden") &&
        YTKACEContentContains(token, @[@"topic_chip", @"feed_filter", @"chip_cloud"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Privacy.SearchHistoryDisabled") &&
        YTKACEContentContains(token, @[@"search_history", @"history_suggestion"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        YTKACEContentContains(token, @[@"paid_promotion", @"paidpromotion"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") &&
        YTKACEContentContains(token, @[@"premium_upsell", @"premium_promo"])) {
        return YES;
    }
    if ((YTKACEFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") ||
         YTKACEFeatureEnabled(@"YTKACE.Preference.App.UpdatePromptHidden")) &&
        YTKACEContentContains(token, @[@"update_dialog", @"upgrade_dialog"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.SuggestedVideosHidden") &&
        YTKACEContentContains(token, @[@"suggested_video", @"related_video"])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") &&
        YTKACEContentContains(token, @[
            @"continue_watching", @"continuewatching", @"resume_watching"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden") &&
        YTKACEContentContains(token, @[
            @"shorts_pause", @"reel_pause", @"pause_card", @"pausecard",
            @"paused_state_carousel", @"reelpausedstatecarousel"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACEContentContains(token, @[
            @"shorts_product", @"product_sticker", @"shopping_carousel",
            @"shopping_destination", @"tagged_product", @"creator_product"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden") &&
        YTKACEContentContains(token, @[
            @"brand_link_sticker", @"product_sticker", @"promoted_sticker",
            @"sponsored_sticker", @"shorts_ads_shopping"
        ])) {
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACEContentContains(token, YTKACEProductsMarkers())) {
        return YES;
    }
    if (YTKACEFeatureEnabled(
            @"YTKACE.Preference.Feed.CommunityPostsHidden") &&
        [identifier isEqualToString:@"id_ui_backstage_original_post"]) {
        YTKACECollapseHostCell(view);
        return YES;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.MixesHidden") &&
        [identifier isEqualToString:@"feed_nudge_view"]) {
        return YES;
    }
    return NO;
}

static void YTKACEScheduleFixedBarLayout(UIView *view) {
    UIView *bar = nil;
    UIView *walk = view;
    for (NSUInteger depth = 0; walk != nil && depth < 8; depth++) {
        if ([walk.accessibilityIdentifier
                containsString:@"non_scrollable_action_bar"]) {
            bar = walk;
            break;
        }
        walk = walk.superview;
    }
    if (bar == nil) return;
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (strongBar == nil) return;
        [strongBar setNeedsLayout];
        [strongBar layoutIfNeeded];
    });
}

static void YTKACEApplyContentVisibility(UIView *view) {
    YTKACEFeedEnsureFlagObserver();
    if (!atomic_load(&YTKACEContentHideAny) &&
        !atomic_load(&YTKACEFeedActionHideAny)) {
        NSNumber *idleBaseline = objc_getAssociatedObject(
            view, YTKACEContentHiddenAssociation);
        if (idleBaseline == nil) return;
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, YTKACEContentHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *actionPreference = atomic_load(&YTKACEFeedActionHideAny)
        ? YTKACEActionPreferenceForView(view) : nil;
    if (actionPreference.length != 0) {
        YTKACEEnsureStructuralActionHook();
        UIView *target = YTKACEActionContainer(view);
        BOOL hidden = YTKACEFeatureEnabled(actionPreference);
        NSNumber *baseline = objc_getAssociatedObject(
            target,
            YTKACEContentHiddenAssociation
        );
        if (hidden) {
            if (baseline == nil) {
                objc_setAssociatedObject(target,
                                         YTKACEContentHiddenAssociation, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            target.hidden = YES;
            target.userInteractionEnabled = NO;
            YTKACERefreshActionCollection(view);
        } else if (baseline != nil) {
            target.hidden = NO;
            target.userInteractionEnabled = YES;
            objc_setAssociatedObject(target,
                                     YTKACEContentHiddenAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        YTKACECompactFixedActionGroup(target);
        YTKACEScheduleFixedBarLayout(view);
        return;
    }

    BOOL hideSuperview = NO;
    BOOL hidden = YTKACEContentShouldHide(view, &hideSuperview);

    UIView *target = hideSuperview ? view.superview : view;
    if (target == nil) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        target,
        YTKACEContentHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(target,
                                     YTKACEContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        target.hidden = YES;
        target.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        target.hidden = NO;
        target.userInteractionEnabled = YES;
        objc_setAssociatedObject(target,
                                 YTKACEContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACEConsiderProductDisplayView(UIView *view, NSString *identifier) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACEProductIdentifierMatches(identifier)) {
        YTKACEHideProductSubtree(view);
    }
}




static void YTKACEDisplayViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalDisplayViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalDisplayViewDidMove)(receiver, selector);
    }
    YTKACEApplyContentVisibility(receiver);
    YTKACEHandleAdDisplayView(receiver);
    YTKACEConsiderProductDisplayView(receiver, receiver.accessibilityIdentifier);
}




static BOOL YTKACEViewInsideReelOverlay(UIView *view) {
    UIView *walker = view;
    for (NSUInteger depth = 0; depth < 12 && walker != nil; depth++) {
        if ([walker.accessibilityIdentifier isEqualToString:@"id.reel_overlay"]) {
            return YES;
        }
        walker = walker.superview;
    }
    return NO;
}




static void YTKACEDisplayViewSetIdentifier(UIView *receiver,
                                           SEL selector,
                                           NSString *identifier) {
    if (OriginalDisplayViewSetIdentifier != NULL) {
        ((void (*)(id, SEL, id))OriginalDisplayViewSetIdentifier)(
            receiver,
            selector,
            identifier
        );
    }
    YTKACEApplyContentVisibility(receiver);
    YTKACEHandleAdDisplayView(receiver);
    YTKACEConsiderProductDisplayView(receiver, identifier);
}

static BOOL YTKACEHideTopics(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden");
}

static void YTKACECollapseSubheader(id receiver) {
    SEL height = NSSelectorFromString(@"setMaximumSubheaderHeight:");
    if ([receiver respondsToSelector:height]) {
        ((void (*)(id, SEL, double))objc_msgSend)(receiver, height, 0.0);
    }
    for (NSString *name in @[@"hideSubheaderBar", @"disableSubheaderBar",
                             @"setSubheaderHeightToZero",
                             @"resetScrollViewInsetOffset"]) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    SEL enabled = NSSelectorFromString(@"setSubheaderBarEnabled:");
    if ([receiver respondsToSelector:enabled]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(receiver, enabled, NO);
    }
}

static double YTKACEMaximumSubheaderHeightGetter(id receiver, SEL selector) {
    if (YTKACEHideTopics()) return 0.0;
    return OriginalMaximumSubheaderHeightGetter == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalMaximumSubheaderHeightGetter)(
            receiver, selector);
}

static double YTKACESubheaderDefaultHeight(id receiver, SEL selector) {
    if (YTKACEHideTopics()) return 0.0;
    return OriginalSubheaderDefaultHeight == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalSubheaderDefaultHeight)(
            receiver, selector);
}

static void YTKACEPaidContentLayout(UIView *receiver, SEL selector) {
    if (OriginalPaidContentLayout != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentLayout)(receiver, selector);
    }
    BOOL hide = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden");
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, YTKACEContentHiddenAssociation);
    if (hide) {
        if (baseline == nil) {
            objc_setAssociatedObject(receiver,
                                     YTKACEContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        receiver.hidden = YES;
        receiver.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 YTKACEContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTKACEPaidContentDidAppear(UIViewController *receiver,
                                       SEL selector,
                                       BOOL animated) {
    if (OriginalPaidContentDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPaidContentDidAppear)(
            receiver, selector, animated);
    }
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return;
    receiver.view.hidden = YES;
    receiver.view.userInteractionEnabled = NO;
    for (NSString *name in @[@"hidePaidContent",
                             @"removePaidContentViewController"]) {
        SEL action = NSSelectorFromString(name);
        if ([receiver respondsToSelector:action]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, action);
        }
    }
}

static void YTKACEPaidContentPlaybackStarted(id receiver, SEL selector) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalPaidContentPlaybackStarted != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentPlaybackStarted)(receiver, selector);
    }
}

static void YTKACESetPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalSetPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTKACESetPaidContentRenderer(id receiver, SEL selector, id renderer) {
    if (OriginalSetPaidContentRenderer != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentRenderer)(
            receiver, selector,
            YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") ? nil : renderer);
    }
}

static BOOL YTKACEHasPaidContentOverlay(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return NO;
    return OriginalHasPaidContentOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasPaidContentOverlay)(receiver, selector);
}

static id YTKACEPaidContentOverlay(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return nil;
    return OriginalPaidContentOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalPaidContentOverlay)(receiver, selector);
}

static void YTKACEOverlayPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalOverlayPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalOverlayPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTKACEInlinePaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalInlinePaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalInlinePaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTKACEDidInsertPlayerOverlay(id receiver, SEL selector,
                                         id provider, id overlay) {
    NSString *identifier = YTKACEContentValue(overlay, @"overlayIdentifier");
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        [identifier isEqualToString:@"player_overlay_paid_content"]) {
        return;
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        [identifier isEqualToString:@"player_overlay_product_in_video"]) {
        return;
    }
    if (OriginalDidInsertPlayerOverlay != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidInsertPlayerOverlay)(
            receiver, selector, provider, overlay);
    }
}

static void YTKACEEnableSubheaderBar(__unsafe_unretained id receiver, SEL selector,
                                     __unsafe_unretained id view) {
    BOOL hide = YTKACEHideTopics();
    if (hide) {
        YTKACECollapseSubheader(receiver);
        return;
    }
    if (OriginalEnableSubheaderBar != NULL) {
        ((void (*)(id, SEL, id))OriginalEnableSubheaderBar)(receiver, selector, view);
    }
}

static void YTKACEChipBarUpdate(__unsafe_unretained id receiver, SEL selector,
                                __unsafe_unretained id collectionViewController,
                                __unsafe_unretained id host,
                                __unsafe_unretained id renderer,
                                __unsafe_unretained id browseIdentifier,
                                __unsafe_unretained id sectionList) {
    BOOL hide = YTKACEHideTopics();
    if (hide) return;
    if (OriginalChipBarUpdate != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id))OriginalChipBarUpdate)(
            receiver, selector, collectionViewController, host, renderer,
            browseIdentifier, sectionList);
    }
}

static void YTKACEChipCloudSetEntry(__unsafe_unretained id receiver, SEL selector,
                                    __unsafe_unretained id entry) {
    if (OriginalChipCloudSetEntry != NULL) {
        ((void (*)(id, SEL, id))OriginalChipCloudSetEntry)(receiver, selector, entry);
    }
    BOOL hide = YTKACEHideTopics();
    if (!hide) return;
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = (UIView *)receiver;
        cell.hidden = YES;
        cell.userInteractionEnabled = NO;
    }
}

static void YTKACEChipCloudLayout(__unsafe_unretained id receiver, SEL selector) {
    if (OriginalChipCloudLayout != NULL) {
        ((void (*)(id, SEL))OriginalChipCloudLayout)(receiver, selector);
    }
    BOOL hide = YTKACEHideTopics();
    if (!hide) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *cell = (UIView *)receiver;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    CGRect frame = cell.frame;
    if (frame.size.height != 0.0) {
        frame.size.height = 0.0;
        cell.frame = frame;
    }
    for (UIView *subview in cell.subviews) {
        subview.hidden = YES;
    }
}

static void YTKACEFeedHeaderScrollMode(__unsafe_unretained id receiver, SEL selector,
                                       int mode) {
    if (OriginalFeedHeaderScrollMode != NULL) {
        ((void (*)(id, SEL, int))OriginalFeedHeaderScrollMode)(
            receiver, selector, YTKACEHideTopics() ? 0 : mode);
    }
}

static IMP OriginalChipViewFrames;

static id YTKACEChipViewFrames(__unsafe_unretained id receiver, SEL selector, double width) {
    if (YTKACEHideTopics()) return nil;
    return OriginalChipViewFrames == NULL ? nil
        : ((id (*)(id, SEL, double))OriginalChipViewFrames)(receiver, selector, width);
}

static void YTKACESubsSetChipFilterView(__unsafe_unretained id receiver, SEL selector,
                                        __unsafe_unretained id view) {
    BOOL hide = YTKACEHideTopics();
    if (hide) return;
    if (OriginalSubsSetChipFilterView != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsSetChipFilterView)(receiver, selector, view);
    }
}

static void YTKACESubsChipFilter(__unsafe_unretained id receiver, SEL selector,
                                 __unsafe_unretained id model) {
    BOOL hide = YTKACEHideTopics();
    if (hide) return;
    if (OriginalSubsChipFilter != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsChipFilter)(receiver, selector, model);
    }
}

static void YTKACEMaximumSubheaderHeight(__unsafe_unretained id receiver,
                                        SEL selector, double height) {
    BOOL hide = YTKACEHideTopics();
    if (hide) height = 0.0;
    if (OriginalMaximumSubheaderHeight != NULL) {
        ((void (*)(id, SEL, double))OriginalMaximumSubheaderHeight)(
            receiver, selector, height);
    }
}

static void YTKACESetHeaderHeights(id receiver, SEL selector,
                                    double headerHeight,
                                    double subheaderHeight,
                                    double topOffset,
                                    BOOL animated) {
    if (YTKACEHideTopics()) {
        subheaderHeight = 0.0;
    }
    if (OriginalSetHeaderHeights != NULL) {
        ((void (*)(id, SEL, double, double, double, BOOL))OriginalSetHeaderHeights)(
            receiver, selector, headerHeight, subheaderHeight, topOffset, animated);
    }
}

static BOOL YTKACEShouldHideSubheader(id receiver, SEL selector) {
    if (YTKACEHideTopics()) return YES;
    return OriginalShouldHideSubheader != NULL &&
        ((BOOL (*)(id, SEL))OriginalShouldHideSubheader)(receiver, selector);
}

static void YTKACEAddSections(id receiver, SEL selector, NSArray *sections) {
    if (OriginalAddSections != NULL) {
        YTKACEEnsureStructuralActionHook();
        NSArray *filtered = YTKACEFilteredFeedSections(receiver, sections);
        ((void (*)(id, SEL, id))OriginalAddSections)(
            receiver, selector, filtered);
    }
}

static IMP OriginalSetupSectionList;

static BOOL YTKACEIsGuidelinesSection(id section) {
    NSData *pattern = [@"community_guidelines.eml" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *bytes = YTKACESectionBytes(section) ?: YTKACEDescendantBytes(section);
    if (bytes.length == 0 ||
        [bytes rangeOfData:pattern options:0
                     range:NSMakeRange(0, bytes.length)].location == NSNotFound) {
        return NO;
    }
    id itemSection = YTKACEFastChildSel(section, YTKACESelItemSectionRenderer) ?: section;
    return YTKACEFastContents(itemSection).count <= 1;
}

static void YTKACEStripGuidelinesSections(id model) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden")) {
        return;
    }
    NSArray *sections = YTKACEFastContents(model);
    if (![sections isKindOfClass:NSMutableArray.class] || sections.count == 0) return;
    NSIndexSet *drop = [sections indexesOfObjectsPassingTest:
        ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
        return YTKACEIsGuidelinesSection(section);
    }];
    if (drop.count == 0) return;
    [(NSMutableArray *)sections removeObjectsAtIndexes:drop];
}

static void YTKACESetupSectionList(id receiver, SEL selector, id model, BOOL loadingMore,
                                   BOOL refreshing, BOOL preserveHeader) {
    YTKACEStripGuidelinesSections(model);
    if (OriginalSetupSectionList != NULL) {
        ((void (*)(id, SEL, id, BOOL, BOOL, BOOL))OriginalSetupSectionList)(
            receiver, selector, model, loadingMore, refreshing, preserveHeader);
    }
}

void YTKACEInstallContentVisibilityHooks(void) {
    YTKACEInstallInstanceHook(
        @"YTAppCollectionViewController",
        @"setupSectionListWithModel:isLoadingMore:isRefreshingFromContinuation:"
         "shouldPreserveHeaderOnRefresh:",
        (IMP)YTKACESetupSectionList, &OriginalSetupSectionList);
    __unused NSArray<NSNumber *> *actionHooks = @[
        @(YTKACEInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)YTKACEScrollableActionButtonsArray,
                                    &OriginalScrollableActionButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)YTKACEScrollableActionBarButtonsArray,
                                    &OriginalScrollableActionBarButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)YTKACEScrollableButtonsArray,
                                    &OriginalScrollableButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)YTKACEScrollableActionsArray,
                                    &OriginalScrollableActionsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)YTKACEActionButtonsArray,
                                    &OriginalActionButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)YTKACEActionBarButtonsArray,
                                    &OriginalActionBarButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)YTKACEButtonsArray,
                                    &OriginalButtonsArray)),
        @(YTKACEInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)YTKACEActionsArray,
                                    &OriginalActionsArray))
    ];
    YTKACEInstallInstanceHook(@"YTSlimVideoDetailsActionView",
                              @"didMoveToWindow",
                              (IMP)YTKACEActionViewDidMove,
                              &OriginalActionViewDidMove);
    YTKACEEnsureStructuralActionHook();
    YTKACEEnsureActionCellControllerHooks();
    YTKACEEnsureActionCollectionLayoutHook();
    YTKACEScheduleStructuralActionHook();
    YTKACEInstallInstanceHook(@"YTSlimVideoScrollableDetailsActionsView",
                              @"didMoveToWindow",
                              (IMP)YTKACEActionsViewDidMove,
                              &OriginalActionsViewDidMove);
    YTKACEInstallInstanceHook(@"YTSlimVideoScrollableActionBarCell",
                              @"didMoveToWindow",
                              (IMP)YTKACEActionCellDidMove,
                              &OriginalActionCellDidMove);
    YTKACEInstallInstanceHook(@"_ASDisplayView",
                              @"didMoveToWindow",
                              (IMP)YTKACEDisplayViewDidMove,
                              &OriginalDisplayViewDidMove);
    YTKACEInstallInstanceHook(@"_ASDisplayView",
                              @"setAccessibilityIdentifier:",
                              (IMP)YTKACEDisplayViewSetIdentifier,
                              &OriginalDisplayViewSetIdentifier);
    YTKACEInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"addSectionsFromArray:",
                              (IMP)YTKACEAddSections,
                              &OriginalAddSections);
    YTKACEInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"sectionControllersForSectionRenderers:reloadingSectionControllerByRenderer:",
                              (IMP)YTKACESectionControllers,
                              &OriginalSectionControllers);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"enableSubheaderBarWithView:",
                              (IMP)YTKACEEnableSubheaderBar,
                              &OriginalEnableSubheaderBar);
    YTKACEInstallInstanceHook(@"YTFeedFilterChipBarController",
                              @"updateWithCollectionViewController:feedFilterChipBarHost:feedFilterChipBarRenderer:browseIdentifier:sectionList:",
                              (IMP)YTKACEChipBarUpdate,
                              &OriginalChipBarUpdate);
    YTKACEInstallInstanceHook(@"YTChipCloudCell",
                              @"setEntry:",
                              (IMP)YTKACEChipCloudSetEntry,
                              &OriginalChipCloudSetEntry);
    YTKACEInstallInstanceHook(@"YTMySubsFilterHeaderViewController",
                              @"loadChipFilterFromModel:",
                              (IMP)YTKACESubsChipFilter,
                              &OriginalSubsChipFilter);
    YTKACEInstallInstanceHook(@"YTChipCloudCell",
                              @"layoutSubviews",
                              (IMP)YTKACEChipCloudLayout,
                              &OriginalChipCloudLayout);
    YTKACEInstallInstanceHook(@"YTChipCloudCell",
                              @"framesForChipViewsWithWidth:",
                              (IMP)YTKACEChipViewFrames,
                              &OriginalChipViewFrames);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setFeedHeaderScrollMode:",
                              (IMP)YTKACEFeedHeaderScrollMode,
                              &OriginalFeedHeaderScrollMode);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setMaximumSubheaderHeight:",
                              (IMP)YTKACEMaximumSubheaderHeight,
                              &OriginalMaximumSubheaderHeight);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"maximumSubheaderHeight",
                              (IMP)YTKACEMaximumSubheaderHeightGetter,
                              &OriginalMaximumSubheaderHeightGetter);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"subheaderDefaultHeight",
                              (IMP)YTKACESubheaderDefaultHeight,
                              &OriginalSubheaderDefaultHeight);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setHeaderHeight:subheaderHeight:topOffset:animated:",
                              (IMP)YTKACESetHeaderHeights,
                              &OriginalSetHeaderHeights);
    YTKACEInstallInstanceHook(@"YTHeaderContentComboView",
                              @"shouldHideSubHeader",
                              (IMP)YTKACEShouldHideSubheader,
                              &OriginalShouldHideSubheader);
    YTKACEInstallInstanceHook(@"YTMySubsFilterHeaderView",
                              @"setChipFilterView:",
                              (IMP)YTKACESubsSetChipFilterView,
                              &OriginalSubsSetChipFilterView);
    YTKACEInstallInstanceHook(@"YTPaidContentOverlayView",
                              @"layoutSubviews",
                              (IMP)YTKACEPaidContentLayout,
                              &OriginalPaidContentLayout);
    YTKACEInstallInstanceHook(@"YTPaidContentViewController",
                              @"viewDidAppear:",
                              (IMP)YTKACEPaidContentDidAppear,
                              &OriginalPaidContentDidAppear);
    YTKACEInstallInstanceHook(@"YTPaidContentController",
                              @"playbackDidStart",
                              (IMP)YTKACEPaidContentPlaybackStarted,
                              &OriginalPaidContentPlaybackStarted);
    YTKACEInstallInstanceHook(@"YTPaidContentController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTKACESetPaidContentPlayerData,
                              &OriginalSetPaidContentPlayerData);
    YTKACEInstallInstanceHook(@"YTPaidContentViewController",
                              @"setPaidContentRenderer:",
                              (IMP)YTKACESetPaidContentRenderer,
                              &OriginalSetPaidContentRenderer);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"hasPaidContentOverlay",
                              (IMP)YTKACEHasPaidContentOverlay,
                              &OriginalHasPaidContentOverlay);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"paidContentOverlay",
                              (IMP)YTKACEPaidContentOverlay,
                              &OriginalPaidContentOverlay);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTKACEOverlayPaidContentPlayerData,
                              &OriginalOverlayPaidContentPlayerData);
    YTKACEInstallInstanceHook(@"YTInlineMutedPlaybackPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTKACEInlinePaidContentPlayerData,
                              &OriginalInlinePaidContentPlayerData);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)YTKACEDidInsertPlayerOverlay,
                              &OriginalDidInsertPlayerOverlay);
}
