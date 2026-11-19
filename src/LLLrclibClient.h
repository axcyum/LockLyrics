#import <Foundation/Foundation.h>
#import "LLLyricLine.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^LLLyricsFetchCompletion)(NSArray<LLLyricLine *> * _Nullable lines);

@interface LLLrclibClient : NSObject

+ (instancetype)sharedClient;

/// Asynchronously fetches synced lyrics for the given track from LRCLIB.
/// Completion is invoked on an arbitrary background queue with parsed lines, or nil if unavailable.
- (void)fetchSyncedLyricsForTitle:(NSString *)title
                           artist:(nullable NSString *)artist
                         duration:(NSTimeInterval)duration
                       completion:(LLLyricsFetchCompletion)completion;

/// Cancels any in-flight network request.
- (void)cancelCurrentFetch;

@end

NS_ASSUME_NONNULL_END
