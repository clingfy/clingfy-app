// Headless geometry tests for CreateCameraShapeGeometry (renderer redesign P5:
// hexagon / star polygons). These need only an ID2D1Factory1 — no D3D device,
// swapchain, window, or display — so they ALWAYS run: the factory builds the
// path geometry and FillContainsPoint is a CPU point-in-polygon query. They pin
// the exact silhouettes (a hexagon is flat-topped, a star is concave) so the
// polygon math cannot silently drift back to the old squircle/circle fallback
// or diverge from the GDI overlay + Dart preview it must match.

#include "Capture/Camera/camera_bubble_painter.h"

#include <d2d1_1.h>
#include <d2d1helper.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

using Microsoft::WRL::ComPtr;

// A 200x200 square bubble: center (100,100), circum-radius 100, star inner 50.
constexpr float kL = 0.0f, kT = 0.0f, kR = 200.0f, kB = 200.0f;

ComPtr<ID2D1Factory1> MakeFactory() {
  ComPtr<ID2D1Factory1> factory;
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                    __uuidof(ID2D1Factory1),
                    reinterpret_cast<void**>(factory.GetAddressOf()));
  return factory;
}

bool Contains(ID2D1Geometry* geo, float x, float y) {
  BOOL contains = FALSE;
  geo->FillContainsPoint(D2D1::Point2F(x, y), nullptr, &contains);
  return contains != FALSE;
}

ComPtr<ID2D1Geometry> Shape(ID2D1Factory1* factory, const char* name) {
  return CreateCameraShapeGeometry(factory, name, 0.0,
                                   D2D1::RectF(kL, kT, kR, kB));
}

TEST(CameraShapeGeometry, SquareAndUnknownReturnNull) {
  ComPtr<ID2D1Factory1> factory = MakeFactory();
  ASSERT_NE(factory, nullptr);
  // Square draws to the rect directly (no mask geometry); an unknown name is
  // treated the same, not a crash.
  EXPECT_EQ(Shape(factory.Get(), "square"), nullptr);
  EXPECT_EQ(Shape(factory.Get(), "definitely-not-a-shape"), nullptr);
}

TEST(CameraShapeGeometry, CircleContainsCenterExcludesCorners) {
  ComPtr<ID2D1Factory1> factory = MakeFactory();
  ASSERT_NE(factory, nullptr);
  ComPtr<ID2D1Geometry> geo = Shape(factory.Get(), "circle");
  ASSERT_NE(geo, nullptr);
  EXPECT_TRUE(Contains(geo.Get(), 100.0f, 100.0f));  // center
  EXPECT_FALSE(Contains(geo.Get(), 8.0f, 8.0f));     // corner outside the disc
}

// Hexagon (rotation +30°): flat top/bottom edges, vertices at left/right center
// — the GDI overlay + Dart preview orientation. The top edge sits at y≈13.4, so
// a point above it (but a circle/square would contain) proves the flat top.
TEST(CameraShapeGeometry, HexagonIsAFlatTopPolygon) {
  ComPtr<ID2D1Factory1> factory = MakeFactory();
  ASSERT_NE(factory, nullptr);
  ComPtr<ID2D1Geometry> geo = Shape(factory.Get(), "hexagon");
  ASSERT_NE(geo, nullptr);

  EXPECT_TRUE(Contains(geo.Get(), 100.0f, 100.0f));   // center
  EXPECT_TRUE(Contains(geo.Get(), 5.0f, 100.0f));     // just inside left vertex
  EXPECT_TRUE(Contains(geo.Get(), 195.0f, 100.0f));   // just inside right vertex
  // Above the flat top edge (y≈13.4): a circle or square WOULD contain this, so
  // its exclusion pins the hexagon silhouette (and its flat-top orientation).
  EXPECT_FALSE(Contains(geo.Get(), 100.0f, 8.0f));
  EXPECT_FALSE(Contains(geo.Get(), 8.0f, 8.0f));      // corner
}

// Star (5 points, inner ratio 0.5, point up): concave. A point in a notch —
// radially beyond the inner vertex — must be OUTSIDE even though it is well
// within the outer radius (where a circle/convex polygon would contain it).
TEST(CameraShapeGeometry, StarIsConcaveWithPointUp) {
  ComPtr<ID2D1Factory1> factory = MakeFactory();
  ASSERT_NE(factory, nullptr);
  ComPtr<ID2D1Geometry> geo = Shape(factory.Get(), "star");
  ASSERT_NE(geo, nullptr);

  EXPECT_TRUE(Contains(geo.Get(), 100.0f, 100.0f));   // center
  EXPECT_TRUE(Contains(geo.Get(), 100.0f, 5.0f));     // top point (tip ~ y=0)
  // Notch between the top point and the upper-right point: angle -54°, r≈75 —
  // outside the concave star (boundary there is the inner vertex at r=50),
  // inside a circle of radius 100. Exclusion proves concavity.
  EXPECT_FALSE(Contains(geo.Get(), 144.0f, 39.0f));
  EXPECT_FALSE(Contains(geo.Get(), 8.0f, 8.0f));      // corner
}

// corner_radius is intentionally ignored for hexagon/star (sharp — the GDI /
// Dart convention), so passing a large radius must not change the silhouette:
// the notch stays excluded and the flat-top exclusion holds.
TEST(CameraShapeGeometry, HexagonAndStarIgnoreCornerRadius) {
  ComPtr<ID2D1Factory1> factory = MakeFactory();
  ASSERT_NE(factory, nullptr);
  const D2D1_RECT_F rect = D2D1::RectF(kL, kT, kR, kB);

  ComPtr<ID2D1Geometry> hex =
      CreateCameraShapeGeometry(factory.Get(), "hexagon", 0.5, rect);
  ASSERT_NE(hex, nullptr);
  EXPECT_FALSE(Contains(hex.Get(), 100.0f, 8.0f));  // flat top unchanged

  ComPtr<ID2D1Geometry> star =
      CreateCameraShapeGeometry(factory.Get(), "star", 0.5, rect);
  ASSERT_NE(star, nullptr);
  EXPECT_FALSE(Contains(star.Get(), 144.0f, 39.0f));  // notch still concave
}

}  // namespace
}  // namespace clingfy::capture
