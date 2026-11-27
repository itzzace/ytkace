#import "../../YTKACE.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

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
            YTKACEDebugLog(@"promo", @"throttled interstitial (%@)", match);
            return YES;
        }
        // Modals with client throttling rules only show
        // once per time window.
        SEL hasRules = NSSelectorFromString(@"hasModalClientThrottlingRules");
        SEL rules = NSSelectorFromString(@"modalClientThrottlingRules");
        SEL setOnce = NSSelectorFromString(@"setOncePerTimeWindow:");
        if ([receiver respondsToSelector:hasRules] && [receiver respondsToSelector:rules] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(receiver, hasRules)) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, rules);
            if ([value respondsToSelector:setOnce]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(value, setOnce, YES);
                YTKACEDebugLog(@"promo", @"interstitial set once per window");
            }
        }
    }
    return OriginalThrottleInterstitial != NULL &&
        ((BOOL (*)(id, SEL))OriginalThrottleInterstitial)(receiver, selector);
}

// Event handlers for commerce alerts (like "renew Premium"), promo
// interstitials and promo sheets. YouTube registers them once at setup, so
// the setting applies from the next launch.
static IMP OriginalCommerceHandlers;
static IMP OriginalInterstitialHandlers;
static IMP OriginalPromosheetHandlers;

static void YTKACECommerceHandlers(id receiver, SEL selector) {
    if (YTKACEHidePromos()) {
        YTKACEDebugLog(@"promo", @"blocked commerce handlers");
        return;
    }
    if (OriginalCommerceHandlers != NULL) ((void (*)(id, SEL))OriginalCommerceHandlers)(receiver, selector);
}

static void YTKACEInterstitialHandlers(id receiver, SEL selector) {
    if (YTKACEHidePromos()) {
        YTKACEDebugLog(@"promo", @"blocked interstitial handlers");
        return;
    }
    if (OriginalInterstitialHandlers != NULL) ((void (*)(id, SEL))OriginalInterstitialHandlers)(receiver, selector);
}

static void YTKACEPromosheetHandlers(id receiver, SEL selector) {
    if (YTKACEHidePromos()) {
        YTKACEDebugLog(@"promo", @"blocked promo sheet handlers");
        return;
    }
    if (OriginalPromosheetHandlers != NULL) ((void (*)(id, SEL))OriginalPromosheetHandlers)(receiver, selector);
}

static IMP OriginalCanShowPromo[2];
static IMP OriginalCanShowPromoCap[2];
static IMP OriginalCanShowPromoCaps[2];

static BOOL YTKACECanShowPromo0(id r, SEL s) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromo[0] != NULL && ((BOOL (*)(id, SEL))OriginalCanShowPromo[0])(r, s);
}
static BOOL YTKACECanShowPromo1(id r, SEL s) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromo[1] != NULL && ((BOOL (*)(id, SEL))OriginalCanShowPromo[1])(r, s);
}
static BOOL YTKACECanShowPromoCap0(id r, SEL s, id cap) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromoCap[0] != NULL && ((BOOL (*)(id, SEL, id))OriginalCanShowPromoCap[0])(r, s, cap);
}
static BOOL YTKACECanShowPromoCap1(id r, SEL s, id cap) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromoCap[1] != NULL && ((BOOL (*)(id, SEL, id))OriginalCanShowPromoCap[1])(r, s, cap);
}
static BOOL YTKACECanShowPromoCaps0(id r, SEL s, id caps) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromoCaps[0] != NULL && ((BOOL (*)(id, SEL, id))OriginalCanShowPromoCaps[0])(r, s, caps);
}
static BOOL YTKACECanShowPromoCaps1(id r, SEL s, id caps) {
    if (YTKACEHidePromos()) return NO;
    return OriginalCanShowPromoCaps[1] != NULL && ((BOOL (*)(id, SEL, id))OriginalCanShowPromoCaps[1])(r, s, caps);
}

static IMP OriginalShowSurvey;

static void YTKACEShowSurvey(id receiver, SEL selector, id renderer, id responder) {
    if (YTKACEHidePromos()) return;
    if (OriginalShowSurvey != NULL) ((void (*)(id, SEL, id, id))OriginalShowSurvey)(receiver, selector, renderer, responder);
}

void YTKACEInstallPromoHooks(void) {
    YTKACEInstallInstanceHook(@"YTCommerceEventGroupHandler", @"addEventHandlers",
                              (IMP)YTKACECommerceHandlers, &OriginalCommerceHandlers);
    YTKACEInstallInstanceHook(@"YTInterstitialPromoEventGroupHandler", @"addEventHandlers",
                              (IMP)YTKACEInterstitialHandlers, &OriginalInterstitialHandlers);
    YTKACEInstallInstanceHook(@"YTPromosheetEventGroupHandler", @"addEventHandlers",
                              (IMP)YTKACEPromosheetHandlers, &OriginalPromosheetHandlers);
    NSArray<NSString *> *throttles = @[@"YTPromoThrottleController", @"YTPromoThrottleControllerImpl"];
    IMP canShow[2] = {(IMP)YTKACECanShowPromo0, (IMP)YTKACECanShowPromo1};
    IMP canShowCap[2] = {(IMP)YTKACECanShowPromoCap0, (IMP)YTKACECanShowPromoCap1};
    IMP canShowCaps[2] = {(IMP)YTKACECanShowPromoCaps0, (IMP)YTKACECanShowPromoCaps1};
    for (NSUInteger i = 0; i < 2; i++) {
        YTKACEInstallInstanceHook(throttles[i], @"canShowThrottledPromo",
                                  canShow[i], &OriginalCanShowPromo[i]);
        YTKACEInstallInstanceHook(throttles[i], @"canShowThrottledPromoWithFrequencyCap:",
                                  canShowCap[i], &OriginalCanShowPromoCap[i]);
        YTKACEInstallInstanceHook(throttles[i], @"canShowThrottledPromoWithFrequencyCaps:",
                                  canShowCaps[i], &OriginalCanShowPromoCaps[i]);
    }
    YTKACEInstallInstanceHook(@"YTSurveyController", @"showSurveyWithRenderer:surveyParentResponder:",
                              (IMP)YTKACEShowSurvey, &OriginalShowSurvey);
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
