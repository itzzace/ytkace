#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// Shows the dislike count from the Return YouTube Dislike API next to the
// watch page dislike button.

static NSString *const YTKACEReturnDislikeKey = @"YTKACE.Preference.ActionBar.ReturnDislike";
static const void *YTKACEDislikeNumberAssociation = &YTKACEDislikeNumberAssociation;
static const void *YTKACEDislikeVideoAssociation = &YTKACEDislikeVideoAssociation;
static const void *YTKACEDislikeCountAssociation = &YTKACEDislikeCountAssociation;
static const void *YTKACEDislikeStyleAssociation = &YTKACEDislikeStyleAssociation;
static IMP OriginalRollingUpdate;
static IMP OriginalRollingPrepare;
static IMP OriginalRollingSize;
static IMP OriginalRollingLayout;
static const CGFloat YTKACEDislikeGap = 4.0;
static NSCache<NSString *, NSNumber *> *YTKACEDislikeCounts;
static NSMutableDictionary<NSString *, NSHashTable<UIView *> *> *YTKACEDislikeWaiting;

static id YTKACEDislikeGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id YTKACEDislikeIvar(id object, const char *name) {
    for (Class cls = [object class]; cls != Nil; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar != NULL) return object_getIvar(object, ivar);
    }
    return nil;
}

static NSString *YTKACEDislikeText(long long count) {
    if (count < 1000) return [NSString stringWithFormat:@"%lld", count];
    NSArray<NSString *> *units = @[@"K", @"M", @"B"];
    double value = (double)count;
    NSUInteger unit = 0;
    value /= 1000.0;
    while (value >= 1000.0 && unit + 1 < units.count) {
        value /= 1000.0;
        unit++;
    }
    NSString *number = value < 10.0
        ? [NSString stringWithFormat:@"%.1f", floor(value * 10.0) / 10.0]
        : [NSString stringWithFormat:@"%.0f", floor(value)];
    if ([number hasSuffix:@".0"]) number = [number substringToIndex:number.length - 2];
    return [number stringByAppendingString:units[unit]];
}

static NSString *YTKACEDislikeVideoID(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        id player = [NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]
            ? responder : YTKACEDislikeGet(responder, @"playerViewController");
        id video = YTKACEDislikeGet(player, @"currentVideoID");
        if ([video isKindOfClass:NSString.class] && [video length] != 0) return video;
        if ([NSStringFromClass(responder.class) isEqualToString:@"YTReelContainerViewController"]) {
            id model = YTKACEDislikeGet(responder, @"model");
            for (NSString *name in @[@"videoId", @"videoID", @"onesieVideoID", @"contentVideoID"]) {
                id value = YTKACEDislikeGet(model, name);
                if ([value isKindOfClass:NSString.class] && [value length] == 11) return value;
            }
        }
    }
    return nil;
}

static id YTKACEDislikeLikeNumber(UIView *dislikeView) {
    for (UIView *sibling in dislikeView.superview.subviews) {
        if (![sibling.accessibilityIdentifier isEqualToString:@"id.video.like.button"]) continue;
        id likeNode = YTKACEDislikeGet(sibling, @"keepalive_node");
        for (id child in YTKACEDislikeGet(likeNode, @"yogaChildren")) {
            if ([NSStringFromClass([child class]) isEqualToString:@"YTRollingNumberNode"]) return child;
        }
    }
    return nil;
}

static void YTKACEDislikeRelayout(id node) {
    for (id current = node; current != nil; current = YTKACEDislikeGet(current, @"supernode")) {
        SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
        if ([current respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        SEL needs = NSSelectorFromString(@"setNeedsLayout");
        if ([current respondsToSelector:needs]) ((void (*)(id, SEL))objc_msgSend)(current, needs);
    }
}


// Puts our count on one of our number nodes; YouTube's own nodes are untouched.
static BOOL YTKACEDislikeApplyCount(id number) {
    NSNumber *count = objc_getAssociatedObject(number, YTKACEDislikeCountAssociation);
    if (count == nil) return NO;
    UIView *rolling = YTKACEDislikeGet(number, @"rollingNumberView");
    // Match the like count's font and color as they are now; on a video that
    // is already disliked they aren't set yet the first time we get here.
    id likeNumber = [objc_getAssociatedObject(number, YTKACEDislikeStyleAssociation) anyObject];
    UIView *likeRolling = YTKACEDislikeGet(likeNumber, @"rollingNumberView");
    NSMutableDictionary *style = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"font", @"fontAttributes", @"color"]) {
        id value = YTKACEDislikeGet(likeRolling, key);
        if (value != nil) style[key] = value;
    }
    if (style[@"font"] == nil) return YES;
    SEL set = NSSelectorFromString(@"setUpdatedCount:updatedCountNumber:font:fontAttributes:color:skipAnimation:");
    if (rolling == nil || ![rolling respondsToSelector:set]) return YES;
    NSString *text = YTKACEDislikeText(count.longLongValue);
    if ([YTKACEDislikeGet(rolling, @"updatedCount") isEqual:text]) return YES;
    ((void (*)(id, SEL, id, id, id, id, id, BOOL))objc_msgSend)(
        rolling, set, text, count, style[@"font"], style[@"fontAttributes"], style[@"color"], YES);
    return YES;
}

// On our node YouTube's update would put the like count back and fight with
// ours, leaving half-rolled digits, so only ours is applied there.
static void YTKACERollingUpdate(id receiver, SEL selector) {
    if (YTKACEDislikeApplyCount(receiver)) return;
    if (OriginalRollingUpdate != NULL) ((void (*)(id, SEL))OriginalRollingUpdate)(receiver, selector);
}

static void YTKACERollingPrepare(id receiver, SEL selector) {
    if (OriginalRollingPrepare != NULL) ((void (*)(id, SEL))OriginalRollingPrepare)(receiver, selector);
    YTKACEDislikeApplyCount(receiver);
}

static CGSize YTKACERollingSize(id receiver, SEL selector, CGSize constrained) {
    CGSize size = OriginalRollingSize != NULL
        ? ((CGSize (*)(id, SEL, CGSize))OriginalRollingSize)(receiver, selector, constrained) : CGSizeZero;
    if (!YTKACEDislikeApplyCount(receiver)) return size;
    UIView *rolling = YTKACEDislikeGet(receiver, @"rollingNumberView");
    if (rolling == nil) return size;
    CGSize fit = [rolling sizeThatFits:constrained];
    return CGSizeMake(ceil(fit.width) + YTKACEDislikeGap, MAX(size.height, ceil(fit.height)));
}

// Same gap between the icon and the number as the like side.
static void YTKACERollingLayout(id receiver, SEL selector) {
    if (OriginalRollingLayout != NULL) ((void (*)(id, SEL))OriginalRollingLayout)(receiver, selector);
    if (objc_getAssociatedObject(receiver, YTKACEDislikeCountAssociation) == nil) return;
    UIView *rolling = YTKACEDislikeGet(receiver, @"rollingNumberView");
    UIView *host = YTKACEDislikeGet(receiver, @"view");
    if (rolling == nil || host == nil) return;
    CGRect frame = rolling.frame;
    frame.origin.x = YTKACEDislikeGap;
    frame.size.width = MAX(0.0, host.bounds.size.width - YTKACEDislikeGap);
    frame.origin.y = round((host.bounds.size.height - frame.size.height) / 2.0);
    rolling.frame = frame;
    rolling.userInteractionEnabled = NO;
}

static NSHashTable<UIView *> *YTKACEWatchDislikeViews;

static void YTKACEDislikeShow(UIView *dislikeView, NSNumber *count) {
    if (YTKACEWatchDislikeViews == nil) YTKACEWatchDislikeViews = [NSHashTable weakObjectsHashTable];
    [YTKACEWatchDislikeViews addObject:dislikeView];
    id dislikeNode = YTKACEDislikeGet(dislikeView, @"keepalive_node");
    id likeNumber = YTKACEDislikeLikeNumber(dislikeView);
    if (dislikeNode == nil || likeNumber == nil) {
        YTKACEDebugLog(@"ryd", @"show missing node=%d like=%d", dislikeNode != nil, likeNumber != nil);
        return;
    }
    id number = objc_getAssociatedObject(dislikeNode, YTKACEDislikeNumberAssociation);
    if (number == nil) {
        id element = YTKACEDislikeGet(likeNumber, @"element");
        id context = YTKACEDislikeIvar(likeNumber, "_context");
        Class numberClass = NSClassFromString(@"YTRollingNumberNode");
        SEL init = NSSelectorFromString(@"initWithElement:context:");
        if (element == nil || numberClass == Nil) {
            YTKACEDebugLog(@"ryd", @"no element=%d context=%d", element != nil, context != nil);
            return;
        }
        @try {
            number = ((id (*)(id, SEL, id, id))objc_msgSend)([numberClass alloc], init, element, context);
        } @catch (__unused NSException *exception) {
            return;
        }
        if (number == nil) return;
        objc_setAssociatedObject(dislikeNode, YTKACEDislikeNumberAssociation, number,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // A node made outside YouTube's build has no yoga node until this.
        SEL enable = NSSelectorFromString(@"enableYoga");
        if ([number respondsToSelector:enable]) ((void (*)(id, SEL))objc_msgSend)(number, enable);
        SEL add = NSSelectorFromString(@"addYogaChild:");
        @try {
            if ([dislikeNode respondsToSelector:add]) ((void (*)(id, SEL, id))objc_msgSend)(dislikeNode, add, number);
        } @catch (NSException *exception) {
            YTKACEDebugLog(@"ryd", @"add threw %@ %@", exception.name, exception.reason);
            objc_setAssociatedObject(dislikeNode, YTKACEDislikeNumberAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        // Taps on the number go to the dislike button, like on the like side.
        SEL interaction = @selector(setUserInteractionEnabled:);
        if ([number respondsToSelector:interaction]) ((void (*)(id, SEL, BOOL))objc_msgSend)(number, interaction, NO);
        UIView *numberView = YTKACEDislikeGet(number, @"view");
        numberView.userInteractionEnabled = NO;
        if (numberView != nil) [dislikeView addSubview:numberView];
    }
    NSHashTable *likeRef = [NSHashTable weakObjectsHashTable];
    [likeRef addObject:likeNumber];
    objc_setAssociatedObject(number, YTKACEDislikeStyleAssociation, likeRef, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(number, YTKACEDislikeCountAssociation, count, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEDislikeApplyCount(number);
    SEL invalidate = NSSelectorFromString(@"invalidateCachedCalculatedSize");
    if ([number respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(number, invalidate);
    UIView *rolling = YTKACEDislikeGet(number, @"rollingNumberView");
    YTKACEDislikeRelayout(number);
    YTKACEDebugLog(@"ryd", @"show %@ rolling=%d frame=%@", YTKACEDislikeText(count.longLongValue),
                   rolling != nil, NSStringFromCGRect(dislikeView.frame));
}


// Shorts: YouTube dropped the dislike button, so a node with the count goes in
// the button column right after Like, as part of YouTube's own layout.
static NSString *const YTKACEShortsDislikeKey = @"YTKACE.Preference.Shorts.DislikeCount";
static const void *YTKACEShortsDislikeNodeAssociation = &YTKACEShortsDislikeNodeAssociation;
static const NSInteger YTKACEShortsDislikeLabelTag = 0x52594444;

static const NSInteger YTKACEShortsDislikeIconTag = 0x52594449;
static const void *YTKACEShortsViewVideoAssociation = &YTKACEShortsViewVideoAssociation;
static NSMutableSet<NSString *> *YTKACEDislikedVideos;
static NSHashTable<UIView *> *YTKACEShortsDislikeViews;
static void YTKACEShortsDislikeTapped(UIView *view);

@interface YTKACEShortsDislikeTarget : NSObject
@end

@implementation YTKACEShortsDislikeTarget
- (void)tapped:(UITapGestureRecognizer *)recognizer {
    YTKACEShortsDislikeTapped(recognizer.view);
}
@end

static UIImage *YTKACEShortsDislikeIcon(BOOL filled) {
    return [UIImage systemImageNamed:filled ? @"hand.thumbsdown.fill" : @"hand.thumbsdown"
                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                                                     weight:UIImageSymbolWeightRegular]];
}

static UIView *YTKACEShortsDislikeMakeView(void) {
    static YTKACEShortsDislikeTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [YTKACEShortsDislikeTarget new]; });
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 60)];
    view.userInteractionEnabled = YES;
    view.accessibilityTraits = UIAccessibilityTraitButton;
    [view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)]];
    view.isAccessibilityElement = YES;
    view.accessibilityIdentifier = @"id.ytkace_dislike_button";
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(20, 9, 24, 24)];
    icon.tag = YTKACEShortsDislikeIconTag;
    icon.image = YTKACEShortsDislikeIcon(NO);
    icon.contentMode = UIViewContentModeCenter;
    icon.tintColor = UIColor.whiteColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 36, 64, 16)];
    label.tag = YTKACEShortsDislikeLabelTag;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    for (UIView *part in @[icon, label]) {
        part.layer.shadowColor = UIColor.blackColor.CGColor;
        part.layer.shadowOpacity = 0.4;
        part.layer.shadowRadius = 2.0;
        part.layer.shadowOffset = CGSizeZero;
        [view addSubview:part];
    }
    return view;
}

static CGSize YTKACEShortsDislikeNodeSize(__unused id receiver, __unused SEL selector, __unused CGSize constrained) {
    return CGSizeMake(64.0, 60.0);
}

// ASDisplayNode subclass sized like the other Shorts buttons.
static Class YTKACEShortsDislikeNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASDisplayNode");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "YTKACEShortsDislikeNode", 0);
        if (cls == Nil) { cls = NSClassFromString(@"YTKACEShortsDislikeNode"); return; }
        class_addMethod(cls, NSSelectorFromString(@"calculateSizeThatFits:"),
                        (IMP)YTKACEShortsDislikeNodeSize, "{CGSize=dd}32@0:8{CGSize=dd}16");
        objc_registerClassPair(cls);
    });
    return cls;
}

static BOOL YTKACEIsReelLike(id node) {
    return [node respondsToSelector:@selector(accessibilityIdentifier)] &&
        [[node accessibilityIdentifier] isEqualToString:@"id.reel_like_button"];
}

// Puts our node right after Like. Only called once the column is built.
static NSUInteger YTKACEShortsLikeIndex(NSArray *children) {
    for (NSUInteger i = 0; i < children.count; i++) {
        if (YTKACEIsReelLike(children[i])) return i;
    }
    return NSNotFound;
}


static id YTKACEShortsDislikeInsert(id rail) {
    NSArray *children = YTKACEDislikeGet(rail, @"yogaChildren");
    NSUInteger index = YTKACEShortsLikeIndex(children);
    if (index == NSNotFound) return nil;
    id node = objc_getAssociatedObject(rail, YTKACEShortsDislikeNodeAssociation);
    if (node != nil) {
        if ([children indexOfObjectIdenticalTo:node] == NSNotFound)
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(rail, NSSelectorFromString(@"insertYogaChild:atIndex:"),
                                                             node, index + 1);
        return node;
    }
    UIView *(^block)(void) = ^UIView *{ return YTKACEShortsDislikeMakeView(); };
    node = ((id (*)(id, SEL, id))objc_msgSend)([YTKACEShortsDislikeNodeClass() alloc],
                                               NSSelectorFromString(@"initWithViewBlock:"), block);
    if (node == nil) return nil;
    ((void (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"enableYoga"));
    objc_setAssociatedObject(rail, YTKACEShortsDislikeNodeAssociation, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(rail, NSSelectorFromString(@"insertYogaChild:atIndex:"),
                                                     node, index + 1);
    // The column adds subnodes from its layout; adding ours by hand drops the
    // buttons after it.
    SEL managesSelector = NSSelectorFromString(@"automaticallyManagesSubnodes");
    BOOL managed = [rail respondsToSelector:managesSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(rail, managesSelector);
    if (!managed) ((void (*)(id, SEL, id))objc_msgSend)(rail, NSSelectorFromString(@"addSubnode:"), node);
    return node;
}

static IMP OriginalNodeAddYogaChild;
static IMP OriginalNodeInsertYogaChild;
static IMP OriginalNodeSetYogaChildren;

// These hooks see every node YouTube adds, so they check a cached flag first.
static volatile BOOL YTKACEShortsDislikeOn;

static void YTKACEShortsRefreshFlag(void) {
    YTKACEShortsDislikeOn = YTKACEFeatureEnabled(YTKACEShortsDislikeKey);
}

static NSUInteger YTKACEShortsOurIndex(id rail) {
    id node = objc_getAssociatedObject(rail, YTKACEShortsDislikeNodeAssociation);
    return node == nil ? NSNotFound : [YTKACEDislikeGet(rail, @"yogaChildren") indexOfObjectIdenticalTo:node];
}

// Our node goes in while YouTube builds the column, right after Like, so the
// first layout already has it. YouTube's later inserts use its own indexes,
// which are shifted past our node so its order is kept.
static void YTKACEShortsAfterChange(id rail) {
    if (!YTKACEShortsDislikeOn) return;
    if (YTKACEShortsDislikeInsert(rail) != nil) YTKACEDebugLog(@"ryd", @"shorts inserted at build");
}

static void YTKACENodeAddYogaChild(id receiver, SEL selector, id child) {
    if (OriginalNodeAddYogaChild != NULL) ((void (*)(id, SEL, id))OriginalNodeAddYogaChild)(receiver, selector, child);
    if (YTKACEShortsDislikeOn && YTKACEIsReelLike(child)) YTKACEShortsAfterChange(receiver);
}

static void YTKACENodeInsertYogaChild(id receiver, SEL selector, id child, NSUInteger index) {
    id ours = YTKACEShortsDislikeOn ? objc_getAssociatedObject(receiver, YTKACEShortsDislikeNodeAssociation) : nil;
    if (ours != nil && child != ours) {
        NSUInteger position = YTKACEShortsOurIndex(receiver);
        if (position != NSNotFound && index >= position) index++;
    }
    if (OriginalNodeInsertYogaChild != NULL)
        ((void (*)(id, SEL, id, NSUInteger))OriginalNodeInsertYogaChild)(receiver, selector, child, index);
    if (YTKACEShortsDislikeOn && child != ours && YTKACEIsReelLike(child)) YTKACEShortsAfterChange(receiver);
}

static void YTKACENodeSetYogaChildren(id receiver, SEL selector, NSArray *children) {
    if (OriginalNodeSetYogaChildren != NULL) ((void (*)(id, SEL, id))OriginalNodeSetYogaChildren)(receiver, selector, children);
    if (!YTKACEShortsDislikeOn) return;
    for (id child in children) {
        if (YTKACEIsReelLike(child)) {
            YTKACEShortsAfterChange(receiver);
            return;
        }
    }
}

static void YTKACEShortsDislikeShow(UIView *likeView, NSNumber *count) {
    id likeNode = YTKACEDislikeGet(likeView, @"keepalive_node");
    id rail = YTKACEDislikeGet(likeNode, @"supernode");
    BOOL late = objc_getAssociatedObject(rail, YTKACEShortsDislikeNodeAssociation) == nil;
    id node = YTKACEShortsDislikeInsert(rail);
    if (node == nil) return;
    UIView *view = YTKACEDislikeGet(node, @"view");
    UILabel *label = [view viewWithTag:YTKACEShortsDislikeLabelTag];
    label.text = count != nil ? YTKACEDislikeText(count.longLongValue) : YTKACELocalized(@"Dislike");
    view.accessibilityLabel = count != nil ? [NSString stringWithFormat:@"%@ dislikes", label.text] : label.text;
    NSString *videoID = objc_getAssociatedObject(likeView, YTKACEDislikeVideoAssociation);
    objc_setAssociatedObject(view, YTKACEShortsViewVideoAssociation, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((UIImageView *)[view viewWithTag:YTKACEShortsDislikeIconTag]).image =
        YTKACEShortsDislikeIcon(videoID != nil && [YTKACEDislikedVideos containsObject:videoID]);
    if (YTKACEShortsDislikeViews == nil) YTKACEShortsDislikeViews = [NSHashTable weakObjectsHashTable];
    [YTKACEShortsDislikeViews addObject:view];
    if (!late) return;
    // Fallback if the column got past layout without us.
    YTKACEDebugLog(@"ryd", @"shorts inserted late rail=%p", rail);
    YTKACEDislikeRelayout(node);
    for (id current = rail; current != nil; current = YTKACEDislikeGet(current, @"supernode")) {
        [(UIView *)YTKACEDislikeGet(current, @"view") setNeedsLayout];
        SEL layoutIfNeeded = NSSelectorFromString(@"layoutIfNeeded");
        if ([current respondsToSelector:layoutIfNeeded]) ((void (*)(id, SEL))objc_msgSend)(current, layoutIfNeeded);
    }
}

static void YTKACEDislikeFetch(NSString *videoID) {
    NSString *address = [@"https://returnyoutubedislikeapi.com/votes?videoId="
        stringByAppendingString:[videoID stringByAddingPercentEncodingWithAllowedCharacters:
                                 NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.timeoutInterval = 10.0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id dislikes = [json isKindOfClass:NSDictionary.class] ? json[@"dislikes"] : nil;
        YTKACEDebugLog(@"ryd", @"fetch video=%@ status=%ld dislikes=%@ error=%@", videoID,
                       (long)[(NSHTTPURLResponse *)response statusCode], dislikes, error.localizedDescription ?: @"-");
        if (![dislikes isKindOfClass:NSNumber.class]) return;
        [YTKACEDislikeCounts setObject:dislikes forKey:videoID];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<UIView *> *views;
            @synchronized (YTKACEDislikeWaiting) {
                views = YTKACEDislikeWaiting[videoID].allObjects;
                [YTKACEDislikeWaiting removeObjectForKey:videoID];
            }
            for (UIView *view in views) {
                if (view.window != nil &&
                    [objc_getAssociatedObject(view, YTKACEDislikeVideoAssociation) isEqualToString:videoID]) {
                    if ([view.accessibilityIdentifier isEqualToString:@"id.reel_like_button"]) {
                        YTKACEShortsDislikeShow(view, dislikes);
                    } else {
                        YTKACEDislikeShow(view, dislikes);
                    }
                }
            }
        });
    }] resume];
}

void YTKACEReturnDislikeConsiderView(UIView *view) {
    if (view.window == nil) return;
    NSString *identifier = view.accessibilityIdentifier;
    BOOL shorts = [identifier isEqualToString:@"id.reel_like_button"];
    if (shorts) {
        if (!YTKACEFeatureEnabled(YTKACEShortsDislikeKey)) return;
    } else if (![identifier isEqualToString:@"id.video.dislike.button"] ||
               !YTKACEFeatureEnabled(YTKACEReturnDislikeKey) ||
               YTKACEFeatureEnabled(@"YTKACE.Preference.ActionBar.DislikeHidden")) {
        return;
    }
    NSString *videoID = YTKACEDislikeVideoID(view);
    if (videoID.length == 0) return;
    objc_setAssociatedObject(view, YTKACEDislikeVideoAssociation, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Shorts: make room right away so the button doesn't pop in after the fetch.
    if (shorts) YTKACEShortsDislikeShow(view, nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        YTKACEDislikeCounts = [NSCache new];
        YTKACEDislikeCounts.countLimit = 200;
        YTKACEDislikeWaiting = [NSMutableDictionary dictionary];
    });
    NSNumber *cached = [YTKACEDislikeCounts objectForKey:videoID];
    if (cached != nil) {
        if (shorts) YTKACEShortsDislikeShow(view, cached);
        else YTKACEDislikeShow(view, cached);
        return;
    }
    BOOL first;
    @synchronized (YTKACEDislikeWaiting) {
        NSHashTable *views = YTKACEDislikeWaiting[videoID];
        first = views == nil;
        if (first) views = YTKACEDislikeWaiting[videoID] = [NSHashTable weakObjectsHashTable];
        [views addObject:view];
    }
    if (first) YTKACEDislikeFetch(videoID);
}

// Every like, dislike and removal goes through YouTube's like service, from
// the watch page, fullscreen and Shorts.
static __weak id YTKACELikeService;
static IMP OriginalLikeRequest;
static IMP OriginalLikeRequestDispatch;
static IMP OriginalLikeServiceInit;

static id YTKACELikeServiceInit(id receiver, SEL selector, id account) {
    id service = ((id (*)(id, SEL, id))OriginalLikeServiceInit)(receiver, selector, account);
    YTKACELikeService = service;
    return service;
}

static NSString *YTKACELikeTargetVideoID(id target) {
    for (NSString *name in @[@"videoId", @"videoID"]) {
        id value = YTKACEDislikeGet(target, name);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return value;
    }
    return nil;
}

// ---- Vote submission (off by default). Only a random ID, the video ID and the
// vote are sent. The API asks for a small proof of work before it takes votes.
static NSString *const YTKACEVotesKey = @"YTKACE.Preference.ActionBar.ReturnDislikeVotes";
static NSString *const YTKACERYDUserKey = @"YTKACE.Cache.RYDUserID";
static NSString *const YTKACERYDRegisteredKey = @"YTKACE.Cache.RYDRegistered";

static dispatch_queue_t YTKACEVoteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.ytkace.ryd-votes", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *YTKACERYDUserID(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *user = [defaults stringForKey:YTKACERYDUserKey];
    if (user.length == 36) return user;
    static const char letters[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    char buffer[37] = {0};
    for (int i = 0; i < 36; i++) buffer[i] = letters[arc4random_uniform((uint32_t)(sizeof letters - 1))];
    user = @(buffer);
    [defaults setObject:user forKey:YTKACERYDUserKey];
    [defaults setBool:NO forKey:YTKACERYDRegisteredKey];
    return user;
}

static id YTKACERYDRequest(NSString *method, NSString *path, NSDictionary *body, NSInteger *status) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://returnyoutubedislikeapi.com" stringByAppendingString:path]]];
    request.HTTPMethod = method;
    request.timeoutInterval = 15.0;
    if (body != nil) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    __block id result = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        code = [(NSHTTPURLResponse *)response statusCode];
        if (data.length != 0) result = [NSJSONSerialization JSONObjectWithData:data
                                                                       options:NSJSONReadingFragmentsAllowed error:nil];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (status != NULL) *status = code;
    return result;
}

// Finds a 4-byte prefix whose SHA-512 with the challenge starts with enough zero bits.
static NSString *YTKACERYDSolve(NSDictionary *puzzle) {
    if (![puzzle isKindOfClass:NSDictionary.class]) return nil;
    NSData *challenge = [[NSData alloc] initWithBase64EncodedString:puzzle[@"challenge"] ?: @"" options:0];
    NSInteger difficulty = [puzzle[@"difficulty"] integerValue];
    if (challenge.length == 0 || difficulty <= 0 || difficulty > 30) return nil;
    uint8_t buffer[20] = {0};
    memcpy(buffer + 4, challenge.bytes, MIN((NSUInteger)16, challenge.length));
    uint64_t limit = ((uint64_t)1 << difficulty) * 5;
    uint8_t hash[CC_SHA512_DIGEST_LENGTH];
    for (uint64_t attempt = 0; attempt < limit && attempt <= UINT32_MAX; attempt++) {
        uint32_t value = (uint32_t)attempt;
        buffer[0] = value & 0xff; buffer[1] = (value >> 8) & 0xff;
        buffer[2] = (value >> 16) & 0xff; buffer[3] = (value >> 24) & 0xff;
        CC_SHA512(buffer, sizeof buffer, hash);
        NSInteger zeros = 0;
        for (int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) {
            if (hash[i] == 0) { zeros += 8; continue; }
            zeros += __builtin_clz((unsigned int)hash[i]) - 24;
            break;
        }
        if (zeros >= difficulty) return [[NSData dataWithBytes:buffer length:4] base64EncodedStringWithOptions:0];
    }
    return nil;
}

static BOOL YTKACERYDRegister(NSString *user) {
    NSString *path = [@"/puzzle/registration?userId=" stringByAppendingString:user];
    NSString *solution = YTKACERYDSolve(YTKACERYDRequest(@"GET", path, nil, NULL));
    if (solution == nil) return NO;
    id result = YTKACERYDRequest(@"POST", path, @{@"solution": solution}, NULL);
    BOOL ok = [result isKindOfClass:NSNumber.class] && [result boolValue];
    [NSUserDefaults.standardUserDefaults setBool:ok forKey:YTKACERYDRegisteredKey];
    YTKACEDebugLog(@"ryd", @"vote register ok=%d", ok);
    return ok;
}

static void YTKACERYDSubmitVote(NSString *videoID, NSInteger value) {
    dispatch_async(YTKACEVoteQueue(), ^{
        NSString *user = YTKACERYDUserID();
        if (![NSUserDefaults.standardUserDefaults boolForKey:YTKACERYDRegisteredKey] && !YTKACERYDRegister(user)) return;
        for (int attempt = 0; attempt < 2; attempt++) {
            NSInteger code = 0;
            id puzzle = YTKACERYDRequest(@"POST", @"/interact/vote",
                                         @{@"userId": user, @"videoId": videoID, @"value": @(value)}, &code);
            if (code == 401 && attempt == 0 && YTKACERYDRegister(user)) continue;
            NSString *solution = YTKACERYDSolve(puzzle);
            if (solution == nil) {
                YTKACEDebugLog(@"ryd", @"vote video=%@ value=%ld status=%ld no puzzle", videoID, (long)value, (long)code);
                return;
            }
            id result = YTKACERYDRequest(@"POST", @"/interact/confirmVote",
                                         @{@"userId": user, @"videoId": videoID, @"solution": solution}, &code);
            YTKACEDebugLog(@"ryd", @"vote video=%@ value=%ld confirmed=%@ status=%ld", videoID, (long)value,
                           result, (long)code);
            return;
        }
    });
}

// ---- Count and Shorts state follow the user's own like, dislike or removal.
static NSMutableDictionary<NSString *, NSNumber *> *YTKACELastLikeStatus;

static void YTKACEDislikeAdjust(NSString *videoID, NSInteger delta) {
    NSNumber *cached = [YTKACEDislikeCounts objectForKey:videoID];
    if (cached == nil || delta == 0) return;
    NSNumber *updated = @(MAX(0LL, cached.longLongValue + delta));
    [YTKACEDislikeCounts setObject:updated forKey:videoID];
    for (UIView *view in YTKACEWatchDislikeViews.allObjects) {
        if (view.window != nil && [objc_getAssociatedObject(view, YTKACEDislikeVideoAssociation) isEqualToString:videoID]) {
            YTKACEDislikeShow(view, updated);
        }
    }
    for (UIView *view in YTKACEShortsDislikeViews.allObjects) {
        if (![objc_getAssociatedObject(view, YTKACEShortsViewVideoAssociation) isEqualToString:videoID]) continue;
        UILabel *label = [view viewWithTag:YTKACEShortsDislikeLabelTag];
        label.text = YTKACEDislikeText(updated.longLongValue);
    }
}

static void YTKACELikeRequested(id service, int status, id target) {
    YTKACELikeService = service;
    NSString *videoID = YTKACELikeTargetVideoID(target);
    YTKACEDebugLog(@"ryd", @"like request status=%d video=%@", status, videoID ?: @"-");
    if (videoID.length == 0 || status < 0 || status > 2) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (YTKACELastLikeStatus == nil) YTKACELastLikeStatus = [NSMutableDictionary dictionary];
        if (YTKACEDislikedVideos == nil) YTKACEDislikedVideos = [NSMutableSet set];
        BOOL wasDisliked = [YTKACEDislikedVideos containsObject:videoID] ||
            [YTKACELastLikeStatus[videoID] intValue] == 1;
        if (YTKACELastLikeStatus[videoID] != nil && [YTKACELastLikeStatus[videoID] intValue] == status) return;
        YTKACELastLikeStatus[videoID] = @(status);
        BOOL disliked = status == 1;
        if (disliked) [YTKACEDislikedVideos addObject:videoID];
        else [YTKACEDislikedVideos removeObject:videoID];
        YTKACEDislikeAdjust(videoID, disliked && !wasDisliked ? 1 : (!disliked && wasDisliked ? -1 : 0));
        for (UIView *view in YTKACEShortsDislikeViews.allObjects) {
            if ([objc_getAssociatedObject(view, YTKACEShortsViewVideoAssociation) isEqualToString:videoID])
                ((UIImageView *)[view viewWithTag:YTKACEShortsDislikeIconTag]).image = YTKACEShortsDislikeIcon(disliked);
        }
        if (YTKACEFeatureEnabled(YTKACEVotesKey)) YTKACERYDSubmitVote(videoID, status == 0 ? 1 : (status == 1 ? -1 : 0));
    });
}

// Tapping the Shorts count dislikes the Short through YouTube's like service.
static void YTKACEShortsDislikeTapped(UIView *view) {
    NSString *videoID = objc_getAssociatedObject(view, YTKACEShortsViewVideoAssociation);
    id service = YTKACELikeService;
    Class targetClass = NSClassFromString(@"YTILikeTarget");
    if (videoID.length == 0 || service == nil || targetClass == Nil) {
        YTKACEDebugLog(@"ryd", @"shorts tap video=%@ service=%d", videoID ?: @"-", service != nil);
        return;
    }
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    id target = [targetClass new];
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(@"setVideoId:"), videoID);
    int status = [YTKACEDislikedVideos containsObject:videoID] ? 2 : 1;
    void (^response)(id) = ^(__unused id result) {};
    void (^failure)(id) = ^(id error) { YTKACEDebugLog(@"ryd", @"shorts dislike failed %@", error); };
    SEL request = NSSelectorFromString(
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:responseBlock:errorBlock:");
    ((void (*)(id, SEL, int, id, id, id, id, id, id))objc_msgSend)(service, request, status, target, nil, nil, nil,
                                                                  response, failure);
}

static void YTKACELikeRequest(id receiver, SEL selector, int status, id target, id tracking, id queue, id params,
                              id response, id error) {
    YTKACELikeService = receiver;
    ((void (*)(id, SEL, int, id, id, id, id, id, id))OriginalLikeRequest)(receiver, selector, status, target, tracking,
                                                                         queue, params, response, error);
}

static void YTKACELikeRequestDispatch(id receiver, SEL selector, int status, id target, id tracking, id queue,
                                      id params, int dispatch, id response, id error) {
    YTKACELikeRequested(receiver, status, target);
    ((void (*)(id, SEL, int, id, id, id, id, int, id, id))OriginalLikeRequestDispatch)(
        receiver, selector, status, target, tracking, queue, params, dispatch, response, error);
}

void YTKACEInstallReturnDislikeHooks(void) {
    YTKACEShortsRefreshFlag();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                                                     queue:nil usingBlock:^(__unused NSNotification *note) {
        YTKACEShortsRefreshFlag();
    }];
    YTKACEInstallInstanceHook(@"YTLikeServiceImpl", @"initWithAccountID:",
                              (IMP)YTKACELikeServiceInit, &OriginalLikeServiceInit);
    YTKACEInstallInstanceHook(@"YTLikeServiceImpl",
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:responseBlock:errorBlock:",
        (IMP)YTKACELikeRequest, &OriginalLikeRequest);
    YTKACEInstallInstanceHook(@"YTLikeServiceImpl",
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:requestDispatchType:responseBlock:errorBlock:",
        (IMP)YTKACELikeRequestDispatch, &OriginalLikeRequestDispatch);
    YTKACEInstallInstanceHook(@"YTRollingNumberNode", @"updateRollingNumberView",
                              (IMP)YTKACERollingUpdate, &OriginalRollingUpdate);
    YTKACEInstallInstanceHook(@"YTRollingNumberNode", @"prepareInitialRollingNumberView",
                              (IMP)YTKACERollingPrepare, &OriginalRollingPrepare);
    YTKACEInstallInstanceHook(@"YTRollingNumberNode", @"layout",
                              (IMP)YTKACERollingLayout, &OriginalRollingLayout);
    YTKACEInstallInstanceHook(@"YTRollingNumberNode", @"calculateSizeThatFits:",
                              (IMP)YTKACERollingSize, &OriginalRollingSize);
    YTKACEInstallInstanceHook(@"ASDisplayNode", @"addYogaChild:",
                              (IMP)YTKACENodeAddYogaChild, &OriginalNodeAddYogaChild);
    YTKACEInstallInstanceHook(@"ASDisplayNode", @"insertYogaChild:atIndex:",
                              (IMP)YTKACENodeInsertYogaChild, &OriginalNodeInsertYogaChild);
    YTKACEInstallInstanceHook(@"ASDisplayNode", @"setYogaChildren:",
                              (IMP)YTKACENodeSetYogaChildren, &OriginalNodeSetYogaChildren);
}
