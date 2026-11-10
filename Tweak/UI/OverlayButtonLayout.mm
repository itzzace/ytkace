#import "OverlayButtonLayout.h"
#import "../Runtime/Preferences.h"

NSString *const YTKACEOverlayZoneTop = @"top";
NSString *const YTKACEOverlayZoneBelow = @"below";
NSString *const YTKACEOverlayZoneBottom = @"bottom";

static NSString *const YTKACEOverlayLayoutKey = @"YTKACE.Preference.Player.ButtonLayout";
static NSString *const YTKACEDownloadPlacementKey = @"YTKACE.Preference.Downloads.Placement";

NSArray<NSDictionary *> *YTKACEOverlayButtonCatalog(void) {
    return @[
        @{@"id": @"loop", @"title": @"Loop", @"symbol": @"repeat", @"key": YTKACELoopKey},
        @{@"id": @"quality", @"title": @"Quality", @"symbol": @"slider.horizontal.3", @"text": @"720p",
          @"key": @"YTKACE.Preference.Player.QualityButton"},
        @{@"id": @"speed", @"title": @"Speed", @"symbol": @"speedometer", @"key": YTKACESpeedKey},
        @{@"id": @"sponsorblock", @"title": @"SponsorBlock", @"symbol": @"shield.lefthalf.filled",
          @"key": @"YTKACE.Preference.SponsorBlock.OverlayButton"},
        @{@"id": @"sleeptimer", @"title": @"Sleep Timer", @"symbol": @"moon.zzz", @"key": YTKACESleepTimerKey},
        @{@"id": @"pip", @"title": @"Picture in Picture", @"symbol": @"pip", @"key": YTKACEPiPKey},
        @{@"id": @"transcript", @"title": @"Transcript", @"symbol": @"text.bubble",
          @"key": @"YTKACE.Preference.Playback.Transcript"},
        @{@"id": @"downloads", @"title": @"Download", @"symbol": @"arrow.down.circle"}
    ];
}

NSArray<NSString *> *YTKACEOverlayZones(void) {
    return @[YTKACEOverlayZoneTop, YTKACEOverlayZoneBelow, YTKACEOverlayZoneBottom];
}

// Saved layout with every catalog button in exactly one zone; new or
// unknown buttons go in the row under YouTube's, like before.
static NSDictionary<NSString *, NSArray<NSString *> *> *YTKACEOverlayLayout(void) {
    static NSDictionary *cachedStored;
    static NSDictionary *cachedLayout;
    id stored = YTKACEPreferenceObject(YTKACEOverlayLayoutKey);
    if (![stored isKindOfClass:NSDictionary.class]) stored = @{};
    if (cachedLayout != nil && [cachedStored isEqualToDictionary:stored]) return cachedLayout;

    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) [known addObject:button[@"id"]];
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    NSMutableDictionary *layout = [NSMutableDictionary dictionary];
    for (NSString *zone in YTKACEOverlayZones()) {
        NSMutableArray *ids = [NSMutableArray array];
        id list = stored[zone];
        for (id identifier in [list isKindOfClass:NSArray.class] ? list : @[]) {
            if (![identifier isKindOfClass:NSString.class] || ![known containsObject:identifier] ||
                [placed containsObject:identifier]) continue;
            [ids addObject:identifier];
            [placed addObject:identifier];
        }
        layout[zone] = ids;
    }
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) {
        if (![placed containsObject:button[@"id"]]) [layout[YTKACEOverlayZoneBelow] addObject:button[@"id"]];
    }
    cachedStored = [stored copy];
    cachedLayout = [layout copy];
    return cachedLayout;
}

NSString *YTKACEOverlayButtonZone(NSString *identifier) {
    NSDictionary *layout = YTKACEOverlayLayout();
    for (NSString *zone in YTKACEOverlayZones()) {
        if ([layout[zone] containsObject:identifier]) return zone;
    }
    return YTKACEOverlayZoneBelow;
}

NSArray<NSString *> *YTKACEOverlayZoneOrder(NSString *zone) {
    return YTKACEOverlayLayout()[zone] ?: @[];
}

void YTKACESetOverlayLayout(NSDictionary<NSString *, NSArray<NSString *> *> *layout) {
    YTKACESetPreferenceObject(YTKACEOverlayLayoutKey, layout.count != 0 ? layout : nil);
}

static NSString *YTKACEOverlayButtonKey(NSString *identifier) {
    for (NSDictionary *button in YTKACEOverlayButtonCatalog()) {
        if ([button[@"id"] isEqualToString:identifier]) return button[@"key"];
    }
    return nil;
}

// The download button's placement also covers YouTube's own download button.
BOOL YTKACEOverlayButtonEnabled(NSString *identifier) {
    if ([identifier isEqualToString:@"downloads"]) {
        const NSInteger placement = YTKACEDownloadPlacement();
        return placement == 1 || placement == 3;
    }
    NSString *key = YTKACEOverlayButtonKey(identifier);
    return key != nil && [NSUserDefaults.standardUserDefaults boolForKey:key];
}

void YTKACESetOverlayButtonEnabled(NSString *identifier, BOOL enabled) {
    if (YTKACEOverlayButtonEnabled(identifier) == enabled) return;
    if ([identifier isEqualToString:@"downloads"]) {
        // hiding our button keeps downloads on through YouTube's button
        const NSInteger placement = YTKACEDownloadPlacement();
        YTKACESetPreferenceObject(YTKACEDownloadPlacementKey,
                                  @(enabled ? (placement == 2 ? 3 : 1) : 2));
        return;
    }
    NSString *key = YTKACEOverlayButtonKey(identifier);
    if (key != nil) YTKACESetPreference(key, enabled);
}
