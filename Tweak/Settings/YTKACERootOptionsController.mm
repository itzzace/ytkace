#import "YTKACERootOptionsController.h"
#import "../YTKACE.h"
#import "YTKACEDownloadsController.h"
#import "YTKACESettingsPages.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../Features/Downloads/DownloadLog.h"

#import <objc/runtime.h>
#import <sys/utsname.h>

static UIColor *YTKACERootBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceBackgroundColor(traits);
    }];
}

static UIColor *YTKACERootCellBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceBackgroundColor(traits);
    }];
}

static UIImage *YTKACETemplateImage(NSString *asset, NSString *symbol) {
    return [YTKACEAssetImage(asset, symbol)
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *YTKACESponsorIcon(void) {
    return YTKACETemplateImage(@"sponsorblock_shield_template",
                               @"play.shield");
}

static UIImage *YTKACEShortsIcon(void) {
    return [YTKACEShortsImage(NO)
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static const void *YTKACEDismissTargetKey = &YTKACEDismissTargetKey;

@interface YTKACEDismissTarget : NSObject
@property(nonatomic, weak) UIViewController *controller;
- (void)dismiss;
- (void)pop;
@end

@implementation YTKACEDismissTarget
- (void)dismiss {
    [self.controller dismissViewControllerAnimated:YES completion:nil];
}
- (void)pop {
    [self.controller.navigationController popViewControllerAnimated:YES];
}
@end

static const void *YTKACEOwnedNavigationKey = &YTKACEOwnedNavigationKey;

BOOL YTKACEOwnsNavigationController(UINavigationController *navigation) {
    if (navigation == nil) return NO;
    return [objc_getAssociatedObject(navigation, YTKACEOwnedNavigationKey) boolValue];
}

void YTKACEApplyAppearance(UIViewController *controller) {
    controller.view.backgroundColor = YTKACERootBackground();
    controller.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    UINavigationController *navigation = controller.navigationController;
    if (!YTKACEOwnsNavigationController(navigation)) {
        if (navigation != nil &&
            controller.navigationItem.leftBarButtonItem == nil &&
            navigation.viewControllers.firstObject != controller) {
            YTKACEDismissTarget *target = [YTKACEDismissTarget new];
            target.controller = controller;
            objc_setAssociatedObject(controller, YTKACEDismissTargetKey, target,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIImageSymbolConfiguration *symbolConfiguration =
                [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                  weight:UIImageSymbolWeightSemibold];
            UIImage *chevron =
                [UIImage systemImageNamed:@"chevron.backward"
                        withConfiguration:symbolConfiguration];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            UIButtonConfiguration *configuration =
                [UIButtonConfiguration plainButtonConfiguration];
            configuration.image = chevron;
            configuration.title = YTKACELocalized(@"Back");
            configuration.imagePadding = 4.0;
            configuration.contentInsets =
                NSDirectionalEdgeInsetsMake(0.0, 8.0, 0.0, 4.0);
            button.configuration = configuration;
            [button addTarget:target action:@selector(pop)
                forControlEvents:UIControlEventTouchUpInside];
            UIBarButtonItem *back =
                [[UIBarButtonItem alloc] initWithCustomView:button];
            controller.navigationItem.leftBarButtonItem = back;
            controller.navigationItem.hidesBackButton = YES;
        }
        return;
    }
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = YTKACERootBackground();
        appearance.titleTextAttributes = @{
            NSForegroundColorAttributeName: UIColor.labelColor
        };
        navigation.navigationBar.standardAppearance = appearance;
        navigation.navigationBar.scrollEdgeAppearance = appearance;
        navigation.navigationBar.compactAppearance = appearance;
    }
}

@interface YTKACEDownloadLogController : UIViewController
@property(nonatomic, strong) UITextView *textView;
@end

@implementation YTKACEDownloadLogController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTKACELocalized(@"Download Log");
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:13.0
        weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(14.0, 14.0, 14.0, 14.0);
    [self.view addSubview:self.textView];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:YTKACELocalized(@"Clear") style:UIBarButtonItemStylePlain
            target:self action:@selector(clearLog)],
        [[UIBarButtonItem alloc] initWithTitle:YTKACELocalized(@"Share") style:UIBarButtonItemStylePlain
            target:self action:@selector(shareLog)],
        [[UIBarButtonItem alloc] initWithTitle:YTKACELocalized(@"Copy") style:UIBarButtonItemStylePlain
            target:self action:@selector(copyLog)]
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    YTKACEApplyAppearance(self);
    self.textView.backgroundColor = YTKACERootBackground();
    self.textView.textColor = UIColor.labelColor;
    self.textView.text = YTKACEDownloadLogContents();
    NSRange end = NSMakeRange(self.textView.text.length, 0);
    [self.textView scrollRangeToVisible:end];
}

- (void)shareLog {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:@"ytkace-download.log"]];
    NSError *error = nil;
    if (![self.textView.text writeToURL:url atomically:YES
                               encoding:NSUTF8StringEncoding error:&error]) {
        YTKACEShowNotice(YTKACELocalized(@"Could not prepare the log"));
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItems.count > 1
            ? self.navigationItem.rightBarButtonItems[1]
            : self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string = self.textView.text;
    YTKACEShowNotice(YTKACELocalized(@"Download log copied"));
}

- (void)clearLog {
    YTKACEClearDownloadLog();
    self.textView.text = YTKACEDownloadLogContents();
}

@end

NSString *YTKACEDeviceInformationText(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *model = [NSString stringWithUTF8String:systemInfo.machine] ?: @"iOS Device";
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *youtubeVersion = info[@"CFBundleShortVersionString"] ?: @"Unknown";
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.google.ios.youtube";
    return [NSString stringWithFormat:@"YTKACE %@  •  YouTube %@\n%@\n%@  •  iOS %@",
        YTKACEVersion, youtubeVersion, bundleID, model,
        UIDevice.currentDevice.systemVersion];
}

UIViewController *YTKACEMakeDownloadLogController(void) {
    return [YTKACEDownloadLogController new];
}

@interface YTKACERootOptionsController ()
@property(nonatomic, strong) UIView *settingsHeader;
@end

@implementation YTKACERootOptionsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.sectionHeaderHeight = 22.0;
    self.tableView.sectionFooterHeight = 6.0;
    self.settingsHeader = [self makeSettingsHeader];
    self.tableView.tableHeaderView = self.settingsHeader;
    UILongPressGestureRecognizer *developerHold =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleDeveloperHold:)];
    developerHold.minimumPressDuration = 3.0;
    developerHold.cancelsTouchesInView = YES;
    [self.tableView addGestureRecognizer:developerHold];
}

- (void)showDownloadLog {
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    [self.navigationController pushViewController:
        [YTKACEDownloadLogController new] animated:YES];
}

- (void)handleDeveloperHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:
        [recognizer locationInView:self.tableView]];
    if (indexPath.section == 4 && indexPath.row == 0) {
        [self showDownloadLog];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACERootBackground();
    self.settingsHeader.backgroundColor = YTKACERootBackground();
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat difference = CGRectGetWidth(self.settingsHeader.frame) - width;
    difference = difference < 0.0 ? -difference : difference;
    if (width > 0.0 && difference > 0.5) {
        CGRect frame = self.settingsHeader.frame;
        frame.size.width = width;
        self.settingsHeader.frame = frame;
        self.tableView.tableHeaderView = self.settingsHeader;
    }
}

- (UIView *)makeSettingsHeader {
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0.0) {
        width = CGRectGetWidth(self.view.bounds);
    }
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 122.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(8.0, 8.0, 40.0, 40.0);
    [close setImage:YTKACETemplateImage(@"", @"xmark")
            forState:UIControlStateNormal];
    close.tintColor = UIColor.labelColor;
    close.accessibilityLabel = YTKACELocalized(@"Close");
    [close addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(width - 48.0, 8.0, 40.0, 40.0);
    apply.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [apply setImage:YTKACETemplateImage(@"", @"checkmark")
            forState:UIControlStateNormal];
    apply.tintColor = UIColor.labelColor;
    apply.accessibilityLabel = YTKACELocalized(@"Apply Settings");
    [apply addTarget:self action:@selector(applySettings) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:apply];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(56.0, 55.0, width - 112.0, 34.0)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"YTKACE";
    title.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = UIColor.labelColor;
    [header addSubview:title];

    UILabel *version = [[UILabel alloc] initWithFrame:CGRectMake(56.0, 89.0, width - 112.0, 20.0)];
    version.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    version.text = [NSString stringWithFormat:@"v%@", YTKACEVersion];
    version.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    version.textAlignment = NSTextAlignmentCenter;
    version.textColor = UIColor.secondaryLabelColor;
    [header addSubview:version];

    return header;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return 1;
        case 1: return 4;
        case 2: return 5;
        case 3: return 2;
        case 4: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[@"", YTKACELocalized(@"MAIN"), YTKACELocalized(@"VIDEO"),
             YTKACELocalized(@"APP"), YTKACELocalized(@"ABOUT")][(NSUInteger)section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}

- (NSString *)deviceInformationText {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *model = [NSString stringWithUTF8String:systemInfo.machine] ?: YTKACELocalized(@"iOS Device");
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *youtubeVersion = info[@"CFBundleShortVersionString"] ?: YTKACELocalized(@"Unknown");
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.google.ios.youtube";
    return [NSString stringWithFormat:YTKACELocalized(@"YTKACE %@  •  YouTube %@\n%@\n%@  •  iOS %@"),
        YTKACEVersion, youtubeVersion, bundleID, model,
        UIDevice.currentDevice.systemVersion];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 0) return 68.0;
    if (indexPath.section == 4 && indexPath.row == 1) {
        return 92.0;
    }
    return 62.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 1.0 : 30.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 40.0 : 8.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0,
        CGRectGetWidth(tableView.bounds), 40.0)];
    footer.backgroundColor = YTKACERootBackground();
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24.0, 0.0,
        MAX(0.0, CGRectGetWidth(tableView.bounds) - 48.0), 18.0)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.text = YTKACELocalized(@"Save your changes with the checkmark above.");
    label.font = [UIFont systemFontOfSize:13.0];
    label.textColor = UIColor.secondaryLabelColor;
    [footer addSubview:label];
    return footer;
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView
                                    style:(UITableViewCellStyle)style {
    NSString *identifier = [NSString stringWithFormat:@"YTKACERoot-%ld", (long)style];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    }
    cell.backgroundColor = YTKACERootCellBackground();
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = UIColor.labelColor;
    cell.imageView.image = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)configureImageForCell:(UITableViewCell *)cell
                         asset:(NSString *)asset
                         symbol:(NSString *)symbol {
    cell.imageView.image = YTKACETemplateImage(asset, symbol);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleSubtitle];
        cell.textLabel.text = YTKACELocalized(@"Enabled");
        cell.textLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = nil;
        [self configureImageForCell:cell asset:@"" symbol:@"power"];
        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 72.0, 28.0)];
        status.text = YTKACELocalized(@"ACTIVE");
        status.textAlignment = NSTextAlignmentCenter;
        status.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        status.textColor = UIColor.systemGreenColor;
        status.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.14];
        status.layer.cornerRadius = 14.0;
        status.layer.masksToBounds = YES;
        cell.accessoryView = status;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 1) {
        NSArray *titles = @[YTKACELocalized(@"Player"), YTKACELocalized(@"SponsorBlock"),
                            YTKACELocalized(@"Tabs"), YTKACELocalized(@"Gestures")];
        NSArray *details = @[
            YTKACELocalized(@"Downloads, PiP, speed, loop, and background audio"),
            YTKACELocalized(@"Skip or mark sponsored segments"),
            YTKACELocalized(@"Choose, reorder, and rename tabs"),
            YTKACELocalized(@"Brightness, volume, and seeking")
        ];
        NSArray *symbols = @[@"play.rectangle", @"play.shield",
                             @"rectangle.bottomthird.inset.filled", @"hand.draw"];
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleSubtitle];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.detailTextLabel.text = details[(NSUInteger)indexPath.row];
        [self configureImageForCell:cell asset:@"" symbol:symbols[(NSUInteger)indexPath.row]];
        if (indexPath.row == 1) cell.imageView.image = YTKACESponsorIcon();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 2) {
        NSArray *titles = @[YTKACELocalized(@"Overlay"), YTKACELocalized(@"Playback"),
                            YTKACELocalized(@"Shorts"), YTKACELocalized(@"Wi-Fi Quality"),
                            YTKACELocalized(@"Cellular Quality")];
        NSArray *details = @[
            YTKACELocalized(@"Player controls and visibility"),
            YTKACELocalized(@"Quality, autoplay, and skip settings"),
            YTKACELocalized(@"Buttons, downloads, and feed options"),
            YTKACELocalized(@"Preferred quality on Wi-Fi"),
            YTKACELocalized(@"Preferred quality on mobile data")
        ];
        NSArray *symbols = @[@"rectangle.on.rectangle", @"playpause",
                             @"", @"wifi", @"antenna.radiowaves.left.and.right"];
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleSubtitle];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.detailTextLabel.text = details[(NSUInteger)indexPath.row];
        if (indexPath.row == 2) {
            cell.imageView.image = YTKACEShortsIcon();
        } else {
            [self configureImageForCell:cell asset:@"" symbol:symbols[(NSUInteger)indexPath.row]];
        }
        BOOL quality = indexPath.row >= 3;
        if (!quality) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            NSString *key = indexPath.row == 3 ? @"YTKACE.Preference.Playback.WiFiQuality" : @"YTKACE.Preference.Playback.CellularQuality";
            NSArray *options = @[YTKACELocalized(@"Auto"), @"2160p60", @"2160p", @"1440p60", @"1440p",
                                 @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
                                 @"360p", @"240p", @"144p"];
            NSArray *values = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
            UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 66.0, 28.0)];
            value.text = YTKACEPickerSummary(key, options, values, 0);
            value.textAlignment = NSTextAlignmentRight;
            value.font = [UIFont systemFontOfSize:15.0];
            value.textColor = YTKACEAccentColor();
            cell.accessoryView = value;
        }
        return cell;
    }

    if (indexPath.section == 3) {
        NSArray *titles = @[YTKACELocalized(@"Navigation"), YTKACELocalized(@"Other")];
        NSArray *details = @[
            YTKACELocalized(@"Top bar buttons, logo, and cast"),
            YTKACELocalized(@"Appearance, privacy, and compatibility")
        ];
        NSArray *symbols = @[@"rectangle.topthird.inset.filled", @"ellipsis.circle"];
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleSubtitle];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.detailTextLabel.text = details[(NSUInteger)indexPath.row];
        [self configureImageForCell:cell asset:@"" symbol:symbols[(NSUInteger)indexPath.row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.row == 1) {
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleDefault];
        cell.textLabel.text = [self deviceInformationText];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 3;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleValue1];
    cell.textLabel.text = YTKACELocalized(@"itzzace");
    cell.detailTextLabel.text = @"YTKACE";
    cell.imageView.image = YTKACEAssetImage(@"YTKIco", @"person.crop.circle");
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 4 && indexPath.row == 0) {
        NSURL *URL = [NSURL URLWithString:@"https://github.com/itzzace/ytkace"];
        [UIApplication.sharedApplication openURL:URL options:@{}
                               completionHandler:nil];
        return;
    }
    UIViewController *controller = nil;
    if (indexPath.section == 2 && (indexPath.row == 3 || indexPath.row == 4)) {
            NSString *title = indexPath.row == 3 ? YTKACELocalized(@"Wi-Fi Quality") : YTKACELocalized(@"Cellular Quality");
            NSString *key = indexPath.row == 3 ? @"YTKACE.Preference.Playback.WiFiQuality" : @"YTKACE.Preference.Playback.CellularQuality";
            NSArray *titles = @[YTKACELocalized(@"Auto"), @"2160p60", @"2160p", @"1440p60", @"1440p",
                                @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
                                @"360p", @"240p", @"144p"];
            NSArray *values = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            YTKACEPresentChoiceMenu(self, cell, title, titles, values, key, 0,
                ^(__unused NSUInteger position) {
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                          withRowAnimation:UITableViewRowAnimationNone];
                });
            return;
    }
    if (indexPath.section == 1) {
        NSArray *builders = @[
            [^UIViewController *{ return YTKACEMakePlayerControlsController(); } copy],
            [^UIViewController *{ return YTKACEMakeSponsorBlockController(); } copy],
            [^UIViewController *{ return YTKACEMakeTabBarOptionsController(); } copy],
            [^UIViewController *{ return YTKACEMakeGestureOptionsController(); } copy]
        ];
        UIViewController *(^builder)(void) = builders[(NSUInteger)indexPath.row];
        controller = builder();
    } else if (indexPath.section == 2) {
        NSArray *builders = @[
            [^UIViewController *{ return YTKACEMakeOverlayOptionsController(); } copy],
            [^UIViewController *{ return YTKACEMakeStreamingOptionsController(); } copy],
            [^UIViewController *{ return YTKACEMakeShortsOptionsController(); } copy],
            [^UIViewController *{ return nil; } copy],
            [^UIViewController *{ return nil; } copy]
        ];
        UIViewController *(^builder)(void) = builders[(NSUInteger)indexPath.row];
        controller = builder();
    } else if (indexPath.section == 3) {
        NSArray *builders = @[
            [^UIViewController *{ return YTKACEMakeNavigationOptionsController(); } copy],
            [^UIViewController *{ return YTKACEMakeMiscOptionsController(); } copy]
        ];
        UIViewController *(^builder)(void) = builders[(NSUInteger)indexPath.row];
        controller = builder();
    }
    if (controller != nil) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
        [self.navigationController pushViewController:controller animated:YES];
    }
}

- (void)masterChanged:(UISwitch *)sender {
    (void)sender;
    YTKACESetPreference(YTKACEMasterEnabledKey, YES);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                 withRowAnimation:UITableViewRowAnimationNone];
}

- (void)applySettings {
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:YTKACEPreferencesDidChangeNotification
                                                      object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"YTKACETabConfigDidChange"
                                                      object:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

UINavigationController *YTKACEMakeSettingsNavigationController(void) {
    YTKACERootOptionsController *root = [YTKACERootOptionsController new];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:root];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    objc_setAssociatedObject(navigation, YTKACEOwnedNavigationKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return navigation;
}
