#include "Bridge/Devices/display_label.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace clingfy::bridge::devices {
namespace {

// This suite is a one-for-one mirror of
// macos/RunnerTests/DisplayLabelerTests.swift and asserts the SAME literal
// output strings. If either platform's algorithm drifts, one of the two goes
// red — that pairing is the cross-platform parity guard.

// Composes the payload the enumerator would build, so the ordinal and the name
// are produced by one expression here too.
struct Composed {
  std::int64_t id = 0;
  std::int64_t ordinal = 0;
  std::string name;
  std::string os_name;
};

std::vector<Composed> Compose(const std::vector<OrderingInput>& inputs,
                              const std::vector<std::string>& raw_names,
                              const std::string& screen_word) {
  const auto order = OrderedIndices(inputs);
  std::vector<Composed> out;
  for (std::size_t position = 0; position < order.size(); ++position) {
    const std::size_t source = order[position];
    Composed entry;
    entry.id = inputs[source].id;
    entry.ordinal = static_cast<std::int64_t>(position) + 1;
    const std::string& raw = raw_names[source];
    entry.os_name = IsGenericMonitorName(raw) ? std::string()
                                              : NormalizeMonitorName(raw);
    entry.name = ComposeDisplayName(entry.os_name, entry.ordinal, screen_word);
    out.push_back(entry);
  }
  return out;
}

// ---- Ordering --------------------------------------------------------------

TEST(DisplayLabelTest, OrderingIsLeftToRightThenTopToBottom) {
  const std::vector<OrderingInput> in = {{3, 4072, 0}, {1, 0, 0}, {2, 1512, 0}};
  const auto order = OrderedIndices(in);
  ASSERT_EQ(order.size(), 3u);
  EXPECT_EQ(in[order[0]].id, 1);
  EXPECT_EQ(in[order[1]].id, 2);
  EXPECT_EQ(in[order[2]].id, 3);
}

TEST(DisplayLabelTest, OrderingTieBreaksOnYThenId) {
  const std::vector<OrderingInput> by_y = {{1, 0, 0}, {2, 0, -1080}};
  const auto y_order = OrderedIndices(by_y);
  EXPECT_EQ(by_y[y_order[0]].id, 2);
  EXPECT_EQ(by_y[y_order[1]].id, 1);

  const std::vector<OrderingInput> by_id = {{7, 0, 0}, {3, 0, 0}};
  const auto id_order = OrderedIndices(by_id);
  EXPECT_EQ(by_id[id_order[0]].id, 3);
  EXPECT_EQ(by_id[id_order[1]].id, 7);
}

TEST(DisplayLabelTest, OrderingIsIndependentOfInputPermutation) {
  // The hotplug / enumeration-order drift guard.
  const OrderingInput a{11, 0, 0};
  const OrderingInput b{22, 1512, 0};
  const OrderingInput c{33, 4072, 0};
  const std::vector<std::vector<OrderingInput>> permutations = {
      {a, b, c}, {a, c, b}, {b, a, c}, {b, c, a}, {c, a, b}, {c, b, a}};

  for (const auto& permutation : permutations) {
    const auto order = OrderedIndices(permutation);
    ASSERT_EQ(order.size(), 3u);
    EXPECT_EQ(permutation[order[0]].id, 11);
    EXPECT_EQ(permutation[order[1]].id, 22);
    EXPECT_EQ(permutation[order[2]].id, 33);
  }
}

// ---- Names -----------------------------------------------------------------

TEST(DisplayLabelTest, EmptyOSNameFallsBackToLocalizedScreenWord) {
  EXPECT_EQ(ComposeDisplayName("", 1, "Ecran"), "1. Ecran");
}

TEST(DisplayLabelTest, IsGenericMonitorNameRejectsInboxDrivers) {
  EXPECT_TRUE(IsGenericMonitorName("Generic PnP Monitor"));
  EXPECT_TRUE(IsGenericMonitorName("  generic non-pnp monitor  "));
  EXPECT_TRUE(IsGenericMonitorName("Display"));
  EXPECT_TRUE(IsGenericMonitorName("Unknown"));
  EXPECT_TRUE(IsGenericMonitorName("Unknown Display"));
  EXPECT_TRUE(IsGenericMonitorName("Default Monitor"));
  EXPECT_TRUE(IsGenericMonitorName(""));
  EXPECT_TRUE(IsGenericMonitorName("   "));
  EXPECT_FALSE(IsGenericMonitorName("DELL U2720Q"));
  EXPECT_FALSE(IsGenericMonitorName("LG HDR 4K"));
}

TEST(DisplayLabelTest, NormalizeMonitorNameCollapsesWhitespace) {
  EXPECT_EQ(NormalizeMonitorName("DELL   U2720Q\n"), "DELL U2720Q");
  EXPECT_EQ(NormalizeMonitorName("  Studio Display  "), "Studio Display");
  EXPECT_EQ(NormalizeMonitorName("   "), "");
  EXPECT_EQ(NormalizeMonitorName(""), "");
}

TEST(DisplayLabelTest, InternalWhitespaceIsCollapsedInTheComposedName) {
  const auto rows = Compose({{1, 0, 0}}, {"DELL   U2720Q\n"}, "Screen");
  ASSERT_EQ(rows.size(), 1u);
  EXPECT_EQ(rows[0].name, "1. DELL U2720Q");
  EXPECT_EQ(rows[0].os_name, "DELL U2720Q");
}

TEST(DisplayLabelTest, DuplicateModelNamesAreDisambiguatedByOrdinal) {
  const auto rows = Compose({{1, 0, 0}, {2, 2560, 0}},
                            {"DELL U2720Q", "DELL U2720Q"}, "Screen");
  ASSERT_EQ(rows.size(), 2u);
  EXPECT_EQ(rows[0].name, "1. DELL U2720Q");
  EXPECT_EQ(rows[1].name, "2. DELL U2720Q");
  EXPECT_NE(rows[0].name, rows[1].name);
}

TEST(DisplayLabelTest, GenericNameBecomesAbsentRatherThanEmptyLabel) {
  const auto rows = Compose({{1, 0, 0}}, {"Generic PnP Monitor"}, "Screen");
  ASSERT_EQ(rows.size(), 1u);
  EXPECT_TRUE(rows[0].os_name.empty());
  EXPECT_EQ(rows[0].name, "1. Screen");
}

TEST(DisplayLabelTest, OrdinalIsTheNamePrefix) {
  // The coherence invariant, as an executable assertion.
  const auto rows =
      Compose({{1, 0, 0}, {2, 1512, 0}, {3, 3000, 0}, {4, 5000, 0}},
              {"A", "Generic PnP Monitor", "C", "D"}, "Screen");
  ASSERT_EQ(rows.size(), 4u);
  for (const auto& row : rows) {
    const std::string prefix = std::to_string(row.ordinal) + ". ";
    EXPECT_EQ(row.name.rfind(prefix, 0), 0u)
        << row.name << " must be prefixed with its own ordinal "
        << row.ordinal;
  }
  EXPECT_EQ(rows[0].ordinal, 1);
  EXPECT_EQ(rows[3].ordinal, 4);
}

TEST(DisplayLabelTest, EmptyInputProducesNoRows) {
  EXPECT_TRUE(OrderedIndices({}).empty());
}

TEST(DisplayLabelTest, ComposeFallsBackWhenTheScreenWordIsAlsoEmpty) {
  EXPECT_EQ(ComposeDisplayName("", 3, ""), "3. Screen");
}

}  // namespace
}  // namespace clingfy::bridge::devices
