#import "LLArtworkRenderer.h"
#import "LLCommon.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

@interface LLArtworkRenderer ()

@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) UIGraphicsImageRendererFormat *rendererFormat;

@end

@implementation LLArtworkRenderer

+ (instancetype)sharedRenderer {
    static LLArtworkRenderer *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Software/GPU hybrid CIContext with caching disabled to keep background memory low
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextCacheIntermediates: @(NO)
        };
        _ciContext = [CIContext contextWithOptions:options];

        _rendererFormat = [UIGraphicsImageRendererFormat defaultFormat];
        _rendererFormat.scale = 1.0;
        _rendererFormat.opaque = YES;
    }
    return self;
}

- (UIImage *)aspectFillImage:(UIImage *)source toSize:(CGSize)targetSize {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:self.rendererFormat];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        CGSize srcSize = source.size;
        if (srcSize.width <= 0 || srcSize.height <= 0) {
            return;
        }
        CGFloat scale = MAX(targetSize.width / srcSize.width, targetSize.height / srcSize.height);
        CGFloat drawWidth = srcSize.width * scale;
        CGFloat drawHeight = srcSize.height * scale;
        CGFloat drawX = (targetSize.width - drawWidth) * 0.5;
        CGFloat drawY = (targetSize.height - drawHeight) * 0.5;
        [source drawInRect:CGRectMake(drawX, drawY, drawWidth, drawHeight)];
    }];
}

- (UIImage *)createDarkGradientBackgroundOfSize:(CGSize)size {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:self.rendererFormat];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        CGContextRef cgCtx = ctx.CGContext;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (!colorSpace) {
            [[UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1.0] setFill];
            CGContextFillRect(cgCtx, CGRectMake(0, 0, size.width, size.height));
            return;
        }

        NSArray *colors = @[
            (__bridge id)[UIColor colorWithRed:0.14 green:0.16 blue:0.22 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0].CGColor
        ];
        CGFloat locations[] = { 0.0, 0.55, 1.0 };
        CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, locations);
        if (gradient) {
            CGContextDrawLinearGradient(cgCtx,
                                        gradient,
                                        CGPointMake(0, 0),
                                        CGPointMake(size.width, size.height),
                                        0);
            CGGradientRelease(gradient);
        }
        CGColorSpaceRelease(colorSpace);
    }];
}

- (UIImage *)createBlurredBackgroundFromImage:(nullable UIImage *)originalImage {
    CGSize canvasSize = CGSizeMake(kLLArtworkCanvasSize, kLLArtworkCanvasSize);
    CGRect canvasRect = CGRectMake(0, 0, canvasSize.width, canvasSize.height);

    @autoreleasepool {
        @try {
            if (!originalImage || originalImage.size.width <= 0 || originalImage.size.height <= 0) {
                return [self createDarkGradientBackgroundOfSize:canvasSize];
            }

            // Downscale/crop to 600x600 first to minimize memory and blur cost
            UIImage *normalized = [self aspectFillImage:originalImage toSize:canvasSize];
            CIImage *ciInput = [[CIImage alloc] initWithImage:normalized];
            if (!ciInput) {
                return [self createDarkGradientBackgroundOfSize:canvasSize];
            }

            // Clamp edges so Gaussian blur doesn't bleed transparent borders
            CIFilter *clampFilter = [CIFilter filterWithName:@"CIAffineClamp"];
            [clampFilter setValue:ciInput forKey:kCIInputImageKey];
            [clampFilter setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:kCIInputTransformKey];
            CIImage *clampedImage = clampFilter.outputImage ?: ciInput;

            // Apply Gaussian blur
            CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
            [blurFilter setValue:clampedImage forKey:kCIInputImageKey];
            [blurFilter setValue:@(22.0) forKey:kCIInputRadiusKey];
            CIImage *blurredCI = blurFilter.outputImage;

            UIImage *blurredUIImage = nil;
            if (blurredCI) {
                CGImageRef cgImage = [self.ciContext createCGImage:blurredCI fromRect:canvasRect];
                if (cgImage) {
                    blurredUIImage = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
                    CGImageRelease(cgImage);
                }
            }

            if (!blurredUIImage) {
                blurredUIImage = normalized;
            }

            // Composite dark translucent overlay for high lyric contrast
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:self.rendererFormat];
            return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
                [blurredUIImage drawInRect:canvasRect];

                CGContextRef cgCtx = ctx.CGContext;
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                if (colorSpace) {
                    NSArray *overlayColors = @[
                        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.50].CGColor,
                        (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.60].CGColor
                    ];
                    CGFloat locations[] = { 0.0, 1.0 };
                    CGGradientRef overlayGradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)overlayColors, locations);
                    if (overlayGradient) {
                        CGContextDrawLinearGradient(cgCtx,
                                                    overlayGradient,
                                                    CGPointMake(0, 0),
                                                    CGPointMake(0, canvasSize.height),
                                                    0);
                        CGGradientRelease(overlayGradient);
                    }
                    CGColorSpaceRelease(colorSpace);
                } else {
                    [[UIColor colorWithWhite:0.0 alpha:0.55] setFill];
                    CGContextFillRect(cgCtx, canvasRect);
                }
            }];
        } @catch (NSException *exception) {
            LLLog(@"Error creating blurred background: %@", exception);
            return [self createDarkGradientBackgroundOfSize:canvasSize];
        }
    }
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesWithFont:(UIFont *)font
                                                         color:(UIColor *)color
                                                     lineBreak:(NSLineBreakMode)lineBreak
                                                  shadowOpacity:(CGFloat)shadowOpacity
                                                   shadowRadius:(CGFloat)shadowRadius {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = lineBreak;
    paragraph.lineSpacing = 6.0;

    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:shadowOpacity];
    shadow.shadowOffset = CGSizeMake(0.0, 2.0);
    shadow.shadowBlurRadius = shadowRadius;

    return @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
        NSShadowAttributeName: shadow
    };
}

- (nullable UIImage *)renderLyricsImageWithBackground:(UIImage *)backgroundImage
                                         previousLine:(nullable NSString *)previousLine
                                          currentLine:(nullable NSString *)currentLine
                                             nextLine:(nullable NSString *)nextLine {
    if (!backgroundImage) {
        return nil;
    }

    @autoreleasepool {
        @try {
            CGSize canvasSize = CGSizeMake(kLLArtworkCanvasSize, kLLArtworkCanvasSize);
            CGRect canvasRect = CGRectMake(0, 0, canvasSize.width, canvasSize.height);

            const CGFloat horizontalPadding = 44.0;
            const CGFloat verticalMargin = 36.0;
            const CGFloat lineGap = 24.0;
            const CGFloat textWidth = canvasSize.width - (horizontalPadding * 2.0);
            const CGFloat maxCurrentHeight = 230.0;

            NSString *displayCurrent = (currentLine.length > 0) ? currentLine : @"♪";
            BOOL isInstrumentalPlaceholder = (currentLine.length == 0);

            // Auto-fit current line font size for long Japanese/English lines
            CGFloat currentFontSize = isInstrumentalPlaceholder ? 48.0 : 38.0;
            NSDictionary *currentAttrs = nil;
            CGRect currentMeasured = CGRectZero;

            if (!isInstrumentalPlaceholder) {
                NSArray<NSNumber *> *candidateSizes = @[ @(38.0), @(33.0), @(28.0) ];
                for (NSNumber *sizeNum in candidateSizes) {
                    currentFontSize = sizeNum.doubleValue;
                    UIFont *font = [UIFont boldSystemFontOfSize:currentFontSize];
                    currentAttrs = [self attributesWithFont:font
                                                      color:[UIColor whiteColor]
                                                  lineBreak:NSLineBreakByWordWrapping
                                               shadowOpacity:0.70
                                                shadowRadius:8.0];
                    currentMeasured = [displayCurrent boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                                                   options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                                                attributes:currentAttrs
                                                                   context:nil];
                    if (ceil(currentMeasured.size.height) <= maxCurrentHeight) {
                        break;
                    }
                }
            } else {
                UIFont *font = [UIFont boldSystemFontOfSize:currentFontSize];
                currentAttrs = [self attributesWithFont:font
                                                  color:[UIColor colorWithWhite:1.0 alpha:0.80]
                                              lineBreak:NSLineBreakByWordWrapping
                                           shadowOpacity:0.55
                                            shadowRadius:6.0];
                currentMeasured = [displayCurrent boundingRectWithSize:CGSizeMake(textWidth, maxCurrentHeight)
                                                               options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                                            attributes:currentAttrs
                                                               context:nil];
            }

            CGFloat currentHeight = MIN(ceil(currentMeasured.size.height), maxCurrentHeight);
            CGFloat currentY = floor((canvasSize.height - currentHeight) * 0.5);
            CGRect currentRect = CGRectMake(horizontalPadding, currentY, textWidth, currentHeight);

            UIFont *secondaryFont = [UIFont systemFontOfSize:24.0 weight:UIFontWeightMedium];
            NSDictionary *secondaryAttrs = [self attributesWithFont:secondaryFont
                                                              color:[UIColor colorWithWhite:1.0 alpha:0.46]
                                                          lineBreak:NSLineBreakByWordWrapping
                                                       shadowOpacity:0.45
                                                        shadowRadius:4.0];

            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:self.rendererFormat];
            return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
                [backgroundImage drawInRect:canvasRect];

                // Draw current lyric line (center)
                [displayCurrent drawWithRect:currentRect
                                     options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading | NSStringDrawingTruncatesLastVisibleLine)
                                  attributes:currentAttrs
                                     context:nil];

                // Draw previous lyric line (above center)
                if (previousLine.length > 0) {
                    CGFloat maxPrevHeight = MAX(0.0, CGRectGetMinY(currentRect) - lineGap - verticalMargin);
                    if (maxPrevHeight >= 28.0) {
                        CGRect prevMeasured = [previousLine boundingRectWithSize:CGSizeMake(textWidth, maxPrevHeight)
                                                                         options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                                                      attributes:secondaryAttrs
                                                                         context:nil];
                        CGFloat prevHeight = MIN(ceil(prevMeasured.size.height), maxPrevHeight);
                        CGFloat prevY = CGRectGetMinY(currentRect) - lineGap - prevHeight;
                        CGRect prevRect = CGRectMake(horizontalPadding, prevY, textWidth, prevHeight);
                        [previousLine drawWithRect:prevRect
                                           options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading | NSStringDrawingTruncatesLastVisibleLine)
                                        attributes:secondaryAttrs
                                           context:nil];
                    }
                }

                // Draw next lyric line (below center)
                if (nextLine.length > 0) {
                    CGFloat nextY = CGRectGetMaxY(currentRect) + lineGap;
                    CGFloat maxNextHeight = MAX(0.0, (canvasSize.height - verticalMargin) - nextY);
                    if (maxNextHeight >= 28.0) {
                        CGRect nextMeasured = [nextLine boundingRectWithSize:CGSizeMake(textWidth, maxNextHeight)
                                                                     options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                                                  attributes:secondaryAttrs
                                                                     context:nil];
                        CGFloat nextHeight = MIN(ceil(nextMeasured.size.height), maxNextHeight);
                        CGRect nextRect = CGRectMake(horizontalPadding, nextY, textWidth, nextHeight);
                        [nextLine drawWithRect:nextRect
                                       options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading | NSStringDrawingTruncatesLastVisibleLine)
                                    attributes:secondaryAttrs
                                       context:nil];
                    }
                }
            }];
        } @catch (NSException *exception) {
            LLLog(@"Error rendering lyrics artwork: %@", exception);
            return nil;
        }
    }
}

@end
