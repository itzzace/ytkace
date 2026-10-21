#import "YouTubeLinkCleaner.h"

static BOOL YTKACEYouTubeHost(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
        [host hasSuffix:[@"." stringByAppendingString:domain]];
}

// Foundation's nonliteral splitting can absorb delimiters followed by combining
// marks. Scan ASCII delimiters directly and retain each original substring.
static NSArray<NSString *> *YTKACESplitLiteral(NSString *input, unichar delimiter) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger start = 0;
    for (NSUInteger index = 0; index <= input.length; index++) {
        if (index == input.length || [input characterAtIndex:index] == delimiter) {
            [parts addObject:[input substringWithRange:NSMakeRange(start, index - start)]];
            start = index + 1;
        }
    }
    return parts;
}

NSString *YTKACECleanYouTubeLink(NSString *input) {
    // Validate one whole URL, never prose, a selection, or multiple links.
    if (input.length == 0 || input.length > 8192 ||
        [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192 ||
        [input rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [input rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [input containsString:@"\\"]) return input;
    // Foundation repairs malformed percent escapes; decline rather than repair.
    if ([input stringByRemovingPercentEncoding] == nil) return input;
    NSURLComponents *components = [NSURLComponents componentsWithString:input];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    BOOL youtube = YTKACEYouTubeHost(host, @"youtube.com");
    BOOL shortHost = YTKACEYouTubeHost(host, @"youtu.be");
    if ((!youtube && !shortHost) ||
        (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) ||
        components.user != nil || components.password != nil ||
        components.URL == nil || [components.path isEqualToString:@"/signin"]) return input;

    NSRange hash = [input rangeOfString:@"#" options:NSLiteralSearch];
    NSUInteger end = hash.location == NSNotFound ? input.length : hash.location;
    NSRange question = [input rangeOfString:@"?" options:NSLiteralSearch range:NSMakeRange(0, end)];
    if (question.location == NSNotFound) return input;
    NSString *query = [input substringWithRange:
        NSMakeRange(question.location + 1, end - question.location - 1)];
    NSArray<NSString *> *pairs = YTKACESplitLiteral(query, '&');
    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:pairs.count];

    NSArray<NSString *> *path = YTKACESplitLiteral(components.path, '/');
    // `is` is a share ID only on short, Shorts, and live video links.
    BOOL shortVideo = shortHost &&
        ((path.count == 2 && [path[1] length] != 0) ||
         (path.count == 3 && [path[1] length] != 0 && [path[2] length] == 0));
    BOOL longVideo = youtube && (path.count == 3 ||
        (path.count == 4 && [path[3] length] == 0)) &&
        ([path[1] isEqualToString:@"shorts"] || [path[1] isEqualToString:@"live"]) &&
        [path[2] length] != 0;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"=" options:NSLiteralSearch];
        NSString *rawName = equals.location == NSNotFound ? pair :
            [pair substringToIndex:equals.location];
        NSString *name = rawName.stringByRemovingPercentEncoding.lowercaseString;
        BOOL tracking = [@[@"si", @"feature", @"gclid", @"kw", @"pp"] containsObject:name];
        if ([name hasPrefix:@"utm_"] && name.length > 4) {
            NSString *suffix = [name substringFromIndex:4];
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz_"];
            tracking = [suffix rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
        }
        if ((shortVideo || longVideo) && [name isEqualToString:@"is"]) tracking = YES;
        if (!tracking) [kept addObject:pair];
    }
    if (kept.count == pairs.count) return input;
    NSString *remaining = kept.count == 0 ? @"" :
        [@"?" stringByAppendingString:[kept componentsJoinedByString:@"&"]];
    return [NSString stringWithFormat:@"%@%@%@",
        [input substringToIndex:question.location], remaining, [input substringFromIndex:end]];
}
