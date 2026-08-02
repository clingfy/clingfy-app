#!/usr/bin/env bash
# notify_telegram.sh
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_config.sh"

status="${1:-failure}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  log_warn "Telegram credentials missing. Skipping Telegram notification."
  exit 0
fi

build_id="$(current_build_id)"
branch_name="$(current_branch_name)"
build_url="https://dev.azure.com/clingfy/Clingfy/_build/results?buildId=${build_id}"

# ---------------------------------------------------------
# NEW: Helper to escape HTML for Telegram's strict parser
# ---------------------------------------------------------
escape_html() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  printf '%s' "$text"
}

app_name_esc="$(escape_html "$APP_NAME")"
app_version_esc="$(escape_html "$APP_VERSION")"

message=""

if [[ "$status" == "success" ]]; then
  message+=$'🚀 <b>New Release: '
  message+="${app_name_esc}"
  message+=$' v'
  message+="${app_version_esc}"
  message+=$'</b>\n\n'

  if [[ -f "$RELEASE_NOTES_TEMP" ]]; then
    message+=$'📝 <b>What\'s New:</b>\n'
    # Telegram sendMessage caps a message at 4096 characters and answers a longer
    # one with HTTP 400 "message is too long" — which fails this step, and this
    # step runs BEFORE "Step 6: Create Git Tag", so an over-long changelog
    # publishes the release and then aborts the pipeline before it is tagged.
    # That is exactly what happened on 1.0.7 (5037 chars; 1.0.6 was 2797 and
    # fit by luck, which is why the limit had never been hit).
    #
    # Budget the notes rather than the finished message, and cut on a line
    # boundary before HTML-escaping: truncating escaped text can slice a
    # `&amp;` in half and Telegram then rejects the whole message as malformed
    # HTML — trading a length failure for a parse failure.
    notes_budget=3200
    notes_used=0
    notes_truncated=0
    while IFS= read -r line; do
      line="${line#- }"
      [[ -z "$line" ]] && continue
      if (( notes_used + ${#line} + 3 > notes_budget )); then
        notes_truncated=1
        break
      fi
      notes_used=$(( notes_used + ${#line} + 3 ))
      message+=$'• '
      message+="$(escape_html "$line")"
      message+=$'\n'
    done < "$RELEASE_NOTES_TEMP"
    if (( notes_truncated )); then
      message+=$'…\n<i>Release notes truncated — see the full changelog in the app or on GitHub.</i>\n'
      log_warn "Release notes exceeded ${notes_budget} chars; truncated for Telegram."
    fi
    message+=$'\n'
  fi

  message+=$'📦 <a href="'
  message+="${DOWNLOAD_BASE_URL}${FINAL_DMG_NAME}"
  message+=$'">Download DMG</a>\n'
  message+=$'✅ Release published successfully.'
else
  message+=$'⚠️ <b>Build Failed: '
  message+="${app_name_esc}"
  message+=$'</b>\n'
  message+=$'<b>Branch:</b> '
  message+="$(escape_html "$branch_name")"
  message+=$'\n'
  message+=$'<b>Run ID:</b> '
  message+="${build_id}"
  message+=$'\n\n'
  message+=$'🔗 <a href="'
  message+="${build_url}"
  message+=$'">View Build Logs</a>'
fi

# ---------------------------------------------------------
# NEW: Better curl execution to capture Telegram's error body
# ---------------------------------------------------------
response=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${message}" \
  --data-urlencode "parse_mode=HTML")

# Extract the HTTP status code (last line) and the body (everything else)
http_code=$(tail -n1 <<< "$response")
body=$(sed '$ d' <<< "$response")

if [[ "$http_code" != "200" ]]; then
  log_error "Telegram API failed with HTTP $http_code"
  log_error "Telegram Response: $body"
  # Deliberately NOT fatal.
  #
  # On the success path this runs AFTER "Step 5: Publish Release" and BEFORE
  # "Step 6: Create Git Tag" (azure-pipelines/release-prod.yml). Exiting non-zero
  # here therefore leaves a release that is fully built, notarized, published to
  # the CDN and live on the appcast — but untagged, because the pipeline stops.
  # That happened on 1.0.7: users were being offered the update while the repo
  # had no v1.0.7 tag.
  #
  # A chat notification is not a release gate. Telegram being down, a rotated
  # token, or an over-long message must never cost the tag. The failure is
  # logged loudly above and the step is still visible in the run; the operator
  # can resend by hand.
  log_warn "Continuing anyway — a notification failure must not block the git tag."
  exit 0
fi

log_success "Telegram notification sent (${status})"