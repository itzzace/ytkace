#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

static IMP OriginalPlayableInBackground;
static IMP OriginalMLPlayableInBackground;
static IMP OriginalBackgroundEnabled;
static IMP OriginalPlayableInPiP;

static BOOL YTKACEBackgroundBoolean(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey)) {
        return YES;
    }

    IMP original = NULL;
    if ([NSStringFromSelector(selector) isEqualToString:@"isPlayableInBackground"]) {
        original = OriginalPlayableInBackground;
    } else if ([NSStringFromSelector(selector) isEqualToString:@"playableInBackground"]) {
        original = OriginalMLPlayableInBackground;
    } else {
        original = OriginalBackgroundEnabled;
    }
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTKACEPlayableInPiP(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey) || YTKACEFeatureEnabled(YTKACEPiPKey)) return YES;
    return OriginalPlayableInPiP != NULL &&
        ((BOOL (*)(id, SEL))OriginalPlayableInPiP)(receiver, selector);
}

void YTKACEInstallBackgroundPlaybackHooks(void) {
    YTKACEInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInPictureInPicture",
                              (IMP)YTKACEPlayableInPiP,
                              &OriginalPlayableInPiP);
    YTKACEInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInBackground",
                              (IMP)YTKACEBackgroundBoolean,
                              &OriginalPlayableInBackground);
    YTKACEInstallInstanceHook(@"MLVideo",
                              @"playableInBackground",
                              (IMP)YTKACEBackgroundBoolean,
                              &OriginalMLPlayableInBackground);
    if (!YTKACEInstallInstanceHook(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)YTKACEBackgroundBoolean,
            &OriginalBackgroundEnabled)) {
        YTKACEAddInstanceMethod(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)YTKACEBackgroundBoolean,
            "B@:"
        );
    }
}
