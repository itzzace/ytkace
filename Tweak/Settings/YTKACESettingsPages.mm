#import "YTKACESettingsPages.h"
#import "../UI/OverlayButtonHost.h"
#import "YTKACESettingsSearch.h"
#import "../Features/Downloads/SABRDownloader.h"
#import "YTKACERootOptionsController.h"
#import "YTKACETabEditorController.h"
#import "../Runtime/Preferences.h"
#import "../YTKACE.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../Features/Downloads/YTKACEBackupManager.h"
#import "../Features/Downloads/YTKACEMediaImporter.h"
#import "../Features/SponsorBlock/SponsorPreferences.h"
#import "../Features/SponsorBlock/DeArrow.h"
#import "../Features/Translation/YTKACEVOTLog.h"
#import "../Features/Translation/YTKACEVOTClient.h"
#import "../Features/Translation/YTKACEYandexAuthViewController.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

typedef UIViewController * _Nonnull (^YTKACEControllerBuilder)(void);
typedef void (^YTKACEAction)(UIViewController *controller);

static const void *YTKACEItemAssociation = &YTKACEItemAssociation;
static const void *YTKACEValueLabelAssociation = &YTKACEValueLabelAssociation;

static NSArray<NSString *> *YTKACELocalizedList(NSArray<NSString *> *titles) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        [out addObject:YTKACELocalized(title)];
    }
    return out;
}

static NSDictionary *YTKACEToggle(NSString *title,
                                   NSString *key,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"toggle",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSDictionary *YTKACEWithFooter(NSDictionary *item, NSString *footer) {
    NSMutableDictionary *copy = [item mutableCopy];
    copy[@"footer"] = YTKACELocalized(footer);
    return copy;
}

static NSDictionary *YTKACEToggleDetail(NSString *title,
                                         NSString *subtitle,
                                         NSString *key) {
    return @{
        @"type": @"toggle",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"subtitle": YTKACELocalized(subtitle ?: @""),
        @"key": key,
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *YTKACEPickerDetail(NSString *title,
                                        NSString *subtitle,
                                        NSString *key,
                                        NSArray<NSString *> *titles,
                                        NSArray *values,
                                        NSUInteger defaultIndex) {
    return @{
        @"type": @"picker",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"subtitle": YTKACELocalized(subtitle ?: @""),
        @"key": key,
        @"titles": YTKACELocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *YTKACEPicker(NSString *title,
                                   NSString *key,
                                   NSArray<NSString *> *titles,
                                   NSArray *values,
                                   NSUInteger defaultIndex,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"picker",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"titles": YTKACELocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSString *YTKACEStepperText(NSDictionary *item, double value) {
    NSString *number = [NSString stringWithFormat:@"%.0f", value];
    if ([item[@"unit"] isEqualToString:@"count"]) {
        return [NSString stringWithFormat:@"%@: %@",
                item[@"title"] ?: YTKACELocalized(@"Limit"), number];
    }
    return [NSString stringWithFormat:YTKACELocalized(@"Seconds: %@"), number];
}

static NSDictionary *YTKACEStepper(NSString *title,
                                    NSString *key,
                                    double minimum,
                                    double maximum,
                                    double step,
                                    double fallback) {
    return @{
        @"type": @"stepper",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static NSDictionary *YTKACECountStepper(NSString *title,
                                        NSString *key,
                                        double minimum,
                                        double maximum,
                                        double step,
                                        double fallback) {
    NSMutableDictionary *row =
        [YTKACEStepper(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = @"count";
    return row;
}

static NSDictionary *YTKACESegmentedStacked(NSString *title,
                                            NSString *key,
                                            NSArray<NSString *> *titles,
                                            NSArray *values,
                                            NSUInteger defaultIndex) {
    return @{
        @"type": @"segmented",
        @"stacked": @YES,
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"titles": YTKACELocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex)
    };
}

static NSDictionary *YTKACESlider(NSString *title,
                                   NSString *key,
                                   double minimum,
                                   double maximum,
                                   double step,
                                   double fallback) {
    return @{
        @"type": @"slider",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static const void *YTKACEStepTargetAssociation = &YTKACEStepTargetAssociation;

static NSDictionary *YTKACEStackedSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback,
                                         NSString *unit) {
    NSMutableDictionary *row =
        [YTKACESlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = unit ?: @"";
    row[@"stacked"] = @YES;
    return row;
}

static NSDictionary *YTKACEPercentSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback) {
    NSMutableDictionary *item =
        [YTKACESlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    item[@"unit"] = @"percent";
    item[@"stacked"] = @YES;
    return item;
}

static UIButton *YTKACEStepControl(BOOL increment,
                                   UISlider *slider,
                                   id target,
                                   SEL action) {
    UIImageSymbolConfiguration *glyph =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                        weight:UIImageSymbolWeightSemibold];
    UIButton *control = [UIButton buttonWithType:UIButtonTypeSystem];
    control.tag = increment ? 1 : -1;
    control.tintColor = YTKACEAccentColor();
    [control setImage:[UIImage systemImageNamed:increment ? @"plus" : @"minus"
                              withConfiguration:glyph]
             forState:UIControlStateNormal];
    [control.widthAnchor constraintEqualToConstant:30.0].active = YES;
    objc_setAssociatedObject(control, YTKACEStepTargetAssociation, slider,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return control;
}

static NSString *YTKACETrimmedNumber(double value) {
    NSString *text = [NSString stringWithFormat:@"%.2f", value];
    while ([text containsString:@"."] && [text hasSuffix:@"0"]) {
        text = [text substringToIndex:text.length - 1];
    }
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return text;
}

static NSString *YTKACESliderValueText(NSDictionary *item, double value) {
    NSString *unit = item[@"unit"];
    if ([unit isEqualToString:@"percent"]) {
        return [NSString stringWithFormat:@"%.0f%%", value];
    }
    if ([unit isEqualToString:@"speed"]) {
        return [YTKACETrimmedNumber(value) stringByAppendingString:@"x"];
    }
    return [NSString stringWithFormat:YTKACELocalized(@"%@ seconds"),
            [NSString stringWithFormat:@"%.0f", value]];
}

static NSDictionary *YTKACEColor(NSString *title,
                                 NSString *key,
                                 NSString *fallback) {
    return @{
        @"type": @"color",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"key": key,
        @"fallback": fallback
    };
}

static NSDictionary *YTKACEColorDetail(NSString *title, NSString *subtitle, NSString *key, NSString *fallback) {
    NSMutableDictionary *item = [YTKACEColor(title, key, fallback) mutableCopy];
    item[@"subtitle"] = YTKACELocalized(subtitle ?: @"");
    return item;
}

static NSString *YTKACEHexFromColor(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#00D400";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lround(red * 255.0), (int)lround(green * 255.0),
            (int)lround(blue * 255.0)];
}

static UIColor *YTKACEColorFromHex(NSString *hex) {
    NSString *value = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#"
                                                                withString:@""] uppercaseString];
    if (value.length != 6) return UIColor.systemGreenColor;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSDictionary *YTKACEActionDetail(NSString *title,
                                         NSString *subtitle,
                                         YTKACEAction action) {
    return @{
        @"type": @"action",
        @"title": YTKACELocalized(title),
        @"en": title,
        @"subtitle": YTKACELocalized(subtitle ?: @""),
        @"asset": @"",
        @"symbol": @"",
        @"action": [action copy]
    };
}

static UIColor *YTKACESettingsBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceBackgroundColor(traits);
    }];
}

static UIColor *YTKACESettingsCellBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceBackgroundColor(traits);
    }];
}

BOOL YTKACEPreferenceNeedsRestart(NSString *key) {
    return [@[
        YTKACEOLEDKey,
        @"YTKACE.Preference.Navigation.PremiumLogo",
        @"YTKACE.Preference.Navigation.LogoHidden",
        @"YTKACE.Preference.App.LayoutIdiom",
        @"YTKACE.Preference.App.RTLDisabled",
        @"YTKACE.Preference.Playback.LegacyQualityMenu",
        @"YTKACE.Preference.Navigation.StatusBarHidden",
        @"YTKACE.Preference.Tabs.Glass",
        @"YTKACE.Preference.Tabs.GlassMode",
        @"YTKACE.Preference.Glass.TopBar",
        @"YTKACE.Preference.Glass.Menus",
        @"YTKACE.Preference.Glass.Notices",
        @"YTKACE.Preference.Glass.Player",
        @"YTKACE.Preference.Tabs.Startup",
        @"YTKACE.Preference.Playback.CaptionsAlwaysOn",
        @"YTKACE.Preference.Playback.CaptionsMode",
        @"YTKACE.Preference.Feed.HomeTabsHidden",
        @"YTKACE.Preference.Language",
        @"YTKACE.Preference.Navigation.NotificationsHidden"
    ] containsObject:key];
}

void YTKACEShowRestartNotice(UIViewController *controller) {
    UIView *host = controller.navigationController.view ?: controller.view;
    UIView *old = [host viewWithTag:0x594B524E];
    [old removeFromSuperview];
    UIView *notice = [UIView new];
    notice.tag = 0x594B524E;
    notice.backgroundColor = [UIColor colorWithWhite:0.72 alpha:0.96];
    notice.layer.cornerRadius = 8.0;
    notice.layer.masksToBounds = YES;
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = YTKACELocalized(@"Your changes take effect once YouTube restarts.");
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:13.0];
    label.numberOfLines = 2;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [notice addSubview:label];
    if (YTKACEApplyGlassBackground(notice, NO)) notice.layer.cornerRadius = 16.0;
    [host addSubview:notice];
    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [notice.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [notice.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [notice.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [notice.heightAnchor constraintEqualToConstant:48.0],
        [label.leadingAnchor constraintEqualToAnchor:notice.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:notice.trailingAnchor constant:-14.0],
        [label.centerYAnchor constraintEqualToAnchor:notice.centerYAnchor]
    ]];
    notice.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 0.0; }
                         completion:^(__unused BOOL finished) { [notice removeFromSuperview]; }];
    });
}

static void YTKACEStorePickerValue(NSString *key, id value,
                                   __unused NSUInteger index) {
    YTKACESetPreferenceObject(key, value);
}

static UIImage *YTKACEBlankChoiceIcon(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24.0, 24.0), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

void YTKACEPresentSelectionMenu(UIViewController *presenter,
                                UIView *sourceView,
                                NSString *title,
                                NSArray<NSString *> *titles,
                                NSUInteger selectedIndex,
                                YTKACEChoiceHandler handler) {
    (void)title;
    (void)sourceView;
    if (titles.count == 0) {
        return;
    }
    selectedIndex = MIN(selectedIndex, titles.count - 1);
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeAction = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    id sheet = [actionClass respondsToSelector:makeAction] ? YTKACEMakeSheet(nil, nil) : nil;
    if (sheet != nil) {
        UIImage *check = [[UIImage systemImageNamed:@"checkmark"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImage *blank = YTKACEBlankChoiceIcon();
        [titles enumerateObjectsUsingBlock:^(NSString *choice, NSUInteger index, BOOL *stop) {
            (void)stop;
            dispatch_block_t selection = ^{
                if (handler != nil) {
                    handler(index);
                }
            };
            id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeAction, choice,
                index == selectedIndex ? check : blank, 0, selection);
            SEL addAction = NSSelectorFromString(@"addAction:");
            if ([sheet respondsToSelector:addAction]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
            }
        }];
        YTKACEShowSheet(sheet, presenter);
        return;
    }
    YTKACEShowNotice(YTKACELocalized(@"YouTube menu unavailable"));
}

void YTKACEPresentChoiceMenu(UIViewController *presenter,
                             UIView *sourceView,
                             NSString *title,
                             NSArray<NSString *> *titles,
                             NSArray *values,
                             NSString *key,
                             NSUInteger defaultIndex,
                             YTKACEChoiceHandler handler) {
    id selected = YTKACEPreferenceObject(key);
    NSUInteger selectedIndex = [values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(defaultIndex, values.count - 1);
    }
    YTKACEPresentSelectionMenu(presenter, sourceView, title, titles, selectedIndex,
        ^(NSUInteger index) {
            YTKACEStorePickerValue(key, values[index], index);
            if (([key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ||
                 [key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"]) && index < 2) {
                NSString *otherKey = [key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"]
                    ? @"YTKACE.Preference.Gestures.VolumeSide" : @"YTKACE.Preference.Gestures.BrightnessSide";
                id otherValue = YTKACEPreferenceObject(otherKey);
                NSInteger otherSide = otherValue == nil
                    ? ([otherKey isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ? 1 : 0)
                    : [otherValue integerValue];
                if (otherSide == [values[index] integerValue] || otherSide == 3) {
                    YTKACEStorePickerValue(otherKey, @([values[index] integerValue] == 0),
                                           [values[index] integerValue] == 0 ? 1 : 0);
                }
            }
            if ([key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"] &&
                [values[index] integerValue] == 3) {
                YTKACEStorePickerValue(@"YTKACE.Preference.Gestures.BrightnessSide", @2, 2);
            }
            if (handler != nil) handler(index);
        });
}

NSString *YTKACEPickerSummary(NSString *key,
                              NSArray<NSString *> *titles,
                              NSArray *values,
                              NSUInteger defaultIndex) {
    id selected = YTKACEPreferenceObject(key);
    NSUInteger index = [values indexOfObject:selected];
    if (index == NSNotFound || index >= titles.count) {
        index = MIN(defaultIndex, titles.count - 1);
    }
    return titles.count == 0 ? @"" : titles[index];
}

@interface YTKACEPickerController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex;
@end

@implementation YTKACEPickerController {
    NSString *_preferenceKey;
    NSArray<NSString *> *_titles;
    NSArray *_values;
    NSUInteger _defaultIndex;
}

- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _preferenceKey = [key copy];
        _titles = [titles copy];
        _values = [values copy];
        _defaultIndex = defaultIndex;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACEOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACESettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTKACEPickerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    id selected = YTKACEPreferenceObject(_preferenceKey);
    NSUInteger selectedIndex = [_values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(_defaultIndex, _values.count - 1);
    }
    cell.textLabel.text = _titles[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.backgroundColor = YTKACESettingsCellBackground();
    cell.accessoryType = (NSUInteger)indexPath.row == selectedIndex
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id value = _values[(NSUInteger)indexPath.row];
    YTKACEStorePickerValue(_preferenceKey, value, (NSUInteger)indexPath.row);
    [tableView reloadData];
}

@end

@interface YTKACEOptionsController : UITableViewController
    <UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles;
- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles;
@end

@implementation YTKACEOptionsController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
    NSInteger _pickerMode;
    NSString *_importCategory;
    NSString *_colorKey;
    NSIndexPath *_colorPath;
    UIView *_backupOverlay;
    UILabel *_backupOverlayLabel;
    NSURL *_pendingBackupURL;
    BOOL _backupRunning;
    BOOL _restoreRunning;
}

- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _sections = [sections copy];
        _sectionTitles = [sectionTitles copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 50.0;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0.0;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACEOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACESettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)_sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ((NSUInteger)section >= _sectionTitles.count) {
        return nil;
    }
    NSString *title = _sectionTitles[(NSUInteger)section];
    return title.length == 0 ? nil : title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    id footer = _sections[(NSUInteger)section].lastObject[@"footer"];
    return [footer isKindOfClass:NSString.class] ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    id footer = _sections[(NSUInteger)section].lastObject[@"footer"];
    return [footer isKindOfClass:NSString.class] ? UITableViewAutomaticDimension : tableView.sectionFooterHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = (NSUInteger)section < _sectionTitles.count
        ? _sectionTitles[(NSUInteger)section]
        : @"";
    return title.length == 0 ? 18.0 : 38.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    if ([type isEqualToString:@"text"]) {
        return 92.0;
    }
    if ([type isEqualToString:@"slider"]) {
        return [item[@"stacked"] boolValue] ? 78.0 : 58.0;
    }
    if ([type isEqualToString:@"segmented"] && [item[@"stacked"] boolValue]) {
        return 74.0;
    }
    return [item[@"subtitle"] length] == 0 ? 40.0 : 56.0;
}

- (void)tableView:(UITableView *)tableView
willDisplayHeaderView:(UIView *)view
        forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        header.textLabel.textColor = UIColor.secondaryLabelColor;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    UITableViewCellStyle style;
    if ([type isEqualToString:@"picker"]) {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleValue1
            : UITableViewCellStyleSubtitle;
    } else {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleDefault
            : UITableViewCellStyleSubtitle;
    }
    NSString *identifier = [NSString stringWithFormat:@"YTKACEOption-%ld", (long)style];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    }

    [[cell.contentView viewWithTag:8801] removeFromSuperview];
    [[cell.contentView viewWithTag:8802] removeFromSuperview];
    [[cell.contentView viewWithTag:4271] removeFromSuperview];

    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"subtitle"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.backgroundColor = YTKACESettingsCellBackground();
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.imageView.image = nil;

    if ([type isEqualToString:@"toggle"]) {
        UISwitch *toggle = [UISwitch new];
        toggle.transform = CGAffineTransformMakeScale(0.95, 0.95);
        toggle.onTintColor = YTKACEAccentColor();
        id stored = YTKACEPreferenceObject(item[@"key"]);
        toggle.on = [stored respondsToSelector:@selector(boolValue)] && [stored boolValue];
        objc_setAssociatedObject(toggle,
                                 YTKACEItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self
                   action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"segmented"]) {
        UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:item[@"titles"]];
        id selected = YTKACEPreferenceObject(item[@"key"]);
        NSUInteger selectedIndex = [item[@"values"] indexOfObject:selected];
        control.selectedSegmentIndex = selectedIndex == NSNotFound
            ? [item[@"default"] unsignedIntegerValue]
            : selectedIndex;
        objc_setAssociatedObject(control,
                                 YTKACEItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [control addTarget:self
                    action:@selector(segmentChanged:)
          forControlEvents:UIControlEventValueChanged];
        if ([item[@"stacked"] boolValue]) {
            UILabel *caption = [UILabel new];
            caption.tag = 8802;
            caption.text = item[@"title"];
            caption.font = [UIFont systemFontOfSize:16.0];
            caption.textColor = UIColor.labelColor;
            caption.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:caption];
            control.tag = 8801;
            control.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:control];
            UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [caption.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [caption.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [caption.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                  constant:8.0],
                [control.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [control.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [control.topAnchor constraintEqualToAnchor:caption.bottomAnchor
                                                  constant:8.0],
                [control.heightAnchor constraintEqualToConstant:30.0]
            ]];
            cell.textLabel.text = nil;
            cell.accessoryView = nil;
        } else {
            CGFloat width = MAX(128.0, [item[@"titles"] count] * 68.0);
            control.frame = CGRectMake(0.0, 0.0, width, 30.0);
            cell.accessoryView = control;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"stepper"]) {
        double stored = [YTKACEPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        cell.textLabel.text = YTKACEStepperText(item, value);
        UIStepper *stepper = [UIStepper new];
        stepper.tintColor = YTKACEAccentColor();
        stepper.minimumValue = [item[@"minimum"] doubleValue];
        stepper.maximumValue = [item[@"maximum"] doubleValue];
        stepper.stepValue = [item[@"step"] doubleValue];
        stepper.value = value;
        objc_setAssociatedObject(stepper,
                                 YTKACEItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(stepper,
                                 YTKACEValueLabelAssociation,
                                 cell,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stepper addTarget:self
                    action:@selector(stepperChanged:)
          forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stepper;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"] && [item[@"stacked"] boolValue]) {
        double stored = [YTKACEPreferenceObject(item[@"key"]) doubleValue];
        if ([item[@"unit"] isEqualToString:@"percent"] && stored > 0.0 && stored <= 1.0) {
            stored = stored * 100.0;
            YTKACESetPreferenceObject(item[@"key"], @(stored));
        }
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];

        UILabel *caption = [UILabel new];
        caption.text = item[@"title"];
        caption.font = [UIFont systemFontOfSize:16.0];
        caption.textColor = UIColor.labelColor;

        UILabel *readout = [UILabel new];
        readout.font = [UIFont monospacedDigitSystemFontOfSize:15.0
                                                        weight:UIFontWeightSemibold];
        readout.textColor = YTKACEAccentColor();
        readout.textAlignment = NSTextAlignmentRight;
        readout.text = YTKACESliderValueText(item, value);
        [readout setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

        UISlider *slider = [UISlider new];
        slider.minimumTrackTintColor = YTKACEAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        objc_setAssociatedObject(slider, YTKACEItemAssociation, item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, YTKACEValueLabelAssociation, readout,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self
                   action:@selector(sliderChanged:)
         forControlEvents:UIControlEventValueChanged];

        UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[caption, readout]];
        heading.axis = UILayoutConstraintAxisHorizontal;
        heading.spacing = 8.0;

        UIStackView *track = [[UIStackView alloc] initWithArrangedSubviews:@[
            YTKACEStepControl(NO, slider, self, @selector(sliderStepped:)),
            slider,
            YTKACEStepControl(YES, slider, self, @selector(sliderStepped:))
        ]];
        track.axis = UILayoutConstraintAxisHorizontal;
        track.alignment = UIStackViewAlignmentCenter;
        track.spacing = 10.0;

        UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[heading, track]];
        container.tag = 4271;
        container.axis = UILayoutConstraintAxisVertical;
        container.spacing = 6.0;
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:container];

        UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [container.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [container.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                constant:8.0],
            [container.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                                   constant:-8.0]
        ]];
        cell.textLabel.text = nil;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"]) {
        double stored = [YTKACEPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 46.0)];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 30.0)];
        slider.minimumTrackTintColor = YTKACEAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 28.0, 158.0, 14.0)];
        valueLabel.font = [UIFont systemFontOfSize:10.0];
        valueLabel.textColor = UIColor.tertiaryLabelColor;
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.text = YTKACESliderValueText(item, value);
        objc_setAssociatedObject(slider, YTKACEItemAssociation, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, YTKACEValueLabelAssociation, valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [accessory addSubview:slider];
        [accessory addSubview:valueLabel];
        cell.accessoryView = accessory;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"picker"]) {
        NSString *summary = YTKACEPickerSummary(
            item[@"key"],
            item[@"titles"],
            item[@"values"],
            [item[@"default"] unsignedIntegerValue]
        );
        if ([item[@"subtitle"] length] == 0) {
            cell.detailTextLabel.text = summary;
            cell.detailTextLabel.textColor = YTKACEAccentColor();
        } else {
            UILabel *value = [UILabel new];
            value.text = summary;
            value.font = [UIFont systemFontOfSize:15.0];
            value.textColor = YTKACEAccentColor();
            value.textAlignment = NSTextAlignmentRight;
            [value sizeToFit];
            cell.accessoryView = value;
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = YTKACEPreferenceObject(item[@"key"]);
        UIColor *color = YTKACEColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 28.0, 28.0)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 14.0;
        dot.layer.borderWidth = 2.0;
        dot.layer.borderColor = UIColor.secondaryLabelColor.CGColor;
        cell.accessoryView = dot;
    } else if ([type isEqualToString:@"text"]) {
        cell.textLabel.font = [UIFont systemFontOfSize:10.0];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTKACEItemAssociation);
    NSArray *values = item[@"values"];
    if ((NSUInteger)sender.selectedSegmentIndex < values.count) {
        YTKACESetPreferenceObject(item[@"key"], values[(NSUInteger)sender.selectedSegmentIndex]);
        if (YTKACEPreferenceNeedsRestart(item[@"key"])) {
            YTKACEShowRestartNotice(self);
        }
    }
}

- (void)toggleChanged:(UISwitch *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTKACEItemAssociation);
    NSString *key = item[@"key"];
    YTKACESetPreference(key, sender.isOn);
    if ([key isEqualToString:YTKACEOLEDKey]) {
        YTKACEApplyAppearance(self);
        self.tableView.backgroundColor = YTKACESettingsBackground();
        [self.tableView reloadData];
    }
    if (YTKACEPreferenceNeedsRestart(key)) {
        YTKACEShowRestartNotice(self);
    }
}

- (void)stepperChanged:(UIStepper *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTKACEItemAssociation);
    UITableViewCell *cell = objc_getAssociatedObject(sender, YTKACEValueLabelAssociation);
    YTKACESetPreferenceObject(item[@"key"], @(sender.value));
    cell.textLabel.text = YTKACEStepperText(item, sender.value);
}

- (void)sliderStepped:(UIButton *)sender {
    UISlider *slider = objc_getAssociatedObject(sender, YTKACEStepTargetAssociation);
    NSDictionary *item = objc_getAssociatedObject(slider, YTKACEItemAssociation);
    if (slider == nil || item == nil) return;
    const double step = MAX(0.01, [item[@"step"] doubleValue]);
    const double lower = [item[@"minimum"] doubleValue];
    const double upper = [item[@"maximum"] doubleValue];
    double shifted = slider.value + step * (double)sender.tag;
    shifted = MIN(upper, MAX(lower, shifted));
    slider.value = (float)shifted;
    [self sliderChanged:slider];
}

- (void)sliderChanged:(UISlider *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTKACEItemAssociation);
    UILabel *label = objc_getAssociatedObject(sender, YTKACEValueLabelAssociation);
    double step = MAX(0.01, [item[@"step"] doubleValue]);
    double value = round(round(sender.value / step) * step * 100.0) / 100.0;
    YTKACESetPreferenceObject(item[@"key"], @(value));
    label.text = YTKACESliderValueText(item, value);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    UIViewController *controller = nil;
    if ([type isEqualToString:@"controller"]) {
        YTKACEControllerBuilder builder = item[@"builder"];
        controller = builder();
    } else if ([type isEqualToString:@"picker"]) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        YTKACEPresentChoiceMenu(self, cell, item[@"title"], item[@"titles"],
            item[@"values"], item[@"key"],
            [item[@"default"] unsignedIntegerValue], ^(__unused NSUInteger index) {
                NSString *key = item[@"key"];
                if ([key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ||
                    [key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"]) {
                    [self.tableView reloadData];
                } else {
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                          withRowAnimation:UITableViewRowAnimationNone];
                }
                if (YTKACEPreferenceNeedsRestart(item[@"key"])) {
                    YTKACEShowRestartNotice(self);
                }
            });
    } else if ([type isEqualToString:@"action"]) {
        YTKACEAction action = item[@"action"];
        action(self);
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = YTKACEPreferenceObject(item[@"key"]);
        UIColorPickerViewController *picker = [UIColorPickerViewController new];
        picker.title = item[@"title"];
        picker.supportsAlpha = NO;
        picker.selectedColor = YTKACEColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        picker.delegate = self;
        _colorKey = [item[@"key"] copy];
        _colorPath = indexPath;
        [self presentViewController:picker animated:YES completion:nil];
    }
    if (controller != nil) {
        [self.navigationController pushViewController:controller animated:YES];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (_pickerMode == 3) {
        if (_pendingBackupURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
        }
        _pendingBackupURL = nil;
        _pickerMode = 0;
        return;
    }
    if (urls.count == 0) return;
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    for (NSURL *URL in urls) {
        if ([URL startAccessingSecurityScopedResource]) [scoped addObject:URL];
    }
    if (_pickerMode == 1) {
        _restoreRunning = YES;
        [self setBackupProgressVisible:YES message:YTKACELocalized(@"Restoring Backup...")];
        [YTKACEBackupManager restoreBackupFromURL:urls.firstObject
            completion:^(NSError *error) {
                for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
                self->_restoreRunning = NO;
                [self setBackupProgressVisible:NO message:nil];
                [self showResult:error == nil ? YTKACELocalized(@"Backup Restored") : YTKACELocalized(@"Restore Failed")
                          message:error.localizedDescription];
            }];
        _pickerMode = 0;
        return;
    }
    NSString *category = _importCategory ?: YTKACELocalized(@"Video");
    [YTKACEMediaImporter importURLs:urls category:category
        completion:^(NSUInteger count, NSError *error) {
            for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
            NSString *message = error.localizedDescription ?: [NSString
                stringWithFormat:YTKACELocalized(@"%lu items added to %@."),
                (unsigned long)count, category];
            [self showResult:error == nil ? YTKACELocalized(@"Import Complete") : YTKACELocalized(@"Import Failed")
                      message:message];
        }];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    (void)continuously;
    if (_colorKey.length == 0 || color == nil) return;
    YTKACESetPreferenceObject(_colorKey, YTKACEHexFromColor(color));
    if (_colorPath != nil) {
        [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    if (_colorKey.length != 0) {
        YTKACESetPreferenceObject(_colorKey, YTKACEHexFromColor(viewController.selectedColor));
        if (_colorPath != nil) {
            [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                                  withRowAnimation:UITableViewRowAnimationNone];
        }
    }
    _colorKey = nil;
    _colorPath = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    NSInteger mode = _pickerMode;
    _pickerMode = 0;
    if (mode == 3) {
        if (_pendingBackupURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
        }
        _pendingBackupURL = nil;
        NSString *message = YTKACELocalized(@"The backup was not saved to the Files app.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (!YTKACEShowYouTubeDialog(YTKACELocalized(@"Backup Not Saved"), message)) {
                    YTKACEShowNotice(YTKACELocalized(@"Warning: Backup was not saved to Files app."));
                }
            });
    }
}

- (void)setBackupProgressVisible:(BOOL)visible message:(NSString *)message {
    if (!visible) {
        UIView *overlay = _backupOverlay;
        _backupOverlay = nil;
        _backupOverlayLabel = nil;
        [UIView animateWithDuration:0.18 animations:^{
            overlay.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [overlay removeFromSuperview];
        }];
        return;
    }
    if (_backupOverlay != nil) {
        _backupOverlayLabel.text = message.length == 0 ? YTKACELocalized(@"Please Wait...") : message;
        return;
    }
    UIView *host = self.navigationController.view ?: self.view;
    UIView *overlay = [UIView new];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.alpha = 0.0;

    UIView *card = [UIView new];
    card.backgroundColor = YTKACEInterfaceSurfaceColor(self.traitCollection);
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = UIColor.labelColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UILabel *label = [UILabel new];
    label.text = message.length == 0 ? YTKACELocalized(@"Please Wait...") : message;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:spinner];
    [card addSubview:label];
    [overlay addSubview:card];
    [host addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:190.0],
        [card.heightAnchor constraintEqualToConstant:94.0],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:17.0],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-17.0]
    ]];
    _backupOverlay = overlay;
    _backupOverlayLabel = label;
    [UIView animateWithDuration:0.18 animations:^{ overlay.alpha = 1.0; }];
}

- (void)performBackup {
    if (_backupRunning) return;
    _backupRunning = YES;
    [self setBackupProgressVisible:YES message:YTKACELocalized(@"Preparing Backup...")];
    __weak YTKACEOptionsController *weakSelf = self;
    [YTKACEBackupManager createBackupWithCompletion:^(NSURL *URL, NSError *error) {
        YTKACEOptionsController *controller = weakSelf;
        if (controller == nil) return;
        controller->_backupRunning = NO;
        [controller setBackupProgressVisible:NO message:nil];
        if (URL == nil || error != nil) {
            NSString *message = error.localizedDescription ?: YTKACELocalized(@"The backup could not be created.");
            if (!YTKACEShowYouTubeDialog(YTKACELocalized(@"Backup Failed"), message)) {
                [controller showResult:YTKACELocalized(@"Backup Failed") message:message];
            }
            return;
        }
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[URL] asCopy:YES];
        controller->_pickerMode = 3;
        controller->_pendingBackupURL = URL;
        picker.delegate = controller;
        [controller presentViewController:picker animated:YES completion:nil];
    }];
}

- (void)beginBackup {
    if (_backupRunning) return;
    __weak YTKACEOptionsController *weakSelf = self;
    BOOL shown = YTKACEShowYouTubeConfirmation(
        @"YTKACE",
        YTKACELocalized(@"Do you want to create a backup?"),
        YTKACELocalized(@"Create"),
        ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf performBackup];
            });
        }
    );
    if (!shown) {
        YTKACEShowNotice(YTKACELocalized(@"Backup confirmation unavailable"));
    }
}

- (void)beginRestore {
    if (_restoreRunning) return;
    _pickerMode = 1;
    UTType *zip = [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[zip] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)beginImportForCategory:(NSString *)category {
    _pickerMode = 2;
    _importCategory = [category copy];
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObjects:
        UTTypeMovie, UTTypeAudio, UTTypeImage, nil];
    UTType *srt = [UTType typeWithFilenameExtension:@"srt"];
    UTType *vtt = [UTType typeWithFilenameExtension:@"vtt"];
    if (srt != nil) [types addObject:srt];
    if (vtt != nil) [types addObject:vtt];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseImportCategory {
    YTKACEPresentChoiceMenu(self, self.view, YTKACELocalized(@"Import Media"),
        @[YTKACELocalized(@"Video"), YTKACELocalized(@"Audio"), YTKACELocalized(@"Shorts")],
        @[@"Video", @"Audio", @"Shorts"],
        @"YTKACEImportMediaType", 0, ^(NSUInteger index) {
            NSArray *categories = @[@"Video", @"Audio", @"Shorts"];
            [self beginImportForCategory:categories[index]];
        });
}

- (void)showResult:(NSString *)title message:(NSString *)message {
    NSString *notice = message.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", title, message] : title;
    YTKACEShowNotice(notice);
}

- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles {
    _sections = [sections copy];
    _sectionTitles = [sectionTitles copy];
    [self.tableView reloadData];
}

@end

UIViewController *YTKACEMakeSettingsResultsController(
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    return [[YTKACEOptionsController alloc] initWithTitle:@""
                                                 sections:sections
                                            sectionTitles:sectionTitles];
}

void YTKACEUpdateSettingsResultsController(UIViewController *controller,
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    if (![controller isKindOfClass:YTKACEOptionsController.class]) return;
    [(YTKACEOptionsController *)controller replaceSections:sections
                                            sectionTitles:sectionTitles];
}

static YTKACEOptionsController *YTKACEPage(NSString *title,
                                           NSArray *sections,
                                           NSArray *sectionTitles) {
    return [[YTKACEOptionsController alloc] initWithTitle:YTKACELocalized(title)
                                                 sections:sections
                                           sectionTitles:YTKACELocalizedList(sectionTitles)];
}

static NSArray<NSString *> *YTKACEQualityTitles(void) {
    return @[YTKACELocalized(@"Auto"), @"2160p60", @"2160p", @"1440p60", @"1440p", @"1080p60",
             @"1080p", @"720p60", @"720p", @"480p", @"360p", @"240p", @"144p"];
}

static NSArray *YTKACEQualityValues(void) {
    return @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
}

static NSDictionary *YTKACEPageDefinition(NSString *pageID,
                                          NSString *title,
                                          NSArray *sections,
                                          NSArray *headers) {
    return @{
        @"id": pageID,
        @"title": title,
        @"sections": sections,
        @"headers": headers
    };
}

static YTKACEOptionsController *YTKACEPageFromDefinition(NSDictionary *definition) {
    return YTKACEPage(definition[@"title"],
                      definition[@"sections"],
                      definition[@"headers"]);
}

void YTKACEStartupDestinations(NSArray<NSString *> * _Nullable * _Nullable outTitles,
                               NSArray<NSString *> * _Nullable * _Nullable outValues) {
    NSArray<NSArray<NSString *> *> *destinations = @[
        @[@"", YTKACELocalized(@"Default"), @""],
        @[@"home", YTKACELocalized(@"Home"), @"YTKACE.Preference.Tabs.Hidden.Home"],
        @[@"explore", YTKACELocalized(@"Explore"), @""],
        @[@"subscriptions", YTKACELocalized(@"Subscriptions"), @"YTKACE.Preference.Tabs.Hidden.Subscriptions"],
        @[@"shorts", YTKACELocalized(@"Shorts"), @"YTKACE.Preference.Tabs.Hidden.Shorts"],
        @[@"library", YTKACELocalized(@"You"), @"YTKACE.Preference.Tabs.Hidden.Library"],
        @[@"ytkace", @"YTKACE", @"YTKACE.Preference.Tabs.Hidden.YTKACETab"],
        @[@"create", YTKACELocalized(@"Create"), @"YTKACE.Preference.Tabs.Hidden.Create"],
        @[@"music", YTKACELocalized(@"Music"), @"YTKACE.Preference.Tabs.Hidden.Music"],
        @[@"live", YTKACELocalized(@"Live"), @"YTKACE.Preference.Tabs.Hidden.Live"],
        @[@"gaming", YTKACELocalized(@"Gaming"), @"YTKACE.Preference.Tabs.Hidden.Gaming"],
        @[@"news", YTKACELocalized(@"News"), @"YTKACE.Preference.Tabs.Hidden.News"],
        @[@"posts", YTKACELocalized(@"Posts"), @"YTKACE.Preference.Tabs.Hidden.Posts"],
        @[@"sports", YTKACELocalized(@"Sports"), @"YTKACE.Preference.Tabs.Hidden.Sports"],
        @[@"learning", YTKACELocalized(@"Learning"), @"YTKACE.Preference.Tabs.Hidden.Learning"],
        @[@"fashion", YTKACELocalized(@"Fashion"), @"YTKACE.Preference.Tabs.Hidden.Fashion"],
        @[@"playlists", YTKACELocalized(@"Playlists"), @"YTKACE.Preference.Tabs.Hidden.Playlists"],
        @[@"history", YTKACELocalized(@"History"), @"YTKACE.Preference.Tabs.Hidden.History"],
        @[@"notifications", YTKACELocalized(@"Notifs"), @"YTKACE.Preference.Tabs.Hidden.Notifs"],
        @[@"watchlater", YTKACELocalized(@"WLater"), @"YTKACE.Preference.Tabs.Hidden.WatchLater"]
    ];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *selected = [defaults stringForKey:@"YTKACE.Preference.Tabs.Startup"];
    NSArray<NSString *> *known = [defaults arrayForKey:@"YTKACE.Preference.Tabs.Known"];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSArray<NSString *> *entry in destinations) {
        NSString *token = entry[0];
        NSString *hideKey = entry[2];
        BOOL hidden = hideKey.length != 0 && [defaults boolForKey:hideKey];
        NSString *canonical =
            [token isEqualToString:@"library"] ? @"you" : token;
        if (token.length != 0 && known.count != 0 &&
            ![known containsObject:canonical] && ![token isEqualToString:selected]) {
            continue;
        }
        if (hidden && ![token isEqualToString:selected]) continue;
        [titles addObject:entry[1]];
        [values addObject:token];
    }
    if (outTitles != NULL) *outTitles = titles;
    if (outValues != NULL) *outValues = values;
}

UIViewController *YTKACEMakeStartupPickerController(void) {
    NSArray<NSString *> *titles = nil;
    NSArray<NSString *> *values = nil;
    YTKACEStartupDestinations(&titles, &values);
    return [[YTKACEPickerController alloc]
        initWithTitle:YTKACELocalized(@"Startup Page")
                   key:@"YTKACE.Preference.Tabs.Startup"
                titles:titles
                values:values
          defaultIndex:0];
}

UIViewController *YTKACEMakeWiFiQualityController(void) {
    return [[YTKACEPickerController alloc] initWithTitle:YTKACELocalized(@"Wi-Fi Quality")
                                                    key:@"YTKACE.Preference.Playback.WiFiQuality"
                                                 titles:YTKACEQualityTitles()
                                                 values:YTKACEQualityValues()
                                           defaultIndex:0];
}

UIViewController *YTKACEMakeCellularQualityController(void) {
    return [[YTKACEPickerController alloc] initWithTitle:YTKACELocalized(@"Cellular Quality")
                                                    key:@"YTKACE.Preference.Playback.CellularQuality"
                                                 titles:YTKACEQualityTitles()
                                                 values:YTKACEQualityValues()
                                           defaultIndex:0];
}

static NSDictionary *YTKACESponsorBlockDefinition(void) {
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@[
        YTKACEToggleDetail(@"SponsorBlock",
                           @"Skip or mark video segments. Set each category below.",
                           YTKACESponsorBlockKey),
        YTKACEPickerDetail(@"Skip Notice", @"Shown after a segment is skipped.",
                     @"YTKACE.Preference.SponsorBlock.NotificationMode",
                     @[@"With Unskip", @"Text Only", @"Off"],
                     @[@0, @1, @2], 0),
        YTKACEToggleDetail(@"Skip Sound", @"Play a sound and vibrate when a segment is skipped.",
                           @"YTKACE.Preference.SponsorBlock.AudioFeedback"),
        YTKACESlider(@"Notice Duration", @"YTKACE.Preference.SponsorBlock.SkipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0),
        YTKACESlider(@"Unskip Duration", @"YTKACE.Preference.SponsorBlock.UnskipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0)
    ]];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:YTKACELocalized(@"MAIN")];

    [sections addObject:@[
        YTKACEToggleDetail(@"DeArrow Thumbnails",
                           @"Replace clickbait thumbnails with community-picked "
                            "frames from DeArrow. Videos without a submission are "
                            "left untouched.",
                           YTKACEDeArrowThumbModeKey),
        YTKACEToggleDetail(@"DeArrow Titles",
                           @"Replace clickbait titles with community-written ones "
                            "from DeArrow. Videos without a submission keep their "
                            "original title.",
                           YTKACEDeArrowTitlesKey)
    ]];
    [titles addObject:YTKACELocalized(@"DEARROW")];

    for (NSDictionary<NSString *, NSString *> *definition in
         YTKACESponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        BOOL highlight = [category isEqualToString:@"poi_highlight"];
        [sections addObject:@[
            highlight
                ? YTKACEPicker(@"Behavior", YTKACESponsorBehaviorKey(category),
                               @[@"Show Marker", @"Disabled"], @[@3, @2], 1, @"", @"")
                : YTKACEPicker(@"Behavior", YTKACESponsorBehaviorKey(category),
                               @[@"Auto-skip", @"Ask", @"Show Marker", @"Disabled"],
                               @[@0, @1, @3, @2],
                               [category isEqualToString:@"sponsor"] ? 0 : 3,
                               @"", @""),
            YTKACEColor(@"Segment Color", YTKACESponsorColorKey(category),
                        definition[@"color"])
        ]];
        [titles addObject:YTKACELocalized([definition[@"title"] uppercaseString])];
    }
    return YTKACEPageDefinition(@"sponsorblock", @"SponsorBlock", sections, titles);
}

static NSDictionary *YTKACEPlayerDefinition(void) {
    return YTKACEPageDefinition(@"player", @"Player", @[
        @[
            YTKACEToggleDetail(@"PiP Button", @"Add a button that opens the video in picture in picture.", YTKACEPiPKey),
            YTKACEToggle(@"Loop Button", YTKACELoopKey, @"", @""),
            YTKACEToggle(@"Sleep Timer Button", YTKACESleepTimerKey, @"", @""),
            YTKACEToggle(@"Speed Button", YTKACESpeedKey, @"", @""),
            YTKACEPickerDetail(@"Speed Button Style",
                @"Speed Menu shows the current speed and opens YouTube's speed menu with speeds up to 5x.",
                @"YTKACE.Preference.Player.SpeedButtonStyle",
                @[@"− / +", @"Speed Menu"], @[@0, @1], 0)
        ],
        @[
            YTKACEPicker(@"Default Playback Speed",
                         @"YTKACE.Preference.Player.StartRate",
                         @[@"Follow YouTube", @"Match last used", @"Custom"],
                         @[@0, @(-1), @(-2)], 0, @"", @""),
            YTKACEStackedSlider(@"Custom speed",
                                @"YTKACE.Preference.Player.CustomRate",
                                0.25, 5.0, 0.05, 1.0, @"speed"),
            YTKACEToggleDetail(@"Custom Hold Speed",
                               @"Change the speed used when you hold to speed up. "
                               @"Restart YouTube after changing.",
                               @"YTKACE.Preference.Player.HoldSpeedEnabled"),
            YTKACEStackedSlider(@"Hold speed",
                                @"YTKACE.Preference.Player.HoldSpeedRate",
                                0.25, 5.0, 0.25, 2.0, @"speed")
        ],
        @[
            YTKACEToggleDetail(@"Background Audio",
                               @"Keep playing when you leave the app or lock the screen.",
                               YTKACEBackgroundPlaybackKey),
            YTKACEToggleDetail(@"Stop Autoplay Next",
                               @"Do not roll into the next video when one ends.",
                               @"YTKACE.Preference.Playback.AutoplayDisabled"),
            YTKACEToggleDetail(@"Open Videos Paused",
                               @"Videos load without starting playback.",
                               @"YTKACE.Preference.Playback.OpenPaused"),
            YTKACEToggleDetail(@"Local Queue",
                               @"Play next and play last without Premium.",
                               @"YTKACE.Preference.Playback.LocalQueue"),
            YTKACEPickerDetail(@"Lock Screen Skip",
                @"Replace next and previous on the lock screen and in Control Center with skip buttons.",
                @"YTKACE.Preference.Playback.RemoteSkip",
                @[@"Off", @"10 seconds", @"15 seconds", @"30 seconds"], @[@0, @10, @15, @30], 0),
            YTKACEToggle(@"Remove Ads", YTKACENoAdsKey, @"", @""),
            YTKACEPickerDetail(@"Playback Fix",
                @"Try this if videos won't load or keep buffering. Restart YouTube after changing.",
                @"YTKACE.Preference.Playback.FixMode",
                @[@"Off", @"Reload", @"HLS Streams"],
                @[@0, @1, @2], (NSUInteger)YTKACEPlaybackFixMode())
        ],
        @[
            YTKACEToggleDetail(@"Keep Controls Visible", @"Player controls never fade out.",
                               @"YTKACE.Preference.Overlay.AlwaysShowControls"),
            YTKACEToggle(@"Keep Play Button Visible", @"YTKACE.Preference.Overlay.AlwaysShowPlayPause", @"", @""),
            YTKACEToggle(@"Keep Timeline Visible", @"YTKACE.Preference.Overlay.ProgressAlwaysVisible", @"", @""),
            YTKACEToggleDetail(@"Remove Player Dimming",
                               @"Stop the video from darkening when the controls show.",
                               @"YTKACE.Preference.Overlay.DimmingRemoved"),
            YTKACEToggle(@"Show Status Bar in Fullscreen", @"YTKACE.Preference.Overlay.StatusBarVisible", @"", @""),
            YTKACEPickerDetail(@"Video Zoom",
                @"Stop pinch zoom at fill, or zoom past YouTube's 8x limit.",
                @"YTKACE.Preference.Playback.VideoZoom",
                @[@"Original", @"Cap to Fill", @"Unlimited"],
                @[@0, @1, @2], 0)
        ],
        @[
            YTKACEToggleDetail(@"Disable Previous/Next", @"Grey out previous and next so they can't be tapped.",
                               @"YTKACE.Preference.Overlay.PreviousNextDisabled"),
            YTKACEToggle(@"Smaller Previous/Next", @"YTKACE.Preference.Overlay.CompactPreviousNext", @"", @""),
            YTKACEToggle(@"Remove Previous/Next", @"YTKACE.Preference.Overlay.PreviousNextHidden", @"", @"")
        ],
        @[
            YTKACEToggle(@"Remove Play Button", @"YTKACE.Preference.Overlay.PlayPauseHidden", @"", @""),
            YTKACEToggle(@"Remove Settings Button", @"YTKACE.Preference.Overlay.MoreButtonHidden", @"", @""),
            YTKACEToggle(@"Remove Captions Button", @"YTKACE.Preference.Overlay.CaptionsButtonHidden", @"", @""),
            YTKACEToggle(@"Remove Cast Button", @"YTKACE.Preference.Overlay.CastHidden", @"", @""),
            YTKACEToggle(@"Remove Autoplay Switch", @"YTKACE.Preference.Overlay.AutoplayHidden", @"", @""),
            YTKACEToggle(@"Remove Info Cards", @"YTKACE.Preference.Overlay.InfoCardsHidden", @"", @""),
            YTKACEToggle(@"Remove Channel Watermark", @"YTKACE.Preference.Overlay.WatermarkHidden", @"", @""),
            YTKACEToggle(@"Remove End Screen", @"YTKACE.Preference.Overlay.EndScreenHidden", @"", @""),
            YTKACEToggleDetail(@"Remove Fullscreen Actions",
                               @"Hide the row of buttons under the progress bar in fullscreen.",
                               @"YTKACE.Preference.Overlay.FullscreenActionsHidden"),
            YTKACEToggle(@"Remove Quick Actions", @"YTKACE.Preference.Overlay.QuickActionsHidden", @"", @""),
            YTKACEToggle(@"Remove Continue Watching", @"YTKACE.Preference.Overlay.ContinueWatchingDisabled", @"", @"")
        ],
        @[
            YTKACESegmentedStacked(@"Progress bar style", @"YTKACE.Preference.Progress.Style",
                                   @[@"Default", @"Solid color", @"Gradient"], @[@0, @1, @2], 0),
            YTKACEColor(@"Main color", @"YTKACE.Preference.Progress.MainColor", @"#FF0000"),
            YTKACEColorDetail(@"Gradient highlight", @"Used only with Gradient.",
                              @"YTKACE.Preference.Progress.HighlightColor", @"#8E8EFF"),
            YTKACEColorDetail(@"Scrubber color", @"Not used with the Default style.",
                              @"YTKACE.Preference.Progress.ScrubberColor", @"#FF0000")
        ]
    ], @[YTKACELocalized(@"BUTTONS"), YTKACELocalized(@"SPEED"), YTKACELocalized(@"PLAYBACK"),
         YTKACELocalized(@"CONTROLS"), YTKACELocalized(@"PREVIOUS & NEXT"),
         YTKACELocalized(@"HIDE FROM PLAYER"), YTKACELocalized(@"PROGRESS BAR")]);
}

static NSDictionary *YTKACEQualityDefinition(void) {
    NSArray *qualities = @[@"Auto", @"2160p60", @"2160p", @"1440p60", @"1440p",
                           @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
                           @"360p", @"240p", @"144p"];
    NSArray *values = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
    return YTKACEPageDefinition(@"quality", @"Video Quality", @[
        @[
            YTKACEPicker(@"Wi-Fi Quality", @"YTKACE.Preference.Playback.WiFiQuality",
                         qualities, values, 0, @"", @""),
            YTKACEPicker(@"Mobile Data Quality", @"YTKACE.Preference.Playback.CellularQuality",
                         qualities, values, 0, @"", @""),
            YTKACEToggleDetail(@"HD on Mobile Data", @"Remove YouTube's quality limit on mobile data.",
                               @"YTKACE.Preference.Playback.HDOnCellular")
        ],
        @[
            YTKACEToggleDetail(@"Classic Quality Menu", @"Show the full resolution list instead of YouTube's simple menu.",
                               @"YTKACE.Preference.Playback.LegacyQualityMenu"),
            YTKACEToggleDetail(@"Hide Premium Quality",
                               @"Removes 1080p Premium from the quality menu.",
                               @"YTKACE.Preference.Playback.PremiumQualityHidden"),
            YTKACEToggleDetail(@"Disable HDR",
                               @"Play videos in standard dynamic range.",
                               @"YTKACE.Preference.Playback.HDRDisabled")
        ]
    ], @[YTKACELocalized(@"DEFAULT QUALITY"), YTKACELocalized(@"QUALITY MENU")]);
}

static NSDictionary *YTKACECaptionsDefinition(void) {
    return YTKACEPageDefinition(@"captions", @"Captions", @[
        @[
            YTKACEPickerDetail(@"Captions",
                @"Default follows YouTube. Restart YouTube after changing.",
                @"YTKACE.Preference.Playback.CaptionsMode",
                @[@"Default", @"Always On", @"Always Off"], @[@0, @1, @2], 0),
            YTKACEPickerDetail(@"Caption Language",
                         @"Turns captions on in this language when a video has them.",
                         @"YTKACE.Preference.Playback.CaptionLanguage",
                         @[@"Default", @"English", @"Spanish", @"Portuguese",
                           @"French", @"German", @"Italian", @"Dutch",
                           @"Polish", @"Turkish", @"Russian", @"Arabic",
                           @"Hindi", @"Indonesian", @"Vietnamese", @"Thai",
                           @"Japanese", @"Korean", @"Chinese"],
                         @[@"", @"en", @"es", @"pt", @"fr", @"de", @"it",
                           @"nl", @"pl", @"tr", @"ru", @"ar", @"hi", @"id",
                           @"vi", @"th", @"ja", @"ko", @"zh"],
                         0)
        ],
        @[
            YTKACEToggleDetail(@"Transcript Button",
                               @"Copy or share a video's captions from the player.",
                               @"YTKACE.Preference.Playback.Transcript")
        ]
    ], @[YTKACELocalized(@"CAPTIONS"), YTKACELocalized(@"TRANSCRIPT")]);
}

static NSDictionary *YTKACEWatchPageDefinition(void) {
    return YTKACEPageDefinition(@"watch", @"Watch Page", @[
        @[
            YTKACEToggle(@"Remove Suggested Videos", @"YTKACE.Preference.Overlay.SuggestedVideosHidden", @"", @""),
            YTKACEToggle(@"Remove Related Videos", @"YTKACE.Preference.Overlay.RelatedVideosHidden", @"", @""),
            YTKACEToggleDetail(@"Remove Comments", @"Hide the comments box under the video.",
                               @"YTKACE.Preference.Overlay.CommentsHidden"),
            YTKACEToggle(@"Remove Comment Preview", @"YTKACE.Preference.Overlay.CommentPreviewsHidden", @"", @""),
            YTKACEToggle(@"Remove Comment Guidelines", @"YTKACE.Preference.Overlay.CommentGuidelinesHidden", @"", @""),
            YTKACEToggle(@"Remove Paid Promotion Label", @"YTKACE.Preference.Overlay.PaidPromotionHidden", @"", @""),
            YTKACEToggleDetail(@"Remove Products", @"Hide shopping and product tags in videos, Shorts and feeds.",
                               @"YTKACE.Preference.Overlay.ProductsHidden")
        ],
        @[
            YTKACEToggle(@"Remove Like", @"YTKACE.Preference.ActionBar.LikeHidden", @"", @""),
            YTKACEToggle(@"Remove Dislike", @"YTKACE.Preference.ActionBar.DislikeHidden", @"", @""),
            YTKACEToggle(@"Remove Share", @"YTKACE.Preference.ActionBar.ShareHidden", @"", @""),
            YTKACEToggle(@"Remove Download", @"YTKACE.Preference.ActionBar.DownloadHidden", @"", @""),
            YTKACEToggle(@"Remove Save", @"YTKACE.Preference.ActionBar.SaveHidden", @"", @""),
            YTKACEToggle(@"Remove Clip", @"YTKACE.Preference.ActionBar.ClipHidden", @"", @""),
            YTKACEToggle(@"Remove Remix", @"YTKACE.Preference.ActionBar.RemixHidden", @"", @""),
            YTKACEToggle(@"Remove Thanks", @"YTKACE.Preference.ActionBar.ThanksHidden", @"", @""),
            YTKACEToggle(@"Remove Hype", @"YTKACE.Preference.ActionBar.HypeHidden", @"", @""),
            YTKACEToggle(@"Remove Report", @"YTKACE.Preference.ActionBar.ReportHidden", @"", @""),
            YTKACEToggle(@"Remove Ask Button", @"YTKACE.Preference.ActionBar.AskHidden", @"", @""),
            YTKACEToggle(@"Remove ⋯ Button", @"YTKACE.Preference.ActionBar.OverflowHidden", @"", @"")
        ]
    ], @[YTKACELocalized(@"UNDER THE VIDEO"), YTKACELocalized(@"ACTION BAR")]);
}

static NSDictionary *YTKACEFeedDefinition(void) {
    return YTKACEPageDefinition(@"feed", @"Home & Feed", @[
        @[
            YTKACEToggleDetail(@"Normal Home Layout",
                               @"Switches the tabbed Home redesign some accounts get back to the normal layout.",
                               @"YTKACE.Preference.Feed.HomeTabsHidden"),
            YTKACEToggleDetail(@"Remove Filter Chips", @"Hide the filter chips at the top of Home and Subscriptions.",
                               @"YTKACE.Preference.Navigation.TopicsHidden")
        ],
        @[
            YTKACEToggle(@"Remove Shorts Shelves", @"YTKACE.Preference.Shorts.FeedHidden", @"", @""),
            YTKACEToggleDetail(@"Keep Shorts in Home",
                @"Still show Shorts on the Home feed when shelves are removed.",
                @"YTKACE.Preference.Shorts.HomeKept"),
            YTKACEToggleDetail(@"Keep Shorts in Subscriptions",
                @"Still show Shorts in the Subscriptions feed when shelves are removed.",
                @"YTKACE.Preference.Shorts.SubscriptionsKept"),
            YTKACEToggleDetail(@"Keep Shorts in Search",
                @"Still show Shorts in search results when shelves are removed.",
                @"YTKACE.Preference.Shorts.SearchKept"),
            YTKACEToggleDetail(@"Keep Shorts on Channels",
                @"Still show Shorts on channel pages when shelves are removed.",
                @"YTKACE.Preference.Shorts.ChannelsKept"),
            YTKACEToggleDetail(@"Remove Horizontal Shelves",
                               @"Removes horizontal shelves like Watch again from the feed.",
                               @"YTKACE.Preference.Feed.HorizontalShelvesHidden"),
            YTKACEToggleDetail(@"Remove Community Posts",
                               @"Removes community posts from the feed.",
                               @"YTKACE.Preference.Feed.CommunityPostsHidden"),
            YTKACEToggleDetail(@"Remove Mixes",
                               @"Removes YouTube Mix playlists from the feed.",
                               @"YTKACE.Preference.Feed.MixesHidden"),
            YTKACEToggleDetail(@"Remove Playables",
                               @"Removes playable games from the feed.",
                               @"YTKACE.Preference.Feed.PlayablesHidden")
        ],
        @[
            YTKACEToggleDetail(@"Hide AI Channels",
                               @"Hides videos from channels on the AiSList blocklist.",
                               @"YTKACE.Preference.Feed.AIChannelsHidden"),
            YTKACEWithFooter(YTKACEToggleDetail(@"Hide Suspected AI Channels",
                               @"Also hides channels on the AiSList warnlist.",
                               @"YTKACE.Preference.Feed.SuspectedAIChannelsHidden"),
                             @"List from aisloplist.com, updates automatically.")
        ]
    ], @[YTKACELocalized(@"HOME"), YTKACELocalized(@"FEED"), YTKACELocalized(@"AI CHANNELS")]);
}

static NSDictionary *YTKACEShortsOptionsDefinition(void) {
    return YTKACEPageDefinition(@"shorts", @"Shorts", @[
        @[
            YTKACEToggleDetail(@"Shorts Progress Bar", @"Show a thin progress line at the bottom of Shorts.", @"shortsProgress"),
            YTKACEToggle(@"Auto-Scroll to Next Short", @"autoSkipShorts", @"", @""),
            YTKACEToggleDetail(@"Play Shorts Once",
                               @"Pause at the end instead of replaying.",
                               @"YTKACE.Preference.Shorts.LoopDisabled"),
            YTKACEPicker(@"Shorts Speed", @"YTKACE.Preference.Shorts.PlaybackRate",
                         @[@"Same as videos", @"0.5x", @"0.75x", @"1x", @"1.25x",
                           @"1.5x", @"1.75x", @"2x"],
                         @[@0, @0.5, @0.75, @1, @1.25, @1.5, @1.75, @2], 0, @"", @""),
            YTKACEToggleDetail(@"Pinch to Fullscreen",
                               @"Pinch out in Shorts to hide the overlay and tab bar.",
                               @"YTKACE.Preference.Shorts.PinchFullscreen"),
            YTKACEToggle(@"Disable PiP for Shorts", @"YTKACE.Preference.Shorts.PiPDisabled", @"", @""),
            YTKACEPickerDetail(@"Download Button Position", @"Needs Download Button turned on in Downloads.",
                         @"YTKACE.Preference.Shorts.DownloadPosition",
                         @[@"Top Corner", @"Action Buttons"], @[@0, @1], 0)
        ],
        @[
            YTKACEToggleDetail(@"Limit Shorts",
                @"Stop scrolling after a set number of Shorts. Resets when YouTube restarts.",
                @"YTKACE.Preference.Shorts.LimitEnabled"),
            YTKACECountStepper(@"Shorts limit", @"YTKACE.Preference.Shorts.LimitCount",
                               5.0, 200.0, 5.0, 20.0)
        ],
        @[
            YTKACEToggleDetail(@"Remove Pause Suggestions", @"Hide the videos shown when you pause a Short.",
                               @"YTKACE.Preference.Shorts.PauseCardHidden"),
            YTKACEToggle(@"Remove Sticker Ads", @"YTKACE.Preference.Shorts.StickerAdsHidden", @"", @""),
            YTKACEToggleDetail(@"Remove Suggestion Pill",
                               @"Hide the suggestion pill above a Short's title.",
                               @"YTKACE.Preference.Shorts.SuggestionPillHidden"),
            YTKACEToggle(@"Remove Like", @"YTKACE.Preference.Shorts.LikeHidden", @"", @""),
            YTKACEToggle(@"Remove Comments", @"YTKACE.Preference.Shorts.CommentsHidden", @"", @""),
            YTKACEToggle(@"Remove Share", @"YTKACE.Preference.Shorts.ShareHidden", @"", @""),
            YTKACEToggle(@"Remove Save", @"YTKACE.Preference.Shorts.SaveHidden", @"", @""),
            YTKACEToggle(@"Remove Remix", @"YTKACE.Preference.Shorts.RemixHidden", @"", @""),
            YTKACEToggle(@"Remove Sound Button", @"YTKACE.Preference.Shorts.SoundHidden", @"", @"")
        ]
    ], @[YTKACELocalized(@"PLAYBACK"), YTKACELocalized(@"SCREEN TIME"), YTKACELocalized(@"HIDE FROM SHORTS")]);
}

static NSDictionary *YTKACETopBarDefinition(void) {
    return YTKACEPageDefinition(@"topbar", @"Top Bar", @[
        @[
            YTKACEToggle(@"Premium Logo", @"YTKACE.Preference.Navigation.PremiumLogo", @"", @""),
            YTKACEToggle(@"Remove YouTube Logo", @"YTKACE.Preference.Navigation.LogoHidden", @"", @"")
        ],
        @[
            YTKACEToggle(@"Remove Notifications Button", @"YTKACE.Preference.Navigation.NotificationsHidden", @"", @""),
            YTKACEToggle(@"Remove Messages Button", @"YTKACE.Preference.Navigation.MessagesHidden", @"", @""),
            YTKACEToggle(@"Remove Search Button", @"YTKACE.Preference.Navigation.SearchHidden", @"", @""),
            YTKACEToggle(@"Remove Account Button", @"YTKACE.Preference.Navigation.AccountHidden", @"", @""),
            YTKACEToggle(@"Remove Cast Button", @"YTKACE.Preference.Navigation.CastHidden", @"", @""),
            YTKACEToggleDetail(@"Confirm Before Casting", @"Ask before opening the Cast menu.",
                               @"YTKACE.Preference.Navigation.CastConfirmation")
        ],
        @[
            YTKACEToggle(@"Hide Status Bar", @"YTKACE.Preference.Navigation.StatusBarHidden", @"", @"")
        ]
    ], @[YTKACELocalized(@"LOGO"), YTKACELocalized(@"BUTTONS"), YTKACELocalized(@"STATUS BAR")]);
}

static NSDictionary *YTKACEGlassOptionsDefinition(void) {
    return YTKACEPageDefinition(@"glass", @"Liquid Glass", @[
        @[
            YTKACEPickerDetail(@"Tab Bar", @"Default leaves YouTube's own tab bar as is.",
                               @"YTKACE.Preference.Tabs.GlassMode",
                               @[@"Default", @"YTKACE", @"YouTube", @"Off"], @[@0, @1, @2, @3],
                               YTKACETabBarOwnGlass() ? 1 : 0),
            YTKACEToggle(@"Top Bar Buttons", @"YTKACE.Preference.Glass.TopBar", @"", @""),
            YTKACEToggle(@"Menus and Sheets", @"YTKACE.Preference.Glass.Menus", @"", @""),
            YTKACEToggle(@"YTKACE Toasts and Popups", @"YTKACE.Preference.Glass.Notices", @"", @""),
            YTKACEToggle(@"Player Buttons", @"YTKACE.Preference.Glass.Player", @"", @"")
        ],
        @[
            YTKACEToggleDetail(@"Shrink Tab Bar When Scrolling", @"Needs the Liquid Glass tab bar.",
                               @"YTKACE.Preference.Tabs.GlassMinimize"),
            YTKACEPicker(@"Selected Tab Color", @"YTKACE.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            YTKACEColor(@"Color", @"YTKACE.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[YTKACELocalized(@"GLASS"), YTKACELocalized(@"EXTRAS")]);
}

static NSDictionary *YTKACEGeneralDefinition(void) {
    NSMutableArray *languageTitles = [NSMutableArray array];
    for (NSString *code in YTKACEAvailableLanguages()) {
        [languageTitles addObject:[code isEqualToString:@"system"]
            ? @"System" : YTKACELanguageDisplayName(code)];
    }
    return YTKACEPageDefinition(@"general", @"General", @[
        @[
            YTKACEPickerDetail(@"Language",
                @"Language for YTKACE menus. System follows your iPhone.",
                YTKACELanguageKey, languageTitles, YTKACEAvailableLanguages(), 0)
        ],
        @[
            YTKACEToggleDetail(@"OLED Black", @"Pure black background in dark mode.", YTKACEOLEDKey),
            YTKACEPercentSlider(@"Extra Dim",
                                @"YTKACE.Preference.Appearance.ExtraDim",
                                0.0, 80.0, 5.0, 0.0),
            YTKACEToggleDetail(@"Skip Launch Animation", @"Starts YouTube faster.",
                               @"YTKACE.Preference.Appearance.LaunchAnimationDisabled"),
            YTKACEPickerDetail(@"Device Layout",
                @"Force the iPhone or iPad layout instead of following the device.",
                @"YTKACE.Preference.App.LayoutIdiom",
                @[@"Default", @"iPhone", @"iPad"],
                @[@0, @1, @2], 0),
            YTKACEToggleDetail(@"Force Left-to-Right Layout", @"Keep a left-to-right layout in right-to-left languages.",
                               @"YTKACE.Preference.App.RTLDisabled"),
            YTKACEToggleDetail(@"Block Drag and Drop", @"Stop thumbnails and text from being dragged.",
                               @"YTKACE.Preference.App.DragDropDisabled")
        ],
        @[
            YTKACEToggleDetail(@"Use iOS Share Sheet", @"Use the iOS share sheet instead of YouTube's.",
                               @"YTKACE.Preference.Sharing.NativeSheet"),
            YTKACEToggleDetail(@"Share at Current Time",
                               @"Links shared from the iOS share sheet start where you are in the video.",
                               @"YTKACE.Preference.Sharing.Timestamp"),
            YTKACEToggle(@"Hold Avatar to Enlarge", @"YTKACE.Preference.Profiles.Preview", @"", @""),
            YTKACEToggleDetail(@"Save Post Images",
                @"Adds a save button when you open an image from a community post.",
                @"YTKACE.Preference.Posts.SaveImage"),
            YTKACEToggleDetail(@"Hold to Copy Text", @"Hold a post or comment to copy its text.",
                               @"YTKACE.Preference.Posts.CopyText"),
            YTKACEToggleDetail(@"Mini Player for Kids Videos",
                @"Allow the mini player on made-for-kids videos.",
                @"YTKACE.Preference.Playback.KidsMiniPlayer")
        ],
        @[
            YTKACEToggleDetail(@"Remove Search History", @"Hides past searches. Searches are still saved.",
                               @"YTKACE.Preference.Privacy.SearchHistoryDisabled"),
            YTKACEToggleDetail(@"Block Premium Prompts", @"Also hides \"Are you still watching?\" and upgrade dialogs.",
                               @"YTKACE.Preference.Ads.PremiumPromosHidden"),
            YTKACEToggleDetail(@"Hide YouTube Pop-up Messages",
                @"Hides the small messages YouTube shows at the bottom, like Saved to Watch later.",
                @"YTKACE.Preference.App.HUDAlertsHidden"),
            YTKACEToggleDetail(@"Skip Age Gate", @"Skip the age check screen. Some videos may still be blocked.",
                               @"YTKACE.Preference.Content.AgeGateBypass")
        ]
    ], @[YTKACELocalized(@"LANGUAGE"), YTKACELocalized(@"APPEARANCE"), YTKACELocalized(@"SHARING & EXTRAS"),
         YTKACELocalized(@"PRIVACY & PROMPTS")]);
}

static NSDictionary *YTKACEDownloadsDefinition(void) {
    YTKACEAction backup = ^(UIViewController *controller) {
        [(YTKACEOptionsController *)controller beginBackup];
    };
    YTKACEAction restore = ^(UIViewController *controller) {
        [(YTKACEOptionsController *)controller beginRestore];
    };
    YTKACEAction importMedia = ^(UIViewController *controller) {
        [(YTKACEOptionsController *)controller chooseImportCategory];
    };
    YTKACEAction clearCache = ^(UIViewController *controller) {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *cache = [YTKACEApplicationSupportDirectory()
            URLByAppendingPathComponent:@"Cache"
                            isDirectory:YES];
        NSUInteger freed = 0;
        NSDirectoryEnumerator *walker = [manager enumeratorAtURL:cache
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 errorHandler:nil];
        for (NSURL *child in walker) {
            NSNumber *size = nil;
            [child getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            freed += size.unsignedIntegerValue;
        }
        [manager removeItemAtURL:cache error:nil];
        freed += YTKACEPurgeDownloadScratch(YES);
        freed += YTKACEPurgeSystemCaches();
        NSString *summary = freed == 0
            ? YTKACELocalized(@"Nothing to clear.")
            : [NSString stringWithFormat:YTKACELocalized(@"Freed %@."),
               [NSByteCountFormatter stringFromByteCount:(long long)freed
                   countStyle:NSByteCountFormatterCountStyleFile]];
        [(YTKACEOptionsController *)controller
            showResult:YTKACELocalized(@"Cache Cleared") message:summary];
    };
    return YTKACEPageDefinition(@"downloads", @"Downloads", @[
        @[
            YTKACEPickerDetail(@"Download Button",
                         @"Off turns off all downloads, including Shorts and playlists.",
                         @"YTKACE.Preference.Downloads.Placement",
                         @[@"Off", @"Player overlay", @"YouTube's button", @"Both"],
                         @[@0, @1, @2, @3], 0),
            YTKACEToggle(@"Playlist Download Button",
                         @"YTKACE.Preference.Downloads.PlaylistEnabled", @"", @""),
            YTKACEPicker(@"Save Videos To",
                         @"YTKACE.Preference.Downloads.SaveLocation",
                         @[@"YTKACE Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            YTKACEPicker(@"Save Audio To",
                         @"YTKACE.Preference.Downloads.AudioSaveLocation",
                         @[@"YTKACE Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            YTKACEToggleDetail(@"Include Subtitles",
                               @"Embed captions into downloaded videos.",
                               @"YTKACE.Preference.Downloads.Subtitles"),
            YTKACEPickerDetail(@"Download Method",
                @"SABR is the default. Use TV Client or Direct if downloads fail.",
                @"YTKACE.Preference.Downloads.Method",
                @[@"SABR", @"TV Client", @"Direct"], @[@0, @2, @1], 0)
        ],
        @[
            YTKACEActionDetail(@"Back Up", @"Save settings and media to a ZIP file.", backup),
            YTKACEActionDetail(@"Restore", @"Open a YTKACE backup from Files.", restore),
            YTKACEActionDetail(@"Import", @"Add video, audio, Shorts, artwork, or subtitles.", importMedia)
        ],
        @[
            YTKACEToggleDetail(@"Clear Cache at Launch", @"Clear cache when YouTube opens, at most once a day.",
                               @"YTKACE.Preference.Downloads.ClearOnStartup"),
            YTKACEActionDetail(@"Clear Cache Now", @"Delete temporary files and YouTube's cache.", clearCache)
        ]
    ], @[YTKACELocalized(@"DOWNLOADS"), YTKACELocalized(@"BACKUP"), YTKACELocalized(@"STORAGE")]);
}

static NSDictionary *YTKACEGestureOptionsDefinition(void) {
    NSArray *actionTitles = @[@"None", @"Brightness", @"Volume", @"Brightness + Volume"];
    NSArray *actionValues = @[@0, @1, @2, @3];
    return YTKACEPageDefinition(@"gestures", @"Gestures", @[
        @[
            YTKACEPicker(@"Left Side", @"YTKACE.Preference.Gestures.LeftAction",
                         actionTitles, actionValues, 0, @"", @""),
            YTKACEPicker(@"Right Side", @"YTKACE.Preference.Gestures.RightAction",
                         actionTitles, actionValues, 0, @"", @""),
            YTKACEPercentSlider(@"Edge Width",
                                @"YTKACE.Preference.Gestures.ActivationArea",
                                10.0, 50.0, 5.0, 20.0),
            YTKACEToggleDetail(@"Landscape Only",
                               @"Disable gestures while the player is in portrait.",
                               @"YTKACE.Preference.Gestures.LandscapeOnly")
        ],
        @[
            YTKACEToggleDetail(@"Level Indicator",
                               @"Show the current brightness or volume level.",
                               @"YTKACE.Preference.Gestures.HUDEnabled"),
            YTKACEPicker(@"Indicator Size", @"YTKACE.Preference.Gestures.HUDSize",
                         @[@"Compact", @"Standard", @"Large"], @[@0, @1, @2],
                         1, @"", @""),
            YTKACEPicker(@"Indicator Position", @"YTKACE.Preference.Gestures.HUDPosition",
                         @[@"Top", @"Center", @"Bottom"], @[@0, @1, @2],
                         0, @"", @"")
        ],
        @[
            YTKACEToggleDetail(@"Turn Off Double Tap", @"Double tapping the video does nothing.",
                               @"YTKACE.Preference.Overlay.DoubleTapDisabled"),
            YTKACEToggle(@"Custom Double-Tap Skip", @"YTKACE.Preference.Playback.CustomDoubleTap", @"", @""),
            YTKACEStepper(@"Seconds", @"YTKACE.Preference.Playback.DoubleTapSeconds", 5.0, 60.0, 5.0, 10.0)
        ],
        @[
            YTKACEToggleDetail(@"Hold to Seek", @"Hold the left or right side to rewind or fast-forward.",
                               @"YTKACE.Preference.Gestures.HoldToSeek"),
            YTKACESlider(@"Seek Step", @"YTKACE.Preference.Gestures.HoldSeekSeconds", 1.0, 60.0, 1.0, 10.0),
            YTKACEToggleDetail(@"Tap to Seek", @"Tap the progress bar to jump to that point.",
                               @"YTKACE.Preference.Playback.TapToSeek"),
            YTKACEToggleDetail(@"Two-Finger Tap to Pause",
                               @"Tap the video with two fingers to pause or play.",
                               @"YTKACE.Preference.Gestures.TwoFingerTap")
        ]
    ], @[YTKACELocalized(@"SWIPE ON EDGES"), YTKACELocalized(@"LEVEL INDICATOR"),
         YTKACELocalized(@"DOUBLE TAP"), YTKACELocalized(@"SEEK")]);
}

UIViewController *YTKACEMakeTabBarOptionsController(void) {
    return [YTKACETabEditorController new];
}

NSArray<NSDictionary *> *YTKACESettingsMenu(void) {
    NSMutableArray *look = [NSMutableArray arrayWithArray:@[
        @{@"id": @"watch", @"title": @"Watch Page", @"detail": @"Comments, suggestions, and the button row", @"symbol": @"rectangle.on.rectangle"},
        @{@"id": @"feed", @"title": @"Home & Feed", @"detail": @"Home redesign, shelves, mixes, and posts", @"symbol": @"house"},
        @{@"id": @"shorts", @"title": @"Shorts", @"detail": @"Playback, limit, and buttons", @"symbol": @"shorts"},
        @{@"id": @"tabs", @"title": @"Tabs", @"detail": @"Choose, reorder, and rename tabs", @"symbol": @"rectangle.bottomthird.inset.filled"},
        @{@"id": @"topbar", @"title": @"Top Bar", @"detail": @"Logo, buttons, and status bar", @"symbol": @"rectangle.topthird.inset.filled"}
    ]];
    if (YTKACELiquidGlassAvailable()) {
        [look addObject:@{@"id": @"glass", @"title": @"Liquid Glass", @"detail": @"Tab bar, menus, toasts, and player", @"symbol": @"drop"}];
    }
    return @[
        @{@"header": @"PLAYBACK", @"rows": @[
            @{@"id": @"player", @"title": @"Player", @"detail": @"Buttons, speed, background audio, and controls", @"symbol": @"play.rectangle"},
            @{@"id": @"quality", @"title": @"Video Quality", @"detail": @"Default quality on Wi-Fi and mobile data", @"symbol": @"sparkles.tv"},
            @{@"id": @"captions", @"title": @"Captions", @"detail": @"Captions on or off, language, and transcript", @"symbol": @"captions.bubble"},
            @{@"id": @"gestures", @"title": @"Gestures", @"detail": @"Brightness, volume, double tap, and seeking", @"symbol": @"hand.draw"},
            @{@"id": @"sponsorblock", @"title": @"SponsorBlock", @"detail": @"Skip or mark sponsored segments", @"symbol": @"sponsor"},
            @{@"id": @"vot", @"title": @"Voice-Over Translation", @"detail": @"Yandex voice-over translation for videos", @"symbol": @"globe"}
        ]},
        @{@"header": @"LOOK & LAYOUT", @"rows": look},
        @{@"header": @"APP", @"rows": @[
            @{@"id": @"downloads", @"title": @"Downloads", @"detail": @"Download button, where to save, and backups", @"symbol": @"arrow.down.circle"},
            @{@"id": @"general", @"title": @"General", @"detail": @"Language, appearance, privacy, and prompts", @"symbol": @"gearshape"}
        ]}
    ];
}

static NSDictionary *YTKACEDefinitionForPage(NSString *pageID) {
    if ([pageID isEqualToString:@"vot"]) return YTKACEVOTDefinition();
    if ([pageID isEqualToString:@"sponsorblock"]) return YTKACESponsorBlockDefinition();
    if ([pageID isEqualToString:@"player"]) return YTKACEPlayerDefinition();
    if ([pageID isEqualToString:@"quality"]) return YTKACEQualityDefinition();
    if ([pageID isEqualToString:@"captions"]) return YTKACECaptionsDefinition();
    if ([pageID isEqualToString:@"gestures"]) return YTKACEGestureOptionsDefinition();
    if ([pageID isEqualToString:@"watch"]) return YTKACEWatchPageDefinition();
    if ([pageID isEqualToString:@"feed"]) return YTKACEFeedDefinition();
    if ([pageID isEqualToString:@"shorts"]) return YTKACEShortsOptionsDefinition();
    if ([pageID isEqualToString:@"topbar"]) return YTKACETopBarDefinition();
    if ([pageID isEqualToString:@"glass"]) return YTKACEGlassOptionsDefinition();
    if ([pageID isEqualToString:@"general"]) return YTKACEGeneralDefinition();
    if ([pageID isEqualToString:@"downloads"]) return YTKACEDownloadsDefinition();
    return nil;
}

UIViewController *YTKACEMakeSettingsPage(NSString *pageID) {
    if ([pageID isEqualToString:@"tabs"]) return YTKACEMakeTabBarOptionsController();
    NSDictionary *definition = YTKACEDefinitionForPage(pageID);
    return definition != nil ? YTKACEPageFromDefinition(definition) : nil;
}

NSDictionary *YTKACEVOTDefinition(void) {
    YTKACEAction shareVOTLog = ^(UIViewController *controller) {
        NSString *contents = YTKACEVOTLogContents();
        if (contents.length == 0) {
            YTKACEShowNotice(YTKACELocalized(@"Log file is empty"));
            return;
        }

        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-vot.log"]];
        [contents writeToURL:tempURL atomically:YES encoding:NSUTF8StringEncoding error:nil];

        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[tempURL] applicationActivities:nil];
        if (activity.popoverPresentationController != nil) {
            activity.popoverPresentationController.sourceView = controller.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 0, 0);
            activity.popoverPresentationController.permittedArrowDirections = 0;
        }
        [controller presentViewController:activity animated:YES completion:nil];
    };

    YTKACEAction clearVOTLog = ^(UIViewController *controller) {
        (void)controller;
        YTKACEClearVOTLog();
        YTKACEShowNotice(YTKACELocalized(@"Translation log cleared"));
    };

    BOOL isAuth = [YTKACEVOTClient isYandexAuthorized];
    NSString *currentLogin = [YTKACEVOTClient currentYandexLogin] ?: @"";

    NSMutableArray *accountRows = [NSMutableArray array];
    if (isAuth) {
        NSString *accountTitle = [NSString stringWithFormat:YTKACELocalized(@"Logged in as %@"), currentLogin];
        [accountRows addObject:YTKACEActionDetail(@"Yandex Account Status", accountTitle, ^(UIViewController *c) {
            (void)c;
        })];
        [accountRows addObject:YTKACEActionDetail(@"Log Out",
                                                  @"Disconnect Yandex account and remove token.",
                                                  ^(UIViewController *c) {
            [YTKACEVOTClient logoutYandex];
            YTKACEShowNotice(YTKACELocalized(@"Logged out from Yandex"));
            if ([c isKindOfClass:[YTKACEOptionsController class]]) {
                NSDictionary *def = YTKACEVOTDefinition();
                [(YTKACEOptionsController *)c replaceSections:def[@"sections"] sectionTitles:def[@"headers"]];
            }
        })];
    } else {
        [accountRows addObject:YTKACEActionDetail(@"Log in via Safari",
                                                  @"Open Yandex OAuth authorization page in Safari.",
                                                  ^(UIViewController *c) {
            (void)c;
            [YTKACEYandexAuthViewController openSafariAuth];
        })];
        [accountRows addObject:YTKACEActionDetail(@"Paste Token from Clipboard",
                                                  @"Paste OAuth token or verification URL copied from browser.",
                                                  ^(UIViewController *c) {
            NSString *clip = [UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *token = [YTKACEVOTClient cleanOAuthToken:clip];
            if (token.length > 0) {
                [YTKACEVOTClient validateAndSaveToken:token completion:^(BOOL success, NSString *login, NSString *errorMessage) {
                    if (success) {
                        YTKACEShowNotice([NSString stringWithFormat:YTKACELocalized(@"Logged in as %@"), login]);
                        if ([c isKindOfClass:[YTKACEOptionsController class]]) {
                            NSDictionary *def = YTKACEVOTDefinition();
                            [(YTKACEOptionsController *)c replaceSections:def[@"sections"] sectionTitles:def[@"headers"]];
                        }
                    } else {
                        YTKACEShowNotice(errorMessage ?: YTKACELocalized(@"Invalid Yandex token"));
                    }
                }];
            } else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKACELocalized(@"Enter Yandex Token")
                                                                               message:YTKACELocalized(@"Paste your OAuth token or verification URL from Yandex.")
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
                    textField.placeholder = @"y0_AgAAAA...";
                    if (clip.length > 0) {
                        textField.text = clip;
                    }
                }];
                [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Save") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    (void)action;
                    NSString *entered = alert.textFields.firstObject.text;
                    NSString *extracted = [YTKACEVOTClient cleanOAuthToken:entered];
                    if (extracted.length == 0) {
                        YTKACEShowNotice(YTKACELocalized(@"Empty token"));
                        return;
                    }
                    [YTKACEVOTClient validateAndSaveToken:extracted completion:^(BOOL success, NSString *login, NSString *errorMessage) {
                        if (success) {
                            YTKACEShowNotice([NSString stringWithFormat:YTKACELocalized(@"Logged in as %@"), login]);
                            if ([c isKindOfClass:[YTKACEOptionsController class]]) {
                                NSDictionary *def = YTKACEVOTDefinition();
                                [(YTKACEOptionsController *)c replaceSections:def[@"sections"] sectionTitles:def[@"headers"]];
                            }
                        } else {
                            YTKACEShowNotice(errorMessage ?: YTKACELocalized(@"Invalid Yandex token"));
                        }
                    }];
                }]];
                [c presentViewController:alert animated:YES completion:nil];
            }
        })];
    }

    return YTKACEPageDefinition(@"vot", @"Voice-Over Translation", @[
        @[
            YTKACEToggleDetail(@"Voice-Over Translation",
                               @"Translate foreign videos with Russian neural voice-over.",
                               @"YTKACE.Preference.VOT.Enabled"),
            YTKACEToggleDetail(@"Auto-translate",
                               @"Automatically start translation for foreign videos.",
                               @"YTKACE.Preference.VOT.AutoTranslate")
        ],
        accountRows,
        @[
            YTKACESegmentedStacked(@"Voice Type",
                                   @"YTKACE.Preference.VOT.VoiceType",
                                   @[@"Standard Voices", @"Live Voices"],
                                   @[@"standard", @"live"],
                                   0)
        ],
        @[
            YTKACESegmentedStacked(@"Target Language",
                                   @"YTKACE.Preference.VOT.TargetLanguage",
                                   @[@"Russian", @"English", @"Kazakh"],
                                   @[@"ru", @"en", @"kk"],
                                   0)
        ],
        @[
            YTKACESegmentedStacked(@"Button Placement",
                                   @"YTKACE.Preference.VOT.Placement",
                                   @[@"Player Overlay", @"Settings Menu", @"Both"],
                                   @[@0, @1, @2],
                                   0)
        ],
        @[
            YTKACEToggleDetail(@"Smart Adaptive Volume",
                               @"Automatically restore video volume when translation voice is silent.",
                               @"YTKACE.Preference.VOT.AdaptiveVolume"),
            YTKACEPercentSlider(@"Original Video Volume",
                                @"YTKACE.Preference.VOT.BackgroundVolume",
                                0.0, 100.0, 5.0, 20.0),
            YTKACEPercentSlider(@"Translation Volume",
                                @"YTKACE.Preference.VOT.TranslationVolume",
                                0.0, 100.0, 5.0, 100.0)
        ],
        @[
            YTKACEActionDetail(@"Export Translation Log",
                               @"Save or share the diagnostic log of translation and player events.",
                               shareVOTLog),
            YTKACEActionDetail(@"Clear Translation Log",
                               @"Delete all recorded translation logs.",
                               clearVOTLog)
        ]
    ], @[
        YTKACELocalized(@"GENERAL"),
        YTKACELocalized(@"YANDEX ACCOUNT"),
        YTKACELocalized(@"VOICE TYPE"),
        YTKACELocalized(@"TARGET LANGUAGE"),
        YTKACELocalized(@"BUTTON PLACEMENT"),
        YTKACELocalized(@"VOLUME SETTINGS"),
        YTKACELocalized(@"DIAGNOSTICS")
    ]);
}

UIViewController *YTKACEMakeVOTController(void) { return YTKACEMakeSettingsPage(@"vot"); }
UIViewController *YTKACEMakeSponsorBlockController(void) { return YTKACEMakeSettingsPage(@"sponsorblock"); }
UIViewController *YTKACEMakePlayerControlsController(void) { return YTKACEMakeSettingsPage(@"player"); }
UIViewController *YTKACEMakeOverlayOptionsController(void) { return YTKACEMakeSettingsPage(@"watch"); }
UIViewController *YTKACEMakeStreamingOptionsController(void) { return YTKACEMakeSettingsPage(@"quality"); }
UIViewController *YTKACEMakeNavigationOptionsController(void) { return YTKACEMakeSettingsPage(@"topbar"); }
UIViewController *YTKACEMakeGlassOptionsController(void) { return YTKACEMakeSettingsPage(@"glass"); }
UIViewController *YTKACEMakeShortsOptionsController(void) { return YTKACEMakeSettingsPage(@"shorts"); }
UIViewController *YTKACEMakeMiscOptionsController(void) { return YTKACEMakeSettingsPage(@"general"); }
UIViewController *YTKACEMakeGestureOptionsController(void) { return YTKACEMakeSettingsPage(@"gestures"); }

NSArray<NSDictionary *> *YTKACEAllPageDefinitions(void) {
    NSMutableArray *pages = [NSMutableArray array];
    for (NSDictionary *section in YTKACESettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            NSDictionary *definition = YTKACEDefinitionForPage(row[@"id"]);
            if (definition != nil) [pages addObject:definition];
        }
    }
    [pages addObject:YTKACEPageDefinition(@"tabs", @"Tabs", @[
        @[
            YTKACEToggle(@"Hide Tab Labels", @"YTKACE.Preference.Tabs.LabelsHidden", @"", @""),
            YTKACEToggle(@"Don't Open App in Shorts", @"YTKACE.Preference.Shorts.PreventAutoOpen", @"", @""),
            YTKACEPicker(@"Frosted Tab Bar", @"YTKACE.Preference.Tabs.Frosted",
                         @[@"Default", @"On", @"Off"], @[@0, @1, @2], 0, @"", @""),
            YTKACEPicker(@"Selected Tab Color", @"YTKACE.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            YTKACEColor(@"Color", @"YTKACE.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[YTKACELocalized(@"MAIN")])];
    return pages;
}

UIViewController *YTKACEMakeCreditsController(void) {
    UILabel *label = [UILabel new];
    label.text = YTKACELocalized(@"YTKACE\nClean-room implementation\nMIT licensed code\nBuilt by Epic");
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    UIViewController *controller = [UIViewController new];
    controller.title = YTKACELocalized(@"Credits");
    controller.view.backgroundColor = YTKACESettingsBackground();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-24.0]
    ]];
    return controller;
}
