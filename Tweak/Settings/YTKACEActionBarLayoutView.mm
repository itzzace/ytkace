#import "YTKACEActionBarLayoutView.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"

// The same names the layout hooks use: "Like" goes with
// YTKACE.Preference.ActionBar.LikeHidden, and the saved order lists them all.
static NSString *const YTKACEActionOrderKey = @"YTKACE.Preference.ActionBar.Order";
static NSString *const YTKACEActionLayoutKey = @"YTKACE.State.ActionBarLayout";
static NSString *const YTKACEBarZone = @"bar";
static NSString *const YTKACETrayZone = @"hidden";
static const CGFloat YTKACEBarChipHeight = 32.0;

static NSArray<NSDictionary *> *YTKACEBarButtons(void) {
    return @[
        @{@"name": @"Like", @"title": @"Like", @"symbol": @"hand.thumbsup", @"chip": @"1.2K"},
        @{@"name": @"Dislike", @"title": @"Dislike", @"symbol": @"hand.thumbsdown"},
        @{@"name": @"Share", @"title": @"Share", @"symbol": @"arrowshape.turn.up.right"},
        @{@"name": @"Ask", @"title": @"Ask", @"symbol": @"sparkle"},
        @{@"name": @"Save", @"title": @"Save", @"symbol": @"bookmark"},
        @{@"name": @"Download", @"title": @"Download", @"symbol": @"arrow.down.to.line"},
        @{@"name": @"Clip", @"title": @"Clip", @"symbol": @"scissors"},
        @{@"name": @"Remix", @"title": @"Remix", @"symbol": @"wand.and.stars"},
        @{@"name": @"Thanks", @"title": @"Thanks", @"symbol": @"heart"},
        @{@"name": @"Hype", @"title": @"Hype", @"symbol": @"flame"},
        @{@"name": @"Report", @"title": @"Report", @"symbol": @"flag"},
        @{@"name": @"Overflow", @"title": @"⋯ Button", @"symbol": @"ellipsis"}
    ];
}

static NSArray<NSString *> *YTKACEBarDefaultOrder(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *button in YTKACEBarButtons()) [names addObject:button[@"name"]];
    return names;
}

static NSString *YTKACEBarHiddenKey(NSString *name) {
    return [NSString stringWithFormat:@"YTKACE.Preference.ActionBar.%@Hidden", name];
}

// The iPhone row of icons unless this device was seen with the chips.
static BOOL YTKACEBarUsesChips(void) {
    NSString *seen = [NSUserDefaults.standardUserDefaults stringForKey:YTKACEActionLayoutKey];
    if ([seen isEqualToString:@"chips"]) return YES;
    if ([seen isEqualToString:@"fixed"]) return NO;
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

#pragma mark - Chip

@interface YTKACEBarChip : UIView
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *chipText;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIView *separator;
@property(nonatomic, assign) BOOL chips;
@property(nonatomic, assign) BOOL inTray;
// A row in the ⋯ menu (the iPhone bar's buttons that don't fit).
@property(nonatomic, assign) BOOL row;
// Halves of the like/dislike pill.
@property(nonatomic, assign) BOOL joinedRight;
@property(nonatomic, assign) BOOL joinedLeft;
- (CGFloat)chipWidth;
- (void)applyStyle;
@end

@implementation YTKACEBarChip

- (instancetype)initWithButton:(NSDictionary *)button {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    self.name = button[@"name"];
    self.title = YTKACELocalized(button[@"title"]);
    self.chipText = button[@"chip"];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = self.title;
    self.layer.cornerRadius = YTKACEBarChipHeight * 0.5;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    UIImage *image = [[UIImage systemImageNamed:button[@"symbol"]]
        imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                                                           weight:UIImageSymbolWeightMedium]];
    self.icon = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    self.icon.contentMode = UIViewContentModeCenter;
    [self addSubview:self.icon];
    self.label = [UILabel new];
    self.label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    [self addSubview:self.label];
    self.separator = [UIView new];
    [self addSubview:self.separator];
    [self applyStyle];
    return self;
}

// In the tray every chip has its name. On the bar the iPhone row is just
// icons; the chips have YouTube's text, the like/dislike pill a count.
- (NSString *)labelText {
    if (self.inTray || self.row) return self.title;
    if (!self.chips) return nil;
    if ([self.name isEqualToString:@"Like"]) return self.chipText;
    if ([self.name isEqualToString:@"Dislike"] || [self.name isEqualToString:@"Overflow"]) return nil;
    return self.title;
}

- (CGFloat)chipWidth {
    NSString *text = [self labelText];
    if (text.length == 0) return [self.name isEqualToString:@"Dislike"] && self.joinedLeft ? 40.0 : YTKACEBarChipHeight;
    const CGFloat textWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName: self.label.font}].width);
    if ([self.name isEqualToString:@"Overflow"]) return 24.0 + textWidth;
    return 10.0 + 18.0 + 5.0 + textWidth + 12.0;
}

- (void)applyStyle {
    self.label.text = [self labelText];
    self.label.hidden = self.label.text.length == 0;
    UIColor *tint = self.inTray ? UIColor.labelColor : UIColor.whiteColor;
    self.icon.tintColor = tint;
    self.label.textColor = tint;
    if (self.inTray) {
        self.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    } else {
        self.backgroundColor = self.chips && !self.row ? [UIColor colorWithWhite:1.0 alpha:0.12] : UIColor.clearColor;
    }
    const BOOL pill = !self.inTray && !self.row && self.chips;
    CACornerMask corners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    if (pill && self.joinedRight) corners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    if (pill && self.joinedLeft) corners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.layer.maskedCorners = corners;
    self.separator.hidden = !(pill && self.joinedLeft);
    self.separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyStyle];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGRect bounds = self.bounds;
    const CGFloat height = CGRectGetHeight(bounds);
    // "⋯ Button" already starts with the glyph.
    const BOOL glyphInTitle = [self.name isEqualToString:@"Overflow"] && !self.label.hidden;
    self.icon.hidden = glyphInTitle;
    if (glyphInTitle) {
        self.label.frame = CGRectMake(12.0, 0.0, CGRectGetWidth(bounds) - 24.0, height);
    } else if (self.label.hidden) {
        self.icon.frame = bounds;
    } else {
        self.icon.frame = CGRectMake(10.0, 0.0, 18.0, height);
        self.label.frame = CGRectMake(33.0, 0.0, CGRectGetWidth(bounds) - 33.0 - 8.0, height);
    }
    self.separator.frame = CGRectMake(0.0, 7.0, 1.0, height - 14.0);
}

@end

#pragma mark - Editor

@interface YTKACEActionBarLayoutView ()
@property(nonatomic, assign) BOOL chips;
@property(nonatomic, assign) BOOL saving;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIView *pageView;
@property(nonatomic, strong) NSMutableArray<UIView *> *marks;
@property(nonatomic, strong) UIView *avatar;
@property(nonatomic, strong) UILabel *subscribe;
@property(nonatomic, strong) UIView *channelName;
@property(nonatomic, strong) UIView *titleBar;
@property(nonatomic, strong) UIView *metaBar;
@property(nonatomic, strong) UIView *menuBox;
@property(nonatomic, strong) UIView *trayView;
@property(nonatomic, strong) UILabel *trayLabel;
@property(nonatomic, strong) UILabel *trayEmptyLabel;
@property(nonatomic, strong) UIButton *resetButton;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEBarChip *> *chipViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *zones;
@property(nonatomic, strong) YTKACEBarChip *dragging;
@property(nonatomic, assign) CGPoint dragOffset;
@property(nonatomic, copy) NSString *targetZone;
@property(nonatomic, assign) NSUInteger targetIndex;
@property(nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@end

@implementation YTKACEActionBarLayoutView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.chips = YTKACEBarUsesChips();
    self.selectionFeedback = [UISelectionFeedbackGenerator new];

    self.hintLabel = [UILabel new];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:self.hintLabel];

    self.pageView = [UIView new];
    self.pageView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    self.pageView.layer.cornerRadius = 14.0;
    self.pageView.layer.cornerCurve = kCACornerCurveContinuous;
    self.pageView.layer.borderWidth = 1.0;
    self.pageView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.pageView.clipsToBounds = YES;
    [self addSubview:self.pageView];
    [self buildPageMock];

    self.trayView = [UIView new];
    self.trayView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceSurfaceColor(traits);
    }];
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
    [self.resetButton addTarget:self action:@selector(resetOrder) forControlEvents:UIControlEventTouchUpInside];
    [self.trayView addSubview:self.resetButton];

    self.chipViews = [NSMutableDictionary dictionary];
    for (NSDictionary *button in YTKACEBarButtons()) {
        YTKACEBarChip *chip = [[YTKACEBarChip alloc] initWithButton:button];
        chip.chips = self.chips;
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
        press.minimumPressDuration = 0.15;
        press.allowableMovement = CGFLOAT_MAX;
        [chip addGestureRecognizer:press];
        self.chipViews[chip.name] = chip;
        [self addSubview:chip];
    }
    [self setHint:nil];
    [self loadModel];
    // the Remove toggles on the same page hide buttons too
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
    [self loadModel];
    if ([before isEqualToDictionary:self.zones]) return;
    [self animateToModel];
    if (self.heightHandler != nil && [self heightForWidth:CGRectGetWidth(self.bounds)] != height) {
        self.heightHandler();
    }
}

#pragma mark - Model

- (void)loadModel {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    id stored = YTKACEPreferenceObject(YTKACEActionOrderKey);
    for (id name in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if ([YTKACEBarDefaultOrder() containsObject:name] && ![order containsObject:name]) [order addObject:name];
    }
    for (NSString *name in YTKACEBarDefaultOrder()) {
        if (![order containsObject:name]) [order addObject:name];
    }
    // Clip, Remix, Thanks and Hype only show on some videos: offer them once
    // YouTube has sent one (or if they were hidden before).
    NSArray *seen = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.State.ActionBarSeen"];
    if (![seen isKindOfClass:NSArray.class]) seen = @[];
    NSArray *occasional = @[@"Clip", @"Remix", @"Thanks", @"Hype"];
    NSMutableArray *bar = [NSMutableArray array];
    NSMutableArray *hidden = [NSMutableArray array];
    for (NSString *name in [order copy]) {
        if ([occasional containsObject:name] && ![seen containsObject:name] &&
            !YTKACEFeatureEnabled(YTKACEBarHiddenKey(name))) {
            [order removeObject:name];
        }
    }
    for (NSString *name in order) {
        [YTKACEFeatureEnabled(YTKACEBarHiddenKey(name)) ? hidden : bar addObject:name];
    }
    // The iPhone bar always ends with ⋯.
    if (!self.chips && [bar containsObject:@"Overflow"]) {
        [bar removeObject:@"Overflow"];
        [bar addObject:@"Overflow"];
    }
    self.zones = [@{YTKACEBarZone: bar, YTKACETrayZone: hidden} mutableCopy];
    [self keepPillTogether:bar];
}

// The chips put like and dislike in one pill, where the first of them is.
- (void)keepPillTogether:(NSMutableArray<NSString *> *)bar {
    if (!self.chips) return;
    NSUInteger like = [bar indexOfObject:@"Like"], dislike = [bar indexOfObject:@"Dislike"];
    if (like == NSNotFound || dislike == NSNotFound || dislike == like + 1) return;
    const NSUInteger first = MIN(like, dislike);
    [bar removeObject:@"Like"];
    [bar removeObject:@"Dislike"];
    [bar insertObject:@"Dislike" atIndex:MIN(first, bar.count)];
    [bar insertObject:@"Like" atIndex:MIN(first, bar.count)];
}

#pragma mark - Page mock

- (UIView *)markWithAlpha:(CGFloat)alpha radius:(CGFloat)radius {
    UIView *mark = [UIView new];
    mark.backgroundColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    mark.layer.cornerRadius = radius;
    mark.userInteractionEnabled = NO;
    [self.pageView addSubview:mark];
    return mark;
}

// Stand-ins for the title, the channel and Subscribe around the bar.
- (void)buildPageMock {
    self.titleBar = [self markWithAlpha:0.2 radius:5.0];
    self.metaBar = [self markWithAlpha:0.1 radius:4.0];
    self.avatar = [self markWithAlpha:0.22 radius:14.0];
    self.channelName = [self markWithAlpha:0.14 radius:4.0];
    self.subscribe = [UILabel new];
    self.subscribe.text = YTKACELocalized(@"Subscribe");
    self.subscribe.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.subscribe.textAlignment = NSTextAlignmentCenter;
    self.subscribe.textColor = UIColor.blackColor;
    self.subscribe.backgroundColor = UIColor.whiteColor;
    self.subscribe.layer.cornerRadius = 14.0;
    self.subscribe.layer.masksToBounds = YES;
    [self.pageView addSubview:self.subscribe];
    // YouTube's ⋯ sheet, holding what doesn't fit in the iPhone bar.
    self.menuBox = [UIView new];
    self.menuBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    self.menuBox.layer.cornerRadius = 12.0;
    self.menuBox.layer.cornerCurve = kCACornerCurveContinuous;
    self.menuBox.userInteractionEnabled = NO;
    [self.pageView addSubview:self.menuBox];
}

- (CGFloat)subscribeWidth {
    return ceil([self.subscribe.text sizeWithAttributes:@{NSFontAttributeName: self.subscribe.font}].width) + 28.0;
}

// The channel row's middle.
- (CGFloat)channelY {
    return 64.0;
}

// Where the bar's buttons start: beside Subscribe on the iPhone row, or on
// their own line under the channel with the chips.
- (CGFloat)barTop {
    return self.chips ? [self channelY] + 14.0 + 14.0 : [self channelY] - YTKACEBarChipHeight * 0.5;
}

- (CGFloat)firstLineStart {
    return self.chips ? 14.0 : 14.0 + 28.0 + 8.0 + [self subscribeWidth] + 10.0;
}

- (void)layoutPageMock {
    const CGFloat width = CGRectGetWidth(self.pageView.bounds);
    const CGFloat y = [self channelY];
    self.titleBar.frame = CGRectMake(14.0, 16.0, round(width * 0.62), 10.0);
    self.metaBar.frame = CGRectMake(14.0, 33.0, round(width * 0.4), 8.0);
    self.avatar.frame = CGRectMake(14.0, y - 14.0, 28.0, 28.0);
    const CGFloat subscribeWidth = [self subscribeWidth];
    if (self.chips) {
        self.channelName.hidden = NO;
        self.channelName.frame = CGRectMake(50.0, y - 4.0, MIN(90.0, width * 0.25), 8.0);
        self.subscribe.frame = CGRectMake(width - 14.0 - subscribeWidth, y - 14.0, subscribeWidth, 28.0);
    } else {
        self.channelName.hidden = YES;
        self.subscribe.frame = CGRectMake(50.0, y - 14.0, subscribeWidth, 28.0);
    }
}

#pragma mark - Layout

- (void)setHint:(NSString *)title {
    self.hintLabel.text = title ?: YTKACELocalized(@"Hold any button and drag it where you want it. Drag it off the bar to hide it.");
    self.hintLabel.font = title != nil ? [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
                                       : [UIFont systemFontOfSize:14.0];
    self.hintLabel.textColor = title != nil ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (CGFloat)panelWidthForWidth:(CGFloat)width {
    return MIN(560.0, width - 32.0);
}

- (NSArray<NSString *> *)idsForZone:(NSString *)zone withDrag:(BOOL)withDrag {
    NSMutableArray *ids = [NSMutableArray arrayWithArray:self.zones[zone] ?: @[]];
    if (withDrag && self.dragging != nil && [self.targetZone isEqualToString:zone]) {
        [ids insertObject:self.dragging.name atIndex:MIN(self.targetIndex, ids.count)];
    }
    return ids;
}

// The bar wraps like a flow: the first line beside Subscribe (iPhone) and
// the rest under it. Like and dislike sit flush as one pill with the chips.
// How many buttons the iPhone bar shows before ⋯, like YouTube's on a phone.
static const NSUInteger YTKACEFixedBarSlots = 4;
static const CGFloat YTKACEFixedSlotWidth = 36.0;
static const CGFloat YTKACEMenuRowHeight = 36.0;

// The iPhone bar: the first four next to Subscribe, then ⋯, the rest as
// rows in the ⋯ menu under it.
- (NSArray<NSValue *> *)fixedFrames:(NSArray<NSString *> *)ids width:(CGFloat)width gap:(NSUInteger)gap {
    NSMutableArray<NSString *> *sequence = [NSMutableArray array];
    const BOOL overflow = [ids containsObject:@"Overflow"];
    NSUInteger gapPosition = NSNotFound;
    for (NSUInteger index = 0; index <= ids.count; index++) {
        if (index == gap) {
            gapPosition = sequence.count;
            [sequence addObject:@""];
        }
        if (index < ids.count && ![ids[index] isEqualToString:@"Overflow"]) [sequence addObject:ids[index]];
    }
    const NSUInteger inBar = MIN(YTKACEFixedBarSlots, sequence.count);
    const NSUInteger slots = inBar + (overflow ? 1 : 0);
    const CGFloat barX = width - 14.0 - (CGFloat)slots * YTKACEFixedSlotWidth;
    const CGFloat barY = [self channelY] - YTKACEBarChipHeight * 0.5;
    const CGFloat menuTop = [self channelY] + 14.0 + 14.0 + 8.0;
    NSMutableDictionary<NSString *, NSValue *> *byName = [NSMutableDictionary dictionary];
    for (NSUInteger position = 0; position < sequence.count; position++) {
        if (position == gapPosition) continue;
        CGRect frame;
        if (position < YTKACEFixedBarSlots) {
            frame = CGRectMake(barX + (CGFloat)position * YTKACEFixedSlotWidth + 2.0, barY, YTKACEBarChipHeight,
                               YTKACEBarChipHeight);
        } else {
            frame = CGRectMake(22.0, menuTop + (CGFloat)(position - YTKACEFixedBarSlots) * YTKACEMenuRowHeight,
                               width - 44.0, YTKACEMenuRowHeight);
        }
        byName[sequence[position]] = [NSValue valueWithCGRect:frame];
    }
    if (overflow) {
        byName[@"Overflow"] = [NSValue valueWithCGRect:CGRectMake(barX + (CGFloat)inBar * YTKACEFixedSlotWidth + 2.0, barY,
                                                                  YTKACEBarChipHeight, YTKACEBarChipHeight)];
    }
    NSMutableArray *frames = [NSMutableArray array];
    for (NSString *name in ids) [frames addObject:byName[name] ?: [NSValue valueWithCGRect:CGRectZero]];
    return frames;
}

// The ⋯ menu box around the rows, or empty.
- (CGRect)menuBoxFrameForIds:(NSArray<NSString *> *)ids width:(CGFloat)width {
    NSUInteger rows = 0;
    for (NSString *name in ids) if (![name isEqualToString:@"Overflow"]) rows++;
    rows = rows > YTKACEFixedBarSlots ? rows - YTKACEFixedBarSlots : 0;
    if (self.chips || rows == 0) return CGRectZero;
    const CGFloat top = [self channelY] + 14.0 + 14.0;
    return CGRectMake(14.0, top, width - 28.0, 16.0 + (CGFloat)rows * YTKACEMenuRowHeight);
}

- (NSArray<NSValue *> *)barFrames:(NSArray<NSString *> *)ids width:(CGFloat)width
                              gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    if (!self.chips) return [self fixedFrames:ids width:width gap:gap];
    const CGFloat spacing = self.chips ? 8.0 : 4.0;
    const CGFloat limit = width - 14.0;
    CGFloat x = [self firstLineStart], y = [self barTop];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSUInteger index = 0; index <= ids.count; index++) {
        if (index == gap) {
            if (x + gapWidth > limit && x > 14.0) { x = 14.0; y += YTKACEBarChipHeight + 8.0; }
            x += gapWidth + spacing;
        }
        if (index == ids.count) break;
        NSString *name = ids[index];
        const CGFloat chipWidth = [self.chipViews[name] chipWidth];
        if (x + chipWidth > limit && x > 14.0) { x = 14.0; y += YTKACEBarChipHeight + 8.0; }
        [frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, chipWidth, YTKACEBarChipHeight)]];
        const BOOL flush = self.chips && [name isEqualToString:@"Like"] && index + 1 < ids.count &&
            [ids[index + 1] isEqualToString:@"Dislike"] && gap != index + 1;
        x += chipWidth + (flush ? 0.0 : spacing);
    }
    return frames;
}

- (NSArray<NSValue *> *)trayFrames:(NSArray<NSString *> *)ids width:(CGFloat)width
                               gap:(NSUInteger)gap gapWidth:(CGFloat)gapWidth {
    const CGFloat start = 14.0, limit = width - 14.0;
    CGFloat x = start, y = 34.0;
    NSMutableArray *frames = [NSMutableArray array];
    for (NSUInteger index = 0; index <= ids.count; index++) {
        if (index == gap) {
            if (x + gapWidth > limit) { x = start; y += YTKACEBarChipHeight + 8.0; }
            x += gapWidth + 8.0;
        }
        if (index == ids.count) break;
        const CGFloat chipWidth = [self trayWidthOf:ids[index]];
        if (x + chipWidth > limit) { x = start; y += YTKACEBarChipHeight + 8.0; }
        [frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, chipWidth, YTKACEBarChipHeight)]];
        x += chipWidth + 8.0;
    }
    return frames;
}

// A chip's width in the tray, where it shows its name.
- (CGFloat)trayWidthOf:(NSString *)name {
    YTKACEBarChip *chip = self.chipViews[name];
    const CGFloat textWidth = ceil([chip.title sizeWithAttributes:@{NSFontAttributeName: chip.label.font}].width);
    if ([name isEqualToString:@"Overflow"]) return 24.0 + textWidth;
    return 10.0 + 18.0 + 5.0 + textWidth + 12.0;
}

- (CGFloat)bottomOf:(NSArray<NSValue *> *)frames minimum:(CGFloat)minimum {
    CGFloat bottom = minimum;
    for (NSValue *frame in frames) bottom = MAX(bottom, CGRectGetMaxY(frame.CGRectValue));
    return bottom;
}

- (CGFloat)pageHeightForWidth:(CGFloat)width {
    NSArray *ids = [self idsForZone:YTKACEBarZone withDrag:YES];
    NSArray *frames = [self barFrames:ids width:width gap:NSNotFound gapWidth:0.0];
    const CGFloat box = CGRectGetMaxY([self menuBoxFrameForIds:ids width:width]);
    return MAX(box, [self bottomOf:frames minimum:[self barTop] + YTKACEBarChipHeight]) + 16.0;
}

- (CGFloat)trayHeightForWidth:(CGFloat)width {
    NSArray *ids = [self idsForZone:YTKACETrayZone withDrag:YES];
    NSArray *frames = [self trayFrames:ids width:width gap:NSNotFound gapWidth:0.0];
    return [self bottomOf:frames minimum:34.0 + YTKACEBarChipHeight] + 14.0;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    const CGFloat inner = [self panelWidthForWidth:width];
    return 44.0 + [self pageHeightForWidth:inner] + 16.0 + [self trayHeightForWidth:inner] + 12.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = [self panelWidthForWidth:CGRectGetWidth(self.bounds)];
    const CGFloat left = round((CGRectGetWidth(self.bounds) - width) * 0.5);
    self.hintLabel.frame = CGRectMake(left, 2.0, width, 40.0);
    self.pageView.frame = CGRectMake(left, 44.0, width, [self pageHeightForWidth:width]);
    [self layoutPageMock];
    self.trayView.frame = CGRectMake(left, CGRectGetMaxY(self.pageView.frame) + 16.0, width,
                                     [self trayHeightForWidth:width]);
    self.trayLabel.frame = CGRectMake(16.0, 10.0, width - 120.0, 18.0);
    self.resetButton.frame = CGRectMake(width - 96.0, 5.0, 80.0, 28.0);
    self.trayEmptyLabel.frame = CGRectMake(16.0, 34.0, width - 32.0, YTKACEBarChipHeight);
    if (self.dragging == nil) [self layoutChipsAnimated:NO];
}

// Frames in this view's coordinates, with room left for the dragged chip
// when it's headed into the zone.
- (NSArray<NSValue *> *)framesForZone:(NSString *)zone withGap:(BOOL)withGap {
    const BOOL target = withGap && self.dragging != nil && [zone isEqualToString:self.targetZone];
    const NSUInteger gap = target ? self.targetIndex : NSNotFound;
    NSArray *ids = self.zones[zone] ?: @[];
    UIView *panel = [zone isEqualToString:YTKACEBarZone] ? self.pageView : self.trayView;
    const CGFloat width = CGRectGetWidth(panel.bounds);
    NSArray<NSValue *> *local;
    if (panel == self.pageView) {
        local = [self barFrames:ids width:width gap:gap gapWidth:target ? [self.dragging chipWidth] : 0.0];
    } else {
        local = [self trayFrames:ids width:width gap:gap gapWidth:target ? [self trayWidthOf:self.dragging.name] : 0.0];
    }
    NSMutableArray *frames = [NSMutableArray array];
    for (NSValue *frame in local) {
        [frames addObject:[NSValue valueWithCGRect:[panel convertRect:frame.CGRectValue toView:self]]];
    }
    return frames;
}

- (void)updatePillHalves {
    NSArray *bar = self.zones[YTKACEBarZone];
    const NSUInteger like = [bar indexOfObject:@"Like"];
    const BOOL joined = self.chips && like != NSNotFound && like + 1 < bar.count &&
        [bar[like + 1] isEqualToString:@"Dislike"] &&
        !(self.dragging != nil && [self.targetZone isEqualToString:YTKACEBarZone] && self.targetIndex == like + 1);
    YTKACEBarChip *likeChip = self.chipViews[@"Like"], *dislikeChip = self.chipViews[@"Dislike"];
    const BOOL likeJoined = joined && likeChip != self.dragging && dislikeChip != self.dragging;
    if (likeChip.joinedRight != likeJoined || dislikeChip.joinedLeft != likeJoined) {
        likeChip.joinedRight = likeJoined;
        dislikeChip.joinedLeft = likeJoined;
        [likeChip applyStyle];
        [dislikeChip applyStyle];
    }
}

- (void)layoutChipsAnimated:(BOOL)animated {
    [self updatePillHalves];
    // Buttons this device hasn't had (Clip, Thanks, ...) aren't in any zone.
    for (YTKACEBarChip *chip in self.chipViews.allValues) {
        BOOL listed = chip == self.dragging;
        for (NSString *zone in self.zones) listed = listed || [self.zones[zone] containsObject:chip.name];
        chip.hidden = !listed;
    }
    void (^apply)(void) = ^{
        for (NSString *zone in @[YTKACEBarZone, YTKACETrayZone]) {
            NSArray<NSValue *> *frames = [self framesForZone:zone withGap:YES];
            NSArray<NSString *> *ids = self.zones[zone];
            for (NSUInteger index = 0; index < ids.count && index < frames.count; index++) {
                YTKACEBarChip *chip = self.chipViews[ids[index]];
                if (chip == self.dragging) continue;
                const BOOL tray = [zone isEqualToString:YTKACETrayZone];
                const BOOL row = !self.chips && !tray && frames[index].CGRectValue.size.width > 60.0;
                if (chip.inTray != tray || chip.row != row) {
                    chip.inTray = tray;
                    chip.row = row;
                    [chip applyStyle];
                }
                chip.bounds = (CGRect){CGPointZero, frames[index].CGRectValue.size};
                chip.center = CGPointMake(CGRectGetMidX(frames[index].CGRectValue),
                                          CGRectGetMidY(frames[index].CGRectValue));
                [chip layoutIfNeeded];
            }
        }
        NSArray *barIds = [self idsForZone:YTKACEBarZone withDrag:YES];
        const CGRect box = [self menuBoxFrameForIds:barIds width:CGRectGetWidth(self.pageView.bounds)];
        self.menuBox.alpha = CGRectIsEmpty(box) ? 0.0 : 1.0;
        if (!CGRectIsEmpty(box)) self.menuBox.frame = box;
        self.trayEmptyLabel.alpha = [self.zones[YTKACETrayZone] count] == 0 &&
            ![self.targetZone isEqualToString:YTKACETrayZone] ? 1.0 : 0.0;
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

- (UIScrollView *)enclosingScrollView {
    for (UIView *view = self.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:UIScrollView.class]) return (UIScrollView *)view;
    }
    return nil;
}

- (NSString *)zoneAtPoint:(CGPoint)point {
    return CGRectContainsPoint(CGRectInset(self.pageView.frame, -20.0, -12.0), point) ? YTKACEBarZone : YTKACETrayZone;
}

- (NSUInteger)indexInZone:(NSString *)zone atPoint:(CGPoint)point {
    NSUInteger index = 0;
    for (NSValue *value in [self framesForZone:zone withGap:NO]) {
        const CGRect frame = value.CGRectValue;
        const BOOL sameLine = point.y < CGRectGetMaxY(frame) + 4.0;
        if (point.y > CGRectGetMaxY(frame) + 4.0 || (sameLine && point.y > CGRectGetMinY(frame) - 4.0 &&
                                                       point.x > CGRectGetMidX(frame))) {
            index++;
        }
    }
    return index;
}

// With the chips nothing goes between like and dislike.
- (NSUInteger)clampIndex:(NSUInteger)index zone:(NSString *)zone {
    NSArray *ids = self.zones[zone];
    index = MIN(index, ids.count);
    if (!self.chips && [zone isEqualToString:YTKACEBarZone]) {
        if ([self.dragging.name isEqualToString:@"Overflow"]) return ids.count;
        const NSUInteger overflow = [ids indexOfObject:@"Overflow"];
        return overflow == NSNotFound ? index : MIN(index, overflow);
    }
    if (!self.chips || ![zone isEqualToString:YTKACEBarZone]) return index;
    const NSUInteger like = [ids indexOfObject:@"Like"];
    if (like != NSNotFound && like + 1 < ids.count && [ids[like + 1] isEqualToString:@"Dislike"] &&
        index == like + 1) {
        return [self.dragging.name isEqualToString:@"Dislike"] ? index : like + 2;
    }
    return index;
}

- (void)updateZoneBorders {
    const BOOL tray = self.dragging != nil && [self.targetZone isEqualToString:YTKACETrayZone];
    const BOOL bar = self.dragging != nil && [self.targetZone isEqualToString:YTKACEBarZone];
    self.trayView.layer.borderColor = (tray ? UIColor.systemBlueColor : [self trayBorderColor]).CGColor;
    self.pageView.layer.borderColor = (bar ? UIColor.systemBlueColor : [UIColor colorWithWhite:1.0 alpha:0.14]).CGColor;
}

- (void)handleDrag:(UILongPressGestureRecognizer *)recognizer {
    YTKACEBarChip *chip = (YTKACEBarChip *)recognizer.view;
    const CGPoint point = [recognizer locationInView:self];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragging = chip;
            for (NSString *zone in self.zones) {
                const NSUInteger index = [self.zones[zone] indexOfObject:chip.name];
                if (index == NSNotFound) continue;
                [self.zones[zone] removeObjectAtIndex:index];
                self.targetZone = zone;
                self.targetIndex = index;
            }
            chip.joinedLeft = NO;
            chip.joinedRight = NO;
            chip.row = NO;
            [chip applyStyle];
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
                [self updateZoneBorders];
            } completion:nil];
            [self layoutChipsAnimated:YES];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            chip.center = CGPointMake(point.x - self.dragOffset.x, point.y - self.dragOffset.y);
            NSString *zone = [self zoneAtPoint:point];
            const NSUInteger index = [self clampIndex:[self indexInZone:zone atPoint:point] zone:zone];
            if (![zone isEqualToString:self.targetZone] || index != self.targetIndex) {
                const BOOL zoneChanged = ![zone isEqualToString:self.targetZone];
                self.targetZone = zone;
                self.targetIndex = index;
                if (zoneChanged) {
                    chip.inTray = [zone isEqualToString:YTKACETrayZone];
                    [chip applyStyle];
                    const CGSize size = CGSizeMake(chip.inTray ? [self trayWidthOf:chip.name] : [chip chipWidth],
                                                   YTKACEBarChipHeight);
                    [UIView animateWithDuration:0.2 animations:^{
                        chip.bounds = (CGRect){CGPointZero, size};
                        [chip layoutIfNeeded];
                    }];
                }
                [self.selectionFeedback selectionChanged];
                [self.selectionFeedback prepare];
                [UIView animateWithDuration:0.2 animations:^{ [self updateZoneBorders]; }];
                [self layoutChipsAnimated:YES];
                if (self.heightHandler != nil) self.heightHandler();
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            NSString *dropped = self.targetZone ?: YTKACEBarZone;
            NSMutableArray *ids = self.zones[dropped];
            [ids insertObject:chip.name atIndex:MIN(self.targetIndex, ids.count)];
            // Moving one half of the pill brings the other along.
            if ([dropped isEqualToString:YTKACEBarZone] && self.chips &&
                ([chip.name isEqualToString:@"Like"] || [chip.name isEqualToString:@"Dislike"])) {
                NSString *partner = [chip.name isEqualToString:@"Like"] ? @"Dislike" : @"Like";
                const NSUInteger at = [ids indexOfObject:partner];
                if (at != NSNotFound) {
                    [ids removeObjectAtIndex:at];
                    NSUInteger mine = [ids indexOfObject:chip.name];
                    [ids insertObject:partner atIndex:[partner isEqualToString:@"Dislike"] ? mine + 1 : mine];
                }
            }
            self.dragging = nil;
            self.targetZone = nil;
            [self enclosingScrollView].scrollEnabled = YES;
            [self setHint:nil];
            [self save];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            [self setNeedsLayout];
            [UIView animateWithDuration:0.42 delay:0.0 usingSpringWithDamping:0.72 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                chip.transform = CGAffineTransformIdentity;
                chip.layer.shadowOpacity = 0.0;
                [self updateZoneBorders];
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

- (void)save {
    self.saving = YES;
    NSMutableArray *order = [NSMutableArray arrayWithArray:self.zones[YTKACEBarZone]];
    [order addObjectsFromArray:self.zones[YTKACETrayZone]];
    NSArray *hidden = self.zones[YTKACETrayZone];
    for (NSString *name in YTKACEBarDefaultOrder()) {
        const BOOL hide = [hidden containsObject:name];
        if (YTKACEFeatureEnabled(YTKACEBarHiddenKey(name)) != hide) YTKACESetPreference(YTKACEBarHiddenKey(name), hide);
    }
    // Only the shown ones' order matters; the default order saves as none.
    NSArray *shown = self.zones[YTKACEBarZone];
    NSMutableArray *defaultShown = [NSMutableArray array];
    for (NSString *name in YTKACEBarDefaultOrder()) {
        if ([shown containsObject:name]) [defaultShown addObject:name];
    }
    YTKACESetPreferenceObject(YTKACEActionOrderKey, [shown isEqualToArray:defaultShown] ? nil : order);
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

// Back to YouTube's order; what's hidden stays hidden.
- (void)resetOrder {
    self.saving = YES;
    YTKACESetPreferenceObject(YTKACEActionOrderKey, nil);
    self.saving = NO;
    [self loadModel];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self animateToModel];
    if (self.changeHandler != nil) self.changeHandler();
    if (self.heightHandler != nil) self.heightHandler();
}

@end
