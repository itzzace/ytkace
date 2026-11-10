#import "../../YTKACE.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>

static IMP OriginalMealbarPromo;
static IMP OriginalPromosheet;
static IMP OriginalUpgradeDialog;
static IMP OriginalOldUpgradeDialog;
static IMP OriginalShouldShowUpgrade;
static IMP OriginalShouldShowUpgradeDialog;
static IMP OriginalYouTherePrompt;
static IMP OriginalThrottleInterstitial;

static BOOL YTKACEHidePromos(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden");
}

static void YTKACEMealbarPromo(id receiver, SEL selector, id event) {
    if (!YTKACEHidePromos() && OriginalMealbarPromo != NULL) {
        ((void (*)(id, SEL, id))OriginalMealbarPromo)(receiver, selector, event);
    }
}

static void YTKACEPromosheet(id receiver, SEL selector, id event) {
    if (!YTKACEHidePromos() && OriginalPromosheet != NULL) {
        ((void (*)(id, SEL, id))OriginalPromosheet)(receiver, selector, event);
    }
}

static void YTKACEUpgradeDialog(id receiver, SEL selector) {
    if (!YTKACEHidePromos() && OriginalUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalUpgradeDialog)(receiver, selector);
    }
}

static void YTKACEOldUpgradeDialog(id receiver, SEL selector) {
    if (!YTKACEHidePromos() && OriginalOldUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalOldUpgradeDialog)(receiver, selector);
    }
}

static BOOL YTKACEShouldShowUpgrade(id receiver, SEL selector) {
    return YTKACEHidePromos() ? NO :
        (OriginalShouldShowUpgrade != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgrade)(receiver, selector));
}

static BOOL YTKACEShouldShowUpgradeDialog(id receiver, SEL selector) {
    return YTKACEHidePromos() ? NO :
        (OriginalShouldShowUpgradeDialog != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgradeDialog)(receiver, selector));
}

// "Video paused. Continue watching?" YouTube can ask through the controller
// or a command from the server, so block every path.
static BOOL YTKACEBlockYouThere(void) {
    return YTKACEHidePromos() || YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.YouThereDisabled");
}

static IMP OriginalShowYouThere;
static IMP OriginalLegacyShouldShowYouThere;
static IMP OriginalLegacyShowYouThere;
static IMP OriginalYouThereCommands;

static BOOL YTKACEShouldShowYouThere(id receiver, SEL selector) {
    return YTKACEBlockYouThere() ? NO :
        (OriginalYouTherePrompt != NULL &&
         ((BOOL (*)(id, SEL))OriginalYouTherePrompt)(receiver, selector));
}

static void YTKACEShowYouThere(id receiver, SEL selector) {
    if (YTKACEBlockYouThere()) {
        YTKACEDebugLog(@"youthere", @"blocked prompt");
        return;
    }
    if (OriginalShowYouThere != NULL) ((void (*)(id, SEL))OriginalShowYouThere)(receiver, selector);
}

static BOOL YTKACELegacyShouldShowYouThere(id receiver, SEL selector) {
    return YTKACEBlockYouThere() ? NO :
        (OriginalLegacyShouldShowYouThere != NULL &&
         ((BOOL (*)(id, SEL))OriginalLegacyShouldShowYouThere)(receiver, selector));
}

static void YTKACELegacyShowYouThere(id receiver, SEL selector) {
    if (YTKACEBlockYouThere()) return;
    if (OriginalLegacyShowYouThere != NULL) ((void (*)(id, SEL))OriginalLegacyShowYouThere)(receiver, selector);
}

static BOOL YTKACEYouThereCommands(id receiver, SEL selector) {
    return YTKACEBlockYouThere() ? NO :
        (OriginalYouThereCommands != NULL &&
         ((BOOL (*)(id, SEL))OriginalYouThereCommands)(receiver, selector));
}

static BOOL YTKACEInterstitialIsPromo(id command, NSString **outMatch) {
    if (command == nil) return NO;
    NSString *text = [[command description] lowercaseString];
    if (text.length == 0) return NO;
    if ([text containsString:@"post"] || [text containsString:@"image"] ||
        [text containsString:@"lightbox"] || [text containsString:@"attachment"]) {
        if (outMatch != NULL) *outMatch = @"post content";
        return NO;
    }
    for (NSString *marker in @[@"premium", @"upsell", @"mealbar",
                               @"promo_sheet", @"promosheet"]) {
        if ([text containsString:marker]) {
            if (outMatch != NULL) *outMatch = marker;
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEShouldThrottleInterstitial(id receiver, SEL selector) {
    if (YTKACEHidePromos()) {
        NSString *match = nil;
        BOOL promo = YTKACEInterstitialIsPromo(receiver, &match);
        if (promo) {
            return YES;
        }
    }
    return OriginalThrottleInterstitial != NULL &&
        ((BOOL (*)(id, SEL))OriginalThrottleInterstitial)(receiver, selector);
}

void YTKACEInstallPromoHooks(void) {
    YTKACEInstallInstanceHook(@"YTMealbarPromoController",
                              @"showMealbarPromoWithEvent:",
                              (IMP)YTKACEMealbarPromo,
                              &OriginalMealbarPromo);
    YTKACEInstallInstanceHook(@"YTPromosheetController",
                              @"presentPromosheetWithEvent:",
                              (IMP)YTKACEPromosheet,
                              &OriginalPromosheet);
    YTKACEInstallInstanceHook(@"YTUpgradeController", @"showUpgradeDialog",
                              (IMP)YTKACEUpgradeDialog,
                              &OriginalUpgradeDialog);
    YTKACEInstallInstanceHook(@"YTUpgradeController", @"showOldUpgradeDialog",
                              (IMP)YTKACEOldUpgradeDialog,
                              &OriginalOldUpgradeDialog);
    YTKACEInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgrade",
                              (IMP)YTKACEShouldShowUpgrade,
                              &OriginalShouldShowUpgrade);
    YTKACEInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgradeDialog",
                              (IMP)YTKACEShouldShowUpgradeDialog,
                              &OriginalShouldShowUpgradeDialog);
    YTKACEInstallInstanceHook(@"YTYouThereControllerImpl",
                              @"shouldShowYouTherePrompt",
                              (IMP)YTKACEShouldShowYouThere,
                              &OriginalYouTherePrompt);
    YTKACEInstallInstanceHook(@"YTYouThereControllerImpl", @"showYouTherePrompt",
                              (IMP)YTKACEShowYouThere, &OriginalShowYouThere);
    YTKACEInstallInstanceHook(@"YTYouThereController", @"shouldShowYouTherePrompt",
                              (IMP)YTKACELegacyShouldShowYouThere, &OriginalLegacyShouldShowYouThere);
    YTKACEInstallInstanceHook(@"YTYouThereController", @"showYouTherePrompt",
                              (IMP)YTKACELegacyShowYouThere, &OriginalLegacyShowYouThere);
    YTKACEInstallInstanceHook(@"YTColdConfig", @"enableYouthereCommandsOnIos",
                              (IMP)YTKACEYouThereCommands, &OriginalYouThereCommands);
    YTKACEInstallInstanceHook(@"YTIShowFullscreenInterstitialCommand",
                              @"shouldThrottleInterstitial",
                              (IMP)YTKACEShouldThrottleInterstitial,
                              &OriginalThrottleInterstitial);
}
