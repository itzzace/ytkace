// Desk (laptop) posture on the iPhone Duo: half open with the crease running
// across the screen. Video players put the picture on the half above the
// crease and the controls on the half below, the way Netflix and the TV app
// do; in book posture (crease top to bottom) the full-screen layout stays.
//
// The app's own layout code moves its video and controls using the crease
// from DUODeskPostureFold. These helpers find the crease, re-run layout when
// the hinge moves, and fill the lower half with a mirrored, slightly soft live
// copy of the picture behind the controls.
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
static const void *DUOReflectionRegionsKey = &DUOReflectionRegionsKey;
// What was last applied to the reflection, so an unchanged layout does no work.
static const void *DUOAppliedRegionsKey = &DUOAppliedRegionsKey;
static const void *DUOAppliedFrameKey = &DUOAppliedFrameKey;
static const void *DUOFadeStartKey = &DUOFadeStartKey;

// The fade is eased with a smoothstep rather than linear, which reads as a band,
// and is built from this many stops.
enum { DUOEaseStops = 16 };

// How bright the reflection is where it starts, and the share of that left at
// the bottom of the screen, so the last row of controls keeps some of the tint.
static const CGFloat DUOReflectionStrength = 0.7;
static const CGFloat DUOReflectionFloor = 0.4;

// The reflection is slightly soft, like one in a still puddle or a mirror: a
// blur of this radius (points), the same everywhere.
static const CGFloat DUOReflectionBlurRadius = 7.0;

static CGFloat DUOSmoothstep(CGFloat t) {
    return t * t * (3.0 - 2.0 * t);
}

// Softens the mirrored picture with Core Animation's gaussianBlur, reached by
// name, on the portal's own layer. A blur view over it would add a frosted
// material that its radius does not control. Without the filter the reflection
// is left sharp.
static void DUOSoften(UIView *portal) {
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL make = NSSelectorFromString(@"filterWithType:");
    id filter = [filterClass respondsToSelector:make]
        ? ((id (*)(id, SEL, id))objc_msgSend)(filterClass, make, @"gaussianBlur") : nil;
    if (filter == nil) return;
    [filter setValue:@(DUOReflectionBlurRadius) forKey:@"inputRadius"];
    [filter setValue:@YES forKey:@"inputNormalizeEdges"];
    [portal.layer setValue:@[filter] forKey:@"filters"];
}

static UIView *DUOMakePortal(UIView *source, Class portalClass) {
    UIView *portal = [portalClass new];
    [portal setValue:source forKey:@"sourceView"];
    if ([portal respondsToSelector:NSSelectorFromString(@"setMatchesPosition:")]) [portal setValue:@NO forKey:@"matchesPosition"];
    if ([portal respondsToSelector:NSSelectorFromString(@"setMatchesTransform:")]) [portal setValue:@NO forKey:@"matchesTransform"];
    return portal;
}

static UIView *DUOMakeReflection(UIView *source) {
    Class portalClass = NSClassFromString(@"_UIPortalView");
    if (portalClass == Nil || source == nil) return nil;
    UIView *root = [UIView new];
    root.clipsToBounds = YES;
    root.userInteractionEnabled = NO;
    root.backgroundColor = UIColor.blackColor;

    // A reflection on a glossy desk: the picture mirrored and slightly soft, strongest
    // at the crease and fading out with distance into the black behind it.
    UIView *content = [UIView new];
    content.tag = 5;
    CAGradientLayer *fade = [CAGradientLayer layer];
    NSMutableArray *colors = [NSMutableArray array];
    for (int index = 0; index <= DUOEaseStops; index++) {
        const CGFloat t = (CGFloat)index / DUOEaseStops;
        [colors addObject:(id)[UIColor colorWithWhite:0 alpha:DUOReflectionStrength * (1.0 - (1.0 - DUOReflectionFloor) * DUOSmoothstep(t))].CGColor];
    }
    fade.colors = colors;
    content.layer.mask = fade;
    [root addSubview:content];

    UIView *portal = DUOMakePortal(source, portalClass);
    portal.tag = 1;
    DUOSoften(portal);
    [content addSubview:portal];

    return root;
}

// Applies the regions set by DUOSetDeskReflectionRegions to the reflection,
// whose frame is in the host's coordinates: the mirrored picture is cut to them
// with a mask, and is clear outside them.
static void DUOApplyReflectionRegions(UIView *host, UIView *root) {
    NSDictionary *regions = objc_getAssociatedObject(host, DUOReflectionRegionsKey);
    // Black behind the reflection. Inside the regions the glass controls then see
    // just the reflection over black, not whatever the host draws behind them
    // (such as a glow that would wash them out). With regions the mask below cuts
    // the black to them, so outside them the host's own background shows.
    root.backgroundColor = UIColor.blackColor;
    if (regions == nil) {
        root.layer.mask = nil;
        objc_setAssociatedObject(root, DUOAppliedRegionsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSValue *frame = [NSValue valueWithCGRect:root.frame];
    if (objc_getAssociatedObject(root, DUOAppliedRegionsKey) == regions &&
        [objc_getAssociatedObject(root, DUOAppliedFrameKey) isEqualToValue:frame]) {
        return;
    }
    objc_setAssociatedObject(root, DUOAppliedRegionsKey, regions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, DUOAppliedFrameKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<NSValue *> *rects = regions[@"rects"];
    NSArray<NSNumber *> *radii = regions[@"radii"];
    const CGPoint origin = root.frame.origin;
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (NSUInteger index = 0; index < rects.count; index++) {
        CGRect local = CGRectOffset(rects[index].CGRectValue, -origin.x, -origin.y);
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:local cornerRadius:(index < radii.count ? radii[index].doubleValue : 0.0)]];
    }
    CAShapeLayer *mask = [root.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)root.layer.mask : nil;
    if (mask == nil) {
        mask = [CAShapeLayer layer];
        mask.fillColor = UIColor.blackColor.CGColor;
        root.layer.mask = mask;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = root.bounds;
    mask.path = path.CGPath;
    [CATransaction commit];
}

void DUOSetDeskReflectionRegions(UIView *host, NSArray<NSValue *> *rects, NSArray<NSNumber *> *radii) {
    if (host == nil) return;
    NSDictionary *regions = rects == nil ? nil : @{@"rects": [rects copy], @"radii": [radii copy] ?: @[]};
    objc_setAssociatedObject(host, DUOReflectionRegionsKey, regions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *root = objc_getAssociatedObject(host, DUOReflectionKey);
    if (root != nil) DUOApplyReflectionRegions(host, root);
}

void DUOUpdateDeskReflection(UIView *host, UIView *source, CGRect fold) {
    DUOUpdateDeskReflectionBelowPicture(host, source, fold, 0.0, 0.0);
}

void DUOUpdateDeskReflectionBelowPicture(UIView *host, UIView *source, CGRect fold, CGFloat topInset,
                                         CGFloat bottomInset) {
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
    // The crease stays black; the mirrored picture starts right below it, with
    // the picture's bottom edge (not the letterbox bar under it) at the top.
    // The letterbox bars are cropped off the mirrored picture at both ends, so
    // the picture itself fills the whole lower half.
    const CGFloat inset = MAX(0.0, bottomInset);
    const CGFloat pictureTop = MAX(0.0, topInset);
    const CGFloat top = CGRectGetMinY(fold);
    const CGFloat crease = CGRectGetHeight(fold);
    root.frame = CGRectMake(CGRectGetMinX(sourceFrame), top, CGRectGetWidth(sourceFrame),
                            CGRectGetHeight(host.bounds) - top);
    DUOApplyReflectionRegions(host, root);

    UIView *portal = [root viewWithTag:1];
    CGSize videoSize = source.bounds.size;
    portal.transform = CGAffineTransformIdentity;
    portal.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
    // Stretched down to the bottom of the screen: the lower half is taller than
    // the picture, and the controls cover all of it. Flipped about the portal's
    // center, so the center is placed to leave the picture's bottom edge right
    // below the crease and its top edge at the bottom of the screen.
    const CGFloat lower = MAX(1.0, CGRectGetHeight(host.bounds) - CGRectGetMaxY(fold));
    const CGFloat stretch = MAX(1.0, lower / MAX(1.0, videoSize.height - inset - pictureTop));
    portal.center = CGPointMake(videoSize.width / 2, crease + stretch * (videoSize.height / 2 - inset));
    portal.transform = CGAffineTransformMakeScale(1, -stretch);
    UIView *content = [root viewWithTag:5];
    content.frame = root.bounds;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CAGradientLayer *fade = (CAGradientLayer *)content.layer.mask;
    fade.frame = content.bounds;
    const CGFloat height = MAX(1.0, CGRectGetHeight(root.bounds));
    const CGFloat start = MIN(1.0, crease / height);
    if (![objc_getAssociatedObject(fade, DUOFadeStartKey) isEqual:@(start)]) {
        objc_setAssociatedObject(fade, DUOFadeStartKey, @(start), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableArray<NSNumber *> *locations = [NSMutableArray arrayWithCapacity:DUOEaseStops + 1];
        for (int index = 0; index <= DUOEaseStops; index++) {
            [locations addObject:@(start + (CGFloat)index / DUOEaseStops * (1.0 - start))];
        }
        fade.locations = locations;
    }
    [CATransaction commit];
}
