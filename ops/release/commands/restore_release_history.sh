#!/usr/bin/env bash
# restore_release_history.sh
set -euo pipefail

# shellcheck source=ops/release/_config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_config.sh"

log_step "STEP 0: Restoring release history"

require_release_storage_cli
safe_mkdir "$RELEASE_ARCHIVE"

if publish_download_if_exists "$AZ_CONTAINER" "$APPCAST_BLOB_PATH" "$APPCAST_XML"; then
# if publish_download_if_exists "$AZ_CONTAINER" "appcast.xml" "$APPCAST_XML"; then
  log_success "Existing appcast.xml downloaded"

  # latest_dmg="$(grep -o 'url="[^"]*"' "$APPCAST_XML" | head -n 1 | sed 's/^url="//; s/"$//' | awk -F/ '{print $NF}')"

  latest_dmg="$(
    grep -oE 'url="[^"]+\.dmg"' "$APPCAST_XML" \
      | head -n 1 \
      | sed 's/^url="//; s/"$//' \
      | awk -F/ '{print $NF}'
  )"

  if [[ -n "$latest_dmg" ]]; then
    previous_blob="${AZ_BINARIES_FOLDER}/${latest_dmg}"
    previous_file="$RELEASE_ARCHIVE/$latest_dmg"

    log_info "Downloading previous release: $previous_blob"
    if publish_download_if_exists "$AZ_CONTAINER" "$previous_blob" "$previous_file"; then
      log_success "Previous release restored: $latest_dmg"
    else
      log_warn "Previous DMG referenced in appcast but not found: $previous_blob"
    fi
  else
    log_warn "Could not extract a previous DMG name from appcast.xml"
  fi
else
  log_warn "No existing appcast found. Continuing as first release."
fi
