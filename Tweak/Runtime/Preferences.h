#import <Foundation/Foundation.h>

@class UIColor, UITraitCollection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTKACEMasterEnabledKey;
FOUNDATION_EXPORT NSString * const YTKACEOLEDKey;
FOUNDATION_EXPORT NSString * const YTKACENoAdsKey;
FOUNDATION_EXPORT NSString * const YTKACESponsorBlockKey;
FOUNDATION_EXPORT NSString * const YTKACEDownloadKey;
FOUNDATION_EXPORT NSString * const YTKACEBackgroundPlaybackKey;
FOUNDATION_EXPORT NSString * const YTKACEPiPKey;
FOUNDATION_EXPORT NSString * const YTKACESpeedKey;
FOUNDATION_EXPORT NSString * const YTKACELoopKey;
FOUNDATION_EXPORT NSString * const YTKACESleepTimerKey;
FOUNDATION_EXPORT NSString * const YTKACECleanCopiedLinksKey;
FOUNDATION_EXPORT NSString * const YTKACEPreferencesDidChangeNotification;

FOUNDATION_EXPORT void YTKACERegisterDefaults(void);
FOUNDATION_EXPORT BOOL YTKACEMasterEnabled(void);
FOUNDATION_EXPORT BOOL YTKACEFeatureEnabled(NSString *key);
FOUNDATION_EXPORT BOOL YTKACEDownloadsEnabled(void);
FOUNDATION_EXPORT NSInteger YTKACEDownloadPlacement(void);
FOUNDATION_EXPORT BOOL YTKACEOLEDActive(UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *YTKACEInterfaceBackgroundColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *YTKACEInterfaceSurfaceColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT BOOL YTKACESponsorBlockEnabled(void);
FOUNDATION_EXPORT void YTKACESetPreference(NSString *key, BOOL enabled);
FOUNDATION_EXPORT id _Nullable YTKACEPreferenceObject(NSString *key);
FOUNDATION_EXPORT void YTKACESetPreferenceObject(NSString *key, id _Nullable value);
FOUNDATION_EXPORT NSURL *YTKACEApplicationSupportDirectory(void);
FOUNDATION_EXPORT NSUInteger YTKACEPurgeSystemCaches(void);

NS_ASSUME_NONNULL_END
