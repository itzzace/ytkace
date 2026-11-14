#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ReelVideoType values on YTIReelWatchEndpoint and YTReelModel.
// 2 = video, 3 = ad, 4 = live, 7 = live preview, 10 = post.
enum {
    YTKACEReelVideoTypeLive = 4,
    YTKACEReelVideoTypeLivePreview = 7,
    YTKACEReelVideoTypePost = 10
};

static IMP OriginalMakeContentModelForEntry;
static IMP OriginalShouldDisplay;
static IMP OriginalSetReels;
static IMP OriginalInsertContentModel;
static IMP OriginalInsertEndpoint;

static Class YTKACEReelModelClass(void) {
    static Class reelModelClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reelModelClass = NSClassFromString(@"YTReelModel");
    });
    return reelModelClass;
}

static BOOL YTKACEHidesLiveShorts(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.LiveHidden");
}

static BOOL YTKACEHidesPostShorts(void) {
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Shorts.PostsHidden");
}

static BOOL YTKACEFiltersVideoType(NSInteger videoType) {
    if (videoType == YTKACEReelVideoTypeLive ||
        videoType == YTKACEReelVideoTypeLivePreview) {
        return YTKACEHidesLiveShorts();
    }
    if (videoType == YTKACEReelVideoTypePost) return YTKACEHidesPostShorts();
    return NO;
}

static BOOL YTKACEFiltersModel(id model) {
    if (![model isKindOfClass:YTKACEReelModelClass()]) return NO;
    NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
        model, NSSelectorFromString(@"videoType"));
    return YTKACEFiltersVideoType(videoType);
}

static BOOL YTKACEFiltersEntry(id entry) {
    id command = ((id (*)(id, SEL))objc_msgSend)(
        entry, NSSelectorFromString(@"command"));
    id endpoint = ((id (*)(id, SEL))objc_msgSend)(
        command, NSSelectorFromString(@"reelWatchEndpoint"));
    NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
        endpoint, NSSelectorFromString(@"videoType"));
    return YTKACEFiltersVideoType(videoType);
}

static id YTKACEMakeContentModelForEntry(id receiver, SEL selector, id entry) {
    if (YTKACEFiltersEntry(entry)) return nil;
    return ((id (*)(id, SEL, id))OriginalMakeContentModelForEntry)(
        receiver, selector, entry);
}

static BOOL YTKACEShouldDisplay(id receiver, SEL selector) {
    if (YTKACEFiltersModel(receiver)) return NO;
    return ((BOOL (*)(id, SEL))OriginalShouldDisplay)(receiver, selector);
}

static void YTKACESetReels(id receiver, SEL selector, NSOrderedSet *reels) {
    NSMutableOrderedSet *filtered =
        [NSMutableOrderedSet orderedSetWithCapacity:reels.count];
    for (id reel in reels) {
        if (!YTKACEFiltersModel(reel)) [filtered addObject:reel];
    }
    ((void (*)(id, SEL, id))OriginalSetReels)(receiver, selector, filtered);
}

static BOOL YTKACEInsertContentModel(id receiver,
                                     SEL selector,
                                     id model,
                                     NSUInteger index) {
    if (YTKACEFiltersModel(model)) return NO;
    return ((BOOL (*)(id, SEL, id, NSUInteger))OriginalInsertContentModel)(
        receiver, selector, model, index);
}

static BOOL YTKACEInsertEndpoint(id receiver,
                                 SEL selector,
                                 id endpoint,
                                 NSUInteger index) {
    NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
        endpoint, NSSelectorFromString(@"videoType"));
    if (YTKACEFiltersVideoType(videoType)) return NO;
    return ((BOOL (*)(id, SEL, id, NSUInteger))OriginalInsertEndpoint)(
        receiver, selector, endpoint, index);
}

void YTKACEInstallShortsFeedFilterHooks(void) {
    YTKACEInstallClassHook(@"YTReelContentModel",
                           @"makeContentModelForEntry:",
                           (IMP)YTKACEMakeContentModelForEntry,
                           &OriginalMakeContentModelForEntry);
    YTKACEInstallInstanceHook(@"YTReelContentModel",
                              @"shouldDisplay",
                              (IMP)YTKACEShouldDisplay,
                              &OriginalShouldDisplay);
    YTKACEInstallInstanceHook(@"YTReelDataSource",
                              @"setReels:",
                              (IMP)YTKACESetReels,
                              &OriginalSetReels);
    YTKACEInstallInstanceHook(@"YTReelDataSource",
                              @"insertContentModel:atIndex:",
                              (IMP)YTKACEInsertContentModel,
                              &OriginalInsertContentModel);
    YTKACEInstallInstanceHook(@"YTReelDataSource",
                              @"insertEndpoint:atIndex:",
                              (IMP)YTKACEInsertEndpoint,
                              &OriginalInsertEndpoint);
}
