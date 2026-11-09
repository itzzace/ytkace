// Desk (laptop) posture on the iPhone Duo: half open with the crease running
// across the screen. Video players put the picture on the half above the
// crease and the controls on the half below, the way Netflix and the TV app
// do; in book posture (crease top to bottom) the full-screen layout stays.
//
// The app's own layout code moves its video and controls using the crease
// from DUODeskPostureFold. These helpers find the crease, re-run layout when
// the hinge moves, and fill the lower half with a mirrored, blurred live copy
// of the picture behind the controls.
//
// From Plex Reborn (PlexDuoVideo.m) and YTKACE; see
// docs/duo-playbook/desk-posture-split.md. iOS 27.1 APIs are reached by name.
#import "DuoKit.h"
#import <objc/message.h>
#import <objc/runtime.h>

CGRect DUODeskPostureFold(UIView *view) {
    Class kindClass = NSClassFromString(@"UIViewReservedRegionKind");
    SEL kindSelector = NSSelectorFromString(@"divisionRegionKind");
    SEL regionsSelector = NSSelectorFromString(@"reservedRegionsOfKind:");
    if (view == nil || kindClass == Nil || ![kindClass respondsToSelector:kindSelector] ||
        ![view respondsToSelector:regionsSelector]) {
        return CGRectNull;
    }
    id kind = ((id (*)(id, SEL))objc_msgSend)(kindClass, kindSelector);
    NSArray *regions = ((NSArray *(*)(id, SEL, id))objc_msgSend)(view, regionsSelector, kind);
    for (id region in regions) {
        BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"isActive"));
        CGRect fold = ((CGRect (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"frame"));
        // Wider than tall: the crease runs across the screen.
        if (active && fold.size.width > fold.size.height) return fold;
    }
    return CGRectNull;
}

static const void *DUOHingeKey = &DUOHingeKey;
static BOOL DUOHingeSeen;
// Remembered across launches, so the first layout after launch already knows
// (the first hinge update arrives a few seconds in).
static NSString *const DUOHingeSeenKey = @"DuoKit.HasHinge";

BOOL DUOHasHinge(void) {
    if (!DUOHingeSeen) DUOHingeSeen = [NSUserDefaults.standardUserDefaults boolForKey:DUOHingeSeenKey];
    return DUOHingeSeen;
}

void DUOObserveHinge(UIView *view) {
    Class hingeClass = NSClassFromString(@"UIHingeInteraction");
    if (view == nil || hingeClass == Nil || objc_getAssociatedObject(view, DUOHingeKey)) return;
    __weak UIView *weakView = view;
    void (^handler)(id, id) = ^(__unused id interaction, id update) {
        // The update's hinge is nil on hardware without one.
        if ([update respondsToSelector:NSSelectorFromString(@"hinge")] && [update valueForKey:@"hinge"] != nil) {
            if (!DUOHingeSeen) [NSUserDefaults.standardUserDefaults setBool:YES forKey:DUOHingeSeenKey];
            DUOHingeSeen = YES;
        }
        UIView *strongView = weakView;
        [strongView setNeedsLayout];
        [strongView.superview setNeedsLayout];
    };
    id hinge = ((id (*)(id, SEL, id))objc_msgSend)([hingeClass alloc],
                                                  NSSelectorFromString(@"initWithUpdateHandler:"), handler);
    if (hinge == nil) return;
    [view addInteraction:hinge];
    objc_setAssociatedObject(view, DUOHingeKey, hinge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Reflection under the crease

// UIKit's portal view (private _UIPortalView) draws another view's live
// rendering, video included, so nothing is copied frame by frame. Flipped
// vertically, its picture's bottom edge meets the crease like a reflection.
static const void *DUOReflectionKey = &DUOReflectionKey;

static UIView *DUOMakeReflection(UIView *source) {
    Class portalClass = NSClassFromString(@"_UIPortalView");
    if (portalClass == Nil || source == nil) return nil;
    UIView *root = [UIView new];
    root.clipsToBounds = YES;
    root.userInteractionEnabled = NO;
    root.backgroundColor = UIColor.blackColor;

    UIView *portal = [portalClass new];
    [portal setValue:source forKey:@"sourceView"];
    if ([portal respondsToSelector:NSSelectorFromString(@"setMatchesPosition:")]) [portal setValue:@NO forKey:@"matchesPosition"];
    if ([portal respondsToSelector:NSSelectorFromString(@"setMatchesTransform:")]) [portal setValue:@NO forKey:@"matchesTransform"];
    portal.tag = 1;
    [root addSubview:portal];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.tag = 2;
    [root addSubview:blur];

    // Darker toward the bottom, where the controls' text sits.
    UIView *shade = [UIView new];
    shade.tag = 3;
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.25].CGColor,
                        (id)[UIColor colorWithWhite:0 alpha:0.75].CGColor];
    [shade.layer addSublayer:gradient];
    [root addSubview:shade];
    return root;
}

void DUOUpdateDeskReflection(UIView *host, UIView *source, CGRect fold) {
    UIView *root = objc_getAssociatedObject(host, DUOReflectionKey);
    BOOL on = host != nil && source != nil && !CGRectIsNull(fold);
    if (!on) {
        root.hidden = YES;
        return;
    }
    if (root == nil) {
        root = DUOMakeReflection(source);
        if (root == nil) return;
        objc_setAssociatedObject(host, DUOReflectionKey, root, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (root.superview != host) {
        if (source.superview == host) [host insertSubview:root aboveSubview:source];
        else [host insertSubview:root atIndex:0];
    }
    root.hidden = NO;
    CGRect sourceFrame = [source.superview convertRect:source.frame toView:host];
    CGFloat top = CGRectGetMinY(fold);
    root.frame = CGRectMake(CGRectGetMinX(sourceFrame), top, CGRectGetWidth(sourceFrame),
                            CGRectGetHeight(host.bounds) - top);

    UIView *portal = [root viewWithTag:1];
    CGSize videoSize = source.bounds.size;
    portal.transform = CGAffineTransformIdentity;
    portal.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
    portal.center = CGPointMake(videoSize.width / 2, videoSize.height / 2);
    portal.transform = CGAffineTransformMakeScale(1, -1);
    [root viewWithTag:2].frame = root.bounds;
    UIView *shade = [root viewWithTag:3];
    shade.frame = root.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shade.layer.sublayers.firstObject.frame = shade.bounds;
    [CATransaction commit];
}
