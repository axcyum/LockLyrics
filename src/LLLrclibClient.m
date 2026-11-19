#import "LLLrclibClient.h"
#import "LLCommon.h"
#import "LLLrcParser.h"
#import <float.h>

@interface LLLrclibClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSCache<NSString *, NSArray<LLLyricLine *> *> *memoryCache;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *activeTask;
@property (nonatomic, assign) NSUInteger fetchGeneration;

@end

@implementation LLLrclibClient

+ (instancetype)sharedClient {
    static LLLrclibClient *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 10.0;
        config.timeoutIntervalForResource = 15.0;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kLLUserAgent,
            @"Accept": @"application/json"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        _memoryCache = [[NSCache alloc] init];
        _memoryCache.countLimit = 50;
        _fetchGeneration = 0;
    }
    return self;
}

- (void)cancelCurrentFetch {
    @synchronized (self) {
        self.fetchGeneration += 1;
        if (self.activeTask) {
            [self.activeTask cancel];
            self.activeTask = nil;
        }
    }
}

- (NSString *)cacheKeyForTitle:(NSString *)title artist:(nullable NSString *)artist {
    NSString *normTitle = [[title lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *normArtist = [[artist lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    return [NSString stringWithFormat:@"%@|%@", normTitle, normArtist];
}

- (void)fetchSyncedLyricsForTitle:(NSString *)title
                           artist:(nullable NSString *)artist
                         duration:(NSTimeInterval)duration
                       completion:(LLLyricsFetchCompletion)completion {
    if (!completion) {
        return;
    }

    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        completion(nil);
        return;
    }

    NSString *safeArtist = ([artist isKindOfClass:[NSString class]] && artist.length > 0) ? artist : @"";
    NSString *cacheKey = [self cacheKeyForTitle:title artist:safeArtist];

    NSArray<LLLyricLine *> *cachedLines = [self.memoryCache objectForKey:cacheKey];
    if (cachedLines.count > 0) {
        LLLog(@"Cache hit for '%@' - '%@' (%lu lines)", title, safeArtist, (unsigned long)cachedLines.count);
        completion(cachedLines);
        return;
    }

    NSUInteger generation = 0;
    @synchronized (self) {
        self.fetchGeneration += 1;
        generation = self.fetchGeneration;
        if (self.activeTask) {
            [self.activeTask cancel];
            self.activeTask = nil;
        }
    }

    // Primary endpoint: /api/get
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://lrclib.net/api/get"];
    NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray array];
    [queryItems addObject:[NSURLQueryItem queryItemWithName:@"track_name" value:title]];
    if (safeArtist.length > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"artist_name" value:safeArtist]];
    }
    if (duration > 0.0) {
        NSInteger roundedDuration = (NSInteger)llround(duration);
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"duration" value:[NSString stringWithFormat:@"%ld", (long)roundedDuration]]];
    }
    components.queryItems = queryItems;

    NSURL *url = components.URL;
    if (!url) {
        LLLog(@"Failed to build /api/get URL for '%@'", title);
        [self fallbackSearchForTitle:title artist:safeArtist duration:duration cacheKey:cacheKey generation:generation completion:completion];
        return;
    }

    LLLog(@"Fetching lyrics (primary): %@", url.absoluteString);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        @synchronized (strongSelf) {
            if (strongSelf.fetchGeneration != generation) {
                return;
            }
        }

        if (error) {
            if (error.code == NSURLErrorCancelled) {
                return;
            }
            LLLog(@"Primary /api/get error: %@", error.localizedDescription);
            [strongSelf fallbackSearchForTitle:title artist:safeArtist duration:duration cacheKey:cacheKey generation:generation completion:completion];
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (httpResponse.statusCode == 200 && data.length > 0) {
            @try {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id syncedObj = json[@"syncedLyrics"];
                    if ([syncedObj isKindOfClass:[NSString class]] && [(NSString *)syncedObj length] > 0) {
                        NSArray<LLLyricLine *> *lines = [LLLrcParser parseLRC:(NSString *)syncedObj];
                        if (lines.count > 0) {
                            [strongSelf.memoryCache setObject:lines forKey:cacheKey];
                            LLLog(@"Fetched synced lyrics via /api/get (%lu lines) for '%@'", (unsigned long)lines.count, title);
                            completion(lines);
                            return;
                        }
                    }
                }
            } @catch (NSException *exception) {
                LLLog(@"JSON parse exception in /api/get: %@", exception);
            }
        }

        LLLog(@"Primary /api/get returned status %ld or no syncedLyrics; falling back to /api/search", (long)httpResponse.statusCode);
        [strongSelf fallbackSearchForTitle:title artist:safeArtist duration:duration cacheKey:cacheKey generation:generation completion:completion];
    }];

    @synchronized (self) {
        if (self.fetchGeneration == generation) {
            self.activeTask = task;
            [task resume];
        }
    }
}

- (void)fallbackSearchForTitle:(NSString *)title
                        artist:(NSString *)artist
                      duration:(NSTimeInterval)duration
                      cacheKey:(NSString *)cacheKey
                    generation:(NSUInteger)generation
                    completion:(LLLyricsFetchCompletion)completion {
    @synchronized (self) {
        if (self.fetchGeneration != generation) {
            return;
        }
    }

    NSString *query = artist.length > 0
        ? [NSString stringWithFormat:@"%@ %@", title, artist]
        : title;

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://lrclib.net/api/search"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query]
    ];

    NSURL *url = components.URL;
    if (!url) {
        LLLog(@"Failed to build /api/search URL for '%@'", query);
        completion(nil);
        return;
    }

    LLLog(@"Fetching lyrics (fallback): %@", url.absoluteString);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        @synchronized (strongSelf) {
            if (strongSelf.fetchGeneration != generation) {
                return;
            }
        }

        if (error) {
            if (error.code == NSURLErrorCancelled) {
                return;
            }
            LLLog(@"Fallback /api/search error: %@", error.localizedDescription);
            completion(nil);
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (httpResponse.statusCode != 200 || data.length == 0) {
            LLLog(@"Fallback /api/search failed with status %ld", (long)httpResponse.statusCode);
            completion(nil);
            return;
        }

        @try {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]]) {
                completion(nil);
                return;
            }

            NSArray *results = (NSArray *)json;
            NSString *bestSyncedLyrics = nil;
            double bestDurationDiff = DBL_MAX;

            for (id item in results) {
                if (![item isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSDictionary *dict = (NSDictionary *)item;
                id syncedObj = dict[@"syncedLyrics"];
                if (![syncedObj isKindOfClass:[NSString class]] || [(NSString *)syncedObj length] == 0) {
                    continue;
                }

                if (duration <= 0.0) {
                    bestSyncedLyrics = (NSString *)syncedObj;
                    break;
                }

                id durObj = dict[@"duration"];
                double candidateDuration = [durObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)durObj doubleValue] : 0.0;
                double diff = (candidateDuration > 0.0) ? fabs(candidateDuration - duration) : 9999.0;

                if (diff < bestDurationDiff) {
                    bestDurationDiff = diff;
                    bestSyncedLyrics = (NSString *)syncedObj;
                }
            }

            if (bestSyncedLyrics.length > 0) {
                NSArray<LLLyricLine *> *lines = [LLLrcParser parseLRC:bestSyncedLyrics];
                if (lines.count > 0) {
                    [strongSelf.memoryCache setObject:lines forKey:cacheKey];
                    LLLog(@"Fetched synced lyrics via /api/search (%lu lines, durationDiff=%.1fs) for '%@'",
                          (unsigned long)lines.count,
                          (bestDurationDiff < DBL_MAX ? bestDurationDiff : -1.0),
                          title);
                    completion(lines);
                    return;
                }
            }

            LLLog(@"No synced lyrics found for '%@' - '%@'", title, artist);
            completion(nil);
        } @catch (NSException *exception) {
            LLLog(@"JSON parse exception in /api/search: %@", exception);
            completion(nil);
        }
    }];

    @synchronized (self) {
        if (self.fetchGeneration == generation) {
            self.activeTask = task;
            [task resume];
        }
    }
}

@end
