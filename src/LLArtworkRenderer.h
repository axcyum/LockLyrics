#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LLArtworkRenderer : NSObject

+ (instancetype)sharedRenderer;

/// Generates a 600x600 blurred + darkened background image from the original artwork,
/// or a dark gradient background if originalImage is nil.
/// Call once per track and cache the returned image.
- (UIImage *)createBlurredBackgroundFromImage:(nullable UIImage *)originalImage;

/// Renders a 600x600 lock screen artwork image with the cached background and 3-line lyrics layout.
- (nullable UIImage *)renderLyricsImageWithBackground:(UIImage *)backgroundImage
                                         previousLine:(nullable NSString *)previousLine
                                          currentLine:(nullable NSString *)currentLine
                                             nextLine:(nullable NSString *)nextLine;

@end

NS_ASSUME_NONNULL_END
