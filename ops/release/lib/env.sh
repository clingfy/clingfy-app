#!/usr/bin/env bash
# env.sh

load_env_file() {
  local env_file="$PROJECT_ROOT/.env.$APP_ENV"
  local temp_env

  [[ -f "$env_file" ]] || die "Environment file not found: $env_file"

  log_info "Loading environment file: .env.$APP_ENV"

  temp_env="$(mktemp)"
  tr -d '\r' < "$env_file" > "$temp_env"

  set -a
  # shellcheck disable=SC1090
  source "$temp_env"
  set +a

  rm -f "$temp_env"
}

read_pubspec_version_info() {
  local version_line
  version_line="$(grep '^version:' "$PROJECT_ROOT/pubspec.yaml" | awk '{print $2}')"

  [[ -n "$version_line" ]] || die "Could not read version from pubspec.yaml"

  local pubspec_app_version="${version_line%%+*}"
  local pubspec_build_number="1"

  if [[ "$version_line" == *"+"* ]]; then
    pubspec_build_number="${version_line#*+}"
  fi

  export APP_VERSION="${APP_VERSION_OVERRIDE:-$pubspec_app_version}"
  export BUILD_NUMBER="${BUILD_NUMBER_OVERRIDE:-$pubspec_build_number}"
  export APP_VERSION_FULL="${APP_VERSION}+${BUILD_NUMBER}"
}

configure_app_flavor() {
  export BASE_APP_NAME="Clingfy"
  export BASE_BUNDLE_ID="com.clingfy.clingfy"
  export APPLE_TEAM_ID="${APPLE_TEAM_ID:-46LWU2HLR5}"

  case "$APP_ENV" in
    prod)
      export APP_DISPLAY_NAME="$BASE_APP_NAME"
      export APP_BUNDLE_ID="$BASE_BUNDLE_ID"
      ;;
    dev)
      export APP_DISPLAY_NAME="${BASE_APP_NAME} Dev"
      export APP_BUNDLE_ID="${BASE_BUNDLE_ID}.dev"
      ;;
    *)
      export APP_DISPLAY_NAME="${BASE_APP_NAME} Local"
      export APP_BUNDLE_ID="${BASE_BUNDLE_ID}.local"
      ;;
  esac

  export APP_NAME="$APP_DISPLAY_NAME"
}

configure_paths() {
  export ARCHIVE_PATH="$PROJECT_ROOT/build/macos/Runner.xcarchive"
  export EXPORT_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release"

  export XCODE_PRODUCT_NAME="${XCODE_PRODUCT_NAME:-Clingfy}"

  export ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$XCODE_PRODUCT_NAME.app"
  export EXPORTED_APP_PATH="$EXPORT_PATH/$XCODE_PRODUCT_NAME.app"

  export DIST_DIR="$PROJECT_ROOT/dist"
  export DMG_CANVAS="$DIST_DIR/dmg_canvas"
  export DMG_OUTPUT="$DIST_DIR/${APP_DISPLAY_NAME// /_}.dmg"

  export RELEASE_ARCHIVE="$PROJECT_ROOT/release_archive"
  export EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$SCRIPT_ROOT/ExportOptionsManual.plist}"

  export APPCAST_XML="$RELEASE_ARCHIVE/appcast.xml"
  export RELEASE_NOTES_TEMP="$RELEASE_ARCHIVE/release_notes.txt"
  export CHANGELOG_FILE="$PROJECT_ROOT/CHANGELOG.md"

  # export FINAL_DMG_NAME="${APP_DISPLAY_NAME// /_}_${APP_VERSION}.dmg"
  # export DSYM_ZIP="${APP_DISPLAY_NAME// /_}_${APP_VERSION}_dSYM.zip"

  # prod: Clingfy_1.0.0.dmg
  # dev : Clingfy_Dev_1.0.0+1523.dmg  (unique per run)
  case "${RELEASE_CHANNEL:-$APP_ENV}" in
    prod)
      export FINAL_DMG_NAME="${APP_DISPLAY_NAME// /_}_${APP_VERSION}.dmg"
      export DSYM_ZIP="${APP_DISPLAY_NAME// /_}_${APP_VERSION}_dSYM.zip"
      ;;
    dev)
      export FINAL_DMG_NAME="${APP_DISPLAY_NAME// /_}_${APP_VERSION}+${BUILD_NUMBER}.dmg"
      export DSYM_ZIP="${APP_DISPLAY_NAME// /_}_${APP_VERSION}+${BUILD_NUMBER}_dSYM.zip"
      ;;
    *)
      export FINAL_DMG_NAME="${APP_DISPLAY_NAME// /_}_${APP_VERSION}+${BUILD_NUMBER}.dmg"
      export DSYM_ZIP="${APP_DISPLAY_NAME// /_}_${APP_VERSION}+${BUILD_NUMBER}_dSYM.zip"
      ;;
  esac
}

configure_azure_defaults() {
  export AZ_CONTAINER_SYMBOLS="${AZ_CONTAINER_SYMBOLS:-symbols}"
  case "${RELEASE_CHANNEL:-$APP_ENV}" in
    prod)
      export AZ_CONTAINER="${AZ_CONTAINER:-updates}"
      export AZ_BINARIES_FOLDER="${AZ_BINARIES_FOLDER:-downloads}"
      export AZ_SYMBOLS_BLOB_PREFIX=""
      export APPCAST_BLOB_PATH="appcast.xml"
      export FEED_PATH="appcast.xml"
      ;;
    dev)
      export AZ_CONTAINER="${AZ_CONTAINER:-updates}"
      export AZ_BINARIES_FOLDER="${AZ_BINARIES_FOLDER:-downloads}"
      export AZ_SYMBOLS_BLOB_PREFIX=""
      export APPCAST_BLOB_PATH="appcast.xml"
      export FEED_PATH="appcast.xml"
      ;;
    *)
      export AZ_CONTAINER="${AZ_CONTAINER:-updates}"
      export AZ_BINARIES_FOLDER="${AZ_BINARIES_FOLDER:-local/downloads}"
      export AZ_SYMBOLS_BLOB_PREFIX="local/"
      export APPCAST_BLOB_PATH="local/appcast.xml"
      export FEED_PATH="local/appcast.xml"
      ;;
  esac

  export DOWNLOAD_BASE_URL="https://${AZ_CDN_ENDPOINT}/${AZ_BINARIES_FOLDER}/"
  export FEED_URL="https://${AZ_CDN_ENDPOINT}/${FEED_PATH}"
}

# Which cloud this channel publishes to.
#
# Azure was decommissioned on 2026-09-10 and clingfy.com/updates/* has served from the AWS releases
# bucket since the 2026-08-17 cutover. Publishing prod to Azure therefore writes to a location
# NOTHING READS: the upload succeeds, the smoke test below passes (it fetches FEED_URL, which is
# built from AZ_CDN_ENDPOINT, so it verifies the copy it just wrote), and no installed app ever sees
# the release. That silent-success shape is why this switch exists rather than a hard swap.
#
# dev deliberately stays on Azure: there is no dev releases bucket (infra/aws/releases.tf builds one
# for prod only), so `clingfyreleasesdev` remains the dev updater's origin until that is rehomed.
configure_storage_provider() {
  case "${RELEASE_CHANNEL:-$APP_ENV}" in
    prod) export RELEASE_STORAGE_PROVIDER="${RELEASE_STORAGE_PROVIDER:-aws}" ;;
    *)    export RELEASE_STORAGE_PROVIDER="${RELEASE_STORAGE_PROVIDER:-azure}" ;;
  esac

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)
      [[ -n "${AWS_RELEASES_BUCKET:-}" ]]         || die "RELEASE_STORAGE_PROVIDER=aws requires AWS_RELEASES_BUCKET (set it in .env.$APP_ENV)."
      ;;
    azure)
      [[ -n "${AZ_STORAGE_ACCOUNT:-}" ]]         || die "RELEASE_STORAGE_PROVIDER=azure requires AZ_STORAGE_ACCOUNT (set it in .env.$APP_ENV)."
      ;;
    *)
      die "RELEASE_STORAGE_PROVIDER must be \"aws\" or \"azure\", got \"$RELEASE_STORAGE_PROVIDER\"."
      ;;
  esac
}

# Single upload entry point. Both backends take (container, local_file, blob_name) and resolve the
# account/bucket themselves, so call sites never branch on the provider.
publish_upload() {
  local container="$1"
  local local_file="$2"
  local blob_name="$3"

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   s3_upload_object "$AWS_RELEASES_BUCKET" "$container" "$local_file" "$blob_name" ;;
    azure) az_upload_blob "$AZ_STORAGE_ACCOUNT" "$container" "$local_file" "$blob_name" ;;
  esac
}

# Mirror of publish_upload for reads. Returns 1 when the object is absent, like its Azure original.
publish_download_if_exists() {
  local container="$1"
  local blob_name="$2"
  local output_file="$3"

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   s3_download_if_exists "$AWS_RELEASES_BUCKET" "$container" "$blob_name" "$output_file" ;;
    azure) az_blob_download_if_exists "$AZ_STORAGE_ACCOUNT" "$container" "$blob_name" "$output_file" ;;
  esac
}

require_release_storage_cli() {
  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   require_aws_cli ;;
    azure) require_azure_cli ;;
  esac
}



load_release_context() {
  export APP_ENV="${1:-local}"
  export SCRIPT_ROOT="${2:?script root is required}"
  export PROJECT_ROOT="$(cd "$SCRIPT_ROOT/../.." && pwd)"
  export RELEASE_CHANNEL="${RELEASE_CHANNEL:-$APP_ENV}"

  load_env_file
  configure_app_flavor
  read_pubspec_version_info
  configure_paths
  configure_azure_defaults
  configure_storage_provider
}
