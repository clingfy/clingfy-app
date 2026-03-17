#!/usr/bin/env bash
# build_archive.sh

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_config.sh"

log_step "STEP 1: Building $APP_DISPLAY_NAME v$APP_VERSION ($APP_ENV)"

ensure_command flutter
ensure_command xcodebuild
ensure_command pod
ensure_command git
ensure_command base64

require_apple_build_env

cd "$PROJECT_ROOT"

timestamp_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
commit_hash="$(git rev-parse --short HEAD)"
build_id="$(current_build_id)"
branch_name="$(current_branch_name)"

log_info "Generating Dart defines"

defines=(
  "APP_ENV=$APP_ENV"
  "BUILD_TIMESTAMP=$timestamp_utc"
  "COMMIT_HASH=$commit_hash"
  "BUILD_ID=$build_id"
  "BUILD_BRANCH=$branch_name"
  "SENTRY_DSN=${SENTRY_DSN:-}"
  "SENTRY_ENVIRONMENT=${SENTRY_ENVIRONMENT:-$APP_ENV}"
  "SENTRY_TRACES_SAMPLE_RATE=${SENTRY_TRACES_SAMPLE_RATE:-}"
  "FLUTTER_BUILD_NAME=$APP_VERSION"
  "FLUTTER_BUILD_NUMBER=$BUILD_NUMBER"
  "API_BASE_URL=${API_BASE_URL:-}"
  "CLINGFY_SITE_URL=${CLINGFY_SITE_URL:-}"
)

encoded_items=()
for item in "${defines[@]}"; do
  encoded_items+=("$(printf '%s' "$item" | base64 | tr -d '\n')")
done

DART_DEFINES_COMBINED="$(join_by "," "${encoded_items[@]}")"

log_info "Environment : $APP_ENV"
log_info "Bundle ID   : $APP_BUNDLE_ID"
log_info "App Name    : $APP_DISPLAY_NAME"
log_info "Commit Hash : $commit_hash"
log_info "Version     : $APP_VERSION (build $BUILD_NUMBER)"

if ! normalize_bool "${SKIP_DEEP_CLEAN:-false}"; then
  log_info "Running deep clean"
  flutter clean
fi

log_info "Resolving Dart packages"
flutter pub get

log_info "Installing CocoaPods"
(
  cd "$PROJECT_ROOT/macos"
  rm -rf Pods .symlinks
  pod install --repo-update
)

log_info "Bootstrapping Flutter macOS config"
flutter build macos \
  --config-only \
  --flavor "$APP_ENV" \
  --build-name "$APP_VERSION" \
  --build-number "$BUILD_NUMBER"

echo "APP_VERSION=$APP_VERSION"
echo "BUILD_NUMBER=$BUILD_NUMBER"
echo "FLUTTER_BUILD_NAME=${FLUTTER_BUILD_NAME:-unset}"
echo "FLUTTER_BUILD_NUMBER=${FLUTTER_BUILD_NUMBER:-unset}"
grep -n "FLUTTER_BUILD_" macos/Flutter/Generated.xcconfig || true

log_info "Generating export options plist"
generate_export_options_plist

log_info "Archiving app"

xcodebuild_args=(
  -workspace "macos/Runner.xcworkspace"
  -scheme "$APP_ENV"
  -archivePath "$ARCHIVE_PATH"
  "DART_DEFINES=$DART_DEFINES_COMBINED"
  archive
)

xcodebuild "${xcodebuild_args[@]}"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -exportPath "$EXPORT_PATH"

[[ -d "$EXPORTED_APP_PATH" ]] || die "Exported app bundle not found: $EXPORTED_APP_PATH"

log_info "Archived app : $ARCHIVED_APP_PATH"
log_info "Exported app : $EXPORTED_APP_PATH"

log_success "Build complete: $EXPORTED_APP_PATH"