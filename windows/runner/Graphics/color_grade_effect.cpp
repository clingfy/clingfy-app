#include "Graphics/color_grade_effect.h"

#include <d2d1effects.h>

namespace clingfy::graphics {

namespace {

// BuildColorMatrix rows are output-major (m[out][in..offset]); the D2D 5x4
// layout is input-major (row per input channel, offsets last) — transpose on
// the way in. Alpha passes through untouched.
D2D1_MATRIX_5X4_F ToD2DMatrix(
    const capture::export_::color::ColorMatrix& cm) {
  D2D1_MATRIX_5X4_F m{};
  m._11 = static_cast<FLOAT>(cm.m[0][0]);
  m._12 = static_cast<FLOAT>(cm.m[1][0]);
  m._13 = static_cast<FLOAT>(cm.m[2][0]);
  m._21 = static_cast<FLOAT>(cm.m[0][1]);
  m._22 = static_cast<FLOAT>(cm.m[1][1]);
  m._23 = static_cast<FLOAT>(cm.m[2][1]);
  m._31 = static_cast<FLOAT>(cm.m[0][2]);
  m._32 = static_cast<FLOAT>(cm.m[1][2]);
  m._33 = static_cast<FLOAT>(cm.m[2][2]);
  m._44 = 1.0f;
  m._51 = static_cast<FLOAT>(cm.m[0][3]);
  m._52 = static_cast<FLOAT>(cm.m[1][3]);
  m._53 = static_cast<FLOAT>(cm.m[2][3]);
  return m;
}

}  // namespace

HRESULT ColorGradeEffectChain::Build(
    ID2D1DeviceContext* d2d_context,
    const capture::export_::color::ColorGrade& grade) {
  Reset();
  if (d2d_context == nullptr) return E_POINTER;

  HRESULT hr = S_OK;

  Microsoft::WRL::ComPtr<ID2D1ColorContext> srgb_ctx;
  Microsoft::WRL::ComPtr<ID2D1ColorContext> scrgb_ctx;
  if (FAILED(hr = d2d_context->CreateColorContext(D2D1_COLOR_SPACE_SRGB,
                                                  nullptr, 0, &srgb_ctx)) ||
      FAILED(hr = d2d_context->CreateColorContext(D2D1_COLOR_SPACE_SCRGB,
                                                  nullptr, 0, &scrgb_ctx))) {
    Reset();
    return hr;
  }

  if (FAILED(hr = d2d_context->CreateEffect(CLSID_D2D1ColorManagement,
                                            &to_linear_)) ||
      FAILED(hr = d2d_context->CreateEffect(CLSID_D2D1ColorMatrix,
                                            &matrix_fx_)) ||
      FAILED(hr = d2d_context->CreateEffect(CLSID_D2D1ColorManagement,
                                            &to_srgb_))) {
    Reset();
    return hr;
  }

  // 16bpc float intermediates on the whole chain — the linearized values
  // must not be quantized back to 8 bits between effects.
  for (ID2D1Effect* fx :
       {to_linear_.Get(), matrix_fx_.Get(), to_srgb_.Get()}) {
    if (FAILED(hr = fx->SetValue(D2D1_PROPERTY_PRECISION,
                                 D2D1_BUFFER_PRECISION_16BPC_FLOAT))) {
      Reset();
      return hr;
    }
  }

  if (FAILED(hr = to_linear_->SetValue(
                 D2D1_COLORMANAGEMENT_PROP_SOURCE_COLOR_CONTEXT,
                 srgb_ctx.Get())) ||
      FAILED(hr = to_linear_->SetValue(
                 D2D1_COLORMANAGEMENT_PROP_DESTINATION_COLOR_CONTEXT,
                 scrgb_ctx.Get())) ||
      FAILED(hr = to_srgb_->SetValue(
                 D2D1_COLORMANAGEMENT_PROP_SOURCE_COLOR_CONTEXT,
                 scrgb_ctx.Get())) ||
      FAILED(hr = to_srgb_->SetValue(
                 D2D1_COLORMANAGEMENT_PROP_DESTINATION_COLOR_CONTEXT,
                 srgb_ctx.Get()))) {
    Reset();
    return hr;
  }

  if (FAILED(hr = UpdateGrade(grade))) {
    Reset();
    return hr;
  }
  if (FAILED(hr = matrix_fx_->SetValue(
                 D2D1_COLORMATRIX_PROP_ALPHA_MODE,
                 D2D1_COLORMATRIX_ALPHA_MODE_STRAIGHT))) {
    Reset();
    return hr;
  }

  matrix_fx_->SetInputEffect(0, to_linear_.Get());
  to_srgb_->SetInputEffect(0, matrix_fx_.Get());
  return S_OK;
}

HRESULT ColorGradeEffectChain::UpdateGrade(
    const capture::export_::color::ColorGrade& grade) {
  if (matrix_fx_ == nullptr) return E_NOT_VALID_STATE;
  const auto matrix =
      ToD2DMatrix(capture::export_::color::BuildColorMatrix(grade));
  return matrix_fx_->SetValue(D2D1_COLORMATRIX_PROP_COLOR_MATRIX, matrix);
}

void ColorGradeEffectChain::SetInput(ID2D1Image* input) {
  if (to_linear_ != nullptr) {
    to_linear_->SetInput(0, input);
  }
}

void ColorGradeEffectChain::Reset() {
  to_linear_.Reset();
  matrix_fx_.Reset();
  to_srgb_.Reset();
}

}  // namespace clingfy::graphics
