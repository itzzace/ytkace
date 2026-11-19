#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/YTKACEDownloadPlayerController.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const YTKACEShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP YTKACEShortsOrigAllowed;
static IMP YTKACEShortsOrigEligible;
static IMP YTKACEShortsOrigCanEnable;
static IMP YTKACEOrigSetWatchViewLayout;

static NSString *const YTKACEMiniplayerPiPKey = @"YTKACE.Preference.Playback.MiniplayerPiPDisabled";
static __weak id YTKACEWatchLayer;

static void YTKACESetWatchViewLayout(id self, SEL _cmd, long long layout) {
    ((void (*)(id, SEL, long long))YTKACEOrigSetWatchViewLayout)(self, _cmd, layout);
    YTKACEWatchLayer = self;
    YTKACEDebugLog(@"pip", @"watch layout=%lld", layout);
}

// The watch page is collapsed into the miniplayer.
static BOOL YTKACEMiniplayerBlocksPiP(void) {
    if (!YTKACEFeatureEnabled(YTKACEMiniplayerPiPKey)) return NO;
    id layer = YTKACEWatchLayer;
    SEL expanded = NSSelectorFromString(@"isWatchExpanded");
    if (layer == nil || ![layer respondsToSelector:expanded]) return NO;
    BOOL blocked = !((BOOL (*)(id, SEL))objc_msgSend)(layer, expanded);
    YTKACEDebugLog(@"pip", @"miniplayer block=%@", blocked ? @"YES" : @"NO");
    return blocked;
}

static id YTKACEShortsPiPOwner(id controller) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "_delegate");
    if (ivar == NULL) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(controller, ivar);
}

static BOOL YTKACELibraryOwnsPiP(void) {
    YTKACEDownloadPlaybackSession *session = YTKACEDownloadPlaybackSession.existingSession;
    return session.currentURL != nil && session.player.rate != 0.0f;
}

static BOOL YTKACEShortsBlocksPiP(id controller) {
    if (YTKACELibraryOwnsPiP()) return YES;
    if (YTKACEMiniplayerBlocksPiP()) return YES;
    if (!YTKACEFeatureEnabled(YTKACEShortsPiPKey)) return NO;
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    id current = YTKACEShortsPiPOwner(controller);
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"] ||
            YTKACEPlayerIsShorts(current)) {
            return YES;
        }
        if (![current respondsToSelector:parentSel]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSel);
    }
    return NO;
}

// YouTube says no to PiP for free accounts outside the US; with YTKACE PiP
// on, every video that isn't blocked above can use it.
static BOOL YTKACEShortsAllowed(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEFeatureEnabled(YTKACEPiPKey)) return YES;
    return ((BOOL (*)(id, SEL))YTKACEShortsOrigAllowed)(self, _cmd);
}

static BOOL YTKACEShortsEligible(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    BOOL eligible = ((BOOL (*)(id, SEL))YTKACEShortsOrigEligible)(self, _cmd);
    if (!eligible && (YTKACEFeatureEnabled(YTKACEBackgroundPlaybackKey) || YTKACEFeatureEnabled(YTKACEPiPKey))) return YES;
    return eligible;
}

static BOOL YTKACEShortsCanEnable(id self, SEL _cmd) {
    if (YTKACEShortsBlocksPiP(self)) return NO;
    if (YTKACEFeatureEnabled(YTKACEPiPKey)) return YES;
    return ((BOOL (*)(id, SEL))YTKACEShortsOrigCanEnable)(self, _cmd);
}

void YTKACEInstallShortsPiPHooks(void) {
    NSString *pipClass = @"YTPlayerPIPController";
    YTKACEInstallInstanceHook(pipClass, @"isPictureInPictureAllowed",
        (IMP)YTKACEShortsAllowed, &YTKACEShortsOrigAllowed);
    YTKACEInstallInstanceHook(pipClass, @"isEligibleForPictureInPicture",
        (IMP)YTKACEShortsEligible, &YTKACEShortsOrigEligible);
    YTKACEInstallInstanceHook(pipClass, @"canEnablePictureInPicture",
        (IMP)YTKACEShortsCanEnable, &YTKACEShortsOrigCanEnable);
    YTKACEInstallInstanceHook(@"YTWatchLayerViewController", @"setWatchViewLayout:",
        (IMP)YTKACESetWatchViewLayout, &YTKACEOrigSetWatchViewLayout);
}
