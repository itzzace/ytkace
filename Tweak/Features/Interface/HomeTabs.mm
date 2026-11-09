#import "../Downloads/DownloadLog.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalBrowseLoadResponse;
static IMP OriginalBrowseLoadInitialResponse;

static BOOL YTKACEHomeBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger YTKACEHomeInt(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector) : -1;
}

static id YTKACEHomeObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void YTKACEHomeSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static IMP OriginalFoxScrollableTabs;
static IMP OriginalFoxCollapsingTabs;
static IMP OriginalFoxIosCollapsingTabs;

static BOOL YTKACEFoxFlag(IMP original, id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return NO;
    return original != NULL && ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTKACEFoxScrollableTabs(id receiver, SEL selector) {
    return YTKACEFoxFlag(OriginalFoxScrollableTabs, receiver, selector);
}

static BOOL YTKACEFoxCollapsingTabs(id receiver, SEL selector) {
    return YTKACEFoxFlag(OriginalFoxCollapsingTabs, receiver, selector);
}

static BOOL YTKACEFoxIosCollapsingTabs(id receiver, SEL selector) {
    return YTKACEFoxFlag(OriginalFoxIosCollapsingTabs, receiver, selector);
}

static NSString *YTKACEHomeTabBrowseID(id tab) {
    id renderer = YTKACEHomeObject(tab, @"tabRenderer");
    id endpoint = YTKACEHomeObject(YTKACEHomeObject(renderer, @"endpoint"), @"browseEndpoint");
    id browseID = YTKACEHomeObject(endpoint, @"browseId");
    return [browseID isKindOfClass:NSString.class] ? browseID : nil;
}

static id YTKACEHomeNew(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls != Nil ? [cls new] : nil;
}

static void YTKACEHomeSet(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (object != nil && value != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static id YTKACEHomeExtension(NSString *className, NSInteger field) {
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%@|%ld", className, (long)field];
    if (cache[key] != nil) return cache[key] == NSNull.null ? nil : cache[key];
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    id result = nil;
    Class registryClass = NSClassFromString(@"GoogleGlobalExtensionRegistry");
    Class target = NSClassFromString(className);
    SEL registrySel = NSSelectorFromString(@"extensionRegistry");
    SEL lookup = NSSelectorFromString(@"extensionForDescriptor:fieldNumber:");
    if (registryClass != Nil && target != Nil && [registryClass respondsToSelector:registrySel] &&
        [target respondsToSelector:@selector(descriptor)]) {
        id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, registrySel);
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(target, @selector(descriptor));
        if ([registry respondsToSelector:lookup]) {
            result = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(registry, lookup, descriptor, field);
        }
    }
    cache[key] = result ?: NSNull.null;
    return result;
}

static id YTKACEHomeWrap(NSString *className, NSInteger field, id value) {
    id extension = YTKACEHomeExtension(className, field);
    id wrapper = YTKACEHomeNew(className);
    SEL setter = NSSelectorFromString(@"setExtension:value:");
    if (extension == nil || wrapper == nil || value == nil || ![wrapper respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(wrapper, setter, extension, value);
    return wrapper;
}

static id YTKACEHomeReloadData(id tab) {
    id list = YTKACEHomeObject(YTKACEHomeObject(YTKACEHomeObject(tab, @"tabRenderer"), @"content"), @"sectionListRenderer");
    for (id continuation in YTKACEHomeObject(list, @"continuationsArray")) {
        id data = YTKACEHomeObject(continuation, @"reloadContinuationData");
        if ([YTKACEHomeObject(data, @"continuation") length] != 0) return data;
    }
    return nil;
}

static id YTKACEHomeReloadCommand(id data) {
    id endpoint = YTKACEHomeNew(@"YTIBrowseSectionListReloadEndpoint");
    id continuations = YTKACEHomeNew(@"YTIBrowseSectionListReloadSupportedContinuations");
    if (data == nil || endpoint == nil || continuations == nil) return nil;
    YTKACEHomeSet(continuations, @"setReloadContinuationData:", data);
    YTKACEHomeSet(endpoint, @"setContinuation:", continuations);
    return YTKACEHomeWrap(@"YTICommand", 120837120, endpoint);
}

static id YTKACEHomeChip(NSString *title, NSInteger icon, id command, BOOL selected) {
    id chip = YTKACEHomeNew(@"YTIChipCloudChipRenderer");
    if (chip == nil) return nil;
    id style = YTKACEHomeNew(@"YTIChipCloudChipStyle");
    id styleDescriptor = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"YTIChipCloudChipStyle"), @selector(descriptor));
    id field = ((id (*)(id, SEL, id))objc_msgSend)(styleDescriptor, NSSelectorFromString(@"fieldWithName:"), @"styleType");
    id enumDescriptor = YTKACEHomeObject(field, @"enumDescriptor");
    int32_t value = 0;
    SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
    if ([enumDescriptor respondsToSelector:lookup] &&
        ((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &value, @"STYLE_HOME_FILTER")) {
        ((void (*)(id, SEL, int))objc_msgSend)(style, NSSelectorFromString(@"setStyleType:"), value);
        YTKACEHomeSet(chip, @"setStyle:", style);
    }
    if (title.length != 0) {
        Class formatted = NSClassFromString(@"YTIFormattedString");
        SEL make = NSSelectorFromString(@"formattedStringWithString:");
        if ([formatted respondsToSelector:make]) {
            YTKACEHomeSet(chip, @"setText:", ((id (*)(id, SEL, id))objc_msgSend)(formatted, make, title));
        }
    }
    if (icon > 0) {
        id image = YTKACEHomeNew(@"YTIIcon");
        ((void (*)(id, SEL, int))objc_msgSend)(image, NSSelectorFromString(@"setIconType:"), (int)icon);
        YTKACEHomeSet(chip, @"setIcon:", image);
    }
    YTKACEHomeSet(chip, @"setNavigationEndpoint:", command);
    YTKACEHomeSetBool(chip, @"setIsSelected:", selected);
    return YTKACEHomeWrap(@"YTIRenderer", 91394224, chip);
}

static void YTKACEHomeBuildChips(NSArray *tabs, id home) {
    id list = YTKACEHomeObject(YTKACEHomeObject(YTKACEHomeObject(home, @"tabRenderer"), @"content"), @"sectionListRenderer");
    if (list == nil) return;
    id header = YTKACEHomeObject(list, @"header");
    if (YTKACEHomeBool(list, @"hasHeader") && YTKACEHomeBool(header, @"hasFeedFilterChipBarRenderer")) return;
    id bar = YTKACEHomeNew(@"YTIFeedFilterChipBarRenderer");
    NSMutableArray *contents = YTKACEHomeObject(bar, @"contentsArray");
    if (![contents isKindOfClass:NSMutableArray.class]) return;
    id homeReload = nil;
    for (id continuation in YTKACEHomeObject(list, @"continuationsArray")) {
        id data = YTKACEHomeObject(continuation, @"reloadContinuationData");
        if ([YTKACEHomeObject(data, @"continuation") length] != 0) homeReload = data;
    }
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = YTKACEHomeObject(tab, @"tabRenderer");
        if (!YTKACEHomeBool(renderer, @"unselectable")) continue;
        id command = YTKACEHomeObject(renderer, @"endpoint");
        NSInteger icon = YTKACEHomeInt(renderer, @"tabIcon");
        if (command == nil || icon <= 0) continue;
        id chip = YTKACEHomeChip(nil, icon, command, NO);
        if (chip != nil) [contents addObject:chip];
        Class dividerClass = YTKACEHomeObject(YTKACEHomeExtension(@"YTIRenderer", 325920579), @"msgClass");
        id divider = dividerClass != Nil ? YTKACEHomeWrap(@"YTIRenderer", 325920579, [dividerClass new]) : nil;
        if (divider != nil) [contents addObject:divider];
    }
    NSString *homeTitle = YTKACEHomeObject(YTKACEHomeObject(home, @"tabRenderer"), @"title");
    id all = YTKACEHomeChip(homeTitle.length != 0 ? homeTitle : @"All", 0, YTKACEHomeReloadCommand(homeReload), YES);
    if (all != nil) [contents addObject:all];
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = YTKACEHomeObject(tab, @"tabRenderer");
        NSString *title = YTKACEHomeObject(renderer, @"title");
        if (title.length == 0 || YTKACEHomeBool(renderer, @"unselectable")) continue;
        id command = YTKACEHomeReloadCommand(YTKACEHomeReloadData(tab)) ?: YTKACEHomeObject(renderer, @"endpoint");
        id chip = YTKACEHomeChip(title, 0, command, NO);
        if (chip != nil) [contents addObject:chip];
    }
    YTKACEDownloadLog(@"home", @"redesign chips=%lu", (unsigned long)contents.count);
    if (contents.count < 2) return;
    YTKACEHomeSet(bar, @"setOnFiltersCleared:", YTKACEHomeReloadCommand(homeReload));
    id newHeader = header ?: YTKACEHomeNew(@"YTISectionListHeaderSupportedRenderers");
    YTKACEHomeSet(newHeader, @"setFeedFilterChipBarRenderer:", bar);
    YTKACEHomeSet(list, @"setHeader:", newHeader);
}

static void YTKACETrimHomeTabsInRenderer(id single) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return;
    NSMutableArray *tabs = YTKACEHomeObject(single, @"tabsArray");
    if (![tabs isKindOfClass:NSMutableArray.class] || tabs.count < 2) return;
    id home = nil;
    BOOL subscriptions = NO;
    for (id tab in tabs) {
        NSString *browseID = YTKACEHomeTabBrowseID(tab);
        if (home == nil && [browseID isEqualToString:@"FEwhat_to_watch"]) home = tab;
        if ([browseID isEqualToString:@"FEsubscriptions"]) subscriptions = YES;
    }
    if (home == nil && subscriptions) home = tabs.firstObject;
    if (home == nil) return;
    YTKACEHomeBuildChips([tabs copy], home);
    [tabs setArray:@[home]];
    YTKACEHomeSetBool(single, @"setHideTabBar:", YES);
    YTKACEHomeSetBool(single, @"setDisableTabSwiping:", YES);
    YTKACEHomeSetBool(YTKACEHomeObject(home, @"tabRenderer"), @"setHasPresentationStyle:", NO);
}

static void YTKACETrimHomeTabs(id response) {
    YTKACETrimHomeTabsInRenderer(YTKACEHomeObject(YTKACEHomeObject(response, @"contents"),
                                                  @"singleColumnBrowseResultsRenderer"));
}

static IMP OriginalTabsLoadModel;
static IMP OriginalTabsLoadModelReload;
static IMP OriginalTabsUpdateModel;

static void YTKACETabsLoadModel(id receiver, SEL selector, id model) {
    YTKACETrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id))OriginalTabsLoadModel)(receiver, selector, model);
}

static void YTKACETabsLoadModelReload(id receiver, SEL selector, id model, BOOL reload) {
    YTKACETrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL))OriginalTabsLoadModelReload)(receiver, selector, model, reload);
}

static void YTKACETabsUpdateModel(id receiver, SEL selector, id model, BOOL isDefault, BOOL reload) {
    YTKACETrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL, BOOL))OriginalTabsUpdateModel)(receiver, selector, model, isDefault, reload);
}

static void YTKACEBrowseLoadResponse(id receiver, SEL selector, id response) {
    YTKACETrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadResponse)(receiver, selector, response);
}

static void YTKACEBrowseLoadInitialResponse(id receiver, SEL selector, id response) {
    YTKACETrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadInitialResponse)(receiver, selector, response);
}

// Report an older app version on Home requests so the server sends the
// layout from before the redesign.
static NSString * const YTKACEHomeSpoofVersion = @"21.33.6";
static IMP OriginalBrowseRequestWrite;
static IMP OriginalBrowseRequestSize;

static BOOL YTKACEIsHomeContinuation(NSString *token) {
    if (![token isKindOfClass:NSString.class] || token.length == 0) return NO;
    NSString *base64 = [[token stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    base64 = [base64 stringByRemovingPercentEncoding] ?: base64;
    while (base64.length % 4 != 0) base64 = [base64 stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *needle = [@"FEwhat_to_watch" dataUsingEncoding:NSUTF8StringEncoding];
    return data.length != 0 && [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static void YTKACESpoofHomeRequest(id request) {
    id browseID = YTKACEHomeObject(request, @"browseId");
    BOOL home = [browseID isKindOfClass:NSString.class] && [browseID isEqualToString:@"FEwhat_to_watch"];
    if (!home && YTKACEIsHomeContinuation(YTKACEHomeObject(request, @"continuation"))) home = YES;
    if (!home) return;
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return;
    id context = YTKACEHomeObject(request, @"context");
    NSString *version = YTKACEHomeObject(YTKACEHomeObject(context, @"client"), @"clientVersion");
    if (context == nil || [version isEqualToString:YTKACEHomeSpoofVersion]) return;
    id copy = [context copy];
    YTKACEHomeSet(YTKACEHomeObject(copy, @"client"), @"setClientVersion:", YTKACEHomeSpoofVersion);
    YTKACEHomeSet(request, @"setContext:", copy);
}

static size_t YTKACEBrowseRequestSize(id receiver, SEL selector) {
    YTKACESpoofHomeRequest(receiver);
    return ((size_t (*)(id, SEL))OriginalBrowseRequestSize)(receiver, selector);
}

static void YTKACEBrowseRequestWrite(id receiver, SEL selector, id stream) {
    YTKACESpoofHomeRequest(receiver);
    ((void (*)(id, SEL, id))OriginalBrowseRequestWrite)(receiver, selector, stream);
}

static IMP OriginalRequestSetHeader;
static IMP OriginalRequestSetBody;

static BOOL YTKACEIsSpoofedHomeBody(NSData *body) {
    if (body.length == 0) return NO;
    NSData *needle = [YTKACEHomeSpoofVersion dataUsingEncoding:NSUTF8StringEncoding];
    return [body rangeOfData:needle options:0 range:NSMakeRange(0, body.length)].location != NSNotFound;
}

// Keep the version header in line with the spoofed request body.
static void YTKACEMatchVersionHeader(NSMutableURLRequest *request) {
    if (![request.URL.path containsString:@"/browse"] || !YTKACEIsSpoofedHomeBody(request.HTTPBody)) return;
    NSString *current = [request valueForHTTPHeaderField:@"X-Youtube-Client-Version"];
    if (current == nil || [current isEqualToString:YTKACEHomeSpoofVersion]) return;
    ((void (*)(id, SEL, id, id))OriginalRequestSetHeader)(request, @selector(setValue:forHTTPHeaderField:),
                                                         YTKACEHomeSpoofVersion, @"X-Youtube-Client-Version");
}

static void YTKACERequestSetHeader(NSMutableURLRequest *receiver, SEL selector, NSString *value, NSString *field) {
    ((void (*)(id, SEL, id, id))OriginalRequestSetHeader)(receiver, selector, value, field);
    if (![field isKindOfClass:NSString.class] ||
        [field caseInsensitiveCompare:@"X-Youtube-Client-Version"] != NSOrderedSame) return;
    YTKACEMatchVersionHeader(receiver);
}

static void YTKACERequestSetBody(NSMutableURLRequest *receiver, SEL selector, NSData *body) {
    ((void (*)(id, SEL, id))OriginalRequestSetBody)(receiver, selector, body);
    YTKACEMatchVersionHeader(receiver);
}

__attribute__((constructor)) static void YTKACEInstallHomeTabs(void) {
    YTKACEInstallInstanceHook(@"NSMutableURLRequest", @"setValue:forHTTPHeaderField:",
                              (IMP)YTKACERequestSetHeader, &OriginalRequestSetHeader);
    YTKACEInstallInstanceHook(@"NSMutableURLRequest", @"setHTTPBody:",
                              (IMP)YTKACERequestSetBody, &OriginalRequestSetBody);
    Class browseRequest = NSClassFromString(@"YTIBrowseRequest");
    SEL write = NSSelectorFromString(@"writeToCodedOutputStream:");
    Method inherited = class_getInstanceMethod(browseRequest, write);
    const char *writeTypes = inherited != NULL ? method_getTypeEncoding(inherited) : NULL;
    if (writeTypes != NULL && strncmp(writeTypes, "v24@0:8@16", 10) == 0) {
        OriginalBrowseRequestWrite = method_getImplementation(inherited);
        if (!class_addMethod(browseRequest, write, (IMP)YTKACEBrowseRequestWrite, writeTypes)) {
            OriginalBrowseRequestWrite = method_setImplementation(
                class_getInstanceMethod(browseRequest, write), (IMP)YTKACEBrowseRequestWrite);
        }
    }
    SEL size = NSSelectorFromString(@"serializedSize");
    Method sizeMethod = class_getInstanceMethod(browseRequest, size);
    const char *sizeTypes = sizeMethod != NULL ? method_getTypeEncoding(sizeMethod) : NULL;
    if (OriginalBrowseRequestWrite != NULL && sizeTypes != NULL && strncmp(sizeTypes, "Q16@0:8", 7) == 0) {
        OriginalBrowseRequestSize = method_getImplementation(sizeMethod);
        if (!class_addMethod(browseRequest, size, (IMP)YTKACEBrowseRequestSize, sizeTypes)) {
            OriginalBrowseRequestSize = method_setImplementation(
                class_getInstanceMethod(browseRequest, size), (IMP)YTKACEBrowseRequestSize);
        }
    }
    YTKACEInstallInstanceHook(@"YTBrowseViewController", @"loadWithResponse:",
                              (IMP)YTKACEBrowseLoadResponse, &OriginalBrowseLoadResponse);
    YTKACEInstallInstanceHook(@"YTBrowseViewController", @"loadWithInitialResponse:",
                              (IMP)YTKACEBrowseLoadInitialResponse, &OriginalBrowseLoadInitialResponse);
    YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableScrollableTabsInFox",
                              (IMP)YTKACEFoxScrollableTabs, &OriginalFoxScrollableTabs);
    YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientEnableCollapsingTabsAfterDwellInFox",
                              (IMP)YTKACEFoxCollapsingTabs, &OriginalFoxCollapsingTabs);
    YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableCollapsingTabsAfterDwellInFox",
                              (IMP)YTKACEFoxIosCollapsingTabs, &OriginalFoxIosCollapsingTabs);
    YTKACEInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:",
                              (IMP)YTKACETabsLoadModel, &OriginalTabsLoadModel);
    YTKACEInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:reloadContentViewControllers:",
                              (IMP)YTKACETabsLoadModelReload, &OriginalTabsLoadModelReload);
    YTKACEInstallInstanceHook(@"YTTabsViewController", @"updateWithModel:isDefaultModel:reloadContentViewControllers:",
                              (IMP)YTKACETabsUpdateModel, &OriginalTabsUpdateModel);
}
