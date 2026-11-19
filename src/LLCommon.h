#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifndef LL_COMMON_H
#define LL_COMMON_H

#define LLLog(fmt, ...) NSLog(@"[LockLyrics] " fmt, ##__VA_ARGS__)

static NSString * const kLLUserAgent __attribute__((unused)) = @"LockLyrics/1.0.0 (iOS Sideload Tweak; +https://lrclib.net)";
static const CGFloat kLLArtworkCanvasSize __attribute__((unused)) = 600.0;
static const NSTimeInterval kLLTimerInterval __attribute__((unused)) = 0.25;

#endif /* LL_COMMON_H */
