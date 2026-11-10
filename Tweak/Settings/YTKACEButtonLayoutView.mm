#import "YTKACEButtonLayoutView.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/OverlayButtonLayout.h"
#import "../UI/Assets.h"
#import "../YTKACE.h"
#import "../Features/Downloads/DownloadCoordinator.h"

static NSString *const YTKACEHiddenZone = @"hidden";
static const CGFloat YTKACEChipHeight = 32.0;
static const CGFloat YTKACEChipSpacing = 6.0;

static UIColor *YTKACELayoutSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceSurfaceColor(traits);
    }];
}

// The images the real player buttons use.
static UIImage *YTKACEChipImage(NSString *identifier) {
    if ([identifier isEqualToString:@"loop"]) return YTKACEAssetImage(@"repeat_24pt_3x_Normal", @"repeat");
    if ([identifier isEqualToString:@"pip"]) return YTKACEAssetImage(@"picture_in_picture_24pt_3x_Normal", @"pip");
    if ([identifier isEqualToString:@"downloads"]) return YTKACEDownloadGlyphImage();
    if ([identifier isEqualToString:@"sleeptimer"]) {
        return YTKACEYouTubeImage(@[@"yt_outline_experimental_sleep_timer_vd_theme_24",
                                    @"yt_outline_experimental_sleep_timer_black_24",
                                    @"yt_outline_sleep_timer_24pt", @"yt_outline_moon_24pt"], @"moon.zzz");
    }
    if ([identifier isEqualToString:@"sponsorblock"]) return [UIImage systemImageNamed:@"shield.lefthalf.filled"];
    if ([identifier isEqualToString:@"transcript"]) return [UIImage systemImageNamed:@"text.bubble"];
    return nil;
}

static UIImageView *YTKACEChipImageView(UIImage *image) {
    UIImageView *view = [[UIImageView alloc] initWithImage:
        [[image imageByApplyingSymbolConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium]] ?: image
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    view.contentMode = UIViewContentModeScaleAspectFit;
    return view;
}

static BOOL YTKACESpeedChipIsMenu(void) {
    return [YTKACEPreferenceObject(@"YTKACE.Preference.Player.SpeedButtonStyle") integerValue] == 1;
}

@interface YTKACELayoutChip : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *minus;
@property(nonatomic, strong) UIImageView *plus;
@property(nonatomic, assign) BOOL inTray;
- (void)refreshContent;
@end

@implementation YTKACELayoutChip

- (instancetype)initWithButton:(NSDictionary *)button {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    self.identifier = button[@"id"];
    self.title = YTKACELocalized(button[@"title"]);
    self.layer.cornerRadius = YTKACEChipHeight * 0.5;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = self.title;
    NSString *text = button[@"text"];
    UIImage *image = YTKACEChipImage(self.identifier);
    if ([self.identifier isEqualToString:@"speed"]) {
        self.label = [UILabel new];
        self.label.text = @"1x";
        self.minus = YTKACEChipImageView(YTKACESpeedButtonImage(NO));
        self.plus = YTKACEChipImageView(YTKACESpeedButtonImage(YES));
        [self addSubview:self.minus];
        [self addSubview:self.plus];
    } else if (text.length != 0 || image == nil) {
        self.label = [UILabel new];
        self.label.text = text.length != 0 ? text : self.title;
    } else {
        self.icon = YTKACEChipImageView(image);
        [self addSubview:self.icon];
    }
    self.label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.label.textAlignment = NSTextAlignmentCenter;
    if (self.label != nil) [self addSubview:self.label];
    [self refreshContent];
    [self applyStyle];
    return self;
}

// The speed button is one "1x" button, or minus, speed and plus.
- (void)refreshContent {
    const BOOL split = self.minus != nil && !YTKACESpeedChipIsMenu();
    self.minus.hidden = !split;
    self.plus.hidden = !split;
    [self setNeedsLayout];
}

- (CGFloat)labelWidth {
    return ceil([self.label sizeThatFits:CGSizeZero].width);
}

- (CGFloat)chipWidth {
    if (self.minus != nil && !self.minus.hidden) return 18.0 * 2.0 + [self labelWidth] + 12.0 * 2.0 + 16.0;
    if (self.label != nil) return MAX(YTKACEChipHeight, [self labelWidth] + 18.0);
    return YTKACEChipHeight;
}

- (void)setInTray:(BOOL)inTray {
    if (_inTray == inTray) return;
    _inTray = inTray;
    [UIView animateWithDuration:0.2 animations:^{ [self applyStyle]; }];
}

// White on the dark player; normal colors in the tray below it.
- (void)applyStyle {
    UIColor *tint = self.inTray ? UIColor.labelColor : UIColor.whiteColor;
    self.backgroundColor = self.inTray ? [UIColor.labelColor colorWithAlphaComponent:0.08]
                                       : [UIColor colorWithWhite:1.0 alpha:0.16];
    self.icon.tintColor = tint;
    self.minus.tintColor = tint;
    self.plus.tintColor = tint;
    self.label.textColor = tint;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGRect bounds = self.bounds;
    self.icon.frame = CGRectInset(bounds, 7.0, 7.0);
    if (self.minus != nil && !self.minus.hidden) {
        const CGFloat size = 18.0, y = (CGRectGetHeight(bounds) - size) * 0.5;
        self.minus.frame = CGRectMake(8.0, y, size, size);
        self.plus.frame = CGRectMake(CGRectGetWidth(bounds) - 8.0 - size, y, size, size);
        self.label.frame = CGRectMake(8.0 + size, 0.0, CGRectGetWidth(bounds) - 2.0 * (8.0 + size), CGRectGetHeight(bounds));
    } else {
        self.label.frame = bounds;
    }
}

@end

@interface YTKACEButtonLayoutView () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIButton *resetButton;
@property(nonatomic, assign) BOOL saving;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIView *playerView;
@property(nonatomic, strong) UIView *trayView;
@property(nonatomic, strong) UILabel *trayLabel;
@property(nonatomic, strong) UILabel *trayEmptyLabel;
@property(nonatomic, strong) UIView *zoneHighlight;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *nativeMarks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACELayoutChip *> *chips;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *zones;
@property(nonatomic, strong) YTKACELayoutChip *dragging;
@property(nonatomic, assign) CGPoint dragOffset;
@property(nonatomic, copy) NSString *targetZone;
@property(nonatomic, assign) NSUInteger targetIndex;
@property(nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@end

@implementation YTKACEButtonLayoutView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.selectionFeedback = [UISelectionFeedbackGenerator new];

    self.hintLabel = [UILabel new];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.font = [UIFont systemFontOfSize:14.0];
    self.hintLabel.textColor = UIColor.secondaryLabelColor;
    [self addSubview:self.hintLabel];

    self.playerView = [UIView new];
    self.playerView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    self.playerView.layer.cornerRadius = 14.0;
    self.playerView.layer.cornerCurve = kCACornerCurveContinuous;
    self.playerView.clipsToBounds = YES;
    self.playerView.layer.borderWidth = 1.0;
    self.playerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    [self addSubview:self.playerView];
    [self buildPlayerMock];

    self.zoneHighlight = [UIView new];
    self.zoneHighlight.layer.cornerRadius = (YTKACEChipHeight + 8.0) * 0.5;
    self.zoneHighlight.layer.borderWidth = 1.5;
    self.zoneHighlight.alpha = 0.0;
    self.zoneHighlight.userInteractionEnabled = NO;
    [self addSubview:self.zoneHighlight];

    self.trayView = [UIView new];
    self.trayView.backgroundColor = YTKACELayoutSurface();
    self.trayView.layer.cornerRadius = 14.0;
    self.trayView.layer.cornerCurve = kCACornerCurveContinuous;
    self.trayView.layer.borderWidth = 1.0;
    self.trayView.layer.borderColor = [self trayBorderColor].CGColor;
    [self addSubview:self.trayView];
    self.trayLabel = [UILabel new];
    self.trayLabel.text = YTKACELocalized(@"Hidden");
    self.trayLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.trayLabel.textColor = UIColor.secondaryLabelColor;
    [self.trayView addSubview:self.trayLabel];
    self.trayEmptyLabel = [UILabel new];
    self.trayEmptyLabel.text = YTKACELocalized(@"Drop a button here to hide it.");
    self.trayEmptyLabel.font = [UIFont systemFontOfSize:14.0];
    self.trayEmptyLabel.textColor = UIColor.tertiaryLabelColor;
    self.trayEmptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.trayView addSubview:self.trayEmptyLabel];
    self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.resetButton setTitle:YTKACELocalized(@"Reset") forState:UIControlStateNormal];
    self.resetButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.resetButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [self.resetButton addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    [self.trayView addSubview:self.resetButton];

    self.chips = [NSMutableDictionary dictionary];
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) {
        YTKACELayoutChip *chip = [[YTKACELayoutChip alloc] initWithButton:button];
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
        press.minimumPressDuration = 0.15;
        press.allowableMovement = CGFLOAT_MAX;
        [chip addGestureRecognizer:press];
        self.chips[chip.identifier] = chip;
        [self addSubview:chip];
    }
    [self setHint:nil];
    [self loadModel];
    // the toggles on the same page can change buttons too
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged)
                                               name:YTKACEPreferencesDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)preferencesChanged {
    if (self.dragging != nil || self.saving) return;
    NSDictionary *before = [self.zones copy];
    const CGFloat height = [self heightForWidth:CGRectGetWidth(self.bounds)];
    YTKACELayoutChip *speed = self.chips[@"speed"];
    const CGFloat speedWidth = [speed chipWidth];
    [speed refreshContent];
    [self loadModel];
    if ([before isEqualToDictionary:self.zones] && [speed chipWidth] == speedWidth) return;
    [self animateToModel];
    // only resize the row; the toggle that changed is already right
    if (self.heightHandler != nil && [self heightForWidth:CGRectGetWidth(self.bounds)] != height) {
        self.heightHandler();
    }
}

- (void)loadModel {
    self.zones = [NSMutableDictionary dictionary];
    NSMutableArray *hidden = [NSMutableArray array];
    for (NSString *zone in YTKACEOverlayZones()) {
        NSMutableArray *ids = [NSMutableArray array];
        for (NSString *identifier in YTKACEOverlayZoneOrder(zone)) {
            [YTKACEOverlayButtonEnabled(identifier) ? ids : hidden addObject:identifier];
        }
        self.zones[zone] = ids;
    }
    // hidden ones in catalog order
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) {
        if ([hidden containsObject:button[@"id"]]) [ordered addObject:button[@"id"]];
    }
    self.zones[YTKACEHiddenZone] = ordered;
}

#pragma mark - Player mock

- (UIView *)markWithSymbol:(NSString *)symbol {
    return [self markWithImage:[UIImage systemImageNamed:symbol]];
}

- (UIView *)markWithImage:(UIImage *)image {
    UIImageView *view = YTKACEChipImageView(image);
    view.tintColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    return view;
}

// Stand-ins for YouTube's own controls so the zones make sense.
- (void)buildPlayerMock {
    self.nativeMarks = [NSMutableDictionary dictionary];
    // autoplay switch: track with a knob holding a pause glyph, like YouTube's
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    pill.layer.cornerRadius = 8.0;
    UIView *knob = [[UIView alloc] initWithFrame:CGRectMake(0.0, -1.0, 18.0, 18.0)];
    knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    knob.layer.cornerRadius = 9.0;
    UIImageView *glyph = YTKACEChipImageView([UIImage systemImageNamed:@"pause.fill"]);
    glyph.tintColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    glyph.frame = CGRectInset(knob.bounds, 5.0, 5.0);
    [knob addSubview:glyph];
    [pill addSubview:knob];
    self.nativeMarks[@"autoplay"] = pill;
    self.nativeMarks[@"cast"] = [self markWithImage:YTKACEYouTubeImage(@[@"yt_outline_chromecast_24pt", @"ic_cast"], @"airplayvideo")];
    self.nativeMarks[@"captions"] = [self markWithImage:YTKACEYouTubeImage(@[@"yt_outline_closed_caption_24pt", @"ic_closed_caption"], @"captions.bubble")];
    self.nativeMarks[@"gear"] = [self markWithImage:YTKACEGearImage()];
    self.nativeMarks[@"fullscreen"] = [self markWithImage:YTKACEYouTubeImage(@[@"ic_fullscreen"], @"arrow.up.left.and.arrow.down.right")];
    UIView *title = [UIView new];
    title.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    title.layer.cornerRadius = 4.0;
    self.nativeMarks[@"title"] = title;
    UIView *track = [UIView new];
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    self.nativeMarks[@"track"] = track;
    UIView *played = [UIView new];
    played.backgroundColor = UIColor.systemRedColor;
    self.nativeMarks[@"played"] = played;
    UILabel *time = [UILabel new];
    time.text = @"4:20 / 10:35";
    time.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
    time.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    self.nativeMarks[@"time"] = time;
    UIView *play = [self markWithSymbol:@"pause.fill"];
    ((UIImageView *)play).preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:26.0 weight:UIImageSymbolWeightMedium];
    self.nativeMarks[@"play"] = play;
    for (UIView *mark in self.nativeMarks.allValues) [self.playerView addSubview:mark];
}

- (CGFloat)rowCenterY:(NSString *)zone {
    const CGFloat height = CGRectGetHeight(self.playerView.bounds);
    if ([zone isEqualToString:YTKACEOverlayZoneTop]) return 24.0;
    if ([zone isEqualToString:YTKACEOverlayZoneBelow]) return 62.0;
    return height - 34.0;
}

// Right edge of each row, in player coordinates.
- (CGFloat)rowRight:(NSString *)zone {
    if ([zone isEqualToString:YTKACEOverlayZoneTop]) return CGRectGetMinX(self.nativeMarks[@"autoplay"].frame) - 8.0;
    if ([zone isEqualToString:YTKACEOverlayZoneBottom]) return CGRectGetMinX(self.nativeMarks[@"fullscreen"].frame) - 6.0;
    return CGRectGetWidth(self.playerView.bounds) - 10.0;
}

- (void)layoutPlayerMock {
    const CGFloat width = CGRectGetWidth(self.playerView.bounds);
    const CGFloat height = CGRectGetHeight(self.playerView.bounds);
    const CGFloat topY = [self rowCenterY:YTKACEOverlayZoneTop];
    CGFloat x = width - 12.0 - 26.0;
    for (NSString *name in @[@"gear", @"captions", @"cast"]) {
        self.nativeMarks[name].frame = CGRectMake(x + 3.0, topY - 10.0, 20.0, 20.0);
        x -= 32.0;
    }
    self.nativeMarks[@"autoplay"].frame = CGRectMake(x - 4.0, topY - 8.0, 30.0, 16.0);
    self.nativeMarks[@"title"].frame = CGRectMake(14.0, topY - 5.0, MIN(120.0, width * 0.28), 10.0);
    self.nativeMarks[@"play"].frame = CGRectMake(width * 0.5 - 14.0, height * 0.5 - 14.0, 28.0, 28.0);
    const CGFloat bottomY = [self rowCenterY:YTKACEOverlayZoneBottom];
    self.nativeMarks[@"fullscreen"].frame = CGRectMake(width - 12.0 - 23.0, bottomY - 10.0, 20.0, 20.0);
    self.nativeMarks[@"time"].frame = CGRectMake(14.0, bottomY - 8.0, 90.0, 16.0);
    self.nativeMarks[@"track"].frame = CGRectMake(14.0, height - 11.0, width - 28.0, 3.0);
    self.nativeMarks[@"played"].frame = CGRectMake(14.0, height - 11.0, (width - 28.0) * 0.4, 3.0);
}

#pragma mark - Layout

- (void)setHint:(NSString *)title {
    self.hintLabel.text = title ?: YTKACELocalized(@"Hold a button and drag it where you want it.");
    self.hintLabel.font = title != nil ? [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
                                       : [UIFont systemFontOfSize:14.0];
    self.hintLabel.textColor = title != nil ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (CGFloat)playerWidthForWidth:(CGFloat)width {
    return MIN(560.0, width - 32.0);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    const CGFloat inner = [self playerWidthForWidth:width];
    return 44.0 + MAX(200.0, round(inner * 9.0 / 16.0)) + 16.0 + [self trayHeightForWidth:inner] + 12.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = [self playerWidthForWidth:CGRectGetWidth(self.bounds)];
    const CGFloat left = round((CGRectGetWidth(self.bounds) - width) * 0.5);
    self.hintLabel.frame = CGRectMake(left, 6.0, width, 30.0);
    const CGFloat playerHeight = MAX(200.0, round(width * 9.0 / 16.0));
    self.playerView.frame = CGRectMake(left, 44.0, width, playerHeight);
    [self layoutPlayerMock];
    const CGFloat trayHeight = [self trayHeightForWidth:width];
    self.trayView.frame = CGRectMake(left, CGRectGetMaxY(self.playerView.frame) + 16.0, width, trayHeight);
    self.trayLabel.frame = CGRectMake(16.0, 10.0, width - 120.0, 18.0);
    self.resetButton.frame = CGRectMake(width - 96.0, 5.0, 80.0, 28.0);
    self.trayEmptyLabel.frame = CGRectMake(16.0, 34.0, width - 32.0, YTKACEChipHeight);
    if (self.dragging == nil) [self layoutChipsAnimated:NO];
}

- (UIScrollView *)enclosingScrollView {
    for (UIView *view = self.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:UIScrollView.class]) return (UIScrollView *)view;
    }
    return nil;
}

- (CGFloat)trayHeightForWidth:(CGFloat)width {
    NSArray *frames = [self trayFrames:self.zones[YTKACEHiddenZone] gap:NSNotFound gapWidth:0.0 width:width];
    CGFloat bottom = 34.0 + YTKACEChipHeight;
    for (NSValue *frame in frames) bottom = MAX(bottom, CGRectGetMaxY(frame.CGRectValue));
    return bottom + 14.0;
}

// Right-aligned row frames in scroll view coordinates, with an optional gap.
- (NSArray<NSValue *> *)rowFrames:(NSArray<NSString *> *)ids zone:(NSString *)zone
                              gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSString *identifier in ids) [widths addObject:@([self.chips[identifier] chipWidth])];
    CGFloat total = 0.0;
    for (NSNumber *value in widths) total += value.doubleValue + YTKACEChipSpacing;
    if (gap != NSNotFound) total += gapWidth + YTKACEChipSpacing;
    total -= YTKACEChipSpacing;
    CGFloat x = MAX(10.0, [self rowRight:zone] - total);
    const CGFloat y = [self rowCenterY:zone] - YTKACEChipHeight * 0.5;
    NSMutableArray *frames = [NSMutableArray array];
    for (NSUInteger index = 0; index < widths.count; index++) {
        if (index == gap) x += gapWidth + YTKACEChipSpacing;
        CGRect frame = CGRectMake(x, y, widths[index].doubleValue, YTKACEChipHeight);
        [frames addObject:[NSValue valueWithCGRect:[self.playerView convertRect:frame toView:self]]];
        x += widths[index].doubleValue + YTKACEChipSpacing;
    }
    return frames;
}

// Left-aligned, wrapping frames in tray coordinates.
- (NSArray<NSValue *> *)trayFrames:(NSArray<NSString *> *)ids gap:(NSUInteger)gap
                          gapWidth:(CGFloat)gapWidth width:(CGFloat)width {
    NSMutableArray *frames = [NSMutableArray array];
    CGFloat x = 16.0, y = 34.0;
    const CGFloat limit = width - 16.0;
    for (NSUInteger index = 0; index <= ids.count; index++) {
        if (index == gap) {
            if (x + gapWidth > limit) { x = 16.0; y += YTKACEChipHeight + 8.0; }
            x += gapWidth + 8.0;
        }
        if (index == ids.count) break;
        const CGFloat chipWidth = [self.chips[ids[index]] chipWidth];
        if (x + chipWidth > limit) { x = 16.0; y += YTKACEChipHeight + 8.0; }
        [frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, chipWidth, YTKACEChipHeight)]];
        x += chipWidth + 8.0;
    }
    return frames;
}

- (NSArray<NSValue *> *)framesForZone:(NSString *)zone gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    NSArray *ids = self.zones[zone];
    if (![zone isEqualToString:YTKACEHiddenZone]) return [self rowFrames:ids zone:zone gap:gap gapWidth:gapWidth];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSValue *frame in [self trayFrames:ids gap:gap gapWidth:gapWidth width:CGRectGetWidth(self.trayView.bounds)]) {
        [frames addObject:[NSValue valueWithCGRect:[self.trayView convertRect:frame.CGRectValue toView:self]]];
    }
    return frames;
}

- (void)layoutChipsAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        for (NSString *zone in self.zones) {
            const BOOL target = self.dragging != nil && [zone isEqualToString:self.targetZone];
            NSArray<NSValue *> *frames = [self framesForZone:zone gap:target ? self.targetIndex : NSNotFound
                                                    gapWidth:target ? [self.dragging chipWidth] : 0.0];
            NSArray<NSString *> *ids = self.zones[zone];
            for (NSUInteger index = 0; index < ids.count; index++) {
                YTKACELayoutChip *chip = self.chips[ids[index]];
                chip.inTray = [zone isEqualToString:YTKACEHiddenZone];
                chip.bounds = (CGRect){CGPointZero, frames[index].CGRectValue.size};
                chip.center = CGPointMake(CGRectGetMidX(frames[index].CGRectValue),
                                          CGRectGetMidY(frames[index].CGRectValue));
            }
        }
        self.trayEmptyLabel.alpha = [self.zones[YTKACEHiddenZone] count] == 0 &&
            ![self.targetZone isEqualToString:YTKACEHiddenZone] ? 1.0 : 0.0;
    };
    if (!animated) {
        apply();
        return;
    }
    [UIView animateWithDuration:0.38 delay:0.0 usingSpringWithDamping:0.78 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:apply completion:nil];
}

#pragma mark - Dragging

- (UIColor *)trayBorderColor {
    return [UIColor.separatorColor resolvedColorWithTraitCollection:self.traitCollection];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.dragging == nil) self.trayView.layer.borderColor = [self trayBorderColor].CGColor;
}

- (NSString *)zoneAtPoint:(CGPoint)point {
    if (point.y > CGRectGetMaxY(self.playerView.frame) + 6.0) return YTKACEHiddenZone;
    CGPoint local = [self convertPoint:point toView:self.playerView];
    NSString *best = YTKACEOverlayZoneBelow;
    CGFloat distance = CGFLOAT_MAX;
    for (NSString *zone in YTKACEOverlayZones()) {
        const CGFloat delta = fabs(local.y - [self rowCenterY:zone]);
        if (delta < distance) {
            distance = delta;
            best = zone;
        }
    }
    return best;
}

- (NSUInteger)indexInZone:(NSString *)zone atPoint:(CGPoint)point {
    NSArray<NSValue *> *frames = [self framesForZone:zone gap:NSNotFound gapWidth:0.0];
    NSUInteger index = 0;
    for (NSValue *value in frames) {
        CGRect frame = value.CGRectValue;
        const BOOL sameLine = point.y < CGRectGetMaxY(frame) + 4.0;
        const BOOL before = [zone isEqualToString:YTKACEHiddenZone]
            ? (point.y > CGRectGetMaxY(frame) + 4.0 || (sameLine && point.x > CGRectGetMidX(frame)))
            : point.x > CGRectGetMidX(frame);
        if (before) index++;
    }
    return index;
}

- (void)updateZoneHighlight {
    if (self.dragging == nil || [self.targetZone isEqualToString:YTKACEHiddenZone]) {
        self.zoneHighlight.alpha = 0.0;
        self.trayView.layer.borderColor = (self.dragging != nil ? UIColor.systemBlueColor : [self trayBorderColor]).CGColor;
        return;
    }
    self.trayView.layer.borderColor = [self trayBorderColor].CGColor;
    const CGFloat right = [self rowRight:self.targetZone];
    const CGFloat centerY = [self rowCenterY:self.targetZone];
    CGRect frame = CGRectMake(6.0, centerY - YTKACEChipHeight * 0.5 - 4.0, right - 2.0, YTKACEChipHeight + 8.0);
    self.zoneHighlight.frame = [self.playerView convertRect:frame toView:self];
    self.zoneHighlight.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    self.zoneHighlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    self.zoneHighlight.alpha = 1.0;
}

- (void)handleDrag:(UILongPressGestureRecognizer *)recognizer {
    YTKACELayoutChip *chip = (YTKACELayoutChip *)recognizer.view;
    const CGPoint point = [recognizer locationInView:self];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragging = chip;
            for (NSString *zone in self.zones) {
                NSUInteger index = [self.zones[zone] indexOfObject:chip.identifier];
                if (index == NSNotFound) continue;
                [self.zones[zone] removeObjectAtIndex:index];
                self.targetZone = zone;
                self.targetIndex = index;
            }
            self.dragOffset = CGPointMake(point.x - chip.center.x, point.y - chip.center.y);
            [self enclosingScrollView].scrollEnabled = NO;
            [self bringSubviewToFront:chip];
            chip.layer.shadowColor = UIColor.blackColor.CGColor;
            chip.layer.shadowOpacity = 0.35;
            chip.layer.shadowRadius = 10.0;
            chip.layer.shadowOffset = CGSizeMake(0.0, 6.0);
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            [self.selectionFeedback prepare];
            [self setHint:chip.title];
            [UIView animateWithDuration:0.25 delay:0.0 usingSpringWithDamping:0.7 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionAllowUserInteraction animations:^{
                chip.transform = CGAffineTransformMakeScale(1.2, 1.2);
                [self updateZoneHighlight];
            } completion:nil];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            chip.center = CGPointMake(point.x - self.dragOffset.x, point.y - self.dragOffset.y);
            NSString *zone = [self zoneAtPoint:point];
            const NSUInteger index = [self indexInZone:zone atPoint:point];
            if (![zone isEqualToString:self.targetZone] || index != self.targetIndex) {
                self.targetZone = zone;
                self.targetIndex = index;
                chip.inTray = [zone isEqualToString:YTKACEHiddenZone];
                [self.selectionFeedback selectionChanged];
                [self.selectionFeedback prepare];
                [UIView animateWithDuration:0.2 animations:^{ [self updateZoneHighlight]; }];
                [self layoutChipsAnimated:YES];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            NSMutableArray *ids = self.zones[self.targetZone];
            [ids insertObject:chip.identifier atIndex:MIN(self.targetIndex, ids.count)];
            NSString *dropped = self.targetZone;
            self.dragging = nil;
            self.targetZone = nil;
            [self enclosingScrollView].scrollEnabled = YES;
            [self setHint:nil];
            [self save:chip.identifier zone:dropped];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            [self setNeedsLayout];
            [UIView animateWithDuration:0.42 delay:0.0 usingSpringWithDamping:0.72 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                chip.transform = CGAffineTransformIdentity;
                chip.layer.shadowOpacity = 0.0;
                [self updateZoneHighlight];
                [self layoutIfNeeded];
                [self layoutChipsAnimated:NO];
            } completion:nil];
            break;
        }
        default:
            break;
    }
}

#pragma mark - Saving

- (void)save:(NSString *)identifier zone:(NSString *)zone {
    NSMutableDictionary *layout = [NSMutableDictionary dictionary];
    for (NSString *row in YTKACEOverlayZones()) layout[row] = [self.zones[row] copy];
    self.saving = YES;
    YTKACESetOverlayLayout(layout);
    YTKACESetOverlayButtonEnabled(identifier, ![zone isEqualToString:YTKACEHiddenZone]);
    self.saving = NO;
    if (self.changeHandler != nil) self.changeHandler();
}

- (void)animateToModel {
    [self setNeedsLayout];
    [UIView animateWithDuration:0.42 delay:0.0 usingSpringWithDamping:0.78 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self layoutIfNeeded];
        [self layoutChipsAnimated:NO];
    } completion:nil];
}

- (void)resetLayout {
    self.saving = YES;
    YTKACESetOverlayLayout(nil);
    self.saving = NO;
    [self loadModel];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self animateToModel];
    if (self.changeHandler != nil) self.changeHandler();
}

@end
