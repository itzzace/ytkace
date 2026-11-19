#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Where our player buttons sit: in YouTube's top row, in our row under it,
// or next to the fullscreen button. Hidden buttons are the ones switched off.
FOUNDATION_EXPORT NSString *const YTKACEOverlayZoneTop;
FOUNDATION_EXPORT NSString *const YTKACEOverlayZoneBelow;
FOUNDATION_EXPORT NSString *const YTKACEOverlayZoneBottom;
// In fullscreen, after the pill of buttons under the progress bar.
FOUNDATION_EXPORT NSString *const YTKACEOverlayZoneFullscreen;
// A column down the left edge of the player.
FOUNDATION_EXPORT NSString *const YTKACEOverlayZoneLeft;

// Each entry: id (the overlay configurator id), title, symbol, optional text.
FOUNDATION_EXPORT NSArray<NSDictionary *> *YTKACEOverlayButtonCatalog(void);

FOUNDATION_EXPORT NSArray<NSString *> *YTKACEOverlayZones(void);
FOUNDATION_EXPORT NSString *YTKACEOverlayButtonZone(NSString *identifier);
// Button ids in a zone, left to right, including switched-off ones.
FOUNDATION_EXPORT NSArray<NSString *> *YTKACEOverlayZoneOrder(NSString *zone);
FOUNDATION_EXPORT void YTKACESetOverlayLayout(NSDictionary<NSString *, NSArray<NSString *> *> *_Nullable layout);

FOUNDATION_EXPORT BOOL YTKACEOverlayButtonEnabled(NSString *identifier);
FOUNDATION_EXPORT void YTKACESetOverlayButtonEnabled(NSString *identifier, BOOL enabled);

// YouTube's own top-right buttons (autoplay, cast, captions, gear), left to
// right. Nil order means YouTube's.
FOUNDATION_EXPORT NSArray<NSString *> *YTKACENativeTopDefaultOrder(void);
FOUNDATION_EXPORT NSArray<NSString *> *YTKACENativeTopOrder(void);
FOUNDATION_EXPORT void YTKACESetNativeTopOrder(NSArray<NSString *> *_Nullable order);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *YTKACENativeTopIdentifiers(void);
// The saved top row as stored: YouTube's names and YTKACE's ids, left to right.
FOUNDATION_EXPORT NSArray<NSString *> *YTKACETopRowOrder(void);

NS_ASSUME_NONNULL_END
