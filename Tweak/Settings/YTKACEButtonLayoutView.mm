#import "YTKACEButtonLayoutView.h"
#import <objc/runtime.h>
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/OverlayButtonLayout.h"
#import "../UI/Assets.h"
#import "../YTKACE.h"
#import "../Features/Downloads/DownloadCoordinator.h"

// Every player button is a chip: YTKACE's own, which can go in any row, and
// YouTube's, which keep to their own row (top right, the center controls, or
// the fullscreen bar) but can be reordered there. Dropping any chip below the
// player in the Hidden tray hides it.

static NSString *const YTKACEHiddenZone = @"hidden";
static NSString *const YTKACECenterZone = @"center";
static const CGFloat YTKACEChipHeight = 32.0;
static const CGFloat YTKACEChipSpacing = 6.0;

static NSString *const YTKACEFullscreenOrderKey = @"YTKACE.Preference.Fullscreen.Order";
static NSString *const YTKACEMoreVideosKey = @"YTKACE.Preference.Overlay.MoreVideosHidden";

typedef NS_ENUM(NSInteger, YTKACEItemKind) {
    YTKACEItemOurs,
    YTKACEItemNativeTop,
    YTKACEItemCenter,
    YTKACEItemPill,
    YTKACEItemMore,
};

static UIColor *YTKACELayoutSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceSurfaceColor(traits);
    }];
}

#pragma mark - YouTube's buttons

static NSArray<NSString *> *YTKACEPillDefaultOrder(void) {
    return @[@"Like", @"Dislike", @"Comments", @"Save", @"Share", @"Ask", @"Overflow"];
}

static NSArray<NSString *> *YTKACEPillOrder(void) {
    NSMutableArray *order = [NSMutableArray array];
    id stored = YTKACEPreferenceObject(YTKACEFullscreenOrderKey);
    for (id key in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if ([YTKACEPillDefaultOrder() containsObject:key] && ![order containsObject:key]) [order addObject:key];
    }
    for (NSString *key in YTKACEPillDefaultOrder()) {
        if (![order containsObject:key]) [order addObject:key];
    }
    return order;
}

// id, title, kind and the setting that hides it, for each of YouTube's buttons.
static NSArray<NSDictionary *> *YTKACENativeItems(void) {
    static NSArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        NSDictionary *topTitles = @{@"autoplay": @"Autoplay Switch", @"cast": @"Cast Button",
                                    @"captions": @"Captions Button", @"gear": @"Settings Button"};
        NSDictionary *topKeys = @{@"autoplay": @"YTKACE.Preference.Overlay.AutoplayHidden",
                                  @"cast": @"YTKACE.Preference.Overlay.CastHidden",
                                  @"captions": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
                                  @"gear": @"YTKACE.Preference.Overlay.MoreButtonHidden"};
        for (NSString *name in YTKACENativeTopDefaultOrder()) {
            [list addObject:@{@"id": [@"yt." stringByAppendingString:name], @"name": name,
                              @"title": topTitles[name], @"kind": @(YTKACEItemNativeTop), @"key": topKeys[name]}];
        }
        [list addObject:@{@"id": @"yt.previous", @"name": @"previous", @"title": @"Previous/Next",
                          @"kind": @(YTKACEItemCenter), @"key": @"YTKACE.Preference.Overlay.PreviousNextHidden"}];
        [list addObject:@{@"id": @"yt.play", @"name": @"play", @"title": @"Play/Pause",
                          @"kind": @(YTKACEItemCenter), @"key": @"YTKACE.Preference.Overlay.PlayPauseHidden"}];
        [list addObject:@{@"id": @"yt.next", @"name": @"next", @"title": @"Previous/Next",
                          @"kind": @(YTKACEItemCenter), @"key": @"YTKACE.Preference.Overlay.PreviousNextHidden"}];
        NSDictionary *pillTitles = @{@"Overflow": @"⋯ Button"};
        for (NSString *name in YTKACEPillDefaultOrder()) {
            [list addObject:@{@"id": [@"yt.pill." stringByAppendingString:name], @"name": name,
                              @"title": pillTitles[name] ?: name, @"kind": @(YTKACEItemPill),
                              @"key": [NSString stringWithFormat:@"YTKACE.Preference.Fullscreen.%@Hidden", name]}];
        }
        [list addObject:@{@"id": @"yt.more", @"name": @"more", @"title": @"More videos", @"text": @"More videos",
                          @"kind": @(YTKACEItemMore), @"key": YTKACEMoreVideosKey}];
        items = list;
    });
    return items;
}

static NSDictionary *YTKACENativeItem(NSString *identifier) {
    for (NSDictionary *item in YTKACENativeItems()) {
        if ([item[@"id"] isEqualToString:identifier]) return item;
    }
    return nil;
}

static YTKACEItemKind YTKACEKindOf(NSString *identifier) {
    NSDictionary *item = YTKACENativeItem(identifier);
    return item != nil ? (YTKACEItemKind)[item[@"kind"] integerValue] : YTKACEItemOurs;
}

static BOOL YTKACEStoredBool(NSString *key) {
    return key.length != 0 && [NSUserDefaults.standardUserDefaults boolForKey:key];
}

// YouTube's autoplay switch, drawn small.
static UIImage *YTKACEAutoplayImage(void) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26.0, 16.0)];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        UIBezierPath *track = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.0, 3.0, 24.0, 10.0) cornerRadius:5.0];
        [[UIColor colorWithWhite:1.0 alpha:0.5] setFill];
        [track fill];
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.0, 0.0, 16.0, 16.0)] fill];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
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
    if ([identifier isEqualToString:@"yt.autoplay"]) return YTKACEAutoplayImage();
    if ([identifier isEqualToString:@"yt.cast"]) {
        return YTKACEYouTubeImage(@[@"yt_outline_chromecast_24pt", @"ic_cast"], @"airplayvideo");
    }
    if ([identifier isEqualToString:@"yt.captions"]) {
        return YTKACEYouTubeImage(@[@"yt_outline_closed_caption_24pt", @"ic_closed_caption"], @"captions.bubble");
    }
    if ([identifier isEqualToString:@"yt.gear"]) return YTKACEGearImage();
    NSDictionary *symbols = @{@"yt.previous": @"backward.end.fill", @"yt.play": @"pause.fill",
                              @"yt.next": @"forward.end.fill", @"yt.pill.Like": @"hand.thumbsup",
                              @"yt.pill.Dislike": @"hand.thumbsdown", @"yt.pill.Comments": @"text.bubble",
                              @"yt.pill.Save": @"bookmark", @"yt.pill.Share": @"arrowshape.turn.up.right",
                              @"yt.pill.Ask": @"sparkle", @"yt.pill.Overflow": @"ellipsis"};
    NSString *symbol = symbols[identifier];
    return symbol != nil ? [UIImage systemImageNamed:symbol] : nil;
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

#pragma mark - Chip

@interface YTKACELayoutChip : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, assign) YTKACEItemKind kind;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *minus;
@property(nonatomic, strong) UIImageView *plus;
@property(nonatomic, assign) BOOL inTray;
- (void)refreshContent;
- (CGFloat)chipWidth;
@end

@implementation YTKACELayoutChip

- (instancetype)initWithButton:(NSDictionary *)button {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    self.identifier = button[@"id"];
    self.title = YTKACELocalized(button[@"title"]);
    self.kind = YTKACEKindOf(self.identifier);
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
        self.label.text = YTKACELocalized(text.length != 0 ? text : self.title);
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

// White on the dark player; normal colors in the tray below it. YouTube's
// buttons get a thin outline so they read as YouTube's, not YTKACE's.
- (void)applyStyle {
    UIColor *tint = self.inTray ? UIColor.labelColor : UIColor.whiteColor;
    const BOOL youtube = self.kind != YTKACEItemOurs;
    if (self.inTray) {
        self.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    } else {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:youtube ? 0.07 : 0.16];
    }
    self.layer.borderWidth = youtube ? 1.0 : 0.0;
    self.layer.borderColor = (self.inTray ? [UIColor.labelColor colorWithAlphaComponent:0.18]
                                          : [UIColor colorWithWhite:1.0 alpha:0.22]).CGColor;
    self.icon.tintColor = tint;
    self.minus.tintColor = tint;
    self.plus.tintColor = tint;
    self.label.textColor = tint;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyStyle];
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

#pragma mark - Editor

@interface YTKACEButtonLayoutView () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIButton *resetButton;
@property(nonatomic, assign) BOOL saving;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIView *playerView;
@property(nonatomic, strong) UILabel *fullscreenLabel;
@property(nonatomic, strong) UIView *fullscreenView;
@property(nonatomic, strong) UIView *pillBackground;
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

    self.playerView = [self darkPanel];
    [self addSubview:self.playerView];
    [self buildPlayerMock];

    self.fullscreenLabel = [UILabel new];
    self.fullscreenLabel.text = YTKACELocalized(@"Fullscreen bar");
    self.fullscreenLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.fullscreenLabel.textColor = UIColor.secondaryLabelColor;
    [self addSubview:self.fullscreenLabel];
    self.fullscreenView = [self darkPanel];
    [self addSubview:self.fullscreenView];
    self.pillBackground = [UIView new];
    self.pillBackground.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    self.pillBackground.layer.cornerCurve = kCACornerCurveContinuous;
    self.pillBackground.userInteractionEnabled = NO;
    [self.fullscreenView addSubview:self.pillBackground];

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
    NSMutableArray *buttons = [YTKACEOverlayButtonCatalog() mutableCopy];
    [buttons addObjectsFromArray:YTKACENativeItems()];
    for (NSDictionary *button in buttons) {
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

- (UIView *)darkPanel {
    UIView *panel = [UIView new];
    panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    panel.layer.cornerRadius = 14.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.clipsToBounds = YES;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    return panel;
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

#pragma mark - Model

- (NSArray<NSString *> *)playerZones {
    return @[YTKACEOverlayZoneTop, YTKACEOverlayZoneBelow, YTKACECenterZone, YTKACEOverlayZoneBottom];
}

- (NSArray<NSString *> *)allZones {
    return @[YTKACEOverlayZoneTop, YTKACEOverlayZoneBelow, YTKACECenterZone, YTKACEOverlayZoneBottom,
             YTKACEOverlayZoneFullscreen, YTKACEHiddenZone];
}

- (void)loadModel {
    self.zones = [NSMutableDictionary dictionary];
    NSMutableArray *hiddenOurs = [NSMutableArray array];
    for (NSString *zone in YTKACEOverlayZones()) {
        NSMutableArray *ids = [NSMutableArray array];
        for (NSString *identifier in YTKACEOverlayZoneOrder(zone)) {
            [YTKACEOverlayButtonEnabled(identifier) ? ids : hiddenOurs addObject:identifier];
        }
        self.zones[zone] = ids;
    }
    NSMutableArray *hidden = [NSMutableArray array];
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) {
        if ([hiddenOurs containsObject:button[@"id"]]) [hidden addObject:button[@"id"]];
    }
    // YouTube's top buttons after ours in the top row.
    for (NSString *name in YTKACENativeTopOrder()) {
        NSString *identifier = [@"yt." stringByAppendingString:name];
        if (YTKACEStoredBool(YTKACENativeItem(identifier)[@"key"])) continue;
        [self.zones[YTKACEOverlayZoneTop] addObject:identifier];
    }
    self.zones[YTKACECenterZone] = [NSMutableArray array];
    for (NSString *identifier in @[@"yt.previous", @"yt.play", @"yt.next"]) {
        if (!YTKACEStoredBool(YTKACENativeItem(identifier)[@"key"])) [self.zones[YTKACECenterZone] addObject:identifier];
    }
    // The fullscreen bar: YouTube's pill, then ours, then More videos.
    NSMutableArray *bar = [NSMutableArray array];
    for (NSString *name in YTKACEPillOrder()) {
        NSString *identifier = [@"yt.pill." stringByAppendingString:name];
        if (!YTKACEStoredBool(YTKACENativeItem(identifier)[@"key"])) [bar addObject:identifier];
    }
    [bar addObjectsFromArray:self.zones[YTKACEOverlayZoneFullscreen] ?: @[]];
    if (!YTKACEStoredBool(YTKACEMoreVideosKey)) [bar addObject:@"yt.more"];
    self.zones[YTKACEOverlayZoneFullscreen] = bar;
    for (NSDictionary *item in YTKACENativeItems()) {
        if (YTKACEStoredBool(item[@"key"])) [hidden addObject:item[@"id"]];
    }
    self.zones[YTKACEHiddenZone] = hidden;
}

// Which rows a chip may go in.
- (BOOL)kind:(YTKACEItemKind)kind allowsZone:(NSString *)zone {
    if ([zone isEqualToString:YTKACEHiddenZone]) return YES;
    switch (kind) {
        case YTKACEItemOurs:
            return ![zone isEqualToString:YTKACECenterZone];
        case YTKACEItemNativeTop:
            return [zone isEqualToString:YTKACEOverlayZoneTop];
        case YTKACEItemCenter:
            return [zone isEqualToString:YTKACECenterZone];
        case YTKACEItemPill:
        case YTKACEItemMore:
            return [zone isEqualToString:YTKACEOverlayZoneFullscreen];
    }
    return NO;
}

- (NSString *)homeZoneForKind:(YTKACEItemKind)kind {
    switch (kind) {
        case YTKACEItemNativeTop: return YTKACEOverlayZoneTop;
        case YTKACEItemCenter: return YTKACECenterZone;
        case YTKACEItemPill:
        case YTKACEItemMore: return YTKACEOverlayZoneFullscreen;
        case YTKACEItemOurs: return YTKACEOverlayZoneBelow;
    }
    return YTKACEOverlayZoneBelow;
}

// Keeps each kind in its part of a row: ours before YouTube's in the top row;
// YouTube's pill, then ours, then More videos in the fullscreen bar; the
// center controls in their fixed order.
- (NSUInteger)clampIndex:(NSUInteger)index zone:(NSString *)zone kind:(YTKACEItemKind)kind identifier:(NSString *)identifier {
    NSArray<NSString *> *ids = self.zones[zone];
    NSUInteger ours = 0, pill = 0;
    for (NSString *other in ids) {
        const YTKACEItemKind otherKind = YTKACEKindOf(other);
        if (otherKind == YTKACEItemOurs) ours++;
        else if (otherKind == YTKACEItemPill) pill++;
    }
    index = MIN(index, ids.count);
    if ([zone isEqualToString:YTKACEOverlayZoneTop]) {
        return kind == YTKACEItemOurs ? MIN(index, ours) : MAX(index, ours);
    }
    if ([zone isEqualToString:YTKACEOverlayZoneFullscreen]) {
        if (kind == YTKACEItemPill) return MIN(index, pill);
        if (kind == YTKACEItemMore) return ids.count;
        return MIN(MAX(index, pill), pill + ours);
    }
    if ([zone isEqualToString:YTKACECenterZone]) {
        NSArray *canonical = @[@"yt.previous", @"yt.play", @"yt.next"];
        const NSUInteger rank = [canonical indexOfObject:identifier];
        NSUInteger position = 0;
        for (NSString *other in ids) {
            if ([canonical indexOfObject:other] < rank) position++;
        }
        return position;
    }
    return index;
}

#pragma mark - Player mock

- (UIView *)markWithImage:(UIImage *)image {
    UIImageView *view = YTKACEChipImageView(image);
    view.tintColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    return view;
}

// Stand-ins for the parts of the player that don't move.
- (void)buildPlayerMock {
    self.nativeMarks = [NSMutableDictionary dictionary];
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
    for (UIView *mark in self.nativeMarks.allValues) [self.playerView addSubview:mark];
}

- (CGFloat)rowCenterY:(NSString *)zone {
    const CGFloat height = CGRectGetHeight(self.playerView.bounds);
    if ([zone isEqualToString:YTKACEOverlayZoneTop]) return 24.0;
    if ([zone isEqualToString:YTKACEOverlayZoneBelow]) return 62.0;
    if ([zone isEqualToString:YTKACECenterZone]) return round(height * 0.5) + 6.0;
    return height - 34.0;
}

// Right edge of each row, in player coordinates.
- (CGFloat)rowRight:(NSString *)zone {
    if ([zone isEqualToString:YTKACEOverlayZoneBottom]) return CGRectGetMinX(self.nativeMarks[@"fullscreen"].frame) - 6.0;
    return CGRectGetWidth(self.playerView.bounds) - 10.0;
}

- (void)layoutPlayerMock {
    const CGFloat width = CGRectGetWidth(self.playerView.bounds);
    const CGFloat height = CGRectGetHeight(self.playerView.bounds);
    const CGFloat topY = [self rowCenterY:YTKACEOverlayZoneTop];
    const CGFloat bottomY = [self rowCenterY:YTKACEOverlayZoneBottom];
    self.nativeMarks[@"title"].frame = CGRectMake(14.0, topY - 5.0, MIN(90.0, width * 0.2), 10.0);
    self.nativeMarks[@"fullscreen"].frame = CGRectMake(width - 12.0 - 23.0, bottomY - 10.0, 20.0, 20.0);
    self.nativeMarks[@"time"].frame = CGRectMake(14.0, bottomY - 8.0, 90.0, 16.0);
    self.nativeMarks[@"track"].frame = CGRectMake(14.0, height - 11.0, width - 28.0, 3.0);
    self.nativeMarks[@"played"].frame = CGRectMake(14.0, height - 11.0, (width - 28.0) * 0.4, 3.0);
}

#pragma mark - Layout

- (void)setHint:(NSString *)title {
    self.hintLabel.text = title ?: YTKACELocalized(@"Hold any button and drag it where you want it. Drag it off the player to hide it.");
    self.hintLabel.font = title != nil ? [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
                                       : [UIFont systemFontOfSize:14.0];
    self.hintLabel.textColor = title != nil ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (CGFloat)playerWidthForWidth:(CGFloat)width {
    return MIN(560.0, width - 32.0);
}

- (CGFloat)playerHeightForWidth:(CGFloat)inner {
    return MAX(220.0, round(inner * 9.0 / 16.0));
}

// Room for every chip in the bar plus a drag gap, so it doesn't change
// height while dragging.
- (CGFloat)fullscreenHeightForWidth:(CGFloat)width {
    NSArray *ids = self.zones[YTKACEOverlayZoneFullscreen] ?: @[];
    NSArray *frames = [self flowFrames:ids gap:ids.count gapWidth:YTKACEChipHeight * 2.0 width:width top:10.0];
    CGFloat bottom = 10.0 + YTKACEChipHeight;
    for (NSValue *frame in frames) bottom = MAX(bottom, CGRectGetMaxY(frame.CGRectValue));
    return bottom + 10.0;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    const CGFloat inner = [self playerWidthForWidth:width];
    return 44.0 + [self playerHeightForWidth:inner] + 12.0 + 18.0 + 6.0 + [self fullscreenHeightForWidth:inner] +
        16.0 + [self trayHeightForWidth:inner] + 12.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = [self playerWidthForWidth:CGRectGetWidth(self.bounds)];
    const CGFloat left = round((CGRectGetWidth(self.bounds) - width) * 0.5);
    self.hintLabel.frame = CGRectMake(left, 2.0, width, 40.0);
    self.playerView.frame = CGRectMake(left, 44.0, width, [self playerHeightForWidth:width]);
    [self layoutPlayerMock];
    self.fullscreenLabel.frame = CGRectMake(left + 4.0, CGRectGetMaxY(self.playerView.frame) + 12.0, width - 8.0, 18.0);
    self.fullscreenView.frame = CGRectMake(left, CGRectGetMaxY(self.fullscreenLabel.frame) + 6.0, width,
                                           [self fullscreenHeightForWidth:width]);
    const CGFloat trayHeight = [self trayHeightForWidth:width];
    self.trayView.frame = CGRectMake(left, CGRectGetMaxY(self.fullscreenView.frame) + 16.0, width, trayHeight);
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
    NSArray *frames = [self flowFrames:self.zones[YTKACEHiddenZone] ?: @[] gap:NSNotFound gapWidth:0.0
                                 width:width top:34.0];
    CGFloat bottom = 34.0 + YTKACEChipHeight;
    for (NSValue *frame in frames) bottom = MAX(bottom, CGRectGetMaxY(frame.CGRectValue));
    return bottom + 14.0;
}

- (CGFloat)widthOf:(NSString *)identifier {
    return [self.chips[identifier] chipWidth];
}

// Right-aligned (or centered) row frames in view coordinates, with an optional gap.
- (NSArray<NSValue *> *)rowFrames:(NSArray<NSString *> *)ids zone:(NSString *)zone
                              gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSString *identifier in ids) [widths addObject:@([self widthOf:identifier])];
    CGFloat total = 0.0;
    for (NSNumber *value in widths) total += value.doubleValue + YTKACEChipSpacing;
    if (gap != NSNotFound) total += gapWidth + YTKACEChipSpacing;
    total = MAX(0.0, total - YTKACEChipSpacing);
    CGFloat x = [zone isEqualToString:YTKACECenterZone]
        ? round((CGRectGetWidth(self.playerView.bounds) - total) * 0.5)
        : MAX(10.0, [self rowRight:zone] - total);
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

// Left-aligned, wrapping frames in the coordinates of a panel.
- (NSArray<NSValue *> *)flowFrames:(NSArray<NSString *> *)ids gap:(NSUInteger)gap
                          gapWidth:(CGFloat)gapWidth width:(CGFloat)width top:(CGFloat)top {
    NSMutableArray *frames = [NSMutableArray array];
    const CGFloat start = 14.0;
    CGFloat x = start, y = top;
    const CGFloat limit = width - 14.0;
    for (NSUInteger index = 0; index <= ids.count; index++) {
        if (index == gap) {
            if (x + gapWidth > limit) { x = start; y += YTKACEChipHeight + 8.0; }
            x += gapWidth + 8.0;
        }
        if (index == ids.count) break;
        const CGFloat chipWidth = [self widthOf:ids[index]];
        if (x + chipWidth > limit) { x = start; y += YTKACEChipHeight + 8.0; }
        [frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, chipWidth, YTKACEChipHeight)]];
        x += chipWidth + 8.0;
    }
    return frames;
}

- (NSArray<NSValue *> *)framesForZone:(NSString *)zone gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    NSArray *ids = self.zones[zone] ?: @[];
    UIView *panel = nil;
    CGFloat top = 0.0;
    if ([zone isEqualToString:YTKACEHiddenZone]) {
        panel = self.trayView;
        top = 34.0;
    } else if ([zone isEqualToString:YTKACEOverlayZoneFullscreen]) {
        panel = self.fullscreenView;
        top = 10.0;
    } else {
        return [self rowFrames:ids zone:zone gap:gap gapWidth:gapWidth];
    }
    NSMutableArray *frames = [NSMutableArray array];
    for (NSValue *frame in [self flowFrames:ids gap:gap gapWidth:gapWidth width:CGRectGetWidth(panel.bounds) top:top]) {
        [frames addObject:[NSValue valueWithCGRect:[panel convertRect:frame.CGRectValue toView:self]]];
    }
    return frames;
}

- (void)layoutChipsAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        for (NSString *zone in [self allZones]) {
            const BOOL target = self.dragging != nil && [zone isEqualToString:self.targetZone];
            NSArray<NSValue *> *frames = [self framesForZone:zone gap:target ? self.targetIndex : NSNotFound
                                                    gapWidth:target ? [self.dragging chipWidth] : 0.0];
            NSArray<NSString *> *ids = self.zones[zone];
            for (NSUInteger index = 0; index < ids.count && index < frames.count; index++) {
                YTKACELayoutChip *chip = self.chips[ids[index]];
                chip.inTray = [zone isEqualToString:YTKACEHiddenZone];
                chip.bounds = (CGRect){CGPointZero, frames[index].CGRectValue.size};
                chip.center = CGPointMake(CGRectGetMidX(frames[index].CGRectValue),
                                          CGRectGetMidY(frames[index].CGRectValue));
            }
        }
        [self layoutPillBackground];
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

// One pill behind YouTube's bar buttons and ours, like the real bar.
- (void)layoutPillBackground {
    CGRect pill = CGRectNull;
    for (NSString *identifier in self.zones[YTKACEOverlayZoneFullscreen]) {
        if ([identifier isEqualToString:@"yt.more"]) continue;
        YTKACELayoutChip *chip = self.chips[identifier];
        if (chip == self.dragging) continue;
        const CGSize size = chip.bounds.size;
        CGRect frame = [self convertRect:CGRectMake(chip.center.x - size.width * 0.5, chip.center.y - size.height * 0.5,
                                                    size.width, size.height)
                                  toView:self.fullscreenView];
        // only the first line
        if (!CGRectIsNull(pill) && CGRectGetMinY(frame) > CGRectGetMinY(pill) + 1.0) continue;
        pill = CGRectIsNull(pill) ? frame : CGRectUnion(pill, frame);
    }
    self.pillBackground.hidden = CGRectIsNull(pill);
    if (CGRectIsNull(pill)) return;
    self.pillBackground.frame = CGRectInset(pill, -5.0, -4.0);
    self.pillBackground.layer.cornerRadius = CGRectGetHeight(self.pillBackground.frame) * 0.5;
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
    if (CGRectContainsPoint(CGRectInset(self.fullscreenView.frame, -4.0, -8.0), point)) {
        return YTKACEOverlayZoneFullscreen;
    }
    if (point.y > CGRectGetMaxY(self.playerView.frame) + 6.0) return YTKACEHiddenZone;
    if (point.x < CGRectGetMinX(self.playerView.frame) - 20.0 || point.x > CGRectGetMaxX(self.playerView.frame) + 20.0 ||
        point.y < CGRectGetMinY(self.playerView.frame) - 30.0) {
        return YTKACEHiddenZone;
    }
    CGPoint local = [self convertPoint:point toView:self.playerView];
    NSString *best = YTKACEOverlayZoneBelow;
    CGFloat distance = CGFLOAT_MAX;
    for (NSString *zone in [self playerZones]) {
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
    const BOOL flow = [zone isEqualToString:YTKACEHiddenZone] || [zone isEqualToString:YTKACEOverlayZoneFullscreen];
    NSUInteger index = 0;
    for (NSValue *value in frames) {
        CGRect frame = value.CGRectValue;
        const BOOL sameLine = point.y < CGRectGetMaxY(frame) + 4.0;
        const BOOL before = flow
            ? (point.y > CGRectGetMaxY(frame) + 4.0 || (sameLine && point.x > CGRectGetMidX(frame)))
            : point.x > CGRectGetMidX(frame);
        if (before) index++;
    }
    return index;
}

- (void)updateZoneHighlight {
    const BOOL panel = [self.targetZone isEqualToString:YTKACEHiddenZone] ||
                       [self.targetZone isEqualToString:YTKACEOverlayZoneFullscreen];
    self.trayView.layer.borderColor = (self.dragging != nil && [self.targetZone isEqualToString:YTKACEHiddenZone]
        ? UIColor.systemBlueColor : [self trayBorderColor]).CGColor;
    self.fullscreenView.layer.borderColor = (self.dragging != nil && [self.targetZone isEqualToString:YTKACEOverlayZoneFullscreen]
        ? UIColor.systemBlueColor : [UIColor colorWithWhite:1.0 alpha:0.14]).CGColor;
    if (self.dragging == nil || panel) {
        self.zoneHighlight.alpha = 0.0;
        return;
    }
    const CGFloat centerY = [self rowCenterY:self.targetZone];
    CGRect frame = CGRectMake(6.0, centerY - YTKACEChipHeight * 0.5 - 4.0,
                              CGRectGetWidth(self.playerView.bounds) - 12.0, YTKACEChipHeight + 8.0);
    if ([self.targetZone isEqualToString:YTKACEOverlayZoneBottom]) {
        frame.size.width = [self rowRight:self.targetZone] - 2.0;
    }
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
                [self layoutPillBackground];
            } completion:nil];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            chip.center = CGPointMake(point.x - self.dragOffset.x, point.y - self.dragOffset.y);
            NSString *zone = [self zoneAtPoint:point];
            // YouTube's buttons stay in their own row; anywhere else on the
            // player puts them back there.
            if (![self kind:chip.kind allowsZone:zone]) zone = [self homeZoneForKind:chip.kind];
            NSUInteger index = [self indexInZone:zone atPoint:point];
            index = [self clampIndex:index zone:zone kind:chip.kind identifier:chip.identifier];
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
            NSString *dropped = self.targetZone ?: [self homeZoneForKind:chip.kind];
            if (self.zones[dropped] == nil) self.zones[dropped] = [NSMutableArray array];
            NSMutableArray *ids = self.zones[dropped];
            [ids insertObject:chip.identifier atIndex:MIN(self.targetIndex, ids.count)];
            // Previous and next are one setting; they go together.
            NSString *partner = [chip.identifier isEqualToString:@"yt.previous"] ? @"yt.next"
                : ([chip.identifier isEqualToString:@"yt.next"] ? @"yt.previous" : nil);
            if (partner != nil && ![ids containsObject:partner]) {
                for (NSString *zone in self.zones) [self.zones[zone] removeObject:partner];
                if ([dropped isEqualToString:YTKACECenterZone]) {
                    [ids insertObject:partner atIndex:[self clampIndex:0 zone:dropped kind:YTKACEItemCenter
                                                            identifier:partner]];
                } else {
                    [ids insertObject:partner atIndex:MIN([ids indexOfObject:chip.identifier] + 1, ids.count)];
                }
            }
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
            if (self.heightHandler != nil) self.heightHandler();
            break;
        }
        default:
            break;
    }
}

#pragma mark - Saving

// The new order of the shown ones, with hidden ones kept where they were.
static NSArray<NSString *> *YTKACEMergeOrder(NSArray<NSString *> *old, NSArray<NSString *> *shown) {
    NSMutableArray *result = [old mutableCopy];
    NSUInteger cursor = 0;
    for (NSUInteger index = 0; index < result.count && cursor < shown.count; index++) {
        if ([shown containsObject:result[index]]) result[index] = shown[cursor++];
    }
    return result;
}

- (void)save:(NSString *)identifier zone:(NSString *)zone {
    self.saving = YES;
    // YTKACE's rows.
    NSMutableDictionary *layout = [NSMutableDictionary dictionary];
    for (NSString *row in YTKACEOverlayZones()) {
        NSMutableArray *ours = [NSMutableArray array];
        for (NSString *other in self.zones[row]) {
            if (YTKACEKindOf(other) == YTKACEItemOurs) [ours addObject:other];
        }
        layout[row] = ours;
    }
    YTKACESetOverlayLayout(layout);
    if (YTKACEKindOf(identifier) == YTKACEItemOurs) {
        YTKACESetOverlayButtonEnabled(identifier, ![zone isEqualToString:YTKACEHiddenZone]);
    }
    // YouTube's: hidden or not, and their order.
    NSArray *hidden = self.zones[YTKACEHiddenZone];
    for (NSDictionary *item in YTKACENativeItems()) {
        const BOOL hide = [hidden containsObject:item[@"id"]];
        if (YTKACEStoredBool(item[@"key"]) != hide) YTKACESetPreference(item[@"key"], hide);
    }
    NSMutableArray *top = [NSMutableArray array];
    for (NSString *other in self.zones[YTKACEOverlayZoneTop]) {
        if (YTKACEKindOf(other) == YTKACEItemNativeTop) [top addObject:[other substringFromIndex:3]];
    }
    YTKACESetNativeTopOrder(YTKACEMergeOrder(YTKACENativeTopOrder(), top));
    NSMutableArray *pill = [NSMutableArray array];
    for (NSString *other in self.zones[YTKACEOverlayZoneFullscreen]) {
        if (YTKACEKindOf(other) == YTKACEItemPill) [pill addObject:[other substringFromIndex:8]];
    }
    NSArray *order = YTKACEMergeOrder(YTKACEPillOrder(), pill);
    YTKACESetPreferenceObject(YTKACEFullscreenOrderKey,
                              [order isEqualToArray:YTKACEPillDefaultOrder()] ? nil : order);
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

// Back to the standard spots and order; what's hidden stays hidden.
- (void)resetLayout {
    self.saving = YES;
    YTKACESetOverlayLayout(nil);
    YTKACESetNativeTopOrder(nil);
    YTKACESetPreferenceObject(YTKACEFullscreenOrderKey, nil);
    self.saving = NO;
    [self loadModel];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self animateToModel];
    if (self.changeHandler != nil) self.changeHandler();
    if (self.heightHandler != nil) self.heightHandler();
}

@end
