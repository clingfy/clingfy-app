#include "Core/canvas_composition.h"

#include <gtest/gtest.h>

#include <utility>

namespace clingfy::core {
namespace {

// The two surfaces that must agree. Export target is the user's chosen
// resolution; the preview texture is capped (preview_engine.cpp kTextureWidth /
// kTextureHeight). Both use the CANVAS aspect, so their shorter sides are what
// the contract normalises against.
constexpr double kExport4kShort = 2160.0;   // 3840x2160
constexpr double kExport1080Short = 1080.0; // 1920x1080
constexpr double kPreviewShort = 720.0;     // 1280x720

TEST(CanvasCompositionTest, RoundTripsThroughTheSameSurface) {
  const double f = NormalizeToShortSide(100.0, kExport4kShort);
  EXPECT_NEAR(DenormalizeFromShortSide(f, kExport4kShort), 100.0, 1e-9);
}

// The regression this type exists for. Before normalisation, padding=100 was
// handed to both surfaces unchanged: 100px on a 3840-wide export is a thin
// border, 100px on a 1280-wide preview is ~3x thicker. The preview lied, and it
// lied MORE the higher the user's export resolution.
TEST(CanvasCompositionTest, SamePaddingLooksProportionallyIdenticalOnBothSurfaces) {
  constexpr double kPaddingPx = 100.0;
  const CanvasComposition c =
      MakeCanvasComposition(kPaddingPx, 0.0, kExport4kShort, std::nullopt);

  const double on_export = DenormalizeFromShortSide(c.padding_fraction, kExport4kShort);
  const double on_preview = DenormalizeFromShortSide(c.padding_fraction, kPreviewShort);

  // Export keeps the authored value.
  EXPECT_NEAR(on_export, kPaddingPx, 1e-9);
  // Preview scales by exactly the surface ratio (720/2160 = 1/3).
  EXPECT_NEAR(on_preview, kPaddingPx * (kPreviewShort / kExport4kShort), 1e-9);
  // Proportion of the surface is identical — that is the WYSIWYG property.
  EXPECT_NEAR(on_export / kExport4kShort, on_preview / kPreviewShort, 1e-12);
}

// The error used to scale with export resolution: correct-looking at 720p and
// visibly wrong at 4K. The fraction must be independent of which resolution the
// user picked, so the preview looks the same at every export setting.
TEST(CanvasCompositionTest, PreviewFramingIsIndependentOfExportResolution) {
  const CanvasComposition at4k =
      MakeCanvasComposition(200.0, 0.0, kExport4kShort, std::nullopt);
  const CanvasComposition at1080 =
      MakeCanvasComposition(100.0, 0.0, kExport1080Short, std::nullopt);

  // 200px on a 2160-short canvas and 100px on a 1080-short canvas are the SAME
  // framing, so they must land on the same preview pixels.
  EXPECT_NEAR(DenormalizeFromShortSide(at4k.padding_fraction, kPreviewShort),
              DenormalizeFromShortSide(at1080.padding_fraction, kPreviewShort),
              1e-9);
}

TEST(CanvasCompositionTest, CornerRadiusNormalizesOnTheSameBasis) {
  const CanvasComposition c =
      MakeCanvasComposition(0.0, 48.0, kExport1080Short, std::nullopt);
  EXPECT_NEAR(DenormalizeFromShortSide(c.corner_radius_fraction, kExport1080Short),
              48.0, 1e-9);
  EXPECT_NEAR(DenormalizeFromShortSide(c.corner_radius_fraction, kPreviewShort),
              48.0 * (kPreviewShort / kExport1080Short), 1e-9);
}

TEST(CanvasCompositionTest, BackgroundPassesThroughUntouched) {
  const CanvasComposition set =
      MakeCanvasComposition(0.0, 0.0, kPreviewShort, std::optional<std::int64_t>{0xFF102030});
  ASSERT_TRUE(set.background_argb.has_value());
  EXPECT_EQ(*set.background_argb, 0xFF102030);

  // nullopt is the Dart default and must stay nullopt so ResolveBackgroundColor
  // applies its opaque-black rule rather than seeing a fabricated value.
  const CanvasComposition unset =
      MakeCanvasComposition(0.0, 0.0, kPreviewShort, std::nullopt);
  EXPECT_FALSE(unset.background_argb.has_value());
}

// A degenerate surface must not divide by zero or clamp the content away. The
// preview legitimately has no known canvas before the first frame.
TEST(CanvasCompositionTest, DegenerateSurfaceYieldsNoPaddingInsteadOfNonsense) {
  EXPECT_EQ(NormalizeToShortSide(100.0, 0.0), 0.0);
  EXPECT_EQ(NormalizeToShortSide(100.0, -1.0), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(0.25, 0.0), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(0.25, -1.0), 0.0);
}

// Dart clamps these, but the contract is the boundary — a negative arriving here
// must not invert the content rect.
TEST(CanvasCompositionTest, NegativeInputsClampToZero) {
  EXPECT_EQ(NormalizeToShortSide(-50.0, kPreviewShort), 0.0);
  EXPECT_EQ(DenormalizeFromShortSide(-0.5, kPreviewShort), 0.0);

  const CanvasComposition c =
      MakeCanvasComposition(-10.0, -10.0, kPreviewShort, std::nullopt);
  EXPECT_EQ(c.padding_fraction, 0.0);
  EXPECT_EQ(c.corner_radius_fraction, 0.0);
}

// --- ResolveCanvasComposition: the resolve-once-dimensions-land contract ---

// A 1080p source with no reframing, so the export canvas short side is 1080 and
// the arithmetic below is checkable by hand.
CanvasFramingArgs PaddedFraming() {
  CanvasFramingArgs framing{};
  framing.padding_px = 108.0;  // exactly 10% of a 1080 short side
  framing.corner_radius_px = 54.0;
  framing.layout_preset = "youtube169";
  framing.resolution_preset = "p1080";
  return framing;
}

// The state every freshly opened project starts in: Dart has pushed the canvas
// but no frame has decoded, so the source size — and therefore the export
// canvas — is unknown. Lengths must stay at 0 rather than normalise against a
// guess, and export_short_side must read 0 so the re-resolve is still owed.
TEST(ResolveCanvasCompositionTest, UnknownSourceLeavesEveryLengthUnresolved) {
  const CanvasComposition c = ResolveCanvasComposition(PaddedFraming(), 0, 0);

  EXPECT_EQ(c.padding_fraction, 0.0);
  EXPECT_EQ(c.corner_radius_fraction, 0.0);
  EXPECT_EQ(c.export_short_side, 0.0);
}

// Backgrounds carry no length, so they must survive the unresolved state —
// otherwise the first frames would show no background at all, one push behind.
TEST(ResolveCanvasCompositionTest, BackgroundSurvivesTheUnresolvedState) {
  CanvasFramingArgs framing = PaddedFraming();
  framing.background_argb = static_cast<std::int64_t>(0xFF112233);
  framing.background_image_path = L"C:/bundle/bg.png";
  framing.has_preset = true;

  const CanvasComposition c = ResolveCanvasComposition(framing, 0, 0);

  ASSERT_TRUE(c.background_argb.has_value());
  EXPECT_EQ(*c.background_argb, static_cast<std::int64_t>(0xFF112233));
  EXPECT_EQ(c.background_image_path, L"C:/bundle/bg.png");
  EXPECT_TRUE(c.has_preset);
}

// Once the dimensions land the same payload resolves against the export canvas
// ResolveTargetSize derives — 1920x1080 here, so a 108px authored padding is
// exactly a tenth of the short side.
TEST(ResolveCanvasCompositionTest, KnownSourceResolvesAgainstTheExportCanvas) {
  const CanvasComposition c =
      ResolveCanvasComposition(PaddedFraming(), 1920.0, 1080.0);

  EXPECT_NEAR(c.export_short_side, kExport1080Short, 1e-9);
  EXPECT_NEAR(c.padding_fraction, 0.1, 1e-9);
  EXPECT_NEAR(c.corner_radius_fraction, 0.05, 1e-9);
}

// THE REGRESSION. Re-resolving the RETAINED payload once the first frame lands
// must produce the fully resolved canvas — this is what makes the open-time
// push self-healing instead of dead. Before the fix the raw payload was
// converted and dropped, so the unresolved result below was permanent and the
// preview drew an unpadded canvas plus a ~3x-too-heavy camera bubble border
// until the user touched an unrelated canvas control.
TEST(ResolveCanvasCompositionTest, ReResolvingTheRetainedPayloadHealsTheCanvas) {
  const CanvasFramingArgs retained = PaddedFraming();

  // Push on project open: no frame yet.
  const CanvasComposition on_open = ResolveCanvasComposition(retained, 0, 0);
  ASSERT_EQ(on_open.export_short_side, 0.0);

  // First composed frame: dimensions known, same payload, resolved canvas.
  const CanvasComposition healed =
      ResolveCanvasComposition(retained, 1920.0, 1080.0);

  EXPECT_NEAR(healed.export_short_side, kExport1080Short, 1e-9);
  EXPECT_NEAR(healed.padding_fraction, 0.1, 1e-9);
  // And it is byte-identical to having had the dimensions all along, so the
  // heal cannot drift from the steady state.
  const CanvasComposition direct =
      ResolveCanvasComposition(retained, 1920.0, 1080.0);
  EXPECT_EQ(healed.padding_fraction, direct.padding_fraction);
  EXPECT_EQ(healed.corner_radius_fraction, direct.corner_radius_fraction);
  EXPECT_EQ(healed.export_short_side, direct.export_short_side);
}

// The camera bubble's reason for needing export_short_side: its border, shadow
// table and min-side floor are export-canvas lengths, so the preview resolves
// them by the surface ratio. At 4K that ratio is 1/3 — which is the ~3x-too-
// thick border the unresolved state produced by handing the painter 1.0.
TEST(ResolveCanvasCompositionTest, ExportShortSideDrivesTheCameraEffectScale) {
  CanvasFramingArgs framing = PaddedFraming();
  framing.resolution_preset = "p2160";

  const CanvasComposition c =
      ResolveCanvasComposition(framing, 3840.0, 2160.0);

  EXPECT_NEAR(c.export_short_side, kExport4kShort, 1e-9);
  // The ratio the preview hands the camera painter.
  EXPECT_NEAR(kPreviewShort / c.export_short_side, 1.0 / 3.0, 1e-9);
}

// --- CanvasNeedsReresolve: the frame thread's decision, pinned without a GPU ---

// The open-time push is the whole point: Dart pushed before any frame decoded,
// so the canvas was resolved against 0x0 and the first frame owes a re-resolve.
TEST(CanvasNeedsReresolveTest, FirstFrameAfterAnOpenTimePushMustReresolve) {
  EXPECT_TRUE(CanvasNeedsReresolve(/*has_framing=*/true, 0, 0, 1920, 1080));
}

// Steady state: same source, already resolved. Re-resolving every frame would
// be wasted work on the per-frame path.
TEST(CanvasNeedsReresolveTest, SteadyStateDoesNotReresolve) {
  EXPECT_FALSE(
      CanvasNeedsReresolve(/*has_framing=*/true, 1920, 1080, 1920, 1080));
}

// A source that changes size invalidates the export canvas the fractions were
// normalised against, so the same comparison catches it.
TEST(CanvasNeedsReresolveTest, ChangedSourceDimensionsReresolve) {
  EXPECT_TRUE(
      CanvasNeedsReresolve(/*has_framing=*/true, 1920, 1080, 3840, 2160));
  // Either axis alone is enough.
  EXPECT_TRUE(
      CanvasNeedsReresolve(/*has_framing=*/true, 1920, 1080, 1920, 1440));
}

// Nothing pushed yet: there is no payload to resolve, and treating this as
// "needs re-resolve" would overwrite the canvas with a default on every frame.
TEST(CanvasNeedsReresolveTest, NoFramingMeansNothingToDo) {
  EXPECT_FALSE(CanvasNeedsReresolve(/*has_framing=*/false, 0, 0, 1920, 1080));
  EXPECT_FALSE(
      CanvasNeedsReresolve(/*has_framing=*/false, 1920, 1080, 3840, 2160));
}

// Frames can arrive before the session reports a size. Asking to resolve
// against 0x0 must not latch a bogus canvas — ResolveCanvasComposition treats
// it as unknown, and the next frame with real dimensions re-resolves again.
TEST(CanvasNeedsReresolveTest, DimensionsGoingUnknownStillReresolves) {
  EXPECT_TRUE(CanvasNeedsReresolve(/*has_framing=*/true, 1920, 1080, 0, 0));
  const CanvasComposition unknown =
      ResolveCanvasComposition(PaddedFraming(), 0.0, 0.0);
  EXPECT_EQ(unknown.export_short_side, 0.0);
}

// A negative or degenerate source is the same "unknown" case, not a reason to
// produce an inverted canvas.
TEST(ResolveCanvasCompositionTest, DegenerateSourceIsTreatedAsUnknown) {
  for (const auto& [w, h] : {std::pair<double, double>{-1920.0, 1080.0},
                             std::pair<double, double>{1920.0, 0.0},
                             std::pair<double, double>{0.0, 0.0}}) {
    const CanvasComposition c = ResolveCanvasComposition(PaddedFraming(), w, h);
    EXPECT_EQ(c.export_short_side, 0.0);
    EXPECT_EQ(c.padding_fraction, 0.0);
  }
}

}  // namespace
}  // namespace clingfy::core
