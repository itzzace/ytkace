#import "YTKACEVOTClient.h"
#import "YTKACEVOTLog.h"
#import <CommonCrypto/CommonHMAC.h>

NSString * const kYTKACEVOTVoiceTypeKey = @"YTKACE.Preference.VOT.VoiceType";
NSString * const kYTKACEVOTYandexTokenKey = @"YTKACE.Preference.VOT.YandexToken";
NSString * const kYTKACEVOTYandexLoginKey = @"YTKACE.Preference.VOT.YandexLogin";

static NSString * const kYandexVOTHost = @"https://api.browser.yandex.ru";
static const char *kYandexVOTHMACKey = "bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";
static NSString * const kYandexVOTComponentVersion = @"26.10.0.1796";

@implementation YTKACEVOTResponse
@end

#pragma mark - Protobuf Helpers

static void VOTAppendVarint(NSMutableData *data, uint64_t val) {
    uint8_t buf[10];
    size_t i = 0;
    while (val > 0x7F) {
        buf[i++] = (val & 0x7F) | 0x80;
        val >>= 7;
    }
    buf[i++] = (uint8_t)(val & 0x7F);
    [data appendBytes:buf length:i];
}

static void VOTAppendTag(NSMutableData *data, uint32_t fieldNumber, uint32_t wireType) {
    VOTAppendVarint(data, (fieldNumber << 3) | wireType);
}

static void VOTAppendString(NSMutableData *data, uint32_t fieldNumber, NSString *string) {
    if (string.length == 0) return;
    NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding];
    VOTAppendTag(data, fieldNumber, 2);
    VOTAppendVarint(data, utf8.length);
    [data appendData:utf8];
}

static void VOTAppendBool(NSMutableData *data, uint32_t fieldNumber, BOOL value) {
    VOTAppendTag(data, fieldNumber, 0);
    VOTAppendVarint(data, value ? 1 : 0);
}

static void VOTAppendInt32(NSMutableData *data, uint32_t fieldNumber, int32_t value) {
    VOTAppendTag(data, fieldNumber, 0);
    VOTAppendVarint(data, (uint64_t)value);
}

static void VOTAppendDouble(NSMutableData *data, uint32_t fieldNumber, double value) {
    VOTAppendTag(data, fieldNumber, 1);
    uint64_t raw;
    memcpy(&raw, &value, sizeof(double));
    [data appendBytes:&raw length:sizeof(double)];
}

#pragma mark - YTKACEVOTClient Implementation

@interface YTKACEVOTClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSCache<NSString *, YTKACEVOTResponse *> *cache;
@property (nonatomic, copy, nullable) NSString *currentSecretKey;
@property (nonatomic, copy, nullable) NSString *currentUUID;
@property (nonatomic, assign) NSTimeInterval sessionExpiresAt;
@end

@implementation YTKACEVOTClient

+ (instancetype)sharedClient {
    static YTKACEVOTClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[YTKACEVOTClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 30.0;
        _session = [NSURLSession sessionWithConfiguration:config];
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 100;
    }
    return self;
}

- (void)clearCache {
    YTKACEVOTLog(@"Client", @"Clearing translation response cache");
    [self.cache removeAllObjects];
}

+ (nullable NSString *)currentYandexToken {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kYTKACEVOTYandexTokenKey];
}

+ (nullable NSString *)currentYandexLogin {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kYTKACEVOTYandexLoginKey];
}

+ (BOOL)isYandexAuthorized {
    return [self currentYandexToken].length > 0;
}

+ (void)logoutYandex {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kYTKACEVOTYandexTokenKey];
    [defaults removeObjectForKey:kYTKACEVOTYandexLoginKey];
    [defaults synchronize];
    YTKACEVOTLog(@"Client", @"Logged out from Yandex account");
}

+ (nullable NSString *)cleanOAuthToken:(NSString *)rawInput {
    if (rawInput.length == 0) return nil;
    NSString *trimmed = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRange tokenRange = [trimmed rangeOfString:@"access_token="];
    if (tokenRange.location != NSNotFound) {
        NSString *sub = [trimmed substringFromIndex:tokenRange.location + tokenRange.length];
        NSRange ampRange = [sub rangeOfString:@"&"];
        if (ampRange.location != NSNotFound) {
            sub = [sub substringToIndex:ampRange.location];
        }
        return sub;
    }

    trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
    return trimmed.length > 0 ? trimmed : nil;
}

+ (void)validateAndSaveToken:(NSString *)rawToken
                  completion:(void (^)(BOOL success, NSString * _Nullable login, NSString * _Nullable errorMessage))completion {
    NSString *token = [self cleanOAuthToken:rawToken];
    if (token.length == 0) {
        if (completion) completion(NO, nil, @"Empty token");
        return;
    }

    NSURL *infoURL = [NSURL URLWithString:@"https://login.yandex.ru/info?format=json"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:infoURL];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"OAuth %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (error != nil || httpResp.statusCode != 200 || data.length == 0) {
            NSString *errDesc = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)httpResp.statusCode];
            YTKACEVOTLog(@"Client", @"Yandex token validation failed: %@", errDesc);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, nil, [NSString stringWithFormat:@"Yandex authorization failed: %@", errDesc]);
                });
            }
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        NSString *login = [json objectForKey:@"login"];
        if (login.length == 0) {
            login = [json objectForKey:@"default_email"];
        }
        if (login.length == 0) {
            login = [json objectForKey:@"display_name"] ?: @"Yandex User";
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:token forKey:kYTKACEVOTYandexTokenKey];
        [defaults setObject:login forKey:kYTKACEVOTYandexLoginKey];
        [defaults synchronize];

        YTKACEVOTLog(@"Client", @"Yandex OAuth authorized successfully for user: %@", login);

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, login, nil);
            });
        }
    }] resume];
}

- (NSString *)generateUUID {
    static const char hexChars[] = "0123456789abcdef";
    char uuid[33];
    for (int i = 0; i < 32; i++) {
        uuid[i] = hexChars[arc4random_uniform(16)];
    }
    uuid[32] = '\0';
    return [NSString stringWithUTF8String:uuid];
}

- (NSString *)hmacSHA256HexForData:(NSData *)data {
    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, kYandexVOTHMACKey, strlen(kYandexVOTHMACKey), data.bytes, data.length, hmac);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hmac[i]];
    }
    return hex;
}

- (NSString *)hmacSHA256HexForString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return [self hmacSHA256HexForData:data];
}

- (void)ensureSessionWithCompletion:(void (^)(NSString * _Nullable secretKey, NSString * _Nullable uuid, NSError * _Nullable error))completion {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.currentSecretKey != nil && self.currentUUID != nil && now < self.sessionExpiresAt) {
        completion(self.currentSecretKey, self.currentUUID, nil);
        return;
    }

    NSString *newUUID = [self generateUUID];
    NSMutableData *sessionReqData = [NSMutableData data];
    VOTAppendString(sessionReqData, 1, newUUID);
    VOTAppendString(sessionReqData, 2, @"video-translation");

    NSString *signature = [self hmacSHA256HexForData:sessionReqData];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kYandexVOTHost stringByAppendingString:@"/session/create"]]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = sessionReqData;
    [request setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:signature forHTTPHeaderField:@"Vtrans-Signature"];

    YTKACEVOTLog(@"Client", @"Creating new Yandex VOT session (UUID: %@)", newUUID);

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        (void)response;
        if (error != nil || data.length == 0) {
            YTKACEVOTLog(@"Client", @"Session creation failed: %@", error.localizedDescription ?: @"empty response");
            completion(nil, nil, error ?: [NSError errorWithDomain:@"YTKACEVOT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create Yandex session"}]);
            return;
        }

        NSString *secretKey = nil;
        uint64_t expires = 3600;

        const uint8_t *bytes = (const uint8_t *)data.bytes;
        NSUInteger len = data.length;
        NSUInteger idx = 0;

        while (idx < len) {
            uint64_t tag = 0;
            int shift = 0;
            while (idx < len) {
                uint8_t b = bytes[idx++];
                tag |= (uint64_t)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            uint32_t fieldNum = (uint32_t)(tag >> 3);
            uint32_t wireType = (uint32_t)(tag & 7);

            if (wireType == 2) {
                uint64_t strLen = 0;
                shift = 0;
                while (idx < len) {
                    uint8_t b = bytes[idx++];
                    strLen |= (uint64_t)(b & 0x7F) << shift;
                    if (!(b & 0x80)) break;
                    shift += 7;
                }
                if (idx + strLen <= len) {
                    if (fieldNum == 1) {
                        secretKey = [[NSString alloc] initWithBytes:&bytes[idx] length:strLen encoding:NSUTF8StringEncoding];
                    }
                    idx += strLen;
                }
            } else if (wireType == 0) {
                uint64_t varint = 0;
                shift = 0;
                while (idx < len) {
                    uint8_t b = bytes[idx++];
                    varint |= (uint64_t)(b & 0x7F) << shift;
                    if (!(b & 0x80)) break;
                    shift += 7;
                }
                if (fieldNum == 2) {
                    expires = varint;
                }
            } else if (wireType == 1) {
                idx += 8;
            } else if (wireType == 5) {
                idx += 4;
            }
        }

        if (secretKey.length > 0) {
            self.currentSecretKey = secretKey;
            self.currentUUID = newUUID;
            self.sessionExpiresAt = now + (NSTimeInterval)(expires > 60 ? expires - 60 : expires);
            YTKACEVOTLog(@"Client", @"Session successfully established, expires in %llu sec", expires);
            completion(secretKey, newUUID, nil);
        } else {
            YTKACEVOTLog(@"Client", @"Invalid session response data");
            completion(nil, nil, [NSError errorWithDomain:@"YTKACEVOT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid session response"}]);
        }
    }] resume];
}

- (void)sendAudioFallbackForVideoID:(NSString *)videoID
                      translationID:(NSString *)translationID
                          secretKey:(NSString *)secretKey
                               uuid:(NSString *)uuid
                         completion:(void (^)(void))callback {
    if (videoID.length == 0 || translationID.length == 0 || secretKey.length == 0 || uuid.length == 0) {
        if (callback) callback();
        return;
    }

    NSString *videoURL = [NSString stringWithFormat:@"https://youtu.be/%@", videoID];
    YTKACEVOTLog(@"Client", @"Sending audio fallback handshake for %@ (translationID: %@)", videoID, translationID);

    // 1. PUT /video-translation/fail-audio-js
    NSDictionary *failJson = @{@"video_url": videoURL};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:failJson options:0 error:nil];
    NSMutableURLRequest *failReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kYandexVOTHost stringByAppendingString:@"/video-translation/fail-audio-js"]]];
    failReq.HTTPMethod = @"PUT";
    failReq.HTTPBody = jsonData;
    [failReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [failReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSString *yandexToken = [[self class] currentYandexToken];
    if (yandexToken.length > 0) {
        [failReq setValue:[NSString stringWithFormat:@"OAuth %@", yandexToken] forHTTPHeaderField:@"Authorization"];
    }

    [[self.session dataTaskWithRequest:failReq completionHandler:^(NSData * _Nullable fData, NSURLResponse * _Nullable fResp, NSError * _Nullable fErr) {
        (void)fData; (void)fResp; (void)fErr;
        YTKACEVOTLog(@"Client", @"fail-audio-js request completed, sending PUT /video-translation/audio...");

        // 2. PUT /video-translation/audio with fallback empty audio buffer
        NSMutableData *audioBuffer = [NSMutableData data];
        VOTAppendString(audioBuffer, 1, [NSString stringWithFormat:@"fallback-empty-audio:video-translation:%@", videoID]);
        VOTAppendVarint(audioBuffer, (2 << 3) | 2);
        VOTAppendVarint(audioBuffer, 0);

        NSMutableData *audioReqBody = [NSMutableData data];
        VOTAppendString(audioReqBody, 1, translationID);
        VOTAppendString(audioReqBody, 2, videoURL);
        VOTAppendTag(audioReqBody, 6, 2);
        VOTAppendVarint(audioReqBody, audioBuffer.length);
        [audioReqBody appendData:audioBuffer];

        NSString *pathAudio = @"/video-translation/audio";
        NSString *tokenAudio = [NSString stringWithFormat:@"%@:%@:%@", uuid, pathAudio, kYandexVOTComponentVersion];
        NSString *tokenAudioSign = [self hmacSHA256HexForString:tokenAudio];
        NSString *bodyAudioSign = [self hmacSHA256HexForData:audioReqBody];

        NSMutableURLRequest *areq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kYandexVOTHost stringByAppendingString:pathAudio]]];
        areq.HTTPMethod = @"PUT";
        areq.HTTPBody = audioReqBody;
        [areq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [areq setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        [areq setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [areq setValue:bodyAudioSign forHTTPHeaderField:@"Vtrans-Signature"];
        [areq setValue:secretKey forHTTPHeaderField:@"Sec-Vtrans-Sk"];
        [areq setValue:[NSString stringWithFormat:@"%@:%@", tokenAudioSign, tokenAudio] forHTTPHeaderField:@"Sec-Vtrans-Token"];
        if (yandexToken.length > 0) {
            [areq setValue:[NSString stringWithFormat:@"OAuth %@", yandexToken] forHTTPHeaderField:@"Authorization"];
        }

        [[self.session dataTaskWithRequest:areq completionHandler:^(NSData * _Nullable aData, NSURLResponse * _Nullable aResp, NSError * _Nullable aErr) {
            (void)aData; (void)aResp; (void)aErr;
            YTKACEVOTLog(@"Client", @"Audio fallback handshake finished successfully");
            if (callback) callback();
        }] resume];
    }] resume];
}

- (void)requestTranslationInternalForVideoID:(NSString *)videoID
                                    duration:(double)duration
                                  sourceLang:(NSString *)source
                                  targetLang:(NSString *)target
                                   voiceType:(NSString *)voiceType
                                   secretKey:(NSString *)secretKey
                                        uuid:(NSString *)uuid
                                     isRetry:(BOOL)isRetry
                                  completion:(YTKACEVOTCompletion)completion {
    NSString *videoURL = [NSString stringWithFormat:@"https://youtu.be/%@", videoID];
    double safeDuration = duration > 0.0 ? duration : 310.0;
    BOOL useLivelyVoice = [voiceType isEqualToString:@"live"];

    NSMutableData *bodyData = [NSMutableData data];
    VOTAppendString(bodyData, 3, videoURL);
    VOTAppendBool(bodyData, 5, !isRetry);
    VOTAppendDouble(bodyData, 6, safeDuration);
    VOTAppendBool(bodyData, 7, YES);
    VOTAppendString(bodyData, 8, source);
    VOTAppendBool(bodyData, 9, NO);
    VOTAppendBool(bodyData, 10, NO);
    VOTAppendString(bodyData, 14, target);
    VOTAppendBool(bodyData, 15, YES);
    VOTAppendInt32(bodyData, 16, 2);
    VOTAppendBool(bodyData, 18, useLivelyVoice);

    NSString *path = @"/video-translation/translate";
    NSString *token = [NSString stringWithFormat:@"%@:%@:%@", uuid, path, kYandexVOTComponentVersion];
    NSString *tokenSignature = [self hmacSHA256HexForString:token];
    NSString *bodySignature = [self hmacSHA256HexForData:bodyData];

    NSMutableURLRequest *transReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kYandexVOTHost stringByAppendingString:path]]];
    transReq.HTTPMethod = @"POST";
    transReq.HTTPBody = bodyData;
    [transReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [transReq setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [transReq setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [transReq setValue:bodySignature forHTTPHeaderField:@"Vtrans-Signature"];
    [transReq setValue:secretKey forHTTPHeaderField:@"Sec-Vtrans-Sk"];
    [transReq setValue:[NSString stringWithFormat:@"%@:%@", tokenSignature, token] forHTTPHeaderField:@"Sec-Vtrans-Token"];
    NSString *yandexToken = [[self class] currentYandexToken];
    if (yandexToken.length > 0) {
        [transReq setValue:[NSString stringWithFormat:@"OAuth %@", yandexToken] forHTTPHeaderField:@"Authorization"];
    }

    YTKACEVOTLog(@"Client", @"POST /video-translation/translate: videoID=%@, duration=%.1f, source=%@, target=%@, voiceType=%@ (lively=%d), isRetry=%d", videoID, safeDuration, source, target, voiceType, useLivelyVoice, isRetry);

    [[self.session dataTaskWithRequest:transReq completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResp.statusCode;

        if (error != nil || data.length == 0) {
            YTKACEVOTLog(@"Client", @"Translation HTTP request failed: code=%ld, error=%@", (long)statusCode, error.localizedDescription);
            completion(nil, error ?: [NSError errorWithDomain:@"YTKACEVOT" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Empty translation response"}]);
            return;
        }

        YTKACEVOTResponse *votResponse = [self parseTranslationResponseData:data];
        YTKACEVOTLog(@"Client", @"Translation response: HTTP=%ld, status=%ld, remainingTime=%ld, transID=%@, msg=%@, audioURL=%@", (long)statusCode, (long)votResponse.status, (long)votResponse.remainingTime, votResponse.translationID ?: @"-", votResponse.message ?: @"-", votResponse.audioURL.length > 0 ? votResponse.audioURL : @"(none)");

        // Check if lively voice failed or is unsupported -> automatic fallback to standard voice
        BOOL isLivelyError = useLivelyVoice && (votResponse.status == YTKACEVOTStatusSessionRequired ||
                                                votResponse.status == YTKACEVOTStatusFailed ||
            (votResponse.message.length > 0 && ([votResponse.message.lowercaseString containsString:@"обычная озвучка"] ||
                                                [votResponse.message.lowercaseString containsString:@"недоступн"] ||
                                                [votResponse.message.lowercaseString containsString:@"ошибка"])));
        if (isLivelyError && !isRetry) {
            YTKACEVOTLog(@"Client", @"Live voices unavailable or failed for this video (status=%ld, msg=%@). Falling back to standard voices...", (long)votResponse.status, votResponse.message ?: @"-");
            [self requestTranslationInternalForVideoID:videoID
                                              duration:safeDuration
                                            sourceLang:source
                                            targetLang:target
                                             voiceType:@"standard"
                                             secretKey:secretKey
                                                  uuid:uuid
                                               isRetry:YES
                                            completion:completion];
            return;
        }

        // Handle AudioRequested (status 6)
        if (votResponse.status == YTKACEVOTStatusAudioRequested && !isRetry && votResponse.translationID.length > 0) {
            YTKACEVOTLog(@"Client", @"Status 6 (AUDIO_REQUESTED). Starting audio fallback handshake...");
            [self sendAudioFallbackForVideoID:videoID
                                translationID:votResponse.translationID
                                    secretKey:secretKey
                                         uuid:uuid
                                   completion:^{
                [self requestTranslationInternalForVideoID:videoID
                                                  duration:safeDuration
                                                sourceLang:source
                                                targetLang:target
                                                 voiceType:voiceType
                                                 secretKey:secretKey
                                                      uuid:uuid
                                                   isRetry:YES
                                                completion:completion];
            }];
            return;
        }

        if (votResponse.status == YTKACEVOTStatusFinished && votResponse.audioURL.length > 0) {
            NSString *cacheKey = [NSString stringWithFormat:@"%@_%@_%@_%@", videoID, source, target, voiceType];
            [self.cache setObject:votResponse forKey:cacheKey];
            YTKACEVOTLog(@"Client", @"Cached finished translation for key: %@", cacheKey);
        }
        completion(votResponse, nil);
    }] resume];
}

- (void)requestTranslationForVideoID:(NSString *)videoID
                            duration:(double)duration
                          sourceLang:(NSString * _Nullable)sourceLang
                          targetLang:(NSString * _Nullable)targetLang
                          completion:(YTKACEVOTCompletion)completion {
    [self requestTranslationForVideoID:videoID
                              duration:duration
                            sourceLang:sourceLang
                            targetLang:targetLang
                             voiceType:nil
                            completion:completion];
}

- (void)requestTranslationForVideoID:(NSString *)videoID
                            duration:(double)duration
                          sourceLang:(NSString * _Nullable)sourceLang
                          targetLang:(NSString * _Nullable)targetLang
                           voiceType:(NSString * _Nullable)voiceType
                          completion:(YTKACEVOTCompletion)completion {
    if (videoID.length == 0) {
        completion(nil, [NSError errorWithDomain:@"YTKACEVOT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid video ID"}]);
        return;
    }

    NSString *target = (targetLang.length > 0) ? targetLang : @"ru";
    NSString *source = sourceLang;
    if (source.length == 0 || [source isEqualToString:@"auto"]) {
        if ([target isEqualToString:@"ru"] || [target isEqualToString:@"kk"]) {
            source = @"en";
        } else {
            source = @"ru";
        }
    }

    NSString *voice = (voiceType.length > 0) ? voiceType : @"standard";
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@_%@_%@", videoID, source, target, voice];
    YTKACEVOTResponse *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil && cached.audioURL.length > 0) {
        YTKACEVOTLog(@"Client", @"Returning cached translation response for %@", cacheKey);
        completion(cached, nil);
        return;
    }

    [self ensureSessionWithCompletion:^(NSString * _Nullable secretKey, NSString * _Nullable uuid, NSError * _Nullable sessionError) {
        if (sessionError != nil) {
            YTKACEVOTLog(@"Client", @"Session error: %@", sessionError.localizedDescription);
            completion(nil, sessionError);
            return;
        }

        [self requestTranslationInternalForVideoID:videoID
                                          duration:duration
                                        sourceLang:source
                                        targetLang:target
                                         voiceType:voice
                                         secretKey:secretKey
                                              uuid:uuid
                                           isRetry:NO
                                        completion:completion];
    }];
}

- (YTKACEVOTResponse *)parseTranslationResponseData:(NSData *)data {
    YTKACEVOTResponse *resp = [[YTKACEVOTResponse alloc] init];
    resp.status = YTKACEVOTStatusFailed;
    resp.remainingTime = -1;

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    NSUInteger idx = 0;

    while (idx < len) {
        uint64_t tag = 0;
        int shift = 0;
        while (idx < len) {
            uint8_t b = bytes[idx++];
            tag |= (uint64_t)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        uint32_t fieldNum = (uint32_t)(tag >> 3);
        uint32_t wireType = (uint32_t)(tag & 7);

        if (wireType == 2) {
            uint64_t strLen = 0;
            shift = 0;
            while (idx < len) {
                uint8_t b = bytes[idx++];
                strLen |= (uint64_t)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (idx + strLen <= len) {
                NSString *str = [[NSString alloc] initWithBytes:&bytes[idx] length:strLen encoding:NSUTF8StringEncoding];
                if (fieldNum == 1) resp.audioURL = str;
                else if (fieldNum == 7) resp.translationID = str;
                else if (fieldNum == 8) resp.detectedLanguage = str;
                else if (fieldNum == 9) resp.message = str;
                idx += strLen;
            }
        } else if (wireType == 0) {
            uint64_t val = 0;
            shift = 0;
            while (idx < len) {
                uint8_t b = bytes[idx++];
                val |= (uint64_t)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (fieldNum == 4) resp.status = (YTKACEVOTStatus)val;
            else if (fieldNum == 5) resp.remainingTime = (NSInteger)val;
        } else if (wireType == 1) {
            idx += 8;
        } else if (wireType == 5) {
            idx += 4;
        }
    }
    return resp;
}

@end
