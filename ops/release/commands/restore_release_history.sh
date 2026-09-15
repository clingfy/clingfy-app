#!/usr/bin/env bash
# restore_release_history.sh
set -euo pipefail

# shellcheck source=ops/release/_config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_config.sh"

log_step "STEP 0: Restoring release history"

require_release_storage_cli
safe_mkdir "$RELEASE_ARCHIVE"

# `|| appcast_probe=$?` rather than a bare call: `set -e` is on, and a bare call returning the
# non-zero "absent" status would abort the script instead of reaching the branches below.
appcast_probe=0
publish_download_if_exists "$AZ_CONTAINER" "$APPCAST_BLOB_PATH" "$APPCAST_XML" || appcast_probe=$?

# 2 = the store could not be reached or could not answer. Continuing here is the single most
# damaging thing this script can do: the `else` branch below declares "first release", the appcast
# is then regenerated containing only the new build, and it is published over the real one. Every
# installed Mac would receive a feed with 1.0.0-1.0.7 erased from its update history — and nothing
# would have printed an error. An unreachable store is not an empty store.
if ((appcast_probe == 2)); then
  die "Could not determine whether ${AZ_CONTAINER}/${APPCAST_BLOB_PATH} exists (provider: ${RELEASE_STORAGE_PROVIDER}). Refusing to continue: treating this as a first release would publish an appcast with the entire update history missing. Check credentials and connectivity, then re-run."
fi

if ((appcast_probe == 0)); then
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
    dmg_probe=0
    publish_download_if_exists "$AZ_CONTAINER" "$previous_blob" "$previous_file" || dmg_probe=$?

    case "$dmg_probe" in
      0) log_success "Previous release restored: $latest_dmg" ;;
      # Genuinely absent is survivable: the delta step simply has no baseline to diff against, so
      # this release ships without a delta. Worth a warning, not a stop.
      1) log_warn "Previous DMG referenced in appcast but not found: $previous_blob" ;;
      # Unreachable is different, and saying "not found" here would be a claim the store never
      # made. The appcast itself downloaded fine moments ago, so a failure at this point means
      # something changed mid-run and the next steps are working from an unknown baseline.
      *) die "Could not determine whether ${AZ_CONTAINER}/${previous_blob} exists (provider: ${RELEASE_STORAGE_PROVIDER}). The appcast read succeeded, so this is not a missing object — stopping rather than building a delta against an unknown baseline." ;;
    esac
  else
    log_warn "Could not extract a previous DMG name from appcast.xml"
  fi
else
  log_warn "No existing appcast found. Continuing as first release."
fi
