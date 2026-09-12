#!/usr/bin/env bash
# aws.sh
#
# S3 counterpart to lib/azure.sh, written to the SAME call signatures so the publish scripts can
# dispatch on RELEASE_STORAGE_PROVIDER without reshaping any call site.
#
# Key mapping is 1:1 with the Azure layout and is not a convention we invented — it is what
# CloudFront already requires. The `/updates/*` cache behaviour on the clingfy.com distribution has
# NO path-rewrite function, so the request URI reaches S3 verbatim:
#
#     https://clingfy.com/updates/downloads/Clingfy_1.0.7.dmg  ->  key  updates/downloads/Clingfy_1.0.7.dmg
#     azure container "updates" + blob "downloads/Clingfy_1.0.7.dmg"
#
# so:  S3 key = "<container>/<blob_name>".
#
# Verified against the live bucket on 2026-09-12: updates/appcast.xml, updates/downloads/*.dmg,
# updates/downloads/*.delta, updates/downloads/windows/*.exe, and symbols/*_dSYM.zip all already
# follow it.

require_aws_cli() {
  ensure_command aws
}

# Content-Type must be set explicitly. `aws s3 cp` guesses from the extension and gets the two that
# matter WRONG: a .dmg uploads as binary/octet-stream and a .delta as binary/octet-stream, where the
# objects already in the bucket are application/x-apple-diskimage and application/octet-stream.
# Sparkle is tolerant here, but a feed served as text/plain is not, and drift between old and new
# objects is the kind of thing nobody notices until an update silently stops installing.
aws_content_type_for() {
  local name="$1"
  case "$name" in
    *.xml)    printf 'application/xml' ;;
    *.dmg)    printf 'application/x-apple-diskimage' ;;
    *.delta)  printf 'application/octet-stream' ;;
    *.zip)    printf 'application/x-zip-compressed' ;;
    *.json)   printf 'application/json' ;;
    *.exe)    printf 'application/x-msdownload' ;;
    *.sha256) printf 'text/plain' ;;
    *.html)   printf 'text/html' ;;
    *)        printf 'application/octet-stream' ;;
  esac
}

s3_download_if_exists() {
  local bucket="$1"
  local container="$2"
  local blob_name="$3"
  local output_file="$4"

  local key="${container}/${blob_name}"

  # head-object is the existence probe: it exits non-zero for a missing key, and unlike `s3 ls` it
  # cannot match a PREFIX by accident (`s3 ls .../appcast.xml` also matches appcast.xml.bak-20260702,
  # and this bucket really does carry those .bak objects).
  if ! aws s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>&1; then
    return 1
  fi

  aws s3 cp "s3://${bucket}/${key}" "$output_file" --only-show-errors >/dev/null
}

s3_upload_object() {
  local bucket="$1"
  local container="$2"
  local local_file="$3"
  local blob_name="$4"

  local key="${container}/${blob_name}"
  local content_type
  content_type="$(aws_content_type_for "$blob_name")"

  aws s3 cp "$local_file" "s3://${bucket}/${key}" \
    --content-type "$content_type" \
    --only-show-errors >/dev/null
}

# CloudFront caches /updates/* with the AWS managed CachingOptimized policy, so a republished
# appcast or DMG stays stale at the edge until its TTL lapses. This is the S3 analogue of
# purge_frontdoor_paths(). Paths are passed as they appear in the URL (leading slash).
invalidate_cloudfront_paths() {
  local distribution_id="$1"
  shift
  local paths=("$@")

  ((${#paths[@]} > 0)) || return 0

  aws cloudfront create-invalidation \
    --distribution-id "$distribution_id" \
    --paths "${paths[@]}" \
    --query 'Invalidation.Id' --output text >/dev/null
}
