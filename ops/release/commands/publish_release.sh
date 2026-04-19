#!/usr/bin/env bash
# publish_release.sh

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_config.sh"

log_step "STEP 5: Publishing release"

require_azure_cli
require_sparkle_tool
ensure_command curl
ensure_command zip
ensure_command python3

[[ -f "$DMG_OUTPUT" ]] || die "DMG not found: $DMG_OUTPUT"
[[ -n "${SPARKLE_KEY_PATH:-}" ]] || die "SPARKLE_KEY_PATH is missing"

safe_mkdir "$RELEASE_ARCHIVE"

extract_release_notes "$APP_VERSION" "$CHANGELOG_FILE" "$RELEASE_NOTES_TEMP"

release_dmg_path="$RELEASE_ARCHIVE/$FINAL_DMG_NAME"
cp "$DMG_OUTPUT" "$release_dmg_path"

notes_filename="${FINAL_DMG_NAME%.*}.html"
notes_html_path="$RELEASE_ARCHIVE/$notes_filename"

convert_release_notes_markdown_to_html() {
  local input_file="$1"
  local output_file="$2"

  cat > "$output_file" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    :root {
      --bg-color: #ffffff;
      --text-color: #333333;
      --muted-text-color: #666666;
      --accent-color: #8957e5;
      --border-color: #eeeeee;
      --code-bg: #f6f6f8;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg-color: #1e1e1e;
        --text-color: #e0e0e0;
        --muted-text-color: #b8b8b8;
        --accent-color: #9467e7;
        --border-color: #444444;
        --code-bg: #2a2a2d;
      }
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background-color: var(--bg-color);
      color: var(--text-color);
      font-size: 13px;
      line-height: 1.5;
      padding: 12px 16px;
      margin: 0;
    }

    p {
      margin: 0 0 12px 0;
    }

    h2, h3 {
      color: var(--accent-color);
      font-weight: 600;
      margin-top: 16px;
      margin-bottom: 8px;
      padding-bottom: 4px;
      border-bottom: 1px solid var(--border-color);
    }

    h2 {
      font-size: 16px;
      margin-top: 0;
    }

    h3 {
      font-size: 15px;
    }

    ul {
      margin: 0 0 16px 0;
      padding-left: 20px;
    }

    li {
      margin-bottom: 6px;
    }

    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, "Courier New", monospace;
      font-size: 12px;
      background: var(--code-bg);
      padding: 1px 4px;
      border-radius: 4px;
    }
  </style>
</head>
<body>
EOF

  python3 - "$input_file" >> "$output_file" <<'PY'
import html
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

in_list = False
paragraph_lines = []

def render_inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    return s

def flush_paragraph():
    global paragraph_lines
    if paragraph_lines:
        joined = " ".join(line.strip() for line in paragraph_lines if line.strip())
        if joined:
            print(f"<p>{render_inline(joined)}</p>")
        paragraph_lines = []

def close_list():
    global in_list
    if in_list:
        print("</ul>")
        in_list = False

for raw in text:
    line = raw.rstrip()

    if not line.strip():
        flush_paragraph()
        close_list()
        continue

    if line.startswith("### "):
        flush_paragraph()
        close_list()
        print(f"<h3>{render_inline(line[4:])}</h3>")
    elif line.startswith("## "):
        flush_paragraph()
        close_list()
        print(f"<h2>{render_inline(line[3:])}</h2>")
    elif line.startswith("- "):
        flush_paragraph()
        if not in_list:
            print("<ul>")
            in_list = True
        print(f"<li>{render_inline(line[2:])}</li>")
    else:
        close_list()
        paragraph_lines.append(line)

flush_paragraph()
close_list()
PY

  cat >> "$output_file" <<'EOF'
</body>
</html>
EOF
}

log_info "Converting release notes markdown to HTML"
convert_release_notes_markdown_to_html "$RELEASE_NOTES_TEMP" "$notes_html_path"

log_info "Generating appcast with: $SPARKLE_BIN"
"$SPARKLE_BIN" "$RELEASE_ARCHIVE" \
  -o "$APPCAST_XML" \
  --download-url-prefix "$DOWNLOAD_BASE_URL" \
  --embed-release-notes \
  --ed-key-file "$SPARKLE_KEY_PATH"

log_info "Uploading DMG"
az_upload_blob "$AZ_STORAGE_ACCOUNT" "$AZ_CONTAINER" "$release_dmg_path" "${AZ_BINARIES_FOLDER}/$FINAL_DMG_NAME"

log_info "Uploading appcast.xml"
az_upload_blob "$AZ_STORAGE_ACCOUNT" "$AZ_CONTAINER" "$APPCAST_XML" "$APPCAST_BLOB_PATH"

log_info "Uploading deltas"
while IFS= read -r -d '' delta_path; do
  delta_name="$(basename "$delta_path")"
  az_upload_blob "$AZ_STORAGE_ACCOUNT" "$AZ_CONTAINER" "$delta_path" "${AZ_BINARIES_FOLDER}/$delta_name"
done < <(find "$RELEASE_ARCHIVE" -type f -name "*.delta" -print0)

log_info "Uploading dSYMs to Azure"
if [[ -d "$ARCHIVE_PATH/dSYMs" ]]; then
  if (
    cd "$ARCHIVE_PATH/dSYMs"
    shopt -s nullglob
    files=( *.dSYM )
    ((${#files[@]} > 0)) || exit 2
    zip -qry "$RELEASE_ARCHIVE/$DSYM_ZIP" "${files[@]}"
  ); then
    az_upload_blob \
      "$AZ_STORAGE_ACCOUNT" \
      "$AZ_CONTAINER_SYMBOLS" \
      "$RELEASE_ARCHIVE/$DSYM_ZIP" \
      "${AZ_SYMBOLS_BLOB_PREFIX}${DSYM_ZIP}"
    log_success "dSYMs uploaded to Azure"
  else
    log_warn "No .dSYM bundles found. Skipping Azure symbols upload."
  fi
else
  log_warn "dSYMs folder not found: $ARCHIVE_PATH/dSYMs"
fi

log_info "Uploading symbols to Sentry (non-blocking)"
if [[ -n "${SENTRY_AUTH_TOKEN:-}" && -n "${SENTRY_ORG:-}" && -n "${SENTRY_PROJECT:-}" ]]; then
  rm -rf "$PROJECT_ROOT/build/symbols"
  safe_mkdir "$PROJECT_ROOT/build/symbols"

  if [[ -d "$ARCHIVE_PATH/dSYMs" ]]; then
    cp -R "$ARCHIVE_PATH/dSYMs/"* "$PROJECT_ROOT/build/symbols/" 2>/dev/null || true
  fi

  if compgen -G "$PROJECT_ROOT/build/symbols/*.dSYM" >/dev/null; then
    if ! (
      cd "$PROJECT_ROOT"
      dart run sentry_dart_plugin
    ); then
      log_warn "Sentry symbol upload failed. Continuing release."
    fi
  else
    log_warn "No staged .dSYM bundles for Sentry. Skipping."
  fi
else
  log_warn "Sentry env vars missing. Skipping Sentry upload."
fi

log_info "Purging Azure Front Door cache"
purge_frontdoor_paths \
  "$AZ_RESOURCE_GROUP" \
  "$AZ_CDN_PROFILE" \
  "$AZ_FRONTDOOR_ENDPOINT_NAME" \
  "$AZ_CDN_ENDPOINT" \
  "/${FEED_PATH}" \
  "/${AZ_BINARIES_FOLDER}/${FINAL_DMG_NAME}"

log_info "Smoke testing published assets"

appcast_ok="false"
for _attempt in {1..9}; do
  if curl -fsS "$FEED_URL" | grep -q "$FINAL_DMG_NAME"; then
    appcast_ok="true"
    break
  fi
  sleep 5
done

[[ "$appcast_ok" == "true" ]] || die "Smoke test failed: appcast.xml does not reference $FINAL_DMG_NAME"

dmg_url="${DOWNLOAD_BASE_URL}${FINAL_DMG_NAME}"
dmg_status="$(curl -sSIL -o /dev/null -w "%{http_code}" "$dmg_url" || true)"
[[ "$dmg_status" == "200" ]] || die "Smoke test failed: DMG returned HTTP $dmg_status"

log_success "Release published successfully"
log_info "Download URL: $dmg_url"