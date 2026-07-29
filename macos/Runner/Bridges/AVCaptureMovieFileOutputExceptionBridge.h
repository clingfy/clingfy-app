#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C shim so an `AVCaptureMovieFileOutput` rejection becomes a Swift
/// error instead of terminating the process.
///
/// `-startRecordingToOutputFileURL:recordingDelegate:` raises an
/// `NSException` when the capture graph is not in a state it accepts — the
/// session not running, no active video connection, the output not attached.
/// Swift cannot catch Objective-C exceptions, so the raise reaches the
/// terminate handler and calls `abort()`: a hard crash on the main thread,
/// straight out of a "start recording" tap.
///
/// Observed in the field on macOS 26.1: a camera was hot-plugged and selected
/// about ten seconds before recording started, and the first segment start
/// aborted the app.
@interface AVCaptureMovieFileOutputExceptionBridge : NSObject

/// Starts a recording, converting any raised exception into `error`.
///
/// Returns `NO` and populates `error` if AVFoundation refused. The delegate is
/// never invoked in that case, so callers must treat `NO` as a terminal start
/// failure rather than waiting for a callback that will not arrive.
+ (BOOL)startRecordingWithOutput:(AVCaptureMovieFileOutput *)output
                       outputURL:(NSURL *)outputURL
               recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
                           error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(startRecording(output:outputURL:recordingDelegate:));

@end

NS_ASSUME_NONNULL_END
