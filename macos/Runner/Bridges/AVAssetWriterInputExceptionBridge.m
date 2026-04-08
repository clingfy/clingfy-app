#import "AVAssetWriterInputExceptionBridge.h"

@implementation AVAssetWriterInputExceptionBridge

+ (nullable AVAssetWriterInput *)makeVideoWriterInputWithMediaType:(AVMediaType)mediaType
                                                    outputSettings:(NSDictionary<NSString *, id> *)outputSettings
                                                  sourceFormatHint:(CMFormatDescriptionRef _Nullable)sourceFormatHint
                                                             error:(NSError * _Nullable * _Nullable)error {
  @try {
    return [[AVAssetWriterInput alloc] initWithMediaType:mediaType
                                          outputSettings:outputSettings
                                        sourceFormatHint:sourceFormatHint];
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:@"Clingfy.AVAssetWriterInputExceptionBridge"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"AVAssetWriterInput rejected the export settings.",
                   @"exceptionName" : exception.name ?: @"NSException",
                   @"exceptionReason" : exception.reason ?: @"",
                   @"settingTypes" : [self summarizedSettingTypesFromValue:outputSettings],
                 }];
    }
    return nil;
  }
}

+ (id)summarizedSettingTypesFromValue:(id)value {
  if (value == nil || value == (id)kCFNull) {
    return @"nil";
  }

  if ([value isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dictionary = (NSDictionary *)value;
    NSMutableDictionary<NSString *, id> *summary = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
    for (id key in dictionary) {
      summary[[key description]] = [self summarizedSettingTypesFromValue:dictionary[key]];
    }
    return summary;
  }

  if ([value isKindOfClass:[NSArray class]]) {
    NSArray *array = (NSArray *)value;
    NSMutableArray<id> *summary = [NSMutableArray arrayWithCapacity:array.count];
    for (id element in array) {
      [summary addObject:[self summarizedSettingTypesFromValue:element]];
    }
    return summary;
  }

  return NSStringFromClass([value class]);
}

@end
