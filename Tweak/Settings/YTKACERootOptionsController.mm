#import "YTKACERootOptionsController.h"
#import "../YTKACE.h"
#import "YTKACEDownloadsController.h"
#import "YTKACESettingsPages.h"
#import "YTKACESettingsSearch.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../Features/Downloads/DownloadLog.h"
#import "DuoKit.h"

#import <objc/runtime.h>
#import <stdlib.h>
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
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"" style:UIBarButtonItemStylePlain target:self action:@selector(toggleDebugLogs)];
    [self updateDebugButton];
}

- (void)updateDebugButton {
    self.navigationItem.leftBarButtonItem.title = YTKACEDebugLogsEnabled()
        ? YTKACELocalized(@"Debug: On") : YTKACELocalized(@"Debug: Off");
}

- (void)toggleDebugLogs {
    BOOL enabled = !YTKACEDebugLogsEnabled();
    YTKACESetDebugLogsEnabled(enabled);
    YTKACEDownloadLog(@"debug", @"debug logs %@", enabled ? @"on" : @"off");
    [self updateDebugButton];
    YTKACEShowNotice(enabled ? YTKACELocalized(@"Debug logs on") : YTKACELocalized(@"Debug logs off"));
    self.textView.text = YTKACEDownloadLogContents();
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
    <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate,
     UIGestureRecognizerDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, assign) CGFloat headerTop;
@property(nonatomic, assign) BOOL headerTopLocked;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIButton *applyButton;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, assign) BOOL listUsesBarColumn;
@property(nonatomic, strong) UIView *settingsHeader;
@property(nonatomic, strong) UITextField *searchField;
@property(nonatomic, strong) UIView *searchPill;
@property(nonatomic, strong) NSArray<NSDictionary *> *searchResults;
@property(nonatomic, strong) UIViewController *searchChild;
@end

@implementation YTKACERootOptionsController

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.sectionHeaderHeight = 22.0;
    self.tableView.sectionFooterHeight = 6.0;
    self.tableView.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [self.view addGestureRecognizer:dismissTap];
    self.settingsHeader = [self makeSettingsHeader];
    [self.view addSubview:self.settingsHeader];
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
    if (indexPath.section == (NSInteger)YTKACESettingsMenu().count && indexPath.row == 0) {
        [self showDownloadLog];
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    if (self.searchField.isFirstResponder) return;
    self.headerTopLocked = NO;
    [self.view setNeedsLayout];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACERootBackground();
    self.settingsHeader.backgroundColor = YTKACERootBackground();
    [self.tableView reloadData];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    const CGFloat width = CGRectGetWidth(self.view.bounds);
    if (width <= 0.0) return;
    if (!self.headerTopLocked) {
        self.headerTop = self.view.safeAreaInsets.top;
        if (self.headerTop > 0.0) self.headerTopLocked = YES;
    }
    const CGFloat top = self.headerTop;
    // Keep the header inside the safe area: beside the iPhone Duo's vertical
    // bar the right inset covers the clock and camera column.
    const BOOL duo = DUOIsDuo();
    const UIEdgeInsets safe = self.view.safeAreaInsets;
    const CGFloat left = duo ? safe.left : 0.0;
    const CGFloat right = duo ? safe.right : 0.0;
    // With no status bar above it (the Duo's status bar is vertical) the header
    // starts at the screen's top edge, so the buttons need more room from the
    // rounded corners.
    const CGFloat inset = duo && top < 1.0 ? 16.0 : 8.0;
    self.settingsHeader.frame = CGRectMake(0.0, top, width, 170.0);
    self.closeButton.frame = CGRectMake(left + inset, inset, 40.0, 40.0);
    self.applyButton.frame = CGRectMake(width - right - inset - 40.0, inset, 40.0, 40.0);
    const CGFloat textWidth = MAX(0.0, width - left - right - 112.0);
    self.titleLabel.frame = CGRectMake(left + 56.0, 55.0, textWidth, 34.0);
    self.versionLabel.frame = CGRectMake(left + 56.0, 89.0, textWidth, 20.0);
    self.searchPill.frame = CGRectMake(left + 20.0, 120.0,
                                       MAX(0.0, width - left - right - 40.0), 38.0);
    self.searchField.frame = CGRectMake(42.0, 0.0,
        MAX(0.0, CGRectGetWidth(self.searchPill.bounds) - 54.0), 38.0);
    const CGFloat contentTop = top + 170.0;
    const CGFloat contentHeight =
        MAX(0.0, CGRectGetHeight(self.view.bounds) - contentTop);
    const CGFloat listTrailing = duo
        ? DUOListTrailingInsetBesideVerticalBar(self.view, contentTop) : 0.0;
    // Rows normally keep out of the safe area; when the list may use the
    // vertical bar's column, its frame stops at the bar region instead.
    self.tableView.frame = CGRectMake(0.0, contentTop,
                                      width - listTrailing, contentHeight);
    const BOOL usesColumn = listTrailing > 0.0;
    if (usesColumn != self.listUsesBarColumn) {
        self.listUsesBarColumn = usesColumn;
        self.tableView.insetsContentViewsToSafeArea = !usesColumn;
        // Rows take their margins from the list, which adds its safe area.
        self.tableView.insetsLayoutMarginsFromSafeArea = !usesColumn;
        for (UITableViewCell *cell in self.tableView.visibleCells) {
            cell.insetsLayoutMarginsFromSafeArea = !usesColumn;
        }
    }
    [self layoutSearchResults];
}

- (void)layoutSearchResults {
    if (self.searchChild == nil) return;
    self.searchChild.view.frame = self.tableView.frame;
}

- (UIView *)makeSettingsHeader {
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0.0) {
        width = CGRectGetWidth(self.view.bounds);
    }
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 170.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(8.0, 8.0, 40.0, 40.0);
    [close setImage:YTKACETemplateImage(@"", @"xmark")
            forState:UIControlStateNormal];
    close.tintColor = UIColor.labelColor;
    close.accessibilityLabel = YTKACELocalized(@"Close");
    [close addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];
    self.closeButton = close;

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(width - 48.0, 8.0, 40.0, 40.0);
    apply.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [apply setImage:YTKACETemplateImage(@"", @"checkmark")
            forState:UIControlStateNormal];
    apply.tintColor = UIColor.labelColor;
    apply.accessibilityLabel = YTKACELocalized(@"Apply Settings");
    [apply addTarget:self action:@selector(applySettings) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:apply];
    self.applyButton = apply;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(56.0, 55.0, width - 112.0, 34.0)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"YTKACE";
    title.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = UIColor.labelColor;
    [header addSubview:title];
    self.titleLabel = title;

    UILabel *version = [[UILabel alloc] initWithFrame:CGRectMake(56.0, 89.0, width - 112.0, 20.0)];
    version.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    version.text = [NSString stringWithFormat:@"v%@", YTKACEVersion];
    version.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    version.textAlignment = NSTextAlignmentCenter;
    version.textColor = UIColor.secondaryLabelColor;
    [header addSubview:version];
    self.versionLabel = version;

    UIView *pill = [[UIView alloc]
        initWithFrame:CGRectMake(20.0, 120.0, MAX(0.0, width - 40.0), 38.0)];
    pill.backgroundColor = UIColor.secondarySystemFillColor;
    pill.layer.cornerRadius = 19.0;
    pill.clipsToBounds = YES;
    UIView *pillGlass = YTKACEMakeSettingsGlass();
    if (pillGlass != nil) {
        pillGlass.frame = pill.bounds;
        pillGlass.layer.cornerRadius = 19.0;
        [pill addSubview:pillGlass];
        pill.backgroundColor = UIColor.clearColor;
    }

    UIImageView *glass = [[UIImageView alloc]
        initWithImage:YTKACETemplateImage(@"", @"magnifyingglass")];
    glass.frame = CGRectMake(14.0, 10.0, 18.0, 18.0);
    glass.contentMode = UIViewContentModeScaleAspectFit;
    glass.tintColor = UIColor.secondaryLabelColor;
    [pill addSubview:glass];

    UITextField *search = [[UITextField alloc]
        initWithFrame:CGRectMake(42.0, 0.0,
                                 MAX(0.0, CGRectGetWidth(pill.bounds) - 54.0),
                                 38.0)];
    search.placeholder = YTKACELocalized(@"Search settings");
    search.font = [UIFont systemFontOfSize:16.0];
    search.textColor = UIColor.labelColor;
    search.clearButtonMode = UITextFieldViewModeWhileEditing;
    search.returnKeyType = UIReturnKeyDone;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.tintColor = YTKACEAccentColor();
    search.delegate = self;
    [search addTarget:self action:@selector(dismissKeyboard)
     forControlEvents:UIControlEventEditingDidEndOnExit];
    [search addTarget:self action:@selector(searchTextChanged:)
     forControlEvents:UIControlEventEditingChanged];
    [pill addSubview:search];
    self.searchField = search;
    self.searchPill = pill;
    [header addSubview:pill];

    return header;
}

- (void)dismissKeyboard {
    [self.searchField resignFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    if (!self.searchField.isFirstResponder) return NO;
    return ![touch.view isDescendantOfView:self.searchPill];
}

- (void)searchTextChanged:(UITextField *)field {
    NSString *query = [field.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    if (query.length == 0) {
        self.searchResults = nil;
        [self.searchChild willMoveToParentViewController:nil];
        [self.searchChild.view removeFromSuperview];
        [self.searchChild removeFromParentViewController];
        self.searchChild = nil;
        self.tableView.hidden = NO;
        [self.tableView reloadData];
        return;
    }
    self.searchResults = YTKACEFilterSettings(query);
    NSArray<NSString *> *titles = @[];
    NSArray *sections = YTKACESearchResultSections(query, &titles);
    if (self.searchChild == nil) {
        UIViewController *child =
            YTKACEMakeSettingsResultsController(sections, titles);
        [self addChildViewController:child];
        [self.view addSubview:child.view];
        [child didMoveToParentViewController:self];
        [self.navigationController setNavigationBarHidden:YES animated:NO];
        self.searchChild = child;
        if ([child isKindOfClass:UITableViewController.class]) {
            UITableView *inner = ((UITableViewController *)child).tableView;
            inner.contentInsetAdjustmentBehavior =
                UIScrollViewContentInsetAdjustmentNever;
            inner.keyboardDismissMode =
                UIScrollViewKeyboardDismissModeOnDrag;
        }
        self.tableView.hidden = YES;
        [self.tableView reloadData];
    } else {
        YTKACEUpdateSettingsResultsController(self.searchChild, sections, titles);
    }
    [self layoutSearchResults];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.searchResults != nil ? 0 : (NSInteger)YTKACESettingsMenu().count + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.searchResults != nil) {
        return self.searchResults.count == 0 ? 1 : (NSInteger)self.searchResults.count;
    }
    NSArray *menu = YTKACESettingsMenu();
    if (section < (NSInteger)menu.count) return (NSInteger)[menu[(NSUInteger)section][@"rows"] count];
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (self.searchResults != nil) {
        return self.searchResults.count == 0 ? @"" : YTKACELocalized(@"RESULTS");
    }
    NSArray *menu = YTKACESettingsMenu();
    if (section < (NSInteger)menu.count) return YTKACELocalized(menu[(NSUInteger)section][@"header"]);
    return YTKACELocalized(@"ABOUT");
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
    if (self.searchResults != nil) return 62.0;
    if (indexPath.section == (NSInteger)YTKACESettingsMenu().count && indexPath.row == 1) {
        return 92.0;
    }
    return 62.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 30.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 8.0;
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView
                                    style:(UITableViewCellStyle)style {
    NSString *identifier = [NSString stringWithFormat:@"YTKACERoot-%ld", (long)style];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    }
    cell.backgroundColor = YTKACERootCellBackground();
    // Rows place their arrows by their own safe area; see viewDidLayoutSubviews.
    cell.insetsLayoutMarginsFromSafeArea = !self.listUsesBarColumn;
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
    if (self.searchResults != nil) {
        UITableViewCell *cell = [self baseCellForTableView:tableView
                                                     style:UITableViewCellStyleSubtitle];
        if (self.searchResults.count == 0) {
            cell.textLabel.text = YTKACELocalized(@"No matching settings");
            cell.textLabel.font = [UIFont systemFontOfSize:16.0];
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.detailTextLabel.text = nil;
            cell.imageView.image = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSDictionary *record = self.searchResults[(NSUInteger)indexPath.row];
        cell.textLabel.text = record[@"title"];
        NSString *header = record[@"header"];
        cell.detailTextLabel.text = header.length != 0
            ? [NSString stringWithFormat:@"%@ › %@", record[@"pageTitle"], header]
            : record[@"pageTitle"];
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSArray *menu = YTKACESettingsMenu();
    if (indexPath.section < (NSInteger)menu.count) {
        NSDictionary *row = menu[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
        UITableViewCell *cell = [self baseCellForTableView:tableView style:UITableViewCellStyleSubtitle];
        cell.textLabel.text = YTKACELocalized(row[@"title"]);
        cell.detailTextLabel.text = YTKACELocalized(row[@"detail"]);
        if ([row[@"symbol"] isEqualToString:@"sponsor"]) {
            cell.imageView.image = YTKACESponsorIcon();
        } else if ([row[@"symbol"] isEqualToString:@"shorts"]) {
            cell.imageView.image = YTKACEShortsIcon();
        } else {
            [self configureImageForCell:cell asset:@"" symbol:row[@"symbol"]];
        }
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
    if (self.searchResults != nil) {
        if (self.searchResults.count == 0) return;
        [self.searchField resignFirstResponder];
        YTKACEOpenSettingsRecord(self.searchResults[(NSUInteger)indexPath.row], self);
        return;
    }
    NSArray *menu = YTKACESettingsMenu();
    if (indexPath.section >= (NSInteger)menu.count) {
        if (indexPath.row != 0) return;
        NSURL *URL = [NSURL URLWithString:@"https://github.com/itzzace/ytkace"];
        [UIApplication.sharedApplication openURL:URL options:@{}
                               completionHandler:nil];
        return;
    }
    NSDictionary *row = menu[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    UIViewController *controller = YTKACEMakeSettingsPage(row[@"id"]);
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
    [NSNotificationCenter.defaultCenter postNotificationName:@"YTKACEPreferencesDidChange"
                                                      object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"YTKACETabConfigDidChange"
                                                      object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(0);
    });
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
