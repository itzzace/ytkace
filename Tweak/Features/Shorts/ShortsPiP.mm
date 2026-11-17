#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/YTKACEDownloadPlayerController.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const YTKACEShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP YTKACEShortsOrigAllowed;
static IMP YTKACEShortsOrigEligible;
static IMP YTKACEShortsOrigCanEnable;

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
}
