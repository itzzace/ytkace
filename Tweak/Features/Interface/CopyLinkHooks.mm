#import "CopyLinkHooks.h"
#import "YouTubeLinkCleaner.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

static IMP OriginalCopyObject;
static IMP OriginalCopyCommand;
static IMP OriginalSetString;
static IMP OriginalSetURL;
// Only the synchronous YTCopyLinkSharer command may filter outgoing writes.
// No pasteboard reads, polling, notifications, or post-copy rewrites.
static thread_local NSUInteger CopyLinkDepth;

static NSURL *YTKACECopyURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] ||
        !YTKACEFeatureEnabled(YTKACECleanCopiedLinksKey)) return URL;
    NSString *original = URL.absoluteString;
    NSString *cleaned = YTKACECleanYouTubeLink(original);
    if ([cleaned isEqualToString:original]) return URL;
    return [NSURL URLWithString:cleaned] ?: URL;
}

static BOOL YTKACEFilteringCopy(id pasteboard) {
    return CopyLinkDepth != 0 &&
        YTKACEFeatureEnabled(YTKACECleanCopiedLinksKey) &&
        pasteboard == UIPasteboard.generalPasteboard;
}

static void YTKACESetCopyString(id receiver, SEL selector, NSString *value) {
    if (YTKACEFilteringCopy(receiver) && [value isKindOfClass:NSString.class]) {
        value = YTKACECleanYouTubeLink(value);
    }
    ((void (*)(id, SEL, id))OriginalSetString)(receiver, selector, value);
}

static void YTKACESetCopyURL(id receiver, SEL selector, NSURL *URL) {
    if (YTKACEFilteringCopy(receiver)) URL = YTKACECopyURL(URL);
    ((void (*)(id, SEL, id))OriginalSetURL)(receiver, selector, URL);
}

static void YTKACECopyObject(id receiver, SEL selector, id objectID,
                            NSInteger shareType, NSURL *URL, id title,
                            id success, id error) {
    ((void (*)(id, SEL, id, NSInteger, id, id, id, id))OriginalCopyObject)(
        receiver, selector, objectID, shareType, YTKACECopyURL(URL), title, success, error);
}

static void (^YTKACEOutsideCopy(void (^callback)(id)))(id) {
    if (callback == nil) return nil;
    return ^(id actions) {
        NSUInteger previous = CopyLinkDepth;
        CopyLinkDepth = 0;
        @try { callback(actions); }
        @finally { CopyLinkDepth = previous; }
    };
}

static void YTKACECopyCommand(id receiver, SEL selector,
                             void (^success)(id), void (^error)(id)) {
    if (!YTKACEFeatureEnabled(YTKACECleanCopiedLinksKey)) {
        ((void (*)(id, SEL, id, id))OriginalCopyCommand)(receiver, selector, success, error);
        return;
    }
    NSUInteger previous = CopyLinkDepth;
    CopyLinkDepth++;
    @try {
        ((void (*)(id, SEL, id, id))OriginalCopyCommand)(receiver, selector,
            YTKACEOutsideCopy(success), YTKACEOutsideCopy(error));
    } @finally {
        CopyLinkDepth = previous;
    }
}

@interface YTKACECopyLinkItem : NSObject <UIActivityItemSource>
@property(nonatomic, strong) NSURL *URL;
@end

@implementation YTKACECopyLinkItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {
    (void)controller;
    return self.URL;
}
- (id)activityViewController:(UIActivityViewController *)controller
        itemForActivityType:(UIActivityType)activityType {
    (void)controller;
    return [activityType isEqualToString:UIActivityTypeCopyToPasteboard]
        ? YTKACECopyURL(self.URL) : self.URL;
}
@end

id YTKACECopyLinkActivityItem(NSURL *URL) {
    if (!YTKACEFeatureEnabled(YTKACECleanCopiedLinksKey)) return URL;
    YTKACECopyLinkItem *item = [YTKACECopyLinkItem new];
    item.URL = URL;
    return item;
}

void YTKACEInstallCopyLinkHooks(void) {
    YTKACEInstallInstanceHook(@"UIPasteboard", @"setString:",
        (IMP)YTKACESetCopyString, &OriginalSetString);
    YTKACEInstallInstanceHook(@"UIPasteboard", @"setURL:",
        (IMP)YTKACESetCopyURL, &OriginalSetURL);
    YTKACEInstallInstanceHook(@"YTCopyLinkSharer",
        @"shareObjectWithID:shareType:URL:title:successBlock:errorBlock:",
        (IMP)YTKACECopyObject, &OriginalCopyObject);
    YTKACEInstallInstanceHook(@"YTCopyLinkSharer", @"shareWithSuccessBlock:errorBlock:",
        (IMP)YTKACECopyCommand, &OriginalCopyCommand);
}
