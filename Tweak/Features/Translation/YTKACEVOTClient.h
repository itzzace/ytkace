#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTKACEVOTStatus) {
    YTKACEVOTStatusFailed = 0,
    YTKACEVOTStatusFinished = 1,
    YTKACEVOTStatusWaiting = 2,
    YTKACEVOTStatusLongWaiting = 3,
    YTKACEVOTStatusPartContent = 5,
    YTKACEVOTStatusAudioRequested = 6,
    YTKACEVOTStatusSessionRequired = 7
};

@interface YTKACEVOTResponse : NSObject
@property (nonatomic, copy, nullable) NSString *audioURL;
@property (nonatomic, assign) YTKACEVOTStatus status;
@property (nonatomic, assign) NSInteger remainingTime;
@property (nonatomic, copy, nullable) NSString *translationID;
@property (nonatomic, copy, nullable) NSString *detectedLanguage;
@property (nonatomic, copy, nullable) NSString *message;
@end

typedef void (^YTKACEVOTCompletion)(YTKACEVOTResponse * _Nullable response, NSError * _Nullable error);

FOUNDATION_EXPORT NSString * const kYTKACEVOTVoiceTypeKey;
FOUNDATION_EXPORT NSString * const kYTKACEVOTYandexTokenKey;
FOUNDATION_EXPORT NSString * const kYTKACEVOTYandexLoginKey;

@interface YTKACEVOTClient : NSObject

+ (instancetype)sharedClient;

+ (nullable NSString *)currentYandexToken;
+ (nullable NSString *)currentYandexLogin;
+ (BOOL)isYandexAuthorized;
+ (void)logoutYandex;
+ (nullable NSString *)cleanOAuthToken:(NSString *)rawInput;
+ (void)validateAndSaveToken:(NSString *)rawToken
                  completion:(void (^)(BOOL success, NSString * _Nullable login, NSString * _Nullable errorMessage))completion;

- (void)requestTranslationForVideoID:(NSString *)videoID
                            duration:(double)duration
                          sourceLang:(NSString * _Nullable)sourceLang
                          targetLang:(NSString * _Nullable)targetLang
                          completion:(YTKACEVOTCompletion)completion;

- (void)requestTranslationForVideoID:(NSString *)videoID
                            duration:(double)duration
                          sourceLang:(NSString * _Nullable)sourceLang
                          targetLang:(NSString * _Nullable)targetLang
                           voiceType:(NSString * _Nullable)voiceType
                          completion:(YTKACEVOTCompletion)completion;

- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
