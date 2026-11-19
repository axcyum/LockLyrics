#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "LLCommon.h"
#import "LLNowPlayingManager.h"

// Thread-local re-entrancy guard to prevent infinite recursion when we update nowPlayingInfo ourselves.
static __thread BOOL tLLIsUpdatingNowPlaying = NO;

@interface MPNowPlayingInfoCenter (LockLyricsSwizzle)
- (void)ll_setNowPlayingInfo:(nullable NSDictionary<NSString *, id> *)nowPlayingInfo;
@end

@implementation MPNowPlayingInfoCenter (LockLyricsSwizzle)

- (void)ll_setNowPlayingInfo:(nullable NSDictionary<NSString *, id> *)nowPlayingInfo {
    if (tLLIsUpdatingNowPlaying) {
        [self ll_setNowPlayingInfo:nowPlayingInfo];
        return;
    }

    NSDictionary<NSString *, id> *forwardedInfo = nowPlayingInfo;
    @try {
        forwardedInfo = [[LLNowPlayingManager sharedManager] handleNowPlayingInfoUpdate:nowPlayingInfo
                                                                              forCenter:self];
    } @catch (NSException *exception) {
        LLLog(@"Exception in ll_setNowPlayingInfo: %@", exception);
        forwardedInfo = nowPlayingInfo;
    }

    tLLIsUpdatingNowPlaying = YES;
    @try {
        [self ll_setNowPlayingInfo:forwardedInfo];
    } @finally {
        tLLIsUpdatingNowPlaying = NO;
    }
}

@end

void LLApplyNowPlayingInfoSafely(MPNowPlayingInfoCenter *center,
                                 NSDictionary<NSString *, id> * _Nullable info) {
    if (!center) {
        return;
    }

    tLLIsUpdatingNowPlaying = YES;
    @try {
        [center setNowPlayingInfo:info];
    } @catch (NSException *exception) {
        LLLog(@"Exception applying updated nowPlayingInfo: %@", exception);
    } @finally {
        tLLIsUpdatingNowPlaying = NO;
    }
}

__attribute__((constructor))
static void LLLockLyricsInit(void) {
    @autoreleasepool {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            @try {
                Class targetClass = [MPNowPlayingInfoCenter class];
                if (!targetClass) {
                    LLLog(@"Failed to locate MPNowPlayingInfoCenter class.");
                    return;
                }

                SEL originalSelector = @selector(setNowPlayingInfo:);
                SEL swizzledSelector = @selector(ll_setNowPlayingInfo:);

                Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
                Method swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector);

                if (!originalMethod || !swizzledMethod) {
                    LLLog(@"Failed to find methods for swizzling setNowPlayingInfo:");
                    return;
                }

                BOOL didAddMethod = class_addMethod(targetClass,
                                                    originalSelector,
                                                    method_getImplementation(swizzledMethod),
                                                    method_getTypeEncoding(swizzledMethod));
                if (didAddMethod) {
                    class_replaceMethod(targetClass,
                                        swizzledSelector,
                                        method_getImplementation(originalMethod),
                                        method_getTypeEncoding(originalMethod));
                } else {
                    method_exchangeImplementations(originalMethod, swizzledMethod);
                }

                LLLog(@"Initialized successfully (zero-dependency ObjC runtime swizzle active).");
            } @catch (NSException *exception) {
                LLLog(@"Initialization exception: %@", exception);
            }
        });
    }
}
