#import "AVCaptureMovieFileOutputExceptionBridge.h"

@implementation AVCaptureMovieFileOutputExceptionBridge

+ (BOOL)startRecordingWithOutput:(AVCaptureMovieFileOutput *)output
                       outputURL:(NSURL *)outputURL
               recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
                           error:(NSError *_Nullable *_Nullable)error {
  @try {
    [output startRecordingToOutputFileURL:outputURL recordingDelegate:delegate];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      // The connection state is captured here rather than at the call site
      // because it is the thing that explains the refusal, and by the time a
      // Swift caller sees the error the graph may already have changed.
      AVCaptureConnection *videoConnection = [output connectionWithMediaType:AVMediaTypeVideo];
      *error = [NSError
          errorWithDomain:@"Clingfy.AVCaptureMovieFileOutputExceptionBridge"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"The camera refused to start recording. Reconnect the camera or pick a "
                       @"different one, then try again.",
                   @"exceptionName" : exception.name ?: @"NSException",
                   @"exceptionReason" : exception.reason ?: @"",
                   @"outputURL" : outputURL.path ?: @"",
                   @"outputIsRecording" : @(output.isRecording),
                   @"hasVideoConnection" : @(videoConnection != nil),
                   @"videoConnectionActive" : @(videoConnection.isActive),
                   @"videoConnectionEnabled" : @(videoConnection.isEnabled),
                   @"connectionCount" : @(output.connections.count),
                 }];
    }
    return NO;
  }
}

+ (BOOL)pauseRecordingWithOutput:(AVCaptureMovieFileOutput *)output
                           error:(NSError *_Nullable *_Nullable)error {
  @try {
    [output pauseRecording];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error = [self errorForException:exception output:output code:2 action:@"pause"];
    }
    return NO;
  }
}

+ (BOOL)resumeRecordingWithOutput:(AVCaptureMovieFileOutput *)output
                            error:(NSError *_Nullable *_Nullable)error {
  @try {
    [output resumeRecording];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error = [self errorForException:exception output:output code:3 action:@"resume"];
    }
    return NO;
  }
}

+ (NSError *)errorForException:(NSException *)exception
                        output:(AVCaptureMovieFileOutput *)output
                          code:(NSInteger)code
                        action:(NSString *)action {
  return [NSError
      errorWithDomain:@"Clingfy.AVCaptureMovieFileOutputExceptionBridge"
                 code:code
             userInfo:@{
               NSLocalizedDescriptionKey :
                   [NSString stringWithFormat:@"The camera refused to %@ recording.", action],
               @"exceptionName" : exception.name ?: @"NSException",
               @"exceptionReason" : exception.reason ?: @"",
               @"outputIsRecording" : @(output.isRecording),
               @"outputIsRecordingPaused" : @(output.isRecordingPaused),
             }];
}

@end
