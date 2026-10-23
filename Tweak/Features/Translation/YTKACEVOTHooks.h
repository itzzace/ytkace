#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTKACEInstallTranslationHooks(void);
FOUNDATION_EXPORT void YTKACEVOTNotifyDidActivateVideo(id receiver, id _Nullable playbackController, id _Nullable video, id _Nullable playbackData);
FOUNDATION_EXPORT void YTKACEVOTNotifyTimeDidChange(id receiver, double time);
FOUNDATION_EXPORT void YTKACERouteVOTMenuItem(id actions);

NS_ASSUME_NONNULL_END
