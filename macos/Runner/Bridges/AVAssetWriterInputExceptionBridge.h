#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVAssetWriterInputExceptionBridge : NSObject

+ (nullable AVAssetWriterInput *)makeVideoWriterInputWithMediaType:(AVMediaType)mediaType
                                                    outputSettings:(NSDictionary<NSString *, id> *)outputSettings
                                                  sourceFormatHint:(CMFormatDescriptionRef _Nullable)sourceFormatHint
                                                             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(makeVideoWriterInput(mediaType:outputSettings:sourceFormatHint:));

@end

NS_ASSUME_NONNULL_END
