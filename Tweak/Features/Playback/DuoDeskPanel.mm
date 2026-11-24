// Laptop posture on the iPhone Duo: below the crease, a grid of glass tiles
// replaces YouTube's controls, the way Netflix's Duo app does. The panel stays
// up while the posture lasts; YouTube's own controls overlay, progress bar and
// actions row are hidden under it and come back when the panel goes.
//
// DuoDeskPlayer.mm calls YTKACEDuoDeskPanelUpdate from the player's layout
// with the crease (or CGRectNull when the split doesn't apply).
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#pragma mark - YouTube

static id YTKACEPanelGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTKACEPanelDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    switch (signature.methodReturnType[0]) {
        case 'f': return ((float (*)(id, SEL))objc_msgSend)(object, selector);
        case 'd': return ((double (*)(id, SEL))objc_msgSend)(object, selector);
        default: return 0.0;
    }
}

static BOOL YTKACEPanelBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static id YTKACEPanelPath(id object, NSArray<NSString *> *path) {
    for (NSString *name in path) object = YTKACEPanelGet(object, name);
    return object;
}

static UIViewController *YTKACEPanelPlayerController(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if ([NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

static UIView *YTKACEPanelFind(UIView *root, NSString *className, NSInteger depth) {
    if (depth < 0) return nil;
    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:className]) return subview;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = YTKACEPanelFind(subview, className, depth - 1);
        if (found != nil) return found;
    }
    return nil;
}

static UIControl *YTKACEPanelControlIn(UIView *view) {
    if ([view isKindOfClass:UIControl.class]) return (UIControl *)view;
    for (UIView *subview in view.subviews) {
        UIControl *control = YTKACEPanelControlIn(subview);
        if (control != nil) return control;
    }
    return nil;
}

// A button of YouTube's controls overlay, by ivar name.
static UIControl *YTKACEPanelOverlayButton(UIView *overlay, NSArray<NSString *> *names) {
    if (overlay == nil) return nil;
    for (NSString *name in names) {
        Ivar ivar = class_getInstanceVariable(object_getClass(overlay), name.UTF8String);
        id value = ivar != NULL ? object_getIvar(overlay, ivar) : nil;
        if ([value isKindOfClass:UIView.class]) {
            UIControl *control = YTKACEPanelControlIn(value);
            if (control != nil) return control;
        }
    }
    return nil;
}

#pragma mark - Chapters

// YouTube's player bar builds its chapters in a decoration controller
// (YTPlayerBarChaptersDecorationController) that keeps them as YTPlayerBarChapterInfo
// objects. The controller is caught when it builds its chapter collection and
// read from there, since nothing else hands them out.
static NSHashTable<id> *YTKACEChapterControllers;
static IMP YTKACEOrigCreateChapterCollection;

static void YTKACERememberChapterController(id controller) {
    @synchronized (YTKACEChapterControllers) {
        [YTKACEChapterControllers addObject:controller];
    }
}

static id YTKACECreateChapterCollectionObject(id self, SEL _cmd, double total) {
    YTKACERememberChapterController(self);
    return ((id (*)(id, SEL, double))YTKACEOrigCreateChapterCollection)(self, _cmd, total);
}

static void YTKACECreateChapterCollectionVoid(id self, SEL _cmd, double total) {
    YTKACERememberChapterController(self);
    ((void (*)(id, SEL, double))YTKACEOrigCreateChapterCollection)(self, _cmd, total);
}

// The chapters of the video that is `total` seconds long, as {start, end, title}
// in order, or nil when it has none (or only one, which says nothing).
static NSArray<NSDictionary *> *YTKACEPanelChapters(double total) {
    if (YTKACEChapterControllers == nil || total <= 1.0) return nil;
    // Read again only when YouTube's chapter list changes: this runs on the
    // panel's refresh timer.
    static __weak id cachedSource;
    static NSUInteger cachedCount;
    static NSArray<NSDictionary *> *cached;
    NSArray *controllers;
    @synchronized (YTKACEChapterControllers) {
        controllers = YTKACEChapterControllers.allObjects;
    }
    for (id controller in controllers.reverseObjectEnumerator) {
        NSNumber *controllerTotal = [controller valueForKey:@"_totalTime"];
        if (fabs(controllerTotal.doubleValue - total) > 2.0) continue;
        NSArray *source = [controller valueForKey:@"_chapters"];
        if (source != nil && source == cachedSource && source.count == cachedCount) return cached;
        NSMutableArray<NSDictionary *> *chapters = [NSMutableArray array];
        for (id chapter in source ?: @[]) {
            if (YTKACEPanelBool(chapter, @"isGhostChapter")) continue;
            NSString *title = YTKACEPanelGet(chapter, @"title");
            [chapters addObject:@{@"start": @(YTKACEPanelDouble(chapter, @"startTime")),
                                  @"end": @(YTKACEPanelDouble(chapter, @"endTime")),
                                  @"title": [title isKindOfClass:NSString.class] ? title : @""}];
        }
        if (chapters.count > 1) {
            cachedSource = source;
            cachedCount = source.count;
            cached = chapters;
            return chapters;
        }
    }
    return nil;
}

static NSString *YTKACEPanelTime(double seconds) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    const long total = (long)floor(seconds);
    const long hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60;
    return hours > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", hours, minutes, rest]
                     : [NSString stringWithFormat:@"%ld:%02ld", minutes, rest];
}

static NSString *YTKACEPanelRateText(double rate) {
    if (rate <= 0.0) rate = 1.0;
    NSString *text = [NSString stringWithFormat:@"%.2f", rate];
    while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return [NSString stringWithFormat:@"  %@×", text];
}

static NSString *const YTKACEPanelRateKey = @"YTKACE.Preference.Player.SavedRate";

// The playing rate from a playback object, the way SpeedControls.mm reads it:
// its own rate getter, or one of the objects it plays through.
static double YTKACEPanelRateFrom(id object, NSUInteger depth) {
    if (object == nil || depth > 2) return 0.0;
    for (NSString *name in @[@"playbackRate", @"currentPlaybackRate", @"rate"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        const char type = [object methodSignatureForSelector:selector].methodReturnType[0];
        double rate = 0.0;
        if (type == 'd') rate = ((double (*)(id, SEL))objc_msgSend)(object, selector);
        else if (type == 'f') rate = ((float (*)(id, SEL))objc_msgSend)(object, selector);
        else if (type == '@') rate = [((id (*)(id, SEL))objc_msgSend)(object, selector) doubleValue];
        if (isfinite(rate) && rate >= 0.25 && rate <= 5.0) return rate;
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController", @"playerController", @"player"]) {
        id child = YTKACEPanelGet(object, name);
        if (child == object) continue;
        const double rate = YTKACEPanelRateFrom(child, depth + 1);
        if (rate >= 0.25) return rate;
    }
    return 0.0;
}

// setPlaybackRate: with whatever number type the target takes.
static BOOL YTKACEPanelSetRate(id target, double rate) {
    SEL selector = NSSelectorFromString(@"setPlaybackRate:");
    if (target == nil || ![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 3) return NO;
    switch ([signature getArgumentTypeAtIndex:2][0]) {
        case 'd': ((void (*)(id, SEL, double))objc_msgSend)(target, selector, rate); return YES;
        case 'f': ((void (*)(id, SEL, float))objc_msgSend)(target, selector, (float)rate); return YES;
        case '@': ((void (*)(id, SEL, id))objc_msgSend)(target, selector, @(rate)); return YES;
        default: return NO;
    }
}

#pragma mark - Tiles

static const CGFloat YTKACEPanelTileRadius = 18.0;
static const CGFloat YTKACEPanelBigTileRadius = 22.0;

static UIColor *YTKACEPanelRed(void) {
    return [UIColor colorWithRed:1.0 green:0.0 blue:0.2 alpha:1.0];
}

// iOS 26's clear glass material, reached by name like the rest of the repo's
// glass (Tweak/UI/Notice.mm). Every control uses this same material. The laptop
// layout only runs on the iPhone Duo (iOS 27), where it always exists; elsewhere
// this returns nil and a tile is left without a background.
static UIVisualEffectView *YTKACEPanelGlass(void) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    if (![effectClass respondsToSelector:styleSelector]) return nil;
    // UIGlassEffectStyleClear.
    UIVisualEffect *effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 1);
    if (effect == nil) return nil;
    [effect setValue:@YES forKey:@"interactive"];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.cornerRadius = YTKACEPanelTileRadius;
    return glass;
}

@interface YTKACEPanelTile : UIButton
@property (nonatomic, strong) UIVisualEffectView *glass;
@end

@implementation YTKACEPanelTile
- (instancetype)initWithSymbol:(NSString *)symbol size:(CGFloat)size {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    self.layer.cornerRadius = YTKACEPanelTileRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _glass = YTKACEPanelGlass();
    if (_glass != nil) [self insertSubview:_glass atIndex:0];
    self.tintColor = UIColor.whiteColor;
    [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    if (symbol != nil) [self setSymbol:symbol size:size];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glass.frame = self.bounds;
    self.glass.layer.cornerRadius = self.layer.cornerRadius;
    [self sendSubviewToBack:self.glass];
}

- (void)setSymbol:(NSString *)symbol size:(CGFloat)size {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
    [self setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration] forState:UIControlStateNormal];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.05 : 0.2 animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity;
    }];
}
@end

#pragma mark - Panel

// The slider only takes touches at its thumb. Anywhere else on the scrubber tile
// the touch goes to the chapters button behind it.
@interface YTKACEPanelSlider : UISlider
@end

@implementation YTKACEPanelSlider
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    const CGRect track = [self trackRectForBounds:self.bounds];
    const CGRect thumb = [self thumbRectForBounds:self.bounds trackRect:track value:self.value];
    return CGRectContainsPoint(CGRectInset(thumb, -20.0, -20.0), point);
}
@end

@interface YTKACEDeskPanel : UIView
@property (nonatomic, weak) UIView *player;
@property (nonatomic, strong) YTKACEPanelTile *titleTile, *captionsTile, *settingsTile;
@property (nonatomic, strong) YTKACEPanelTile *backTile, *playTile, *forwardTile;
@property (nonatomic, strong) UIView *scrubTile;
// Covers the scrubber tile; tapping it opens the chapters as a native menu.
@property (nonatomic, strong) UIButton *chaptersButton;
@property (nonatomic, strong) UIVisualEffectView *scrubGlass;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIView *chapterTicks;
@property (nonatomic, strong) UILabel *chapterLabel;
// A chevron after the chapter's title: tapping the tile opens the list.
@property (nonatomic, strong) UIImageView *chapterChevron;
@property (nonatomic, copy) NSArray<NSDictionary *> *chapters;
@property (nonatomic, strong) UILabel *elapsedLabel, *totalLabel, *titleLabel, *channelLabel;
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) YTKACEPanelTile *speedTile, *previousTile, *nextTile, *exitTile;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSHashTable<UIView *> *hiddenViews;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL shownPlaying;
@property (nonatomic) double rate;
@property (nonatomic, copy) NSString *videoID;
// What was last given to DuoKit as the reflection's shape.
@property (nonatomic, copy) NSArray<NSValue *> *reflectionRects;
@property (nonatomic, copy) NSArray<NSNumber *> *reflectionRadii;
// What the chapter ticks were last drawn for.
@property (nonatomic, copy) NSString *ticksKey;
@end

@implementation YTKACEDeskPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    // Dark glass, so the white icons read over a bright picture too.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _hiddenViews = [NSHashTable weakObjectsHashTable];
    _rate = YTKACEStartPlaybackRate();
    _shownPlaying = YES;  // the play tile starts as pause.fill
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playbackTimeChanged:)
                                               name:@"YTKACEPlaybackTimeDidChange" object:nil];

    _titleTile = [self tile:nil size:0 action:NULL];
    _titleTile.userInteractionEnabled = NO;
    _logo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"play.rectangle.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightBold]]];
    _logo.tintColor = YTKACEPanelRed();
    _logo.contentMode = UIViewContentModeScaleAspectFit;
    [_titleTile addSubview:_logo];
    _titleLabel = [self label:15.0 weight:UIFontWeightBold alpha:1.0];
    _channelLabel = [self label:12.0 weight:UIFontWeightMedium alpha:0.6];
    [_titleTile addSubview:_titleLabel];
    [_titleTile addSubview:_channelLabel];

    _captionsTile = [self tile:@"captions.bubble" size:18.0 action:@selector(captionsPressed)];
    // The gear opens a small menu: fill screen, and YouTube's own settings.
    _settingsTile = [self tile:@"gearshape" size:18.0 action:NULL];
    _settingsTile.showsMenuAsPrimaryAction = YES;
    [self rebuildSettingsMenu];
    _backTile = [self tile:@"gobackward.10" size:30.0 action:@selector(backPressed)];
    _playTile = [self tile:@"pause.fill" size:40.0 action:@selector(playPressed)];
    _forwardTile = [self tile:@"goforward.10" size:30.0 action:@selector(forwardPressed)];
    for (YTKACEPanelTile *tile in @[_backTile, _playTile, _forwardTile]) {
        tile.layer.cornerRadius = YTKACEPanelBigTileRadius;
    }

    _scrubTile = [UIView new];
    _scrubTile.layer.cornerRadius = YTKACEPanelTileRadius;
    _scrubTile.layer.cornerCurve = kCACornerCurveContinuous;
    _scrubGlass = YTKACEPanelGlass();
    if (_scrubGlass != nil) [_scrubTile addSubview:_scrubGlass];
    [self addSubview:_scrubTile];
    // Behind the slider and labels; the list is built when the menu opens, so it
    // always shows the current chapter.
    _chaptersButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _chaptersButton.showsMenuAsPrimaryAction = YES;
    // The menu opens upward, and by default UIKit then lists the first item at the
    // bottom (nearest the button). Chapters read top down, in video order.
    if (@available(iOS 16.0, *)) _chaptersButton.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    _chaptersButton.userInteractionEnabled = NO;
    __weak __typeof(self) weakSelf = self;
    _chaptersButton.menu = [UIMenu menuWithChildren:@[
        [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion([weakSelf chapterActions] ?: @[]);
        }]]];
    [_scrubTile addSubview:_chaptersButton];
    _elapsedLabel = [self label:13.0 weight:UIFontWeightSemibold alpha:0.9];
    _totalLabel = [self label:13.0 weight:UIFontWeightSemibold alpha:0.6];
    _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    _totalLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    _totalLabel.textAlignment = NSTextAlignmentRight;
    _slider = [YTKACEPanelSlider new];
    _slider.minimumTrackTintColor = YTKACEPanelRed();
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    [_slider setThumbImage:[self thumbImage:14.0] forState:UIControlStateNormal];
    [_slider setThumbImage:[self thumbImage:20.0] forState:UIControlStateHighlighted];
    [_slider addTarget:self action:@selector(scrubBegan) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(scrubEnded)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_scrubTile addSubview:_elapsedLabel];
    [_scrubTile addSubview:_slider];
    [_scrubTile addSubview:_totalLabel];
    _chapterTicks = [UIView new];
    _chapterTicks.userInteractionEnabled = NO;
    [_scrubTile addSubview:_chapterTicks];
    _chapterLabel = [self label:13.0 weight:UIFontWeightSemibold alpha:0.85];
    [_scrubTile addSubview:_chapterLabel];
    _chapterChevron = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightBold]]];
    _chapterChevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _chapterChevron.contentMode = UIViewContentModeCenter;
    [_scrubTile addSubview:_chapterChevron];

    _speedTile = [self tile:nil size:0 action:@selector(speedPressed)];
    [_speedTile setSymbol:@"gauge.with.dots.needle.67percent" size:16.0];
    _previousTile = [self tile:@"backward.end.fill" size:18.0 action:@selector(previousPressed)];
    _nextTile = [self tile:@"forward.end.fill" size:18.0 action:@selector(nextPressed)];
    _exitTile = [self tile:@"arrow.down.right.and.arrow.up.left" size:18.0 action:@selector(exitPressed)];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Follows speed changes made anywhere, YouTube's own menu included.
- (void)playbackTimeChanged:(NSNotification *)notification {
    if (self.hidden || self.window == nil) return;
    const double rate = YTKACEPanelRateFrom(notification.object, 0);
    if (rate >= 0.25 && fabs(rate - self.rate) > 0.01) self.rate = rate;
}

- (YTKACEPanelTile *)tile:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    YTKACEPanelTile *tile = [[YTKACEPanelTile alloc] initWithSymbol:symbol size:size];
    if (action != NULL) [tile addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:tile];
    return tile;
}

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    return label;
}

- (UIImage *)thumbImage:(CGFloat)diameter {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter)];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [YTKACEPanelRed() setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] fill];
    }];
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    const UIEdgeInsets safe = self.safeAreaInsets;
    const CGFloat gap = 10.0;
    const CGFloat left = MAX(14.0, safe.left + 8.0), right = MAX(14.0, safe.right + 8.0);
    const CGFloat top = 14.0, bottom = MAX(14.0, safe.bottom + 6.0);
    const CGFloat width = CGRectGetWidth(self.bounds) - left - right;
    const CGFloat height = CGRectGetHeight(self.bounds) - top - bottom;
    // Taller while the video has chapters: the chapter's title sits above the bar.
    const CGFloat small = 48.0, barHeight = 58.0;
    const CGFloat chapterRow = self.chapters.count > 1 ? 22.0 : 0.0;
    const CGFloat scrub = barHeight + chapterRow;
    CGFloat big = MIN(210.0, MAX(64.0, height - 2.0 * small - scrub - 3.0 * gap));
    const CGFloat block = 2.0 * small + scrub + big + 3.0 * gap;
    CGFloat y = top + MAX(0.0, (height - block) * 0.5);

    // Title | CC | settings
    const CGFloat square = small + 8.0;
    self.settingsTile.frame = CGRectMake(left + width - square, y, square, small);
    self.captionsTile.frame = CGRectMake(CGRectGetMinX(self.settingsTile.frame) - gap - square, y, square, small);
    self.titleTile.frame = CGRectMake(left, y, CGRectGetMinX(self.captionsTile.frame) - gap - left, small);
    self.logo.frame = CGRectMake(14.0, (small - 22.0) * 0.5, 26.0, 22.0);
    const CGFloat textX = CGRectGetMaxX(self.logo.frame) + 10.0;
    const CGFloat textWidth = CGRectGetWidth(self.titleTile.frame) - textX - 12.0;
    self.titleLabel.frame = CGRectMake(textX, 6.0, textWidth, 20.0);
    self.channelLabel.frame = CGRectMake(textX, 25.0, textWidth, 16.0);
    y += small + gap;

    // -10 | play | +10
    const CGFloat unit = (width - 2.0 * gap) / 3.4;
    self.backTile.frame = CGRectMake(left, y, unit, big);
    self.playTile.frame = CGRectMake(CGRectGetMaxX(self.backTile.frame) + gap, y, unit * 1.4, big);
    self.forwardTile.frame = CGRectMake(CGRectGetMaxX(self.playTile.frame) + gap, y, unit, big);
    y += big + gap;

    // Scrubber
    self.scrubTile.frame = CGRectMake(left, y, width, scrub);
    self.scrubGlass.frame = self.scrubTile.bounds;
    const CGFloat labelWidth = 62.0;
    self.chapterLabel.hidden = chapterRow == 0.0;
    self.chaptersButton.frame = self.scrubTile.bounds;
    self.chaptersButton.userInteractionEnabled = self.chapters.count > 1;
    [self layoutChapterLabel:width];
    self.elapsedLabel.frame = CGRectMake(16.0, chapterRow, labelWidth, barHeight);
    self.totalLabel.frame = CGRectMake(width - 16.0 - labelWidth, chapterRow, labelWidth, barHeight);
    self.slider.frame = CGRectMake(CGRectGetMaxX(self.elapsedLabel.frame) + 4.0, chapterRow,
                                   CGRectGetMinX(self.totalLabel.frame) - CGRectGetMaxX(self.elapsedLabel.frame) - 8.0, barHeight);
    [self layoutChapterTicks];
    y += scrub + gap;

    // Speed | previous | next | exit
    NSArray<YTKACEPanelTile *> *row = @[self.speedTile, self.previousTile, self.nextTile, self.exitTile];
    const CGFloat each = (width - gap * (row.count - 1)) / row.count;
    for (NSUInteger index = 0; index < row.count; index++) {
        row[index].frame = CGRectMake(left + index * (each + gap), y, each, small);
    }
    [self layoutReflectionShape];
}

#pragma mark Lifecycle

// Refreshes four times a second while the panel is showing, and not at all while
// it is hidden or off screen.
- (void)updateTimer {
    const BOOL running = !self.hidden && self.window != nil;
    if (!running) {
        [self.timer invalidate];
        self.timer = nil;
        return;
    }
    if (self.timer != nil) return;
    __weak __typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf refresh];
    }];
    [self refresh];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateTimer];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateTimer];
}

- (UIViewController *)controller {
    return YTKACEPanelPlayerController(self.player);
}

- (UIView *)controlsOverlay {
    return YTKACEPanelFind(self.player, @"YTMainAppControlsOverlayView", 6);
}

// YouTube's controls, progress bar and the actions row (like, comment, the
// up next thumbnail) stay hidden under the panel. YouTube can show them
// again on its own, so this runs on every refresh.
- (void)hideYouTubeControls {
    UIView *overlay = [self controlsOverlay];
    UIView *bar = YTKACEPanelFind(overlay.superview, @"YTInlinePlayerBarContainerView", 2);
    UIView *actions = YTKACEPanelFind(self.player, @"YTFullscreenActionsView", 4);
    void (^hide)(UIView *) = ^(UIView *view) {
        if (view == nil || view.hidden) return;
        view.hidden = YES;
        [self.hiddenViews addObject:view];
    };
    hide(overlay);
    hide(bar);
    hide(actions);
}

- (void)restoreYouTubeControls {
    for (UIView *view in self.hiddenViews.allObjects) view.hidden = NO;
    [self.hiddenViews removeAllObjects];
}

- (void)refresh {
    if (self.hidden || self.window == nil) return;
    [self hideYouTubeControls];
    id controller = [self controller];
    const double total = YTKACEPanelDouble(controller, @"currentVideoTotalMediaTime");
    const double now = YTKACEPanelDouble(controller, @"currentVideoMediaTime");
    if (!self.scrubbing) {
        self.slider.maximumValue = (float)MAX(total, 1.0);
        self.slider.value = (float)now;
        self.elapsedLabel.text = YTKACEPanelTime(now);
    }
    self.totalLabel.text = YTKACEPanelTime(total);
    [self updateChapters:total at:self.scrubbing ? self.slider.value : now];

    id details = YTKACEPanelPath(controller, @[@"contentPlayerResponse", @"playerData", @"videoDetails"]);
    if (details == nil) details = YTKACEPanelPath(controller, @[@"playerResponse", @"playerData", @"videoDetails"]);
    NSString *videoID = YTKACEPanelGet(details, @"videoId");
    if ([videoID isKindOfClass:NSString.class] && ![videoID isEqualToString:self.videoID]) {
        if (self.videoID != nil) self.rate = YTKACEStartPlaybackRate();
        self.videoID = videoID;
    }
    NSString *title = YTKACEPanelGet(details, @"title");
    NSString *channel = YTKACEPanelGet(details, @"author");
    if ([title isKindOfClass:NSString.class] && ![self.titleLabel.text isEqualToString:title]) self.titleLabel.text = title;
    if ([channel isKindOfClass:NSString.class] && ![self.channelLabel.text isEqualToString:channel]) self.channelLabel.text = channel;

    NSString *rateText = YTKACEPanelRateText(self.rate);
    if (![[self.speedTile titleForState:UIControlStateNormal] isEqualToString:rateText]) {
        [self.speedTile setTitle:rateText forState:UIControlStateNormal];
    }
    [self showPlaying:[self isPlaying]];
}

// playerState 3 is playing (YouTube's own speed check uses it the same way).
- (BOOL)isPlaying {
    id controller = [self controller];
    SEL state = NSSelectorFromString(@"playerState");
    if (![controller respondsToSelector:state]) return YES;
    return ((long long (*)(id, SEL))objc_msgSend)(controller, state) == 3;
}

- (void)showPlaying:(BOOL)playing {
    if (playing == self.shownPlaying) return;
    self.shownPlaying = playing;
    [self.playTile setSymbol:playing ? @"pause.fill" : @"play.fill" size:40.0];
}

// The reflection behind the panel is limited to the tiles' shapes (every subview
// is a tile), so it shows through the glass and nowhere else (not the crease, not
// the gaps between tiles). Those stay the player's own black background.
- (void)layoutReflectionShape {
    UIView *player = self.player;
    if (player == nil) return;
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:self.subviews.count];
    NSMutableArray<NSNumber *> *radii = [NSMutableArray arrayWithCapacity:self.subviews.count];
    for (UIView *tile in self.subviews) {
        [rects addObject:[NSValue valueWithCGRect:[self convertRect:tile.frame toView:player]]];
        [radii addObject:@(tile.layer.cornerRadius)];
    }
    if ([rects isEqualToArray:self.reflectionRects] && [radii isEqualToArray:self.reflectionRadii]) return;
    self.reflectionRects = rects;
    self.reflectionRadii = radii;
    DUOSetDeskReflectionRegions(player, rects, radii);
}

#pragma mark Chapters

// The chapter's title, with the chevron right after it.
- (void)layoutChapterLabel:(CGFloat)tileWidth {
    const CGFloat chevron = 14.0, space = 4.0, available = tileWidth - 32.0;
    const CGFloat text = MIN(ceil([self.chapterLabel sizeThatFits:CGSizeMake(available, 18.0)].width), available - chevron - space);
    self.chapterLabel.frame = CGRectMake(16.0, 10.0, text, 18.0);
    self.chapterChevron.frame = CGRectMake(16.0 + text + space, 10.0, chevron, 18.0);
    self.chapterChevron.hidden = self.chapterLabel.hidden;
}


// A notch on the track where each chapter after the first starts.
- (void)layoutChapterTicks {
    self.chapterTicks.frame = self.slider.frame;
    const double total = self.slider.maximumValue;
    NSString *key = [NSString stringWithFormat:@"%p %.1f %.1f", self.chapters, total, CGRectGetWidth(self.slider.frame)];
    if ([key isEqualToString:self.ticksKey]) return;
    self.ticksKey = key;
    for (CALayer *layer in [self.chapterTicks.layer.sublayers copy]) [layer removeFromSuperlayer];
    if (self.chapters.count < 2 || total <= 1.0) return;
    const CGRect track = [self.slider trackRectForBounds:self.slider.bounds];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSDictionary *chapter in self.chapters) {
        const double start = [chapter[@"start"] doubleValue];
        if (start < 1.0 || start > total - 1.0) continue;
        CALayer *tick = [CALayer layer];
        tick.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
        tick.cornerRadius = 1.0;
        tick.frame = CGRectMake(CGRectGetMinX(track) + start / total * CGRectGetWidth(track) - 1.0,
                                CGRectGetMidY(track) - 6.0, 2.0, 12.0);
        [self.chapterTicks.layer addSublayer:tick];
    }
    [CATransaction commit];
}

// Shows the title of the chapter at `time` in the scrubber tile.
- (void)showChapterAt:(double)time {
    const NSInteger index = [self currentChapterIndex:time];
    if (index < 0) return;
    self.chapterLabel.text = self.chapters[(NSUInteger)index][@"title"];
    [self layoutChapterLabel:CGRectGetWidth(self.scrubTile.bounds)];
}

- (void)updateChapters:(double)total at:(double)time {
    NSArray<NSDictionary *> *chapters = YTKACEPanelChapters(total);
    // (Two nils are equal; isEqualToArray: on a nil is not.)
    if (chapters != self.chapters && ![chapters isEqualToArray:self.chapters]) {
        self.chapters = chapters;
        YTKACEDebugLog(@"duo-panel", @"chapters: %lu", (unsigned long)chapters.count);
        [self setNeedsLayout];
    }
    if (self.chapters.count > 1) [self showChapterAt:time];
}

#pragma mark Chapter menu

- (NSInteger)currentChapterIndex:(double)time {
    for (NSUInteger index = 0; index < self.chapters.count; index++) {
        if (time >= [self.chapters[index][@"start"] doubleValue] && time < [self.chapters[index][@"end"] doubleValue]) return (NSInteger)index;
    }
    return self.chapters.count > 0 ? (NSInteger)self.chapters.count - 1 : -1;
}

// One item per chapter, with the current one ticked; choosing one seeks to it.
- (NSArray<UIMenuElement *> *)chapterActions {
    const NSInteger current = [self currentChapterIndex:self.slider.value];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak __typeof(self) weakSelf = self;
    [self.chapters enumerateObjectsUsingBlock:^(NSDictionary *chapter, NSUInteger index, __unused BOOL *stop) {
        UIAction *action = [UIAction actionWithTitle:chapter[@"title"] ?: @"" image:nil identifier:nil
                                             handler:^(__unused UIAction *item) { [weakSelf seekToChapter:index]; }];
        action.subtitle = YTKACEPanelTime([chapter[@"start"] doubleValue]);
        action.state = (NSInteger)index == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }];
    return actions;
}

// Seeks YouTube's player to `time` seconds. NO where it can't.
- (BOOL)seekTo:(double)time {
    id controller = [self controller];
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![controller respondsToSelector:seek]) return NO;
    ((void (*)(id, SEL, double))objc_msgSend)(controller, seek, time);
    return YES;
}

- (void)seekToChapter:(NSUInteger)index {
    if (index >= self.chapters.count) return;
    [self seekTo:[self.chapters[index][@"start"] doubleValue]];
    YTKACEDebugLog(@"duo-panel", @"chapter %lu", (unsigned long)index);
    [self refresh];
}

#pragma mark Settings menu

- (void)rebuildSettingsMenu {
    __weak __typeof(self) weakSelf = self;
    UIAction *fill = [UIAction actionWithTitle:@"Fill Screen"
                                         image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"]
                                    identifier:nil
                                       handler:^(__unused UIAction *action) { [weakSelf toggleFill]; }];
    fill.state = YTKACEFeatureEnabled(YTKACEDuoDeskFillKey) ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *settings = [UIAction actionWithTitle:@"Playback Settings"
                                             image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) { [weakSelf settingsPressed]; }];
    self.settingsTile.menu = [UIMenu menuWithChildren:@[fill, settings]];
}

- (void)toggleFill {
    YTKACESetPreference(YTKACEDuoDeskFillKey, !YTKACEFeatureEnabled(YTKACEDuoDeskFillKey));
    YTKACEDebugLog(@"duo-panel", @"fill screen %d", YTKACEFeatureEnabled(YTKACEDuoDeskFillKey));
    [self rebuildSettingsMenu];
    [self.player setNeedsLayout];
}

#pragma mark Actions

- (void)seekBy:(double)seconds {
    id controller = [self controller];
    const double total = YTKACEPanelDouble(controller, @"currentVideoTotalMediaTime");
    double time = YTKACEPanelDouble(controller, @"currentVideoMediaTime") + seconds;
    time = MAX(0.0, total > 1.0 ? MIN(total - 0.5, time) : time);
    if ([self seekTo:time]) [self refresh];
}

- (void)backPressed { [self seekBy:-10.0]; }
- (void)forwardPressed { [self seekBy:10.0]; }

- (void)playPressed {
    // YouTube's own handlers, so its state and analytics follow.
    id overlay = YTKACEPanelGet([self controller], @"activeVideoPlayerOverlay");
    const BOOL playing = [self isPlaying];
    SEL selector = NSSelectorFromString(playing ? @"didPressPause:" : @"didPressPlay:");
    if ([overlay respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(overlay, selector, nil);
    } else {
        id controller = [self controller];
        selector = NSSelectorFromString(playing ? @"pause" : @"play");
        if ([controller respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(controller, selector);
    }
    YTKACEDebugLog(@"duo-panel", @"%@", playing ? @"pause" : @"play");
    [self showPlaying:!playing];
}

- (void)captionsPressed {
    UIControl *button = YTKACEPanelOverlayButton([self controlsOverlay], @[@"_closedCaptionsOrSubtitlesButton"]);
    YTKACEDebugLog(@"duo-panel", @"captions button %@", button != nil ? @"pressed" : @"not found");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)settingsPressed {
    UIControl *button = YTKACEPanelOverlayButton([self controlsOverlay], @[@"_settingsButton", @"_overflowButton"]);
    YTKACEDebugLog(@"duo-panel", @"settings button %@", button != nil ? @"pressed" : @"not found");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)speedPressed {
    static const double rates[] = {1.0, 1.25, 1.5, 1.75, 2.0, 0.5, 0.75};
    const NSUInteger count = sizeof(rates) / sizeof(rates[0]);
    NSUInteger next = 0;
    for (NSUInteger index = 0; index < count; index++) {
        if (fabs(rates[index] - self.rate) < 0.01) { next = (index + 1) % count; break; }
    }
    id overlay = YTKACEPanelGet([self controller], @"activeVideoPlayerOverlay");
    if (!YTKACEPanelSetRate(overlay, rates[next]) && !YTKACEPanelSetRate([self controller], rates[next])) return;
    self.rate = rates[next];
    // Shared with YTKACE's speed button and start speed.
    [NSUserDefaults.standardUserDefaults setFloat:(float)self.rate forKey:YTKACEPanelRateKey];
    YTKACEDebugLog(@"duo-panel", @"speed %.2f", self.rate);
    [self refresh];
}

- (void)skip:(NSString *)name {
    id overlay = YTKACEPanelGet([self controller], @"activeVideoPlayerOverlay");
    SEL plain = NSSelectorFromString(name);
    SEL withSender = NSSelectorFromString([name stringByAppendingString:@":"]);
    if ([overlay respondsToSelector:plain]) {
        ((void (*)(id, SEL))objc_msgSend)(overlay, plain);
    } else if ([overlay respondsToSelector:withSender]) {
        ((void (*)(id, SEL, id))objc_msgSend)(overlay, withSender, nil);
    }
}

- (void)previousPressed { [self skip:@"didPressPrevious"]; }
- (void)nextPressed { [self skip:@"didPressNext"]; }

- (void)exitPressed {
    UIView *button = YTKACEPanelFind(self.player, @"YTEnterExitFullscreenButtonView", 8);
    UIControl *control = YTKACEPanelControlIn(button);
    YTKACEDebugLog(@"duo-panel", @"exit button %@", control != nil ? @"pressed" : @"not found");
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

#pragma mark Scrubbing

- (void)scrubBegan { self.scrubbing = YES; }

- (void)scrubMoved {
    self.elapsedLabel.text = YTKACEPanelTime(self.slider.value);
    if (self.chapters.count > 1) [self showChapterAt:self.slider.value];
}

- (void)scrubEnded {
    [self seekTo:self.slider.value];
    // Let the player catch up before the slider follows it again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.scrubbing = NO;
    });
}

@end

#pragma mark - Popups

// The panel while it is showing, so YouTube's popups can be kept on its half.
static __weak YTKACEDeskPanel *YTKACEShownPanel;

// YouTube's settings popup and its submenus (quality, speed, captions, more) are
// all one YTContextualSheetView, which YouTube places next to the button that
// opened it and resizes for each submenu. With the laptop panel up, that lands
// across the crease, so the sheet is kept on the panel's half instead: just
// below the gear tile, and no lower than the screen allows.
static CGRect YTKACESheetFrameBelowCrease(UIView *sheet, CGRect frame) {
    YTKACEDeskPanel *panel = YTKACEShownPanel;
    if (panel == nil || panel.hidden || panel.window == nil) return frame;
    if (sheet.window != nil && sheet.window != panel.window) return frame;
    UIView *space = sheet.superview ?: panel.window;
    const CGRect region = [panel.superview convertRect:panel.frame toView:space];
    UIView *gear = panel.settingsTile;
    const CGFloat margin = 8.0;
    frame.size.height = MIN(CGRectGetHeight(frame), CGRectGetHeight(region) - 2.0 * margin);
    CGFloat top = CGRectGetMaxY([gear.superview convertRect:gear.frame toView:space]) + margin;
    top = MIN(top, CGRectGetMaxY(region) - margin - CGRectGetHeight(frame));
    frame.origin.y = MAX(top, CGRectGetMinY(region) + margin);
    frame.origin.x = MAX(CGRectGetMinX(region) + margin,
                         MIN(CGRectGetMinX(frame), CGRectGetMaxX(region) - margin - CGRectGetWidth(frame)));
    return frame;
}

static IMP YTKACEOrigSheetSetFrame;

static void YTKACESheetSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))YTKACEOrigSheetSetFrame)(self, _cmd, YTKACESheetFrameBelowCrease(self, frame));
}

void YTKACEInstallDuoDeskPanelHooks(void) {
    YTKACEInstallInstanceHook(@"YTContextualSheetView", @"setFrame:", (IMP)YTKACESheetSetFrame, &YTKACEOrigSheetSetFrame);
    Class cls = NSClassFromString(@"YTPlayerBarChaptersDecorationController");
    SEL selector = NSSelectorFromString(@"createChapterCollectionWithTotalTime:");
    Method method = cls != Nil ? class_getInstanceMethod(cls, selector) : NULL;
    if (method == NULL) return;
    char argument[8] = {0};
    method_getArgumentType(method, 2, argument, sizeof(argument));
    char *result = method_copyReturnType(method);
    const BOOL object = result != NULL && result[0] == '@';
    const BOOL none = result != NULL && result[0] == 'v';
    free(result);
    if (argument[0] != 'd' || (!object && !none)) return;
    YTKACEChapterControllers = [NSHashTable weakObjectsHashTable];
    YTKACEInstallInstanceHook(@"YTPlayerBarChaptersDecorationController", @"createChapterCollectionWithTotalTime:",
                              object ? (IMP)YTKACECreateChapterCollectionObject : (IMP)YTKACECreateChapterCollectionVoid,
                              &YTKACEOrigCreateChapterCollection);
}


#pragma mark - Entry

static const void *YTKACEDeskPanelKey = &YTKACEDeskPanelKey;

void YTKACEDuoDeskPanelUpdate(UIView *player, CGRect fold) {
    YTKACEDeskPanel *panel = objc_getAssociatedObject(player, YTKACEDeskPanelKey);
    id controller = YTKACEPanelPlayerController(player);
    const BOOL show = !CGRectIsNull(fold) && !YTKACEPanelBool(controller, @"isPlayingAd");
    if (!show) {
        if (panel != nil && !panel.hidden) {
            panel.hidden = YES;
            // An empty shape, not nil (which means a reflection that fills the lower
            // half): nothing of it shows while the panel is hidden.
            DUOSetDeskReflectionRegions(player, @[], @[]);
            panel.reflectionRects = nil;
            if (YTKACEShownPanel == panel) YTKACEShownPanel = nil;
            [panel restoreYouTubeControls];
        }
        return;
    }
    const BOOL fresh = panel == nil || panel.hidden;
    if (panel == nil) {
        panel = [YTKACEDeskPanel new];
        panel.player = player;
        objc_setAssociatedObject(player, YTKACEDeskPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACEDebugLog(@"duo-panel", @"created");
    }
    const CGFloat top = CGRectGetMaxY(fold);
    const CGRect frame = CGRectMake(0.0, top, CGRectGetWidth(player.bounds), CGRectGetHeight(player.bounds) - top);
    // This can run inside YouTube's own animation (entering full screen), which
    // would otherwise fly the new panel and its tiles in from the top left.
    // A panel that is first shown is placed and laid out at its final size.
    YTKACEShownPanel = panel;
    void (^place)(void) = ^{
        if (panel.superview != player) [player addSubview:panel];
        else if (player.subviews.lastObject != panel) [player bringSubviewToFront:panel];
        if (!CGRectEqualToRect(panel.frame, frame)) panel.frame = frame;
        if (panel.hidden) {
            panel.hidden = NO;
        }
        // The panel keeps its size while hidden, so showing it again does not lay
        // it out by itself, and the reflection's shape comes from that layout.
        if (fresh) {
            [panel setNeedsLayout];
            [panel layoutIfNeeded];
        }
    };
    if (fresh) [UIView performWithoutAnimation:place];
    else place();
}
