#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LLLyricLine : NSObject

@property (nonatomic, assign, readonly) NSTimeInterval timestamp;
@property (nonatomic, copy, readonly) NSString *text;

- (instancetype)initWithTimestamp:(NSTimeInterval)timestamp text:(NSString *)text NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
