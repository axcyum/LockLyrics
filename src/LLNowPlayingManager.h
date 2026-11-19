#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Implemented in LLTweakEntry.m to safely invoke the original setNowPlayingInfo:
/// with re-entrancy protection enabled.
FOUNDATION_EXTERN void LLApplyNowPlayingInfoSafely(MPNowPlayingInfoCenter *center,
                                                   NSDictionary<NSString *, id> * _Nullable info);

@interface LLNowPlayingManager : NSObject

+ (instancetype)sharedManager;

/// Called from the swizzled -[MPNowPlayingInfoCenter setNowPlayingInfo:].
/// Extracts metadata, detects track changes, manages the lyric sync timer,
/// and returns the dictionary to forward to the original implementation.
- (nullable NSDictionary<NSString *, id> *)handleNowPlayingInfoUpdate:(nullable NSDictionary<NSString *, id> *)nowPlayingInfo
                                                            forCenter:(MPNowPlayingInfoCenter *)center;

@end

NS_ASSUME_NONNULL_END
