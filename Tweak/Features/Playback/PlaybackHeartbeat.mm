#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"

BOOL YTKACEShouldBlockPlaybackHeartbeat(NSURL *URL) {
    if (!YTKACEFeatureEnabled(@"YTKACE.Preference.Playback.BlockHeartbeat")) return NO;
    if (![URL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![URL.path isEqualToString:@"/youtubei/v1/player/heartbeat"]) return NO;

    NSString *host = URL.host.lowercaseString;
    return [host isEqualToString:@"youtube.com"] ||
        [host hasSuffix:@".youtube.com"] ||
        [host isEqualToString:@"youtubei.googleapis.com"];
}
