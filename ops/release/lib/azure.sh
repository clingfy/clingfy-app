#!/usr/bin/env bash
# azure.sh

require_azure_cli() {
  ensure_command az
}

# Existence probe with a THREE-state result, mirroring s3_object_exists(). See the contract note
# in lib/env.sh: 0 = present, 1 = genuinely absent, 2 = could not determine.
#
# The old inline version read `--query exists -o tsv` through a pipeline, so the az exit status was
# discarded and ANY failure — expired login, wrong account, no network — produced an empty string
# that compared unequal to "true" and was reported as absence. Absence and failure must not look
# alike here: upstream, absence means "first release, regenerate the appcast from scratch".
az_blob_exists() {
  local account="$1"
  local container="$2"
  local blob_name="$3"

  local out
  # No pipeline: `$?` must belong to az itself, not to `tr`.
  if ! out="$(
    az storage blob exists \
      --account-name "$account" \
      --container-name "$container" \
      --name "$blob_name" \
      --auth-mode login \
      --query exists -o tsv 2>&1
  )"; then
    log_warn "Could not determine whether ${account}/${container}/${blob_name} exists: ${out}"
    return 2
  fi

  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    true)  return 0 ;;
    false) return 1 ;;
    *)
      log_warn "Unexpected 'az storage blob exists' output for ${account}/${container}/${blob_name}: ${out}"
      return 2
      ;;
  esac
}

az_blob_download_if_exists() {
  local account="$1"
  local container="$2"
  local blob_name="$3"
  local output_file="$4"

  az_blob_exists "$account" "$container" "$blob_name"
  local probe=$?
  ((probe == 0)) || return "$probe"

  # The unconditional `return 0` that used to sit here was the mirror image of the aws.sh bug and
  # strictly worse: a failed download reported SUCCESS, so the caller carried on believing it held
  # a valid appcast when the file was missing or truncated. Same normalisation as aws.sh -- the
  # probe already said the blob is present, so a failure here is "could not determine", never
  # absence and never success.
  if ! az storage blob download \
    --account-name "$account" \
    --container-name "$container" \
    --name "$blob_name" \
    --file "$output_file" \
    --auth-mode login \
    --overwrite \
    --only-show-errors >/dev/null; then
    log_warn "az_blob_exists found ${container}/${blob_name} but the download failed. This is not absence."
    return 2
  fi

  return 0
}

az_upload_blob() {
  local account="$1"
  local container="$2"
  local local_file="$3"
  local blob_name="$4"

  az storage blob upload \
    --account-name "$account" \
    --container-name "$container" \
    --file "$local_file" \
    --name "$blob_name" \
    --auth-mode login \
    --overwrite \
    --only-show-errors >/dev/null
}

purge_frontdoor_paths() {
  local resource_group="$1"
  local profile_name="$2"
  local endpoint_name="$3"
  local domain="$4"
  shift 4
  local content_paths=("$@")

  az afd endpoint purge \
    --resource-group "$resource_group" \
    --profile-name "$profile_name" \
    --endpoint-name "$endpoint_name" \
    --domains "$domain" \
    --content-paths "${content_paths[@]}"
}
