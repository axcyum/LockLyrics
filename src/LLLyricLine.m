#import "LLLyricLine.h"

@implementation LLLyricLine

- (instancetype)initWithTimestamp:(NSTimeInterval)timestamp text:(NSString *)text {
    self = [super init];
    if (self) {
        _timestamp = timestamp;
        _text = [text copy] ?: @"";
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<LLLyricLine %.2fs: %@>", self.timestamp, self.text];
}

@end
