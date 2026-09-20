#include "Encoding/mf_sink_writer_encoder.h"

#include <gtest/gtest.h>

#include <optional>
#include <string>

#include "Encoding/mf_encoder_config.h"
#include "Graphics/d3d_device.h"

namespace clingfy::encoding {
namespace {

EncoderConfig ValidConfigWithPath(const std::string& output_path) {
  EncoderConfig config;
  config.output_path = output_path;
  config.width = 640;
  config.height = 360;
  config.fps = 30;
  config.avg_bitrate_bps = 2'000'000;
  return config;
}

// A failing Open must RETURN its EncoderError, never throw.
//
// `Open` holds `mutex_` for its whole body and cleans up through Cancel on five
// failure paths. Those used to call the PUBLIC `Cancel()`, which locks `mutex_`
// again — and `mutex_` is a plain `std::mutex`, so re-locking it on the same
// thread throws `std::system_error(resource_deadlock_would_occur)`. Every
// failure inside Open therefore threw instead of returning, and the exception
// escaped `RecordingEngine::Start`: a user whose encoder could not open got a
// crash instead of a refusal.
//
// An unwritable output path is the cheapest way in — it fails at
// `MFCreateSinkWriterFromURL`, the second of the five Cancel sites, after the
// D3D manager has already been opened.
TEST(MfSinkWriterEncoderOpenFailureTest, UnwritablePathReturnsAnErrorInsteadOfThrowing) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }

  MfSinkWriterEncoder encoder;
  // A directory that cannot exist, so the sink writer cannot be created.
  const auto config = ValidConfigWithPath(
      "Z:\clingfy-no-such-drive\nested\out.mp4");

  std::optional<EncoderError> error;
  ASSERT_NO_THROW({
    error = encoder.Open(config, device, std::nullopt);
  }) << "Open must not throw on a failure path";

  ASSERT_TRUE(error.has_value())
      << "an unwritable output path must be reported as an error";
  EXPECT_FALSE(encoder.open());
}

// The public Cancel still takes the lock — the split must not have moved the
// locking responsibility onto its callers.
TEST(MfSinkWriterEncoderOpenFailureTest, CancelIsSafeOnAFreshEncoder) {
  MfSinkWriterEncoder encoder;
  ASSERT_NO_THROW(encoder.Cancel());
  EXPECT_FALSE(encoder.open());
  // Idempotent: a second Cancel must not throw either.
  ASSERT_NO_THROW(encoder.Cancel());
}

}  // namespace
}  // namespace clingfy::encoding
