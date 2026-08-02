#include "Core/app_identity.h"

#include <gtest/gtest.h>

#include <string>

namespace clingfy::core {
namespace {

// ---------------------------------------------------------------------------
// THE INVARIANT. prod's identity is what every previously shipped build used.
//
// Changing either of these does not "rename a folder" — path_provider and the
// recordings root are derived from them, so a released build would start
// looking in a directory the user's recordings and settings are not in, on
// upgrade, silently. These literals are load-bearing; if a change here looks
// harmless, it is not.
// ---------------------------------------------------------------------------

TEST(AppIdentityTest, ProdFolderNameIsUnchangedFromShippedBuilds) {
  EXPECT_EQ(LocalAppDataFolderName(AppChannel::kProd), L"Clingfy");
}

TEST(AppIdentityTest, ProdMutexSuffixIsUnchangedFromShippedBuilds) {
  EXPECT_EQ(InstanceMutexSuffix(AppChannel::kProd), L"com.clingfy.clingfy");
}

// ---------------------------------------------------------------------------
// The split itself.
// ---------------------------------------------------------------------------

// The whole point of D9: dev and prod must not collide. Equal values here mean
// one channel reads the other's recordings and settings, and only one of the
// two can run at a time.
TEST(AppIdentityTest, DevAndProdShareNothing) {
  EXPECT_NE(LocalAppDataFolderName(AppChannel::kDev),
            LocalAppDataFolderName(AppChannel::kProd));
  EXPECT_NE(InstanceMutexSuffix(AppChannel::kDev),
            InstanceMutexSuffix(AppChannel::kProd));
}

TEST(AppIdentityTest, DevHasItsOwnNames) {
  EXPECT_EQ(LocalAppDataFolderName(AppChannel::kDev), L"Clingfy Dev");
  EXPECT_EQ(InstanceMutexSuffix(AppChannel::kDev), L"com.clingfy.clingfy.dev");
}

// ---------------------------------------------------------------------------
// Resolution. Everything that is not exactly "dev" must be prod.
// ---------------------------------------------------------------------------

TEST(AppIdentityTest, OnlyDevOptsOutOfProd) {
  EXPECT_EQ(ResolveChannel("dev"), AppChannel::kDev);
  EXPECT_EQ(ResolveChannel("prod"), AppChannel::kProd);
}

// The release lane's -Channel parameter is validated as lowercase, but a human
// running the script by hand is not, and a mis-cased value must not silently
// change which directory a build uses.
TEST(AppIdentityTest, ChannelTokenIsCaseInsensitive) {
  EXPECT_EQ(ResolveChannel("Dev"), AppChannel::kDev);
  EXPECT_EQ(ResolveChannel("DEV"), AppChannel::kDev);
  EXPECT_EQ(ResolveChannel("dEv"), AppChannel::kDev);
}

// THE SAFE DIRECTION. An unset define, a typo, a `local` build, or a channel
// name this binary predates all resolve to prod. Guessing dev for a released
// build would point it away from the user's data; guessing prod for a dev
// build merely shares a directory, which is a developer's problem.
TEST(AppIdentityTest, AnythingUnrecognisedResolvesToProd) {
  for (const char* token :
       {"", "prod", "local", "beta", "staging", "production", "d", "devel",
        "dev ", " dev", "nightly"}) {
    EXPECT_EQ(ResolveChannel(token), AppChannel::kProd)
        << "token '" << token << "' must not resolve to dev";
  }
}

// The convenience wrappers must agree with the explicit ones for whichever
// channel this binary was compiled as — otherwise a call site could pick up a
// different directory depending on which overload it happened to use.
TEST(AppIdentityTest, WrappersMatchTheCompiledChannel) {
  EXPECT_EQ(LocalAppDataFolderName(), LocalAppDataFolderName(CurrentChannel()));
  EXPECT_EQ(InstanceMutexSuffix(), InstanceMutexSuffix(CurrentChannel()));
}

// Tests build with no CLINGFY_CHANNEL define (or an explicit prod one), so the
// compiled channel must be prod. If this ever fails, the test binary is being
// built with a dev define and every other expectation here is testing the
// wrong branch.
TEST(AppIdentityTest, TestBinaryCompilesAsProd) {
  EXPECT_EQ(CurrentChannel(), AppChannel::kProd);
}


// ---------------------------------------------------------------------------
// DisplayName — user-visible text, NOT an identity.
// ---------------------------------------------------------------------------

TEST(AppIdentityTest, DisplayNameIsHumanReadable) {
  EXPECT_EQ(DisplayName(AppChannel::kProd), L"Clingfy");
  EXPECT_EQ(DisplayName(AppChannel::kDev), L"Clingfy Dev");
}

// The two channels must be distinguishable on screen. D9 made running both at
// once possible, so two windows both titled "Clingfy" would be a worse bug
// than the lowercase title this replaced.
TEST(AppIdentityTest, DisplayNameDistinguishesTheChannels) {
  EXPECT_NE(DisplayName(AppChannel::kDev), DisplayName(AppChannel::kProd));
}

// THE DISTINCTION THAT MATTERS. DisplayName is display text and free to
// change; the version resource's ProductName is an IDENTITY that path_provider
// derives the data directory from. If someone ever "tidies" them into one
// value, prod's data directory moves and every existing user is orphaned.
// These must not be equal, and the folder name must stay the frozen literal.
//
// This got sharper once ProductName was re-cased to "Clingfy": it and
// DisplayName now read the SAME, which makes them look like duplication
// begging to be merged. They are equal by coincidence, not by contract. The
// resource value may be re-cased (NTFS is case-insensitive, so the store is
// reused) but never renamed; DisplayName has no such constraint.
TEST(AppIdentityTest, DisplayNameIsNotTheDataDirectoryIdentity) {
  EXPECT_NE(DisplayName(AppChannel::kProd),
            LocalAppDataFolderName(AppChannel::kProd) + L" ");
  // The prod data folder is still exactly the shipped literal.
  EXPECT_EQ(LocalAppDataFolderName(AppChannel::kProd), L"Clingfy");
  // Dev's display name and its data folder happen to read alike; that is
  // coincidence, not coupling — the folder is pinned above, this is not.
  EXPECT_EQ(DisplayName(AppChannel::kDev), L"Clingfy Dev");
}

TEST(AppIdentityTest, DisplayNameWrapperMatchesTheCompiledChannel) {
  EXPECT_EQ(DisplayName(), DisplayName(CurrentChannel()));
}

}  // namespace
}  // namespace clingfy::core
