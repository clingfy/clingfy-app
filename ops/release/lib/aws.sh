#!/usr/bin/env bash
# aws.sh
#
# The storage backend for every published release. It was written to the same call signatures as
# the Azure helpers it replaced (lib/azure.sh, deleted 2026-09-21) so the publish scripts can
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

  s3_object_exists "$bucket" "$container" "$blob_name"
  local probe=$?
  # 1 = genuinely absent, 2 = could not determine. Propagate both verbatim; collapsing 2 into 1
  # here is what made a credentials failure read as "first release" upstream.
  ((probe == 0)) || return "$probe"

  # The probe just said the object is THERE, so a failure here cannot mean absence -- and the
  # bare `aws s3 cp` that used to end this function returned its own exit status, which is 1,
  # which this contract defines as "genuinely absent". That turned a transient download failure
  # into "no appcast exists, this is the first release" in restore_release_history.sh, which
  # republishes a feed containing only the new build and erases the update history of every
  # installed Mac. The careful `return "$probe"` two lines up was undone by the last line of the
  # same function. Normalise to 2 so the caller's existing `die` on 2 actually fires.
  if ! aws s3 cp "s3://${bucket}/${key}" "$output_file" --only-show-errors >/dev/null; then
    log_warn "head-object found s3://${bucket}/${key} but the download failed. This is not absence."
    return 2
  fi
  return 0
}

# Existence probe with a THREE-state result. See the contract note in lib/env.sh:
#   0 = present, 1 = genuinely absent, 2 = could not determine.
#
# The two-state version of this was the highest-damage bug in the release path. `aws s3api
# head-object` exits non-zero for a missing key AND for expired credentials, a wrong bucket, a
# denied policy and a network failure alike; returning 1 for all of them told
# restore_release_history.sh "no appcast exists, this is the first release", which regenerates a
# feed containing only the new build. Every installed Mac would then be offered a feed with
# 1.0.0-1.0.7 erased from its update history. The distinction below is the whole point:
# only a genuine 404/NoSuchKey is absence, everything else is an error.
#
# head-object is also the right probe rather than `s3 ls`: `s3 ls .../appcast.xml` matches by
# PREFIX and would also hit appcast.xml.bak-20260702, which this bucket really does carry.
s3_object_exists() {
  local bucket="$1"
  local container="$2"
  local blob_name="$3"

  local key="${container}/${blob_name}"
  local err
  err="$(aws s3api head-object --bucket "$bucket" --key "$key" 2>&1 >/dev/null)" && return 0

  # The CLI reports a missing key as `An error occurred (404) when calling the HeadObject
  # operation: Not Found`. NoSuchKey appears on some paths/endpoints, so accept either.
  if printf '%s' "$err" | grep -qE '\(404\)|NoSuchKey|Not Found'; then
    # A MISSING BUCKET ALSO ANSWERS 404 with the same wording, so the 404 alone does not mean the
    # key is absent — it can equally mean AWS_RELEASES_BUCKET is misspelled or points at a bucket
    # that was never created. Those must not be reported as absence: upstream, absence of the
    # appcast means "first release, regenerate from scratch", so a typo in one variable would
    # publish a feed with the whole update history gone. Confirm the bucket itself answers before
    # believing the 404. (Caught by a probe test on 2026-09-15, which expected 2 and got 1.)
    local bucket_err
    if ! bucket_err="$(aws s3api head-bucket --bucket "$bucket" 2>&1 >/dev/null)"; then
      log_warn "Could not confirm the bucket s3://${bucket} itself is reachable, so the 404 on ${key} is not evidence the object is absent: ${bucket_err}"
      return 2
    fi
    return 1
  fi

  log_warn "Could not determine whether s3://${bucket}/${key} exists: ${err}"
  return 2
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
