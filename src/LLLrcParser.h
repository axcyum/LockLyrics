#import <Foundation/Foundation.h>
#import "LLLyricLine.h"

NS_ASSUME_NONNULL_BEGIN

@interface LLLrcParser : NSObject

/// Parses an LRC string into a timestamp-sorted array of LLLyricLine objects.
/// Returns an empty array if input is nil, empty, or contains no valid timed lines.
+ (NSArray<LLLyricLine *> *)parseLRC:(nullable NSString *)lrcString;

@end

NS_ASSUME_NONNULL_END
