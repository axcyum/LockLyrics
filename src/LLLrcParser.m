#import "LLLrcParser.h"
#import "LLCommon.h"

@implementation LLLrcParser

+ (NSArray<LLLyricLine *> *)parseLRC:(nullable NSString *)lrcString {
    if (![lrcString isKindOfClass:[NSString class]] || lrcString.length == 0) {
        return @[];
    }

    @try {
        static NSRegularExpression *timestampRegex = nil;
        static NSRegularExpression *offsetRegex = nil;
        static NSRegularExpression *inlineWordRegex = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // Matches [mm:ss.xx], [mm:ss.xxx], [mm:ss:xx], [mm:ss]
            timestampRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]"
                                                                       options:0
                                                                         error:nil];
            // Matches [offset:+500] or [offset:-250] (milliseconds)
            offsetRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[offset\\s*:\\s*([+-]?\\d+)\\]"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
            // Strips enhanced LRC inline word timestamps like <00:12.34>
            inlineWordRegex = [NSRegularExpression regularExpressionWithPattern:@"<\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?>"
                                                                        options:0
                                                                          error:nil];
        });

        if (!timestampRegex) {
            return @[];
        }

        // Normalize line breaks
        NSString *normalized = [lrcString stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
        normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        NSArray<NSString *> *rawLines = [normalized componentsSeparatedByString:@"\n"];

        NSTimeInterval offsetSeconds = 0.0;
        NSMutableArray<LLLyricLine *> *parsedLines = [NSMutableArray array];
        NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

        for (NSString *rawLine in rawLines) {
            if (rawLine.length == 0) {
                continue;
            }

            // Check optional [offset:ms] metadata tag
            if (offsetRegex) {
                NSTextCheckingResult *offsetMatch = [offsetRegex firstMatchInString:rawLine
                                                                            options:0
                                                                              range:NSMakeRange(0, rawLine.length)];
                if (offsetMatch && offsetMatch.numberOfRanges >= 2) {
                    NSRange valRange = [offsetMatch rangeAtIndex:1];
                    if (valRange.location != NSNotFound) {
                        NSInteger offsetMs = [[rawLine substringWithRange:valRange] integerValue];
                        offsetSeconds = (NSTimeInterval)offsetMs / 1000.0;
                    }
                    continue;
                }
            }

            NSArray<NSTextCheckingResult *> *matches = [timestampRegex matchesInString:rawLine
                                                                               options:0
                                                                                 range:NSMakeRange(0, rawLine.length)];
            if (matches.count == 0) {
                continue;
            }

            // Extract lyric text after the last timestamp tag
            NSTextCheckingResult *lastMatch = matches.lastObject;
            NSUInteger textStart = NSMaxRange(lastMatch.range);
            NSString *lyricText = (textStart < rawLine.length) ? [rawLine substringFromIndex:textStart] : @"";

            if (inlineWordRegex && lyricText.length > 0) {
                lyricText = [inlineWordRegex stringByReplacingMatchesInString:lyricText
                                                                      options:0
                                                                        range:NSMakeRange(0, lyricText.length)
                                                                 withTemplate:@""];
            }

            lyricText = [lyricText stringByTrimmingCharactersInSet:whitespaceSet];

            for (NSTextCheckingResult *match in matches) {
                if (match.numberOfRanges < 3) {
                    continue;
                }

                NSRange minRange = [match rangeAtIndex:1];
                NSRange secRange = [match rangeAtIndex:2];
                if (minRange.location == NSNotFound || secRange.location == NSNotFound) {
                    continue;
                }

                double minutes = [[rawLine substringWithRange:minRange] doubleValue];
                double seconds = [[rawLine substringWithRange:secRange] doubleValue];
                double fraction = 0.0;

                if (match.numberOfRanges >= 4) {
                    NSRange fracRange = [match rangeAtIndex:3];
                    if (fracRange.location != NSNotFound && fracRange.length > 0) {
                        NSString *fracStr = [rawLine substringWithRange:fracRange];
                        double fracVal = [fracStr doubleValue];
                        if (fracRange.length == 1) {
                            fraction = fracVal / 10.0;
                        } else if (fracRange.length == 2) {
                            fraction = fracVal / 100.0;
                        } else {
                            fraction = fracVal / 1000.0;
                        }
                    }
                }

                // In LRC, positive offset means lyrics appear earlier (timestamp - offset)
                NSTimeInterval totalTime = (minutes * 60.0) + seconds + fraction - offsetSeconds;
                if (totalTime < 0.0) {
                    totalTime = 0.0;
                }

                LLLyricLine *line = [[LLLyricLine alloc] initWithTimestamp:totalTime text:lyricText];
                [parsedLines addObject:line];
            }
        }

        [parsedLines sortUsingComparator:^NSComparisonResult(LLLyricLine *a, LLLyricLine *b) {
            if (a.timestamp < b.timestamp) return NSOrderedAscending;
            if (a.timestamp > b.timestamp) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        return [parsedLines copy];
    } @catch (NSException *exception) {
        LLLog(@"LRC parse exception: %@", exception);
        return @[];
    }
}

@end
