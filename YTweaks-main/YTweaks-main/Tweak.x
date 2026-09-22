#import <substrate.h>
#import <UIKit/UIKit.h>
#import <YouTubeHeader/YTAppDelegate.h>
#import <YouTubeHeader/YTGlobalConfig.h>
#import <YouTubeHeader/YTColdConfig.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTPlayerOverlayManager.h>
#import <YouTubeHeader/YTWatchController.h>

// Forward declarations
@class YTWatchViewController;
@class YTMainAppVideoPlayerOverlayView;

// Home feed cells use _ASCollectionViewCell; hook this directly, not UICollectionViewCell.
@interface _ASCollectionViewCell : UICollectionViewCell
@end

// Storage for original method implementations
NSMutableDictionary <NSString *, NSMutableDictionary <NSString *, NSNumber *> *> *abConfigCache;

// Fake brightness overlay
static UIView *nightModeOverlay = nil;

static const NSInteger YTWKSFakeBrightnessMin = 5;
static const NSInteger YTWKSFakeBrightnessMax = 100;
static const NSInteger YTWKSFakeBrightnessDefault = 100;
static const NSInteger YTWKSFakeBrightnessNightDefault = 30;
static const NSInteger YTWKSScheduleStartDefaultMinutes = 1320; // 22:00
static const NSInteger YTWKSScheduleEndDefaultMinutes = 360;    // 06:00

// Defined in Settings.x; shared here to evaluate the night-mode schedule.
extern BOOL YTWKSMinutesInScheduleWindow(NSInteger nowMinutes, NSInteger startMinutes, NSInteger endMinutes);

static void YTWKSMigrateLegacyNightModeLevel(NSUserDefaults *prefs) {
    if ([prefs objectForKey:@"fakeBrightness_percent"]) return;
    if (![prefs objectForKey:@"nightMode_level"]) return;

    NSInteger level = [prefs integerForKey:@"nightMode_level"];
    CGFloat opacityValues[] = {0.0, 0.3, 0.5, 0.7, 0.9};
    NSInteger percent = YTWKSFakeBrightnessDefault;
    if (level >= 1 && level <= 4) {
        CGFloat opacity = opacityValues[level];
        percent = (NSInteger)lround(100.0 - opacity * 95.0);
        if (percent < YTWKSFakeBrightnessMin) percent = YTWKSFakeBrightnessMin;
    }
    [prefs setInteger:percent forKey:@"fakeBrightness_percent"];
    [prefs removeObjectForKey:@"nightMode_level"];
    [prefs synchronize];
}

static NSInteger YTWKSFakeBrightnessPercent(NSUserDefaults *prefs) {
    YTWKSMigrateLegacyNightModeLevel(prefs);
    if (![prefs objectForKey:@"fakeBrightness_percent"])
        return YTWKSFakeBrightnessDefault;
    NSInteger percent = [prefs integerForKey:@"fakeBrightness_percent"];
    NSInteger clamped = percent;
    if (clamped < YTWKSFakeBrightnessMin) clamped = YTWKSFakeBrightnessMin;
    if (clamped > YTWKSFakeBrightnessMax) clamped = YTWKSFakeBrightnessMax;
    if (clamped != percent) {
        [prefs setInteger:clamped forKey:@"fakeBrightness_percent"];
        [prefs synchronize];
    }
    return clamped;
}

// The percent actually applied to the overlay: the regular fakeBrightness
// value, unless the night-mode schedule is enabled and the current time
// falls inside the configured window, in which case the night percent wins.
static NSInteger YTWKSEffectiveBrightnessPercent(NSUserDefaults *prefs) {
    NSInteger dayPercent = YTWKSFakeBrightnessPercent(prefs);

    if (![prefs boolForKey:@"fakeBrightness_schedule_enabled"]) return dayPercent;

    NSInteger nightPercent = [prefs objectForKey:@"fakeBrightness_night_percent"]
        ? [prefs integerForKey:@"fakeBrightness_night_percent"]
        : YTWKSFakeBrightnessNightDefault;
    if (nightPercent < YTWKSFakeBrightnessMin) nightPercent = YTWKSFakeBrightnessMin;
    if (nightPercent > YTWKSFakeBrightnessMax) nightPercent = YTWKSFakeBrightnessMax;

    NSInteger startMinutes = [prefs objectForKey:@"fakeBrightness_schedule_start"]
        ? [prefs integerForKey:@"fakeBrightness_schedule_start"]
        : YTWKSScheduleStartDefaultMinutes;
    NSInteger endMinutes = [prefs objectForKey:@"fakeBrightness_schedule_end"]
        ? [prefs integerForKey:@"fakeBrightness_schedule_end"]
        : YTWKSScheduleEndDefaultMinutes;

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *nowComps = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
    NSInteger nowMinutes = nowComps.hour * 60 + nowComps.minute;

    return YTWKSMinutesInScheduleWindow(nowMinutes, startMinutes, endMinutes) ? nightPercent : dayPercent;
}

static CGFloat YTWKSFakeBrightnessOpacityForPercent(NSInteger percent) {
    if (percent >= YTWKSFakeBrightnessMax) return 0.0;
    return (100.0 - percent) / 95.0;
}

static void ensureOverlayOnMainWindow(void) {
    UIWindow *mainWindow = [[[UIApplication sharedApplication] delegate] window];
    if (!mainWindow) return;

    if (!nightModeOverlay) {
        nightModeOverlay = [[UIView alloc] initWithFrame:mainWindow.bounds];
        nightModeOverlay.backgroundColor = [UIColor blackColor];
        nightModeOverlay.alpha = 0.0;
        nightModeOverlay.userInteractionEnabled = NO;
        nightModeOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        nightModeOverlay.layer.zPosition = CGFLOAT_MAX;
    }

    if (nightModeOverlay.window != mainWindow) {
        [nightModeOverlay removeFromSuperview];
        [mainWindow addSubview:nightModeOverlay];
    }
}

static void updateFakeBrightnessOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ updateFakeBrightnessOverlay(); });
        return;
    }

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSInteger percent = YTWKSEffectiveBrightnessPercent(prefs);
    CGFloat opacity = YTWKSFakeBrightnessOpacityForPercent(percent);

    if (percent < YTWKSFakeBrightnessMax && opacity > 0.0) {
        ensureOverlayOnMainWindow();
        if (nightModeOverlay) {
            nightModeOverlay.hidden = NO;
            [UIView animateWithDuration:0.3 animations:^{ nightModeOverlay.alpha = opacity; }];
        }
    } else if (nightModeOverlay) {
        [UIView animateWithDuration:0.3 animations:^{
            nightModeOverlay.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (finished) nightModeOverlay.hidden = YES;
        }];
    }
}

// Helper function to get original value from config instance
static BOOL getValueFromInvocation(id target, SEL selector) {
    IMP imp = [target methodForSelector:selector];
    BOOL (*func)(id, SEL) = (BOOL (*)(id, SEL))imp;
    return func(target, selector);
}

// Replacement function for A/B config boolean methods
static BOOL returnFunction(id const self, SEL _cmd) {
    NSString *method = NSStringFromSelector(_cmd);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Check if user has overridden this setting
    if ([defaults objectForKey:method]) {
        return [defaults boolForKey:method];
    }
    
    // Return cached original value if not overridden
    NSString *classKey = NSStringFromClass([self class]);
    NSNumber *cachedValue = abConfigCache[classKey][method];
    return cachedValue ? [cachedValue boolValue] : NO;
}

// Get all boolean methods from a config class
static NSMutableArray <NSString *> *getBooleanMethods(Class clz) {
    NSMutableArray *allMethods = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(clz, &methodCount);
    
    for (unsigned int i = 0; i < methodCount; ++i) {
        Method method = methods[i];
        const char *encoding = method_getTypeEncoding(method);
        
        // Only hook boolean return methods: B16@0:8
        if (strcmp(encoding, "B16@0:8")) continue;
        
        NSString *selector = [NSString stringWithUTF8String:sel_getName(method_getName(method))];
        
        // Exclude Android and other irrelevant methods
        if ([selector hasPrefix:@"android"] || 
            [selector hasPrefix:@"amsterdam"] ||
            [selector hasPrefix:@"kidsClient"] ||
            [selector hasPrefix:@"musicClient"] ||
            [selector hasPrefix:@"musicOfflineClient"] ||
            [selector hasPrefix:@"unplugged"] ||
            [selector rangeOfString:@"Android"].location != NSNotFound) {
            continue;
        }
        
        if (![allMethods containsObject:selector])
            [allMethods addObject:selector];
    }
    
    free(methods);
    return allMethods;
}

// Hook all boolean methods in a config class
static void hookClass(NSObject *instance) {
    if (!instance) return;
    
    Class instanceClass = [instance class];
    NSMutableArray <NSString *> *methods = getBooleanMethods(instanceClass);
    NSString *classKey = NSStringFromClass(instanceClass);
    
    // Initialize cache for this class
    NSMutableDictionary *classCache = abConfigCache[classKey] = [NSMutableDictionary new];
    
    // Hook each boolean method
    for (NSString *method in methods) {
        SEL selector = NSSelectorFromString(method);
        
        // Cache the original value
        BOOL result = getValueFromInvocation(instance, selector);
        classCache[method] = @(result);
        
        // Replace with our function that checks NSUserDefaults
        MSHookMessageEx(instanceClass, selector, (IMP)returnFunction, NULL);
    }
}

// Hook YTAppDelegate to intercept A/B config classes on app launch
%hook YTAppDelegate

- (BOOL)application:(id)arg1 didFinishLaunchingWithOptions:(id)arg2 {
    BOOL result = %orig;
    
    // Hook YouTube's A/B config classes
    YTGlobalConfig *globalConfig = nil;
    YTColdConfig *coldConfig = nil;
    YTHotConfig *hotConfig = nil;
    
    @try {
        // Try to get config instances from app delegate
        globalConfig = [self valueForKey:@"_globalConfig"];
        coldConfig = [self valueForKey:@"_coldConfig"];
        hotConfig = [self valueForKey:@"_hotConfig"];
    } @catch (id ex) {
        // Fallback: try getting from _settings
        @try {
            id settings = [self valueForKey:@"_settings"];
            globalConfig = [settings valueForKey:@"_globalConfig"];
            coldConfig = [settings valueForKey:@"_coldConfig"];
            hotConfig = [settings valueForKey:@"_hotConfig"];
        } @catch (id ex) {}
    }
    
    // Hook each config class
    hookClass(globalConfig);
    hookClass(coldConfig);
    hookClass(hotConfig);
    
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTWKSFakeBrightnessChanged"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { updateFakeBrightnessOverlay(); }];

    // Re-evaluate on foreground and every 60s so a schedule boundary (e.g.
    // 22:00 arriving) is caught even if no setting was touched and the app
    // was just sitting open/backgrounded.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { updateFakeBrightnessOverlay(); }];

    [NSTimer scheduledTimerWithTimeInterval:60.0
        repeats:YES
        block:^(NSTimer *timer) { updateFakeBrightnessOverlay(); }];

    // 3 second delay before applying setting on fresh launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ updateFakeBrightnessOverlay(); });
    
    return result;
}

%end

// Fullscreen direction (iPhone-Exclusive) - @arichornlover & @bhackel
// fullscreen_button_mode / fullscreen_swipe_mode: 0 = Off, 1 = Left, 2 = Right, 3 = Portrait
// Button: didPressToggleFullscreen (PVC + overlay manager). Swipe: showFullScreen when button flag unset.

static const NSTimeInterval kYTWKSFullscreenPendingDuration = 0.5;

static BOOL gButtonFullscreenPending = NO;
static BOOL gSwipeFullscreenPending = NO;

static UIInterfaceOrientationMask YTWKSFullscreenMaskForMode(NSInteger mode) {
    if (mode == 1) return UIInterfaceOrientationMaskLandscapeLeft;
    if (mode == 2) return UIInterfaceOrientationMaskLandscapeRight;
    if (mode == 3) return UIInterfaceOrientationMaskPortrait;
    return 0;
}

static void YTWKSActivatePendingFlag(BOOL *pendingFlag) {
    *pendingFlag = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kYTWKSFullscreenPendingDuration * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ *pendingFlag = NO; });
}

static BOOL YTWKSIsEnteringFullscreen(YTPlayerViewController *player) {
    if (!player) return YES;
    id overlay = [player activeVideoPlayerOverlay];
    if (overlay && [overlay respondsToSelector:@selector(isFullscreen)]) {
        return ![(YTMainAppVideoPlayerOverlayViewController *)overlay isFullscreen];
    }
    return YES;
}

static YTPlayerViewController *YTWKSPlayerFromOverlayManager(YTPlayerOverlayManager *manager) {
    @try {
        id player = [manager valueForKey:@"_playerViewController"];
        if (!player) player = [manager valueForKey:@"playerViewController"];
        return player;
    } @catch (id ex) {
        return nil;
    }
}

static void YTWKSBeginScopedFullscreen(YTPlayerViewController *player, NSString *prefKey, BOOL *pendingFlag) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs integerForKey:prefKey] == 0) return;
    if (!YTWKSIsEnteringFullscreen(player)) return;
    YTWKSActivatePendingFlag(pendingFlag);
}

static void YTWKSBeginSwipeFullscreenFromShowFullScreen(void) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs integerForKey:@"fullscreen_swipe_mode"] == 0) return;
    if (gButtonFullscreenPending) return;
    YTWKSActivatePendingFlag(&gSwipeFullscreenPending);
}

static void YTWKSMigrateLegacyFullscreenMode(void) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSInteger global = [prefs integerForKey:@"fullscreen_mode"];
    if (global == 0) return;

    if ([prefs integerForKey:@"fullscreen_button_mode"] == 0)
        [prefs setInteger:global forKey:@"fullscreen_button_mode"];
    if ([prefs integerForKey:@"fullscreen_swipe_mode"] == 0)
        [prefs setInteger:global forKey:@"fullscreen_swipe_mode"];
    [prefs removeObjectForKey:@"fullscreen_mode"];
    [prefs synchronize];
}

%hook YTWatchViewController
- (UIInterfaceOrientationMask)allowedFullScreenOrientations {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    UIInterfaceOrientationMask forced = 0;

    if (gButtonFullscreenPending) {
        forced = YTWKSFullscreenMaskForMode([prefs integerForKey:@"fullscreen_button_mode"]);
        if (forced) return forced;
    }
    if (gSwipeFullscreenPending) {
        forced = YTWKSFullscreenMaskForMode([prefs integerForKey:@"fullscreen_swipe_mode"]);
        if (forced) return forced;
    }
    return %orig;
}
%end

%hook YTPlayerViewController
- (void)didPressToggleFullscreen {
    YTWKSBeginScopedFullscreen(self, @"fullscreen_button_mode", &gButtonFullscreenPending);
    %orig;
}
- (void)didSwipeToEnterFullscreen {
    YTWKSBeginScopedFullscreen(self, @"fullscreen_swipe_mode", &gSwipeFullscreenPending);
    %orig;
}
%end

%hook YTPlayerOverlayManager
- (void)didPressToggleFullscreen {
    YTWKSBeginScopedFullscreen(YTWKSPlayerFromOverlayManager(self), @"fullscreen_button_mode", &gButtonFullscreenPending);
    %orig;
}
%end

%hook YTWatchController
- (void)showFullScreen {
    YTWKSBeginSwipeFullscreenFromShowFullScreen();
    %orig;
}
%end

// Virtual bezel in landscape mode to prevent accidental video scrubbing
%hook YTMainAppVideoPlayerOverlayView
- (void)layoutSubviews {
    %orig;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"virtualBezel_enabled"]) {
        // Remove blocking views if feature is disabled
        UIView *view = (UIView *)self;
        UIView *leftBlocker = [view viewWithTag:999998];
        UIView *rightBlocker = [view viewWithTag:999999];
        if (leftBlocker) [leftBlocker removeFromSuperview];
        if (rightBlocker) [rightBlocker removeFromSuperview];
        return;
    }
    
    // Check if we're in landscape orientation
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(orientation);
    
    if (!isLandscape) {
        // Remove blocking views if they exist when not in landscape
        UIView *view = (UIView *)self;
        UIView *leftBlocker = [view viewWithTag:999998];
        UIView *rightBlocker = [view viewWithTag:999999];
        if (leftBlocker) [leftBlocker removeFromSuperview];
        if (rightBlocker) [rightBlocker removeFromSuperview];
        return;
    }
    
    // Get screen dimensions
    UIView *view = (UIView *)self;
    CGRect screenBounds = view.bounds;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat screenHeight = screenBounds.size.height;
    
    // Calculate 2177:1179 aspect ratio for clickable area (touchable region)
    // This ratio extends the clickable area just enough to reach the settings button
    CGFloat clickableAspectRatio = 2177.0 / 1179.0;
    CGFloat clickableWidth, clickableHeight;
    
    // Calculate clickable area based on aspect ratio
    // In landscape, we want the clickable area to match the aspect ratio
    if (screenWidth / screenHeight > clickableAspectRatio) {
        // Screen is wider than 2177:1179, so clickable height matches screen height
        clickableHeight = screenHeight;
        clickableWidth = clickableHeight * clickableAspectRatio;
    } else {
        // Screen is taller than 2177:1179, so clickable width matches screen width
        clickableWidth = screenWidth;
        clickableHeight = clickableWidth / clickableAspectRatio;
    }
    
    // Center the clickable region
    CGFloat clickableX = (screenWidth - clickableWidth) / 2.0;
    
    // Only create blocking views if there's space on the sides
    if (clickableX > 0) {
        // Create or update left blocking view
        UIView *leftBlocker = [view viewWithTag:999998];
        if (!leftBlocker) {
            leftBlocker = [[UIView alloc] init];
            leftBlocker.tag = 999998;
            leftBlocker.backgroundColor = [UIColor clearColor];
            leftBlocker.userInteractionEnabled = YES;
            leftBlocker.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleHeight;
            [view addSubview:leftBlocker];
        }
        leftBlocker.frame = CGRectMake(0, 0, clickableX, screenHeight);
    } else {
        // Remove left blocker if no space
        UIView *leftBlocker = [view viewWithTag:999998];
        if (leftBlocker) [leftBlocker removeFromSuperview];
    }
    
    CGFloat rightBlockerX = clickableX + clickableWidth;
    CGFloat rightBlockerWidth = screenWidth - rightBlockerX;
    if (rightBlockerWidth > 0) {
        // Create or update right blocking view
        UIView *rightBlocker = [view viewWithTag:999999];
        if (!rightBlocker) {
            rightBlocker = [[UIView alloc] init];
            rightBlocker.tag = 999999;
            rightBlocker.backgroundColor = [UIColor clearColor];
            rightBlocker.userInteractionEnabled = YES;
            rightBlocker.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
            [view addSubview:rightBlocker];
        }
        rightBlocker.frame = CGRectMake(rightBlockerX, 0, rightBlockerWidth, screenHeight);
    } else {
        // Remove right blocker if no space
        UIView *rightBlocker = [view viewWithTag:999999];
        if (rightBlocker) [rightBlocker removeFromSuperview];
    }
}
%end

// Hide AI summaries on Home feed — removeFromSuperview on Flex-confirmed targets, inside-out:
//   1. id.elements.inline_expander
//   2. inner _ASDisplayView under id.elements.inlin*
//   3. eml.expandable_metadata row container

static NSString *const kAISummaryInlineExpanderId = @"id.elements.inline_expander";
static NSString *const kAISummaryMetadataRowId = @"eml.expandable_metadata";
static NSString *const kAISummaryInlineElementPrefix = @"id.elements.inlin";

static const NSInteger kAISummarySearchDepth = 8;
static const NSInteger kAISummaryRowSearchDepth = 5;

static BOOL isASDisplayView(UIView *view) {
    return [NSStringFromClass([view class]) isEqualToString:@"_ASDisplayView"];
}

static void collectViewsWithIdentifierPrefix(UIView *root, NSString *prefix, NSInteger maxDepth, NSMutableArray *out) {
    if (!root || maxDepth <= 0) return;
    for (UIView *subview in root.subviews) {
        NSString *identifier = subview.accessibilityIdentifier;
        if (identifier.length && [identifier hasPrefix:prefix]) {
            [out addObject:subview];
        }
        collectViewsWithIdentifierPrefix(subview, prefix, maxDepth - 1, out);
    }
}

static UIView *inlineInnerDisplayView(UIView *metadataRow) {
    NSMutableArray *inlineEls = [NSMutableArray array];
    collectViewsWithIdentifierPrefix(metadataRow, kAISummaryInlineElementPrefix, kAISummaryRowSearchDepth, inlineEls);
    for (UIView *inlineEl in inlineEls) {
        for (UIView *subview in inlineEl.subviews) {
            if (isASDisplayView(subview)) return subview;
        }
    }
    return nil;
}

static void removeViewIfAttached(UIView *view) {
    if (view.superview) [view removeFromSuperview];
}

static void hideAISummaryViewsInCell(UIView *cell) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"hideAISummaries_enabled"]) return;

    NSMutableArray *expanders = [NSMutableArray array];
    collectViewsWithIdentifierPrefix(cell, kAISummaryInlineExpanderId, kAISummarySearchDepth, expanders);
    for (UIView *view in expanders) {
        removeViewIfAttached(view);
    }

    NSMutableArray *metadataRows = [NSMutableArray array];
    collectViewsWithIdentifierPrefix(cell, kAISummaryMetadataRowId, kAISummarySearchDepth, metadataRows);
    for (UIView *row in metadataRows) {
        UIView *inner = inlineInnerDisplayView(row);
        if (inner) {
            removeViewIfAttached(inner);
        } else {
            for (UIView *subview in [row.subviews copy]) {
                if (isASDisplayView(subview)) removeViewIfAttached(subview);
            }
        }
        removeViewIfAttached(row);
    }
}

%hook _ASCollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"hideAISummaries_enabled"]) return;

    __weak UIView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf) hideAISummaryViewsInCell(weakSelf);
    });
}
%end

// Fix Casting: https://github.com/arichornlover/uYouEnhanced/issues/606#issuecomment-2098289942
%hook YTColdConfig
- (BOOL)cxClientEnableIosLocalNetworkPermissionReliabilityFixes {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"fixCasting_enabled"]) {
        return YES;
    }
    return %orig;
}
- (BOOL)cxClientEnableIosLocalNetworkPermissionUsingSockets {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"fixCasting_enabled"]) {
        return NO;
    }
    return %orig;
}
- (BOOL)cxClientEnableIosLocalNetworkPermissionWifiFixes {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"fixCasting_enabled"]) {
        return YES;
    }
    return %orig;
}
%end

%hook YTHotConfig
- (BOOL)isPromptForLocalNetworkPermissionsEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"fixCasting_enabled"]) {
        return YES;
    }
    return %orig;
}
%end

%ctor {
    [[NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Frameworks/Module_Framework.framework", [[NSBundle mainBundle] bundlePath]]] load];
    
    // Initialize A/B config cache
    abConfigCache = [NSMutableDictionary new];

    YTWKSMigrateLegacyFullscreenMode();
    YTWKSMigrateLegacyNightModeLevel([NSUserDefaults standardUserDefaults]);
    
    %init;
}

%dtor {
    // Clean up cache on unload
    [abConfigCache removeAllObjects];
}
