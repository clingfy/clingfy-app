// Editing-features port (color) — the ONE Direct2D effect chain both the
// export pipeline and the live preview use to apply a color grade:
//
//     input (sRGB-encoded, any D2D image)
//        └─► ColorManagement  sRGB → scRGB      (piecewise linearization —
//        │                                       D2D has no sRGB-transfer
//        │                                       primitive; GammaTransfer is
//        │                                       a pure power curve)
//        └─► ColorMatrix      BuildColorMatrix   (straight alpha; the single
//        │                    (grade), 5x4       linear-space matrix that
//        │                                       replicates the whole macOS
//        │                                       filter chain — see
//        │                                       Capture/Export/color_grade.h)
//        └─► ColorManagement  scRGB → sRGB       (re-encode)
//
// Every effect runs at D2D1_BUFFER_PRECISION_16BPC_FLOAT — 8bpc
// intermediates quantize the linearized values and band the shadows.
//
// Shared so preview and export can never drift: the WYSIWYG contract is
// "the preview's grade IS the export's grade", enforced by construction.
// The pure matrix math stays in Capture/Export/color_grade.h (no D2D); this
// unit is the only place the matrix meets Direct2D.

#ifndef RUNNER_GRAPHICS_COLOR_GRADE_EFFECT_H_
#define RUNNER_GRAPHICS_COLOR_GRADE_EFFECT_H_

#include <d2d1_1.h>
#include <wrl/client.h>

#include "Capture/Export/color_grade.h"

namespace clingfy::graphics {

// A built effect chain. Rebuild when the owning ID2D1DeviceContext changes
// (device loss); update the matrix in place when only the grade changes —
// UpdateGrade is cheap (one SetValue), Build creates three effects.
class ColorGradeEffectChain {
 public:
  // Builds the chain against `d2d_context` for `grade`. Returns the first
  // failing HRESULT (chain left empty) or S_OK. Building an identity grade
  // is allowed but pointless — callers should skip the pass entirely via
  // grade.IsIdentity().
  HRESULT Build(ID2D1DeviceContext* d2d_context,
                const capture::export_::color::ColorGrade& grade);

  // Re-derives and uploads the 5x4 matrix for a new grade without
  // recreating the effects. Only valid after a successful Build.
  HRESULT UpdateGrade(const capture::export_::color::ColorGrade& grade);

  // Sets the chain's input image (a bitmap or another effect's output).
  void SetInput(ID2D1Image* input);

  // The chain's tail effect for ID2D1DeviceContext::DrawImage. Null until
  // Build succeeds.
  ID2D1Effect* Output() const { return to_srgb_.Get(); }

  bool IsBuilt() const { return to_srgb_ != nullptr; }
  void Reset();

 private:
  Microsoft::WRL::ComPtr<ID2D1Effect> to_linear_;
  Microsoft::WRL::ComPtr<ID2D1Effect> matrix_fx_;
  Microsoft::WRL::ComPtr<ID2D1Effect> to_srgb_;
};

}  // namespace clingfy::graphics

#endif  // RUNNER_GRAPHICS_COLOR_GRADE_EFFECT_H_
