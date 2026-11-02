#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTKACECleanLinksKey = @"YTKACE.Preference.Sharing.CleanLinks";
static NSString * const YTKACEDirectLinksKey = @"YTKACE.Preference.Sharing.DirectLinks";
static const NSUInteger YTKACECopyTextField = 90198251;

static IMP OriginalCopyShareObject;
static IMP OriginalCopyShare;
static IMP OriginalTextShareObject;
static IMP OriginalMailShareObject;
static IMP OriginalSystemShareObject;
static IMP OriginalSystemShareText;
static IMP OriginalSystemItem;
static IMP OriginalSystemPlaceholder;
static IMP OriginalMessageSetBody;
static IMP OriginalMailSetBody;
static IMP OriginalOpenURL;

static BOOL YTKACECleanLinksEnabled(void) {
    return YTKACEFeatureEnabled(YTKACECleanLinksKey);
}

static BOOL YTKACEIsYouTubeHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"youtu.be"] || [host isEqualToString:@"youtube.com"] ||
        [host hasSuffix:@".youtube.com"];
}

static BOOL YTKACEIsTrackingParameter(NSString *name) {
    NSString *lower = name.lowercaseString;
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"si", @"is", @"pp", @"feature", @"gclid", @"kw", @"ab_channel"]];
    });
    return [names containsObject:lower] || [lower hasPrefix:@"utm_"];
}

NSString *YTKACECleanYouTubeLink(NSString *link) {
    if (![link isKindOfClass:NSString.class] || link.length == 0 || link.length > 8192) return link;
    NSURLComponents *components = [NSURLComponents componentsWithString:link];
    if (components == nil || !YTKACEIsYouTubeHost(components.host)) return link;
    NSArray<NSURLQueryItem *> *items = components.queryItems;
    if (items.count == 0) return link;
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in items) {
        if (!YTKACEIsTrackingParameter(item.name)) [kept addObject:item];
    }
    if (kept.count == items.count) return link;
    components.queryItems = kept.count != 0 ? kept : nil;
    return components.string ?: link;
}

static BOOL YTKACEIsWebScheme(NSString *scheme) {
    scheme = scheme.lowercaseString;
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

static NSURL *YTKACEDirectLinkURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !YTKACEIsWebScheme(URL.scheme)) return URL;
    NSString *host = URL.host.lowercaseString;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (!([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"]) ||
        ![components.path isEqualToString:@"/redirect"]) {
        return URL;
    }
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"q"]) continue;
        NSURL *target = item.value.length != 0 ? [NSURL URLWithString:item.value] : nil;
        return target.host.length != 0 && YTKACEIsWebScheme(target.scheme) ? target : URL;
    }
    return URL;
}

static NSString *YTKACECleanLinksInText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || [text rangeOfString:@"http"].location == NSNotFound) {
        return text;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>]+" options:0 error:NULL];
    });
    NSMutableString *result = [text mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:text options:0
                                                                     range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *link = [text substringWithRange:match.range];
        NSString *cleaned = YTKACECleanYouTubeLink(link);
        if (![cleaned isEqualToString:link]) [result replaceCharactersInRange:match.range withString:cleaned];
    }
    return result;
}

static id YTKACECleanLinkObject(id value) {
    if (!YTKACECleanLinksEnabled()) return value;
    if ([value isKindOfClass:NSURL.class]) {
        NSString *cleaned = YTKACECleanYouTubeLink([value absoluteString]);
        return [NSURL URLWithString:cleaned] ?: value;
    }
    if ([value isKindOfClass:NSString.class]) return YTKACECleanLinksInText(value);
    return value;
}

static void YTKACECleanCopyEndpoint(id sharer) {
    id endpoint = nil;
    @try {
        endpoint = [sharer valueForKey:@"_navigationEndpoint"];
    } @catch (__unused NSException *exception) {
        return;
    }
    SEL extension = NSSelectorFromString(@"messageForFieldNumber:");
    if (![endpoint respondsToSelector:extension]) return;
    id copyText = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(endpoint, extension, YTKACECopyTextField);
    SEL getText = NSSelectorFromString(@"text");
    SEL setText = NSSelectorFromString(@"setText:");
    if (![copyText respondsToSelector:getText] || ![copyText respondsToSelector:setText]) return;
    NSString *text = ((id (*)(id, SEL))objc_msgSend)(copyText, getText);
    NSString *cleaned = YTKACECleanLinksInText(text);
    YTKACEDebugLog(@"links", @"copy text %@ -> %@", text ?: @"-", cleaned ?: @"-");
    if (cleaned != nil && ![cleaned isEqualToString:text]) {
        ((void (*)(id, SEL, id))objc_msgSend)(copyText, setText, cleaned);
    }
}

#define YTKACE_SHARE_OBJECT_HOOK(name, original) \
static void name(id receiver, SEL selector, id objectID, long long type, id URL, id title, id success, id failure) { \
    id cleaned = YTKACECleanLinkObject(URL); \
    YTKACEDebugLog(@"links", @"%@ url %@ -> %@", NSStringFromClass([receiver class]), URL, cleaned); \
    ((void (*)(id, SEL, id, long long, id, id, id, id))original)(receiver, selector, objectID, type, cleaned, title, \
                                                                  success, failure); \
}

YTKACE_SHARE_OBJECT_HOOK(YTKACECopyShareObject, OriginalCopyShareObject)
YTKACE_SHARE_OBJECT_HOOK(YTKACETextShareObject, OriginalTextShareObject)
YTKACE_SHARE_OBJECT_HOOK(YTKACEMailShareObject, OriginalMailShareObject)
YTKACE_SHARE_OBJECT_HOOK(YTKACESystemShareObject, OriginalSystemShareObject)

static void YTKACECopyShare(id receiver, SEL selector, id success, id failure) {
    if (YTKACECleanLinksEnabled()) YTKACECleanCopyEndpoint(receiver);
    ((void (*)(id, SEL, id, id))OriginalCopyShare)(receiver, selector, success, failure);
}

static void YTKACESystemShareText(id receiver, SEL selector, id text, id URL, id subject, id entity,
                                  id success, id failure) {
    id cleanedText = YTKACECleanLinkObject(text);
    id cleanedURL = YTKACECleanLinkObject(URL);
    YTKACEDebugLog(@"links", @"system text %@ url %@ -> %@", text, URL, cleanedURL);
    ((void (*)(id, SEL, id, id, id, id, id, id))OriginalSystemShareText)(receiver, selector, cleanedText, cleanedURL,
                                                                         subject, entity, success, failure);
}

static id YTKACESystemItem(id receiver, SEL selector, id controller, id activityType) {
    id item = ((id (*)(id, SEL, id, id))OriginalSystemItem)(receiver, selector, controller, activityType);
    id cleaned = YTKACECleanLinkObject(item);
    YTKACEDebugLog(@"links", @"system item %@ %@ -> %@", activityType, item, cleaned);
    return cleaned;
}

static id YTKACESystemPlaceholder(id receiver, SEL selector, id controller) {
    id item = ((id (*)(id, SEL, id))OriginalSystemPlaceholder)(receiver, selector, controller);
    return YTKACECleanLinkObject(item);
}

static void YTKACEMessageSetBody(id receiver, SEL selector, id body) {
    ((void (*)(id, SEL, id))OriginalMessageSetBody)(receiver, selector, YTKACECleanLinkObject(body));
}

static void YTKACEMailSetBody(id receiver, SEL selector, id body, BOOL html) {
    ((void (*)(id, SEL, id, BOOL))OriginalMailSetBody)(receiver, selector, YTKACECleanLinkObject(body), html);
}

static void YTKACEOpenURL(id receiver, SEL selector, id URL, id options, id completion) {
    id target = URL;
    if (YTKACEFeatureEnabled(YTKACEDirectLinksKey)) {
        target = YTKACEDirectLinkURL(URL);
        if (target != URL) YTKACEDebugLog(@"links", @"open redirect %@ -> %@", ((NSURL *)URL).host ?: @"-", ((NSURL *)target).host ?: @"-");
    }
    ((void (*)(id, SEL, id, id, id))OriginalOpenURL)(receiver, selector, target, options, completion);
}

static BOOL YTKACELinkMethodTypes(NSString *className, NSString *selector, const char *prefix) {
    Method method = class_getInstanceMethod(NSClassFromString(className), NSSelectorFromString(selector));
    const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
    return types != NULL && strncmp(types, prefix, strlen(prefix)) == 0;
}

static BOOL YTKACEInstallLinkHook(NSString *className, NSString *selector, const char *prefix, IMP replacement,
                                  IMP *original) {
    return YTKACELinkMethodTypes(className, selector, prefix) &&
        YTKACEInstallInstanceHook(className, selector, replacement, original);
}

void YTKACEInstallLinkCleaningHooks(void) {
    NSString *shareObject = @"shareObjectWithID:shareType:URL:title:successBlock:errorBlock:";
    const char *shareObjectTypes = "v64@0:8@16q24@32@40";
    BOOL copyObject = YTKACEInstallLinkHook(@"YTCopyLinkSharer", shareObject, shareObjectTypes,
                                            (IMP)YTKACECopyShareObject, &OriginalCopyShareObject);
    BOOL copyPlain = YTKACEInstallLinkHook(@"YTCopyLinkSharer", @"shareWithSuccessBlock:errorBlock:", "v32@0:8",
                                           (IMP)YTKACECopyShare, &OriginalCopyShare);
    BOOL textObject = YTKACEInstallLinkHook(@"YTTextMessageSharer", shareObject, shareObjectTypes,
                                            (IMP)YTKACETextShareObject, &OriginalTextShareObject);
    BOOL mailObject = YTKACEInstallLinkHook(@"YTEmailSharer", shareObject, shareObjectTypes,
                                            (IMP)YTKACEMailShareObject, &OriginalMailShareObject);
    BOOL systemObject = YTKACEInstallLinkHook(@"YTSystemActivityDialogSharer", shareObject, shareObjectTypes,
                                              (IMP)YTKACESystemShareObject, &OriginalSystemShareObject);
    BOOL systemText = YTKACEInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"shareWithText:url:subject:serializedShareEntity:successBlock:errorBlock:", "v64@0:8@16@24@32@40",
        (IMP)YTKACESystemShareText, &OriginalSystemShareText);
    BOOL systemItem = YTKACEInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"activityViewController:itemForActivityType:", "@32@0:8@16@24",
        (IMP)YTKACESystemItem, &OriginalSystemItem);
    BOOL systemPlaceholder = YTKACEInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"activityViewControllerPlaceholderItem:", "@24@0:8@16",
        (IMP)YTKACESystemPlaceholder, &OriginalSystemPlaceholder);
    BOOL messageBody = YTKACEInstallLinkHook(@"MFMessageComposeViewController", @"setBody:", "v24@0:8@16",
                                             (IMP)YTKACEMessageSetBody, &OriginalMessageSetBody);
    BOOL mailBody = YTKACEInstallLinkHook(@"MFMailComposeViewController", @"setMessageBody:isHTML:", "v28@0:8@16B24",
                                          (IMP)YTKACEMailSetBody, &OriginalMailSetBody);
    BOOL openURL = YTKACEInstallLinkHook(@"UIApplication", @"openURL:options:completionHandler:", "v40@0:8@16@24",
                                         (IMP)YTKACEOpenURL, &OriginalOpenURL);
    YTKACEDownloadLog(@"links", @"hooks copy=%d/%d text=%d mail=%d system=%d/%d/%d/%d compose=%d/%d open=%d",
                      copyObject, copyPlain, textObject, mailObject, systemObject, systemText, systemItem,
                      systemPlaceholder, messageBody, mailBody, openURL);
}
