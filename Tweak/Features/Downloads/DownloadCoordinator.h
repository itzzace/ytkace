#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIImage *YTKACEDownloadGlyphImage(void);

FOUNDATION_EXPORT void YTKACESaveVideoToPhotosFile(
    NSURL *url, void (^_Nullable completion)(BOOL success, NSError *_Nullable error));

@interface YTKACEDownloadCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, strong, nullable) id playerResponse;
- (void)showDownloadMenu;
- (void)showDownloadMenuFromButton:(nullable UIButton *)button;
- (void)showShortsDownloadMenuFromView:(UIView *)sourceView;
- (void)showDownloadMenuForResponse:(id)response
                        sourceView:(nullable UIView *)sourceView;
- (void)downloadVoiceOverAudioFromView:(nullable UIView *)sourceView;
- (NSUInteger)activeJobCount;
- (BOOL)enqueueDownloadForResponse:(id)response
                           quality:(NSInteger)quality
                         audioOnly:(BOOL)audioOnly
                      savesToPhotos:(BOOL)savesToPhotos
                        sharesFile:(BOOL)sharesFile;
- (void)beginBatchSharing;
- (void)flushBatchSharingFromView:(nullable UIView *)sourceView;
- (void)resolvePlaylistDestinationFromView:(nullable UIView *)sourceView
                                 audioOnly:(BOOL)audioOnly
                                      then:(void (^)(BOOL savesToPhotos,
                                                     BOOL sharesFile))handler;
- (NSDictionary *)nativeSheetAction:(NSString *)title
                               icon:(NSString *)icon
                            handler:(dispatch_block_t)handler;
- (void)presentPlaylistSheetWithTitle:(nullable NSString *)title
                             subtitle:(nullable NSString *)subtitle
                           sourceView:(nullable UIView *)sourceView
                              actions:(NSArray<NSDictionary *> *)actions;
@end

NS_ASSUME_NONNULL_END
