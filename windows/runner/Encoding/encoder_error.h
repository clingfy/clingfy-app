#ifndef RUNNER_ENCODING_ENCODER_ERROR_H_
#define RUNNER_ENCODING_ENCODER_ERROR_H_

#include <windows.h>  // HRESULT

#include <string>

// Shared failure type for the encoders in this folder. Both the H.264 Sink
// Writer (`MfSinkWriterEncoder`) and the Phase 6 Slice 5B WIC GIF encoder
// (`GifEncoder`) return `std::optional<EncoderError>` (std::nullopt == success)
// so the export pipeline can drive either one from a single loop.
namespace clingfy::encoding {

struct EncoderError {
  std::string message;
  HRESULT hr = 0;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_ENCODER_ERROR_H_
