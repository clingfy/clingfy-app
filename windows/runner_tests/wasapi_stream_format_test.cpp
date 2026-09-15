#include "Audio/wasapi_stream_format.h"

#include <gtest/gtest.h>

#include "Audio/audio_format.h"

// The canonical format is handed straight to IAudioClient::Initialize, so a
// wrong field does not throw — it either gets the stream refused or, worse,
// gets it accepted at a shape the rest of the pipeline does not actually
// produce. These pin the values a reader would otherwise have to trust.
namespace clingfy::audio {
namespace {

TEST(CanonicalPipelineFormatTest, IsWhatTheRestOfThePipelineAssumes) {
  const WAVEFORMATEXTENSIBLE f = CanonicalPipelineFormat();
  EXPECT_EQ(f.Format.nSamplesPerSec, kPipelineSampleRateHz);
  EXPECT_EQ(f.Format.nChannels, kPipelineChannelCount);
  EXPECT_EQ(f.Format.wBitsPerSample, kPipelineBytesPerSampleFloat * 8);
  EXPECT_EQ(f.Format.wFormatTag, WAVE_FORMAT_EXTENSIBLE);
}

TEST(CanonicalPipelineFormatTest, TheDerivedByteRatesAreSelfConsistent) {
  // nBlockAlign and nAvgBytesPerSec are the two fields nothing else would
  // catch: a stream initialized with a wrong block align lands data at an
  // offset the capture loop's memcpy reads straight past.
  const WAVEFORMATEXTENSIBLE f = CanonicalPipelineFormat();
  EXPECT_EQ(f.Format.nBlockAlign,
            f.Format.nChannels * (f.Format.wBitsPerSample / 8));
  EXPECT_EQ(f.Format.nBlockAlign, 8u);  // 2ch * 4 bytes
  EXPECT_EQ(f.Format.nAvgBytesPerSec,
            f.Format.nSamplesPerSec * f.Format.nBlockAlign);
  EXPECT_EQ(f.Format.nAvgBytesPerSec, 384'000u);
}

TEST(CanonicalPipelineFormatTest, CarriesTheExtensibleTail) {
  // cbSize counts only the bytes AFTER the WAVEFORMATEX header. Get it wrong
  // and the engine reads a truncated or over-long sub-format — the classic
  // WAVEFORMATEXTENSIBLE mistake.
  const WAVEFORMATEXTENSIBLE f = CanonicalPipelineFormat();
  EXPECT_EQ(f.Format.cbSize, 22u);
  EXPECT_EQ(f.Format.cbSize,
            sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX));
  EXPECT_EQ(f.Samples.wValidBitsPerSample, f.Format.wBitsPerSample);
  EXPECT_EQ(f.dwChannelMask,
            static_cast<DWORD>(SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT));
  EXPECT_TRUE(IsEqualGUID(f.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
}

TEST(CanonicalPipelineFormatTest, RoundTripsThroughThePipelineCompatibleGate) {
  // The load-bearing property: the format we ask the engine to convert TO is
  // the same one every downstream consumer validates against. If these ever
  // disagreed, a successfully resampled stream would still be rejected — or
  // accepted and then misread.
  const WAVEFORMATEXTENSIBLE f = CanonicalPipelineFormat();
  const AudioFormatSnapshot snap =
      Snapshot(reinterpret_cast<const WAVEFORMATEX*>(&f));
  EXPECT_TRUE(IsPipelineCompatible(snap));
  EXPECT_EQ(snap.sample_type, SampleType::kFloat32);
  EXPECT_EQ(FrameSizeBytes(snap), 8u);
}

TEST(InitializeSharedStreamTest, NullArgumentsFailRatherThanCrash) {
  // Both call sites reach this from a device that may have vanished between
  // enumeration and activation.
  EXPECT_EQ(InitializeSharedStream(nullptr, 0, 0, nullptr).hr, E_POINTER);
  EXPECT_FALSE(InitializeSharedStream(nullptr, 0, 0, nullptr).converted);
}

}  // namespace
}  // namespace clingfy::audio
