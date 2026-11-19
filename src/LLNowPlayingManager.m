#import "LLNowPlayingManager.h"
#import "LLCommon.h"
#import "LLLyricLine.h"
#import "LLLrclibClient.h"
#import "LLArtworkRenderer.h"
#import <UIKit/UIKit.h>

static const NSInteger kLLLineIndexUnset = -2;
static const NSInteger kLLLineIndexIntro = -1;

@interface LLNowPlayingManager ()

@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong, nullable) dispatch_source_t syncTimer;
@property (nonatomic, assign) BOOL timerRunning;

@property (nonatomic, weak, nullable) MPNowPlayingInfoCenter *activeCenter;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *latestOriginalInfo;

// Track metadata
@property (nonatomic, copy, nullable) NSString *currentTrackKey;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSUInteger trackGeneration;

// Timing anchor: currentElapsed = baseElapsedTime + (now - baseDate) * playbackRate
@property (nonatomic, assign) NSTimeInterval baseElapsedTime;
@property (nonatomic, strong, nullable) NSDate *baseDate;
@property (nonatomic, assign) double playbackRate;

// Artwork & lyrics state
@property (nonatomic, strong, nullable) MPMediaItemArtwork *lastOriginalArtwork;
@property (nonatomic, strong, nullable) UIImage *cachedOriginalImage;
@property (nonatomic, strong, nullable) UIImage *cachedBlurredBackground;
@property (nonatomic, strong, nullable) MPMediaItemArtwork *currentRenderedArtwork;
@property (nonatomic, copy, nullable) NSArray<LLLyricLine *> *lyricLines;
@property (nonatomic, assign) NSInteger currentLineIndex;

@end

@implementation LLNowPlayingManager

+ (instancetype)sharedManager {
    static LLNowPlayingManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.locklyrics.state", DISPATCH_QUEUE_SERIAL);
        _workQueue = dispatch_queue_create("com.locklyrics.work", DISPATCH_QUEUE_SERIAL);
        _currentLineIndex = kLLLineIndexUnset;
        _playbackRate = 0.0;
        _duration = 0.0;
        _baseElapsedTime = 0.0;
        _trackGeneration = 0;
        _timerRunning = NO;
    }
    return self;
}

- (void)dealloc {
    [self stopTimerLocked];
}

#pragma mark - Public Entry Point

- (nullable NSDictionary<NSString *, id> *)handleNowPlayingInfoUpdate:(nullable NSDictionary<NSString *, id> *)nowPlayingInfo
                                                            forCenter:(MPNowPlayingInfoCenter *)center {
    __block NSDictionary<NSString *, id> *resultInfo = nowPlayingInfo;

    @try {
        dispatch_sync(self.stateQueue, ^{
            self.activeCenter = center;

            if (![nowPlayingInfo isKindOfClass:[NSDictionary class]] || nowPlayingInfo.count == 0) {
                [self resetStateLocked];
                resultInfo = nowPlayingInfo;
                return;
            }

            id titleObj = nowPlayingInfo[MPMediaItemPropertyTitle];
            NSString *incomingTitle = [titleObj isKindOfClass:[NSString class]] ? (NSString *)titleObj : nil;
            if (incomingTitle.length == 0) {
                [self resetStateLocked];
                resultInfo = nowPlayingInfo;
                return;
            }

            id artistObj = nowPlayingInfo[MPMediaItemPropertyArtist];
            NSString *incomingArtist = [artistObj isKindOfClass:[NSString class]] ? (NSString *)artistObj : @"";

            id durationObj = nowPlayingInfo[MPMediaItemPropertyPlaybackDuration];
            NSTimeInterval incomingDuration = [durationObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)durationObj doubleValue] : 0.0;

            id elapsedObj = nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime];
            id rateObj = nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate];
            id artworkObj = nowPlayingInfo[MPMediaItemPropertyArtwork];
            MPMediaItemArtwork *incomingArtwork = [artworkObj isKindOfClass:[MPMediaItemArtwork class]] ? (MPMediaItemArtwork *)artworkObj : nil;

            NSString *trackKey = [self makeTrackKeyWithTitle:incomingTitle artist:incomingArtist];
            BOOL isNewTrack = ![trackKey isEqualToString:self.currentTrackKey];

            // Keep a clean copy of the app's original metadata
            self.latestOriginalInfo = [nowPlayingInfo copy];

            if (isNewTrack) {
                [self handleTrackChangeLockedWithKey:trackKey
                                               title:incomingTitle
                                              artist:incomingArtist
                                            duration:incomingDuration];
            } else if (incomingDuration > 0.0 && self.duration <= 0.0) {
                self.duration = incomingDuration;
            }

            // Update timing anchor
            NSDate *now = [NSDate date];
            if ([elapsedObj isKindOfClass:[NSNumber class]]) {
                self.baseElapsedTime = MAX(0.0, [(NSNumber *)elapsedObj doubleValue]);
                self.baseDate = now;
            } else if (!self.baseDate) {
                self.baseDate = now;
            } else if ([rateObj isKindOfClass:[NSNumber class]]) {
                // Rate changed without explicit elapsed time: freeze current calculated elapsed as new anchor
                self.baseElapsedTime = [self calculatedElapsedTimeLockedAtDate:now];
                self.baseDate = now;
            }

            if ([rateObj isKindOfClass:[NSNumber class]]) {
                self.playbackRate = [(NSNumber *)rateObj doubleValue];
            } else if (isNewTrack) {
                // Default MediaPlayer playback rate when omitted on a new track
                self.playbackRate = 1.0;
            }

            // Extract and cache original artwork if a new non-synthetic artwork object arrived
            if (incomingArtwork &&
                incomingArtwork != self.currentRenderedArtwork &&
                incomingArtwork != self.lastOriginalArtwork) {
                self.lastOriginalArtwork = incomingArtwork;
                NSUInteger gen = self.trackGeneration;
                [self extractAndBlurArtworkAsync:incomingArtwork forGeneration:gen];
            }

            // Manage timer based on playbackRate and available lyrics
            [self updateTimerStateLocked];

            // If we already have lyrics for this track, check if the line index changed (e.g. after seek)
            if (self.lyricLines.count > 0) {
                NSTimeInterval elapsed = [self calculatedElapsedTimeLockedAtDate:now];
                NSInteger newIndex = [self lyricIndexForElapsedTimeLocked:elapsed];
                if (newIndex != self.currentLineIndex) {
                    NSUInteger gen = self.trackGeneration;
                    [self scheduleRenderForLineIndexLocked:newIndex generation:gen];
                }

                // Preserve currently rendered lyric artwork to prevent album cover flicker on pause/seek
                if (self.currentRenderedArtwork && self.currentLineIndex >= 0) {
                    NSMutableDictionary *patched = [nowPlayingInfo mutableCopy];
                    patched[MPMediaItemPropertyArtwork] = self.currentRenderedArtwork;
                    resultInfo = [patched copy];
                }
            }
        });
    } @catch (NSException *exception) {
        LLLog(@"Exception in handleNowPlayingInfoUpdate: %@", exception);
        resultInfo = nowPlayingInfo;
    }

    return resultInfo;
}

#pragma mark - State Management (Must be called on stateQueue)

- (NSString *)makeTrackKeyWithTitle:(NSString *)title artist:(NSString *)artist {
    NSString *t = [[title lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *a = [[artist lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    return [NSString stringWithFormat:@"%@|%@", t, a];
}

- (void)resetStateLocked {
    [self stopTimerLocked];
    [[LLLrclibClient sharedClient] cancelCurrentFetch];

    self.trackGeneration += 1;
    self.currentTrackKey = nil;
    self.title = nil;
    self.artist = nil;
    self.duration = 0.0;
    self.baseElapsedTime = 0.0;
    self.baseDate = nil;
    self.playbackRate = 0.0;
    self.latestOriginalInfo = nil;

    self.lastOriginalArtwork = nil;
    self.cachedOriginalImage = nil;
    self.cachedBlurredBackground = nil;
    self.currentRenderedArtwork = nil;
    self.lyricLines = nil;
    self.currentLineIndex = kLLLineIndexUnset;
}

- (void)handleTrackChangeLockedWithKey:(NSString *)trackKey
                                 title:(NSString *)title
                                artist:(NSString *)artist
                              duration:(NSTimeInterval)duration {
    [self stopTimerLocked];
    [[LLLrclibClient sharedClient] cancelCurrentFetch];

    self.trackGeneration += 1;
    NSUInteger gen = self.trackGeneration;

    self.currentTrackKey = trackKey;
    self.title = title;
    self.artist = artist;
    self.duration = duration;
    self.baseElapsedTime = 0.0;
    self.baseDate = [NSDate date];

    self.lastOriginalArtwork = nil;
    self.cachedOriginalImage = nil;
    self.cachedBlurredBackground = nil;
    self.currentRenderedArtwork = nil;
    self.lyricLines = nil;
    self.currentLineIndex = kLLLineIndexUnset;

    LLLog(@"Track changed -> Title: '%@' | Artist: '%@' | Duration: %.1fs", title, artist, duration);

    __weak typeof(self) weakSelf = self;
    [[LLLrclibClient sharedClient] fetchSyncedLyricsForTitle:title
                                                      artist:artist
                                                    duration:duration
                                                  completion:^(NSArray<LLLyricLine *> * _Nullable lines) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        dispatch_async(strongSelf.stateQueue, ^{
            if (strongSelf.trackGeneration != gen) {
                return;
            }

            if (lines.count == 0) {
                LLLog(@"Lyrics unavailable for '%@'; keeping original artwork.", title);
                return;
            }

            strongSelf.lyricLines = lines;
            strongSelf.currentLineIndex = kLLLineIndexUnset;
            LLLog(@"Loaded %lu synced lyric lines for '%@'", (unsigned long)lines.count, title);

            [strongSelf updateTimerStateLocked];
            [strongSelf evaluateCurrentLyricLineLocked];
        });
    }];
}

- (NSTimeInterval)calculatedElapsedTimeLockedAtDate:(NSDate *)now {
    if (!self.baseDate) {
        return self.baseElapsedTime;
    }
    NSTimeInterval delta = [now timeIntervalSinceDate:self.baseDate];
    if (delta < 0.0) {
        delta = 0.0;
    }
    NSTimeInterval elapsed = self.baseElapsedTime + (delta * self.playbackRate);
    if (self.duration > 0.0 && elapsed > self.duration) {
        elapsed = self.duration;
    }
    if (elapsed < 0.0) {
        elapsed = 0.0;
    }
    return elapsed;
}

- (NSInteger)lyricIndexForElapsedTimeLocked:(NSTimeInterval)elapsed {
    NSArray<LLLyricLine *> *lines = self.lyricLines;
    NSUInteger count = lines.count;
    if (count == 0) {
        return kLLLineIndexUnset;
    }

    if (elapsed < lines[0].timestamp) {
        return kLLLineIndexIntro;
    }

    // Binary search for the last line with timestamp <= elapsed
    NSUInteger low = 0;
    NSUInteger high = count - 1;
    NSUInteger best = 0;

    while (low <= high) {
        NSUInteger mid = low + ((high - low) / 2);
        if (lines[mid].timestamp <= elapsed) {
            best = mid;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    return (NSInteger)best;
}

#pragma mark - Timer Management (Must be called on stateQueue)

- (void)updateTimerStateLocked {
    BOOL shouldRun = (self.playbackRate > 0.0 && self.lyricLines.count > 0);
    if (shouldRun && !self.timerRunning) {
        [self startTimerLocked];
    } else if (!shouldRun && self.timerRunning) {
        [self stopTimerLocked];
    }
}

- (void)startTimerLocked {
    [self stopTimerLocked];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    if (!timer) {
        return;
    }

    uint64_t intervalNs = (uint64_t)(kLLTimerInterval * NSEC_PER_SEC);
    uint64_t leewayNs = (uint64_t)(0.05 * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, intervalNs), intervalNs, leewayNs);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf evaluateCurrentLyricLineLocked];
    });

    self.syncTimer = timer;
    self.timerRunning = YES;
    dispatch_resume(timer);
}

- (void)stopTimerLocked {
    if (self.syncTimer) {
        dispatch_source_cancel(self.syncTimer);
        self.syncTimer = nil;
    }
    self.timerRunning = NO;
}

- (void)evaluateCurrentLyricLineLocked {
    if (self.lyricLines.count == 0) {
        return;
    }

    NSTimeInterval elapsed = [self calculatedElapsedTimeLockedAtDate:[NSDate date]];
    NSInteger newIndex = [self lyricIndexForElapsedTimeLocked:elapsed];

    if (newIndex == self.currentLineIndex) {
        return;
    }

    NSUInteger gen = self.trackGeneration;
    [self scheduleRenderForLineIndexLocked:newIndex generation:gen];
}

#pragma mark - Artwork Extraction & Rendering

- (void)extractAndBlurArtworkAsync:(MPMediaItemArtwork *)artwork forGeneration:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UIImage *extracted = nil;
        @try {
            CGSize targetSize = CGSizeMake(kLLArtworkCanvasSize, kLLArtworkCanvasSize);
            UIImage *img = [artwork imageWithSize:targetSize];
            if ([img isKindOfClass:[UIImage class]] && img.size.width > 0 && img.size.height > 0) {
                extracted = img;
            }
        } @catch (NSException *exception) {
            LLLog(@"Failed to extract UIImage from MPMediaItemArtwork: %@", exception);
        }

        UIImage *blurred = [[LLArtworkRenderer sharedRenderer] createBlurredBackgroundFromImage:extracted];

        dispatch_async(strongSelf.stateQueue, ^{
            if (strongSelf.trackGeneration != generation) {
                return;
            }
            strongSelf.cachedOriginalImage = extracted;
            strongSelf.cachedBlurredBackground = blurred;

            // If we are already showing a lyric line, re-render with the newly available blurred album cover
            if (strongSelf.lyricLines.count > 0 && strongSelf.currentLineIndex >= 0) {
                [strongSelf scheduleRenderForLineIndexLocked:strongSelf.currentLineIndex generation:generation];
            }
        });
    });
}

- (void)scheduleRenderForLineIndexLocked:(NSInteger)lineIndex generation:(NSUInteger)generation {
    self.currentLineIndex = lineIndex;

    // Before the first lyric line (intro): keep original album cover
    if (lineIndex < 0) {
        self.currentRenderedArtwork = nil;
        return;
    }

    NSArray<LLLyricLine *> *lines = self.lyricLines;
    if ((NSUInteger)lineIndex >= lines.count) {
        return;
    }

    NSString *prevText = (lineIndex > 0) ? lines[(NSUInteger)(lineIndex - 1)].text : nil;
    NSString *currText = lines[(NSUInteger)lineIndex].text;
    NSString *nextText = ((NSUInteger)(lineIndex + 1) < lines.count) ? lines[(NSUInteger)(lineIndex + 1)].text : nil;

    UIImage *background = self.cachedBlurredBackground;
    UIImage *originalImg = self.cachedOriginalImage;

    LLLog(@"Line switch [%ld/%lu]: %@",
          (long)(lineIndex + 1),
          (unsigned long)lines.count,
          currText.length > 0 ? currText : @"(instrumental)");

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UIImage *bgToUse = background;
        if (!bgToUse) {
            bgToUse = [[LLArtworkRenderer sharedRenderer] createBlurredBackgroundFromImage:originalImg];
            dispatch_async(strongSelf.stateQueue, ^{
                if (strongSelf.trackGeneration == generation && !strongSelf.cachedBlurredBackground) {
                    strongSelf.cachedBlurredBackground = bgToUse;
                }
            });
        }

        UIImage *rendered = [[LLArtworkRenderer sharedRenderer] renderLyricsImageWithBackground:bgToUse
                                                                                   previousLine:prevText
                                                                                    currentLine:currText
                                                                                       nextLine:nextText];
        if (!rendered) {
            return;
        }

        MPMediaItemArtwork *newArtwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(kLLArtworkCanvasSize, kLLArtworkCanvasSize)
                                                                         requestHandler:^UIImage * _Nonnull(CGSize size) {
            return rendered;
        }];

        dispatch_async(strongSelf.stateQueue, ^{
            if (strongSelf.trackGeneration != generation || strongSelf.currentLineIndex != lineIndex) {
                return;
            }

            MPNowPlayingInfoCenter *center = strongSelf.activeCenter ?: [MPNowPlayingInfoCenter defaultCenter];
            NSDictionary<NSString *, id> *baseInfo = strongSelf.latestOriginalInfo;
            if (!center || !baseInfo) {
                return;
            }

            strongSelf.currentRenderedArtwork = newArtwork;

            NSMutableDictionary<NSString *, id> *updatedInfo = [baseInfo mutableCopy];
            updatedInfo[MPMediaItemPropertyArtwork] = newArtwork;
            // Keep scrubber accurate when pushing updated artwork
            NSTimeInterval currentElapsed = [strongSelf calculatedElapsedTimeLockedAtDate:[NSDate date]];
            updatedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(currentElapsed);
            updatedInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(strongSelf.playbackRate);

            NSDictionary<NSString *, id> *finalInfo = [updatedInfo copy];

            dispatch_async(dispatch_get_main_queue(), ^{
                LLApplyNowPlayingInfoSafely(center, finalInfo);
            });
        });
    });
}

@end
