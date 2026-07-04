// Tests for the pure color-grade math (editing port, color — step 2).
//
// Two layers:
//   1. INVARANT tests — internal consistency of the matrix construction
//      (identity, per-leg algebra, composition order). Tight tolerances;
//      these must always pass and prove the code does what ITS OWN math
//      says.
//   2. GOLDEN tests — parity against the real macOS renderer, using the
//      fixture dumped by macos RunnerTests/ColorGradeGoldenDumpTests
//      (windows/runner_tests/fixtures/color_grade_golden.json). Looser
//      tolerance; these prove the math matches Core Image. They FAIL — not
//      skip — when the fixture is missing, because PR-2a is gated on golden
//      parity and a silent skip would read as green coverage that doesn't
//      exist (the GTEST_SKIP-on-missing-decoder pattern hid exactly that).

#include "Capture/Export/color_grade.h"

#include <gtest/gtest.h>

#include <cctype>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace clingfy::capture::export_::color {
namespace {

constexpr double kTight = 1e-9;
// Golden tolerance: fixture values are 1e-6-rounded floats from a GPU render;
// our path is CPU doubles. Start loose enough to absorb render noise, tight
// enough that a wrong pivot/luma/locus constant fails clearly.
constexpr double kGolden = 2e-3;

// ---------------------------------------------------------------------------
// Invariant layer
// ---------------------------------------------------------------------------

TEST(ColorGradeTest, IsIdentityIsNumbersOnly) {
  EXPECT_TRUE(ColorGrade{}.IsIdentity());
  // autoEnabled with all-zero numbers is IDENTITY — Swift semantics
  // (macOS testIsIdentityIgnoresAutoFlagWhenNumbersAreNeutral).
  ColorGrade auto_only;
  auto_only.auto_enabled = true;
  EXPECT_TRUE(auto_only.IsIdentity());

  ColorGrade g;
  g.exposure = 0.1;
  EXPECT_FALSE(g.IsIdentity());
  g = ColorGrade{};
  g.contrast = -0.1;
  EXPECT_FALSE(g.IsIdentity());
  g = ColorGrade{};
  g.saturation = 0.1;
  EXPECT_FALSE(g.IsIdentity());
  g = ColorGrade{};
  g.temperature = 0.1;
  EXPECT_FALSE(g.IsIdentity());
  g = ColorGrade{};
  g.tint = -0.1;
  EXPECT_FALSE(g.IsIdentity());
}

TEST(ColorGradeTest, IdentityGradeBuildsIdentityMatrix) {
  EXPECT_EQ(BuildColorMatrix(ColorGrade{}), ColorMatrix::Identity());
}

TEST(ColorGradeTest, ExposureIsPureGain) {
  const ColorMatrix m = ExposureMatrix(1.0);
  const double gain = std::pow(2.0, kExposureEvScale);  // 2^1.5
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 4; ++c) {
      const double expected = (r == c) ? gain : 0.0;
      EXPECT_NEAR(m.m[r][c], expected, kTight) << "at " << r << "," << c;
    }
  }
  // Negative exposure darkens symmetrically: gains multiply to 1.
  const ColorMatrix inv = ExposureMatrix(-1.0);
  EXPECT_NEAR(m.m[0][0] * inv.m[0][0], 1.0, kTight);
}

TEST(ColorGradeTest, ContrastPivotIsFixedPoint) {
  const ColorMatrix m = ContrastSaturationMatrix(0.7, 0.0);
  // The pivot maps to itself for any contrast.
  const auto pivot =
      m.Apply(kContrastPivot, kContrastPivot, kContrastPivot);
  EXPECT_NEAR(pivot[0], kContrastPivot, kTight);
  EXPECT_NEAR(pivot[1], kContrastPivot, kTight);
  EXPECT_NEAR(pivot[2], kContrastPivot, kTight);
  // Slope away from the pivot is 1 + 0.5c.
  const auto one = m.Apply(1.0, 1.0, 1.0);
  EXPECT_NEAR(one[0] - pivot[0],
              (1.0 - kContrastPivot) * (1.0 + kContrastScalePerUnit * 0.7),
              kTight);
}

TEST(ColorGradeTest, SaturationLeavesGrayUntouched) {
  for (const double s : {-1.0, -0.5, 0.5, 1.0}) {
    const ColorMatrix m = ContrastSaturationMatrix(0.0, s);
    for (const double v : {0.0, 0.25, 0.6, 1.0}) {
      const auto out = m.Apply(v, v, v);
      EXPECT_NEAR(out[0], v, kTight) << "s=" << s << " v=" << v;
      EXPECT_NEAR(out[1], v, kTight) << "s=" << s << " v=" << v;
      EXPECT_NEAR(out[2], v, kTight) << "s=" << s << " v=" << v;
    }
  }
}

TEST(ColorGradeTest, FullDesaturationCollapsesToLuma) {
  const ColorMatrix m = ContrastSaturationMatrix(0.0, -1.0);
  const auto out = m.Apply(1.0, 0.0, 0.0);  // pure red
  EXPECT_NEAR(out[0], kSaturationLumaR, kTight);
  EXPECT_NEAR(out[1], kSaturationLumaR, kTight);
  EXPECT_NEAR(out[2], kSaturationLumaR, kTight);
}

TEST(ColorGradeTest, TemperatureTintZeroIsExactIdentity) {
  EXPECT_EQ(TemperatureTintMatrix(0.0, 0.0), ColorMatrix::Identity());
}

TEST(ColorGradeTest, PositiveTemperatureWarmsNeutralGray) {
  const ColorMatrix m = TemperatureTintMatrix(1.0, 0.0);
  const auto out = m.Apply(0.5, 0.5, 0.5);
  EXPECT_GT(out[0], out[2]) << "warm shift must raise red above blue";
}

TEST(ColorGradeTest, NegativeTemperatureCoolsNeutralGray) {
  const ColorMatrix m = TemperatureTintMatrix(-1.0, 0.0);
  const auto out = m.Apply(0.5, 0.5, 0.5);
  EXPECT_LT(out[0], out[2]) << "cool shift must raise blue above red";
}

TEST(ColorGradeTest, TintShiftsGreenMagentaAxis) {
  // Positive tint = magenta (macOS comment): green falls relative to the
  // red/blue average. Negative tint goes the other way.
  const auto magenta = TemperatureTintMatrix(0.0, 1.0).Apply(0.5, 0.5, 0.5);
  EXPECT_LT(magenta[1], (magenta[0] + magenta[2]) / 2.0);
  const auto green = TemperatureTintMatrix(0.0, -1.0).Apply(0.5, 0.5, 0.5);
  EXPECT_GT(green[1], (green[0] + green[2]) / 2.0);
}

TEST(ColorGradeTest, BuildComposesLegsInMacosOrder) {
  ColorGrade g;
  g.exposure = 0.3;
  g.contrast = -0.2;
  g.saturation = 0.4;
  g.temperature = -0.6;
  g.tint = 0.8;
  const ColorMatrix combined = BuildColorMatrix(g);

  // Manual sequential application: exposure → contrast+saturation → temp/tint.
  const ColorMatrix e = ExposureMatrix(g.exposure);
  const ColorMatrix cs = ContrastSaturationMatrix(g.contrast, g.saturation);
  const ColorMatrix tt = TemperatureTintMatrix(g.temperature, g.tint);
  for (const auto& rgb :
       {std::array<double, 3>{0.2, 0.5, 0.8}, {1.0, 0.0, 0.0},
        {0.04, 0.04, 0.04}}) {
    const auto step1 = e.Apply(rgb[0], rgb[1], rgb[2]);
    const auto step2 = cs.Apply(step1[0], step1[1], step1[2]);
    const auto expected = tt.Apply(step2[0], step2[1], step2[2]);
    const auto actual = combined.Apply(rgb[0], rgb[1], rgb[2]);
    EXPECT_NEAR(actual[0], expected[0], kTight);
    EXPECT_NEAR(actual[1], expected[1], kTight);
    EXPECT_NEAR(actual[2], expected[2], kTight);
  }
}

TEST(ColorGradeTest, ComposeMatchesSequentialApply) {
  ColorMatrix a = ColorMatrix::Identity();
  a.m[0] = {{0.9, 0.1, 0.0, 0.05}};
  a.m[1] = {{0.0, 1.1, -0.1, -0.02}};
  a.m[2] = {{0.2, 0.0, 0.8, 0.0}};
  ColorMatrix b = ColorMatrix::Identity();
  b.m[0] = {{1.2, 0.0, 0.0, -0.1}};
  b.m[1] = {{0.0, 0.7, 0.3, 0.0}};
  b.m[2] = {{0.0, 0.0, 1.0, 0.2}};
  const ColorMatrix ab = ColorMatrix::Compose(a, b);
  const auto via_compose = ab.Apply(0.3, 0.6, 0.9);
  const auto b_first = b.Apply(0.3, 0.6, 0.9);
  const auto sequential = a.Apply(b_first[0], b_first[1], b_first[2]);
  EXPECT_NEAR(via_compose[0], sequential[0], kTight);
  EXPECT_NEAR(via_compose[1], sequential[1], kTight);
  EXPECT_NEAR(via_compose[2], sequential[2], kTight);
}

TEST(ColorGradeTest, SrgbTransferRoundTripsAndMatchesAnchors) {
  for (const double v : {0.0, 0.001, 0.02, 0.18, 0.5, 1.0, -0.3, 1.5}) {
    EXPECT_NEAR(LinearToSrgb(SrgbToLinear(v)), v, 1e-12) << "v=" << v;
  }
  // IEC anchors.
  EXPECT_NEAR(SrgbToLinear(0.0), 0.0, kTight);
  EXPECT_NEAR(SrgbToLinear(1.0), 1.0, kTight);
  EXPECT_NEAR(SrgbToLinear(0.5), 0.21404114, 1e-6);
}

// ---------------------------------------------------------------------------
// Golden layer — parity vs the macOS renderer fixture
// ---------------------------------------------------------------------------

// Minimal recursive-descent JSON reader for the fixture (test-only; the
// production runner deliberately has no general JSON dependency). Supports
// exactly what JSONSerialization emits: objects, arrays, numbers, strings,
// bools, null.
class JsonValue {
 public:
  enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };
  Type type = Type::kNull;
  bool boolean = false;
  double number = 0.0;
  std::string string;
  std::vector<JsonValue> array;
  std::map<std::string, JsonValue> object;
};

class JsonParser {
 public:
  explicit JsonParser(const std::string& text) : text_(text) {}

  bool Parse(JsonValue* out) {
    SkipWs();
    if (!ParseValue(out)) return false;
    SkipWs();
    return pos_ == text_.size();
  }

 private:
  void SkipWs() {
    while (pos_ < text_.size() &&
           std::isspace(static_cast<unsigned char>(text_[pos_]))) {
      ++pos_;
    }
  }

  bool ParseValue(JsonValue* out) {
    SkipWs();
    if (pos_ >= text_.size()) return false;
    const char c = text_[pos_];
    if (c == '{') return ParseObject(out);
    if (c == '[') return ParseArray(out);
    if (c == '"') {
      out->type = JsonValue::Type::kString;
      return ParseString(&out->string);
    }
    if (c == 't' || c == 'f') {
      out->type = JsonValue::Type::kBool;
      if (text_.compare(pos_, 4, "true") == 0) {
        out->boolean = true;
        pos_ += 4;
        return true;
      }
      if (text_.compare(pos_, 5, "false") == 0) {
        out->boolean = false;
        pos_ += 5;
        return true;
      }
      return false;
    }
    if (c == 'n') {
      if (text_.compare(pos_, 4, "null") == 0) {
        out->type = JsonValue::Type::kNull;
        pos_ += 4;
        return true;
      }
      return false;
    }
    // Number.
    const std::size_t start = pos_;
    if (text_[pos_] == '-') ++pos_;
    while (pos_ < text_.size() &&
           (std::isdigit(static_cast<unsigned char>(text_[pos_])) ||
            text_[pos_] == '.' || text_[pos_] == 'e' || text_[pos_] == 'E' ||
            text_[pos_] == '+' || text_[pos_] == '-')) {
      ++pos_;
    }
    if (pos_ == start) return false;
    out->type = JsonValue::Type::kNumber;
    out->number = std::stod(text_.substr(start, pos_ - start));
    return true;
  }

  bool ParseString(std::string* out) {
    if (text_[pos_] != '"') return false;
    ++pos_;
    out->clear();
    while (pos_ < text_.size() && text_[pos_] != '"') {
      char c = text_[pos_];
      if (c == '\\' && pos_ + 1 < text_.size()) {
        ++pos_;
        const char esc = text_[pos_];
        switch (esc) {
          case 'n': c = '\n'; break;
          case 't': c = '\t'; break;
          case 'r': c = '\r'; break;
          case 'u':
            // Fixture strings are ASCII; skip the 4 hex digits, emit '?'.
            pos_ += 4;
            c = '?';
            break;
          default: c = esc; break;
        }
      }
      out->push_back(c);
      ++pos_;
    }
    if (pos_ >= text_.size()) return false;
    ++pos_;  // closing quote
    return true;
  }

  bool ParseObject(JsonValue* out) {
    out->type = JsonValue::Type::kObject;
    ++pos_;  // '{'
    SkipWs();
    if (pos_ < text_.size() && text_[pos_] == '}') {
      ++pos_;
      return true;
    }
    while (pos_ < text_.size()) {
      SkipWs();
      std::string key;
      if (!ParseString(&key)) return false;
      SkipWs();
      if (pos_ >= text_.size() || text_[pos_] != ':') return false;
      ++pos_;
      JsonValue value;
      if (!ParseValue(&value)) return false;
      out->object.emplace(std::move(key), std::move(value));
      SkipWs();
      if (pos_ >= text_.size()) return false;
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == '}') {
        ++pos_;
        return true;
      }
      return false;
    }
    return false;
  }

  bool ParseArray(JsonValue* out) {
    out->type = JsonValue::Type::kArray;
    ++pos_;  // '['
    SkipWs();
    if (pos_ < text_.size() && text_[pos_] == ']') {
      ++pos_;
      return true;
    }
    while (pos_ < text_.size()) {
      JsonValue value;
      if (!ParseValue(&value)) return false;
      out->array.push_back(std::move(value));
      SkipWs();
      if (pos_ >= text_.size()) return false;
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == ']') {
        ++pos_;
        return true;
      }
      return false;
    }
    return false;
  }

  const std::string& text_;
  std::size_t pos_ = 0;
};

std::string FixturePath() {
  // __FILE__ = <repo>/windows/runner_tests/color_grade_test.cpp.
  std::string path = __FILE__;
  const std::size_t slash = path.find_last_of("/\\");
  path.resize(slash == std::string::npos ? 0 : slash);
  return path + "/fixtures/color_grade_golden.json";
}

class ColorGradeGoldenTest : public ::testing::Test {
 protected:
  static void SetUpTestSuite() {
    fixture_ = new JsonValue();
    std::ifstream file(FixturePath(), std::ios::binary);
    if (!file.is_open()) {
      fixture_missing_ = true;
      return;
    }
    std::ostringstream buffer;
    buffer << file.rdbuf();
    const std::string text = buffer.str();
    JsonParser parser(text);
    if (!parser.Parse(fixture_)) {
      fixture_missing_ = true;
    }
  }

  static void TearDownTestSuite() {
    delete fixture_;
    fixture_ = nullptr;
  }

  // FAILS (not skips) when the fixture is absent: PR-2a is gated on golden
  // parity, and a skip would read as coverage that doesn't exist.
  bool RequireFixture() {
    if (fixture_missing_) {
      ADD_FAILURE()
          << "Golden fixture missing or unparseable: " << FixturePath()
          << "\nGenerate it on the Mac and commit it:\n"
          << "  cd macos && export APP_ENV=dev\n"
          << "  xcodebuild test -workspace Runner.xcworkspace -scheme dev \\\n"
          << "    -configuration Debug-dev -destination 'platform=macOS' \\\n"
          << "    -only-testing:RunnerTests/ColorGradeGoldenDumpTests";
      return false;
    }
    return true;
  }

  static JsonValue* fixture_;
  static bool fixture_missing_;
};

JsonValue* ColorGradeGoldenTest::fixture_ = nullptr;
bool ColorGradeGoldenTest::fixture_missing_ = false;

TEST_F(ColorGradeGoldenTest, MatrixPipelineMatchesMacosRenderer) {
  if (!RequireFixture()) return;

  const auto& inputs = fixture_->object["inputs"].array;
  const auto& cases = fixture_->object["cases"].array;
  ASSERT_GT(inputs.size(), 0u);
  ASSERT_GT(cases.size(), 0u);

  std::size_t checked = 0;
  double worst = 0.0;
  std::string worst_label;

  for (const auto& c : cases) {
    auto grade_obj = c.object.at("grade").object;
    ColorGrade grade;
    grade.exposure = grade_obj["exposure"].number;
    grade.contrast = grade_obj["contrast"].number;
    grade.saturation = grade_obj["saturation"].number;
    grade.temperature = grade_obj["temperature"].number;
    grade.tint = grade_obj["tint"].number;
    const ColorMatrix matrix = BuildColorMatrix(grade);

    const auto& outputs = c.object.at("outputs").array;
    ASSERT_EQ(outputs.size(), inputs.size());

    for (std::size_t i = 0; i < inputs.size(); ++i) {
      const auto& in = inputs[i].array;
      const auto& expect = outputs[i].array;

      // sRGB-encoded fixture value → linear → matrix → re-encode.
      const auto graded = matrix.Apply(SrgbToLinear(in[0].number),
                                       SrgbToLinear(in[1].number),
                                       SrgbToLinear(in[2].number));
      const double out[3] = {LinearToSrgb(graded[0]), LinearToSrgb(graded[1]),
                             LinearToSrgb(graded[2])};

      for (int ch = 0; ch < 3; ++ch) {
        const double diff = std::abs(out[ch] - expect[ch].number);
        if (diff > worst) {
          worst = diff;
          std::ostringstream label;
          label << "grade{e=" << grade.exposure << ",c=" << grade.contrast
                << ",s=" << grade.saturation << ",t=" << grade.temperature
                << ",n=" << grade.tint << "} input[" << i << "] ch" << ch;
          worst_label = label.str();
        }
        EXPECT_NEAR(out[ch], expect[ch].number, kGolden)
            << "grade{e=" << grade.exposure << ",c=" << grade.contrast
            << ",s=" << grade.saturation << ",t=" << grade.temperature
            << ",n=" << grade.tint << "} input " << i << " (sRGB "
            << in[0].number << "," << in[1].number << "," << in[2].number
            << ") channel " << ch;
        ++checked;
      }
    }
  }

  // Visibility into calibration headroom even when green.
  std::cout << "[golden] " << checked << " channel comparisons; worst |diff| = "
            << worst << " at " << worst_label << " (tolerance " << kGolden
            << ")\n";
}

TEST_F(ColorGradeGoldenTest, FixtureCoversEveryAxisAndComposites) {
  if (!RequireFixture()) return;
  const auto& cases = fixture_->object["cases"].array;
  bool has[5] = {false, false, false, false, false};
  bool has_composite = false;
  for (const auto& c : cases) {
    auto g = c.object.at("grade").object;
    const double vals[5] = {g["exposure"].number, g["contrast"].number,
                            g["saturation"].number, g["temperature"].number,
                            g["tint"].number};
    int nonzero = 0;
    for (int i = 0; i < 5; ++i) {
      if (vals[i] != 0.0) {
        has[i] = true;
        ++nonzero;
      }
    }
    if (nonzero >= 3) has_composite = true;
  }
  for (int i = 0; i < 5; ++i) {
    EXPECT_TRUE(has[i]) << "fixture missing single-axis coverage for axis "
                        << i;
  }
  EXPECT_TRUE(has_composite)
      << "fixture missing composite (chain-order) coverage";
}

}  // namespace
}  // namespace clingfy::capture::export_::color
