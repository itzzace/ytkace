#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Tweak/Features/Interface/YouTubeLinkCleaner.h"
#import "../Tweak/Features/Interface/CopyLinkHooks.h"
#import "../Tweak/Runtime/Preferences.h"
#import "../Tweak/Features/Downloads/DownloadLog.h"

UIActivityType const UIActivityTypeCopyToPasteboard = @"copy";
NSString * const YTKACECleanCopiedLinksKey = @"YTKACE.Preference.Sharing.CleanCopiedLinks";
static BOOL Enabled;
BOOL YTKACEFeatureEnabled(NSString *key) {
    NSCAssert([key isEqualToString:YTKACECleanCopiedLinksKey], @"Unexpected preference");
    return Enabled;
}
void YTKACEDownloadLog(NSString *scope, NSString *format, ...) {
    (void)scope; (void)format;
}
@implementation UIActivityViewController
@end
@implementation UIPasteboard
+ (UIPasteboard *)generalPasteboard {
    static UIPasteboard *board;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ board = [UIPasteboard new]; });
    return board;
}
- (void)setString:(NSString *)string { self.lastValue = string; }
- (NSString *)string { self.contentReads++; return self.lastValue; }
- (void)setURL:(NSURL *)URL { self.lastValue = URL; }
- (NSURL *)URL { self.contentReads++; return self.lastValue; }
@end

// Both observed YTCopyLinkSharer entry points, using the real hook installer.
@interface YTCopyLinkSharer : NSObject
@property(nonatomic, strong) UIPasteboard *board;
@property(nonatomic, strong) id value;
@property(nonatomic) BOOL raises;
@property(nonatomic, copy) void (^onWrite)(void);
- (void)shareObjectWithID:(id)objectID shareType:(NSInteger)shareType URL:(NSURL *)URL
                   title:(id)title successBlock:(void (^)(void))success errorBlock:(id)error;
- (void)shareWithSuccessBlock:(void (^)(id))success errorBlock:(void (^)(id))error;
@end
@implementation YTCopyLinkSharer
- (void)shareObjectWithID:(id)objectID shareType:(NSInteger)shareType URL:(NSURL *)URL
                   title:(id)title successBlock:(void (^)(void))success errorBlock:(id)error {
    NSCAssert([objectID isEqual:@"id"] && shareType == 42 && [title isEqual:@"title"] &&
        [error isEqual:@"error"], @"Forward all other arguments unchanged");
    self.board.string = URL.absoluteString;
    if (success) success();
}
- (void)shareWithSuccessBlock:(void (^)(id))success errorBlock:(void (^)(id))error {
    if ([self.value isKindOfClass:NSURL.class]) self.board.URL = self.value;
    else self.board.string = self.value;
    if (self.onWrite) self.onWrite();
    if (self.raises) [NSException raise:@"test" format:@"Scope must unwind"];
    if (success) success(@[@"success"]);
    if (error) error(@[@"error"]);
}
@end

static NSUInteger Checks;
static void Check(BOOL condition, NSString *message) {
    Checks++;
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static NSUInteger TestCopyBoundaries(void) {
    NSUInteger before = Checks;
    YTKACEInstallCopyLinkHooks();
    NSString *tracked = @"https://youtu.be/video?si=secret&t=31&list=PL1&index=2";
    NSString *clean = @"https://youtu.be/video?t=31&list=PL1&index=2";
    NSURL *URL = [NSURL URLWithString:tracked];
    UIPasteboard *board = UIPasteboard.generalPasteboard;
    YTCopyLinkSharer *sharer = [YTCopyLinkSharer new];
    sharer.board = board;
    sharer.value = tracked;
    Enabled = NO;
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check(board.lastValue == tracked, @"Disabled command must preserve the original object");
    Check(YTKACECopyLinkActivityItem(URL) == URL, @"Disabled activity keeps original URL item");
    [sharer shareObjectWithID:@"id" shareType:42 URL:URL title:@"title"
                successBlock:nil errorBlock:@"error"];
    Check([board.lastValue isEqual:tracked], @"Disabled direct URL copy");
    Enabled = YES;
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check([board.lastValue isEqual:clean], @"Command cleans a string before writing");
    sharer.value = URL;
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check([[board.lastValue absoluteString] isEqual:clean], @"Command cleans a URL before writing");
    __block BOOL directSuccess = NO;
    [sharer shareObjectWithID:@"id" shareType:42 URL:URL title:@"title"
        successBlock:^{ directSuccess = YES; } errorBlock:@"error"];
    Check(directSuccess && [board.lastValue isEqual:clean], @"Direct URL copy preserves callback");
    [sharer shareObjectWithID:@"id" shareType:42 URL:nil title:@"title"
        successBlock:nil errorBlock:@"error"];
    Check(board.lastValue == nil, @"Nil URL passes through");

    board.string = tracked;
    Check(board.lastValue == tracked, @"Unrelated direct string copy stays unchanged");
    board.URL = URL;
    Check(board.lastValue == URL, @"Unrelated direct URL copy stays unchanged");
    sharer.value = @"A comment containing https://youtu.be/video?si=secret";
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check(board.lastValue == sharer.value, @"Prose stays unchanged inside command");
    sharer.value = @"https://example.org/?si=secret&utm_source=keep";
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check(board.lastValue == sharer.value, @"Other hosts stay unchanged inside command");
    UIPasteboard *named = [UIPasteboard new];
    sharer.board = named;
    sharer.value = tracked;
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    Check(named.lastValue == tracked, @"Named pasteboard stays unchanged");
    sharer.board = board;

    __block NSUInteger callbacks = 0;
    [sharer shareWithSuccessBlock:^(id actions) {
        Check([actions isEqual:@[@"success"]], @"Preserve success payload");
        Check([board.lastValue isEqual:clean], @"Clean before success callback");
        board.string = tracked;
        Check(board.lastValue == tracked, @"Success callback writes are outside scope");
        callbacks++;
    } errorBlock:^(id actions) {
        Check([actions isEqual:@[@"error"]], @"Preserve error payload");
        board.URL = URL;
        Check(board.lastValue == URL, @"Error callback writes are outside scope");
        callbacks++;
    }];
    Check(callbacks == 2, @"Original callbacks run once each");
    // A different thread must not inherit the active copy scope.
    sharer.onWrite = ^{
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            board.string = tracked;
            Check(board.lastValue == tracked, @"Concurrent copies stay unchanged");
            dispatch_semaphore_signal(done);
        });
        Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
            @"Concurrent copy finished");
    };
    [sharer shareWithSuccessBlock:nil errorBlock:nil];
    sharer.onWrite = nil;
    sharer.raises = YES;
    @try { [sharer shareWithSuccessBlock:nil errorBlock:nil]; }
    @catch (NSException *exception) { (void)exception; }
    board.string = tracked;
    Check(board.lastValue == tracked, @"Exceptions restore copy scope");

    id<UIActivityItemSource> item = YTKACECopyLinkActivityItem(URL);
    Check([item activityViewControllerPlaceholderItem:nil] == URL, @"Preserve placeholder");
    Check([[item activityViewController:nil itemForActivityType:@"mail"] isEqual:URL],
        @"Non-copy sharing stays unchanged");
    Check([item activityViewController:nil itemForActivityType:nil] == URL,
        @"Unspecified activity stays unchanged");
    Check([[[item activityViewController:nil itemForActivityType:UIActivityTypeCopyToPasteboard]
        absoluteString] isEqual:clean], @"Native sheet Copy cleans only its URL");
    Enabled = NO;
    Check([item activityViewController:nil itemForActivityType:UIActivityTypeCopyToPasteboard] == URL,
        @"Read preference again when activity is selected");
    Check(board.contentReads == 0 && named.contentReads == 0, @"Never read clipboard content");
    return Checks - before;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"Expected corpus path");
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSArray *cases = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        Check([cases isKindOfClass:NSArray.class] && cases.count > 0, @"Load corpus");
        for (NSDictionary *test in cases) {
            NSString *result = YTKACECleanYouTubeLink(test[@"input"]);
            Check([[result dataUsingEncoding:NSUTF8StringEncoding]
                isEqual:[test[@"expected"] dataUsingEncoding:NSUTF8StringEncoding]],
                [NSString stringWithFormat:@"%@: expected %@, got %@",
                    test[@"name"], test[@"expected"], result]);
            Check([YTKACECleanYouTubeLink(result) isEqualToString:result], @"Idempotence");
        }
        for (NSString *unit in @[@"a", @"é"]) {
            NSString *large = [@"https://youtu.be/id?si=x&data=" stringByAppendingString:
                [@"" stringByPaddingToLength:8200 withString:unit startingAtIndex:0]];
            Check(YTKACECleanYouTubeLink(large) == large, @"Oversized input stays unchanged");
        }
        NSUInteger boundaryChecks = TestCopyBoundaries();
        printf("%lu URL regressions plus idempotence; %lu copy boundary checks passed\n",
            (unsigned long)cases.count, (unsigned long)boundaryChecks);
    }
    return 0;
}
