#import <PSHeader/Misc.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTToastResponderEvent.h>
#import <YouTubeHeader/YTSettingsCell.h>
#import <YouTubeHeader/YTAlertView.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#define TWEAK_VERSION 0.6.9
#define Prefix @"YTWKS"
#define _LOC(b, x) [b localizedStringForKey:x value:nil table:nil]
#define LOC(x) _LOC(tweakBundle, x)

static const NSInteger YTWKSSection = 'ytwk'; // For YouGroupSettings
static const NSInteger YTWKSFakeBrightnessMin = 7;
static const NSInteger YTWKSFakeBrightnessMax = 100;
static const NSInteger YTWKSFakeBrightnessDefault = 100;
static const NSInteger YTWKSFakeBrightnessSliderTag = 888888;
static const NSInteger YTWKSFakeBrightnessLabelTag = 888889;
static const NSInteger YTWKSFullscreenButtonSegmentTag = 888887;
static const NSInteger YTWKSFullscreenSwipeSegmentTag = 888886;
static const NSInteger YTWKSFakeBrightnessNightDefault = 30;
static const NSInteger YTWKSFakeBrightnessNightSliderTag = 888885;
static const NSInteger YTWKSFakeBrightnessNightLabelTag = 888884;
static const NSInteger YTWKSScheduleStartPickerTag = 888883;
static const NSInteger YTWKSScheduleEndPickerTag = 888882;
static const NSInteger YTWKSScheduleStartLabelTag = 888881;
static const NSInteger YTWKSScheduleEndLabelTag = 888880;
static const NSInteger YTWKSScheduleStartDefaultMinutes = 1320; // 22:00
static const NSInteger YTWKSScheduleEndDefaultMinutes = 360;    // 06:00

static NSInteger YTWKSFakeBrightnessPercent(NSUserDefaults *prefs) {
    if (![prefs objectForKey:@"fakeBrightness_percent"]) return YTWKSFakeBrightnessDefault;
    NSInteger percent = [prefs integerForKey:@"fakeBrightness_percent"];
    NSInteger clamped = percent;
    if (clamped < YTWKSFakeBrightnessMin) clamped = YTWKSFakeBrightnessMin;
    if (clamped > YTWKSFakeBrightnessMax) clamped = YTWKSFakeBrightnessMax;
    if (clamped != percent) { [prefs setInteger:clamped forKey:@"fakeBrightness_percent"]; [prefs synchronize]; }
    return clamped;
}

static NSInteger YTWKSFakeBrightnessNightPercent(NSUserDefaults *prefs) {
    if (![prefs objectForKey:@"fakeBrightness_night_percent"]) return YTWKSFakeBrightnessNightDefault;
    NSInteger percent = [prefs integerForKey:@"fakeBrightness_night_percent"];
    NSInteger clamped = percent;
    if (clamped < YTWKSFakeBrightnessMin) clamped = YTWKSFakeBrightnessMin;
    if (clamped > YTWKSFakeBrightnessMax) clamped = YTWKSFakeBrightnessMax;
    if (clamped != percent) { [prefs setInteger:clamped forKey:@"fakeBrightness_night_percent"]; [prefs synchronize]; }
    return clamped;
}

static void YTWKSUpdateFakeBrightnessLabel(UILabel *label, NSInteger percent) { label.text = [NSString stringWithFormat:@"%ld%%", (long)percent]; }

// Minutes-since-midnight helpers for the schedule time pickers
static NSInteger YTWKSMinutesFromDate(NSDate *date) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comps = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return comps.hour * 60 + comps.minute;
}

static NSDate *YTWKSDateFromMinutes(NSInteger minutes) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.hour = minutes / 60;
    comps.minute = minutes % 60;
    return [cal dateFromComponents:comps] ?: [NSDate date];
}

// Non-static: also called from Tweak.x (declared there via `extern`) to decide
// whether night-mode brightness should currently be applied. Handles the
// overnight wraparound case (e.g. 22:00 -> 06:00).
BOOL YTWKSMinutesInScheduleWindow(NSInteger nowMinutes, NSInteger startMinutes, NSInteger endMinutes) {
    if (startMinutes == endMinutes) return NO;
    if (startMinutes < endMinutes) {
        return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    }
    return nowMinutes >= startMinutes || nowMinutes < endMinutes;
}

@interface YTSettingsSectionItemManager (YTweaks) <UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL isImportingPreferences;
- (void)updateYTWKSSectionWithEntry:(id)entry;
- (void)exportPreferences;
- (void)importPreferences;
- (void)restoreDefaults;
@end

@interface YTSettingsCell (YTweaks)
- (BOOL)YTWKS_layoutFullscreenDirectionSegmentWithIdentifier:(NSString *)identifier
                                                         tag:(NSInteger)tag
                                                     prefKey:(NSString *)prefKey
                                                      action:(SEL)action;
- (void)YTWKS_layoutScheduledTimeRange;
- (void)fakeBrightnessSliderChanged:(UISlider *)sender;
- (void)fakeBrightnessNightSliderChanged:(UISlider *)sender;
- (void)scheduleStartTimeChanged:(UIDatePicker *)sender;
- (void)scheduleEndTimeChanged:(UIDatePicker *)sender;
- (void)fullscreenButtonModeSegmentChanged:(UISegmentedControl *)sender;
- (void)fullscreenSwipeModeSegmentChanged:(UISegmentedControl *)sender;
@end

NSUserDefaults *defaults;

NSBundle *YTWKSBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTWKS" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: PS_ROOT_PATH_NS(@"/Library/Application Support/" Prefix ".bundle")];
    });
    return bundle;
}

%hook YTSettingsGroupData

- (NSArray <NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks))) return %orig;
    NSArray *categories = %orig;
    NSMutableArray *mutableCategories = categories.mutableCopy;
    NSNumber *sectionNumber = @(YTWKSSection);
    if (![mutableCategories containsObject:sectionNumber]) { [mutableCategories insertObject:sectionNumber atIndex:0]; }
    return mutableCategories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray <NSNumber *> *order = %orig;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        NSMutableArray <NSNumber *> *mutableOrder = [order mutableCopy];
        NSNumber *sectionNumber = @(YTWKSSection);
        if (![mutableOrder containsObject:sectionNumber]) { [mutableOrder insertObject:sectionNumber atIndex:insertIndex + 1]; }
        order = mutableOrder.copy;
    }
    return order;
}

%end

%hook YTSettingsSectionItemManager

%new
- (void)setIsImportingPreferences:(BOOL)isImportingPreferences {
    objc_setAssociatedObject(self, @selector(isImportingPreferences), @(isImportingPreferences), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (BOOL)isImportingPreferences {
    return [objc_getAssociatedObject(self, @selector(isImportingPreferences)) boolValue];
}

%new(v@:@)
- (void)updateYTWKSSectionWithEntry:(id)entry {
    NSMutableArray *sectionItems = [NSMutableArray array];
    NSBundle *tweakBundle = YTWKSBundle();
    Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);

    // Fullscreen settings
    YTSettingsSectionItem *fullscreenButtonMode = [YTSettingsSectionItemClass itemWithTitle:LOC(@"FULLSCREEN_BUTTON_MODE")
        titleDescription:LOC(@"FULLSCREEN_BUTTON_MODE_DESC")
        accessibilityIdentifier:@"fullscreenButtonModeSegment"
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }];
    [sectionItems addObject:fullscreenButtonMode];

    YTSettingsSectionItem *fullscreenSwipeMode = [YTSettingsSectionItemClass itemWithTitle:LOC(@"FULLSCREEN_SWIPE_MODE")
        titleDescription:LOC(@"FULLSCREEN_SWIPE_MODE_DESC")
        accessibilityIdentifier:@"fullscreenSwipeModeSegment"
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:fullscreenSwipeMode];

    // A/B settings: Disable Floating Miniplayer
    BOOL isMiniplayerEnabled = [defaults objectForKey:@"enableIosFloatingMiniplayer"]
        ? [defaults boolForKey:@"enableIosFloatingMiniplayer"]
        : YES;
    YTSettingsSectionItem *disableFloatingMiniplayer = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"ENABLE_IOS_FLOATING_MINIPLAYER")
        titleDescription:LOC(@"ENABLE_IOS_FLOATING_MINIPLAYER_DESC")
        accessibilityIdentifier:nil
        switchOn:!isMiniplayerEnabled
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL disableMiniplayer) {
            [defaults setBool:!disableMiniplayer forKey:@"enableIosFloatingMiniplayer"];
            [defaults synchronize];
            return YES;
        }
        settingItemId:2];
    [sectionItems addObject:disableFloatingMiniplayer];

    // Virtual bezel in landscape
    YTSettingsSectionItem *virtualBezel = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"VIRTUAL_BEZEL")
        titleDescription:LOC(@"VIRTUAL_BEZEL_DESC")
        accessibilityIdentifier:nil
        switchOn:[defaults boolForKey:@"virtualBezel_enabled"]
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [defaults setBool:enabled forKey:@"virtualBezel_enabled"];
            [defaults synchronize];
            return YES;
        }
        settingItemId:3];
    [sectionItems addObject:virtualBezel];

    // Fix Casting
    YTSettingsSectionItem *fixCasting = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"FIX_CASTING")
        titleDescription:LOC(@"FIX_CASTING_DESC")
        accessibilityIdentifier:nil
        switchOn:[defaults boolForKey:@"fixCasting_enabled"]
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [defaults setBool:enabled forKey:@"fixCasting_enabled"];
            [defaults synchronize];
            return YES;
        }
        settingItemId:5];
    [sectionItems addObject:fixCasting];

    // Hide AI Summaries
    YTSettingsSectionItem *hideAISummaries = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"HIDE_AI_SUMMARIES")
        titleDescription:LOC(@"HIDE_AI_SUMMARIES_DESC")
        accessibilityIdentifier:nil
        switchOn:[defaults boolForKey:@"hideAISummaries_enabled"]
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [defaults setBool:enabled forKey:@"hideAISummaries_enabled"];
            [defaults synchronize];
            return YES;
        }
        settingItemId:4];
    [sectionItems addObject:hideAISummaries];

    // Fake Brightness — slider row (no description here to avoid overlap)
    YTSettingsSectionItem *fakeBrightness = [YTSettingsSectionItemClass itemWithTitle:LOC(@"FAKE_BRIGHTNESS")
        titleDescription:@"\u200B" // hacky workaround to stop slider from overlapping with title
        accessibilityIdentifier:@"fakeBrightnessSlider"
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:fakeBrightness];

    // Fake Brightness — description row (blank title, description text only)
    YTSettingsSectionItem *fakeBrightnessDesc = [YTSettingsSectionItemClass itemWithTitle:@""
        titleDescription:LOC(@"FAKE_BRIGHTNESS_DESC")
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:fakeBrightnessDesc];

    // Schedule Fake Brightness (Night Mode) — toggle
    YTSettingsSectionItem *scheduleToggle = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"SCHEDULE_NIGHT_MODE")
        titleDescription:LOC(@"SCHEDULE_NIGHT_MODE_DESC")
        accessibilityIdentifier:nil
        switchOn:[defaults boolForKey:@"fakeBrightness_schedule_enabled"]
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [defaults setBool:enabled forKey:@"fakeBrightness_schedule_enabled"];
            [defaults synchronize];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
            return YES;
        }
        settingItemId:6];
    [sectionItems addObject:scheduleToggle];

    // Night mode brightness slider (no title at all; \u200B trick keeps slider spacing sane)
    YTSettingsSectionItem *fakeBrightnessNight = [YTSettingsSectionItemClass itemWithTitle:@" "
        accessibilityIdentifier:@"fakeBrightnessNightSlider"
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:fakeBrightnessNight];

    // Night mode schedule time range (From / To)
    YTSettingsSectionItem *scheduleRange = [YTSettingsSectionItemClass itemWithTitle:LOC(@"SCHEDULE_TIME_RANGE")
        titleDescription:@"\u200B"
        accessibilityIdentifier:@"fakeBrightnessScheduleRange"
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:scheduleRange];

    // Small blank spacer row before Preferences management
    YTSettingsSectionItem *prefsSpacer = [YTSettingsSectionItemClass itemWithTitle:@" "
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:prefsSpacer];

    // Preferences management
    YTSettingsSectionItem *prefsHeader = [YTSettingsSectionItemClass itemWithTitle:LOC(@"PREFERENCES_MANAGEMENT")
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:prefsHeader];

    // Import preferences
    YTSettingsSectionItem *importPrefs = [YTSettingsSectionItemClass itemWithTitle:LOC(@"IMPORT_PREFERENCES")
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{ [self importPreferences]; }
            actionTitle:LOC(@"YES")
            cancelAction:^{}
            cancelTitle:LOC(@"CANCEL")];
            alertView.title = LOC(@"WARNING");
            alertView.subtitle = LOC(@"IMPORT_CONFIRM");
            [alertView show];
            return YES;
        }];
    [sectionItems addObject:importPrefs];

    // Export preferences
    YTSettingsSectionItem *exportPrefs = [YTSettingsSectionItemClass itemWithTitle:LOC(@"EXPORT_PREFERENCES")
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { [self exportPreferences]; return YES; }
        ];
    [sectionItems addObject:exportPrefs];

    // Restore defaults
    YTSettingsSectionItem *restoreDefaults = [YTSettingsSectionItemClass itemWithTitle:LOC(@"RESTORE_DEFAULTS")
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{ [self restoreDefaults]; }
            actionTitle:LOC(@"YES")
            cancelAction:^{}
            cancelTitle:LOC(@"CANCEL")];
            alertView.title = LOC(@"WARNING");
            alertView.subtitle = LOC(@"RESTORE_CONFIRM");
            [alertView show];
            return YES;
        }];
    [sectionItems addObject:restoreDefaults];

    // Version number footer
    #define STRINGIFY(x) #x
    #define TOSTRING(x) STRINGIFY(x)
    NSString *versionString = [NSString stringWithFormat:@"YTweaks v%s", TOSTRING(TWEAK_VERSION)];
    YTSettingsSectionItem *versionFooter = [YTSettingsSectionItemClass itemWithTitle:versionString
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:nil
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) { return NO; }
        ];
    [sectionItems addObject:versionFooter];

    YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
    NSString *title = @"YTweaks";
    if ([delegate respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_MAGIC_WAND;
        [delegate setSectionItems:sectionItems
            forCategory:YTWKSSection
            title:title
            icon:icon
            titleDescription:nil
            headerHidden:NO];
    } else
        [delegate setSectionItems:sectionItems
            forCategory:YTWKSSection
            title:title
            titleDescription:nil
            headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == YTWKSSection) { [self updateYTWKSSectionWithEntry:entry]; return; }
    %orig;
}

%new
- (void)exportPreferences {
    self.isImportingPreferences = NO;
    NSDictionary *prefs = [defaults dictionaryRepresentation];
    NSMutableDictionary *ytweaksPrefs = [NSMutableDictionary dictionary];
    for (NSString *key in prefs) {
        if ([key hasPrefix:@"fullscreen_"] ||
            [key hasPrefix:@"enable"] ||
            [key hasPrefix:@"virtualBezel"] ||
            [key hasPrefix:@"hideAISummaries"] ||
            [key hasPrefix:@"fixCasting"] ||
            [key hasPrefix:@"fakeBrightness"]) {
            ytweaksPrefs[key] = prefs[key];
        }
    }
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"YTweaks-preferences.plist"];
    [ytweaksPrefs writeToFile:tempPath atomically:YES];
    NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithURL:fileURL
        inMode:UIDocumentPickerModeExportToService];
    picker.delegate = self;
    YTSettingsViewController *settingsVC = [self valueForKey:@"_dataDelegate"];
    [settingsVC presentViewController:picker animated:YES completion:nil];
}

%new
- (void)importPreferences {
    self.isImportingPreferences = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.xml", @"com.apple.property-list"]
        inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    YTSettingsViewController *settingsVC = [self valueForKey:@"_dataDelegate"];
    [settingsVC presentViewController:picker animated:YES completion:nil];
}

%new
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!self.isImportingPreferences) return;
    if (urls.count == 0) return;
    NSURL *fileURL = urls[0];
    NSDictionary *importedPrefs = [NSDictionary dictionaryWithContentsOfURL:fileURL];
    NSBundle *bundle = YTWKSBundle();
    if (importedPrefs) {
        for (NSString *key in importedPrefs) { [defaults setObject:importedPrefs[key] forKey:key]; }
        [defaults synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
        NSString *successMsg = [bundle localizedStringForKey:@"IMPORT_SUCCESS" value:nil table:nil];
        [[%c(YTToastResponderEvent) eventWithMessage:successMsg
            firstResponder:[self parentResponder]] send];
    } else {
        NSString *failMsg = [bundle localizedStringForKey:@"IMPORT_FAILED" value:nil table:nil];
        [[%c(YTToastResponderEvent) eventWithMessage:failMsg
            firstResponder:[self parentResponder]] send];
    }
}

%new
- (void)restoreDefaults {
    NSArray *keys = @[@"fullscreen_button_mode",
                      @"fullscreen_swipe_mode",
                      @"enableIosFloatingMiniplayer",
                      @"virtualBezel_enabled",
                      @"hideAISummaries_enabled",
                      @"fixCasting_enabled",
                      @"fakeBrightness_percent",
                      @"fakeBrightness_schedule_enabled",
                      @"fakeBrightness_night_percent",
                      @"fakeBrightness_schedule_start",
                      @"fakeBrightness_schedule_end"];
    for (NSString *key in keys) { [defaults removeObjectForKey:key]; }
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
}

%end

%hook YTSettingsCell

// FIX: all reuse cleanup now happens here, in prepareForReuse, which runs
// once per recycled cell BEFORE the next layout pass. This is what breaks
// the freeze: layoutSubviews below no longer calls removeFromSuperview,
// so it can never re-trigger its own layout pass and loop forever.
//
// IMPORTANT: no %new here. prepareForReuse already exists on
// UITableViewCell — this is a normal override, not a new selector.
// Marking it %new was the actual cause of the repeat freeze: %orig
// inside a %new method doesn't reliably chain up to the real
// UITableViewCell implementation, and can end up recursing into itself.
- (void)prepareForReuse {
    %orig;

    self.userInteractionEnabled = YES;

    UISlider *staleSlider = [self.contentView viewWithTag:YTWKSFakeBrightnessSliderTag];
    if (staleSlider) [staleSlider removeFromSuperview];

    UILabel *staleLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessLabelTag];
    if (staleLabel) [staleLabel removeFromSuperview];

    UISegmentedControl *staleButtonSegment = [self.contentView viewWithTag:YTWKSFullscreenButtonSegmentTag];
    if (staleButtonSegment) [staleButtonSegment removeFromSuperview];

    UISegmentedControl *staleSwipeSegment = [self.contentView viewWithTag:YTWKSFullscreenSwipeSegmentTag];
    if (staleSwipeSegment) [staleSwipeSegment removeFromSuperview];

    UISlider *staleNightSlider = [self.contentView viewWithTag:YTWKSFakeBrightnessNightSliderTag];
    if (staleNightSlider) [staleNightSlider removeFromSuperview];

    UILabel *staleNightLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessNightLabelTag];
    if (staleNightLabel) [staleNightLabel removeFromSuperview];

    UIDatePicker *staleStartPicker = [self.contentView viewWithTag:YTWKSScheduleStartPickerTag];
    if (staleStartPicker) [staleStartPicker removeFromSuperview];

    UIDatePicker *staleEndPicker = [self.contentView viewWithTag:YTWKSScheduleEndPickerTag];
    if (staleEndPicker) [staleEndPicker removeFromSuperview];

    UILabel *staleStartLabel = [self.contentView viewWithTag:YTWKSScheduleStartLabelTag];
    if (staleStartLabel) [staleStartLabel removeFromSuperview];

    UILabel *staleEndLabel = [self.contentView viewWithTag:YTWKSScheduleEndLabelTag];
    if (staleEndLabel) [staleEndLabel removeFromSuperview];
}

- (void)layoutSubviews {
    %orig;

    NSBundle *bundle = YTWKSBundle();

    // NOTE: this method only ADDS or UPDATES views now. Never removes.
    // Removal happens exclusively in prepareForReuse above.

    if ([self.accessibilityIdentifier isEqualToString:@"fakeBrightnessSlider"]) {
        UISlider *slider = [self.contentView viewWithTag:YTWKSFakeBrightnessSliderTag];
        UILabel *percentLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessLabelTag];
        NSInteger percent = YTWKSFakeBrightnessPercent(defaults);

        if (!slider) {
            slider = [[UISlider alloc] init];
            slider.tag = YTWKSFakeBrightnessSliderTag;
            slider.minimumValue = YTWKSFakeBrightnessMin;
            slider.maximumValue = YTWKSFakeBrightnessMax;
            slider.value = (float)percent;
            slider.continuous = YES;
            slider.minimumTrackTintColor = [UIColor whiteColor];
            slider.maximumTrackTintColor = [UIColor colorWithWhite:0.4 alpha:1.0];
            slider.thumbTintColor = [UIColor whiteColor];
            [slider addTarget:self action:@selector(fakeBrightnessSliderChanged:) forControlEvents:UIControlEventValueChanged];
            slider.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:slider];

            percentLabel = [[UILabel alloc] init];
            percentLabel.tag = YTWKSFakeBrightnessLabelTag;
            percentLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
            percentLabel.textColor = [UIColor whiteColor];
            percentLabel.textAlignment = NSTextAlignmentRight;
            YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);
            percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:percentLabel];

            [NSLayoutConstraint activateConstraints:@[
                [percentLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [percentLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
                [percentLabel.widthAnchor constraintEqualToConstant:44],
                [slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
                [slider.trailingAnchor constraintEqualToAnchor:percentLabel.leadingAnchor constant:-8],
                [slider.centerYAnchor constraintEqualToAnchor:percentLabel.centerYAnchor]
            ]];
        } else {
            if ((NSInteger)lround(slider.value) != percent)
                slider.value = (float)percent;
            if (percentLabel)
                YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);
        }
        return;
    }

    if ([self.accessibilityIdentifier isEqualToString:@"fakeBrightnessNightSlider"]) {
        UISlider *slider = [self.contentView viewWithTag:YTWKSFakeBrightnessNightSliderTag];
        UILabel *percentLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessNightLabelTag];
        NSInteger percent = YTWKSFakeBrightnessNightPercent(defaults);

        if (!slider) {
            slider = [[UISlider alloc] init];
            slider.tag = YTWKSFakeBrightnessNightSliderTag;
            slider.minimumValue = YTWKSFakeBrightnessMin;
            slider.maximumValue = YTWKSFakeBrightnessMax;
            slider.value = (float)percent;
            slider.continuous = YES;
            slider.minimumTrackTintColor = [UIColor whiteColor];
            slider.maximumTrackTintColor = [UIColor colorWithWhite:0.4 alpha:1.0];
            slider.thumbTintColor = [UIColor whiteColor];
            [slider addTarget:self action:@selector(fakeBrightnessNightSliderChanged:) forControlEvents:UIControlEventValueChanged];
            slider.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:slider];

            percentLabel = [[UILabel alloc] init];
            percentLabel.tag = YTWKSFakeBrightnessNightLabelTag;
            percentLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
            percentLabel.textColor = [UIColor whiteColor];
            percentLabel.textAlignment = NSTextAlignmentRight;
            YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);
            percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:percentLabel];

            [NSLayoutConstraint activateConstraints:@[
                [percentLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [percentLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
                [percentLabel.widthAnchor constraintEqualToConstant:44],
                [slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
                [slider.trailingAnchor constraintEqualToAnchor:percentLabel.leadingAnchor constant:-8],
                [slider.centerYAnchor constraintEqualToAnchor:percentLabel.centerYAnchor]
            ]];
        } else {
            if ((NSInteger)lround(slider.value) != percent)
                slider.value = (float)percent;
            if (percentLabel)
                YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);
        }
        return;
    }

    if ([self.accessibilityIdentifier isEqualToString:@"fakeBrightnessScheduleRange"]) {
        [self YTWKS_layoutScheduledTimeRange];
        return;
    }

    if ([self YTWKS_layoutFullscreenDirectionSegmentWithIdentifier:@"fullscreenButtonModeSegment"
                                                               tag:YTWKSFullscreenButtonSegmentTag
                                                           prefKey:@"fullscreen_button_mode"
                                                            action:@selector(fullscreenButtonModeSegmentChanged:)]) {
        return;
    }

    if ([self YTWKS_layoutFullscreenDirectionSegmentWithIdentifier:@"fullscreenSwipeModeSegment"
                                                               tag:YTWKSFullscreenSwipeSegmentTag
                                                           prefKey:@"fullscreen_swipe_mode"
                                                            action:@selector(fullscreenSwipeModeSegmentChanged:)]) {
        return;
    }

    // Make the preferences management header smaller and non-clickable
    NSString *headerText = [bundle localizedStringForKey:@"PREFERENCES_MANAGEMENT" value:nil table:nil];

    BOOL isHeaderCell = NO;
    UILabel *titleLabel = nil;

    @try {
        titleLabel = [self valueForKey:@"_titleLabel"];
        if (!titleLabel) {
            titleLabel = [self valueForKey:@"titleLabel"];
        }

        if (!titleLabel) {
            for (UIView *subview in self.contentView.subviews) {
                if ([subview isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)subview;
                    if ([label.text isEqualToString:headerText]) {
                        titleLabel = label;
                        isHeaderCell = YES;
                        break;
                    }
                }
            }
        } else if (titleLabel && [titleLabel.text isEqualToString:headerText]) {
            isHeaderCell = YES;
        }

        if (isHeaderCell && titleLabel) {
            self.userInteractionEnabled = NO;
            titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        }

        // Style version footer (smaller, lighter)
        NSString *versionPrefix = @"YTweaks ";
        if (titleLabel && [titleLabel.text hasPrefix:versionPrefix]) {
            self.userInteractionEnabled = NO;
            titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightLight];
        }
    } @catch (NSException *e) {
        // Couldn't access properties
    }
}

%new
- (BOOL)YTWKS_layoutFullscreenDirectionSegmentWithIdentifier:(NSString *)identifier
                                                         tag:(NSInteger)tag
                                                     prefKey:(NSString *)prefKey
                                                      action:(SEL)action {
    if (![self.accessibilityIdentifier isEqualToString:identifier]) return NO;

    NSBundle *bundle = YTWKSBundle();
    NSOperatingSystemVersion ios13 = {13, 0, 0};
    SEL tintSelector = NSSelectorFromString(@"setSelectedSegmentTintColor:");

    UISegmentedControl *segment = [self.contentView viewWithTag:tag];
    if (!segment) {
        NSArray *items = @[
            [bundle localizedStringForKey:@"FULLSCREEN_OFF" value:@"Off" table:nil],
            [bundle localizedStringForKey:@"FULLSCREEN_LEFT" value:@"Left" table:nil],
            [bundle localizedStringForKey:@"FULLSCREEN_RIGHT" value:@"Right" table:nil],
            [bundle localizedStringForKey:@"FULLSCREEN_PORTRAIT" value:@"Portrait" table:nil]
        ];
        segment = [[UISegmentedControl alloc] initWithItems:items];
        segment.tag = tag;
        segment.selectedSegmentIndex = [defaults integerForKey:prefKey];
        [segment addTarget:self action:action forControlEvents:UIControlEventValueChanged];

        segment.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
        if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:ios13] &&
            [segment respondsToSelector:tintSelector]) {
            UIColor *tintColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
            ((void (*)(id, SEL, id))objc_msgSend)(segment, tintSelector, tintColor);
        }
        [segment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
        [segment setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];

        UIFont *font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
        [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];

        segment.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:segment];

        [NSLayoutConstraint activateConstraints:@[
            [segment.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [segment.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [segment.heightAnchor constraintEqualToConstant:32]
        ]];
    } else {
        NSInteger currentMode = [defaults integerForKey:prefKey];
        if (segment.selectedSegmentIndex != currentMode) {
            segment.selectedSegmentIndex = currentMode;
        }
    }
    return YES;
}

%new
- (void)YTWKS_layoutScheduledTimeRange {
    NSBundle *tweakBundle = YTWKSBundle();
    UIDatePicker *startPicker = [self.contentView viewWithTag:YTWKSScheduleStartPickerTag];
    UIDatePicker *endPicker = [self.contentView viewWithTag:YTWKSScheduleEndPickerTag];

    NSInteger startMinutes = [defaults objectForKey:@"fakeBrightness_schedule_start"]
        ? [defaults integerForKey:@"fakeBrightness_schedule_start"]
        : YTWKSScheduleStartDefaultMinutes;
    NSInteger endMinutes = [defaults objectForKey:@"fakeBrightness_schedule_end"]
        ? [defaults integerForKey:@"fakeBrightness_schedule_end"]
        : YTWKSScheduleEndDefaultMinutes;

    if (!startPicker) {
        UILabel *startLabel = [[UILabel alloc] init];
        startLabel.tag = YTWKSScheduleStartLabelTag;
        startLabel.text = LOC(@"START_TIME_LABEL");
        startLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        startLabel.textColor = [UIColor whiteColor];
        startLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:startLabel];

        startPicker = [[UIDatePicker alloc] init];
        startPicker.tag = YTWKSScheduleStartPickerTag;
        startPicker.datePickerMode = UIDatePickerModeTime;
        if (@available(iOS 13.4, *)) startPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        startPicker.date = YTWKSDateFromMinutes(startMinutes);
        [startPicker addTarget:self action:@selector(scheduleStartTimeChanged:) forControlEvents:UIControlEventValueChanged];
        startPicker.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:startPicker];

        UILabel *endLabel = [[UILabel alloc] init];
        endLabel.tag = YTWKSScheduleEndLabelTag;
        endLabel.text = LOC(@"END_TIME_LABEL");
        endLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        endLabel.textColor = [UIColor whiteColor];
        endLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:endLabel];

        endPicker = [[UIDatePicker alloc] init];
        endPicker.tag = YTWKSScheduleEndPickerTag;
        endPicker.datePickerMode = UIDatePickerModeTime;
        if (@available(iOS 13.4, *)) endPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        endPicker.date = YTWKSDateFromMinutes(endMinutes);
        [endPicker addTarget:self action:@selector(scheduleEndTimeChanged:) forControlEvents:UIControlEventValueChanged];
        endPicker.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:endPicker];

        [NSLayoutConstraint activateConstraints:@[
            [startLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [startLabel.centerYAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],

            [startPicker.leadingAnchor constraintEqualToAnchor:startLabel.trailingAnchor constant:8],
            [startPicker.centerYAnchor constraintEqualToAnchor:startLabel.centerYAnchor],

            [endLabel.leadingAnchor constraintEqualToAnchor:startPicker.trailingAnchor constant:8],
            [endLabel.centerYAnchor constraintEqualToAnchor:startLabel.centerYAnchor],

            [endPicker.leadingAnchor constraintEqualToAnchor:endLabel.trailingAnchor constant:8],
            [endPicker.centerYAnchor constraintEqualToAnchor:startLabel.centerYAnchor]
        ]];
    } else {
        // Keep pickers in sync if prefs changed elsewhere (import/restore)
        if (YTWKSMinutesFromDate(startPicker.date) != startMinutes)
            startPicker.date = YTWKSDateFromMinutes(startMinutes);
        if (endPicker && YTWKSMinutesFromDate(endPicker.date) != endMinutes)
            endPicker.date = YTWKSDateFromMinutes(endMinutes);
    }
}

%new
- (void)fakeBrightnessSliderChanged:(UISlider *)sender {
    NSInteger percent = (NSInteger)lround(sender.value);
    if (percent < YTWKSFakeBrightnessMin) percent = YTWKSFakeBrightnessMin;
    if (percent > YTWKSFakeBrightnessMax) percent = YTWKSFakeBrightnessMax;
    sender.value = (float)percent;

    UILabel *percentLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessLabelTag];
    if (percentLabel) YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);

    [defaults setInteger:percent forKey:@"fakeBrightness_percent"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
}

%new
- (void)fakeBrightnessNightSliderChanged:(UISlider *)sender {
    NSInteger percent = (NSInteger)lround(sender.value);
    if (percent < YTWKSFakeBrightnessMin) percent = YTWKSFakeBrightnessMin;
    if (percent > YTWKSFakeBrightnessMax) percent = YTWKSFakeBrightnessMax;
    sender.value = (float)percent;

    UILabel *percentLabel = [self.contentView viewWithTag:YTWKSFakeBrightnessNightLabelTag];
    if (percentLabel) YTWKSUpdateFakeBrightnessLabel(percentLabel, percent);

    [defaults setInteger:percent forKey:@"fakeBrightness_night_percent"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
}

%new
- (void)scheduleStartTimeChanged:(UIDatePicker *)sender {
    NSInteger minutes = YTWKSMinutesFromDate(sender.date);
    [defaults setInteger:minutes forKey:@"fakeBrightness_schedule_start"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
}

%new
- (void)scheduleEndTimeChanged:(UIDatePicker *)sender {
    NSInteger minutes = YTWKSMinutesFromDate(sender.date);
    [defaults setInteger:minutes forKey:@"fakeBrightness_schedule_end"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTWKSFakeBrightnessChanged" object:nil];
}

%new
- (void)fullscreenButtonModeSegmentChanged:(UISegmentedControl *)sender {
    [defaults setInteger:sender.selectedSegmentIndex forKey:@"fullscreen_button_mode"];
    [defaults synchronize];
}

%new
- (void)fullscreenSwipeModeSegmentChanged:(UISegmentedControl *)sender {
    [defaults setInteger:sender.selectedSegmentIndex forKey:@"fullscreen_swipe_mode"];
    [defaults synchronize];
}

%end

%ctor {
    defaults = [NSUserDefaults standardUserDefaults];
    %init;
}
