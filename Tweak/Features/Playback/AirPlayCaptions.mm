#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Captions on the TV while AirPlaying.
//
// Under AirPlay the receiver plays the HLS stream that MLHLSProxy serves (an
// AVAssetResourceLoader delegate on mlhls://localhost). Its master playlist has
// audio renditions only, so the receiver has no captions to draw, and the app's
// AirPlay caption controller (MLAVMediaCaptionController) reports no tracks,
// which greys out the CC button.
//
// This adds one SUBTITLES rendition per caption track to the master playlist.
// Each points at a one-segment playlist served here, whose segment is YouTube's
// timedtext URL in WebVTT. It then hands the stream's subtitle options to the
// AirPlay caption controller. The app never does that itself: -[MLAVPlayer
// loadPlayerCaptionsForAssetPlayer:] sends them to its captionDelegate instead.
// With the options in place the CC button and the captions menu work as usual.

static NSString *const YTKACEAirPlayCaptionsKey =
    @"YTKACE.Preference.Playback.AirPlayCaptions";
static NSString *const YTKACEAirPlayCaptionsPath = @"/ytkace-captions/";
static NSString *const YTKACEAirPlayCaptionsGroup = @"ytkace-captions";
// Marks the renditions added here, so they can be told apart from options iOS
// adds to the stream on its own.
static NSString *const YTKACEAirPlayCaptionsCharacteristic =
    @"com.ytkace.caption";

static const void *YTKACEAirPlayCaptionsInfoKey = &YTKACEAirPlayCaptionsInfoKey;

static IMP OriginalSelectorInit;
static IMP OriginalSelectorInitWithHelper;
static IMP OriginalFinishWithData;
static IMP OriginalShouldWait;
static IMP OriginalLoadPlayerCaptions;
static IMP OriginalSetUpCaptionController;
static IMP OriginalStopCaptions;
static IMP OriginalSetAirPlayCaptionTrack;

static const void *YTKACEAirPlayCaptionsWereOnKey =
    &YTKACEAirPlayCaptionsWereOnKey;
// What the viewer last did with captions during AirPlay. Nil until they turn
// them on or off.
static NSNumber *YTKACEAirPlayCaptionsWanted;

static id YTKACEAirPlayObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    const char *type =
        [receiver methodSignatureForSelector:selector].methodReturnType;
    if (type == NULL || type[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static long long YTKACEAirPlayInteger(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return 0;
    const char *type =
        [receiver methodSignatureForSelector:selector].methodReturnType;
    if (type == NULL) return 0;
    if (type[0] == 'q' || type[0] == 'l' || type[0] == 'Q' || type[0] == 'L') {
        return ((long long (*)(id, SEL))objc_msgSend)(receiver, selector);
    }
    if (type[0] == 'i' || type[0] == 'I') {
        return ((int (*)(id, SEL))objc_msgSend)(receiver, selector);
    }
    if (type[0] == 'B' || type[0] == 'c') {
        return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
    }
    return 0;
}

static NSString *YTKACEAirPlayVTTURL(id track) {
    NSURL *URL = YTKACECaptionTrackURL(track);
    if (URL == nil) return nil;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"fmt"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"vtt"]];
    components.queryItems = items;
    return components.URL.absoluteString;
}

// The CC button turns on the first track in the list, so the best one goes
// first: a hand-made track in the wanted language, else an auto-generated one
// in that language, else the track YouTube marks as the default for the
// video's own audio.
static NSUInteger YTKACEAirPlayDefaultTrack(NSArray<NSDictionary *> *tracks,
                                            id renderer,
                                            BOOL indicesMatch) {
    NSString *wanted = [NSUserDefaults.standardUserDefaults
        stringForKey:@"YTKACE.Preference.Playback.CaptionLanguage"];
    if (wanted.length == 0) {
        wanted = [NSLocale.preferredLanguages.firstObject
            componentsSeparatedByString:@"-"].firstObject;
    }
    wanted = wanted.lowercaseString ?: @"";
    NSUInteger generated = NSNotFound;
    for (NSUInteger index = 0; index < tracks.count; index++) {
        NSDictionary *track = tracks[index];
        if (wanted.length == 0 ||
            ![[track[@"language"] lowercaseString] hasPrefix:wanted]) {
            continue;
        }
        if (![track[@"generated"] boolValue]) return index;
        if (generated == NSNotFound) generated = index;
    }
    if (generated != NSNotFound) return generated;
    if (!indicesMatch) return 0;
    id audio = YTKACEAirPlayObject(renderer, @"ml_defaultAudioTrackData");
    long long index = -1;
    if (YTKACEAirPlayInteger(audio, @"hasDefaultCaptionTrackIndex")) {
        index = YTKACEAirPlayInteger(audio, @"defaultCaptionTrackIndex");
    } else {
        id indices = YTKACEAirPlayObject(audio, @"captionTrackIndicesArray");
        SEL valueAt = NSSelectorFromString(@"valueAtIndex:");
        if (YTKACEAirPlayInteger(indices, @"count") > 0 &&
            [indices respondsToSelector:valueAt]) {
            index = ((int32_t (*)(id, SEL, NSUInteger))objc_msgSend)(
                indices, valueAt, 0);
        }
    }
    return index >= 0 && index < (long long)tracks.count
        ? (NSUInteger)index : 0;
}

static void YTKACEAirPlayRememberCaptions(id streamSelector, id video) {
    if (streamSelector == nil || video == nil) return;
    @try {
        id captions = YTKACEAirPlayObject(video, @"playerCaptions");
        id renderer = YTKACEAirPlayObject(captions,
                                          @"playerCaptionsTracklistRenderer")
            ?: captions;
        NSArray *entries = YTKACEAirPlayObject(renderer, @"captionTracksArray");
        if (![entries isKindOfClass:NSArray.class] || entries.count == 0) return;
        NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
        for (id entry in entries) {
            NSString *URL = YTKACEAirPlayVTTURL(entry);
            if (URL.length == 0) continue;
            NSString *kind = YTKACEAirPlayObject(entry, @"kind");
            [tracks addObject:@{
                @"url": URL,
                @"language": YTKACECaptionTrackLanguage(entry) ?: @"und",
                @"name": YTKACECaptionTrackLabel(entry) ?: @"Captions",
                @"generated": @([kind isKindOfClass:NSString.class] &&
                                [kind isEqualToString:@"asr"])
            }];
        }
        if (tracks.count == 0) return;
        NSUInteger first = YTKACEAirPlayDefaultTrack(
            tracks, renderer, tracks.count == entries.count);
        if (first > 0 && first < tracks.count) {
            NSDictionary *track = tracks[first];
            [tracks removeObjectAtIndex:first];
            [tracks insertObject:track atIndex:0];
        }
        id details = YTKACEAirPlayObject(video, @"videoDetails");
        long long seconds = YTKACEAirPlayInteger(details, @"lengthSeconds");
        objc_setAssociatedObject(streamSelector, YTKACEAirPlayCaptionsInfoKey,
            @{@"tracks": tracks, @"seconds": @(seconds)},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTKACEDebugLog(@"airplay-cc", @"%lu tracks, first=%@",
                       (unsigned long)tracks.count, tracks[0][@"name"]);
    } @catch (__unused NSException *exception) {
    }
}

static NSDictionary *YTKACEAirPlayCaptionsForProxy(id proxy) {
    id selector = YTKACEAirPlayObject(proxy, @"delegate");
    if (selector == nil) return nil;
    NSDictionary *info =
        objc_getAssociatedObject(selector, YTKACEAirPlayCaptionsInfoKey);
    return [info isKindOfClass:NSDictionary.class] ? info : nil;
}

static id YTKACEAirPlaySelectorInit(id receiver, SEL selector, id video,
                                    id config, id streamingData) {
    id result = ((id (*)(id, SEL, id, id, id))OriginalSelectorInit)(
        receiver, selector, video, config, streamingData);
    if (YTKACEFeatureEnabled(YTKACEAirPlayCaptionsKey)) {
        YTKACEAirPlayRememberCaptions(result, video);
    }
    return result;
}

static id YTKACEAirPlaySelectorInitWithHelper(id receiver, SEL selector,
                                              id video, id config,
                                              id streamingData, id helper) {
    id result = ((id (*)(id, SEL, id, id, id, id))
        OriginalSelectorInitWithHelper)(receiver, selector, video, config,
                                        streamingData, helper);
    if (YTKACEFeatureEnabled(YTKACEAirPlayCaptionsKey)) {
        YTKACEAirPlayRememberCaptions(result, video);
    }
    return result;
}

static NSString *YTKACEAirPlayAttribute(NSString *value) {
    NSString *clean = [value stringByReplacingOccurrencesOfString:@"\""
                                                       withString:@"'"];
    return [clean stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

// AUTOSELECT=NO keeps iOS from showing these on its own when the same stream
// plays on the phone. They only show when the CC button selects one.
static NSData *YTKACEAirPlayMasterWithCaptions(NSData *data,
                                               NSArray<NSDictionary *> *tracks) {
    NSString *master = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
    if (master == nil || ![master containsString:@"#EXT-X-STREAM-INF:"]) {
        return data;
    }
    // A video with hand-made captions already has SUBTITLES renditions from
    // YouTube, for those tracks only. The ones added here cover every track,
    // so they take the place of YouTube's.
    NSRegularExpression *ownGroup = [NSRegularExpression
        regularExpressionWithPattern:@",SUBTITLES=\"[^\"]*\"|SUBTITLES=\"[^\"]*\","
                             options:0
                               error:nil];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    BOOL added = NO;
    for (NSString *line in [master componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"#EXT-X-MEDIA:"] &&
            [line containsString:@"TYPE=SUBTITLES"]) {
            continue;
        }
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            [lines addObject:line];
            continue;
        }
        if (!added) {
            added = YES;
            for (NSUInteger index = 0; index < tracks.count; index++) {
                NSDictionary *track = tracks[index];
                NSString *name = YTKACEAirPlayAttribute(track[@"name"]);
                if ([names containsObject:name]) {
                    name = [NSString stringWithFormat:@"%@ (%@)", name,
                            track[@"language"]];
                }
                while ([names containsObject:name]) {
                    name = [name stringByAppendingString:@" "];
                }
                [names addObject:name];
                [lines addObject:[NSString stringWithFormat:
                    @"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"%@\",NAME=\"%@\","
                     "LANGUAGE=\"%@\",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,"
                     "CHARACTERISTICS=\"%@\","
                     "URI=\"mlhls://localhost%@%lu/captions.m3u8\"",
                    YTKACEAirPlayCaptionsGroup, name,
                    YTKACEAirPlayAttribute(track[@"language"]),
                    YTKACEAirPlayCaptionsCharacteristic,
                    YTKACEAirPlayCaptionsPath, (unsigned long)index]];
            }
        }
        NSString *variant = [ownGroup
            stringByReplacingMatchesInString:line
                                     options:0
                                       range:NSMakeRange(0, line.length)
                                withTemplate:@""];
        [lines addObject:[variant stringByAppendingFormat:@",SUBTITLES=\"%@\"",
                          YTKACEAirPlayCaptionsGroup]];
    }
    return [[lines componentsJoinedByString:@"\n"]
        dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

static void YTKACEAirPlayFinishWithData(id receiver, SEL selector,
                                        AVAssetResourceLoadingRequest *request,
                                        NSData *data) {
    if (YTKACEFeatureEnabled(YTKACEAirPlayCaptionsKey) &&
        [data isKindOfClass:NSData.class] &&
        [request.request.URL.path isEqualToString:@"/master.m3u8"]) {
        NSArray *tracks = YTKACEAirPlayCaptionsForProxy(receiver)[@"tracks"];
        if (tracks.count != 0) {
            data = YTKACEAirPlayMasterWithCaptions(data, tracks);
        }
    }
    ((void (*)(id, SEL, id, id))OriginalFinishWithData)(receiver, selector,
                                                         request, data);
}

static BOOL YTKACEAirPlayShouldWait(id receiver, SEL selector, id loader,
                                    AVAssetResourceLoadingRequest *request) {
    NSURL *URL = request.request.URL;
    if (![URL.path hasPrefix:YTKACEAirPlayCaptionsPath]) {
        return ((BOOL (*)(id, SEL, id, id))OriginalShouldWait)(
            receiver, selector, loader, request);
    }
    NSDictionary *info = YTKACEAirPlayCaptionsForProxy(receiver);
    NSArray<NSDictionary *> *tracks = info[@"tracks"];
    NSArray<NSString *> *parts = URL.pathComponents;
    NSUInteger index = parts.count > 2
        ? (NSUInteger)MAX(0, parts[2].integerValue) : NSNotFound;
    if (index >= tracks.count) {
        [request finishLoadingWithError:
            [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorFileDoesNotExist
                            userInfo:nil]];
        return YES;
    }
    // One segment for the whole video: the WebVTT file from YouTube.
    double seconds = [info[@"seconds"] doubleValue];
    if (seconds <= 0) seconds = 6 * 60 * 60;
    NSString *playlist = [NSString stringWithFormat:
        @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%ld\n"
         "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
         "#EXTINF:%.3f,\n%@\n#EXT-X-ENDLIST\n",
        (long)ceil(seconds), seconds, tracks[index][@"url"]];
    NSData *data = [playlist dataUsingEncoding:NSUTF8StringEncoding];
    request.response = [[NSURLResponse alloc]
        initWithURL:URL
           MIMEType:@"application/vnd.apple.mpegurl"
        expectedContentLength:(NSInteger)data.length
        textEncodingName:@"UTF-8"];
    [request.dataRequest respondWithData:data];
    [request finishLoading];
    return YES;
}

// iOS can add its own entries to a stream's subtitle options, such as
// on-device "Transcribed" and "Translated" ones. They show up in the captions
// menu as plain language names and draw nothing on the TV. The caption
// controller only reads -options from what it is given, so give it a stand-in
// that lists the renditions added here.
@interface YTKACEAirPlayCaptionOptions : NSObject
@property (nonatomic, copy) NSArray *options;
@end

@implementation YTKACEAirPlayCaptionOptions
@end

static id YTKACEAirPlayOwnOptions(id group) {
    NSArray *options = YTKACEAirPlayObject(group, @"options");
    if (![options isKindOfClass:NSArray.class]) return group;
    // An entry iOS derives from one of ours, such as a translation, carries
    // our mark too. iOS tags everything it generates, so check that as well.
    NSMutableArray *own = [NSMutableArray array];
    for (id option in options) {
        if ([option isKindOfClass:AVMediaSelectionOption.class] &&
            [(AVMediaSelectionOption *)option hasMediaCharacteristic:
                YTKACEAirPlayCaptionsCharacteristic] &&
            ![(AVMediaSelectionOption *)option hasMediaCharacteristic:
                @"com.apple.machine-generated"]) {
            [own addObject:option];
        }
    }
    if (own.count == 0 || own.count == options.count) return group;
    YTKACEAirPlayCaptionOptions *stand = [YTKACEAirPlayCaptionOptions new];
    stand.options = own;
    return stand;
}

// The AirPlay caption controller starts with no track, but the CC button keeps
// the state it had on the phone. If captions were on, the button then shows on
// with nothing on the TV, and every tap sends "off". So start AirPlay the way
// the viewer left captions: as they were on the controller this one replaces,
// or as they last set them during AirPlay when the player starts in AirPlay.
static void YTKACEAirPlayCarryCaptionsOver(id player, id controller) {
    NSNumber *wereOn =
        objc_getAssociatedObject(player, YTKACEAirPlayCaptionsWereOnKey);
    NSNumber *wanted = wereOn ?: YTKACEAirPlayCaptionsWanted;
    SEL enable =
        NSSelectorFromString(@"enableCaptionsIfAvailableWithSelectionReason:");
    if (!wanted.boolValue || ![player respondsToSelector:enable] ||
        YTKACEAirPlayObject(controller, @"activeCaptionTrack") != nil) {
        return;
    }
    ((void (*)(id, SEL, long long))objc_msgSend)(player, enable, 1);
}

// Only MLAVMediaCaptionController, the one the app uses under AirPlay, takes
// subtitle options. The normal caption controllers do not respond to this.
static void YTKACEAirPlayOfferCaptions(id player, id assetPlayer) {
    if (!YTKACEFeatureEnabled(YTKACEAirPlayCaptionsKey)) return;
    SEL changed = NSSelectorFromString(@"playerCaptionOptionsDidChange:");
    SEL load = NSSelectorFromString(@"loadCaptionsOptionsWithCompletionHandler:");
    id controller = YTKACEAirPlayObject(player, @"captionController");
    if (![controller respondsToSelector:changed] ||
        ![assetPlayer respondsToSelector:load]) {
        return;
    }
    __weak id weakPlayer = player;
    void (^handler)(id) = ^(id group) {
        dispatch_block_t offer = ^{
            id current = YTKACEAirPlayObject(weakPlayer, @"captionController");
            if (group == nil || ![current respondsToSelector:changed]) return;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    current, changed, YTKACEAirPlayOwnOptions(group));
                YTKACEAirPlayCarryCaptionsOver(weakPlayer, current);
            } @catch (__unused NSException *exception) {
            }
        };
        if (NSThread.isMainThread) offer();
        else dispatch_async(dispatch_get_main_queue(), offer);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(assetPlayer, load, handler);
}

static void YTKACEAirPlayLoadPlayerCaptions(id receiver, SEL selector,
                                            id assetPlayer) {
    ((void (*)(id, SEL, id))OriginalLoadPlayerCaptions)(receiver, selector,
                                                         assetPlayer);
    YTKACEAirPlayOfferCaptions(receiver, assetPlayer);
}

// Runs again when AirPlay starts or stops in the middle of a video, which
// replaces the caption controller.
static void YTKACEAirPlaySetUpCaptionController(id receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalSetUpCaptionController)(receiver, selector);
    YTKACEAirPlayOfferCaptions(receiver,
                               YTKACEAirPlayObject(receiver, @"assetPlayer"));
}

// Called before the caption controller is replaced, for instance when AirPlay
// starts in the middle of a video.
static void YTKACEAirPlayStopCaptions(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEAirPlayCaptionsKey)) {
        id controller = YTKACEAirPlayObject(receiver, @"captionController");
        if (controller != nil) {
            BOOL on =
                YTKACEAirPlayObject(controller, @"activeCaptionTrack") != nil;
            objc_setAssociatedObject(receiver, YTKACEAirPlayCaptionsWereOnKey,
                                     @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    ((void (*)(id, SEL))OriginalStopCaptions)(receiver, selector);
}

// Reason 1 is the viewer using the CC button or the captions menu.
static void YTKACEAirPlaySetCaptionTrack(id receiver, SEL selector, id track,
                                         long long reason, BOOL updateLanguage) {
    if (track != nil) {
        YTKACEAirPlayCaptionsWanted = @YES;
    } else if (reason == 1) {
        YTKACEAirPlayCaptionsWanted = @NO;
    }
    ((void (*)(id, SEL, id, long long, BOOL))OriginalSetAirPlayCaptionTrack)(
        receiver, selector, track, reason, updateLanguage);
}

void YTKACEInstallAirPlayCaptionHooks(void) {
    YTKACEInstallInstanceHook(
        @"MLHLSStreamSelector", @"initWithVideo:playerConfig:streamingData:",
        (IMP)YTKACEAirPlaySelectorInit, &OriginalSelectorInit);
    YTKACEInstallInstanceHook(
        @"MLHLSStreamSelector",
        @"initWithVideo:playerConfig:streamingData:fairPlayLicenseLookupHelper:",
        (IMP)YTKACEAirPlaySelectorInitWithHelper,
        &OriginalSelectorInitWithHelper);
    YTKACEInstallInstanceHook(
        @"MLHLSProxy", @"didFinishResourceLoadingRequest:withData:",
        (IMP)YTKACEAirPlayFinishWithData, &OriginalFinishWithData);
    YTKACEInstallInstanceHook(
        @"MLHLSProxy",
        @"resourceLoader:shouldWaitForLoadingOfRequestedResource:",
        (IMP)YTKACEAirPlayShouldWait, &OriginalShouldWait);
    YTKACEInstallInstanceHook(
        @"MLAVPlayer", @"loadPlayerCaptionsForAssetPlayer:",
        (IMP)YTKACEAirPlayLoadPlayerCaptions, &OriginalLoadPlayerCaptions);
    YTKACEInstallInstanceHook(
        @"MLAVPlayer", @"setUpCaptionController",
        (IMP)YTKACEAirPlaySetUpCaptionController,
        &OriginalSetUpCaptionController);
    YTKACEInstallInstanceHook(@"MLAVPlayer", @"stopCaptions",
                              (IMP)YTKACEAirPlayStopCaptions,
                              &OriginalStopCaptions);
    YTKACEInstallInstanceHook(
        @"MLAVMediaCaptionController",
        @"setActiveCaptionTrack:selectionReason:updateCaptionConfigLanguage:",
        (IMP)YTKACEAirPlaySetCaptionTrack, &OriginalSetAirPlayCaptionTrack);
}
