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

  # URL composition moved to configure_public_endpoint(), which runs after the storage provider is
  # known. Composing them here from AZ_CDN_ENDPOINT was a bug: it put the bytes in S3 while the
  # appcast it generated still pointed every enclosure at the Azure blob.
}

# Which cloud this channel publishes to.
#
# Azure was decommissioned on 2026-09-10 and clingfy.com/updates/* has served from the AWS releases
# bucket since the 2026-08-17 cutover. While the `azure` arm still existed, publishing prod to it
# wrote to a location NOTHING READ: the upload succeeded, the smoke test passed as long as FEED_URL
# was still composed from AZ_CDN_ENDPOINT (it then verified the copy it had just written), and no
# installed app ever saw the release. That silent-success shape is why this switch exists rather
# than a hard swap — and it is why FEED_URL is now composed in configure_public_endpoint() below,
# off the endpoint the artifacts are actually SERVED from.
#
# dev used to stay on Azure because there was no dev releases bucket. There is one now
# (`clingfy-labs-dev-releases-<account>`, clingfy-labs PR #209, applied 2026-09-15), it has been
# seeded from the `clingfyreleasesdev` updates container with the enclosure hosts rewritten to
# dev.clingfy.com, and `dev.clingfy.com/updates/*` is served from it rather than 302'd into Azure.
# `clingfyreleases` (prod) was deleted on 2026-09-15 and `clingfyreleasesdev` follows once this
# lands — at which point publishing ANY channel to Azure writes to an account that no longer exists.
#
# `local` gets `none`, not a cloud. It used to default to `azure`, which stopped being a
# harmless placeholder the day both Azure release accounts were deleted (2026-09-15): the arm
# still existed, so a local publish aimed at storage that no longer answers. `none` keeps local
# BUILDS working and makes a local PUBLISH say why it cannot proceed.
configure_storage_provider() {
  case "${RELEASE_CHANNEL:-$APP_ENV}" in
    prod|dev) export RELEASE_STORAGE_PROVIDER="${RELEASE_STORAGE_PROVIDER:-aws}" ;;
    *)        export RELEASE_STORAGE_PROVIDER="${RELEASE_STORAGE_PROVIDER:-none}" ;;
  esac

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)
      [[ -n "${AWS_RELEASES_BUCKET:-}" ]]         || die "RELEASE_STORAGE_PROVIDER=aws requires AWS_RELEASES_BUCKET (set it in .env.$APP_ENV)."
      # Required, not optional. /updates/* is served by CloudFront with the managed
      # CachingOptimized policy, and every feed this pipeline publishes is a REPUBLISHED
      # path -- appcast.xml here, latest-windows.json on the Windows lane (replaced on
      # every publish by design). Without an invalidation those keep serving the previous
      # release from the edge for the full TTL while S3 already holds the new bytes.
      #
      # That is the same silent-success shape this provider switch exists to kill: the
      # upload succeeds, nothing errors, and no installed app sees the release. Publishing
      # to AWS without the means to invalidate is not a degraded release, it is a release
      # nobody receives -- so it fails here, before any bytes move, rather than warning
      # after the fact.
      [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}" ]] || die "RELEASE_STORAGE_PROVIDER=aws requires AWS_CLOUDFRONT_DISTRIBUTION_ID: /updates/* is cached by CloudFront and a republished feed stays stale at the edge without an invalidation (set it in .env.$APP_ENV)."
      ;;
    none)
      # Nothing to validate: this channel does not publish. The seams below refuse the
      # actual transfer, so a local build runs and a local publish stops with a reason.
      ;;
    *)
      die "RELEASE_STORAGE_PROVIDER must be \"aws\" or \"none\", got \"$RELEASE_STORAGE_PROVIDER\"."
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
    # No silent fall-through. An unmatched `case` returns 0, which would make this seam
    # report success without moving a byte -- the exact silent-success shape the provider
    # switch exists to prevent.
    *)     die "publish_upload: RELEASE_STORAGE_PROVIDER=$RELEASE_STORAGE_PROVIDER cannot publish. Only \"aws\" has a storage target; the \"$APP_ENV\" channel does not publish." ;;
  esac
}

# Mirror of publish_upload for reads.
#
# RETURN CONTRACT, shared with publish_object_exists() and both backends:
#   0  the object is present (and, for the download form, has been written to $output_file)
#   1  the object is genuinely absent — the store answered, and the answer was "no"
#   2  could not determine — credentials, network, permissions, a wrong bucket/account
#
# 1 and 2 are NOT interchangeable. Callers act on absence (restore_release_history.sh treats it as
# "first release" and regenerates the appcast from scratch; the overwrite guard treats it as "this
# version is not published yet"), so reporting a failure as absence produces a confident wrong
# answer in both. Every caller must handle 2 explicitly, and the safe handling is to stop.
publish_download_if_exists() {
  local container="$1"
  local blob_name="$2"
  local output_file="$3"

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   s3_download_if_exists "$AWS_RELEASES_BUCKET" "$container" "$blob_name" "$output_file" ;;
    # No silent fall-through. An unmatched `case` returns 0, which would make this seam
    # report success without moving a byte -- the exact silent-success shape the provider
    # switch exists to prevent.
    *)     die "publish_download_if_exists: RELEASE_STORAGE_PROVIDER=$RELEASE_STORAGE_PROVIDER cannot publish. Only \"aws\" has a storage target; the \"$APP_ENV\" channel does not publish." ;;
  esac
}

# Existence probe that does not transfer the object. Same three-state contract as
# publish_download_if_exists(). This exists so the prod overwrite guard can stop hardcoding
# `az storage blob exists` against AZ_STORAGE_ACCOUNT: with RELEASE_STORAGE_PROVIDER=aws that
# guard was interrogating a store nothing publishes to, so it answered "not published" for every
# version and silently permitted an overwrite it was written to prevent.
publish_object_exists() {
  local container="$1"
  local blob_name="$2"

  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   s3_object_exists "$AWS_RELEASES_BUCKET" "$container" "$blob_name" ;;
    # No silent fall-through. An unmatched `case` returns 0, which would make this seam
    # report success without moving a byte -- the exact silent-success shape the provider
    # switch exists to prevent.
    *)     die "publish_object_exists: RELEASE_STORAGE_PROVIDER=$RELEASE_STORAGE_PROVIDER cannot publish. Only \"aws\" has a storage target; the \"$APP_ENV\" channel does not publish." ;;
  esac
}

# Public URL the artifacts are SERVED from. Distinct from where they are UPLOADED to, and the two
# must move together — that is precisely what the first cut of this change got wrong.
#
# generate_appcast bakes DOWNLOAD_BASE_URL into every enclosure url= in the feed, so an endpoint
# left pointing at Azure produces a feed served from clingfy.com whose downloads resolve to a
# storage account that is being retired. The smoke test would eventually catch it (it fetches
# FEED_URL and greps for the new DMG) but only after the upload had already happened, and with a
# message about the feed rather than the endpoint.
configure_public_endpoint() {
  case "$RELEASE_STORAGE_PROVIDER" in
    aws)
      export RELEASE_PUBLIC_ENDPOINT="${RELEASE_PUBLIC_ENDPOINT:-${AWS_PUBLIC_ENDPOINT:-}}"
      [[ -n "$RELEASE_PUBLIC_ENDPOINT" ]]         || die "RELEASE_STORAGE_PROVIDER=aws requires AWS_PUBLIC_ENDPOINT (host + path prefix the releases are served from, e.g. clingfy.com/updates). Set it in .env.$APP_ENV."
      ;;
    none)
      # Must still be exported, even empty: the two compositions below are unconditional and
      # lib/common.sh sets `set -u`, so leaving it unset aborts a local build on an unbound
      # variable instead of letting it finish.
      export RELEASE_PUBLIC_ENDPOINT="${RELEASE_PUBLIC_ENDPOINT:-}"
      ;;
  esac

  export DOWNLOAD_BASE_URL="https://${RELEASE_PUBLIC_ENDPOINT}/${AZ_BINARIES_FOLDER}/"
  export FEED_URL="https://${RELEASE_PUBLIC_ENDPOINT}/${FEED_PATH}"
}

require_release_storage_cli() {
  case "$RELEASE_STORAGE_PROVIDER" in
    aws)   require_aws_cli ;;
    none)  ;;  # nothing to publish with, and nothing to install
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
  configure_public_endpoint
}
