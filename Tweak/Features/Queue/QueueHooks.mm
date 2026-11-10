#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEQueueKey = @"YTKACE.Preference.Playback.LocalQueue";

static NSString *YTKACEQueueClip(id object, NSUInteger limit);
static NSUInteger YTKACEQueueIndexOfVideo(NSString *videoID);
static NSUInteger YTKACEQueueCurrentIndex(void);
static NSString *YTKACEQueueOpenVideoID(void);
static NSUInteger YTKACEQueueUpcomingIndex(NSString *playing);
static void YTKACEQueueRemoveAt(NSUInteger index);
static BOOL YTKACEQueueVideoIsOpen(void);
static NSString *YTKACEQueueDescribeHost(id candidate);
static void YTKACEQueuePruneController(void);
static NSString *YTKACEQueueCursor(void);
static NSUInteger YTKACEQueueNextIndex(void);
static id YTKACEQueueWatchCommand(NSString *videoID);
static BOOL YTKACEQueueSendCommand(id command, NSString *videoID);
static BOOL YTKACEQueueOpenMinimized(NSString *videoID);
static BOOL YTKACEQueueNoteStarted(NSString *videoID);
static id YTKACEQueueItemMenu(NSString *videoID);
static BOOL YTKACEQueueIsActive(void);
static NSString *YTKACEQueueCurrentVideoID(void);
static id YTKACEQueueValue(id object, NSArray<NSString *> *keys);
static id YTKACEQueueSentinelCommand(NSString *action, NSString *videoID);
static void YTKACEQueueRefreshPanel(void);
static void YTKACEQueueRebuildWatchPage(void);
static void YTKACEQueueRestoreLoopMode(id controller);
static long long YTKACEQueueSavedLoopMode(void);
static void YTKACEQueueStoreLoopMode(long long mode);
static void YTKACEQueueApplyLoopMode(id controller, long long mode);
static void YTKACEQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex);

static IMP OriginalDiscoveryExecute;
static IMP OriginalPanelParse;
static IMP OriginalResponsePanel;
static IMP OriginalSetWatchNext;
static IMP OriginalPrepareWatchNext;
static IMP OriginalViewUpdateWatchNext;
static IMP OriginalPanelInit;
static IMP OriginalPanelInitQueue;
static IMP OriginalQueueControllerInit;
static IMP OriginalDidPressNext;
static IMP OriginalDidPressPrevious;
static IMP OriginalAutonavPlayNext;
static IMP OriginalMoveItem;
static IMP OriginalRemoveItem;
static IMP OriginalRemoveIndex;
static IMP OriginalClearQueue;
static IMP OriginalIsQueue;
static IMP OriginalHasQueueContents;
static IMP OriginalCanMoveItem;
static IMP OriginalNextVideoTitle;
static IMP OriginalNextVideoIndex;
static IMP OriginalReplaceAutoplay;
static IMP OriginalSetCanReorder;
static IMP OriginalAllowsReordering;
static IMP OriginalCellControllerSetCell;
static IMP OriginalCellPrepareForReuse;
static IMP OriginalAlphaForIndex;
static IMP OriginalUpdateCellForIndex;
static IMP OriginalSlideLayoutSubviews;
static NSTimeInterval YTKACEQueueActiveVideoTime;
static IMP OriginalSetVideoCountText;
static IMP OriginalDidTapShuffle;
static IMP OriginalDidTapLoop;
static IMP OriginalDidTapAction;
static IMP OriginalAutonavHasNext;
static IMP OriginalAutonavHasPrevious;
static IMP OriginalQueueHasNext;
static IMP OriginalQueueHasPrevious;
static IMP OriginalNextNavigable;
static IMP OriginalPreviousNavigable;
static IMP OriginalPanelByline;
static NSString *const YTKACEQueueLoopKey = @"YTKACE.Preference.Playback.QueueLoopMode";
static __weak id YTKACEQueuePlayerViewController;
static NSString *YTKACEQueueCurrentOverride;
static NSString *YTKACEQueueActiveVideo;
static __weak id YTKACEQueuePanelController;
static __weak id YTKACEQueueControllerInstance;
static id YTKACELastWatchNextResponse;
static BOOL YTKACEQueuePanelInjected;
static __weak id YTKACEQueueWatchViewController;
static IMP OriginalRouterHandle;
static IMP OriginalRouterHandleCompletion;
static IMP OriginalScopedRouterHandle;
static IMP OriginalScopedRouterHandleCompletion;

static NSMutableArray<NSDictionary *> *YTKACEQueueItems;
static __weak id YTKACEQueueResponder;
static NSString *YTKACEQueueAdvancedFromVideoID;
static BOOL YTKACEQueueSyncSuppressed;

// The cursor is the queue item that most recently played. Items after it are
// upcoming; nil means the queue was built while idle and has not started yet.
static NSString *const YTKACEQueueCursorKey = @"YTKACE.Queue.Cursor";

static NSString *YTKACEQueueCursor(void) {
    id value = [NSUserDefaults.standardUserDefaults
        objectForKey:YTKACEQueueCursorKey];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Set once the last queued video has played to the end with no loop.
static NSString *const YTKACEQueueFinishedKey = @"YTKACE.Queue.Finished";

static BOOL YTKACEQueueFinished(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:YTKACEQueueFinishedKey];
}

static void YTKACEQueueSetFinished(BOOL finished) {
    if (finished == YTKACEQueueFinished()) return;
    [NSUserDefaults.standardUserDefaults setBool:finished
                                          forKey:YTKACEQueueFinishedKey];
}

static void YTKACEQueueSetCursor(NSString *videoID) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (videoID.length == 0) {
        [defaults removeObjectForKey:YTKACEQueueCursorKey];
    } else if (![videoID isEqualToString:YTKACEQueueCursor()]) {
        [defaults setObject:videoID forKey:YTKACEQueueCursorKey];
    }
}

static NSString *YTKACEQueueStorePath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) return nil;
    NSString *folder = [documents stringByAppendingPathComponent:@"YTKACE"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return [folder stringByAppendingPathComponent:@"queue.plist"];
}

static void YTKACEQueueSave(void) {
    NSString *path = YTKACEQueueStorePath();
    if (path.length == 0) return;
    if (YTKACEQueueItems.count == 0) {
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        YTKACEQueueSetCursor(nil);
        YTKACEQueueSetFinished(NO);
        return;
    }
    [YTKACEQueueItems writeToFile:path atomically:YES];
}

static NSMutableArray<NSDictionary *> *YTKACEQueue(void) {
    if (YTKACEQueueItems != nil) return YTKACEQueueItems;
    NSString *path = YTKACEQueueStorePath();
    NSArray *stored = path.length != 0
        ? [NSArray arrayWithContentsOfFile:path]
        : nil;
    YTKACEQueueItems = stored != nil ? [stored mutableCopy] : [NSMutableArray array];
    return YTKACEQueueItems;
}

BOOL YTKACEQueueHasItems(void) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    return YTKACEQueueNextIndex() != NSNotFound;
}

// True when the queue decides what plays after the current video, including
// a video opened outside the queue while queued videos are still waiting.
BOOL YTKACEQueueOwnsCurrentVideo(void) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    return YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID()) != NSNotFound ||
        YTKACEQueueNextIndex() != NSNotFound;
}

static NSString *YTKACEQueueVideoIDFromParams(NSData *data, int *position) {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    const NSUInteger length = data.length;
    if (position != NULL) *position = 0;
    for (NSUInteger index = 0; index + 1 < length; index++) {
        if (bytes[index] == 0x08 && (bytes[index + 1] == 0x02 ||
                                     bytes[index + 1] == 0x03)) {
            if (position != NULL) *position = bytes[index + 1];
            break;
        }
    }
    for (NSUInteger index = 0; index + 12 < length; index++) {
        if (bytes[index] != 0x0a || bytes[index + 1] != 0x0b) continue;
        NSString *candidate = [[NSString alloc]
            initWithBytes:bytes + index + 2 length:11
                 encoding:NSUTF8StringEncoding];
        if (candidate.length != 11) continue;
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"]
            invertedSet];
        if ([candidate rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            continue;
        }
        return candidate;
    }
    return nil;
}

static NSString *YTKACEQueueDiscoveryParams(id command) {
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    if (![dump containsString:@"discovery_params"]) return nil;
    // A plain video tap carries discovery params too; only treat a command
    // as a queue add when it is not a bare watch endpoint.
    const BOOL watch = [dump containsString:@"watch_endpoint"] ||
        [dump containsString:@"watchEndpoint"];
    if (watch && [dump rangeOfString:@"queue"
                             options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return nil;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"discovery_params:\\s*\"([^\"]+)\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return nil;
    return [dump substringWithRange:[match rangeAtIndex:1]];
}

static NSString *YTKACEQueueTitleNearView(id view) {
    UIView *current = [view isKindOfClass:UIView.class] ? view : nil;
    NSString *best = nil;
    for (NSUInteger depth = 0; depth < 6 && current != nil; depth++) {
        NSString *label = current.accessibilityLabel;
        if (label.length > best.length) best = label;
        current = current.superview;
    }
    if (best.length < 6) return nil;
    return best;
}


static void YTKACEQueueUpdateEntry(NSString *videoID, NSString *title,
                                   NSString *author, NSString *length) {
    if (videoID.length == 0 || title.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *queue = YTKACEQueue();
        for (NSUInteger index = 0; index < queue.count; index++) {
            if (![queue[index][@"videoId"] isEqualToString:videoID]) continue;
            NSMutableDictionary *entry = [queue[index] mutableCopy];
            entry[@"title"] = title;
            if (author.length != 0) entry[@"author"] = author;
            if (length.length != 0) entry[@"length"] = length;
            queue[index] = entry;
            YTKACEQueueSave();
            YTKACEQueueRefreshPanel();
            break;
        }
    });
}


static id YTKACEQueueValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector]) continue;
        NSMethodSignature *signature =
            [object methodSignatureForSelector:selector];
        const char *type = signature.methodReturnType;
        if (type == NULL) continue;
        if (strcmp(type, @encode(id)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            void *raw = NULL;
            [invocation getReturnValue:&raw];
            id value = (__bridge id)raw;
            if (value != nil) return value;
            continue;
        }
        if (strcmp(type, @encode(int)) == 0 ||
            strcmp(type, @encode(unsigned int)) == 0 ||
            strcmp(type, @encode(long long)) == 0 ||
            strcmp(type, @encode(unsigned long long)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            long long number = 0;
            [invocation getReturnValue:&number];
            if (number != 0) return @(number);
        }
    }
    return nil;
}

static id YTKACEQueueVideoDetails(id response) {
    id details = YTKACEQueueValue(response, @[@"videoDetails"]);
    if (details != nil) return details;
    for (NSString *wrapper in @[@"playerData", @"playerResponse",
                                @"playerResponseData"]) {
        id inner = YTKACEQueueValue(response, @[wrapper]);
        details = YTKACEQueueValue(inner, @[@"videoDetails"]);
        if (details != nil) return details;
    }
    return nil;
}

static NSString *YTKACEQueueLengthText(NSString *seconds) {
    const NSInteger total = seconds.integerValue;
    if (total <= 0) return nil;
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total % 3600) / 60;
    const NSInteger remainder = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours,
            (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes,
        (long)remainder];
}

static void YTKACEQueueFetchFromOEmbed(NSString *videoID) {
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/oembed?url=https%%3A%%2F%%2Fwww.youtube.com"
        @"%%2Fwatch%%3Fv%%3D%@&format=json", videoID];
    NSURL *url = [NSURL URLWithString:address];
    if (url == nil) return;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:url
      completionHandler:^(NSData *data, __unused NSURLResponse *response,
                          __unused NSError *error) {
        if (data.length == 0) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        YTKACEQueueUpdateEntry(videoID, json[@"title"], json[@"author_name"],
                               nil);
    }];
    [task resume];
}

static void YTKACEQueueFetchTitle(NSString *videoID) {
    if (videoID.length == 0) return;
    static NSMutableSet<NSString *> *pending;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [NSMutableSet set];
    });
    @synchronized (pending) {
        if ([pending containsObject:videoID]) return;
        [pending addObject:videoID];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized (pending) {
            [pending removeObject:videoID];
        }
    });
    YTKACEQueueFetchFromOEmbed(videoID);
    YTKACEResolvePlayerResponse(videoID, ^(id response, __unused NSError *error) {
        id details = YTKACEQueueVideoDetails(response);
        id rawTitle = YTKACEQueueValue(details, @[@"title"]);
        NSString *title = [rawTitle isKindOfClass:NSString.class] ? rawTitle : nil;
        id rawAuthor = YTKACEQueueValue(details,
            @[@"author", @"channelTitle", @"ownerChannelName"]);
        NSString *author = [rawAuthor isKindOfClass:NSString.class]
            ? rawAuthor : nil;
        id rawSeconds = YTKACEQueueValue(details,
            @[@"lengthSeconds", @"lengthSecondsString", @"videoLengthSeconds"]);
        NSString *seconds = nil;
        if ([rawSeconds isKindOfClass:NSString.class]) {
            seconds = rawSeconds;
        } else if ([rawSeconds isKindOfClass:NSNumber.class]) {
            seconds = [rawSeconds stringValue];
        }
        NSString *length = YTKACEQueueLengthText(seconds);

        if (title.length != 0) {
            YTKACEQueueUpdateEntry(videoID, title, author, length);
        }
    });
}

static void YTKACEQueueAdd(NSString *videoID, NSString *title,
                           BOOL playNext) {
    NSMutableArray *queue = YTKACEQueue();
    NSString *playing = YTKACEQueueOpenVideoID();
    YTKACEDebugLog(@"queue", @"add %@ next=%d playing=%@ current=%@ queue=%lu cursor=%@ "
          @"watch=[%@] player=[%@] responder=[%@]",
          videoID, playNext, playing ?: @"nil", YTKACEQueueCurrentVideoID() ?: @"nil",
          (unsigned long)queue.count, YTKACEQueueCursor() ?: @"nil",
          YTKACEQueueDescribeHost(YTKACEQueueWatchViewController),
          YTKACEQueueDescribeHost(YTKACEQueuePlayerViewController),
          YTKACEQueueDescribeHost(YTKACEQueueResponder));
    if ([playing isEqualToString:videoID] &&
        YTKACEQueueIndexOfVideo(videoID) != NSNotFound) {
        return;
    }
    // With nothing open the old queue went away with the player, so this
    // starts a new one, opened paused in the miniplayer like YouTube's own.
    if (playing.length == 0) {
        [queue removeAllObjects];
        YTKACEQueueSetCursor(nil);
    }
    NSUInteger existing = YTKACEQueueIndexOfVideo(videoID);
    if (existing != NSNotFound) YTKACEQueueRemoveAt(existing);
    if (playing.length != 0) {
        YTKACEQueueNoteStarted(playing);
        // A new queue starts with the video on screen; an existing one keeps
        // its order and the new video goes after what is already queued.
        if (queue.count == 0) {
            NSMutableDictionary *seed = [NSMutableDictionary dictionary];
            seed[@"videoId"] = playing;
            [queue addObject:seed];
            YTKACEQueueSetCursor(playing);
            YTKACEQueueFetchTitle(playing);
        }
    }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"videoId"] = videoID;
    if (title.length != 0) item[@"title"] = title;
    if (playNext) {
        [queue insertObject:item atIndex:MIN(YTKACEQueueUpcomingIndex(playing),
                                             queue.count)];
    } else {
        [queue addObject:item];
    }
    YTKACEQueueSetFinished(NO);
    YTKACEQueueSave();
    YTKACEDebugLog(@"queue", @"add done queue=%@", [queue valueForKey:@"videoId"]);
    if (title.length == 0) YTKACEQueueFetchTitle(videoID);
    YTKACEShowNotice(playNext ? YTKACELocalized(@"Playing next")
                              : YTKACELocalized(@"Added to queue"));
    if (playing.length == 0) {
        if (YTKACEQueueOpenMinimized(videoID)) YTKACEQueueSetCursor(videoID);
        return;
    }
    YTKACEQueueAppendToController(item, YTKACEQueueIndexOfVideo(videoID));
    YTKACEQueuePruneController();
    if (!YTKACEQueuePanelInjected || queue.count <= 2) {
        YTKACEQueueRebuildWatchPage();
    }
    YTKACEQueueRefreshPanel();
}

static __weak id YTKACEQueueCommandSender;
static __weak id YTKACEQueueCommandView;
static __weak id YTKACEQueueRouter;
static IMP YTKACEQueueRouterOriginal;
static BOOL YTKACEQueueRouterHasCompletion;

static void YTKACEQueueNoteRouter(id router, IMP original, BOOL completion,
                                  id view, id sender) {
    YTKACEQueueCommandSender = sender;
    YTKACEQueueCommandView = view;
    if (router == nil || original == NULL) return;
    YTKACEQueueRouter = router;
    YTKACEQueueRouterOriginal = original;
    YTKACEQueueRouterHasCompletion = completion;
}

static BOOL YTKACEQueueSendViaRouter(id command, id view, id sender) {
    id router = YTKACEQueueRouter;
    IMP original = YTKACEQueueRouterOriginal;
    if (command == nil || router == nil || original == NULL) return NO;
    @try {
        if (YTKACEQueueRouterHasCompletion) {
            return ((BOOL (*)(id, SEL, id, id, id, id, id))original)(router,
                @selector(handleCommand:entry:fromView:sender:completionBlock:),
                command, nil, view, sender, nil);
        }
        return ((BOOL (*)(id, SEL, id, id, id, id))original)(router,
            @selector(handleCommand:entry:fromView:sender:), command, nil, view,
            sender);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL YTKACEQueueSendViaEvent(id command, id view, id responder) {
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    SEL eventSelector =
        @selector(eventWithCommand:fromView:displayTitle:firstResponder:);
    if (command == nil || responder == nil ||
        ![eventClass respondsToSelector:eventSelector]) {
        return NO;
    }
    @try {
        id event = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            eventClass, eventSelector, command, view, nil, responder);
        if (event == nil) return NO;
        ((void (*)(id, SEL))objc_msgSend)(event, @selector(send));
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

static void YTKACEQueueNoteSent(NSString *videoID) {
    YTKACEQueueActiveVideo = videoID;
    YTKACEQueueActiveVideoTime = NSDate.timeIntervalSinceReferenceDate;
}

// Moving through the queue goes through the playing player first; it is the
// responder that keeps the watch page.
static BOOL YTKACEQueueSendCommand(id command, NSString *videoID) {
    id view = YTKACEQueueCommandView;
    id sender = YTKACEQueueCommandSender;
    const BOOL sent =
        YTKACEQueueSendViaEvent(command, nil, YTKACEQueueResponder) ||
        YTKACEQueueSendViaRouter(command, view, sender) ||
        YTKACEQueueSendViaEvent(command, view, sender);
    if (sent) YTKACEQueueNoteSent(videoID);
    return sent;
}

static BOOL YTKACEQueuePlay(NSString *videoID) {
    return YTKACEQueueSendCommand(YTKACEQueueWatchCommand(videoID), videoID);
}

static BOOL YTKACEQueueReplayCurrent(void) {
    id player = YTKACEQueuePlayerViewController;
    if (player == nil) return NO;
    @try {
        if ([player respondsToSelector:@selector(replayWithSeekSource:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(player,
                @selector(replayWithSeekSource:), 0);
            return YES;
        }
        if ([player respondsToSelector:@selector(seekToTime:)]) {
            ((void (*)(id, SEL, double))objc_msgSend)(player,
                @selector(seekToTime:), 0.0);
            if ([player respondsToSelector:@selector(play)]) {
                ((void (*)(id, SEL))objc_msgSend)(player, @selector(play));
            }
            return YES;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return NO;
}

static BOOL YTKACEQueueOverlayLoop(void) {
    return YTKACEFeatureEnabled(YTKACELoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

// Repeat-one only replays when a video ends on its own; pressing Next or
// Previous still moves through the queue.
static BOOL YTKACEQueueStep(NSInteger offset, BOOL manual) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    NSArray *queue = [YTKACEQueue() copy];
    NSUInteger current = YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
    if (current == NSNotFound) {
        // A video opened outside the queue: carry on with what is queued.
        NSUInteger next = offset > 0 ? YTKACEQueueNextIndex() : NSNotFound;
        if (next == NSNotFound) return NO;
        return YTKACEQueuePlay(queue[next][@"videoId"]);
    }
    const long long loop = YTKACEQueueSavedLoopMode();
    NSInteger target = (NSInteger)current + offset;
    if (loop == 2 && !manual) return YTKACEQueueReplayCurrent();
    if (target < 0 || target >= (NSInteger)queue.count) {
        if (loop == 0 || queue.count == 0) return NO;
        target = target < 0 ? (NSInteger)queue.count - 1 : 0;
    }
    NSString *videoID = queue[(NSUInteger)target][@"videoId"];
    if (videoID.length == 0) return NO;
    return YTKACEQueuePlay(videoID);
}

static long long YTKACEQueueLoopMode(void) {
    return YTKACEQueueSavedLoopMode();
}

static void YTKACEQueueAdvance(NSString *finishing) {
    NSArray *queue = [YTKACEQueue() copy];
    NSUInteger current = YTKACEQueueIndexOfVideo(finishing);
    if (current == NSNotFound) {
        NSUInteger next = YTKACEQueueNextIndex();
        if (next != NSNotFound) YTKACEQueuePlay(queue[next][@"videoId"]);
        return;
    }
    const long long loop = YTKACEQueueLoopMode();
    if (loop == 2 || YTKACEQueueOverlayLoop()) {
        YTKACEQueueReplayCurrent();
        return;
    }
    if (current + 1 >= queue.count) {
        if (loop != 1 || queue.count == 0) {
            YTKACEQueueSetFinished(YES);
            return;
        }
        NSString *first = queue.firstObject[@"videoId"];
        if (first.length != 0) YTKACEQueuePlay(first);
        return;
    }
    NSString *videoID = queue[current + 1][@"videoId"];
    if (videoID.length == 0) return;
    YTKACEQueuePlay(videoID);
}

static id YTKACEQueueMessage(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(message));
}

static id YTKACEQueueFormatted(NSString *text) {
    Class cls = NSClassFromString(@"YTIFormattedString");
    if (cls == Nil || text.length == 0) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, @selector(formattedStringWithString:), text);
}

static id YTKACEQueueWatchCommand(NSString *videoID) {
    id endpoint = YTKACEQueueMessage(@"YTIWatchEndpoint");
    id command = YTKACEQueueMessage(@"YTICommand");
    if (endpoint == nil || command == nil) return nil;
    [endpoint setValue:videoID forKey:@"videoId"];
    [endpoint setValue:@0 forKey:@"startTimeSeconds"];
    [command setValue:endpoint forKey:@"watchEndpoint"];
    return command;
}

static NSString *YTKACEQueueTitleForVideo(NSString *videoID, NSString *stored) {
    if (stored.length != 0) return stored;
    id response = YTKACECachedPlayerResponse(videoID);
    if (response == nil) return nil;
    @try {
        id details = [response valueForKey:@"videoDetails"];
        id title = [details valueForKey:@"title"];
        if ([title isKindOfClass:NSString.class] && [title length] != 0) {
            return title;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return nil;
}

static void YTKACEQueueSafeSet(id object, id value, NSString *key) {
    if (object == nil) return;
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
        static NSMutableSet<NSString *> *reported;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ reported = [NSMutableSet set]; });
        NSString *name = [NSString stringWithFormat:@"%@.%@", NSStringFromClass([object class]), key];
        @synchronized (reported) {
            if ([reported containsObject:name]) return;
            [reported addObject:name];
        }
        YTKACEDebugLog(@"queue", @"skipped unsupported field %@", name);
    }
}

static id YTKACEQueuePanelItem(NSString *videoID, NSString *title,
                               NSString *author, NSString *length,
                               BOOL selected, NSUInteger index) {
    id renderer = YTKACEQueueMessage(@"YTIPlaylistPanelVideoRenderer");
    id wrapper = YTKACEQueueMessage(
        @"YTIPlaylistPanelRenderer_PlaylistPanelVideoSupportedRenderers");
    if (renderer == nil || wrapper == nil) return nil;
    YTKACEQueueSafeSet(renderer, videoID, @"videoId");
    YTKACEQueueSafeSet(renderer, videoID, @"playlistSetVideoId");
    id titleText = YTKACEQueueFormatted(
        YTKACEQueueTitleForVideo(videoID, title) ?: videoID);
    if (titleText != nil) YTKACEQueueSafeSet(renderer, titleText, @"title");
    id indexText = YTKACEQueueFormatted(
        [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)]);
    if (indexText != nil) YTKACEQueueSafeSet(renderer, indexText, @"indexText");
    id thumbnails = YTKACEQueueMessage(@"YTIThumbnailDetails");
    if (thumbnails != nil) {
        NSArray<NSArray *> *sizes = @[@[@"mqdefault", @320, @180],
                                      @[@"hqdefault", @480, @360]];
        for (NSArray *size in sizes) {
            id thumbnail = YTKACEQueueMessage(@"YTIThumbnailDetails_Thumbnail");
            if (thumbnail == nil) continue;
            YTKACEQueueSafeSet(thumbnail, [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/%@.jpg", videoID, size[0]], @"URL");
            YTKACEQueueSafeSet(thumbnail, size[1], @"width");
            YTKACEQueueSafeSet(thumbnail, size[2], @"height");
            [[thumbnails valueForKey:@"thumbnailsArray"] addObject:thumbnail];
        }
        YTKACEQueueSafeSet(renderer, thumbnails, @"thumbnail");
    }
    id style = YTKACEQueueMessage(@"YTIMainAppCompactRendererStyle");
    if (style != nil) {
        YTKACEQueueSafeSet(style, @2, @"value");
        YTKACEQueueSafeSet(renderer, style, @"mainAppStyle");
    }
    if (length.length != 0) {
        id overlay = YTKACEQueueMessage(@"YTIThumbnailOverlaySupportedRenderers");
        id timeStatus =
            YTKACEQueueMessage(@"YTIThumbnailOverlayTimeStatusRenderer");
        id overlayText = YTKACEQueueFormatted(length);
        if (overlay != nil && timeStatus != nil && overlayText != nil) {
            YTKACEQueueSafeSet(timeStatus, overlayText, @"text");
            YTKACEQueueSafeSet(overlay, timeStatus, @"thumbnailOverlayTimeStatusRenderer");
            [[renderer valueForKey:@"thumbnailOverlaysArray"]
                addObject:overlay];
        }
    }
    id menu = YTKACEQueueItemMenu(videoID);
    if (menu != nil) YTKACEQueueSafeSet(renderer, menu, @"menu");
    id removeCommand = YTKACEQueueSentinelCommand(@"remove", videoID);
    if (removeCommand != nil) {
        YTKACEQueueSafeSet(renderer, removeCommand, @"onSwipeLeftCommand");
        YTKACEQueueSafeSet(renderer, removeCommand, @"onItemRemovedCommand");
    }
    if (!selected) {
        id swipe = YTKACEQueueMessage(
            @"YTIPlaylistPanelVideoSwipeToRevealButtonSupportedRenderers");
        id button = YTKACEQueueMessage(@"YTIButtonRenderer");
        id swipeCommand = YTKACEQueueSentinelCommand(@"remove", videoID);
        if (swipe != nil && button != nil && swipeCommand != nil) {
            id label = YTKACEQueueFormatted(YTKACELocalized(@"Remove"));
            if (label != nil) YTKACEQueueSafeSet(button, label, @"text");
            YTKACEQueueSafeSet(button, swipeCommand, @"serviceEndpoint");
            YTKACEQueueSafeSet(swipe, button, @"buttonRenderer");
            [[renderer valueForKey:@"swipeButtonsArray"] addObject:swipe];
        }
    }
    id byline = YTKACEQueueFormatted(author);
    if (byline != nil) {
        YTKACEQueueSafeSet(renderer, byline, @"shortBylineText");
        YTKACEQueueSafeSet(renderer, byline, @"longBylineText");
    }
    id command = YTKACEQueueWatchCommand(videoID);
    if (command != nil) YTKACEQueueSafeSet(renderer, command, @"navigationEndpoint");
    YTKACEQueueSafeSet(renderer, @(selected), @"selected");
    YTKACEQueueSafeSet(wrapper, renderer, @"playlistPanelVideoRenderer");
    return wrapper;
}

static NSUInteger YTKACEQueueIndexOfVideo(NSString *videoID) {
    if (videoID.length == 0) return NSNotFound;
    NSArray *queue = YTKACEQueue();
    for (NSUInteger index = 0; index < queue.count; index++) {
        if ([queue[index][@"videoId"] isEqualToString:videoID]) return index;
    }
    return NSNotFound;
}

static NSString *YTKACEQueueCurrentVideoID(void) {
    if (YTKACEQueueCurrentOverride.length != 0) {
        return YTKACEQueueCurrentOverride;
    }
    id player = YTKACEQueuePlayerViewController;
    id playerValue =
        YTKACEQueueValue(player, @[@"currentVideoID", @"contentVideoID"]);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const NSTimeInterval age =
        NSDate.timeIntervalSinceReferenceDate - YTKACEQueueActiveVideoTime;
    const BOOL preferOwn =
        YTKACEQueueActiveVideo.length != 0 && age < 4.0;
    if (preferOwn) [candidates addObject:YTKACEQueueActiveVideo];
    if ([playerValue isKindOfClass:NSString.class] &&
        [playerValue length] != 0) {
        [candidates addObject:playerValue];
    }
    if (!preferOwn && YTKACEQueueActiveVideo.length != 0) {
        [candidates addObject:YTKACEQueueActiveVideo];
    }
    NSString *last = YTKACELastVideoID();
    if (last.length != 0) [candidates addObject:last];
    for (NSString *candidate in candidates) {
        if (YTKACEQueueIndexOfVideo(candidate) != NSNotFound) return candidate;
    }
    return candidates.firstObject;
}

static NSUInteger YTKACEQueueCurrentIndex(void) {
    return YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
}

static BOOL YTKACEQueueViewOnScreen(id candidate) {
    if (![candidate isKindOfClass:UIViewController.class]) return NO;
    UIViewController *controller = candidate;
    return controller.isViewLoaded && controller.view.window != nil;
}

static NSString *YTKACEQueueDescribeHost(id candidate) {
    if (candidate == nil) return @"nil";
    if (![candidate isKindOfClass:UIViewController.class]) {
        return [NSString stringWithFormat:@"%@(not a VC)", [candidate class]];
    }
    UIViewController *controller = candidate;
    return [NSString stringWithFormat:@"%@ loaded=%d window=%d",
        [candidate class], controller.isViewLoaded,
        controller.isViewLoaded && controller.view.window != nil];
}

// The miniplayer takes the watch view out of the window but keeps the watch
// player in it, so a video is open while either is on screen. Only the watch
// player counts: feed previews run players of their own.
static BOOL YTKACEQueueVideoIsOpen(void) {
    return YTKACEQueueViewOnScreen(YTKACEQueueWatchViewController) ||
        YTKACEQueueViewOnScreen(YTKACEQueuePlayerViewController);
}

static NSString *YTKACEQueueOpenVideoID(void) {
    if (!YTKACEQueueVideoIsOpen()) return nil;
    id live = YTKACEQueueValue(YTKACEQueuePlayerViewController,
                               @[@"currentVideoID", @"contentVideoID"]);
    if ([live isKindOfClass:NSString.class] && [live length] != 0) return live;
    return YTKACEQueueCurrentVideoID();
}

// Index where "play next" inserts: right after the open video when it is in
// the queue, otherwise right after the last item that played.
static NSUInteger YTKACEQueueUpcomingIndex(NSString *playing) {
    NSUInteger index = YTKACEQueueIndexOfVideo(playing);
    if (index == NSNotFound) index = YTKACEQueueIndexOfVideo(YTKACEQueueCursor());
    return index == NSNotFound ? 0 : index + 1;
}

static void YTKACEQueueRemoveAt(NSUInteger index) {
    NSMutableArray *queue = YTKACEQueue();
    if (index >= queue.count) return;
    if ([queue[index][@"videoId"] isEqualToString:YTKACEQueueCursor()]) {
        YTKACEQueueSetCursor(index > 0 ? queue[index - 1][@"videoId"] : nil);
    }
    [queue removeObjectAtIndex:index];
}

// Position the queue continues from: the open video when it is queued,
// otherwise the last queue item that played.
static NSUInteger YTKACEQueueAnchorIndex(void) {
    NSUInteger current = YTKACEQueueCurrentIndex();
    if (current != NSNotFound) return current;
    return YTKACEQueueIndexOfVideo(YTKACEQueueCursor());
}

// The queue item that plays after the current video, or NSNotFound.
static NSUInteger YTKACEQueueNextIndex(void) {
    NSUInteger anchor = YTKACEQueueAnchorIndex();
    NSUInteger next = anchor == NSNotFound ? 0 : anchor + 1;
    return next < YTKACEQueue().count ? next : NSNotFound;
}

// Called when a video starts. A queued video moves the cursor. A video
// opened from elsewhere while the queue is running goes in front of the video
// that was playing and becomes the current item, like YouTube's own queue.
// Once the last queued video has played to the end the queue is finished,
// so the next video starts fresh and the queue is cleared.
// Returns YES when the queue changed.
static BOOL YTKACEQueueNoteStarted(NSString *videoID) {
    NSMutableArray *queue = YTKACEQueue();
    if (videoID.length == 0 || queue.count == 0) return NO;
    if (YTKACEQueueIndexOfVideo(videoID) != NSNotFound) {
        const BOOL moved = ![videoID isEqualToString:YTKACEQueueCursor()];
        YTKACEQueueSetCursor(videoID);
        YTKACEQueueSetFinished(NO);
        return moved;
    }
    NSUInteger cursor = YTKACEQueueIndexOfVideo(YTKACEQueueCursor());
    if (cursor != NSNotFound && cursor + 1 >= queue.count &&
        YTKACEQueueFinished()) {
        YTKACEDebugLog(@"queue", @"finished queue cleared on start of %@", videoID);
        [queue removeAllObjects];
        YTKACEQueueSave();
        return YES;
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"videoId"] = videoID;
    [queue insertObject:entry atIndex:cursor == NSNotFound ? 0 : cursor];
    YTKACEQueueSetCursor(videoID);
    YTKACEQueueSave();
    YTKACEQueueFetchTitle(videoID);
    return YES;
}

static NSString *YTKACEQueuePausePendingID;
static NSTimeInterval YTKACEQueuePauseDeadline;

// The first video of a queue built while idle opens paused. The watch player
// is paused as soon as it takes the video and again on its first time tick,
// which is when YouTube may have started it; only the watch player counts.
static void YTKACEQueuePauseIfPending(id player, id videoID, BOOL final) {
    if (YTKACEQueuePausePendingID.length == 0 ||
        ![videoID isEqual:YTKACEQueuePausePendingID] ||
        player != YTKACEQueuePlayerViewController) {
        return;
    }
    if (final) YTKACEQueuePausePendingID = nil;
    YTKACEDebugLog(@"queue", @"pausing %@ final=%d player=[%@]", videoID,
                      final, YTKACEQueueDescribeHost(player));
    if (NSDate.timeIntervalSinceReferenceDate < YTKACEQueuePauseDeadline &&
        [player respondsToSelector:@selector(pause)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(player, @selector(pause));
        } @catch (__unused NSException *exception) {
        }
    }
}

static void YTKACEQueueSetMiniplayerMode(id endpoint) {
    id config = YTKACEQueueMessage(@"YTIWatchEndpointMainAppConfig");
    if (endpoint == nil || config == nil) return;
    @try {
        SEL descriptorSel = NSSelectorFromString(@"descriptor");
        SEL fieldSel = NSSelectorFromString(@"fieldWithName:");
        SEL enumSel = NSSelectorFromString(@"enumDescriptor");
        SEL nameSel = NSSelectorFromString(@"enumNameForValue:");
        if (![[config class] respondsToSelector:descriptorSel]) return;
        id descriptor = ((id (*)(id, SEL))objc_msgSend)([config class],
                                                        descriptorSel);
        if (![descriptor respondsToSelector:fieldSel]) return;
        id field = ((id (*)(id, SEL, id))objc_msgSend)(descriptor, fieldSel,
            @"suggestedInitialPlayerMode");
        if (![field respondsToSelector:enumSel]) return;
        id enumDescriptor = ((id (*)(id, SEL))objc_msgSend)(field, enumSel);
        if (![enumDescriptor respondsToSelector:nameSel]) return;
        for (int32_t value = 0; value < 16; value++) {
            NSString *name = ((id (*)(id, SEL, int32_t))objc_msgSend)(
                enumDescriptor, nameSel, value);
            if (![name isKindOfClass:NSString.class]) continue;
            if ([name rangeOfString:@"Miniplayer"
                            options:NSCaseInsensitiveSearch].location ==
                NSNotFound) {
                continue;
            }
            [config setValue:@(value) forKey:@"suggestedInitialPlayerMode"];
            [endpoint setValue:config forKey:@"watchEndpointMainAppConfig"];
            return;
        }
    } @catch (__unused NSException *exception) {
    }
}

static BOOL YTKACEQueueOpenVia(id command, id view, id sender) {
    return YTKACEQueueSendViaRouter(command, view, sender) ||
        YTKACEQueueSendViaEvent(command, view, sender) ||
        YTKACEQueueSendViaEvent(command, nil, YTKACEQueueResponder);
}

// Opens the first video of a new queue in the miniplayer and pauses it as
// soon as it loads, so the queue is ready without anything playing. It goes
// through the tap that queued it (the last player may be gone) once the menu
// has closed, and falls back to the regular player if no miniplayer appears.
static BOOL YTKACEQueueOpenMinimized(NSString *videoID) {
    id view = YTKACEQueueCommandView;
    id sender = YTKACEQueueCommandSender;
    YTKACEQueuePausePendingID = videoID;
    YTKACEQueuePauseDeadline = NSDate.timeIntervalSinceReferenceDate + 20.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id command = YTKACEQueueWatchCommand(videoID);
        @try {
            YTKACEQueueSetMiniplayerMode([command valueForKey:@"watchEndpoint"]);
        } @catch (__unused NSException *exception) {
        }
        if (YTKACEQueueOpenVia(command, view, sender)) {
            YTKACEQueueNoteSent(videoID);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // A player that already has the video, even one still loading,
            // must not be sent it again: that reopens the watch page and
            // restarts it.
            id live = YTKACEQueueValue(YTKACEQueuePlayerViewController,
                                       @[@"currentVideoID", @"contentVideoID"]);
            if (![YTKACEQueuePausePendingID isEqualToString:videoID] ||
                YTKACEQueueVideoIsOpen() || [live isEqual:videoID] ||
                [YTKACELastVideoID() isEqualToString:videoID]) {
                return;
            }
            YTKACEDebugLog(@"queue", @"retrying open of %@", videoID);
            YTKACEQueuePauseDeadline =
                NSDate.timeIntervalSinceReferenceDate + 20.0;
            if (YTKACEQueueOpenVia(YTKACEQueueWatchCommand(videoID), view,
                                   sender)) {
                YTKACEQueueNoteSent(videoID);
            }
        });
    });
    return YES;
}

static NSArray<NSString *> *YTKACEQueueControllerIDs(id controller) {
    NSArray *items = nil;
    @try {
        items = [controller valueForKey:@"playbackQueueItems"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id item in items) {
        NSString *videoID = nil;
        @try {
            videoID = [[item valueForKey:@"videoRenderer"] valueForKey:@"videoId"];
        } @catch (__unused NSException *exception) {
            videoID = nil;
        }
        if ([videoID isKindOfClass:NSString.class] && videoID.length != 0) {
            [ids addObject:videoID];
        }
    }
    return ids;
}

// Drops anything YouTube's own queue controller picked up that the user did
// not queue, so the panel mirrors the local queue exactly.
static void YTKACEQueuePruneController(void) {
    id controller = YTKACEQueueControllerInstance;
    if (![controller respondsToSelector:@selector(removeVideoID:)]) return;
    NSString *playing = YTKACEQueueOpenVideoID();
    YTKACEQueueSyncSuppressed = YES;
    for (NSString *videoID in YTKACEQueueControllerIDs(controller)) {
        if (YTKACEQueueIndexOfVideo(videoID) != NSNotFound) continue;
        if ([videoID isEqualToString:playing]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(controller,
                @selector(removeVideoID:), videoID);
        } @catch (__unused NSException *exception) {
        }
    }
    YTKACEQueueSyncSuppressed = NO;
}

static id YTKACEQueuePanelRenderer(void) {
    NSUInteger currentIndex = YTKACEQueueCurrentIndex();
    NSArray<NSDictionary *> *queue = [YTKACEQueue() copy];
    if (queue.count == 0) return nil;
    id panel = YTKACEQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return nil;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    if (contents == nil) return nil;
    for (NSUInteger index = 0; index < queue.count; index++) {
        NSDictionary *entry = queue[index];
        NSString *videoID = entry[@"videoId"];
        if (videoID.length == 0) continue;
        if (entry[@"title"] == nil || entry[@"length"] == nil) {
            YTKACEQueueFetchTitle(videoID);
        }
        id item = YTKACEQueuePanelItem(videoID, entry[@"title"],
                                       entry[@"author"], entry[@"length"],
                                       index == currentIndex, index);
        if (item == nil) continue;
        [contents addObject:item];
    }
    if (contents.count == 0) return nil;
    [panel setValue:@"YTKACEQueue" forKey:@"playlistId"];
    [panel setValue:YTKACELocalized(@"Queue") forKey:@"title"];
    id title = YTKACEQueueFormatted(YTKACELocalized(@"Queue"));
    if (title != nil) [panel setValue:title forKey:@"titleText"];
    [panel setValue:@(contents.count) forKey:@"totalVideos"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"currentIndex"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"localCurrentIndex"];
    [panel setValue:@YES forKey:@"isEditable"];
    id reorder = YTKACEQueueSentinelCommand(@"reorder", @"");
    if (reorder != nil) [panel setValue:reorder forKey:@"onReorderEndpoint"];
    return panel;
}

static void YTKACEQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex) {
    id controller = YTKACEQueueControllerInstance;
    if (controller == nil || entry[@"videoId"] == nil) return;
    SEL selector = @selector(addItemsFromPlaylistPanel:response:atIndex:
                             ignoreSelectedProperty:notifyObservers:);
    if (![controller respondsToSelector:selector]) return;
    id panel = YTKACEQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    id item = YTKACEQueuePanelItem(entry[@"videoId"], entry[@"title"],
                                   entry[@"author"], entry[@"length"], NO,
                                   insertIndex);
    if (contents == nil || item == nil) return;
    [contents addObject:item];
    [panel setValue:@"YTKACEQueue" forKey:@"playlistId"];
    [panel setValue:@1 forKey:@"totalVideos"];
    @try {
        ((void (*)(id, SEL, id, id, unsigned long long, BOOL, BOOL))objc_msgSend)(
            controller, selector, panel, YTKACELastWatchNextResponse,
            (unsigned long long)insertIndex, YES, YES);
    } @catch (NSException *exception) {
        return;
    }
}

static void YTKACEQueueRebuildWatchPage(void) {
    id watch = YTKACEQueueWatchViewController;
    id response = YTKACELastWatchNextResponse;
    if (watch == nil || response == nil) return;
    if (YTKACEQueuePanelInjected) {
        YTKACEQueueRefreshPanel();
        return;
    }
    if (![watch respondsToSelector:@selector(updateWithWatchNextResponse:)]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(watch,
                @selector(updateWithWatchNextResponse:), response);
        } @catch (NSException *exception) {
            return;
        }
    });
}

static void YTKACEQueueRefreshPanel(void) {
    id controller = YTKACEQueuePanelController;
    if (controller == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id panel = YTKACEQueuePanelRenderer();
        if (panel == nil) return;
        @try {
            [controller setValue:panel forKey:@"playlistPanelRenderer"];
            if ([controller respondsToSelector:
                    @selector(refreshPlaylistCollectionViewController)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(refreshPlaylistCollectionViewController));
            }
            if ([controller respondsToSelector:
                    @selector(updateViewForCurrentVideo)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(updateViewForCurrentVideo));
            }
        } @catch (NSException *exception) {
            return;
        }
        YTKACEQueueRestoreLoopMode(controller);
        id watchController = YTKACEQueueWatchViewController;
        if ([watchController respondsToSelector:
                @selector(showPlaylistMiniBarIfNeeded)]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(watchController,
                    @selector(showPlaylistMiniBarIfNeeded));
            } @catch (__unused NSException *exception) {
            }
        }
    });
}

static id YTKACEQueuePanelParse(id receiver, SEL selector, id response) {
    id original = nil;
    if (OriginalPanelParse != NULL) {
        original = ((id (*)(id, SEL, id))OriginalPanelParse)(
            receiver, selector, response);
    }
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return original;
    if (YTKACEQueue().count == 0) return original;
    if (original != nil) {
        return original;
    }
    id panel = YTKACEQueuePanelRenderer();
    return panel ?: original;
}

static id YTKACEQueueResponsePanel(id receiver, SEL selector) {
    id original = NULL;
    if (OriginalResponsePanel != NULL) {
        original = ((id (*)(id, SEL))OriginalResponsePanel)(receiver, selector);
    }
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return original;
    if (YTKACEQueue().count == 0) return original;
    if (original != nil) return original;
    id panel = YTKACEQueuePanelRenderer();
    return panel ?: original;
}








static NSString *YTKACEQueuePanelField(id wrapper) {
    static NSString *cached;
    if (cached != nil) return cached;
    NSString *found = nil;
    SEL descriptorSel = NSSelectorFromString(@"descriptor");
    id descriptor = [[wrapper class] respondsToSelector:descriptorSel]
        ? ((id (*)(id, SEL))objc_msgSend)([wrapper class], descriptorSel) : nil;
    NSArray *fields = [descriptor respondsToSelector:NSSelectorFromString(@"fields")]
        ? [descriptor valueForKey:@"fields"] : nil;
    Class panelClass = NSClassFromString(@"YTIPlaylistPanelRenderer");
    for (id field in fields) {
        NSString *name = [field valueForKey:@"name"];
        if (![name isKindOfClass:NSString.class]) continue;
        SEL msgClassSel = NSSelectorFromString(@"msgClass");
        Class type = [field respondsToSelector:msgClassSel]
            ? ((Class (*)(id, SEL))objc_msgSend)(field, msgClassSel) : Nil;
        if (found == nil && panelClass != Nil && type == panelClass) found = name;
    }
    cached = found ?: @"playlist";
    return cached;
}

// The video a watch-next response belongs to, but only once the player is
// actually on it, so prefetched responses never touch the queue.
static NSString *YTKACEQueueStartedVideoID(id response) {
    id videoID = nil;
    @try {
        videoID = [response valueForKeyPath:
            @"currentVideoEndpoint.watchEndpoint.videoId"];
    } @catch (__unused NSException *exception) {
        videoID = nil;
    }
    if (![videoID isKindOfClass:NSString.class] || [videoID length] == 0) {
        return YTKACEQueueCurrentOverride;
    }
    id live = YTKACEQueueValue(YTKACEQueuePlayerViewController,
                               @[@"currentVideoID", @"contentVideoID"]);
    if ([videoID isEqual:YTKACEQueueCurrentOverride] || [videoID isEqual:live] ||
        [videoID isEqual:YTKACEQueueActiveVideo]) {
        return videoID;
    }
    return nil;
}

static void YTKACEQueueInjectPanel(id response) {
    YTKACELastWatchNextResponse = response;
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return;
    if (YTKACEQueue().count == 0) return;
    @try {
        id contents = [response valueForKey:@"contents"];
        id single = [contents valueForKey:@"singleColumnWatchNextResults"];
        if (single == nil) return;
        id existing = [single valueForKey:@"playlist"];
        NSString *field = existing != nil ? YTKACEQueuePanelField(existing) : @"playlist";
        id current = existing != nil ? [existing valueForKey:field] : nil;
        id owner = current != nil ? YTKACEQueueValue(current, @[@"playlistId"]) : nil;
        if ([owner isKindOfClass:NSString.class] && [owner length] != 0) {
            if (![owner isEqual:@"YTKACEQueue"]) {
                    return;
            }
        }
        YTKACEQueueNoteStarted(YTKACEQueueStartedVideoID(response));
        id panel = YTKACEQueuePanelRenderer();
        if (panel == nil) return;
        id wrapper = YTKACEQueueMessage(
            @"YTISingleColumnWatchNextResultsRenderer_"
            @"SingleColumnWatchNextPlaylistSupportedRenderers");
        if (wrapper == nil) return;
        [wrapper setValue:panel forKey:YTKACEQueuePanelField(wrapper)];
        [single setValue:wrapper forKey:@"playlist"];
        YTKACEQueuePanelInjected = YES;
    } @catch (__unused NSException *exception) {
    }
}

static void YTKACEQueueSetWatchNext(id receiver, SEL selector, id response) {
    YTKACEQueuePlayerViewController = receiver;
    YTKACEDebugLog(@"queue", @"setWatchNext player=[%@] video=%@",
          YTKACEQueueDescribeHost(receiver),
          YTKACEQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]));
    id fresh = YTKACEQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    YTKACEQueueCurrentOverride =
        [fresh isKindOfClass:NSString.class] ? fresh : nil;
    if (YTKACEQueueCurrentOverride.length != 0) {
        YTKACEQueueActiveVideo = YTKACEQueueCurrentOverride;
        YTKACEQueueActiveVideoTime = 0;
    }
    YTKACEQueuePauseIfPending(receiver, YTKACEQueueCurrentOverride, NO);
    YTKACEQueueInjectPanel(response);
    YTKACEQueueCurrentOverride = nil;
    if (OriginalSetWatchNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalSetWatchNext)(receiver, selector, response);
}

static void YTKACEQueuePrepareWatchNext(id receiver, SEL selector, id response) {
    YTKACEQueueInjectPanel(response);
    if (OriginalPrepareWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalPrepareWatchNext)(
            receiver, selector, response);
    }
}




static void YTKACEQueueViewUpdateWatchNext(id receiver, SEL selector,
                                           id response) {
    YTKACEQueueWatchViewController = receiver;
    YTKACEDebugLog(@"queue", @"viewUpdateWatchNext watch=[%@]",
          YTKACEQueueDescribeHost(receiver));
    YTKACEQueuePanelInjected = NO;
    YTKACEQueueInjectPanel(response);
    if (OriginalViewUpdateWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalViewUpdateWatchNext)(
            receiver, selector, response);
    }
}


static void YTKACEQueueEnableEditing(id panelController, id queueController) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return;
    NSArray<NSString *> *flags = @[@"_enableSwipeToRemove",
                                   @"_enableQueueEditBuffer",
                                   @"_queuePhase4Enabled"];
    for (NSString *flag in flags) {
        @try {
            [panelController setValue:@YES forKey:flag];
        } @catch (__unused NSException *exception) {
        }
    }
    @try {
        [queueController setValue:@YES forKey:@"userModifiedQueue"];
    } @catch (__unused NSException *exception) {
    }
}

static id YTKACEQueuePanelInit(id receiver, SEL selector, id account,
                               id responder) {
    id result = NULL;
    if (OriginalPanelInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalPanelInit)(
            receiver, selector, account, responder);
    }
    YTKACEQueuePanelController = result;
    return result;
}

static id YTKACEQueuePanelInitQueue(id receiver, SEL selector, id account,
                                    id responder, id controller) {
    id result = NULL;
    if (OriginalPanelInitQueue != NULL) {
        result = ((id (*)(id, SEL, id, id, id))OriginalPanelInitQueue)(
            receiver, selector, account, responder, controller);
    }
    YTKACEQueuePanelController = result;
    YTKACEQueueControllerInstance = controller;
    YTKACEQueueEnableEditing(result, controller);
    YTKACEQueueRestoreLoopMode(result);
    return result;
}

static id YTKACEQueueControllerInit(id receiver, SEL selector, id account,
                                    id responder) {
    id result = NULL;
    if (OriginalQueueControllerInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalQueueControllerInit)(
            receiver, selector, account, responder);
    }
    YTKACEQueueControllerInstance = result;
    return result;
}

static BOOL YTKACEQueueIsActive(void) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    return YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID()) != NSNotFound;
}

static void YTKACEQueueDidPressNext(id receiver, SEL selector, id sender) {
    if (YTKACEQueueStep(1, YES)) {
        return;
    }
    if (YTKACEQueueIsActive()) {
        return;
    }
    if (OriginalDidPressNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressNext)(receiver, selector, sender);
}

static void YTKACEQueueDidPressPrevious(id receiver, SEL selector, id sender) {
    if (YTKACEQueueStep(-1, YES)) {
        return;
    }
    if (YTKACEQueueIsActive()) {
        return;
    }
    if (OriginalDidPressPrevious == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressPrevious)(receiver, selector,
                                                      sender);
}

static void YTKACEQueueAutonavPlayNext(id receiver, SEL selector) {
    // Returning to the live edge of a stream can report it as ended; a live
    // stream never hands over to the queue.
    id player = YTKACEQueuePlayerViewController;
    id playing = YTKACEQueueValue(player, @[@"currentVideoID", @"contentVideoID"]);
    NSString *current = [playing isKindOfClass:NSString.class] ? playing : YTKACEQueueActiveVideo;
    const BOOL live = YTKACEQueueVideoIsLive(current, player);
    if (live) {
        if (OriginalAutonavPlayNext != NULL) {
            ((void (*)(id, SEL))OriginalAutonavPlayNext)(receiver, selector);
        }
        return;
    }
    BOOL active = YTKACEQueueIsActive();
    if (active && YTKACEQueueOverlayLoop()) {
        if (YTKACEQueueReplayCurrent()) return;
    }
    if (YTKACEQueueStep(1, NO)) {
        return;
    }
    if (active) {
        return;
    }
    if (OriginalAutonavPlayNext == NULL) return;
    ((void (*)(id, SEL))OriginalAutonavPlayNext)(receiver, selector);
}


// Applies a move or removal made in YouTube's queue controller to the local
// queue. Only videos the controller dropped are removed, and only videos it
// knows about are reordered; anything else (e.g. queued while idle) stays put.
static void YTKACEQueueSyncFromController(id controller,
                                          NSArray<NSString *> *before) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey) || YTKACEQueueSyncSuppressed) {
        return;
    }
    NSArray<NSString *> *after = YTKACEQueueControllerIDs(controller);
    if (after == nil) return;
    NSMutableArray *queue = YTKACEQueue();
    __block BOOL changed = NO;
    for (NSString *videoID in before) {
        if ([after containsObject:videoID]) continue;
        NSUInteger index = YTKACEQueueIndexOfVideo(videoID);
        if (index == NSNotFound) continue;
        YTKACEQueueRemoveAt(index);
        changed = YES;
    }
    NSMutableIndexSet *slots = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < queue.count; index++) {
        if ([after containsObject:queue[index][@"videoId"]]) [slots addIndex:index];
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *videoID in after) {
        NSUInteger index = YTKACEQueueIndexOfVideo(videoID);
        if (index == NSNotFound) continue;
        if ([ordered indexOfObjectIdenticalTo:queue[index]] != NSNotFound) continue;
        [ordered addObject:queue[index]];
    }
    if (ordered.count == slots.count) {
        NSArray *snapshot = [queue copy];
        __block NSUInteger next = 0;
        [slots enumerateIndexesUsingBlock:^(NSUInteger slot, __unused BOOL *stop) {
            if (snapshot[slot] != ordered[next]) changed = YES;
            queue[slot] = ordered[next++];
        }];
    }
    if (changed) YTKACEQueueSave();
}

static void YTKACEQueueMoveItem(id receiver, SEL selector, id from, id to,
                                BOOL triggered) {
    NSArray *before = YTKACEQueueControllerIDs(receiver);
    if (OriginalMoveItem != NULL) {
        ((void (*)(id, SEL, id, id, BOOL))OriginalMoveItem)(
            receiver, selector, from, to, triggered);
    }
    YTKACEQueueSyncFromController(receiver, before);
}

static void YTKACEQueueRemoveItem(id receiver, SEL selector, id path,
                                  BOOL triggered) {
    NSArray *before = YTKACEQueueControllerIDs(receiver);
    if (OriginalRemoveItem != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalRemoveItem)(
            receiver, selector, path, triggered);
    }
    YTKACEQueueSyncFromController(receiver, before);
}

static void YTKACEQueueRemoveIndex(id receiver, SEL selector,
                                   unsigned long long index) {
    NSArray *before = YTKACEQueueControllerIDs(receiver);
    if (OriginalRemoveIndex != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalRemoveIndex)(
            receiver, selector, index);
    }
    YTKACEQueueSyncFromController(receiver, before);
}

static void YTKACEQueueClearQueue(id receiver, SEL selector) {
    // YouTube clears its own controller internally (e.g. when the player
    // closes); the local queue is only cleared by the user's Clear action.
    if (OriginalClearQueue != NULL) {
        ((void (*)(id, SEL))OriginalClearQueue)(receiver, selector);
    }
}

static BOOL YTKACEQueueCanMoveItem(id receiver, SEL selector, id from, id to) {
    if (YTKACEQueueIsActive()) return YES;
    if (OriginalCanMoveItem == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id))OriginalCanMoveItem)(receiver, selector,
                                                            from, to);
}

static NSDictionary *YTKACEQueueUpcomingEntry(void) {
    NSArray *queue = [YTKACEQueue() copy];
    NSUInteger current = YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
    if (current == NSNotFound || current + 1 >= queue.count) return nil;
    return queue[current + 1];
}

static id YTKACEQueueNextVideoTitle(id receiver, SEL selector) {
    NSDictionary *entry = YTKACEQueueIsActive() ? YTKACEQueueUpcomingEntry()
                                                : nil;
    NSString *title = entry[@"title"];
    if (title.length != 0) return title;
    if (entry != nil) return entry[@"videoId"];
    if (OriginalNextVideoTitle == NULL) return nil;
    return ((id (*)(id, SEL))OriginalNextVideoTitle)(receiver, selector);
}

static long long YTKACEQueueNextVideoIndex(id receiver, SEL selector) {
    if (YTKACEQueueIsActive()) {
        NSUInteger current =
            YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
        if (current != NSNotFound && current + 1 < YTKACEQueue().count) {
            return (long long)(current + 1);
        }
    }
    if (OriginalNextVideoIndex == NULL) return -1;
    return ((long long (*)(id, SEL))OriginalNextVideoIndex)(receiver, selector);
}

static void YTKACEQueueReplaceAutoplay(id receiver, SEL selector, id response) {
    if (YTKACEQueueIsActive()) {
        return;
    }
    if (OriginalReplaceAutoplay == NULL) return;
    ((void (*)(id, SEL, id))OriginalReplaceAutoplay)(receiver, selector,
                                                     response);
}

static void YTKACEQueueCellControllerSetCell(id receiver, SEL selector,
                                             id cell) {
    if (YTKACEQueueIsActive()) {
        for (NSString *flag in @[@"_enableSwipeToRemove",
                                 @"_enableSwipeToRemoveInPlaylistWatchEp2"]) {
            @try {
                [receiver setValue:@YES forKey:flag];
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (OriginalCellControllerSetCell == NULL) return;
    ((void (*)(id, SEL, id))OriginalCellControllerSetCell)(receiver, selector,
                                                            cell);
}

static double YTKACEQueueAlphaForIndex(id receiver, SEL selector,
                                       unsigned long long index) {
    double value = 1.0;
    if (OriginalAlphaForIndex != NULL) {
        value = ((double (*)(id, SEL, unsigned long long))OriginalAlphaForIndex)(
            receiver, selector, index);
    }
    if (YTKACEQueueIsActive()) {
        if (value < 1.0) {
        }
        return 1.0;
    }
    return value;
}




static void YTKACEQueueClearSlideBackground(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 3) return;
    if ([NSStringFromClass([view class]) isEqualToString:
            @"YTSlideForActionsView"]) {
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
    }
    for (UIView *child in view.subviews) {
        YTKACEQueueClearSlideBackground(child, depth + 1);
    }
}

static void YTKACEQueueSlideLayoutSubviews(id receiver, SEL selector) {
    if (OriginalSlideLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalSlideLayoutSubviews)(receiver, selector);
    }
    if (!YTKACEQueueIsActive()) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *view = receiver;
    UIView *content = nil;
    @try {
        id value = [receiver valueForKey:@"contentView"];
        content = [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        content = nil;
    }
    const BOOL sliding = content != nil &&
        fabs(CGRectGetMinX(content.frame)) > 0.5;
    view.backgroundColor = sliding
        ? [UIColor colorWithWhite:0.62 alpha:1.0]
        : UIColor.clearColor;
}

static void YTKACEQueueUpdateCellForIndex(id receiver, SEL selector, id cell,
                                          __unused long long index) {
    if (OriginalUpdateCellForIndex != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalUpdateCellForIndex)(
            receiver, selector, cell, index);
    }
    if (!YTKACEQueueIsActive()) return;
    if ([cell isKindOfClass:UIView.class]) {
        YTKACEQueueClearSlideBackground(cell, 0);
    }
}

static void YTKACEQueueCellPrepareForReuse(id receiver, SEL selector) {
    @try {
        id button = [receiver valueForKey:@"_swipeToRevealButton"];
        if ([button isKindOfClass:UIView.class]) {
            UIView *view = button;
            view.hidden = YES;
            view.frame = CGRectZero;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        [receiver setValue:@NO forKey:@"_isRemovingWithAnimation"];
    } @catch (__unused NSException *exception) {
    }
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = receiver;
        YTKACEQueueClearSlideBackground(cell, 0);
        cell.alpha = 1.0;
        cell.transform = CGAffineTransformIdentity;
        for (UIView *subview in cell.subviews) {
            subview.alpha = 1.0;
            subview.transform = CGAffineTransformIdentity;
        }
    }
    if (OriginalCellPrepareForReuse == NULL) return;
    ((void (*)(id, SEL))OriginalCellPrepareForReuse)(receiver, selector);
}

static void YTKACEQueueSetCanReorder(id receiver, SEL selector, BOOL value) {
    if (OriginalSetCanReorder == NULL) return;
    ((void (*)(id, SEL, BOOL))OriginalSetCanReorder)(receiver, selector,
        YTKACEQueueIsActive() ? YES : value);
}

static BOOL YTKACEQueueAllowsReordering(id receiver, SEL selector,
                                        CGPoint point) {
    if (YTKACEQueueIsActive()) return YES;
    if (OriginalAllowsReordering == NULL) return NO;
    return ((BOOL (*)(id, SEL, CGPoint))OriginalAllowsReordering)(
        receiver, selector, point);
}

static void YTKACEQueueSetVideoCountText(id receiver, SEL selector, id text,
                                         BOOL countHidden, BOOL shuffleEnabled,
                                         BOOL shuffleSelected,
                                         BOOL loopEnabled, BOOL loopSelected,
                                         BOOL saveEnabled, BOOL shareEnabled,
                                         BOOL saveSelected, BOOL actionEnabled,
                                         long long loopMode, id renderer,
                                         BOOL useRendererSaveIcons,
                                         BOOL headerHidden) {
    if (OriginalSetVideoCountText == NULL) return;
    if (YTKACEQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = YTKACEQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL, BOOL))OriginalSetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons, headerHidden);
}

static IMP OriginalLegacySetVideoCountText;
static IMP OriginalShouldShowPlaylist;

static void YTKACEQueueLegacySetVideoCountText(id receiver, SEL selector, id text,
                                               BOOL countHidden, BOOL shuffleEnabled,
                                               BOOL shuffleSelected,
                                               BOOL loopEnabled, BOOL loopSelected,
                                               BOOL saveEnabled, BOOL shareEnabled,
                                               BOOL saveSelected, BOOL actionEnabled,
                                               long long loopMode, id renderer,
                                               BOOL useRendererSaveIcons) {
    if (OriginalLegacySetVideoCountText == NULL) return;
    if (YTKACEQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = YTKACEQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL))OriginalLegacySetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons);
}

static BOOL YTKACEQueueShouldShowPlaylist(id receiver, SEL selector) {
    if (YTKACEQueuePanelController != receiver) {
        YTKACEQueuePanelController = receiver;
    }
    if (YTKACEQueueIsActive()) return YES;
    if (OriginalShouldShowPlaylist == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalShouldShowPlaylist)(receiver, selector);
}

static void YTKACEQueueDidTapShuffle(id receiver, SEL selector) {
    if (!YTKACEQueueIsActive()) {
        if (OriginalDidTapShuffle == NULL) return;
        ((void (*)(id, SEL))OriginalDidTapShuffle)(receiver, selector);
        return;
    }
    NSMutableArray *queue = YTKACEQueue();
    NSString *currentID = YTKACEQueueCurrentVideoID();
    NSUInteger current = YTKACEQueueIndexOfVideo(currentID);
    if (current == NSNotFound || queue.count < 3) return;
    NSDictionary *entry = queue[current];
    [queue removeObjectAtIndex:current];
    for (NSUInteger index = queue.count; index > 1; index--) {
        const uint32_t pick = arc4random_uniform((uint32_t)index);
        [queue exchangeObjectAtIndex:index - 1 withObjectAtIndex:pick];
    }
    [queue insertObject:entry atIndex:0];
    YTKACEQueueSave();
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *item in queue) {
        [order addObject:item[@"videoId"] ?: @"?"];
    }
    YTKACEQueueRebuildWatchPage();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTKACEQueueRefreshPanel();
        YTKACEQueueApplyLoopMode(YTKACEQueuePanelController,
                                 YTKACEQueueSavedLoopMode());
    });
}

static long long YTKACEQueueSavedLoopMode(void) {
    id value = YTKACEPreferenceObject(YTKACEQueueLoopKey);
    return [value respondsToSelector:@selector(longLongValue)]
        ? [value longLongValue] : 0;
}

static void YTKACEQueueStoreLoopMode(long long mode) {
    YTKACESetPreferenceObject(YTKACEQueueLoopKey, @(mode));
}

static void YTKACEQueueApplyLoopMode(id controller, long long mode) {
    if (controller == nil) return;
    @try {
        [controller setValue:@(mode) forKey:@"loopMode"];
    } @catch (__unused NSException *exception) {
    }
    id collection = nil;
    @try {
        collection =
            [controller valueForKey:@"playlistPanelCollectionViewController"];
    } @catch (__unused NSException *exception) {
        collection = nil;
    }
    if (collection == nil) return;
    @try {
        if ([collection respondsToSelector:@selector(setLoopButtonMode:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(collection,
                @selector(setLoopButtonMode:), mode);
        }
        if ([collection respondsToSelector:@selector(setLoopButtonSelected:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(collection,
                @selector(setLoopButtonSelected:), mode != 0);
        }
    } @catch (__unused NSException *exception) {
    }
}

static void YTKACEQueueRestoreLoopMode(id controller) {
    if (controller == nil || !YTKACEQueueIsActive()) return;
    YTKACEQueueApplyLoopMode(controller, YTKACEQueueSavedLoopMode());
}

static void YTKACEQueueClearAll(void) {
    [YTKACEQueue() removeAllObjects];
    YTKACEQueueSave();
    id controller = YTKACEQueueControllerInstance;
    if ([controller respondsToSelector:@selector(clearQueue)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(controller,
                @selector(clearQueue));
        } @catch (__unused NSException *exception) {
        }
    }
    YTKACEShowNotice(YTKACELocalized(@"Queue cleared"));
    YTKACEQueueRebuildWatchPage();
}

static void YTKACEQueueConfirmClear(void) {
    YTKACEShowYouTubeConfirmation(YTKACELocalized(@"Clear queue"),
        YTKACELocalized(@"Remove every video from the queue?"),
        YTKACELocalized(@"Clear"), ^{
        YTKACEQueueClearAll();
    });
}

// Closing the miniplayer ends the queue, as it ends YouTube's own.
// Originals of hooks installed on every class implementing a selector,
// keyed "selector|class"; a receiver finds its own through its class chain.
static NSMutableDictionary<NSString *, NSValue *> *YTKACEQueueFoundOriginals;

static IMP YTKACEQueueFoundOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        NSValue *value = YTKACEQueueFoundOriginals[[NSString
            stringWithFormat:@"%s|%@", sel_getName(selector),
            NSStringFromClass(cls)]];
        if (value != nil) return (IMP)value.pointerValue;
    }
    return NULL;
}

// Hooks each selector on every app class whose own method list has it; the
// miniplayer comes in more than one flavour. Only the method lists are read:
// asking the runtime to look a method up would run +initialize on classes
// that are not ready for it this early.
static void YTKACEQueueInstallFoundHooks(NSDictionary<NSString *, NSValue *> *hooks) {
    if (YTKACEQueueFoundOriginals == nil) {
        YTKACEQueueFoundOriginals = [NSMutableDictionary dictionary];
    }
    NSMutableSet<NSString *> *missing = [NSMutableSet setWithArray:hooks.allKeys];
    for (NSString *name in YTKACEAppClassNames()) {
        Class cls = NSClassFromString(name);
        if (cls == Nil) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            NSString *selectorName = NSStringFromSelector(
                method_getName(methods[index]));
            NSValue *replacement = hooks[selectorName];
            if (replacement == nil) continue;
            IMP original = NULL;
            if (!YTKACEInstallInstanceHook(name, selectorName,
                                           (IMP)replacement.pointerValue,
                                           &original)) {
                continue;
            }
            YTKACEQueueFoundOriginals[[NSString stringWithFormat:@"%@|%@",
                selectorName, name]] =
                [NSValue valueWithPointer:(void *)original];
            [missing removeObject:selectorName];
            YTKACEDebugLog(@"queue", @"hook %@ on %@", selectorName, name);
        }
        free(methods);
    }
    for (NSString *selectorName in missing) {
        YTKACEDebugLog(@"queue", @"hook %@: no class", selectorName);
    }
}

// Drops the queue without touching the watch page, for when it is closing.
static void YTKACEQueueDropAll(void) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey) || YTKACEQueue().count == 0) return;
    [YTKACEQueue() removeAllObjects];
    YTKACEQueueSetCursor(nil);
    YTKACEQueueSave();
}

static void YTKACEQueueDidDismissMiniBar(id receiver, SEL selector) {
    YTKACEDebugLog(@"queue", @"miniplayer dismissed queue=%lu",
                      (unsigned long)YTKACEQueue().count);
    YTKACEQueueDropAll();
    IMP original = YTKACEQueueFoundOriginal(receiver, selector);
    if (original == NULL) return;
    ((void (*)(id, SEL))original)(receiver, selector);
}

static void YTKACEQueueDidTapAction(id receiver, SEL selector, id button) {
    if (!YTKACEQueueIsActive()) {
        if (OriginalDidTapAction == NULL) return;
        ((void (*)(id, SEL, id))OriginalDidTapAction)(receiver, selector,
                                                      button);
        return;
    }
    UIView *source = [button isKindOfClass:UIView.class] ? button : nil;
    YTKACEDownloadCoordinator *coordinator =
        YTKACEDownloadCoordinator.sharedCoordinator;
    NSMutableArray *actions = [NSMutableArray array];
    if (YTKACEQueue().count != 0 && YTKACEDownloadsEnabled()) {
        [actions addObject:[coordinator nativeSheetAction:
            YTKACELocalized(@"Download") icon:@"arrow.down.circle"
            handler:^{
                NSArray *queue = [YTKACEQueue() copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        YTKACEPresentVideoListDownloadMenu(queue,
                            YTKACELocalized(@"Queue"), source);
                    });
            }]];
    }
    [actions addObject:[coordinator nativeSheetAction:
        YTKACELocalized(@"Clear queue") icon:@"trash" handler:^{
            YTKACEQueueConfirmClear();
        }]];
    [coordinator presentPlaylistSheetWithTitle:nil subtitle:nil
                                    sourceView:source actions:actions];
}

static void YTKACEQueueDidTapLoop(id receiver, SEL selector) {
    if (OriginalDidTapLoop != NULL) {
        ((void (*)(id, SEL))OriginalDidTapLoop)(receiver, selector);
    }
    if (!YTKACEQueueIsActive()) return;
    const long long resolved = (YTKACEQueueSavedLoopMode() + 1) % 3;
    YTKACEQueueStoreLoopMode(resolved);
    YTKACEQueueApplyLoopMode(receiver, resolved);
}

static BOOL YTKACEQueueHasStep(NSInteger offset) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    NSUInteger current = YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
    if (current == NSNotFound) {
        return offset > 0 && YTKACEQueueNextIndex() != NSNotFound;
    }
    if (YTKACEQueueSavedLoopMode() != 0) return YTKACEQueue().count > 1;
    const NSInteger target = (NSInteger)current + offset;
    return target >= 0 && target < (NSInteger)YTKACEQueue().count;
}

static BOOL YTKACEQueueAutonavHasNext(id receiver, SEL selector) {
    if (YTKACEQueueHasStep(1)) return YES;
    if (OriginalAutonavHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasNext)(receiver, selector);
}

static BOOL YTKACEQueueAutonavHasPrevious(id receiver, SEL selector) {
    if (YTKACEQueueHasStep(-1)) return YES;
    if (OriginalAutonavHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasPrevious)(receiver, selector);
}

static BOOL YTKACEQueueControllerHasNext(id receiver, SEL selector) {
    if (YTKACEQueueHasStep(1)) return YES;
    if (OriginalQueueHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasNext)(receiver, selector);
}

static BOOL YTKACEQueueControllerHasPrevious(id receiver, SEL selector) {
    if (YTKACEQueueHasStep(-1)) return YES;
    if (OriginalQueueHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasPrevious)(receiver, selector);
}

static unsigned long long YTKACEQueueNextNavigable(id receiver, SEL selector) {
    if (YTKACEQueueHasStep(1)) {
        NSUInteger current =
            YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
        if (current != NSNotFound) {
            const NSUInteger count = YTKACEQueue().count;
            return (unsigned long long)((current + 1) % MAX(count, 1u));
        }
        return (unsigned long long)YTKACEQueueNextIndex();
    }
    if (OriginalNextNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalNextNavigable)(receiver,
                                                                    selector);
}

static unsigned long long YTKACEQueuePreviousNavigable(id receiver,
                                                       SEL selector) {
    if (YTKACEQueueHasStep(-1)) {
        NSUInteger current =
            YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
        const NSUInteger count = YTKACEQueue().count;
        if (current != NSNotFound && count != 0) {
            return (unsigned long long)(current == 0 ? count - 1 : current - 1);
        }
    }
    if (OriginalPreviousNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalPreviousNavigable)(
        receiver, selector);
}

static id YTKACEQueuePanelByline(id receiver, SEL selector) {
    if (YTKACEQueueIsActive()) {
        NSUInteger current =
            YTKACEQueueIndexOfVideo(YTKACEQueueCurrentVideoID());
        const NSUInteger count = YTKACEQueue().count;
        if (current != NSNotFound && count != 0) {
            return [NSString stringWithFormat:@"%@ • %lu/%lu",
                YTKACELocalized(@"Queue"), (unsigned long)(current + 1),
                (unsigned long)count];
        }
    }
    if (OriginalPanelByline == NULL) return nil;
    return ((id (*)(id, SEL))OriginalPanelByline)(receiver, selector);
}

static BOOL YTKACEQueueIsQueue(id receiver, SEL selector) {
    if (YTKACEQueuePanelController != receiver) {
        YTKACEQueuePanelController = receiver;
    }
    if (YTKACEQueueIsActive()) return YES;
    if (OriginalIsQueue == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalIsQueue)(receiver, selector);
}

static BOOL YTKACEQueueHasContents(id receiver, SEL selector) {
    if (YTKACEQueuePanelController != receiver) {
        YTKACEQueuePanelController = receiver;
    }
    if (YTKACEQueueIsActive()) return YES;
    if (OriginalHasQueueContents == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalHasQueueContents)(receiver, selector);
}

// Whether the player is on a live stream. At the live edge the playback time
// equals the length, which would otherwise look like the end of the video.
BOOL YTKACEQueueVideoIsLive(NSString *videoID, id player) {
    id single = YTKACEQueueValue(player, @[@"activeVideo"]);
    SEL pegged = NSSelectorFromString(@"isPeggedToLive");
    if ([single respondsToSelector:pegged] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(single, pegged)) {
        return YES;
    }
    static NSString *cachedID;
    static BOOL cachedLive;
    if (videoID.length != 0 && [videoID isEqualToString:cachedID]) return cachedLive;
    id details = nil;
    @try {
        details = YTKACEQueueVideoDetails(
            YTKACEQueueValue(player, @[@"contentPlayerResponse", @"playerResponse"]));
        if (details == nil && videoID.length != 0) {
            details = YTKACEQueueVideoDetails(YTKACECachedPlayerResponse(videoID));
        }
    } @catch (__unused NSException *exception) {
    }
    SEL liveSelector = NSSelectorFromString(@"isLive");
    if (details == nil || ![details respondsToSelector:liveSelector]) return NO;
    const BOOL live = ((BOOL (*)(id, SEL))objc_msgSend)(details, liveSelector);
    cachedID = [videoID copy];
    cachedLive = live;
    return live;
}

static void YTKACEQueueHandlePlaybackTime(NSNotification *notification) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return;
    id receiver = notification.object;
    if (receiver == nil) return;
    // Feed previews run their own player; only the watch player drives the
    // queue and names its current video.
    id watchPlayer = YTKACEQueuePlayerViewController;
    if (watchPlayer != nil && receiver != watchPlayer) return;
    YTKACEQueueResponder = receiver;
    id live = YTKACEQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    if ([live isKindOfClass:NSString.class] && [live length] != 0 &&
        ![live isEqualToString:YTKACEQueueActiveVideo]) {
        YTKACEQueueActiveVideo = live;
        YTKACEQueueActiveVideoTime = 0;
        if (receiver == YTKACEQueuePlayerViewController &&
            YTKACEQueueNoteStarted(live)) {
            YTKACEQueueRefreshPanel();
        }
    }
    YTKACEQueuePauseIfPending(receiver, live, YES);
    if (YTKACEQueue().count == 0) return;
    SEL totalSelector = NSSelectorFromString(@"currentVideoTotalMediaTime");
    if (![receiver respondsToSelector:totalSelector]) return;
    const double total = ((double (*)(id, SEL))objc_msgSend)(receiver, totalSelector);
    const double time = [notification.userInfo[@"time"] doubleValue];
    if (total <= 0.0 || time <= 0.0) return;
    // Track the video that is finishing itself rather than the last requested
    // ID, which prefetching changes; otherwise a late tick from the old video
    // advances a second time and skips a queued item.
    NSString *finishing = [live isKindOfClass:NSString.class] && [live length] != 0
        ? (NSString *)live : YTKACELastVideoID();
    if (finishing.length == 0) return;
    if (YTKACEQueueVideoIsLive(finishing, receiver)) return;
    const BOOL advanced =
        [finishing isEqualToString:YTKACEQueueAdvancedFromVideoID];
    if (time < total - 0.75) {
        if (advanced && time < MAX(total - 5.0, total * 0.5)) {
            YTKACEQueueAdvancedFromVideoID = nil;
        }
        return;
    }
    if (advanced) return;
    if (YTKACEQueueIndexOfVideo(finishing) == NSNotFound) {
        // Only the watch player, never a muted feed preview, hands over to
        // the queue after a video that was opened outside it.
        if (receiver != YTKACEQueuePlayerViewController ||
            !YTKACEQueueVideoIsOpen() ||
            YTKACEQueueNextIndex() == NSNotFound) {
            return;
        }
    }
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.AutoplayDisabled")) {
        return;
    }
    YTKACEQueueAdvancedFromVideoID = finishing;
    YTKACEQueueAdvance(finishing);
}


static NSString *const YTKACEQueueSentinelPrefix = @"YTKACEQ|";

static id YTKACEQueueSentinelCommand(NSString *action, NSString *videoID) {
    id command = YTKACEQueueMessage(@"YTICommand");
    if (command == nil) return nil;
    NSString *marker = [NSString stringWithFormat:@"%@%@|%@",
        YTKACEQueueSentinelPrefix, action, videoID];
    [command setValue:[marker dataUsingEncoding:NSUTF8StringEncoding]
               forKey:@"clickTrackingParams"];
    return command;
}

static id YTKACEQueueMenuItem(NSString *label, NSString *action,
                              NSString *videoID) {
    id wrapper = YTKACEQueueMessage(@"YTIMenuItemSupportedRenderers");
    id item = YTKACEQueueMessage(@"YTIMenuServiceItemRenderer");
    id command = YTKACEQueueSentinelCommand(action, videoID);
    if (wrapper == nil || item == nil || command == nil) return nil;
    id text = YTKACEQueueFormatted(label);
    if (text != nil) [item setValue:text forKey:@"text"];
    [item setValue:command forKey:@"serviceEndpoint"];
    [wrapper setValue:item forKey:@"menuServiceItemRenderer"];
    return wrapper;
}

static id YTKACEQueueItemMenu(NSString *videoID) {
    id supported = YTKACEQueueMessage(@"YTIMenuSupportedRenderers");
    id renderer = YTKACEQueueMessage(@"YTIMenuRenderer");
    if (supported == nil || renderer == nil) return nil;
    NSMutableArray *items = [renderer valueForKey:@"itemsArray"];
    if (items == nil) return nil;
    id playNext = YTKACEQueueMenuItem(YTKACELocalized(@"Play next in queue"),
                                      @"next", videoID);
    id remove = YTKACEQueueMenuItem(YTKACELocalized(@"Remove from queue"),
                                    @"remove", videoID);
    if (playNext != nil) [items addObject:playNext];
    if (remove != nil) [items addObject:remove];
    if (items.count == 0) return nil;
    [supported setValue:renderer forKey:@"menuRenderer"];
    return supported;
}

static BOOL YTKACEQueueHandleSentinel(id command) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    NSString *dump = YTKACEQueueClip(command, 600);
    NSRange range = [dump rangeOfString:YTKACEQueueSentinelPrefix];
    if (range.location == NSNotFound) return NO;
    NSString *tail = [dump substringFromIndex:NSMaxRange(range)];
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@"|"];
    if (parts.count < 2) return NO;
    NSString *action = parts[0];
    NSString *videoID = [parts[1] substringToIndex:
        MIN((NSUInteger)11, [parts[1] length])];
    NSUInteger index = YTKACEQueueIndexOfVideo(videoID);
    if (index == NSNotFound) return NO;
    NSDictionary *entry = YTKACEQueue()[index];
    if ([action isEqualToString:@"remove"]) {
        YTKACEQueueRemoveAt(index);
        YTKACEQueueSave();
        id controller = YTKACEQueueControllerInstance;
        if ([controller respondsToSelector:@selector(removeVideoID:)]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(controller,
                    @selector(removeVideoID:), videoID);
            } @catch (__unused NSException *exception) {
            }
        }
        YTKACEShowNotice(YTKACELocalized(@"Removed from queue"));
        YTKACEQueueRebuildWatchPage();
    } else if ([action isEqualToString:@"next"]) {
        NSUInteger target = YTKACEQueueUpcomingIndex(YTKACEQueueOpenVideoID());
        if (index < target) target--;
        if (index == target) {
            YTKACEShowNotice(YTKACELocalized(@"Playing next"));
            return YES;
        }
        [YTKACEQueue() removeObjectAtIndex:index];
        [YTKACEQueue() insertObject:entry atIndex:MIN(target,
            YTKACEQueue().count)];
        YTKACEQueueSave();
        YTKACEShowNotice(YTKACELocalized(@"Playing next"));
    } else {
        return NO;
    }
    YTKACEQueueRefreshPanel();
    return YES;
}

static BOOL YTKACEQueueHandleDiscovery(id command, id view) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    NSString *params = nil;
    @try {
        params = YTKACEQueueDiscoveryParams(command);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (params.length == 0) return NO;
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data.length == 0) return NO;
    int position = 0;
    NSString *videoID = YTKACEQueueVideoIDFromParams(data, &position);
    if (videoID.length == 0) return NO;
    if (position != 2 && position != 3) return NO;
    YTKACEQueueAdd(videoID, YTKACEQueueTitleNearView(view), position == 2);
    return YES;
}

static void YTKACEQueueDiscoveryExecute(id receiver, SEL selector, id command,
                                        id entry, id view, id sender) {
    if (YTKACEQueueHandleDiscovery(command, view)) return;
    if (OriginalDiscoveryExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalDiscoveryExecute)(
        receiver, selector, command, entry, view, sender);
}


static NSString *YTKACEQueueClip(id object, NSUInteger limit) {
    NSString *text = nil;
    @try {
        text = [object description];
    } @catch (__unused NSException *exception) {
        return @"<description failed>";
    }
    if (text.length == 0) return @"<empty>";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length <= limit) return text;
    return [text substringToIndex:limit];
}




// Queue adds that carry the video directly (queueAddEndpoint, or the
// queueAddMenuItemCommand YouTube sends when nothing is playing).
static BOOL YTKACEQueueHandleEndpointAdd(NSString *dump, id view) {
    NSRange marker = [dump rangeOfString:@"queue_add_endpoint"];
    if (marker.location == NSNotFound) marker = [dump rangeOfString:@"queueAddEndpoint"];
    if (marker.location == NSNotFound) {
        marker = [dump rangeOfString:@"queue_add_menu_item_command"];
    }
    if (marker.location == NSNotFound) {
        marker = [dump rangeOfString:@"queueAddMenuItemCommand"];
    }
    // Only a command that is itself a queue add, not one (like a menu) that
    // merely contains queue options somewhere inside it.
    if (marker.location == NSNotFound || marker.location > 300) return NO;
    if ([dump containsString:@"menu_renderer"] ||
        [dump containsString:@"menuRenderer"] ||
        [dump containsString:@"popup"]) {
        return NO;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"video_?[iI]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                                               options:0 error:NULL];
    });
    NSRange tail = NSMakeRange(marker.location, dump.length - marker.location);
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
                                                           range:tail];
    if (match == nil) return NO;
    NSString *videoID = [dump substringWithRange:[match rangeAtIndex:1]];
    NSString *upper = dump.uppercaseString;
    const BOOL playNext = [upper containsString:@"AFTER_CURRENT"] ||
        [upper containsString:@"PLAY_NEXT"];
    YTKACEQueueAdd(videoID, YTKACEQueueTitleNearView(view), playNext);
    return YES;
}

static BOOL YTKACEQueueHandleMenuAdd(id command, id view) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey)) return NO;
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (![dump containsString:@"getWatchNextQueueAddCommand"]) {
        return YTKACEQueueHandleEndpointAdd(dump, view);
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"getWatchNextQueueAddCommand\\]\\s*params:\\s*\"([^\"]+)\""
                                                               options:0 error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return NO;
    NSString *params = [dump substringWithRange:[match rangeAtIndex:1]];
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *videoID = data.length ? YTKACEQueueVideoIDFromParams(data, NULL) : nil;
    if (videoID.length == 0) return NO;
    BOOL playNext = YES;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    for (NSUInteger index = 0; index + 1 < data.length; index++) {
        if (bytes[index] == 0x18 && (bytes[index + 1] == 0x01 || bytes[index + 1] == 0x02)) {
            playNext = bytes[index + 1] == 0x01;
            break;
        }
    }
    YTKACEQueueAdd(videoID, YTKACEQueueTitleNearView(view), playNext);
    return YES;
}

static id YTKACEQueueConditionalItem(id wrapper) {
    SEL getter = NSSelectorFromString(@"menuConditionalServiceItemRenderer");
    SEL has = NSSelectorFromString(@"hasMenuConditionalServiceItemRenderer");
    if (![wrapper respondsToSelector:getter] || ![wrapper respondsToSelector:has]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(wrapper, has)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(wrapper, getter);
}

void YTKACEQueuePrepareMenuRenderers(id renderers) {
    if (!YTKACEFeatureEnabled(YTKACEQueueKey) || ![renderers isKindOfClass:NSArray.class]) return;
    NSMutableDictionary<NSString *, id> *commands = [NSMutableDictionary dictionary];
    NSMutableArray *upsells = [NSMutableArray array];
    for (id wrapper in renderers) {
        id item = YTKACEQueueConditionalItem(wrapper);
        if (item == nil) continue;
        NSString *dump = [item description];
        NSString *icon = [dump containsString:@"QUEUE_PLAY_NEXT"] ? @"next"
            : ([dump containsString:@"ADD_TO_REMOTE_QUEUE"] ? @"last" : nil);
        if (icon == nil) continue;
        if ([dump containsString:@"getWatchNextQueueAddCommand"]) {
            if (commands[icon] == nil) commands[icon] = [item valueForKey:@"serviceEndpoint"];
        } else if ([dump containsString:@"SPunlimited"]) {
            [upsells addObject:@[item, icon]];
        }
    }
    for (NSArray *pair in upsells) {
        id command = commands[pair[1]];
        if (command == nil) continue;
        id item = pair[0];
        [item setValue:command forKey:@"serviceEndpoint"];
        SEL clearIcon = NSSelectorFromString(@"setSecondaryIcon:");
        if ([item respondsToSelector:clearIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, clearIcon, nil);
        }
    }
}

static BOOL YTKACEQueueRouterHandle(id receiver, SEL selector, id command,
                                    id entry, id view, id sender) {
    YTKACEQueueNoteRouter(receiver, OriginalRouterHandle, NO, view, sender);
    if (YTKACEQueueHandleMenuAdd(command, view)) return YES;
    if (YTKACEQueueHandleSentinel(command)) return YES;
    if (YTKACEQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL YTKACEQueueRouterHandleCompletion(id receiver, SEL selector,
                                              id command, id entry, id view,
                                              id sender, id block) {
    YTKACEQueueNoteRouter(receiver, OriginalRouterHandleCompletion, YES, view,
                          sender);
    if (YTKACEQueueHandleMenuAdd(command, view)) return YES;
    if (YTKACEQueueHandleSentinel(command)) return YES;
    if (YTKACEQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))OriginalRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static BOOL YTKACEQueueScopedRouterHandle(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    YTKACEQueueNoteRouter(receiver, OriginalScopedRouterHandle, NO, view,
                          sender);
    if (YTKACEQueueHandleMenuAdd(command, view)) return YES;
    if (YTKACEQueueHandleSentinel(command)) return YES;
    if (YTKACEQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalScopedRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL YTKACEQueueScopedRouterHandleCompletion(id receiver, SEL selector,
                                                    id command, id entry,
                                                    id view, id sender,
                                                    id block) {
    YTKACEQueueNoteRouter(receiver, OriginalScopedRouterHandleCompletion, YES,
                          view, sender);
    if (YTKACEQueueHandleMenuAdd(command, view)) return YES;
    if (YTKACEQueueHandleSentinel(command)) return YES;
    if (YTKACEQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))
        OriginalScopedRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static IMP OriginalLegacyQueueMenuAdd;
static IMP OriginalLegacyWatchNextQueueAdd;

static void YTKACELegacyQueueMenuAdd(id receiver, SEL selector, id command,
                                     id entry, id view, id sender) {
    if (YTKACEQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyQueueMenuAdd)(
        receiver, selector, command, entry, view, sender);
}

static void YTKACELegacyWatchNextQueueAdd(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    if (YTKACEQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyWatchNextQueueAdd)(
        receiver, selector, command, entry, view, sender);
}

// This YouTube build routes queue menu taps to the Impl subclasses, which
// override the base-class methods hooked above.
static IMP OriginalImplMenuExecute;
static IMP OriginalImplMenuExecuteCompletion;
static IMP OriginalImplMenuHandle;
static IMP OriginalImplMenuHandleCompletion;
static IMP OriginalImplWatchNextExecute;
static IMP OriginalImplWatchNextExecuteCompletion;

static BOOL YTKACEQueueTakeMenuCommand(id command, id view, id sender) {
    YTKACEQueueCommandSender = sender;
    YTKACEQueueCommandView = view;
    return YTKACEQueueHandleMenuAdd(command, view);
}

static void YTKACEImplMenuExecute(id receiver, SEL selector, id command,
                                  id entry, id view, id sender) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplMenuExecute)(
        receiver, selector, command, entry, view, sender);
}

static void YTKACEImplMenuExecuteCompletion(id receiver, SEL selector,
                                            id command, id entry, id view,
                                            id sender, id block) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalImplMenuExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static void YTKACEImplMenuHandle(id receiver, SEL selector, id command,
                                 id entry, id view, id sender) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuHandle == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplMenuHandle)(
        receiver, selector, command, entry, view, sender);
}

static void YTKACEImplMenuHandleCompletion(id receiver, SEL selector,
                                           id command, id entry, id view,
                                           id sender, id block) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuHandleCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalImplMenuHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static void YTKACEImplWatchNextExecute(id receiver, SEL selector, id command,
                                       id entry, id view, id sender) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplWatchNextExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplWatchNextExecute)(
        receiver, selector, command, entry, view, sender);
}

static void YTKACEImplWatchNextExecuteCompletion(id receiver, SEL selector,
                                                 id command, id entry,
                                                 id view, id sender,
                                                 id block) {
    if (YTKACEQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplWatchNextExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))
        OriginalImplWatchNextExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

void YTKACEInstallQueueHooks(void) {
    YTKACEInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACEImplMenuExecute, &OriginalImplMenuExecute);
    YTKACEInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTKACEImplMenuExecuteCompletion,
        &OriginalImplMenuExecuteCompletion);
    YTKACEInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"handleQueueAddMenuItemWithCommand:entry:fromView:sender:",
        (IMP)YTKACEImplMenuHandle, &OriginalImplMenuHandle);
    YTKACEInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"handleQueueAddMenuItemWithCommand:entry:fromView:sender:"
        @"completionBlock:",
        (IMP)YTKACEImplMenuHandleCompletion,
        &OriginalImplMenuHandleCompletion);
    YTKACEInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACEImplWatchNextExecute, &OriginalImplWatchNextExecute);
    YTKACEInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTKACEImplWatchNextExecuteCompletion,
        &OriginalImplWatchNextExecuteCompletion);
    YTKACEInstallInstanceHook(@"YTQueueAddMenuItemCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACELegacyQueueMenuAdd, &OriginalLegacyQueueMenuAdd);
    YTKACEInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACELegacyWatchNextQueueAdd, &OriginalLegacyWatchNextQueueAdd);
    YTKACEInstallInstanceHook(
        @"MDXRequestDeviceDiscoveryCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTKACEQueueDiscoveryExecute, &OriginalDiscoveryExecute);
    YTKACEInstallInstanceHook(
        @"YTDefaultQueueWatchNextResponseParser",
        @"playlistPanelRendererFromWatchNextResponse:",
        (IMP)YTKACEQueuePanelParse, &OriginalPanelParse);
    if (!YTKACEInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
        @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
        @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:"
        @"headerHidden:",
        (IMP)YTKACEQueueSetVideoCountText, &OriginalSetVideoCountText)) {
        YTKACEInstallInstanceHook(@"YTPlaylistPanelSectionController",
            @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
            @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
            @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:",
            (IMP)YTKACEQueueLegacySetVideoCountText, &OriginalLegacySetVideoCountText);
    }
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapShuffleButton", (IMP)YTKACEQueueDidTapShuffle,
        &OriginalDidTapShuffle);
    YTKACEInstallInstanceHook(@"YTAutoplayAutonavController", @"hasNextVideo",
        (IMP)YTKACEQueueAutonavHasNext, &OriginalAutonavHasNext);
    YTKACEInstallInstanceHook(@"YTAutoplayAutonavController",
        @"hasPreviousVideo", (IMP)YTKACEQueueAutonavHasPrevious,
        &OriginalAutonavHasPrevious);
    YTKACEInstallInstanceHook(@"YTQueueController", @"nextNavigableVideoIndex",
        (IMP)YTKACEQueueNextNavigable, &OriginalNextNavigable);
    YTKACEInstallInstanceHook(@"YTQueueController",
        @"previousNavigableVideoIndex", (IMP)YTKACEQueuePreviousNavigable,
        &OriginalPreviousNavigable);
    YTKACEInstallInstanceHook(@"YTQueueController", @"hasNextVideo",
        (IMP)YTKACEQueueControllerHasNext, &OriginalQueueHasNext);
    YTKACEInstallInstanceHook(@"YTQueueController", @"hasPreviousVideo",
        (IMP)YTKACEQueueControllerHasPrevious, &OriginalQueueHasPrevious);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapActionButton:", (IMP)YTKACEQueueDidTapAction,
        &OriginalDidTapAction);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController", @"didTapLoopButton",
        (IMP)YTKACEQueueDidTapLoop, &OriginalDidTapLoop);
    YTKACEInstallInstanceHook(
        @"YTPlaylistPanelProminentThumbnailVideoCellController", @"setCell:",
        (IMP)YTKACEQueueCellControllerSetCell, &OriginalCellControllerSetCell);
    YTKACEInstallInstanceHook(@"YTSlideForActionsView", @"layoutSubviews",
        (IMP)YTKACEQueueSlideLayoutSubviews, &OriginalSlideLayoutSubviews);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"updateCell:forIndex:", (IMP)YTKACEQueueUpdateCellForIndex,
        &OriginalUpdateCellForIndex);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"alphaForIndex:", (IMP)YTKACEQueueAlphaForIndex,
        &OriginalAlphaForIndex);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"prepareForReuse", (IMP)YTKACEQueueCellPrepareForReuse,
        &OriginalCellPrepareForReuse);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"setCanReorder:", (IMP)YTKACEQueueSetCanReorder,
        &OriginalSetCanReorder);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"allowsReorderingAtPoint:", (IMP)YTKACEQueueAllowsReordering,
        &OriginalAllowsReordering);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoTitle",
        (IMP)YTKACEQueueNextVideoTitle, &OriginalNextVideoTitle);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoIndex",
        (IMP)YTKACEQueueNextVideoIndex, &OriginalNextVideoIndex);
    YTKACEInstallInstanceHook(@"YTQueueAutoplayController",
        @"replaceAutoplayItemsWithWatchNextResponse:",
        (IMP)YTKACEQueueReplaceAutoplay, &OriginalReplaceAutoplay);
    YTKACEInstallInstanceHook(@"YTQueueController",
        @"canMoveItemAtIndexPath:toIndexPath:", (IMP)YTKACEQueueCanMoveItem,
        &OriginalCanMoveItem);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController", @"byline",
        (IMP)YTKACEQueuePanelByline, &OriginalPanelByline);
    YTKACEInstallInstanceHook(@"YTPlaylistPanelController", @"isQueue",
        (IMP)YTKACEQueueIsQueue, &OriginalIsQueue);
    if (!YTKACEInstallInstanceHook(@"YTPlaylistPanelController",
        @"hasQueueContents", (IMP)YTKACEQueueHasContents,
        &OriginalHasQueueContents)) {
        YTKACEInstallInstanceHook(@"YTPlaylistPanelController",
            @"shouldShowPlaylist", (IMP)YTKACEQueueShouldShowPlaylist,
            &OriginalShouldShowPlaylist);
    }
    YTKACEInstallInstanceHook(@"YTQueueController",
        @"moveItemAtIndexPath:toIndexPath:userTriggered:",
        (IMP)YTKACEQueueMoveItem, &OriginalMoveItem);
    YTKACEInstallInstanceHook(@"YTQueueController",
        @"removeItemAtIndexPath:userTriggered:",
        (IMP)YTKACEQueueRemoveItem, &OriginalRemoveItem);
    YTKACEInstallInstanceHook(@"YTQueueController", @"removeQueueItemAtIndex:",
        (IMP)YTKACEQueueRemoveIndex, &OriginalRemoveIndex);
    YTKACEInstallInstanceHook(@"YTQueueController", @"clearQueue",
        (IMP)YTKACEQueueClearQueue, &OriginalClearQueue);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressNext:", (IMP)YTKACEQueueDidPressNext, &OriginalDidPressNext);
    YTKACEInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPrevious:", (IMP)YTKACEQueueDidPressPrevious,
        &OriginalDidPressPrevious);
    YTKACEInstallInstanceHook(@"YTAutoplayAutonavController", @"playNext",
        (IMP)YTKACEQueueAutonavPlayNext, &OriginalAutonavPlayNext);
    YTKACEInstallInstanceHook(
        @"YTWatchViewController", @"updateWithWatchNextResponse:",
        (IMP)YTKACEQueueViewUpdateWatchNext, &OriginalViewUpdateWatchNext);
    YTKACEInstallInstanceHook(
        @"YTPlaylistPanelController", @"initWithAccountID:parentResponder:",
        (IMP)YTKACEQueuePanelInit, &OriginalPanelInit);
    YTKACEInstallInstanceHook(
        @"YTPlaylistPanelController",
        @"initWithAccountID:parentResponder:queueController:",
        (IMP)YTKACEQueuePanelInitQueue, &OriginalPanelInitQueue);
    YTKACEInstallInstanceHook(
        @"YTQueueController", @"initWithAccountID:parentResponder:",
        (IMP)YTKACEQueueControllerInit, &OriginalQueueControllerInit);
    YTKACEInstallInstanceHook(
        @"YTWatchController", @"prepareWithWatchNextResponse:",
        (IMP)YTKACEQueuePrepareWatchNext, &OriginalPrepareWatchNext);
    YTKACEInstallInstanceHook(
        @"YTPlayerViewController", @"setWatchNextResponse:",
        (IMP)YTKACEQueueSetWatchNext, &OriginalSetWatchNext);
    YTKACEInstallInstanceHook(
        @"YTIWatchNextResponse", @"yt_playlistPanelRenderer",
        (IMP)YTKACEQueueResponsePanel, &OriginalResponsePanel);
    YTKACEInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)YTKACEQueueRouterHandle, &OriginalRouterHandle);
    YTKACEInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTKACEQueueRouterHandleCompletion, &OriginalRouterHandleCompletion);
    YTKACEInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)YTKACEQueueScopedRouterHandle, &OriginalScopedRouterHandle);
    YTKACEInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTKACEQueueScopedRouterHandleCompletion,
        &OriginalScopedRouterHandleCompletion);
    YTKACEQueueInstallFoundHooks(@{
        @"didDismissMiniBar":
            [NSValue valueWithPointer:(void *)YTKACEQueueDidDismissMiniBar],
    });
    [NSNotificationCenter.defaultCenter
        addObserverForName:@"YTKACEPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
        YTKACEQueueHandlePlaybackTime(notification);
    }];
}
