#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../Settings/YTKACEDownloadsController.h"
#import "../../UI/Assets.h"
#import "../Interface/NavigationVisibility.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetPivotRenderer;
static IMP OriginalSetFloatingPivotRenderer;
static IMP OriginalPivotItemLayout;
static IMP OriginalPivotItemSetSelected;
static IMP OriginalPivotItemTraitChanged;
static IMP OriginalPivotLabelSetHidden;
static IMP OriginalPivotLabelSetAlpha;
static IMP OriginalPivotButtonLayout;
static IMP OriginalPivotBarLayout;
static IMP OriginalPivotControllerAppear;
static IMP OriginalSetDefaultSelectedPivot;
static BOOL YTKACEStartupNative;
static IMP OriginalPivotBarStyleColors;
static IMP OriginalPivotBarSetBackgroundStyle;
static IMP OriginalAppViewDidLoad;
static IMP OriginalBrowseViewDidLoad;
static IMP OriginalBrowseResponseViewDidLoad;
static IMP OriginalWrapperViewDidLoad;
static const void *YTKACEDownloadsAssociation = &YTKACEDownloadsAssociation;
static const void *YTKACETabAssociation = &YTKACETabAssociation;
static const void *YTKACETabSelectedAssociation = &YTKACETabSelectedAssociation;
static const void *YTKACETabDragOutAssociation = &YTKACETabDragOutAssociation;
static const void *YTKACEBuiltTabAssociation = &YTKACEBuiltTabAssociation;

static id YTKACEValue(id receiver, NSString *selectorName);

// YouTube's own icon type for Subscriptions, so it draws the tab like its others.
static NSInteger YTKACESubscriptionsIconType(void) {
    static NSInteger value = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class iconClass = NSClassFromString(@"YTIIcon");
        id descriptor = [iconClass respondsToSelector:@selector(descriptor)]
            ? ((id (*)(id, SEL))objc_msgSend)(iconClass, @selector(descriptor)) : nil;
        SEL fieldSelector = NSSelectorFromString(@"fieldWithName:");
        id field = [descriptor respondsToSelector:fieldSelector]
            ? ((id (*)(id, SEL, id))objc_msgSend)(descriptor, fieldSelector, @"iconType") : nil;
        id enumDescriptor = YTKACEValue(field, @"enumDescriptor");
        SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
        if (![enumDescriptor respondsToSelector:lookup]) return;
        for (NSString *name in @[@"TAB_SUBSCRIPTIONS_CAIRO", @"TAB_SUBSCRIPTIONS"]) {
            int32_t found = 0;
            if (((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &found, name)) {
                value = found;
                break;
            }
        }
    });
    return value;
}
static BOOL YTKACEStencilRendering;
static NSString * const YTKACEPivotIdentifier = @"FEYTKACE";
static NSInteger const YTKACEExtraIconTag = 0x59414349;
static NSInteger const YTKACEExtraLabelTag = 0x5941434A;
static BOOL YTKACEStartupApplied;
static NSString *YTKACEFirstVisiblePivot;

static BOOL YTKACENavigationRefreshScheduled;

static id YTKACEValue(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static void YTKACESetValue(id receiver, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver != nil && [receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
    }
}

static id YTKACENew(NSString *className) {
    Class cls = NSClassFromString(className);
    return cls == Nil ? nil : [[cls alloc] init];
}

static id YTKACEMakePivotItem(void) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass,
            factory,
            YTKACEPivotIdentifier,
            @"YTKACE",
            77
        );
        id item = YTKACEValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            YTKACESetValue(item, @"setPivotIdentifier:", YTKACEPivotIdentifier);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = YTKACENew(@"YTIBrowseEndpoint");
    id command = YTKACENew(@"YTICommand");
    id itemRenderer = YTKACENew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = YTKACENew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }

    YTKACESetValue(browseEndpoint, @"setBrowseId:", YTKACEPivotIdentifier);
    YTKACESetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    YTKACESetValue(itemRenderer, @"setPivotIdentifier:", YTKACEPivotIdentifier);
    YTKACESetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id title = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass,
        formattedSelector,
        @"YTKACE"
    );
    YTKACESetValue(itemRenderer, @"setTitle:", title);

    id icon = YTKACEValue(itemRenderer, @"icon");
    SEL iconSelector = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:iconSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, iconSelector, 77);
    }
    YTKACESetValue(
        supportedRenderer,
        @"setPivotBarItemRenderer:",
        itemRenderer
    );
    return supportedRenderer;
}

static id YTKACEMakeBrowsePivotItem(NSString *browseID,
                                    NSString *title,
                                    NSInteger iconType) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass, factory, browseID, title, iconType
        );
        id item = YTKACEValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            YTKACESetValue(item, @"setPivotIdentifier:", browseID);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = YTKACENew(@"YTIBrowseEndpoint");
    id command = YTKACENew(@"YTICommand");
    id itemRenderer = YTKACENew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = YTKACENew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }
    YTKACESetValue(browseEndpoint, @"setBrowseId:", browseID);
    YTKACESetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    YTKACESetValue(itemRenderer, @"setPivotIdentifier:", browseID);
    YTKACESetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id icon = YTKACEValue(itemRenderer, @"icon");
    SEL setIconType = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:setIconType]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, iconType);
    }
    id formatted = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass, formattedSelector, title
    );
    YTKACESetValue(itemRenderer, @"setTitle:", formatted);
    YTKACESetValue(supportedRenderer, @"setPivotBarItemRenderer:", itemRenderer);
    return supportedRenderer;
}

static NSInteger YTKACEInteger(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector)
        : 0;
}

static NSString *YTKACEBrowseIdentifier(UIViewController *controller) {
    id endpoint = YTKACEValue(controller, @"navigationEndpoint");
    if (endpoint == nil) {
        endpoint = YTKACEValue(controller, @"navEndpoint");
    }
    if (endpoint == nil) {
        @try {
            endpoint = [controller valueForKey:@"_navEndpoint"];
        } @catch (__unused NSException *exception) {
        }
    }
    id browseEndpoint = YTKACEValue(endpoint, @"browseEndpoint");
    if (browseEndpoint == nil &&
        [endpoint respondsToSelector:NSSelectorFromString(@"browseId")]) {
        browseEndpoint = endpoint;
    }
    return YTKACEValue(browseEndpoint, @"browseId");
}

static void YTKACEAttachDownloads(UIViewController *controller) {
    if (!YTKACEMasterEnabled() ||
        ![YTKACEBrowseIdentifier(controller) isEqualToString:YTKACEPivotIdentifier] ||
        objc_getAssociatedObject(controller, YTKACEDownloadsAssociation) != nil) {
        return;
    }
    YTKACEDownloadsController *downloads = [YTKACEDownloadsController new];
    [controller addChildViewController:downloads];
    downloads.view.frame = controller.view.bounds;
    downloads.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:downloads.view];
    [downloads didMoveToParentViewController:controller];
    objc_setAssociatedObject(controller,
                             YTKACEDownloadsAssociation,
                             downloads,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTKACETryAttachDownloads(UIViewController *controller) {
    YTKACEAttachDownloads(controller);
    if (objc_getAssociatedObject(controller, YTKACEDownloadsAssociation) == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEAttachDownloads(controller);
        });
    }
}

static void YTKACEAppViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalAppViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalAppViewDidLoad)(receiver, selector);
    }
    YTKACETryAttachDownloads(receiver);
}

static void YTKACEBrowseViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalBrowseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseViewDidLoad)(receiver, selector);
    }
    YTKACETryAttachDownloads(receiver);
}

static void YTKACEBrowseResponseViewDidLoad(UIViewController *receiver,
                                            SEL selector) {
    if (OriginalBrowseResponseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseResponseViewDidLoad)(receiver, selector);
    }
    YTKACETryAttachDownloads(receiver);
}

static void YTKACEWrapperViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalWrapperViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalWrapperViewDidLoad)(receiver, selector);
    }
    YTKACETryAttachDownloads(receiver);
}

static id YTKACETabValue(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static NSString *YTKACETabToken(id item) {
    for (NSString *selectorName in @[
        @"pivotIdentifier",
        @"tabIdentifier",
        @"browseId"
    ]) {
        id value = YTKACETabValue(item, @[selectorName]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return [value lowercaseString];
        }
    }
    NSArray<NSString *> *activeRenderers =
        YTKACEInteger(item, @"hasPivotBarItemRenderer") != 0
            ? @[@"pivotBarItemRenderer"]
            : (YTKACEInteger(item, @"hasPivotBarIconOnlyItemRenderer") != 0
                ? @[@"pivotBarIconOnlyItemRenderer"]
                : @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer"]);
    for (NSString *rendererName in activeRenderers) {
        id nested = YTKACETabValue(item, @[rendererName]);
        if (nested != nil && nested != item) {
            NSString *token = YTKACETabToken(nested);
            if (token.length != 0) {
                return token;
            }
        }
    }
    id renderer = YTKACETabValue(item, @[@"renderer"]);
    if (renderer != nil && renderer != item) {
        NSString *token = YTKACETabToken(renderer);
        if (token.length != 0) {
            return token;
        }
    }
    id endpoint = YTKACETabValue(item, @[@"navigationEndpoint", @"endpoint"]);
    id browseEndpoint = YTKACETabValue(endpoint, @[@"browseEndpoint"]);
    id browseID = YTKACETabValue(browseEndpoint ?: endpoint, @[@"browseId"]);
    if ([browseID isKindOfClass:NSString.class] && [browseID length] != 0) {
        return [browseID lowercaseString];
    }
    id identifier = YTKACETabValue(item, @[@"identifier"]);
    return [identifier isKindOfClass:NSString.class]
        ? [identifier lowercaseString]
        : @"";
}

static NSMutableDictionary<NSString *, NSString *> *YTKACEStartupIdentifiers;

static NSString *YTKACERawTabIdentifier(id item, NSUInteger depth) {
    if (item == nil || depth > 3) return nil;
    for (NSString *name in @[@"pivotIdentifier", @"tabIdentifier", @"browseId"]) {
        id value = YTKACETabValue(item, @[name]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    for (NSString *name in @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer",
                             @"renderer", @"navigationEndpoint", @"endpoint",
                             @"browseEndpoint"]) {
        id nested = YTKACETabValue(item, @[name]);
        if (nested == nil || nested == item) continue;
        NSString *found = YTKACERawTabIdentifier(nested, depth + 1);
        if (found.length != 0) return found;
    }
    return nil;
}

static void YTKACENoteStartupIdentifier(NSString *canonical, id item) {
    if (canonical.length == 0) return;
    NSString *identifier = YTKACERawTabIdentifier(item, 0);
    if (identifier.length == 0) return;
    if (YTKACEStartupIdentifiers == nil) {
        YTKACEStartupIdentifiers = [NSMutableDictionary dictionary];
    }
    if ([YTKACEStartupIdentifiers[canonical] isEqualToString:identifier]) return;
    YTKACEStartupIdentifiers[canonical] = identifier;
    [NSUserDefaults.standardUserDefaults
        setObject:YTKACEStartupIdentifiers.allKeys
           forKey:@"YTKACE.Preference.Tabs.Known"];
}

// The playlist picked for the Playlist tab, as a browse id (VL + playlist id).
static NSString *YTKACECustomPlaylistBrowseID(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Tabs.CustomPlaylist"];
    if (![stored isKindOfClass:NSString.class] || [stored length] == 0) return nil;
    return [@"VL" stringByAppendingString:stored];
}

// Playlist ids are random letters, so match the Playlist tab exactly and
// before the other tabs' substring checks.
static BOOL YTKACEIsCustomPlaylistToken(NSString *token) {
    NSString *browseID = YTKACECustomPlaylistBrowseID();
    return browseID != nil && [token isEqualToString:browseID.lowercaseString];
}

static NSString *YTKACEHideKeyForToken(NSString *token) {
    if (YTKACEIsCustomPlaylistToken(token)) return @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist";
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"YTKACE.Preference.Tabs.Hidden.News";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"YTKACE.Preference.Tabs.Hidden.History";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Notifs";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"YTKACE.Preference.Tabs.Hidden.WatchLater";
    }
    if ([token containsString:@"short"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Library";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Home";
    }
    return nil;
}

static NSString *YTKACECanonicalTabToken(NSString *token) {
    if (YTKACEIsCustomPlaylistToken(token)) return @"customplaylist";
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"news";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"history";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"notifications";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"watchlater";
    }
    if ([token containsString:@"short"] || [token containsString:@"reel"]) {
        return @"shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"you";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"home";
    }
    return token;
}

static NSArray *YTKACETabItems(id renderer, NSString **setterName) {
    NSArray<NSString *> *getters = @[
        @"itemsArray",
        @"items",
        @"pivotBarItemsArray",
        @"pivotBarItems"
    ];
    NSArray<NSString *> *setters = @[
        @"setItemsArray:",
        @"setItems:",
        @"setPivotBarItemsArray:",
        @"setPivotBarItems:"
    ];
    for (NSUInteger index = 0; index < getters.count; index++) {
        id value = YTKACETabValue(renderer, @[getters[index]]);
        if ([value isKindOfClass:NSArray.class]) {
            if (setterName != NULL) {
                *setterName = setters[index];
            }
            return value;
        }
    }
    return nil;
}

static NSInteger YTKACETabOrderIndex(NSString *token, NSArray *order) {
    NSString *canonical = YTKACECanonicalTabToken(token);
    for (NSUInteger index = 0; index < order.count; index++) {
        id value = order[index];
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *entry = [value lowercaseString];
        if ([canonical isEqualToString:entry] ||
            [canonical isEqualToString:YTKACECanonicalTabToken(entry)]) {
            return (NSInteger)index;
        }
    }
    for (NSUInteger index = 0; index < order.count; index++) {
        id value = order[index];
        if (![value isKindOfClass:NSString.class]) continue;
        if ([token containsString:[value lowercaseString]]) return (NSInteger)index;
    }
    return NSIntegerMax;
}

static void YTKACESetTabTitle(id target, NSString *text) {
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    id value = text;
    if (formattedClass != Nil && [formattedClass respondsToSelector:formattedSelector]) {
        value = ((id (*)(id, SEL, id))objc_msgSend)(
            formattedClass,
            formattedSelector,
            text
        );
    }
    SEL selector = NSSelectorFromString(@"setTitle:");
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
    }
}

static void YTKACEApplyTabName(id item, NSString *token) {
    NSDictionary *names =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTKACE.Preference.Tabs.Names"];
    NSString *replacement = names[token] ?: names[YTKACECanonicalTabToken(token)];
    if (![replacement isKindOfClass:NSString.class] || replacement.length == 0) {
        return;
    }
    id target = YTKACETabValue(item, @[
        @"pivotBarItemRenderer",
        @"pivotBarIconOnlyItemRenderer"
    ]) ?: item;
    YTKACESetTabTitle(target, replacement);
}

static BOOL YTKACETabFieldSet(id message, NSString *field) {
    NSString *suffix = [[field substringToIndex:1].uppercaseString stringByAppendingString:[field substringFromIndex:1]];
    SEL has = NSSelectorFromString([@"has" stringByAppendingString:suffix]);
    return ![message respondsToSelector:has] || ((BOOL (*)(id, SEL))objc_msgSend)(message, has);
}

static NSString *YTKACETabSetter(NSString *field) {
    return [NSString stringWithFormat:@"set%@%@:", [field substringToIndex:1].uppercaseString,
                                      [field substringFromIndex:1]];
}

static int32_t YTKACEOneofCase(id message, NSString *oneof) {
    SEL selector = NSSelectorFromString([oneof stringByAppendingString:@"OneOfCase"]);
    return [message respondsToSelector:selector] ? ((int32_t (*)(id, SEL))objc_msgSend)(message, selector) : 0;
}

static const int32_t YTKACEIconOnlyItemCase = 318370163;

static id YTKACELabeledTab(id item) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") ||
        YTKACEOneofCase(item, @"items") != YTKACEIconOnlyItemCase) {
        return item;
    }
    id iconOnly = YTKACEValue(item, @"pivotBarIconOnlyItemRenderer");
    id label = YTKACEValue(YTKACEValue(YTKACEValue(iconOnly, @"accessibility"), @"accessibilityData"), @"label");
    id renderer = YTKACENew(@"YTIPivotBarItemRenderer");
    id supported = YTKACENew(@"YTIPivotBarSupportedRenderers");
    if (![label isKindOfClass:NSString.class] || [label length] == 0 || renderer == nil || supported == nil) {
        return item;
    }
    for (NSString *field in @[@"pivotIdentifier", @"targetId", @"navigationEndpoint", @"accessibility",
                              @"presentationStyle", @"trackingParams", @"progressIndicator",
                              @"onSelected", @"onDeselected", @"indicator", @"onLongPress"]) {
        if (YTKACETabFieldSet(iconOnly, field)) {
            YTKACESetValue(renderer, YTKACETabSetter(field), YTKACEValue(iconOnly, field));
        }
    }
    NSString *image = @{@5: @"icon", @10: @"thumbnail", @16: @"avatar"}[@(YTKACEOneofCase(iconOnly, @"image"))];
    if (image != nil) {
        YTKACESetValue(renderer, YTKACETabSetter(image), YTKACEValue(iconOnly, image));
    }
    for (NSString *field in @[@"navigationType", @"notificationSelectionBehavior", @"isDisabled"]) {
        SEL getter = NSSelectorFromString(field);
        SEL setter = NSSelectorFromString(YTKACETabSetter(field));
        if (![iconOnly respondsToSelector:getter] || ![renderer respondsToSelector:setter] ||
            !YTKACETabFieldSet(iconOnly, field)) {
            continue;
        }
        if ([field isEqualToString:@"isDisabled"]) {
            BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(iconOnly, getter);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(renderer, setter, value);
        } else {
            int32_t value = ((int32_t (*)(id, SEL))objc_msgSend)(iconOnly, getter);
            ((void (*)(id, SEL, int32_t))objc_msgSend)(renderer, setter, value);
        }
    }
    YTKACESetTabTitle(renderer, label);
    YTKACESetValue(supported, @"setPivotBarItemRenderer:", renderer);
    return supported;
}

static void YTKACEFillEmptyTabTitle(id item) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden")) return;
    id renderer = YTKACEValue(item, @"pivotBarItemRenderer");
    if (renderer == nil) return;
    id title = YTKACEValue(YTKACEValue(renderer, @"title"), @"stringWithFormattingRemoved");
    if ([title isKindOfClass:NSString.class] && [title length] != 0) return;
    id label = YTKACEValue(YTKACEValue(YTKACEValue(renderer, @"accessibility"), @"accessibilityData"), @"label");
    if (![label isKindOfClass:NSString.class] || [label length] == 0) return;
    YTKACESetTabTitle(renderer, label);
}

static BOOL YTKACEIsDownloadTab(id item) {
    NSString *token = YTKACETabToken(item);
    if ([token containsString:@"ytkace"]) {
        return YES;
    }
    NSString *identifier = YTKACERawTabIdentifier(item, 0);
    if (identifier.length != 0) {
        return [[identifier lowercaseString] containsString:@"ytkace"];
    }
    NSString *description = [[item description] lowercaseString];
    return [description containsString:@"feytkace"] ||
        [description containsString:@"ytkace"];
}

static void YTKACESetPivotRenderer(id receiver, SEL selector, id renderer) {
    if (renderer != nil) {
        NSString *setterName = nil;
        NSArray *items = YTKACETabItems(renderer, &setterName);
        if (items != nil) {
            NSMutableArray *filtered = [NSMutableArray array];
            BOOL hasDownloadTab = NO;
            for (id item in items) {
                id candidate = item;
                NSString *token = YTKACETabToken(candidate);
                if (YTKACEIsDownloadTab(candidate)) {
                    BOOL duplicate = hasDownloadTab;
                    hasDownloadTab = YES;
                    YTKACENoteStartupIdentifier(@"ytkace", candidate);
                    if (!duplicate && YTKACEMasterEnabled() &&
                        ![NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.YTKACETab"]) {
                        [filtered addObject:candidate];
                    }
                    continue;
                }
                NSString *hideKey = YTKACEHideKeyForToken(token);
                YTKACENoteStartupIdentifier(YTKACECanonicalTabToken(token), candidate);
                if (YTKACEMasterEnabled() && hideKey != nil &&
                    [NSUserDefaults.standardUserDefaults boolForKey:hideKey]) {
                    continue;
                }
                if (YTKACEMasterEnabled() &&
                    [YTKACECanonicalTabToken(token) isEqualToString:@"create"]) {
                    [filtered addObject:candidate];
                    continue;
                }
                if (YTKACEMasterEnabled()) {
                    candidate = YTKACELabeledTab(candidate);
                    YTKACEApplyTabName(candidate, token);
                }
                [filtered addObject:candidate];
            }

            NSMutableArray<NSDictionary *> *extraTabs = [@[
                @{@"token": @"music", @"id": @"UC-9-kyTW8ZkZNDHQJ6FgpwQ",
                  @"title": @"Music", @"key": @"YTKACE.Preference.Tabs.Hidden.Music", @"icon": @1001},
                @{@"token": @"live", @"id": @"UC4R8DWoMoI7CAwX8_LjQHig",
                  @"title": @"Live", @"key": @"YTKACE.Preference.Tabs.Hidden.Live", @"icon": @1002},
                @{@"token": @"gaming", @"id": @"UCOpNcN46UbXVtpKMrmU4Abg",
                  @"title": @"Gaming", @"key": @"YTKACE.Preference.Tabs.Hidden.Gaming", @"icon": @1003},
                @{@"token": @"news", @"id": @"UCYfdidRxbB8Qhf0Nx7ioOYw",
                  @"title": @"News", @"key": @"YTKACE.Preference.Tabs.Hidden.News", @"icon": @1004},
                @{@"token": @"sports", @"id": @"UCEgdi0XIXXZ-qJOFPf4JSKw",
                  @"title": @"Sports", @"key": @"YTKACE.Preference.Tabs.Hidden.Sports", @"icon": @1005},
                @{@"token": @"learning", @"id": @"UCtFRv9O2AHqOZjjynzrv-xg",
                  @"title": @"Learning", @"key": @"YTKACE.Preference.Tabs.Hidden.Learning", @"icon": @1006},
                @{@"token": @"fashion", @"id": @"UCrpQ4p1Ql_hG8rKXIKM1MOQ",
                  @"title": @"Fashion", @"key": @"YTKACE.Preference.Tabs.Hidden.Fashion", @"icon": @1007},
                @{@"token": @"playlists", @"id": @"FEplaylist_aggregation",
                  @"title": @"Playlists", @"key": @"YTKACE.Preference.Tabs.Hidden.Playlists", @"icon": @1008},
                @{@"token": @"history", @"id": @"FEhistory",
                  @"title": @"History", @"key": @"YTKACE.Preference.Tabs.Hidden.History", @"icon": @1009},
                @{@"token": @"notifications", @"id": @"FEnotifications_inbox",
                  @"title": @"Notifs", @"key": @"YTKACE.Preference.Tabs.Hidden.Notifs", @"icon": @1010},
                @{@"token": @"watchlater", @"id": @"VLWL",
                  @"title": @"WLater", @"key": @"YTKACE.Preference.Tabs.Hidden.WatchLater", @"icon": @1011},
                @{@"token": @"posts", @"id": @"FEpost_home",
                  @"title": @"Posts", @"key": @"YTKACE.Preference.Tabs.Hidden.Posts", @"icon": @1012},
                @{@"token": @"subscriptions", @"id": @"FEsubscriptions",
                  @"title": YTKACELocalized(@"Subscriptions"),
                  @"key": @"YTKACE.Preference.Tabs.Hidden.Subscriptions",
                  @"icon": @(YTKACESubscriptionsIconType() > 0 ? YTKACESubscriptionsIconType() : 1013)}
            ] mutableCopy];
            NSString *playlistBrowseID = YTKACECustomPlaylistBrowseID();
            if (playlistBrowseID != nil) {
                [extraTabs addObject:@{@"token": @"customplaylist", @"id": playlistBrowseID,
                    @"title": @"Playlist", @"key": @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist", @"icon": @1014}];
            }
            NSMutableSet<NSString *> *present = [NSMutableSet set];
            for (id item in filtered) {
                [present addObject:YTKACECanonicalTabToken(YTKACETabToken(item))];
            }
            NSDictionary *customNames =
                [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTKACE.Preference.Tabs.Names"];
            for (NSDictionary *entry in extraTabs) {
                NSString *token = entry[@"token"];
                if ([NSUserDefaults.standardUserDefaults boolForKey:entry[@"key"]] ||
                    [present containsObject:token]) {
                    continue;
                }
                NSString *title = customNames[token] ?: entry[@"title"];
                id item = YTKACEMakeBrowsePivotItem(entry[@"id"],
                                                     title,
                                                     [entry[@"icon"] integerValue]);
                if (item != nil) {
                    id itemRenderer = YTKACEValue(item, @"pivotBarItemRenderer");
                    if (itemRenderer != nil) {
                        objc_setAssociatedObject(itemRenderer, YTKACEBuiltTabAssociation, @YES,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    YTKACENoteStartupIdentifier(token, item);
                    [filtered addObject:item];
                    [present addObject:token];
                }
            }

            if (YTKACEMasterEnabled() && !hasDownloadTab &&
                ![NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.YTKACETab"]) {
                id downloadItem = YTKACEMakePivotItem();
                if (downloadItem != nil) {
                    YTKACENoteStartupIdentifier(@"ytkace", downloadItem);
                    [filtered addObject:downloadItem];
                }
            }

            if (YTKACEMasterEnabled()) {
                for (id item in filtered) {
                    if (![YTKACECanonicalTabToken(YTKACETabToken(item)) isEqualToString:@"create"]) {
                        YTKACEFillEmptyTabTitle(item);
                    }
                }
            }

            NSArray *order =
                [NSUserDefaults.standardUserDefaults arrayForKey:@"YTKACE.Preference.Tabs.Order"];
            if (YTKACEMasterEnabled() && order.count != 0) {
                [filtered sortUsingComparator:^NSComparisonResult(id left, id right) {
                    NSInteger leftIndex =
                        YTKACETabOrderIndex(YTKACETabToken(left), order);
                    NSInteger rightIndex =
                        YTKACETabOrderIndex(YTKACETabToken(right), order);
                    if (leftIndex == rightIndex) {
                        return NSOrderedSame;
                    }
                    return leftIndex < rightIndex
                        ? NSOrderedAscending
                        : NSOrderedDescending;
                }];
            }

            NSString *firstIdentifier = filtered.count != 0 ? YTKACERawTabIdentifier(filtered.firstObject, 0) : nil;
            if (firstIdentifier.length != 0) YTKACEFirstVisiblePivot = [firstIdentifier copy];
            SEL setter = NSSelectorFromString(setterName);
            if ([items isKindOfClass:NSMutableArray.class]) {
                [(NSMutableArray *)items setArray:filtered];
            } else if ([renderer respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, filtered);
            }
        }
    }

    static Class floatingClass;
    if (floatingClass == Nil) floatingClass = NSClassFromString(@"YTFloatingPivotBarView");
    BOOL floating = floatingClass != Nil && [receiver isKindOfClass:floatingClass];
    if (floating) {
        NSArray *tabs = renderer != nil ? YTKACETabItems(renderer, NULL) : nil;
        YTKACEDebugLog(@"tabbar", @"floating bar renderer tabs=%lu", (unsigned long)tabs.count);
    }
    IMP original = floating ? OriginalSetFloatingPivotRenderer : OriginalSetPivotRenderer;
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, renderer);
    }
}

static id YTKACEItemRenderer(UIView *view);

static BOOL YTKACEItemFlag(UIView *item, const char *name) {
    Ivar flag = class_getInstanceVariable(object_getClass(item), name);
    return flag != NULL && strcmp(ivar_getTypeEncoding(flag), @encode(BOOL)) == 0 &&
        *(BOOL *)((uint8_t *)(__bridge void *)item + ivar_getOffset(flag));
}

static IMP OriginalIsIconsOnly;

static BOOL YTKACEIsIconsOnly(id receiver, SEL selector) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden")) return NO;
    return OriginalIsIconsOnly != NULL && ((BOOL (*)(id, SEL))OriginalIsIconsOnly)(receiver, selector);
}

static BOOL YTKACEYouTubeDropsTabTitle(UIView *item) {
    if (!YTKACEItemFlag(item, "_enableIconOnlyBottomNav") && !YTKACEItemFlag(item, "_enableIconOnlyOfflinePivotBar")) {
        return NO;
    }
    id renderer = YTKACEItemRenderer(item);
    if (renderer == nil) return NO;
    id title = YTKACEValue(YTKACEValue(renderer, @"title"), @"stringWithFormattingRemoved");
    return ![title isKindOfClass:NSString.class] || [title length] == 0;
}

static BOOL YTKACEYouTubeHidesTabLabels(UIView *item) {
    if (YTKACEYouTubeDropsTabTitle(item)) return YES;
    SEL getter = NSSelectorFromString(@"hideLabel");
    if ([item respondsToSelector:getter] && ((BOOL (*)(id, SEL))objc_msgSend)(item, getter)) return YES;
    SEL barGetter = NSSelectorFromString(@"hideItemLabels");
    for (UIView *bar = item.superview; bar != nil; bar = bar.superview) {
        if ([bar respondsToSelector:barGetter]) return ((BOOL (*)(id, SEL))objc_msgSend)(bar, barGetter);
    }
    return NO;
}

static BOOL YTKACETabLabelsHidden(UIView *item) {
    BOOL hidden = YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden");
    static Class floatingClass;
    if (floatingClass == Nil) floatingClass = NSClassFromString(@"YTFloatingPivotBarView");
    SEL getter = NSSelectorFromString(@"hideLabel");
    SEL setter = NSSelectorFromString(@"setHideLabel:");
    if (floatingClass == Nil || ![item respondsToSelector:getter] || ![item respondsToSelector:setter]) {
        return hidden || YTKACEYouTubeHidesTabLabels(item);
    }
    UIView *bar = item.superview;
    while (bar != nil && ![bar isKindOfClass:floatingClass]) bar = bar.superview;
    if (bar == nil) return hidden || YTKACEYouTubeHidesTabLabels(item);
    if (((BOOL (*)(id, SEL))objc_msgSend)(item, getter) != hidden) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, hidden);
        [item setNeedsLayout];
    }
    return hidden || YTKACEYouTubeDropsTabTitle(item);
}

static void YTKACESetLabelsHidden(UIView *view, BOOL hidden) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) {
            subview.hidden = hidden;
            subview.alpha = hidden ? 0.0 : 1.0;
        }
        YTKACESetLabelsHidden(subview, hidden);
    }
}

static BOOL YTKACEInsidePivotItem(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return YES;
        }
    }
    return NO;
}

static UIView *YTKACEPivotItemAncestor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return current;
        }
    }
    return nil;
}

static void YTKACEPivotLabelSetHidden(UILabel *receiver,
                                      SEL selector,
                                      BOOL hidden) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") &&
        YTKACEInsidePivotItem(receiver)) {
        hidden = YES;
    }
    if (OriginalPivotLabelSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotLabelSetHidden)(
            receiver, selector, hidden
        );
    }
}

static void YTKACEPivotLabelSetAlpha(UILabel *receiver,
                                     SEL selector,
                                     CGFloat alpha) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") &&
        YTKACEInsidePivotItem(receiver)) {
        alpha = 0.0;
    }
    if (OriginalPivotLabelSetAlpha != NULL) {
        ((void (*)(id, SEL, CGFloat))OriginalPivotLabelSetAlpha)(
            receiver, selector, alpha
        );
    }
}

static UIImageView *YTKACEFindImageView(UIView *view);

static BOOL YTKACEContainsLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return YES;
    for (UIView *child in view.subviews) {
        if (YTKACEContainsLabel(child)) return YES;
    }
    return NO;
}

static void YTKACECollectIconCandidates(UIView *view,
                                        UIView *root,
                                        NSMutableArray<UIView *> *candidates) {
    if (view != root && ![view isKindOfClass:UILabel.class]) {
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        CGFloat width = CGRectGetWidth(view.bounds);
        CGFloat height = CGRectGetHeight(view.bounds);
        BOOL iconClass = [view isKindOfClass:UIImageView.class] ||
            [name containsString:@"icon"] || [name containsString:@"image"];
        BOOL iconSize = width >= 12.0 && height >= 12.0 &&
            width <= 64.0 && height <= 64.0;
        if ((view.tag == 0x59414345 || view.tag == YTKACEExtraIconTag ||
             iconClass) && iconSize) {
            [candidates addObject:view];
        }
    }
    for (UIView *child in view.subviews) {
        YTKACECollectIconCandidates(child, root, candidates);
    }
}

static UIView *YTKACEIconContainer(UIView *candidate, UIView *root) {
    UIView *container = candidate;
    while (container.superview != nil && container.superview != root) {
        UIView *parent = container.superview;
        if (YTKACEContainsLabel(parent) ||
            CGRectGetWidth(parent.bounds) > 80.0 ||
            CGRectGetHeight(parent.bounds) > 80.0) {
            break;
        }
        container = parent;
    }
    return container;
}

static void YTKACECenterPivotIcon(UIView *view, BOOL centered) {
    if (!centered) return;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    YTKACECollectIconCandidates(view, view, candidates);
    UIView *candidate = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    CGPoint rootCenter = CGPointMake(CGRectGetMidX(view.bounds),
                                     CGRectGetMidY(view.bounds));
    for (UIView *item in candidates) {
        CGPoint center = [item.superview convertPoint:item.center toView:view];
        CGFloat score = fabs(center.x - rootCenter.x) +
            fabs(CGRectGetWidth(item.bounds) - 24.0) * 0.25 +
            (item.hidden ? 100.0 : 0.0);
        if (item.tag == 0x59414345 || item.tag == YTKACEExtraIconTag) {
            score -= 1000.0;
        }
        if (score < bestScore) {
            bestScore = score;
            candidate = item;
        }
    }
    UIView *iconView = candidate == nil ? nil : YTKACEIconContainer(candidate, view);
    if (iconView == nil || iconView.superview == nil) return;
    CGPoint target = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds),
                                                     CGRectGetMidY(view.bounds))
                                toView:iconView.superview];
    iconView.center = target;
}

static UILabel *YTKACEFindNativeLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return (view.tag == 0x59414347 || view.tag == YTKACEExtraLabelTag)
            ? nil : (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *label = YTKACEFindNativeLabel(subview);
        if (label != nil) {
            return label;
        }
    }
    return nil;
}

static UIColor *YTKACETabForegroundColor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        UIColor *color = [current.backgroundColor
            resolvedColorWithTraitCollection:view.traitCollection];
        CGFloat red = 0.0;
        CGFloat green = 0.0;
        CGFloat blue = 0.0;
        CGFloat alpha = 0.0;
        if ([color getRed:&red green:&green blue:&blue alpha:&alpha] &&
            alpha > 0.2) {
            CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            return luminance < 0.5 ? UIColor.whiteColor : UIColor.blackColor;
        }
    }
    return [UIColor.labelColor
        resolvedColorWithTraitCollection:view.traitCollection];
}

static UIImageView *YTKACEFindImageView(UIView *view) {
    if ([view isKindOfClass:UIImageView.class]) {
        return (view.tag == 0x59414345 || view.tag == YTKACEExtraIconTag)
            ? nil : (UIImageView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIImageView *imageView = YTKACEFindImageView(subview);
        if (imageView != nil) {
            return imageView;
        }
    }
    return nil;
}

static BOOL YTKACEViewIsVisible(UIView *view) {
    if (view.window == nil) {
        return NO;
    }
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) {
            return NO;
        }
    }
    return YES;
}

static UIView *YTKACEFindDownloadsRoot(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"YTKACEDownloadsRoot"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *result = YTKACEFindDownloadsRoot(subview);
        if (result != nil) {
            return result;
        }
    }
    return nil;
}

static BOOL YTKACEDownloadsAreVisible(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *root = YTKACEFindDownloadsRoot(window);
            if (root != nil && YTKACEViewIsVisible(root)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL YTKACENativeTabRows(UIView *view, CGRect *iconFrame, CGRect *labelFrame) {
    for (UIView *sibling in view.superview.subviews) {
        if (sibling == view || ![NSStringFromClass(sibling.class) containsString:@"PivotBarItemView"]) {
            continue;
        }
        UIButton *button = YTKACEValue(sibling, @"navigationButton");
        if (![button isKindOfClass:UIButton.class]) continue;
        UILabel *label = button.titleLabel;
        UIImageView *image = button.imageView;
        if (label.hidden || label.alpha < 0.01 || label.text.length == 0 || CGRectIsEmpty(label.frame) ||
            image == nil || image.hidden || CGRectIsEmpty(image.frame)) {
            continue;
        }
        // Measure the rows inside the sibling tab, not relative to this one:
        // tabs share a size, but on a vertical tab bar (iPhone Duo) they are
        // stacked, so converting to this tab would shift by the tab offset.
        *iconFrame = [button convertRect:image.frame toView:sibling];
        *labelFrame = [button convertRect:label.frame toView:sibling];
        return YES;
    }
    return NO;
}

static void YTKACELayoutTabIconAndLabel(UIView *view, UIView *icon, UILabel *label, BOOL hideLabel) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat size = 24.0;
    CGFloat labelHeight = ceil(label.font.lineHeight);
    CGFloat iconY = hideLabel ? (height - size) * 0.5 : (height - size - 2.0 - labelHeight) * 0.5;
    CGFloat labelY = iconY + size + 2.0;
    CGRect nativeIcon = CGRectZero;
    CGRect nativeLabel = CGRectZero;
    if (!hideLabel && YTKACENativeTabRows(view, &nativeIcon, &nativeLabel)) {
        iconY = CGRectGetMidY(nativeIcon) - size * 0.5;
        labelY = CGRectGetMinY(nativeLabel);
        labelHeight = CGRectGetHeight(nativeLabel);
    }
    icon.frame = CGRectMake((width - size) * 0.5, iconY, size, size);
    label.frame = CGRectMake(0.0, labelY, width, labelHeight);
}

static void YTKACERestorePivotItem(UIView *view,
                                   UILabel *nativeLabel,
                                   BOOL hideLabel) {
    [[view viewWithTag:0x59414347] removeFromSuperview];
    [[view viewWithTag:0x59414345] removeFromSuperview];
    objc_setAssociatedObject(view,
                             YTKACETabAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (nativeLabel != nil) {
        nativeLabel.hidden = hideLabel;
        nativeLabel.alpha = 1.0;
    }
    UIImageView *nativeImageView = YTKACEFindImageView(view);
    if (nativeImageView != nil) {
        nativeImageView.hidden = NO;
    }
}

static void YTKACEApplyDownloadIcon(UIView *view) {
    UILabel *nativeLabel = YTKACEFindNativeLabel(view);
    NSString *token = YTKACETabToken(view);
    NSString *text = nativeLabel.text ?: @"";
    BOOL exactIdentifier = [token isEqualToString:@"feytkace"];
    BOOL exactLabel = [text caseInsensitiveCompare:@"YTKACE"] == NSOrderedSame;
    BOOL associated = [objc_getAssociatedObject(
        view,
        YTKACETabAssociation
    ) boolValue];
    BOOL definiteOther = (token.length != 0 && !exactIdentifier) ||
        (text.length != 0 && !exactLabel);
    BOOL hideLabel = YTKACETabLabelsHidden(view);
    if (definiteOther) {
        YTKACERestorePivotItem(view, nativeLabel, hideLabel);
        return;
    }
    BOOL recognized = exactIdentifier || exactLabel || associated;
    if (!recognized) {
        return;
    }
    objc_setAssociatedObject(view,
                             YTKACETabAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIImageView *nativeImageView = YTKACEFindImageView(view);
    UIColor *tabColor = YTKACETabForegroundColor(view);
    UILabel *label = (UILabel *)[view viewWithTag:0x59414347];
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = 0x59414347;
        label.text = @"YTKACE";
        label.font = nativeLabel.font ?: [UIFont systemFontOfSize:10.0];
        label.textAlignment = NSTextAlignmentCenter;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleTopMargin;
        [view addSubview:label];
    }
    label.textColor = tabColor;
    label.hidden = hideLabel;
    label.alpha = 1.0;
    BOOL selected = [objc_getAssociatedObject(
        view,
        YTKACETabSelectedAssociation
    ) boolValue];
    SEL selectedSelector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selectedSelector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selectedSelector);
    }
    selected = selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0) ||
        YTKACEDownloadsAreVisible();
    if ([objc_getAssociatedObject(view, YTKACETabDragOutAssociation) boolValue]) selected = NO;
    UIImage *image = YTKACEDownloadTabImage(selected);
    UIImageView *imageView = (UIImageView *)[view viewWithTag:0x59414345];
    if (imageView == nil) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x59414345;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleBottomMargin;
        [view addSubview:imageView];
    }
    if (nativeImageView != nil && nativeImageView != imageView) {
        nativeImageView.hidden = YES;
    }
    imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    imageView.tintColor = tabColor;
    imageView.hidden = NO;
    YTKACELayoutTabIconAndLabel(view, imageView, label, hideLabel);
}

static NSDictionary *YTKACEExtraTabIcon(NSString *token) {
    static NSDictionary *icons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icons = @{
            @"music": @[@"yt_outline_music_24pt_3x_Normal",
                         @"music_24pt_3x_Normal",
                         @"music.note", @"music.note"],
            @"live": @[@"live_24pt_3x_Normal", @"ic_youtube_live_3x_Normal",
                        @"dot.radiowaves.left.and.right",
                        @"dot.radiowaves.left.and.right"],
            @"gaming": @[@"gaming_24pt_3x_Normal",
                          @"gaming_24pt_3x_Normal_fill",
                          @"gamecontroller", @"gamecontroller.fill"],
            @"news": @[@"news_24pt_3x_Normal", @"news_24pt_3x_Normal",
                        @"newspaper", @"newspaper.fill"],
            @"sports": @[@"G_sport", @"G_sport_fill",
                          @"trophy", @"trophy.fill"],
            @"learning": @[@"G_Learning", @"G_Learning_fill",
                            @"graduationcap", @"graduationcap.fill"],
            @"fashion": @[@"fashion_24pt_3x_Normal",
                           @"fashion_24pt_3x_Normal",
                           @"tshirt", @"tshirt.fill"],
            @"playlists": @[@"playlist", @"playlist_fill",
                             @"music.note.list", @"music.note.list"],
            @"history": @[@"history", @"history_fill",
                           @"clock.arrow.circlepath",
                           @"clock.arrow.circlepath"],
            @"notifications": @[@"ic_notifications_none_3x_Normal",
                                 @"ic_notifications_3x_Normal",
                                 @"bell", @"bell.fill"],
            @"customplaylist": @[@"playlist", @"playlist_fill",
                                  @"list.bullet.rectangle", @"list.bullet.rectangle.fill"],
            @"watchlater": @[@"clock_24pt_3x_Normal",
                              @"yt_fill_clock_24pt_3x_Normal",
                              @"clock", @"clock.fill"],
            @"posts": @[@"", @"",
                         @"bubble.left.and.bubble.right",
                         @"bubble.left.and.bubble.right.fill"],
            @"subscriptions": @[@"youtube_outline/subscriptions_cairo_24pt", @"youtube_fill/subscriptions_cairo_24pt",
                                 @"rectangle.stack", @"rectangle.stack.fill"]
        };
    });
    NSArray *values = icons[token];
    return values == nil ? nil : @{
        @"normalAsset": values[0],
        @"selectedAsset": values[1],
        @"normalSymbol": values[2],
        @"selectedSymbol": values[3]
    };
}

static BOOL YTKACEPivotItemSelected(UIView *view) {
    if ([objc_getAssociatedObject(view, YTKACETabDragOutAssociation) boolValue]) return NO;
    BOOL selected = [objc_getAssociatedObject(
        view,
        YTKACETabSelectedAssociation
    ) boolValue];
    SEL selector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selector);
    }
    return selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0);
}

static id YTKACEItemRenderer(UIView *view) {
    id renderer = nil;
    @try {
        renderer = [view valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    return renderer;
}

static BOOL YTKACEIsBuiltTab(id renderer) {
    if (renderer == nil) return NO;
    id nested = YTKACEValue(renderer, @"pivotBarItemRenderer");
    return objc_getAssociatedObject(renderer, YTKACEBuiltTabAssociation) != nil ||
        (nested != nil && objc_getAssociatedObject(nested, YTKACEBuiltTabAssociation) != nil);
}

static void YTKACEApplyExtraTabIcon(UIView *view) {
    NSString *token = YTKACECanonicalTabToken(YTKACETabToken(view));
    id renderer = token.length == 0 || [token isEqualToString:@"subscriptions"]
        ? YTKACEItemRenderer(view) : nil;
    if (token.length == 0) token = YTKACECanonicalTabToken(YTKACETabToken(renderer));
    NSDictionary *config = YTKACEExtraTabIcon(token);
    if (config == nil) {
        UILabel *nativeLabel = YTKACEFindNativeLabel(view);
        NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@ %@",
            nativeLabel.text ?: @"", view.accessibilityLabel ?: @"",
            view.accessibilityIdentifier ?: @"", view.description ?: @""] lowercaseString];
        NSDictionary *aliases = @{
            @"music": @[@"music"],
            @"live": @[@"live"],
            @"gaming": @[@"gaming"],
            @"news": @[@"news"],
            @"sports": @[@"sports"],
            @"learning": @[@"learning"],
            @"fashion": @[@"fashion"],
            @"playlists": @[@"playlists", @"playlist"],
            @"history": @[@"history"],
            @"notifications": @[@"notifs", @"notifications"],
            @"watchlater": @[@"wlater", @"watch later"],
            @"posts": @[@"posts", @"post"]
        };
        for (NSString *candidate in aliases) {
            for (NSString *alias in aliases[candidate]) {
                if ([hint containsString:alias]) {
                    token = candidate;
                    config = YTKACEExtraTabIcon(token);
                    break;
                }
            }
            if (config != nil) break;
        }
    }
    if ([token isEqualToString:@"subscriptions"] &&
        (!YTKACEIsBuiltTab(renderer) || YTKACESubscriptionsIconType() > 0)) {
        config = nil;
    }
    if (config == nil) {
        [[view viewWithTag:YTKACEExtraIconTag] removeFromSuperview];
        [[view viewWithTag:YTKACEExtraLabelTag] removeFromSuperview];
        return;
    }
    UIImageView *nativeImage = YTKACEFindImageView(view);
    if (nativeImage != nil) {
        nativeImage.hidden = YES;
    }
    UIImageView *icon = (UIImageView *)[view viewWithTag:YTKACEExtraIconTag];
    if (icon == nil) {
        icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.tag = YTKACEExtraIconTag;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.userInteractionEnabled = NO;
        [view addSubview:icon];
    }
    BOOL selected = YTKACEPivotItemSelected(view);
    NSString *asset = config[selected ? @"selectedAsset" : @"normalAsset"];
    NSString *symbol = config[selected ? @"selectedSymbol" : @"normalSymbol"];
    UIImage *image = YTKACEAssetImage(asset, nil) ?:
        YTKACEYouTubeImage(asset.length != 0 ? @[asset] : @[], symbol);
    if (image == nil) {
        image = [UIImage systemImageNamed:@"circle"];
    }
    icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    icon.tintColor = YTKACETabForegroundColor(view);
    icon.hidden = NO;
    BOOL hideLabel = YTKACETabLabelsHidden(view);
    UILabel *nativeLabel = YTKACEFindNativeLabel(view);
    UILabel *label = (UILabel *)[view viewWithTag:YTKACEExtraLabelTag];
    NSString *title = nativeLabel.text.length != 0
        ? nativeLabel.text : label.text;
    UIFont *font = nativeLabel.font ?: label.font;
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = YTKACEExtraLabelTag;
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        [view addSubview:label];
    }
    label.text = title;
    label.font = font ?: [UIFont systemFontOfSize:10.0];
    label.textColor = icon.tintColor;
    label.hidden = hideLabel;
    label.alpha = hideLabel ? 0.0 : 1.0;
    YTKACELayoutTabIconAndLabel(view, icon, label, hideLabel);
}

static NSString *const YTKACETintModeKey = @"YTKACE.Preference.Tabs.SelectedTint";
static NSString *const YTKACETintColorKey = @"YTKACE.Preference.Tabs.SelectedTintColor";
static const void *YTKACENativeTextColorAssociation = &YTKACENativeTextColorAssociation;
static const void *YTKACENativeIconAssociation = &YTKACENativeIconAssociation;
static IMP OriginalPivotLabelSetTextColor;
static NSInteger YTKACETintMode;
static UIColor *YTKACETintColor;

static NSString *YTKACEPivotItemIdentifier(UIView *item);
static UIImageView *YTKACEFindPhotoView(UIView *view);

static BOOL YTKACERefreshTabTint(void) {
    NSInteger mode = [YTKACEPreferenceObject(YTKACETintModeKey) integerValue];
    id stored = YTKACEPreferenceObject(YTKACETintColorKey);
    NSString *value = [[([stored isKindOfClass:NSString.class] ? stored : @"#0A84FF")
        stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    unsigned int rgb = 0x0A84FF;
    if (value.length == 6) [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    UIColor *color = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
    BOOL changed = mode != YTKACETintMode || ![color isEqual:YTKACETintColor];
    YTKACETintMode = mode;
    YTKACETintColor = color;
    return changed;
}

static void YTKACESetLabelColor(UILabel *label, UIColor *color) {
    if (color == nil || [label.textColor isEqual:color]) return;
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(label, @selector(setTextColor:), color);
    } else {
        label.textColor = color;
    }
}

static void YTKACEPivotLabelSetTextColor(UILabel *receiver, SEL selector, UIColor *color) {
    if (YTKACETintMode != 0) {
        UIView *item = YTKACEPivotItemAncestor(receiver);
        if (item != nil) {
            objc_setAssociatedObject(receiver, YTKACENativeTextColorAssociation, color,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (YTKACEPivotItemSelected(item)) color = YTKACETintColor;
        }
    }
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(receiver, selector, color);
    }
}

static void YTKACECollectLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)subview];
        YTKACECollectLabels(subview, labels);
    }
}

static void YTKACEApplyTabTint(UIView *item) {
    BOOL tinted = YTKACETintMode != 0 && YTKACEPivotItemSelected(item);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    YTKACECollectLabels(item, labels);
    for (UILabel *label in labels) {
        UIColor *native = objc_getAssociatedObject(label, YTKACENativeTextColorAssociation);
        if (YTKACETintMode == 0) {
            if (native == nil) continue;
            objc_setAssociatedObject(label, YTKACENativeTextColorAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTKACESetLabelColor(label, native);
            continue;
        }
        if (native == nil && label.textColor != nil && ![label.textColor isEqual:YTKACETintColor]) {
            native = label.textColor;
            objc_setAssociatedObject(label, YTKACENativeTextColorAssociation, native,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        YTKACESetLabelColor(label, tinted ? YTKACETintColor : native);
    }
    BOOL avatar = [YTKACEPivotItemIdentifier(item) isEqualToString:@"FElibrary"] &&
        YTKACEFindPhotoView(item) != nil;
    BOOL tintIcon = tinted && YTKACETintMode == 2 && !avatar;
    for (NSNumber *tag in @[@0x59414345, @(YTKACEExtraIconTag)]) {
        UIView *custom = [item viewWithTag:tag.integerValue];
        if (tintIcon && [custom isKindOfClass:UIImageView.class]) custom.tintColor = YTKACETintColor;
    }
    UIImageView *icon = YTKACEFindImageView(item);
    NSArray *native = icon != nil ? objc_getAssociatedObject(icon, YTKACENativeIconAssociation) : nil;
    if (native == nil) return;
    objc_setAssociatedObject(icon, YTKACENativeIconAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (icon.image == native[1]) icon.image = native[0];
    icon.tintColor = native[2];
}

static IMP OriginalIconTintSelected;

static UIColor *YTKACEIconTintSelected(UIView *receiver, SEL selector) {
    if (YTKACETintMode == 2 && ![YTKACEPivotItemIdentifier(receiver) isEqualToString:@"FElibrary"]) {
        return YTKACETintColor;
    }
    return OriginalIconTintSelected == NULL ? nil
        : ((id (*)(id, SEL))OriginalIconTintSelected)(receiver, selector);
}

static void YTKACERestyleSelectedTab(UIView *item) {
    SEL setter = NSSelectorFromString(@"setSelected:");
    if (!YTKACEPivotItemSelected(item) || ![item respondsToSelector:setter]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, YES);
}

static void YTKACEApplyPivotItemPresentation(UIView *view) {
    BOOL hideLabels = YTKACETabLabelsHidden(view);
    YTKACESetLabelsHidden(view, hideLabels);
    YTKACEApplyDownloadIcon(view);
    YTKACEApplyExtraTabIcon(view);
    YTKACECenterPivotIcon(view, hideLabels);
    YTKACEApplyTabTint(view);
}

static void YTKACEPivotButtonLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotButtonLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotButtonLayout)(receiver, selector);
    }
    if (YTKACETintMode != 0) {
        UIView *tintItem = YTKACEPivotItemAncestor(receiver);
        if (tintItem != nil) YTKACEApplyTabTint(tintItem);
    }
    UIView *item = YTKACEPivotItemAncestor(receiver);
    if (item == nil || CGRectIsEmpty(item.bounds) || !YTKACETabLabelsHidden(item)) return;
    YTKACESetLabelsHidden(receiver, YES);
    UIImageView *icon = nil;
    for (UIView *child in receiver.subviews) {
        if (![child isKindOfClass:UIImageView.class] || child.hidden ||
            CGRectGetWidth(child.bounds) < 12.0 ||
            CGRectGetHeight(child.bounds) < 12.0) {
            continue;
        }
        icon = (UIImageView *)child;
        break;
    }
    if (icon == nil) return;
    CGPoint target = [item convertPoint:CGPointMake(CGRectGetMidX(item.bounds),
                                                    CGRectGetMidY(item.bounds))
                                  toView:receiver];
    icon.center = target;
}

static BOOL YTKACEContainsCreateText(NSString *value) {
    NSString *text = value.lowercaseString;
    return [text containsString:@"create"] ||
        [text containsString:@"upload"] ||
        [text containsString:@"add video"];
}

static void YTKACEHideCreateViews(UIView *view) {
    BOOL hideCreate = [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Create"];
    for (UIView *subview in view.subviews) {
        NSString *label = subview.accessibilityLabel;
        NSString *identifier = subview.accessibilityIdentifier;
        NSString *className = NSStringFromClass(subview.class);
        if (hideCreate &&
            (YTKACEContainsCreateText(label) ||
             YTKACEContainsCreateText(identifier) ||
             YTKACEContainsCreateText(className))) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
        }
        YTKACEHideCreateViews(subview);
    }
}

static NSString * const YTKACETabBarGlassModeKey = @"YTKACE.Preference.Tabs.GlassMode";

NSInteger YTKACETabBarGlassMode(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:YTKACETabBarGlassModeKey];
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return [defaults boolForKey:@"YTKACE.Preference.Tabs.Glass"] ? 1 : 0;
}

BOOL YTKACETabBarOwnGlass(void) {
    return YTKACETabBarGlassMode() == 1;
}

static IMP YTKACEOrigYouTubeGlass;
static IMP YTKACEOrigYouTubeGlassImpl;
static IMP YTKACEOrigGlassAvailable;
static IMP YTKACEOrigGlassCompute;
static IMP YTKACEOrigPivotGlassEffect;
static IMP YTKACEOrigPivotGlassEffectStyle;

static BOOL YTKACEForcedYouTubeGlass(IMP original, id receiver, SEL selector) {
    NSInteger mode = YTKACETabBarGlassMode();
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    YTKACEDebugLog(@"glass", @"%@ %@ original=%d mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return YES;
    if (mode == 1 || mode == 3) return NO;
    return value;
}

static BOOL YTKACEYouTubeGlass(id receiver, SEL selector) {
    return YTKACEForcedYouTubeGlass(YTKACEOrigYouTubeGlass, receiver, selector);
}

static BOOL YTKACEYouTubeGlassImpl(id receiver, SEL selector) {
    return YTKACEForcedYouTubeGlass(YTKACEOrigYouTubeGlassImpl, receiver, selector);
}

static BOOL YTKACEGlassAvailableValue(IMP original, id receiver, SEL selector) {
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    YTKACEDebugLog(@"glass", @"M3CLiquidGlass %@ original=%d", NSStringFromSelector(selector), value);
    if (YTKACETabBarGlassMode() == 2 && NSClassFromString(@"UIGlassEffect") != Nil) return YES;
    return value;
}

static BOOL YTKACEGlassAvailable(id receiver, SEL selector) {
    return YTKACEGlassAvailableValue(YTKACEOrigGlassAvailable, receiver, selector);
}

static BOOL YTKACEGlassCompute(id receiver, SEL selector) {
    return YTKACEGlassAvailableValue(YTKACEOrigGlassCompute, receiver, selector);
}

static id YTKACEPivotGlassValue(id value, SEL selector) {
    NSInteger mode = YTKACETabBarGlassMode();
    YTKACEDebugLog(@"glass", @"YTPivotBarView %@ effect=%@ mode=%ld", NSStringFromSelector(selector),
                   value != nil ? NSStringFromClass([value class]) : @"nil", (long)mode);
    return mode == 1 || mode == 3 ? nil : value;
}

static id YTKACEPivotGlassEffect(id receiver, SEL selector) {
    id value = ((id (*)(id, SEL))YTKACEOrigPivotGlassEffect)(receiver, selector);
    return YTKACEPivotGlassValue(value, selector);
}

static id YTKACEPivotGlassEffectStyle(id receiver, SEL selector, NSInteger style) {
    id value = ((id (*)(id, SEL, NSInteger))YTKACEOrigPivotGlassEffectStyle)(receiver, selector, style);
    return YTKACEPivotGlassValue(value, selector);
}

static IMP YTKACEOrigFloatyBars;
static IMP YTKACEOrigFloatyBarsImpl;
static IMP YTKACEOrigFloatingStyle;
static IMP YTKACEOrigFloatingStyleImpl;
static IMP YTKACEOrigPivotSetFloatingStyle;

static BOOL YTKACEFloatyValue(IMP original, id receiver, SEL selector) {
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    NSInteger mode = YTKACETabBarGlassMode();
    YTKACEDebugLog(@"glass", @"%@ %@ original=%d mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return YES;
    if (mode == 1 || mode == 3) return NO;
    return value;
}

static BOOL YTKACEFloatyBars(id receiver, SEL selector) {
    return YTKACEFloatyValue(YTKACEOrigFloatyBars, receiver, selector);
}

static BOOL YTKACEFloatyBarsImpl(id receiver, SEL selector) {
    return YTKACEFloatyValue(YTKACEOrigFloatyBarsImpl, receiver, selector);
}

static long long YTKACEFloatingStyleValue(IMP original, id receiver, SEL selector) {
    long long value = original != NULL ? ((long long (*)(id, SEL))original)(receiver, selector) : 0;
    NSInteger mode = YTKACETabBarGlassMode();
    YTKACEDebugLog(@"glass", @"%@ %@ original=%lld mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return 2;
    if (mode == 1 || mode == 3) return 0;
    return value;
}

static long long YTKACEFloatingStyle(id receiver, SEL selector) {
    return YTKACEFloatingStyleValue(YTKACEOrigFloatingStyle, receiver, selector);
}

static long long YTKACEFloatingStyleImpl(id receiver, SEL selector) {
    return YTKACEFloatingStyleValue(YTKACEOrigFloatingStyleImpl, receiver, selector);
}

static void YTKACEPivotSetFloatingStyle(id receiver, SEL selector, long long style) {
    NSInteger mode = YTKACETabBarGlassMode();
    if ((mode == 1 || mode == 3) && style == 2) style = 0;
    ((void (*)(id, SEL, long long))YTKACEOrigPivotSetFloatingStyle)(receiver, selector, style);
}

static BOOL YTKACEMethodTypesMatch(Class cls, NSString *selector, BOOL meta, const char *prefix) {
    Method method = meta ? class_getClassMethod(cls, NSSelectorFromString(selector))
                         : class_getInstanceMethod(cls, NSSelectorFromString(selector));
    const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
    return types != NULL && strncmp(types, prefix, strlen(prefix)) == 0;
}

static IMP YTKACEOrigInfoDictionary;
static IMP YTKACEOrigInfoObject;
static NSString * const YTKACEDesignCompatibilityKey = @"UIDesignRequiresCompatibility";

static NSDictionary *YTKACEInfoDictionary(NSBundle *self, SEL _cmd) {
    NSDictionary *info = ((id (*)(id, SEL))YTKACEOrigInfoDictionary)(self, _cmd);
    if (self != NSBundle.mainBundle || info[YTKACEDesignCompatibilityKey] == nil) return info;
    NSMutableDictionary *copy = [info mutableCopy];
    [copy removeObjectForKey:YTKACEDesignCompatibilityKey];
    return copy;
}

static id YTKACEInfoObject(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:YTKACEDesignCompatibilityKey]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))YTKACEOrigInfoObject)(self, _cmd, key);
}

__attribute__((constructor)) static void YTKACEInstallLiquidGlassDesign(void) {
    BOOL config = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIos27EnableLiquidGlass", NO, "B16") &&
        YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIos27EnableLiquidGlass",
            (IMP)YTKACEYouTubeGlass, &YTKACEOrigYouTubeGlass);
    BOOL impl = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"ios27EnableLiquidGlass", NO, "B16") &&
        YTKACEInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"ios27EnableLiquidGlass",
            (IMP)YTKACEYouTubeGlassImpl, &YTKACEOrigYouTubeGlassImpl);
    BOOL available = YTKACEMethodTypesMatch(NSClassFromString(@"M3CLiquidGlass"),
        @"isLiquidGlassAvailable", YES, "B16") &&
        YTKACEInstallClassHook(@"M3CLiquidGlass", @"isLiquidGlassAvailable",
            (IMP)YTKACEGlassAvailable, &YTKACEOrigGlassAvailable);
    BOOL compute = YTKACEMethodTypesMatch(NSClassFromString(@"M3CLiquidGlass"),
        @"computeIsLiquidGlassAvailable", YES, "B16") &&
        YTKACEInstallClassHook(@"M3CLiquidGlass", @"computeIsLiquidGlassAvailable",
            (IMP)YTKACEGlassCompute, &YTKACEOrigGlassCompute);
    BOOL effect = YTKACEMethodTypesMatch(NSClassFromString(@"YTPivotBarView"), @"liquidGlassEffect", NO, "@16") &&
        YTKACEInstallInstanceHook(@"YTPivotBarView", @"liquidGlassEffect",
            (IMP)YTKACEPivotGlassEffect, &YTKACEOrigPivotGlassEffect);
    BOOL effectStyle = YTKACEMethodTypesMatch(NSClassFromString(@"YTPivotBarView"),
        @"liquidGlassEffectForPageStyle:", NO, "@24") &&
        YTKACEInstallInstanceHook(@"YTPivotBarView", @"liquidGlassEffectForPageStyle:",
            (IMP)YTKACEPivotGlassEffectStyle, &YTKACEOrigPivotGlassEffectStyle);
    BOOL floaty = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIosEnablePositionedFloatyBars", NO, "B16") &&
        YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnablePositionedFloatyBars",
            (IMP)YTKACEFloatyBars, &YTKACEOrigFloatyBars);
    BOOL floatyImpl = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"iosEnablePositionedFloatyBars", NO, "B16") &&
        YTKACEInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"iosEnablePositionedFloatyBars",
            (IMP)YTKACEFloatyBarsImpl, &YTKACEOrigFloatyBarsImpl);
    BOOL floatStyle = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIosFloatingBarStyle", NO, "q16") &&
        YTKACEInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosFloatingBarStyle",
            (IMP)YTKACEFloatingStyle, &YTKACEOrigFloatingStyle);
    BOOL floatStyleImpl = YTKACEMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"iosFloatingBarStyle", NO, "q16") &&
        YTKACEInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"iosFloatingBarStyle",
            (IMP)YTKACEFloatingStyleImpl, &YTKACEOrigFloatingStyleImpl);
    BOOL pivotStyle = YTKACEMethodTypesMatch(NSClassFromString(@"YTPivotBarView"), @"setFloatingBarStyle:", NO, "v24") &&
        YTKACEInstallInstanceHook(@"YTPivotBarView", @"setFloatingBarStyle:",
            (IMP)YTKACEPivotSetFloatingStyle, &YTKACEOrigPivotSetFloatingStyle);
    YTKACEDownloadLog(@"glass", @"youtube glass hooks config=%d impl=%d available=%d compute=%d effect=%d style=%d "
                      "floaty=%d/%d floatStyle=%d/%d pivotStyle=%d mode=%ld",
                      config, impl, available, compute, effect, effectStyle, floaty, floatyImpl, floatStyle,
                      floatStyleImpl, pivotStyle, (long)YTKACETabBarGlassMode());
    if (NSClassFromString(@"UIGlassEffect") == Nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL any = YTKACETabBarGlassMode() == 1 || YTKACETabBarGlassMode() == 2;
    for (NSString *key in @[@"YTKACE.Preference.Glass.TopBar",
                            @"YTKACE.Preference.Glass.Menus", @"YTKACE.Preference.Glass.Notices",
                            @"YTKACE.Preference.Glass.Player"]) {
        if ([defaults boolForKey:key]) any = YES;
    }
    if (!any) return;
    id info = (__bridge id)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    if ([info respondsToSelector:@selector(removeObjectForKey:)]) {
        @try {
            [info removeObjectForKey:YTKACEDesignCompatibilityKey];
        } @catch (__unused NSException *exception) {
        }
    }
    YTKACEInstallInstanceHook(@"NSBundle", @"infoDictionary",
        (IMP)YTKACEInfoDictionary, &YTKACEOrigInfoDictionary);
    YTKACEInstallInstanceHook(@"NSBundle", @"objectForInfoDictionaryKey:",
        (IMP)YTKACEInfoObject, &YTKACEOrigInfoObject);
}

static const void *YTKACEPivotBarSolidAssociation = &YTKACEPivotBarSolidAssociation;
static const void *YTKACEPivotBarGlassAssociation = &YTKACEPivotBarGlassAssociation;
static const void *YTKACEPivotBarPillAssociation = &YTKACEPivotBarPillAssociation;
static const void *YTKACEPivotBarLensAssociation = &YTKACEPivotBarLensAssociation;
static const void *YTKACEPivotBarMagnifyAssociation = &YTKACEPivotBarMagnifyAssociation;
static const void *YTKACEPivotBarHoleAssociation = &YTKACEPivotBarHoleAssociation;
static const void *YTKACEPivotBarPressTimeAssociation = &YTKACEPivotBarPressTimeAssociation;
static const void *YTKACEPivotBarFadedAssociation = &YTKACEPivotBarFadedAssociation;

static BOOL YTKACEViewContainsPivotItem(UIView *view) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) return YES;
    for (UIView *subview in view.subviews) {
        if (YTKACEViewContainsPivotItem(subview)) return YES;
    }
    return NO;
}

static void YTKACECollectPivotItems(UIView *view, NSMutableArray<UIView *> *items) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) {
        [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) YTKACECollectPivotItems(subview, items);
}

static NSHashTable<UIView *> *YTKACEPivotFadedViews(UIView *bar) {
    NSHashTable *faded = objc_getAssociatedObject(bar, YTKACEPivotBarFadedAssociation);
    if (faded == nil) {
        faded = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(bar, YTKACEPivotBarFadedAssociation, faded,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return faded;
}

static UIVisualEffect *YTKACEMakeGlassEffect(BOOL interactive) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, interactive ? 1 : 0)
        : [effectClass new];
    SEL interactiveSelector = NSSelectorFromString(@"setInteractive:");
    if (interactive && [effect respondsToSelector:interactiveSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, interactiveSelector, YES);
    }
    return effect;
}


static UIView *YTKACESelectedPivotItem(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTKACECollectPivotItems(bar, items);
    for (UIView *item in items) {
        if ([objc_getAssociatedObject(item, YTKACETabSelectedAssociation) boolValue]) return item;
    }
    return nil;
}

static NSArray<UIView *> *YTKACESortedPivotItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTKACECollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

static void YTKACETabGeometry(CGRect glass, NSUInteger count, CGFloat *start, CGFloat *step, CGFloat *overlap) {
    CGFloat spill = count <= 4 ? 8.0 : 16.0;
    CGFloat pitch = count == 0 ? 0.0 : (CGRectGetWidth(glass) - 8.0 - spill) / (CGFloat)count;
    if (start) *start = CGRectGetMinX(glass) + 4.0;
    if (step) *step = pitch;
    if (overlap) *overlap = spill;
}

static CGRect YTKACEPillFrameForItem(UIView *bar, UIVisualEffectView *glass, UIView *item) {
    NSArray<UIView *> *sorted = YTKACESortedPivotItems(bar);
    NSUInteger index = [sorted indexOfObject:item];
    CGRect itemFrame = [item convertRect:item.bounds toView:bar];
    CGFloat inset = 4.0;
    CGFloat left = CGRectGetMinX(itemFrame) + 2.0;
    CGFloat right = CGRectGetMaxX(itemFrame) - 2.0;
    if (index != NSNotFound) {
        CGFloat start = 0.0, step = 0.0, overlap = 0.0;
        YTKACETabGeometry(glass.frame, sorted.count, &start, &step, &overlap);
        left = start + step * (CGFloat)index;
        right = left + step + overlap;
    }
    left = MAX(left, CGRectGetMinX(glass.frame) + inset);
    right = MIN(right, CGRectGetMaxX(glass.frame) - inset);
    return CGRectMake(left, CGRectGetMinY(glass.frame) + inset,
                      MAX(right - left, 20.0), CGRectGetHeight(glass.frame) - inset * 2.0);
}

static void YTKACELayoutItemsInGlass(UIView *bar, CGRect glassFrame) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTKACECollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    if (visible.count == 0) return;
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    YTKACETabGeometry(glassFrame, visible.count, &start, &slot, &overlap);
    for (NSUInteger index = 0; index < visible.count; index++) {
        UIView *item = visible[index];
        if (item.superview == nil) continue;
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(start + overlap * 0.5 + slot * index,
                                   CGRectGetMidY(glassFrame) - CGRectGetHeight(current) * 0.5,
                                   slot, CGRectGetHeight(current));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) {
            item.frame = local;
        }
    }
}

// Icon-only tabs keep their renderer under iconOnlyItemRenderer.
static id YTKACEPivotItemAnyRenderer(UIView *item) {
    id renderer = nil;
    @try {
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    if (renderer != nil) return renderer;
    @try {
        renderer = [item valueForKey:@"iconOnlyItemRenderer"];
    } @catch (__unused NSException *exception) {
    }
    return renderer;
}

void YTKACESelectPivotItem(UIView *item) {
    id controller = nil;
    id renderer = nil;
    @try {
        controller = [item valueForKey:@"delegate"];
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    NSString *identifier = nil;
    @try {
        identifier = [YTKACEPivotItemAnyRenderer(item) valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (renderer != nil && [controller respondsToSelector:tap]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, renderer);
        return;
    }
    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0 &&
        [controller respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, select, identifier);
        return;
    }
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    UIControl *button = [item respondsToSelector:buttonSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector) : nil;
    if ([button isKindOfClass:UIControl.class]) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

static UIColor *YTKACEPillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.0 alpha:0.4]
            : [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

static UIView *YTKACEPivotItemsContainer(UIView *bar) {
    for (UIView *subview in bar.subviews) {
        if (YTKACEViewContainsPivotItem(subview)) return subview;
    }
    return nil;
}

static void YTKACELensSetObject(id lens, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(lens, selector, value);
    }
}

static void YTKACELensSetInteger(id lens, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(lens, selector, value);
    }
}

static void YTKACELensSetBool(id lens, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(lens, selector, value);
    }
}

static UIView *YTKACEMakeSystemLens(UIView *bar) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    SEL initSelector = NSSelectorFromString(@"initWithRestingBackground:");
    if (lensClass == Nil || ![lensClass instancesRespondToSelector:initSelector]) return nil;
    Class selectionClass = NSClassFromString(@"_UITabSelectionView");
    BOOL native = selectionClass != Nil && [selectionClass isSubclassOfClass:UIView.class];
    UIView *resting = native ? [selectionClass new] : [UIView new];
    if (!native) resting.backgroundColor = YTKACEPillColor();
    UIView *lens = ((id (*)(id, SEL, id))objc_msgSend)([lensClass alloc], initSelector, resting);
    if (![lens isKindOfClass:UIView.class]) return nil;
    YTKACELensSetObject(lens, @"setLiftedContainerView:", bar);
    YTKACELensSetInteger(lens, @"setLiftedContentMode:", 1);
    YTKACELensSetInteger(lens, @"setStyle:", 1);
    YTKACELensSetBool(lens, @"setWarpsContentBelow:", YES);
    if (!native) {
        @try {
            [lens setValue:YTKACEPillColor() forKey:@"restingBackgroundColor"];
        } @catch (__unused NSException *exception) {
        }
    }
    lens.userInteractionEnabled = YES;
    return lens;
}

static BOOL YTKACEIsSystemLens(UIView *view) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    return lensClass != Nil && [view isKindOfClass:lensClass];
}

static void YTKACETrackLens(UIView *lens, CFTimeInterval seconds);
static void YTKACELowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower);

static void YTKACELensSpring(NSTimeInterval response, CGFloat bounce, CGFloat velocity, dispatch_block_t animations) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, bounce, velocity, 0.0, options, animations, nil);
    } else {
        [UIView animateWithDuration:response delay:0.0 usingSpringWithDamping:1.0 - bounce
              initialSpringVelocity:velocity options:options animations:animations completion:nil];
    }
}

static const void *YTKACEPivotBarExpandedAssociation = &YTKACEPivotBarExpandedAssociation;

static const void *YTKACEPivotBarMinimizedAssociation = &YTKACEPivotBarMinimizedAssociation;
static const void *YTKACEPivotBarMiniAppliedAssociation = &YTKACEPivotBarMiniAppliedAssociation;
static const void *YTKACEPivotBarMiniMaskAssociation = &YTKACEPivotBarMiniMaskAssociation;
static NSString *const YTKACEMinimizeKey = @"YTKACE.Preference.Tabs.GlassMinimize";
static __weak UIView *YTKACEMinimizeBar;
static BOOL YTKACEMinimizeEnabled;
static CGFloat YTKACEMinimizeProgress;

static BOOL YTKACEBarMinimized(UIView *bar) {
    return bar != nil && [objc_getAssociatedObject(bar, YTKACEPivotBarMinimizedAssociation) boolValue];
}


static NSString *YTKACEPivotItemIdentifier(UIView *item);

static void YTKACEBarSpring(NSTimeInterval response, CGFloat damping, NSTimeInterval delay,
                            dispatch_block_t animations, void (^completion)(BOOL)) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, 1.0 - damping, 0.0, delay, options, animations, completion);
    } else {
        [UIView animateWithDuration:response * 1.5 delay:delay usingSpringWithDamping:damping
              initialSpringVelocity:0.0 options:options animations:animations completion:completion];
    }
}

static void YTKACESetBarScale(UIView *bar, CGFloat scale, NSTimeInterval response, CGFloat damping) {
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    CATransform3D transform = CATransform3DIdentity;
    if (glass != nil && fabs(scale - 1.0) > 0.0001) {
        CGFloat dx = CGRectGetMidX(glass.frame) - CGRectGetMidX(bar.bounds);
        CGFloat dy = CGRectGetMidY(glass.frame) - CGRectGetMidY(bar.bounds);
        transform = CATransform3DTranslate(transform, dx, dy, 0.0);
        transform = CATransform3DScale(transform, scale, scale, 1.0);
        transform = CATransform3DTranslate(transform, -dx, -dy, 0.0);
    }
    CALayer *layer = bar.layer;
    if (CATransform3DEqualToTransform(layer.sublayerTransform, transform)) return;
    CALayer *shown = layer.presentationLayer ?: layer;
    CATransform3D from = shown.sublayerTransform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = transform;
    [CATransaction commit];
    if (response <= 0.0) {
        [layer removeAnimationForKey:@"ytkace.scale"];
        return;
    }
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = [NSValue valueWithCATransform3D:from];
    animation.toValue = [NSValue valueWithCATransform3D:transform];
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:@"ytkace.scale"];
}

static const void *YTKACEPivotBarMiniIconAssociation = &YTKACEPivotBarMiniIconAssociation;
static const void *YTKACEPivotBarMiniIconRectAssociation = &YTKACEPivotBarMiniIconRectAssociation;
static NSTimeInterval YTKACEMiniMaskResponse;
static CGFloat YTKACEMiniMaskDamping;

static void YTKACESpringLayer(CALayer *layer, NSString *key, id from, id to, NSTimeInterval response, CGFloat damping) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:key];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:[@"ytkace." stringByAppendingString:key]];
}

static void YTKACEInstallMiniMask(UIView *bar) {
    UIView *container = YTKACEPivotItemsContainer(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    if (container == nil || glass == nil) return;
    CALayer *mask = objc_getAssociatedObject(bar, YTKACEPivotBarMiniMaskAssociation);
    if (mask == nil) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        mask.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, YTKACEPivotBarMiniMaskAssociation, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (container.layer.mask == mask) return;
    CGRect frame = [bar convertRect:glass.frame toView:container];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [mask removeAllAnimations];
    mask.bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    mask.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    mask.cornerRadius = CGRectGetHeight(frame) * 0.5;
    container.layer.mask = mask;
    [CATransaction commit];
}

static void YTKACEUpdateMiniMask(UIView *bar, CGRect glassFrame) {
    CALayer *mask = objc_getAssociatedObject(bar, YTKACEPivotBarMiniMaskAssociation);
    UIView *container = YTKACEPivotItemsContainer(bar);
    if (mask == nil || container == nil || container.layer.mask != mask) return;
    CGRect frame = [bar convertRect:glassFrame toView:container];
    CGRect bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    CGPoint position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGFloat radius = CGRectGetHeight(frame) * 0.5;
    if (CGRectEqualToRect(mask.bounds, bounds) && CGPointEqualToPoint(mask.position, position)) return;
    CALayer *shown = mask.presentationLayer ?: mask;
    CGRect fromBounds = shown.bounds;
    CGPoint fromPosition = shown.position;
    CGFloat fromRadius = shown.cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.bounds = bounds;
    mask.position = position;
    mask.cornerRadius = radius;
    [CATransaction commit];
    if (YTKACEMiniMaskResponse <= 0.0) return;
    YTKACESpringLayer(mask, @"bounds", [NSValue valueWithCGRect:fromBounds], [NSValue valueWithCGRect:bounds],
                      YTKACEMiniMaskResponse, YTKACEMiniMaskDamping);
    YTKACESpringLayer(mask, @"position", [NSValue valueWithCGPoint:fromPosition], [NSValue valueWithCGPoint:position],
                      YTKACEMiniMaskResponse, YTKACEMiniMaskDamping);
    YTKACESpringLayer(mask, @"cornerRadius", @(fromRadius), @(radius), YTKACEMiniMaskResponse, YTKACEMiniMaskDamping);
}

static void YTKACERemoveMiniMask(UIView *bar) {
    CALayer *mask = objc_getAssociatedObject(bar, YTKACEPivotBarMiniMaskAssociation);
    UIView *container = YTKACEPivotItemsContainer(bar);
    if (mask != nil && container.layer.mask == mask) container.layer.mask = nil;
}

static UIImage *YTKACERenderItemIcon(UIView *item, CGRect *iconRect) {
    CGSize size = item.bounds.size;
    CGFloat scale = item.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    YTKACECollectLabels(item, labels);
    NSMutableArray<NSNumber *> *opacity = [NSMutableArray array];
    for (UILabel *label in labels) {
        [opacity addObject:@(label.layer.opacity)];
        label.layer.opacity = 0.0;
    }
    CGFloat alpha = item.alpha;
    item.layer.opacity = 1.0;
    [item.layer renderInContext:context];
    item.layer.opacity = (float)alpha;
    for (NSUInteger index = 0; index < labels.count; index++) {
        labels[index].layer.opacity = opacity[index].floatValue;
    }
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    size_t minX = width, minY = height, maxX = 0, maxY = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (pixels[(y * width + x) * 4 + 3] < 24) continue;
            minX = MIN(minX, x); maxX = MAX(maxX, x);
            minY = MIN(minY, y); maxY = MAX(maxY, y);
        }
    }
    CGImageRef full = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (full == NULL || maxX < minX || maxY < minY) {
        if (full != NULL) CGImageRelease(full);
        return nil;
    }
    CGRect pixelsRect = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
    CGImageRef cropped = CGImageCreateWithImageInRect(full, pixelsRect);
    CGImageRelease(full);
    if (cropped == NULL) return nil;
    UIImage *image = [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    if (iconRect != NULL) {
        *iconRect = CGRectMake(pixelsRect.origin.x / scale, pixelsRect.origin.y / scale,
                               pixelsRect.size.width / scale, pixelsRect.size.height / scale);
    }
    return image;
}

static UIImageView *YTKACEMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, YTKACEPivotBarMiniIconAssociation);
    if (icon == nil) {
        icon = [UIImageView new];
        icon.userInteractionEnabled = NO;
        icon.hidden = YES;
        objc_setAssociatedObject(bar, YTKACEPivotBarMiniIconAssociation, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return icon;
}

static CGPoint YTKACEMiniIconHome(UIView *bar, UIView *glass, UIView *selected) {
    NSValue *stored = objc_getAssociatedObject(bar, YTKACEPivotBarMiniIconRectAssociation);
    CGRect rect = stored != nil ? stored.CGRectValue : selected.bounds;
    CGRect inBar = [selected convertRect:rect toView:bar];
    return CGPointMake(CGRectGetMidX(inBar) - CGRectGetMinX(glass.frame),
                       CGRectGetMidY(inBar) - CGRectGetMinY(glass.frame));
}

static void YTKACEApplyMiniAlpha(UIView *bar, BOOL minimized) {
    BOOL applied = [objc_getAssociatedObject(bar, YTKACEPivotBarMiniAppliedAssociation) boolValue];
    if (applied == minimized) return;
    objc_setAssociatedObject(bar, YTKACEPivotBarMiniAppliedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *selected = YTKACESelectedPivotItem(bar);
    UIView *pill = objc_getAssociatedObject(bar, YTKACEPivotBarPillAssociation);
    pill.alpha = minimized ? 0.0 : 1.0;
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        if (item != selected) item.alpha = minimized ? 0.0 : 1.0;
    }
}

static void YTKACERestoreMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, YTKACEPivotBarMiniIconAssociation);
    if (icon != nil) icon.hidden = YES;
    for (UIView *item in YTKACESortedPivotItems(bar)) item.alpha = 1.0;
}

static void YTKACESetBarMinimized(UIView *bar, BOOL minimized) {
    if (bar == nil || YTKACEBarMinimized(bar) == minimized) return;
    UIView *selected = YTKACESelectedPivotItem(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    if (minimized && (selected == nil || glass == nil ||
                      [YTKACEPivotItemIdentifier(selected) isEqualToString:@"FEshorts"])) return;
    if (minimized) {
        CGRect rect = CGRectZero;
        UIImage *image = YTKACERenderItemIcon(selected, &rect);
        if (image == nil) return;
        objc_setAssociatedObject(bar, YTKACEPivotBarMiniIconRectAssociation, [NSValue valueWithCGRect:rect],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImageView *icon = YTKACEMiniIcon(bar);
        UIView *host = ((UIVisualEffectView *)glass).contentView;
        if (icon.superview != host) [host addSubview:icon];
        [host bringSubviewToFront:icon];
        [UIView performWithoutAnimation:^{
            icon.image = image;
            icon.bounds = CGRectMake(0, 0, CGRectGetWidth(rect), CGRectGetHeight(rect));
            icon.center = YTKACEMiniIconHome(bar, glass, selected);
            icon.alpha = 1.0;
            icon.hidden = NO;
            selected.alpha = 0.0;
        }];
    }
    objc_setAssociatedObject(bar, YTKACEPivotBarMinimizedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEMinimizeProgress = minimized ? 1.0 : 0.0;
    YTKACESetBarScale(bar, 1.0, 0.3, 0.8);
    YTKACEInstallMiniMask(bar);
    __weak UIView *weakBar = bar;
    NSTimeInterval response = minimized ? 0.36 : 0.3;
    YTKACEMiniMaskResponse = response;
    YTKACEMiniMaskDamping = 0.72;
    YTKACEBarSpring(response, 0.72, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !YTKACEBarMinimized(strongBar)) YTKACERestoreMiniIcon(strongBar);
    });
    YTKACEMiniMaskResponse = 0.0;
    UIImageView *miniIcon = objc_getAssociatedObject(bar, YTKACEPivotBarMiniIconAssociation);
    YTKACEBarSpring(minimized ? 0.42 : 0.36, minimized ? 0.76 : 0.72, 0.05, ^{
        YTKACEApplyMiniAlpha(bar, minimized);
        if (!minimized) {
            selected.alpha = 1.0;
            miniIcon.alpha = 0.0;
        }
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !YTKACEBarMinimized(strongBar)) YTKACERemoveMiniMask(strongBar);
    });
}

static void YTKACESetBarExpanded(UIView *bar, BOOL expanded) {
    if (bar == nil || [objc_getAssociatedObject(bar, YTKACEPivotBarExpandedAssociation) boolValue] == expanded) return;
    objc_setAssociatedObject(bar, YTKACEPivotBarExpandedAssociation, expanded ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *lens = objc_getAssociatedObject(bar, YTKACEPivotBarPillAssociation);
    if (lens != nil) YTKACETrackLens(lens, 0.7);
    YTKACELensSpring(0.4, expanded ? 0.5 : 0.25, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    });
}

static void YTKACESetSystemLensLifted(UIView *lens, BOOL lifted, __unused NSString *tag,
                                      dispatch_block_t animations, dispatch_block_t done) {
    YTKACETrackLens(lens, 0.8);
    SEL selector = NSSelectorFromString(@"setLifted:animated:alongsideAnimations:completion:");
    if (![lens respondsToSelector:selector]) {
        [UIView animateWithDuration:0.3 animations:animations completion:^(__unused BOOL finished) {
            if (done != nil) done();
        }];
        return;
    }
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (done != nil) done();
    };
    ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(lens, selector, lifted, YES,
        animations, completion);
}

static void YTKACEUpdateGlassPill(UIView *bar, UIVisualEffectView *glass) {
    UIView *pill = objc_getAssociatedObject(bar, YTKACEPivotBarPillAssociation);
    if (pill == nil) {
        pill = YTKACEMakeSystemLens(bar);
        if (pill == nil) {
            pill = [UIView new];
            pill.userInteractionEnabled = NO;
            pill.layer.cornerCurve = kCACornerCurveContinuous;
            pill.backgroundColor = YTKACEPillColor();
        }
        objc_setAssociatedObject(bar, YTKACEPivotBarPillAssociation, pill,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL dragging = objc_getAssociatedObject(pill, YTKACEPivotBarFadedAssociation) != nil;
    if (dragging) return;
    if (YTKACEIsSystemLens(pill)) {
        UIView *host = glass.contentView;
        if (pill.superview != host) {
            [pill removeFromSuperview];
            host.clipsToBounds = NO;
            [host addSubview:pill];
            YTKACELensSetObject(pill, @"setLiftedContainerView:", host);
            for (UIView *subview in bar.subviews.copy) {
                if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
            }
        }
    } else if (pill.superview != bar) {
        [pill removeFromSuperview];
        [bar insertSubview:pill aboveSubview:glass];
    } else {
        [bar insertSubview:pill aboveSubview:glass];
    }
    UIView *selected = YTKACESelectedPivotItem(bar);
    if (selected == nil) {
        pill.hidden = YES;
        return;
    }
    CGRect target = YTKACEPillFrameForItem(bar, glass, selected);
    BOOL systemLens = YTKACEIsSystemLens(pill);
    if (systemLens) target = [bar convertRect:target toView:pill.superview];
    CGRect current = pill.frame;
    if (systemLens) {
        current = CGRectMake(pill.center.x - CGRectGetWidth(pill.bounds) * 0.5,
                             pill.center.y - CGRectGetHeight(pill.bounds) * 0.5,
                             CGRectGetWidth(pill.bounds), CGRectGetHeight(pill.bounds));
    }
    BOOL moved = fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) > 1.0 ||
        fabs(CGRectGetMidY(current) - CGRectGetMidY(target)) > 1.0 ||
        fabs(CGRectGetWidth(current) - CGRectGetWidth(target)) > 1.0 ||
        fabs(CGRectGetHeight(current) - CGRectGetHeight(target)) > 1.0;
    BOOL animate = !pill.hidden && !CGRectIsEmpty(current) && moved;
    pill.hidden = NO;
    if (!systemLens) pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    if (systemLens && !moved) return;
    if (systemLens && (!animate || fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) < 12.0)) {
        [UIView performWithoutAnimation:^{
            pill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
            pill.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        }];
    } else if (animate && systemLens) {
        id token = [NSObject new];
        objc_setAssociatedObject(pill, YTKACEPivotBarFadedAssociation, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGPoint center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        CGRect lifted = CGRectMake(0, 0, CGRectGetWidth(target) + 16.0, CGRectGetHeight(target) + 16.0);
        __weak UIView *weakPill = pill;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakPill;
            if (settled != nil && objc_getAssociatedObject(settled, YTKACEPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, YTKACEPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        CGPoint start = pill.center;
        YTKACESetSystemLensLifted(pill, YES, @"tap", ^{
            pill.bounds = lifted;
            pill.center = start;
        }, nil);
        YTKACELensSpring(0.4, 0.15, 0.0, ^{ pill.center = center; });
        YTKACELowerWhenArrived(pill, center, token, ^{
            UIView *strongPill = weakPill;
            if (strongPill == nil ||
                objc_getAssociatedObject(strongPill, YTKACEPivotBarFadedAssociation) != token) return;
            YTKACESetSystemLensLifted(strongPill, NO, @"tap", ^{
                strongPill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
                strongPill.center = center;
            }, ^{
                UIView *lens = weakPill;
                if (lens != nil && objc_getAssociatedObject(lens, YTKACEPivotBarFadedAssociation) == token) {
                    objc_setAssociatedObject(lens, YTKACEPivotBarFadedAssociation, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
        });
    } else if (animate) {
        [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ pill.frame = target; } completion:nil];
    } else {
        pill.frame = target;
    }
}

@interface YTKACEGlassSlideHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL lifted;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGFloat restingWidth;
@property (nonatomic, assign) CFTimeInterval pressStart;
@property (nonatomic, assign) CFTimeInterval lastMove;
@property (nonatomic, assign) CGFloat lastX;
@property (nonatomic, assign) CGFloat velocityX;
@property (nonatomic, assign) CGFloat anchorX;
@property (nonatomic, weak) UIView *touchedItem;
@property (nonatomic, weak) UIControl *heldButton;
@property (nonatomic, assign) NSUInteger pressID;
+ (instancetype)sharedHandler;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar;
@end

static NSString *YTKACEPivotItemIdentifier(UIView *item) {
    id renderer = YTKACEPivotItemAnyRenderer(item);
    id identifier = nil;
    @try {
        identifier = [renderer valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    return [identifier isKindOfClass:NSString.class] && [identifier length] != 0 ? identifier : nil;
}

static UIImageView *YTKACEFindPhotoView(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIImageView.class] && !subview.hidden) {
            UIImage *image = ((UIImageView *)subview).image;
            if (image != nil && image.renderingMode != UIImageRenderingModeAlwaysTemplate &&
                CGRectGetWidth(subview.bounds) >= 12.0) {
                return (UIImageView *)subview;
            }
        }
        UIImageView *found = YTKACEFindPhotoView(subview);
        if (found != nil) return found;
    }
    return nil;
}

static UIImageView *YTKACEAvatarView(UIView *bar) {
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        id renderer = nil;
        @try {
            renderer = [item valueForKey:@"renderer"];
        } @catch (__unused NSException *exception) {
        }
        id identifier = nil;
        @try {
            identifier = [renderer valueForKey:@"pivotIdentifier"];
        } @catch (__unused NSException *exception) {
        }
        if ([identifier isEqual:@"FElibrary"]) return YTKACEFindPhotoView(item);
    }
    return nil;
}

static const void *YTKACEStencilSlicesAssociation = &YTKACEStencilSlicesAssociation;

static UIView *YTKACEItemContaining(UIView *view, UIView *bar) {
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        if ([view isDescendantOfView:item]) return item;
    }
    return nil;
}

static void YTKACESyncStencilSlices(UIView *copy) {
    NSMapTable<UIView *, UIView *> *slices = objc_getAssociatedObject(copy, YTKACEStencilSlicesAssociation);
    if (slices.count == 0) return;
    [UIView performWithoutAnimation:^{
        for (UIView *item in slices) {
            UIView *slice = [slices objectForKey:item];
            if (item.superview == nil) continue;
            CALayer *shown = item.layer.presentationLayer ?: item.layer;
            CGRect frame = [item.superview convertRect:shown.frame toView:copy];
            slice.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        }
    }];
}

static void YTKACESyncLensMask(UIView *lens) {
    UIView *copy = objc_getAssociatedObject(lens, YTKACEPivotBarMagnifyAssociation);
    if (copy == nil || lens.superview == nil) return;
    YTKACESyncStencilSlices(copy);
    UIView *mask = copy.maskView;
    if (mask == nil) {
        mask = [UIView new];
        mask.backgroundColor = UIColor.blackColor;
        mask.layer.cornerCurve = kCACornerCurveContinuous;
        copy.maskView = mask;
    }
    CALayer *shown = lens.layer.presentationLayer ?: lens.layer;
    CGRect lensFrame = shown.frame;
    CGRect frame = [lens.superview convertRect:lensFrame toView:copy];
    mask.frame = frame;
    mask.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    UIView *items = objc_getAssociatedObject(lens, YTKACEPivotBarHoleAssociation);
    if (items == nil) return;
    CAShapeLayer *hole = [items.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)items.layer.mask : nil;
    if (hole == nil) {
        hole = [CAShapeLayer layer];
        hole.fillRule = kCAFillRuleEvenOdd;
        items.layer.mask = hole;
    }
    CGRect lensRect = CGRectInset([lens.superview convertRect:lensFrame toView:items], 4.0, 4.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(items.bounds, -200.0, -200.0)];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:lensRect cornerRadius:CGRectGetHeight(lensRect) * 0.5]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    hole.frame = items.bounds;
    hole.path = path.CGPath;
    [CATransaction commit];
}

@interface YTKACELensTracker : NSObject
@property(nonatomic, weak) UIView *lens;
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, assign) CFTimeInterval until;
@property(nonatomic, copy) dispatch_block_t pendingLower;
@property(nonatomic, assign) CGPoint lowerTarget;
@property(nonatomic, weak) id lowerToken;
@end

@implementation YTKACELensTracker

- (void)tick {
    UIView *lens = self.lens;
    if (lens == nil || CACurrentMediaTime() > self.until) {
        [self.link invalidate];
        self.link = nil;
        if (lens != nil) YTKACESyncLensMask(lens);
        return;
    }
    YTKACESyncLensMask(lens);
    [self checkArrival];
}

- (void)checkArrival {
    UIView *lens = self.lens;
    if (lens == nil || self.pendingLower == nil) return;
    CGPoint shown = (lens.layer.presentationLayer ?: lens.layer).position;
    if (fabs(shown.x - self.lowerTarget.x) >= 8.0) return;
    dispatch_block_t lower = self.pendingLower;
    self.pendingLower = nil;
    if (objc_getAssociatedObject(lens, YTKACEPivotBarFadedAssociation) == self.lowerToken) lower();
}

@end

static const void *YTKACELensTrackerAssociation = &YTKACELensTrackerAssociation;

static void YTKACETrackLens(UIView *lens, CFTimeInterval seconds) {
    if (lens == nil) return;
    YTKACELensTracker *tracker = objc_getAssociatedObject(lens, YTKACELensTrackerAssociation);
    if (tracker == nil) {
        tracker = [YTKACELensTracker new];
        tracker.lens = lens;
        objc_setAssociatedObject(lens, YTKACELensTrackerAssociation, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tracker.until = MAX(tracker.until, CACurrentMediaTime() + seconds);
    if (tracker.link == nil) {
        tracker.link = [CADisplayLink displayLinkWithTarget:tracker selector:@selector(tick)];
        [tracker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

static void YTKACELowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower) {
    if (lens == nil) return;
    YTKACETrackLens(lens, 1.0);
    YTKACELensTracker *tracker = objc_getAssociatedObject(lens, YTKACELensTrackerAssociation);
    tracker.pendingLower = lower;
    tracker.lowerTarget = target;
    tracker.lowerToken = token;
    __weak YTKACELensTracker *weakTracker = tracker;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTKACELensTracker *strongTracker = weakTracker;
        if (strongTracker.pendingLower == nil || strongTracker.pendingLower != lower) return;
        strongTracker.pendingLower = nil;
        UIView *strongLens = strongTracker.lens;
        if (strongLens != nil && objc_getAssociatedObject(strongLens, YTKACEPivotBarFadedAssociation) == token) lower();
    });
}

static void YTKACEClearLensHole(UIView *lens) {
    UIView *items = objc_getAssociatedObject(lens, YTKACEPivotBarHoleAssociation);
    items.layer.mask = nil;
    objc_setAssociatedObject(lens, YTKACEPivotBarHoleAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *YTKACEScrubTarget(UIView *bar, CGPoint point, UIEvent *event);
static UIView *YTKACEInlinePlayerBar(UIView *bar);

@implementation YTKACEGlassSlideHandler

+ (instancetype)sharedHandler {
    static YTKACEGlassSlideHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [YTKACEGlassSlideHandler new]; });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    if (glass == nil) return NO;
    if (YTKACEBarMinimized(bar)) {
        YTKACESetBarMinimized(bar, NO);
        return NO;
    }
    CGPoint point = [gesture locationInView:bar];
    if (!CGRectContainsPoint(glass.frame, point)) return NO;
    UIView *scrub = YTKACEScrubTarget(bar, point, nil);
    if (scrub != nil && scrub != YTKACEInlinePlayerBar(bar)) return NO;
    UIView *touched = [self pivotItemNearX:point.x inView:bar bar:bar];
    if (touched != nil && YTKACEPivotItemIdentifier(touched) == nil) return NO;
    gesture.cancelsTouchesInView = touched == nil || touched != YTKACESelectedPivotItem(bar);
    return YES;
}



- (UIVisualEffectView *)lensForBar:(UIView *)bar {
    UIVisualEffectView *lens = objc_getAssociatedObject(bar, YTKACEPivotBarLensAssociation);
    if (lens == nil) {
        lens = [[UIVisualEffectView alloc] initWithEffect:YTKACEMakeGlassEffect(YES)];
        lens.userInteractionEnabled = NO;
        lens.layer.cornerCurve = kCACornerCurveContinuous;
        lens.clipsToBounds = YES;
        objc_setAssociatedObject(bar, YTKACEPivotBarLensAssociation, lens,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (lens.superview != bar) [bar addSubview:lens];
    [bar bringSubviewToFront:lens];
    return lens;
}

- (UIView *)pivotItemNearX:(CGFloat)x inView:(UIView *)view bar:(UIView *)bar {
    NSArray<UIView *> *sorted = YTKACESortedPivotItems(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    if (sorted.count == 0 || glass == nil) return nil;
    CGFloat barX = [view convertPoint:CGPointMake(x, 0.0) toView:bar].x;
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    YTKACETabGeometry(glass.frame, sorted.count, &start, &slot, &overlap);
    NSInteger index = slot > 0.0 ? (NSInteger)floor((barX - start - overlap * 0.5) / slot) : 0;
    index = MAX(0, MIN((NSInteger)sorted.count - 1, index));
    return sorted[(NSUInteger)index];
}

- (UIControl *)buttonForItem:(UIView *)item {
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    if (![item respondsToSelector:buttonSelector]) return nil;
    UIControl *button = ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector);
    return [button isKindOfClass:UIControl.class] ? button : nil;
}

- (UIView *)stencilForItems:(UIView *)items {
    CGSize size = items.bounds.size;
    CGFloat scale = items.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UIView *> *flipped = [NSMutableArray array];
    SEL setSelected = NSSelectorFromString(@"setSelected:");
    YTKACEStencilRendering = YES;
    UIView *bar = items.superview;
    UIImageView *avatar = YTKACEAvatarView(bar);
    BOOL avatarHidden = avatar.hidden;
    avatar.hidden = YES;
    NSMutableArray<UIView *> *draggedOut = [NSMutableArray array];
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        if ([objc_getAssociatedObject(item, YTKACETabDragOutAssociation) boolValue]) {
            objc_setAssociatedObject(item, YTKACETabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [draggedOut addObject:item];
        }
    }
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        if (YTKACEPivotItemSelected(item) || ![item respondsToSelector:setSelected]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, YES);
        [item layoutIfNeeded];
        [flipped addObject:item];
    }
    CALayer *hole = items.layer.mask;
    items.layer.mask = nil;
    [items.layer renderInContext:context];
    items.layer.mask = hole;
    for (UIView *item in flipped) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, NO);
        [item layoutIfNeeded];
    }
    for (UIView *item in draggedOut) {
        objc_setAssociatedObject(item, YTKACETabDragOutAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    avatar.hidden = avatarHidden;
    YTKACEStencilRendering = NO;
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    double total = 0.0;
    double weight = 0.0;
    for (size_t index = 0; index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        if (pixel[3] < 128) continue;
        uint8_t peak = MAX(pixel[0], MAX(pixel[1], pixel[2]));
        total += (double)peak / (double)pixel[3];
        weight += 1.0;
    }
    BOOL brightIcons = weight == 0.0 || total / weight > 0.5;
    BOOL keepColor = YTKACETintMode != 0;
    for (size_t index = 0; !keepColor && index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        uint8_t alpha = pixel[3];
        uint8_t level = 0;
        if (alpha > 0) {
            CGFloat color = (CGFloat)MAX(pixel[0], MAX(pixel[1], pixel[2])) / (CGFloat)alpha;
            CGFloat contrast = brightIcons ? color : 1.0 - color;
            CGFloat ratio = MAX(0.0, MIN(1.0, (contrast - 0.5) / 0.35));
            level = (uint8_t)(ratio * (CGFloat)alpha);
        }
        pixel[0] = level;
        pixel[1] = level;
        pixel[2] = level;
        pixel[3] = level;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == NULL) return nil;
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, size.width, size.height)];
    UIColor *tint = brightIcons ? UIColor.whiteColor : UIColor.blackColor;
    NSMapTable<UIView *, UIView *> *slices = [NSMapTable weakToStrongObjectsMapTable];
    CGRect whole = CGRectMake(0.0, 0.0, size.width, size.height);
    for (UIView *item in YTKACESortedPivotItems(bar)) {
        CGRect frame = CGRectIntersection([item convertRect:item.bounds toView:items], whole);
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;
        CGRect pixels = CGRectMake(floor(frame.origin.x * scale), floor(frame.origin.y * scale),
                                   ceil(frame.size.width * scale), ceil(frame.size.height * scale));
        CGImageRef piece = CGImageCreateWithImageInRect(image, pixels);
        if (piece == NULL) continue;
        UIImageView *slice = [[UIImageView alloc] initWithImage:
            [[UIImage imageWithCGImage:piece scale:scale orientation:UIImageOrientationUp]
                imageWithRenderingMode:keepColor ? UIImageRenderingModeAlwaysOriginal
                                                 : UIImageRenderingModeAlwaysTemplate]];
        CGImageRelease(piece);
        slice.frame = CGRectMake(pixels.origin.x / scale, pixels.origin.y / scale,
                                 pixels.size.width / scale, pixels.size.height / scale);
        slice.tintColor = tint;
        [view addSubview:slice];
        [slices setObject:slice forKey:item];
    }
    CGImageRelease(image);
    if (avatar != nil && !avatarHidden && avatar.image != nil && avatar.window != nil) {
        CGRect face = [avatar convertRect:avatar.bounds toView:items];
        CGFloat radius = MIN(avatar.layer.cornerRadius, MIN(face.size.width, face.size.height) * 0.5);
        if (radius <= 0.0) radius = MIN(face.size.width, face.size.height) * 0.5;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = scale;
        UIImage *photo = [[[UIGraphicsImageRenderer alloc] initWithSize:face.size format:format]
            imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            CGRect bounds = CGRectMake(0.0, 0.0, face.size.width, face.size.height);
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius] addClip];
            CGSize source = avatar.image.size;
            CGFloat fill = source.width > 0.0 && source.height > 0.0
                ? MAX(bounds.size.width / source.width, bounds.size.height / source.height) : 1.0;
            CGSize drawn = CGSizeMake(source.width * fill, source.height * fill);
            [avatar.image drawInRect:CGRectMake((bounds.size.width - drawn.width) * 0.5,
                                                (bounds.size.height - drawn.height) * 0.5,
                                                drawn.width, drawn.height)];
        }];
        UIImageView *photoSlice = [[UIImageView alloc] initWithImage:photo];
        photoSlice.frame = face;
        [view addSubview:photoSlice];
        UIView *owner = YTKACEItemContaining(avatar, bar);
        if (owner != nil) {
            UIView *holder = [slices objectForKey:owner];
            if (holder != nil) {
                photoSlice.frame = [view convertRect:face toView:holder];
                [holder addSubview:photoSlice];
            }
        }
    }
    objc_setAssociatedObject(view, YTKACEStencilSlicesAssociation, slices, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar {
    UIView *old = objc_getAssociatedObject(lens, YTKACEPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = YTKACEPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy == nil || lens.superview == nil) return;
    copy.userInteractionEnabled = NO;
    copy.frame = [items convertRect:items.bounds toView:lens.superview];
    [lens.superview insertSubview:copy atIndex:0];
    YTKACELensSetObject(lens, @"setLiftedContentView:", copy);
    objc_setAssociatedObject(lens, YTKACEPivotBarMagnifyAssociation, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(lens, YTKACEPivotBarHoleAssociation, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACESyncLensMask(lens);
}

- (void)liftLens:(UIView *)lens bar:(UIView *)bar size:(CGSize)size center:(CGPoint)center {
    YTKACESetBarExpanded(bar, YES);
    NSUInteger pressID = self.pressID;
    __weak UIView *weakLens = lens;
    __weak UIView *weakBar = bar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongLens = weakLens;
        if (strongLens == nil || weakBar == nil || !self.lifted || self.pressID != pressID) return;
        [self attachMagnifierToLens:strongLens bar:weakBar];
    });
    UIView *old = objc_getAssociatedObject(lens, YTKACEPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = YTKACEPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy != nil && lens.superview != nil) {
        copy.userInteractionEnabled = NO;
        copy.frame = [items convertRect:items.bounds toView:lens.superview];
        [lens.superview insertSubview:copy atIndex:0];
        YTKACELensSetObject(lens, @"setLiftedContentView:", copy);
        objc_setAssociatedObject(lens, YTKACEPivotBarMagnifyAssociation, copy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(lens, YTKACEPivotBarHoleAssociation, items,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACESyncLensMask(lens);
    }
    self.lifted = YES;
    YTKACESetSystemLensLifted(lens, YES, @"press", ^{
        lens.bounds = CGRectMake(0, 0, size.width, size.height);
        YTKACESyncLensMask(lens);
    }, nil);
    YTKACELensSpring(0.4, 0.15, 0.0, ^{ lens.center = center; });
}

- (void)handleSystemLens:(UIView *)lens gesture:(UILongPressGestureRecognizer *)gesture
                     bar:(UIView *)bar glass:(UIView *)glass {
    UIView *host = lens.superview ?: bar;
    CGPoint point = [gesture locationInView:bar];
    UIView *selectedNow = YTKACESelectedPivotItem(bar);
    CGRect restingFrame = selectedNow != nil
        ? [bar convertRect:YTKACEPillFrameForItem(bar, (UIVisualEffectView *)glass, selectedNow) toView:host]
        : lens.frame;
    CGFloat lensWidth = self.lifted ? self.restingWidth : CGRectGetWidth(restingFrame);
    CGFloat width = lensWidth + 16.0;
    CGFloat height = CGRectGetHeight(restingFrame) + 16.0;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIView *grabbed = [self pivotItemNearX:point.x inView:bar bar:bar];
        CGRect slot = grabbed != nil ? YTKACEPillFrameForItem(bar, (UIVisualEffectView *)glass, grabbed) : CGRectNull;
        self.anchorX = CGRectIsNull(slot) || CGRectGetWidth(slot) <= 0.0
            ? 0.5 : MAX(0.0, MIN(1.0, (point.x - CGRectGetMinX(slot)) / CGRectGetWidth(slot)));
    }
    CGFloat anchor = self.anchorX;
    CGFloat clamped = MAX(CGRectGetMinX(glass.frame) + lensWidth * anchor,
                          MIN(point.x, CGRectGetMaxX(glass.frame) - lensWidth * (1.0 - anchor)));
    CGFloat centerX = clamped - lensWidth * anchor + lensWidth * 0.5;
    CGPoint center = [bar convertPoint:CGPointMake(centerX, CGRectGetMidY(glass.frame)) toView:host];
    CFTimeInterval now = CACurrentMediaTime();
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(lens, YTKACEPivotBarFadedAssociation, [NSObject new],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.pressStart = now;
        self.lastMove = now;
        self.lastX = point.x;
        self.velocityX = 0.0;
        self.startPoint = point;
        self.dragging = NO;
        self.lifted = NO;
        self.restingWidth = CGRectGetWidth(restingFrame);
        self.touchedItem = [self pivotItemNearX:point.x inView:bar bar:bar];
        self.heldButton = nil;
        self.pressID += 1;
        UIView *selected = YTKACESelectedPivotItem(bar);
        BOOL same = self.touchedItem == selected;
        for (UIView *subview in bar.subviews.copy) {
            if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
        }
        (void)same;
        if (self.touchedItem != nil) {
            [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CFTimeInterval step = now - self.lastMove;
        if (step > 0.001) {
            CGFloat instant = (point.x - self.lastX) / step;
            self.velocityX = instant * 0.6 + self.velocityX * 0.4;
            self.lastX = point.x;
            self.lastMove = now;
        }
        if (!self.dragging && fabs(point.x - self.startPoint.x) > 4.0) {
            self.dragging = YES;
            if (!gesture.cancelsTouchesInView) {
                self.heldButton = [self buttonForItem:self.touchedItem];
            }
            if (!self.lifted) {
                [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
                return;
            }
        }
        if (!self.lifted) return;
        YTKACELensSpring(0.2, 0.15, 0.0, ^{ lens.center = center; });
        YTKACETrackLens(lens, 0.4);
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    BOOL dragging = self.dragging;
    self.pressID += 1;
    YTKACESetBarExpanded(bar, NO);
    UIView *draggedFrom = self.touchedItem;
    if ([objc_getAssociatedObject(draggedFrom, YTKACETabDragOutAssociation) boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(draggedFrom, YTKACETabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTKACEApplyPivotItemPresentation(draggedFrom);
        });
    }
    UIControl *heldButton = self.heldButton;
    self.heldButton = nil;
    if (!self.lifted) {
        BOOL bump = !dragging && gesture.state == UIGestureRecognizerStateEnded &&
            self.touchedItem != nil && self.touchedItem == YTKACESelectedPivotItem(bar);
        if (!bump) {
            objc_setAssociatedObject(lens, YTKACEPivotBarFadedAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *tapped = self.touchedItem;
            if (gesture.state == UIGestureRecognizerStateEnded && tapped != nil &&
                YTKACEPivotItemIdentifier(tapped) != nil && tapped != YTKACESelectedPivotItem(bar)) {
                YTKACESelectPivotItem(tapped);
            }
            return;
        }
        id bumpToken = [NSObject new];
        objc_setAssociatedObject(lens, YTKACEPivotBarFadedAssociation, bumpToken,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGRect resting = restingFrame;
        CGPoint middle = CGPointMake(CGRectGetMidX(resting), CGRectGetMidY(resting));
        __weak UIView *weakBump = lens;
        YTKACESetSystemLensLifted(lens, YES, @"bump", ^{
            lens.bounds = CGRectMake(0, 0, CGRectGetWidth(resting) + 14.0, CGRectGetHeight(resting) + 10.0);
            lens.center = middle;
        }, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped == nil || objc_getAssociatedObject(bumped, YTKACEPivotBarFadedAssociation) != bumpToken) return;
            YTKACESetSystemLensLifted(bumped, NO, @"bump", ^{
                bumped.bounds = CGRectMake(0, 0, CGRectGetWidth(resting), CGRectGetHeight(resting));
                bumped.center = middle;
            }, nil);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped != nil && objc_getAssociatedObject(bumped, YTKACEPivotBarFadedAssociation) == bumpToken) {
                objc_setAssociatedObject(bumped, YTKACEPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        return;
    }
    self.lifted = NO;
    id token = [NSObject new];
    objc_setAssociatedObject(lens, YTKACEPivotBarFadedAssociation, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *nearest = dragging ? [self pivotItemNearX:point.x inView:bar bar:bar] : self.touchedItem;
    if (gesture.state == UIGestureRecognizerStateCancelled) nearest = YTKACESelectedPivotItem(bar);
    if (nearest != nil && YTKACEPivotItemIdentifier(nearest) == nil) nearest = YTKACESelectedPivotItem(bar);
    CGRect target = nearest != nil
        ? [bar convertRect:YTKACEPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) toView:host]
        : lens.frame;
    __weak UIView *weakLens = lens;
    CGPoint slide = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    YTKACELensSpring(0.4, 0.15, 0.0, ^{
        lens.center = slide;
        YTKACESyncLensMask(lens);
    });
    YTKACELowerWhenArrived(lens, slide, token, ^{
        UIView *lowering = weakLens;
        if (lowering == nil || objc_getAssociatedObject(lowering, YTKACEPivotBarFadedAssociation) != token) return;
        UIView *copy = objc_getAssociatedObject(lowering, YTKACEPivotBarMagnifyAssociation);
        copy.hidden = YES;
        YTKACEClearLensHole(lowering);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakLens;
            if (settled != nil && objc_getAssociatedObject(settled, YTKACEPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, YTKACEPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        YTKACESetSystemLensLifted(lowering, NO, @"up", ^{
            lowering.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
            lowering.center = slide;
            YTKACESyncLensMask(lowering);
        }, ^{
            UIView *strongLens = weakLens;
            if (strongLens != nil && objc_getAssociatedObject(strongLens, YTKACEPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(strongLens, YTKACEPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    });
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != YTKACESelectedPivotItem(bar)) {
        if (heldButton != nil) {
            __weak UIView *weakNearest = nearest;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *pick = weakNearest;
                if (pick != nil && pick != YTKACESelectedPivotItem(bar)) YTKACESelectPivotItem(pick);
            });
        } else {
            YTKACESelectPivotItem(nearest);
        }
    }
}

- (CGFloat)lensCenterForPoint:(CGPoint)point bar:(UIView *)bar glass:(UIView *)glass width:(CGFloat)width {
    return MAX(CGRectGetMinX(glass.frame) + width * 0.35,
               MIN(point.x, CGRectGetMaxX(glass.frame) - width * 0.35));
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    UIView *pill = objc_getAssociatedObject(bar, YTKACEPivotBarPillAssociation);
    if (glass == nil || pill == nil) return;
    if (YTKACEIsSystemLens(pill)) {
        [self handleSystemLens:pill gesture:gesture bar:bar glass:glass];
        return;
    }
    UIVisualEffectView *lens = [self lensForBar:bar];
    CGPoint point = [gesture locationInView:bar];
    CGFloat width = MAX(CGRectGetWidth(pill.frame), 80.0) + 26.0;
    CGFloat height = CGRectGetHeight(glass.frame) + 18.0;
    CGFloat centerX = [self lensCenterForPoint:point bar:bar glass:glass width:width];
    CGPoint center = CGPointMake(centerX, CGRectGetMidY(glass.frame));
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(pill, YTKACEPivotBarFadedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lens.bounds = pill.bounds.size.width > 0 ? pill.bounds : CGRectMake(0, 0, width, height);
        lens.center = pill.frame.size.width > 0
            ? CGPointMake(CGRectGetMidX(pill.frame), CGRectGetMidY(pill.frame)) : center;
        lens.layer.cornerRadius = CGRectGetHeight(lens.bounds) * 0.5;
        lens.alpha = 0.0;
        lens.hidden = NO;
        [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.7
              initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            lens.alpha = 1.0;
            lens.bounds = CGRectMake(0, 0, width, height);
            lens.layer.cornerRadius = height * 0.5;
            lens.center = center;
            pill.alpha = 0.0;
        } completion:nil];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        [UIView animateWithDuration:0.12 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ lens.center = center; } completion:nil];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    objc_setAssociatedObject(pill, YTKACEPivotBarFadedAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTKACECollectPivotItems(bar, items);
    UIView *nearest = nil;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *item in items) {
        if (item.hidden || CGRectGetWidth(item.bounds) <= 0.0) continue;
        CGFloat distance = fabs(CGRectGetMidX([item convertRect:item.bounds toView:bar]) - lens.center.x);
        if (distance < best) {
            best = distance;
            nearest = item;
        }
    }
    CGRect target = nearest != nil
        ? YTKACEPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) : pill.frame;
    pill.frame = target;
    pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    [UIView animateWithDuration:0.32 delay:0.0 usingSpringWithDamping:0.8
          initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        lens.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
        lens.layer.cornerRadius = target.size.height * 0.5;
        lens.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        lens.alpha = 0.0;
        pill.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (finished) lens.hidden = YES;
    }];
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != YTKACESelectedPivotItem(bar)) {
        YTKACESelectPivotItem(nearest);
    }
}

@end

static void YTKACEInstallGlassSlide(UIView *bar) {
    for (UIGestureRecognizer *recognizer in bar.gestureRecognizers) {
        if (recognizer.delegate == [YTKACEGlassSlideHandler sharedHandler]) return;
    }
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[YTKACEGlassSlideHandler sharedHandler] action:@selector(handlePress:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = [YTKACEGlassSlideHandler sharedHandler];
    [bar addGestureRecognizer:press];
}

BOOL YTKACELiquidGlassAvailable(void) {
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

static BOOL YTKACEViewLooksLikeScrubber(UIView *view, NSUInteger depth) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    for (NSString *word in @[@"scrub", @"progress", @"playerbar", @"slider", @"seek", @"timebar"]) {
        if ([name containsString:word]) return YES;
    }
    if (depth == 0) return NO;
    for (UIView *subview in view.subviews) {
        if (YTKACEViewLooksLikeScrubber(subview, depth - 1)) return YES;
    }
    return NO;
}

static UIView *YTKACEInlinePlayerBar(UIView *bar) {
    Class playerBarClass = NSClassFromString(@"YTInlinePlayerBarContainerView");
    if (playerBarClass == Nil || objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation) == nil) return nil;
    for (UIView *child in bar.subviews) {
        if ([child isKindOfClass:playerBarClass] && !child.hidden && child.alpha > 0.01 &&
            child.userInteractionEnabled && child.window != nil) {
            return child;
        }
    }
    return nil;
}

static UIView *YTKACEScrubTarget(UIView *bar, CGPoint point, UIEvent *event) {
    UIView *playerBar = YTKACEInlinePlayerBar(bar);
    if (playerBar == nil) return nil;
    CGPoint local = [bar convertPoint:point toView:playerBar];
    if (CGRectContainsPoint(playerBar.bounds, local)) return [playerBar hitTest:local withEvent:event];
    UIView *glass = objc_getAssociatedObject(bar, YTKACEPivotBarGlassAssociation);
    if (point.y >= CGRectGetMinY(glass.frame) + 12.0) return nil;
    Class gestureClass = NSClassFromString(@"YTInlineScrubGestureView");
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:playerBar];
    while (queue.count != 0) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (gestureClass != Nil && [node isKindOfClass:gestureClass] && !node.hidden && node.userInteractionEnabled) {
            CGPoint inside = [bar convertPoint:point toView:node];
            return CGRectContainsPoint(node.bounds, inside) ? node : nil;
        }
        [queue addObjectsFromArray:node.subviews];
    }
    return nil;
}

static IMP OriginalPivotBarPointInside;
static IMP OriginalPivotBarHitTest;

static BOOL YTKACEPivotBarPointInside(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    BOOL inside = OriginalPivotBarPointInside != NULL &&
        ((BOOL (*)(id, SEL, CGPoint, id))OriginalPivotBarPointInside)(receiver, selector, point, event);
    if (YTKACEBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, YTKACEPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point);
    }
    if (inside) return YES;
    UIView *playerBar = YTKACEInlinePlayerBar(receiver);
    return playerBar != nil && CGRectContainsPoint(playerBar.frame, point);
}

static UIView *YTKACEPivotBarHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    if (YTKACEBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, YTKACEPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point) ? receiver : nil;
    }
    UIView *scrub = YTKACEScrubTarget(receiver, point, event);
    if (scrub != nil && scrub != YTKACEInlinePlayerBar(receiver)) return scrub;
    if (!CGRectContainsPoint(receiver.bounds, point)) return nil;
    return OriginalPivotBarHitTest == NULL ? nil
        : ((id (*)(id, SEL, CGPoint, id))OriginalPivotBarHitTest)(receiver, selector, point, event);
}

static CGFloat const YTKACEMinimizeDistance = 64.0;
static BOOL YTKACEMinimizeActive;
static __weak UIScrollView *YTKACEMinimizeScroll;
static CGFloat YTKACEMinimizeLastOffset;
static const void *YTKACEMinimizePanAssociation = &YTKACEMinimizePanAssociation;

static BOOL YTKACEMinimizeEligible(UIScrollView *scrollView, UIView *bar) {
    UIWindow *window = bar.window;
    if (window == nil || scrollView.window != window || bar.hidden || bar.alpha < 0.01) return NO;
    if (CGRectGetHeight(scrollView.bounds) < CGRectGetHeight(window.bounds) * 0.4) return NO;
    CGFloat range = scrollView.contentSize.height + scrollView.adjustedContentInset.top +
        scrollView.adjustedContentInset.bottom - CGRectGetHeight(scrollView.bounds);
    if (range < YTKACEMinimizeDistance * 1.5) return NO;
    if (!CGRectIntersectsRect([bar convertRect:bar.bounds toView:window], window.bounds)) return NO;
    UIView *selected = YTKACESelectedPivotItem(bar);
    return selected != nil && ![YTKACEPivotItemIdentifier(selected) isEqualToString:@"FEshorts"];
}

static void YTKACEApplyMinimizeProgress(UIView *bar, CGFloat progress, BOOL tracking) {
    YTKACEMinimizeProgress = progress;
    CGFloat scale = (progress <= 0.0 || progress >= 1.0) ? 1.0 : 1.0 - progress * 0.05;
    if (tracking) YTKACESetBarScale(bar, scale, 0.1, 0.8);
    else YTKACESetBarScale(bar, scale, 0.3, 0.8);
}

@interface YTKACEMinimizePanTracker : NSObject
@end

@implementation YTKACEMinimizePanTracker

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *scrollView = (UIScrollView *)pan.view;
    UIView *bar = YTKACEMinimizeBar;
    if (!YTKACEMinimizeEnabled || bar == nil || ![scrollView isKindOfClass:UIScrollView.class]) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!YTKACEMinimizeEligible(scrollView, bar)) return;
        YTKACEMinimizeActive = YES;
        YTKACEMinimizeScroll = scrollView;
        YTKACEMinimizeLastOffset = scrollView.contentOffset.y;
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled &&
        pan.state != UIGestureRecognizerStateFailed) return;
    if (!YTKACEMinimizeActive || YTKACEMinimizeScroll != scrollView) return;
    YTKACEMinimizeActive = NO;
    BOOL minimized = YTKACEBarMinimized(bar);
    CGFloat progress = YTKACEMinimizeProgress;
    CGFloat velocity = -[pan velocityInView:scrollView].y;
    if (pan.state == UIGestureRecognizerStateEnded && fabs(velocity) > 50.0) {
        CGFloat rate = scrollView.decelerationRate;
        CGFloat travel = velocity / 1000.0 * rate / MAX(0.0001, 1.0 - rate);
        CGFloat minY = -scrollView.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom -
                                 CGRectGetHeight(scrollView.bounds));
        CGFloat target = MAX(minY, MIN(maxY, scrollView.contentOffset.y + travel));
        progress += (target - scrollView.contentOffset.y) / YTKACEMinimizeDistance;
        if (target <= minY + 0.5) progress = 0.0;
    }
    if (progress >= 1.0) {
        if (minimized) YTKACEApplyMinimizeProgress(bar, 1.0, NO);
        else YTKACESetBarMinimized(bar, YES);
    } else if (minimized) {
        YTKACESetBarMinimized(bar, NO);
    } else {
        YTKACEApplyMinimizeProgress(bar, 0.0, NO);
    }
}

@end

static IMP OriginalScrollSetContentOffset;

static NSUInteger YTKACEShortsClipGeneration;

static NSArray<UIView *> *YTKACEShortsClipViews(UIScrollView *pager) {
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:pager];
    for (UIView *view = pager.superview.superview.superview; view != nil && views.count < 3; view = view.superview) {
        if ([view isKindOfClass:NSClassFromString(@"YTAppView")]) break;
        if (view.clipsToBounds) [views addObject:view];
    }
    return views;
}

static const void *YTKACEShortsClipViewsAssociation = &YTKACEShortsClipViewsAssociation;
static const void *YTKACEShortsCoverAssociation = &YTKACEShortsCoverAssociation;

static UIView *YTKACEShortsCover(UIScrollView *pager, NSArray<UIView *> *views, BOOL create) {
    UIView *cover = objc_getAssociatedObject(pager, YTKACEShortsCoverAssociation);
    if (cover != nil || !create) return cover;
    UIView *outer = views.lastObject;
    if (outer == nil || outer.window == nil) return nil;
    CGRect frame = [outer convertRect:outer.bounds toView:nil];
    CGFloat below = CGRectGetHeight(outer.window.bounds) - CGRectGetMaxY(frame);
    if (below <= 0.5) return nil;
    cover = [[UIView alloc] initWithFrame:CGRectMake(0.0, CGRectGetHeight(outer.bounds), CGRectGetWidth(outer.bounds), below)];
    cover.backgroundColor = UIColor.blackColor;
    cover.userInteractionEnabled = NO;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [outer addSubview:cover];
    UIView *backing = [[UIView alloc] initWithFrame:[outer.superview convertRect:cover.frame fromView:outer]];
    backing.backgroundColor = UIColor.blackColor;
    backing.userInteractionEnabled = NO;
    backing.autoresizingMask = cover.autoresizingMask;
    [outer.superview insertSubview:backing belowSubview:outer];
    objc_setAssociatedObject(cover, YTKACEShortsCoverAssociation, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pager, YTKACEShortsCoverAssociation, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cover;
}

static void YTKACEFadeShortsCover(UIView *cover, CGFloat alpha, void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:0.2 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ cover.alpha = alpha; }
                     completion:completion];
}

static void YTKACESetShortsClipping(UIScrollView *pager, BOOL clips) {
    NSArray<UIView *> *views = objc_getAssociatedObject(pager, YTKACEShortsClipViewsAssociation);
    if (!clips) {
        if (views == nil) {
            views = YTKACEShortsClipViews(pager);
            objc_setAssociatedObject(pager, YTKACEShortsClipViewsAssociation, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *cover = YTKACEShortsCover(pager, views, YES);
        cover.alpha = 1.0;
        for (UIView *view in views) view.clipsToBounds = NO;
        if (cover != nil) YTKACEFadeShortsCover(cover, 0.0, nil);
        return;
    }
    UIView *cover = YTKACEShortsCover(pager, views, NO);
    void (^reclip)(void) = ^{
        for (UIView *view in views) view.clipsToBounds = YES;
        [(UIView *)objc_getAssociatedObject(cover, YTKACEShortsCoverAssociation) removeFromSuperview];
        [cover removeFromSuperview];
        objc_setAssociatedObject(pager, YTKACEShortsCoverAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pager, YTKACEShortsClipViewsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    if (cover == nil) {
        reclip();
        return;
    }
    NSUInteger generation = YTKACEShortsClipGeneration;
    __weak UIScrollView *weakPager = pager;
    YTKACEFadeShortsCover(cover, 1.0, ^(__unused BOOL finished) {
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != YTKACEShortsClipGeneration ||
            strongPager.isDragging || strongPager.isDecelerating) return;
        reclip();
    });
}

static void YTKACEScheduleShortsReclip(UIScrollView *pager, NSUInteger generation) {
    __weak UIScrollView *weakPager = pager;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != YTKACEShortsClipGeneration) return;
        if (strongPager.isDragging || strongPager.isDecelerating) {
            YTKACEScheduleShortsReclip(strongPager, generation);
            return;
        }
        YTKACESetShortsClipping(strongPager, YES);
    });
}

static void YTKACEShortsSeeThrough(UIScrollView *receiver) {
    static Class pagerClass;
    static Class rootClass;
    if (pagerClass == Nil) {
        pagerClass = NSClassFromString(@"YTAsyncCollectionView");
        rootClass = NSClassFromString(@"YTReelWatchRootView");
    }
    if (pagerClass == Nil || rootClass == Nil || [receiver class] != pagerClass) return;
    if (![receiver.superview.superview isKindOfClass:rootClass]) return;
    if (!receiver.isDragging && !receiver.isDecelerating) return;
    UIView *cover = objc_getAssociatedObject(receiver, YTKACEShortsCoverAssociation);
    if (cover != nil && cover.layer.presentationLayer.opacity > 0.01 && cover.alpha > 0.0) {
        YTKACEFadeShortsCover(cover, 0.0, nil);
    }
    if (objc_getAssociatedObject(receiver, YTKACEShortsClipViewsAssociation) == nil) {
        YTKACESetShortsClipping(receiver, NO);
        static BOOL logged;
        if (!logged) {
            logged = YES;
            NSMutableArray *names = [NSMutableArray array];
            for (UIView *view in objc_getAssociatedObject(receiver, YTKACEShortsClipViewsAssociation))
                [names addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(view.class),
                                  NSStringFromCGRect([view convertRect:view.bounds toView:nil])]];
            YTKACEDownloadLog(@"glass", @"shorts unclip %@", [names componentsJoinedByString:@" < "]);
        }
    }
    YTKACEScheduleShortsReclip(receiver, ++YTKACEShortsClipGeneration);
}

static void YTKACEScrollSetContentOffset(UIScrollView *receiver, SEL selector, CGPoint offset) {
    if (OriginalScrollSetContentOffset != NULL) {
        ((void (*)(id, SEL, CGPoint))OriginalScrollSetContentOffset)(receiver, selector, offset);
    }
    YTKACEShortsSeeThrough(receiver);
    if (!YTKACEMinimizeEnabled) return;
    UIView *bar = YTKACEMinimizeBar;
    if (bar == nil) return;
    if (objc_getAssociatedObject(receiver, YTKACEMinimizePanAssociation) == nil && receiver.isTracking) {
        static YTKACEMinimizePanTracker *tracker;
        if (tracker == nil) tracker = [YTKACEMinimizePanTracker new];
        objc_setAssociatedObject(receiver, YTKACEMinimizePanAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [receiver.panGestureRecognizer addTarget:tracker action:@selector(pan:)];
        if (YTKACEMinimizeEligible(receiver, bar)) {
            YTKACEMinimizeActive = YES;
            YTKACEMinimizeScroll = receiver;
            YTKACEMinimizeLastOffset = receiver.contentOffset.y;
        }
        return;
    }
    if (receiver != YTKACEMinimizeScroll) return;
    CGFloat y = receiver.contentOffset.y;
    BOOL minimized = YTKACEBarMinimized(bar);
    if (y <= -receiver.adjustedContentInset.top + 0.5) {
        YTKACEMinimizeLastOffset = y;
        if (minimized) YTKACESetBarMinimized(bar, NO);
        else if (YTKACEMinimizeProgress > 0.0) YTKACEApplyMinimizeProgress(bar, 0.0, receiver.isTracking);
        return;
    }
    if (!YTKACEMinimizeActive || !receiver.isTracking) return;
    CGFloat delta = y - YTKACEMinimizeLastOffset;
    YTKACEMinimizeLastOffset = y;
    if (fabs(delta) < 0.01) return;
    CGFloat progress = YTKACEMinimizeProgress + delta / YTKACEMinimizeDistance;
    progress = MAX(minimized ? 0.01 : 0.0, MIN(1.0, progress));
    if (!minimized && progress >= 1.0) {
        YTKACEMinimizeActive = NO;
        YTKACESetBarMinimized(bar, YES);
        return;
    }
    YTKACEApplyMinimizeProgress(bar, progress, YES);
}

static IMP OriginalHidePivotBarOnScroll;
static IMP OriginalUpdatePivotBarVisibility;

static BOOL YTKACEHidePivotBarOnScroll(id receiver, SEL selector) {
    if (YTKACEMinimizeEnabled) return NO;
    return OriginalHidePivotBarOnScroll != NULL &&
        ((BOOL (*)(id, SEL))OriginalHidePivotBarOnScroll)(receiver, selector);
}

static void YTKACEUpdatePivotBarVisibility(id receiver, SEL selector, UIScrollView *scrollView,
                                           CGFloat offsetY, BOOL atBottom) {
    if (YTKACEMinimizeEnabled) return;
    if (OriginalUpdatePivotBarVisibility != NULL) {
        ((void (*)(id, SEL, id, CGFloat, BOOL))OriginalUpdatePivotBarVisibility)(
            receiver, selector, scrollView, offsetY, atBottom);
    }
}

static const void *YTKACEShortsBackdropAssociation = &YTKACEShortsBackdropAssociation;

static void YTKACEApplyShortsBackdrop(UIView *bar, BOOL shorts) {
    UIView *host = bar.superview;
    if (host == nil) return;
    id saved = objc_getAssociatedObject(host, YTKACEShortsBackdropAssociation);
    if (shorts) {
        if (saved == nil) {
            objc_setAssociatedObject(host, YTKACEShortsBackdropAssociation, host.backgroundColor ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        host.backgroundColor = UIColor.blackColor;
    } else if (saved != nil) {
        host.backgroundColor = saved == NSNull.null ? nil : saved;
        objc_setAssociatedObject(host, YTKACEShortsBackdropAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTKACEApplyPivotBarGlass(UIView *receiver, UIView *blur) {
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, YTKACEPivotBarGlassAssociation);
    BOOL wanted = YTKACETabBarOwnGlass() &&
        YTKACELiquidGlassAvailable();
    if (!wanted) {
        if (glass != nil) {
            [glass removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, YTKACEPivotBarPillAssociation) removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, YTKACEPivotBarLensAssociation) removeFromSuperview];
            objc_setAssociatedObject(receiver, YTKACEPivotBarLensAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, YTKACEPivotBarPillAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, YTKACEPivotBarGlassAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            blur.hidden = NO;
            for (UIView *view in YTKACEPivotFadedViews(receiver).allObjects) view.alpha = 1.0;
            [YTKACEPivotFadedViews(receiver) removeAllObjects];
        }
        return NO;
    }
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTKACEMakeGlassEffect(NO)];
        glass.userInteractionEnabled = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = NO;
        objc_setAssociatedObject(receiver, YTKACEPivotBarGlassAssociation, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.hidden = YES;
    NSHashTable<UIView *> *faded = YTKACEPivotFadedViews(receiver);
    UIView *ownPill = objc_getAssociatedObject(receiver, YTKACEPivotBarPillAssociation);
    UIView *ownLens = objc_getAssociatedObject(receiver, YTKACEPivotBarLensAssociation);
    for (UIView *sibling in receiver.subviews) {
        if (sibling == glass || sibling == ownPill || sibling == ownLens) continue;
        if (YTKACEViewContainsPivotItem(sibling)) {
            sibling.opaque = NO;
            sibling.backgroundColor = UIColor.clearColor;
        } else if (sibling.alpha > 0.0 && !YTKACEViewLooksLikeScrubber(sibling, 3) &&
                   (CGRectGetHeight(sibling.frame) >= CGRectGetHeight(receiver.bounds) * 0.6 ||
                    CGRectGetHeight(sibling.frame) <= 1.5)) {
            sibling.alpha = 0.0;
            [faded addObject:sibling];
        }
    }
    receiver.backgroundColor = UIColor.clearColor;
    receiver.layer.backgroundColor = UIColor.clearColor.CGColor;
    receiver.opaque = NO;
    if (glass.superview != receiver) {
        [glass removeFromSuperview];
        [receiver insertSubview:glass atIndex:0];
    } else {
        [receiver sendSubviewToBack:glass];
    }
    CGFloat itemHeight = CGRectGetHeight(receiver.bounds) - receiver.safeAreaInsets.bottom;
    CGFloat extra = 7.0;
    CGFloat glassHeight = MAX(itemHeight, 44.0) + extra * 2.0;
    CGFloat glassTop = MIN(0.0, CGRectGetHeight(receiver.bounds) - glassHeight - 4.0);
    BOOL expanded = [objc_getAssociatedObject(receiver, YTKACEPivotBarExpandedAssociation) boolValue];
    NSUInteger tabs = 0;
    for (UIView *item in YTKACESortedPivotItems(receiver)) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) tabs += 1;
    }
    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    CGFloat margin = expanded ? 14.0 : 21.0;
    CGFloat glassWidth = barWidth - margin * 2.0;
    CGRect screen = (receiver.window.screen ?: UIScreen.mainScreen).bounds;
    CGFloat shortSide = MIN(CGRectGetWidth(screen), CGRectGetHeight(screen));
    if (shortSide > 0.0) glassWidth = MIN(glassWidth, shortSide - margin * 2.0);
    if (tabs > 0 && tabs <= 4) {
        // Grow by the same amount as a full-width bar when pressed.
        CGFloat grow = expanded ? (21.0 - 14.0) * 2.0 : 0.0;
        glassWidth = MIN(glassWidth, 86.0 * (CGFloat)tabs + 16.0 + grow);
    }
    CGRect frame = CGRectMake((barWidth - glassWidth) * 0.5, glassTop, glassWidth, glassHeight);
    UIView *current = YTKACESelectedPivotItem(receiver);
    BOOL darkBar = current != nil && [YTKACEPivotItemIdentifier(current) isEqualToString:@"FEshorts"];
    YTKACEMinimizeEnabled = YTKACEFeatureEnabled(YTKACEMinimizeKey);
    YTKACEMinimizeBar = receiver;
    BOOL minimized = YTKACEBarMinimized(receiver);
    if (minimized && (!YTKACEMinimizeEnabled || darkBar || current == nil)) {
        objc_setAssociatedObject(receiver, YTKACEPivotBarMinimizedAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        minimized = NO;
        YTKACEApplyMiniAlpha(receiver, NO);
        YTKACERestoreMiniIcon(receiver);
        YTKACERemoveMiniMask(receiver);
    }
    if (!YTKACEMinimizeEnabled || darkBar) {
        YTKACEMinimizeProgress = 0.0;
        YTKACESetBarScale(receiver, 1.0, 0.0, 1.0);
    }
    CGRect fullFrame = frame;
    CGFloat circle = MIN(48.0, glassHeight);
    if (minimized) {
        frame = CGRectMake(28.0, CGRectGetMidY(frame) - circle * 0.5, circle, circle);
    }
    receiver.clipsToBounds = NO;
    receiver.layer.masksToBounds = NO;
    glass.frame = frame;
    glass.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    YTKACEUpdateMiniMask(receiver, frame);
    YTKACEApplyShortsBackdrop(receiver, darkBar);
    UIUserInterfaceStyle style = darkBar ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        glass.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
    if (!YTKACEStencilRendering && current != nil && receiver.overrideUserInterfaceStyle != style) {
        receiver.overrideUserInterfaceStyle = style;
        for (UIView *item in YTKACESortedPivotItems(receiver)) YTKACEApplyPivotItemPresentation(item);
    }
    glass.alpha = 1.0;
    YTKACELayoutItemsInGlass(receiver, fullFrame);
    UIImageView *miniIcon = objc_getAssociatedObject(receiver, YTKACEPivotBarMiniIconAssociation);
    if (miniIcon != nil && !miniIcon.hidden && current != nil) {
        miniIcon.center = minimized ? CGPointMake(CGRectGetWidth(frame) * 0.5, CGRectGetHeight(frame) * 0.5)
                                    : YTKACEMiniIconHome(receiver, glass, current);
    }
    if (!minimized) YTKACEUpdateGlassPill(receiver, glass);
    YTKACEInstallGlassSlide(receiver);
    return YES;
}

static IMP OriginalSearchOptOutFrostedPivot;

static BOOL YTKACESearchOptOutFrostedPivot(__unused id receiver, __unused SEL selector) {
    return NO;
}

NSInteger YTKACEFrostedTabBarMode(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Tabs.Frosted"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    return YTKACEFeatureEnabled(@"YTKACE.Preference.Tabs.FrostedHidden") ? 2 : 0;
}

static IMP OriginalFrostedPermitted;

static BOOL YTKACEFrostedPermitted(id receiver, SEL selector) {
    NSInteger mode = YTKACEMasterEnabled() ? YTKACEFrostedTabBarMode() : 0;
    if (YTKACELiquidGlassAvailable() && YTKACETabBarOwnGlass()) return YES;
    if (mode == 1) return YES;
    if (mode == 2) return NO;
    return OriginalFrostedPermitted != NULL && ((BOOL (*)(id, SEL))OriginalFrostedPermitted)(receiver, selector);
}

static NSString *YTKACEColorText(UIColor *color) {
    if (color == nil) return @"nil";
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"?";
    return [NSString stringWithFormat:@"%.2f,%.2f,%.2f,%.2f", red, green, blue, alpha];
}

static NSString *YTKACEPivotItemColors(UIView *item) {
    if (item == nil) return @"-";
    UIImageView *icon = YTKACEFindImageView(item);
    UILabel *label = YTKACEFindNativeLabel(item);
    return [NSString stringWithFormat:@"%@ icon=%@ label=%@", YTKACEPivotItemIdentifier(item) ?: @"?",
            YTKACEColorText(icon.tintColor), YTKACEColorText(label.textColor)];
}

static void YTKACELogPivotState(UIView *receiver) {
    if (receiver.window == nil || !YTKACEDebugLogsEnabled()) return;
    UIView *selected = YTKACESelectedPivotItem(receiver);
    UIView *other = nil;
    for (UIView *item in YTKACESortedPivotItems(receiver)) {
        if (item != selected && !item.hidden) {
            other = item;
            break;
        }
    }
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, YTKACEPivotBarGlassAssociation);
    NSString *selectedID = YTKACEPivotItemIdentifier(selected);
    NSString *state = [NSString stringWithFormat:
        @"tab=%@ shorts=%d glass=%d glassFrame=%@ minimized=%d alpha=%.2f hidden=%d bg=%@ style=%ld trait=%ld "
        @"backdrop=%@ pill=%@ selected[%@] other[%@]",
        selectedID ?: @"none", [selectedID isEqualToString:@"FEshorts"], glass.superview == receiver,
        glass.superview == receiver ? NSStringFromCGRect(glass.frame) : @"-", YTKACEBarMinimized(receiver),
        receiver.alpha, receiver.hidden, YTKACEColorText(receiver.backgroundColor),
        (long)receiver.overrideUserInterfaceStyle, (long)receiver.traitCollection.userInterfaceStyle,
        YTKACEColorText(receiver.superview.backgroundColor), YTKACEColorText(YTKACEPillColor()),
        YTKACEPivotItemColors(selected), YTKACEPivotItemColors(other)];
    static NSString *lastState;
    if ([state isEqualToString:lastState]) return;
    lastState = state;
    YTKACEDebugLog(@"tabbar", @"%@", state);
}

static void YTKACEApplyPivotBarBackgroundInner(UIView *receiver);

static void YTKACEApplyPivotBarBackground(UIView *receiver) {
    YTKACEApplyPivotBarBackgroundInner(receiver);
    YTKACELogPivotState(receiver);
}

static void YTKACEApplyPivotBarBackgroundInner(UIView *receiver) {
    if (YTKACERefreshTabTint()) {
        for (UIView *item in YTKACESortedPivotItems(receiver)) {
            YTKACERestyleSelectedTab(item);
            YTKACEApplyPivotItemPresentation(item);
        }
    }
    SEL blurSelector = NSSelectorFromString(@"blurView");
    UIView *blur = [receiver respondsToSelector:blurSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, blurSelector)
        : nil;
    if (YTKACEApplyPivotBarGlass(receiver, blur)) return;
    BOOL applied = [objc_getAssociatedObject(
        receiver, YTKACEPivotBarSolidAssociation) boolValue];
    if (!YTKACEMasterEnabled() || YTKACEFrostedTabBarMode() != 2) {
        if (!applied) return;
        blur.hidden = NO;
        receiver.backgroundColor = UIColor.clearColor;
        receiver.opaque = NO;
        objc_setAssociatedObject(receiver, YTKACEPivotBarSolidAssociation,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = receiver.window.traitCollection.userInterfaceStyle;
    }
    UIColor *solid = style == UIUserInterfaceStyleDark
        ? UIColor.blackColor
        : UIColor.whiteColor;
    blur.hidden = YES;
    for (UIView *sibling in receiver.subviews) {
        if (sibling != blur && [sibling isKindOfClass:UIVisualEffectView.class]) {
            sibling.hidden = YES;
        }
    }
    receiver.backgroundColor = solid;
    receiver.opaque = YES;
    objc_setAssociatedObject(receiver, YTKACEPivotBarSolidAssociation,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTKACERefreshPivotBarsInView(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTPivotBarView"]) {
        YTKACEApplyPivotBarBackground(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        YTKACERefreshPivotBarsInView(subview);
    }
}

void YTKACERefreshPivotBarBackground(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) YTKACERefreshPivotBarsInView(window);
        }
    }
}

static void YTKACEPivotBarStyleColors(UIView *receiver, SEL selector) {
    if (OriginalPivotBarStyleColors != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarStyleColors)(receiver, selector);
    }
    YTKACEApplyPivotBarBackground(receiver);
}

static void YTKACEPivotBarSetBackgroundStyle(UIView *receiver, SEL selector,
                                             int style) {
    if (OriginalPivotBarSetBackgroundStyle != NULL) {
        ((void (*)(id, SEL, int))OriginalPivotBarSetBackgroundStyle)(
            receiver, selector, style);
    }
    YTKACEApplyPivotBarBackground(receiver);
}

static NSString *YTKACEStartupTabToken(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:@"YTKACE.Preference.Tabs.Startup"];
    if ([stored isKindOfClass:NSString.class]) return stored;
    NSArray<NSString *> *legacy = @[@"", @"explore", @"subscriptions",
                                    @"shorts", @"library"];
    NSInteger index = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    NSString *token = (index > 0 && index < (NSInteger)legacy.count)
        ? legacy[(NSUInteger)index] : @"";
    [defaults setObject:token forKey:@"YTKACE.Preference.Tabs.Startup"];
    return token;
}

static NSString *YTKACEStartupPivotIdentifier(NSString *token) {
    if (token.length == 0) return nil;
    NSDictionary<NSString *, NSString *> *known = @{
        @"home": @"FEwhat_to_watch",
        @"explore": @"FEexplore",
        @"subscriptions": @"FEsubscriptions",
        @"shorts": @"FEshorts",
        @"library": @"FElibrary",
        @"you": @"FElibrary"
    };
    NSString *identifier = known[token];
    if (identifier.length != 0) return identifier;
    return YTKACEStartupIdentifiers[token];
}

static NSString *YTKACEWantedStartupPivot(void) {
    NSString *identifier = YTKACEStartupPivotIdentifier(YTKACEStartupTabToken());
    if (identifier.length != 0) return identifier;
    if (YTKACEMasterEnabled() &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Home"] &&
        YTKACEFirstVisiblePivot.length != 0 && ![YTKACEFirstVisiblePivot isEqualToString:@"FEwhat_to_watch"]) {
        return YTKACEFirstVisiblePivot;
    }
    return nil;
}

static __weak id YTKACEPivotBarControllerRef;

static id YTKACEPivotControllerForView(UIView *view) {
    if (YTKACEPivotBarControllerRef != nil) return YTKACEPivotBarControllerRef;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder respondsToSelector:lookup]) {
            YTKACEPivotBarControllerRef = responder;
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL YTKACENavigateToPivot(id controller, NSString *identifier) {
    if (controller == nil || identifier.length == 0) return NO;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (![controller respondsToSelector:lookup] ||
        ![controller respondsToSelector:tap]) {
        return NO;
    }
    id item = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, identifier);
    if (item == nil) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, item);
    return YES;
}

static BOOL YTKACEStartupNavigated;

static void YTKACEApplyStartupTab(UIView *receiver) {
    if (YTKACEStartupApplied) return;
    NSString *identifier = YTKACEWantedStartupPivot();
    if (identifier.length == 0) {
        if (YTKACEFirstVisiblePivot.length != 0) YTKACEStartupApplied = YES;
        return;
    }
    static NSTimeInterval firstSeen = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (firstSeen == 0.0) firstSeen = now;
    if (now - firstSeen > 8.0) {
        YTKACEStartupApplied = YES;
        return;
    }

    id controller = YTKACEPivotControllerForView(receiver);

    id target = controller ?: receiver;
    SEL current = NSSelectorFromString(@"selectedPivotIdentifier");
    if ([target respondsToSelector:current]) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(target, current);
        // Already switched to it by tapping it below: done. Running the Home
        // workaround after a real switch breaks tab switching for good.
        if (YTKACEStartupNavigated && [selected isKindOfClass:NSString.class] &&
            [selected caseInsensitiveCompare:identifier] == NSOrderedSame) {
            YTKACEStartupApplied = YES;
            return;
        }
        // Home hidden: YouTube files its launch Home page under whichever tab
        // it starts on. Point it at Home first, then switch, so that tab gets
        // its own page. Only before our first switch.
        if ([selected isKindOfClass:NSString.class] && !YTKACEStartupNavigated &&
            [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Home"]) {
            SEL selectItem = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
            SEL setSelected = NSSelectorFromString(@"setSelectedPivotIdentifier:");
            if ([controller respondsToSelector:selectItem])
                ((void (*)(id, SEL, id))objc_msgSend)(controller, selectItem, @"FEwhat_to_watch");
            if ([controller respondsToSelector:setSelected])
                ((void (*)(id, SEL, id))objc_msgSend)(controller, setSelected, @"FEwhat_to_watch");
            @try {
                [controller setValue:@"FEwhat_to_watch" forKey:@"_pivotIdentifier"];
            } @catch (__unused NSException *exception) {
            }
            YTKACEStartupNavigated = YTKACENavigateToPivot(controller, identifier);
            if ([selected caseInsensitiveCompare:identifier] == NSOrderedSame || !YTKACEStartupNavigated) {
                YTKACEStartupApplied = YES;
            }
            return;
        }
        if ([selected isKindOfClass:NSString.class] &&
            [selected caseInsensitiveCompare:identifier] == NSOrderedSame) {
            YTKACEStartupApplied = YES;
            return;
        }
    }

    if (YTKACENavigateToPivot(controller, identifier)) {
        YTKACEStartupNavigated = YES;
        return;
    }

    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([target respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, select, identifier);
    }
}

static void YTKACESetDefaultSelectedPivot(id receiver, SEL selector, id identifier) {
    NSString *wanted = YTKACEStartupPivotIdentifier(YTKACEStartupTabToken());
    if (wanted.length != 0 && !YTKACEStartupApplied) {
        YTKACEStartupNative = YES;
        identifier = wanted;
    }
    if (OriginalSetDefaultSelectedPivot != NULL) {
        ((void (*)(id, SEL, id))OriginalSetDefaultSelectedPivot)(receiver, selector,
                                                                identifier);
    }
}

static void YTKACEScheduleStartupTab(id controller) {
    if (YTKACEStartupApplied) return;
    if (YTKACEWantedStartupPivot().length == 0 && YTKACEFirstVisiblePivot.length != 0) {
        YTKACEStartupApplied = YES;
        return;
    }
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    const double delay = YTKACEStartupNative ? 0.0 : 0.35;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        scheduled = NO;
        SEL pivotView = NSSelectorFromString(@"pivotBarView");
        UIView *view = [controller respondsToSelector:pivotView]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, pivotView)
            : nil;
        YTKACEApplyStartupTab(view);
        if (!YTKACEStartupApplied) YTKACEScheduleStartupTab(controller);
    });
}

static void YTKACEPivotControllerAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalPivotControllerAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotControllerAppear)(receiver, selector,
                                                                animated);
    }
    YTKACEPivotBarControllerRef = receiver;
    YTKACEScheduleStartupTab(receiver);
}

static void YTKACEPivotBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarLayout)(receiver, selector);
    }
    YTKACEHideCreateViews(receiver);
    YTKACEApplyPivotBarBackground(receiver);
}

static void YTKACEPivotItemLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotItemLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotItemLayout)(receiver, selector);
    }
    YTKACEApplyPivotItemPresentation(receiver);
}

void YTKACEDuoTabsSelectionChanged(UIView *item);

static void YTKACEPivotItemSetSelected(UIView *receiver,
                                       SEL selector,
                                       BOOL selected) {
    BOOL wasSelected = [objc_getAssociatedObject(receiver, YTKACETabSelectedAssociation) boolValue];
    if (OriginalPivotItemSetSelected != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotItemSetSelected)(
            receiver, selector, selected
        );
    }
    objc_setAssociatedObject(receiver,
                             YTKACETabSelectedAssociation,
                             @(selected),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEApplyPivotItemPresentation(receiver);
    YTKACEDuoTabsSelectionChanged(receiver);
    if (YTKACEStencilRendering) return;
    if (selected) {
        UIView *bar = receiver.superview;
        while (bar != nil && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) {
            bar = bar.superview;
        }
        if (!wasSelected) YTKACESetBarMinimized(bar, NO);
        [bar setNeedsLayout];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEApplyPivotItemPresentation(receiver);
    });
}

static void YTKACEPivotItemTraitChanged(UIView *receiver,
                                        SEL selector,
                                        UITraitCollection *previous) {
    if (OriginalPivotItemTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotItemTraitChanged)(
            receiver, selector, previous
        );
    }
    YTKACEApplyPivotItemPresentation(receiver);
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEApplyPivotItemPresentation(receiver);
    });
    if (YTKACEFeatureEnabled(YTKACEOLEDKey) &&
        !YTKACENavigationRefreshScheduled) {
        YTKACENavigationRefreshScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACENavigationRefreshScheduled = NO;
            YTKACERefreshNavigationAppearance();
        });
    }
}

void YTKACEInstallTabBarHooks(void) {
    YTKACERefreshTabTint();
    YTKACEInstallClassHook(@"YTFloatingBarExperiment",
                           @"isIconsOnly",
                           (IMP)YTKACEIsIconsOnly,
                           &OriginalIsIconsOnly);
    YTKACEInstallInstanceHook(@"YTPivotBarItemView",
                              @"iconTintColorSelected",
                              (IMP)YTKACEIconTintSelected,
                              &OriginalIconTintSelected);
    YTKACEInstallInstanceHook(@"UILabel",
                              @"setTextColor:",
                              (IMP)YTKACEPivotLabelSetTextColor,
                              &OriginalPivotLabelSetTextColor);
    YTKACEInstallInstanceHook(@"UILabel",
                              @"setHidden:",
                              (IMP)YTKACEPivotLabelSetHidden,
                              &OriginalPivotLabelSetHidden);
    YTKACEInstallInstanceHook(@"UILabel",
                              @"setAlpha:",
                              (IMP)YTKACEPivotLabelSetAlpha,
                              &OriginalPivotLabelSetAlpha);
    YTKACEInstallInstanceHook(@"YTQTMButton",
                              @"layoutSubviews",
                              (IMP)YTKACEPivotButtonLayout,
                              &OriginalPivotButtonLayout);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"setRenderer:",
                              (IMP)YTKACESetPivotRenderer,
                              &OriginalSetPivotRenderer);
    Method floatingSetter = class_getInstanceMethod(NSClassFromString(@"YTFloatingPivotBarView"),
                                                    @selector(setRenderer:));
    const char *floatingTypes = floatingSetter != NULL ? method_getTypeEncoding(floatingSetter) : NULL;
    BOOL floatingHooked = floatingTypes != NULL && strncmp(floatingTypes, "v24@0:8@16", 10) == 0 &&
        YTKACEInstallInstanceHook(@"YTFloatingPivotBarView", @"setRenderer:",
                                  (IMP)YTKACESetPivotRenderer, &OriginalSetFloatingPivotRenderer);
    YTKACEDownloadLog(@"tabbar", @"floating bar hook=%d types=%s", floatingHooked, floatingTypes ?: "-");
    YTKACEInstallInstanceHook(@"YTPivotBarItemView",
                              @"layoutSubviews",
                              (IMP)YTKACEPivotItemLayout,
                              &OriginalPivotItemLayout);
    YTKACEInstallInstanceHook(@"YTPivotBarItemView",
                              @"setSelected:",
                              (IMP)YTKACEPivotItemSetSelected,
                              &OriginalPivotItemSetSelected);
    YTKACEInstallInstanceHook(@"YTPivotBarItemView",
                              @"traitCollectionDidChange:",
                              (IMP)YTKACEPivotItemTraitChanged,
                              &OriginalPivotItemTraitChanged);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"layoutSubviews",
                              (IMP)YTKACEPivotBarLayout,
                              &OriginalPivotBarLayout);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"pointInside:withEvent:",
                              (IMP)YTKACEPivotBarPointInside,
                              &OriginalPivotBarPointInside);
    if (YTKACETabBarOwnGlass() && YTKACELiquidGlassAvailable()) {
        YTKACEInstallInstanceHook(@"UIScrollView",
                                  @"setContentOffset:",
                                  (IMP)YTKACEScrollSetContentOffset,
                                  &OriginalScrollSetContentOffset);
        YTKACEInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"hidePivotBarOnScroll",
                                  (IMP)YTKACEHidePivotBarOnScroll,
                                  &OriginalHidePivotBarOnScroll);
        YTKACEInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"updatePivotBarVisibilityForScrollView:contentOffsetY:isAtBottom:",
                                  (IMP)YTKACEUpdatePivotBarVisibility,
                                  &OriginalUpdatePivotBarVisibility);
        YTKACEInstallInstanceHook(@"YTSearchResultsViewController",
                                  @"optOutOfFrostedPivotBar",
                                  (IMP)YTKACESearchOptOutFrostedPivot,
                                  &OriginalSearchOptOutFrostedPivot);
    }
    YTKACEInstallInstanceHook(@"YTPivotBarViewController",
                              @"isFrostedPivotBarPermitted",
                              (IMP)YTKACEFrostedPermitted,
                              &OriginalFrostedPermitted);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"hitTest:withEvent:",
                              (IMP)YTKACEPivotBarHitTest,
                              &OriginalPivotBarHitTest);
    YTKACEInstallInstanceHook(@"YTPivotBarViewController",
                              @"viewDidAppear:",
                              (IMP)YTKACEPivotControllerAppear,
                              &OriginalPivotControllerAppear);
    YTKACEInstallInstanceHook(@"YTAppPivotBarController",
                              @"setDefaultSelectedPivotIdentifier:",
                              (IMP)YTKACESetDefaultSelectedPivot,
                              &OriginalSetDefaultSelectedPivot);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"styleBackgroundColors",
                              (IMP)YTKACEPivotBarStyleColors,
                              &OriginalPivotBarStyleColors);
    YTKACEInstallInstanceHook(@"YTPivotBarView",
                              @"setBackgroundStyle:",
                              (IMP)YTKACEPivotBarSetBackgroundStyle,
                              &OriginalPivotBarSetBackgroundStyle);
    YTKACEInstallInstanceHook(@"YTAppViewController",
                              @"viewDidLoad",
                              (IMP)YTKACEAppViewDidLoad,
                              &OriginalAppViewDidLoad);
    YTKACEInstallInstanceHook(@"YTBrowseViewController",
                              @"viewDidLoad",
                              (IMP)YTKACEBrowseViewDidLoad,
                              &OriginalBrowseViewDidLoad);
    YTKACEInstallInstanceHook(@"YTBrowseResponseViewController",
                              @"viewDidLoad",
                              (IMP)YTKACEBrowseResponseViewDidLoad,
                              &OriginalBrowseResponseViewDidLoad);
    YTKACEInstallInstanceHook(@"YTWrapperFlatViewController",
                              @"viewDidLoad",
                              (IMP)YTKACEWrapperViewDidLoad,
                              &OriginalWrapperViewDidLoad);
}
