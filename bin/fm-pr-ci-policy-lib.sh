#!/usr/bin/env bash
# Private required-check policy parsing and immutable snapshot helpers.
#
# docs/configuration.md "Private GitHub required-check policy" owns the public
# schema and activation contract. This library is the sole executable parser.
# Callers must source bin/fm-pr-lib.sh first.

fm_pr_ci_policy_id_valid() {
  local value=${1-}
  case "$value" in
    ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) return 1 ;;
  esac
  [ "${#value}" -le 128 ]
}

fm_pr_ci_policy_hash_valid() {
  local value=${1-}
  case "$value" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#value}" -eq 64 ]
}

fm_pr_ci_policy_parse() {  # <file> <owner/repo> <base-or-empty>
  local file=$1 expected_repo=$2 expected_base=$3 parsed header
  FM_PR_CI_POLICY_ID=
  FM_PR_CI_POLICY_HASH=
  FM_PR_CI_POLICY_REQUIREMENTS=
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(fm_pr_file_link_count "$file")" = 1 ] \
    && [ "$(fm_pr_file_mode "$file")" = 600 ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016
  parsed=$(jq -er --arg expected_repo "$expected_repo" --arg expected_base "$expected_base" '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def plain_text($max):
      type == "string" and length > 0 and length <= $max and
      (all(explode[]; . >= 32 and . != 127));
    if type != "object" or
       (exact_keys(["version", "id", "repository", "base", "required_checks"]) | not) or
       .version != 1 or
       (.id | type) != "string" or
       (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") | not) or
       .repository != $expected_repo or
       ($expected_base != "" and .base != $expected_base) or
       (.base | plain_text(255) | not) or
       (.required_checks | type) != "array" or
       (.required_checks | length) < 1 or
       (.required_checks | length) > 64 or
       ([.required_checks[].context] | length) != ([.required_checks[].context] | unique | length) or
       any(.required_checks[];
         type != "object" or
         (exact_keys(["context", "app_id", "app_slug"]) | not) or
         (.context | plain_text(255) | not) or
         (.app_id | type) != "number" or .app_id <= 0 or .app_id != (.app_id | floor) or
         (.app_slug | type) != "string" or
         (.app_slug | test("^[A-Za-z0-9][A-Za-z0-9-]{0,99}$") | not))
    then error("invalid private required-check policy")
    else
      (["policy", .id] | @tsv),
      (.required_checks[] |
        ["require", "required", "policy", .context, "none", "none",
         (.app_id | tostring), .app_slug] | @tsv)
    end
  ' "$file" 2>/dev/null) || return 1
  header=${parsed%%$'\n'*}
  case "$header" in $'policy\t'*) ;; *) return 1 ;; esac
  FM_PR_CI_POLICY_ID=${header#*$'\t'}
  fm_pr_ci_policy_id_valid "$FM_PR_CI_POLICY_ID" || return 1
  FM_PR_CI_POLICY_REQUIREMENTS=${parsed#*$'\n'}
  [ "$FM_PR_CI_POLICY_REQUIREMENTS" != "$parsed" ] || return 1
  FM_PR_CI_POLICY_HASH=$(fm_pr_sha256 "$file") || return 1
  fm_pr_ci_policy_hash_valid "$FM_PR_CI_POLICY_HASH"
}

fm_pr_ci_policy_meta_parse() {  # <task-meta>; returns 0 complete, 2 absent, 1 malformed
  local file=$1 line path_count=0 hash_count=0 id_count=0
  FM_PR_CI_META_POLICY_PATH=
  FM_PR_CI_META_POLICY_HASH=
  FM_PR_CI_META_POLICY_ID=
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr_ci_policy_path=*)
        path_count=$((path_count + 1))
        FM_PR_CI_META_POLICY_PATH=${line#pr_ci_policy_path=}
        ;;
      pr_ci_policy_sha256=*)
        hash_count=$((hash_count + 1))
        FM_PR_CI_META_POLICY_HASH=${line#pr_ci_policy_sha256=}
        ;;
      pr_ci_policy_id=*)
        id_count=$((id_count + 1))
        FM_PR_CI_META_POLICY_ID=${line#pr_ci_policy_id=}
        ;;
    esac
  done < "$file"
  if [ "$path_count" -eq 0 ] && [ "$hash_count" -eq 0 ] && [ "$id_count" -eq 0 ]; then
    return 2
  fi
  [ "$path_count" -eq 1 ] && [ "$hash_count" -eq 1 ] && [ "$id_count" -eq 1 ] \
    && [ "${FM_PR_CI_META_POLICY_PATH#/}" != "$FM_PR_CI_META_POLICY_PATH" ] \
    && fm_pr_ci_policy_hash_valid "$FM_PR_CI_META_POLICY_HASH" \
    && fm_pr_ci_policy_id_valid "$FM_PR_CI_META_POLICY_ID"
}

fm_pr_ci_policy_snapshot() {  # <source> <state-dir> <owner/repo> <expected-id-or-empty> <expected-hash-or-empty>
  local source=$1 state=$2 expected_repo=$3 expected_id=$4 expected_hash=$5
  local resolved source_identity source_hash state_device snapshot snapshot_hash
  FM_PR_CI_POLICY_SNAPSHOT=
  FM_PR_CI_POLICY_SOURCE_PATH=
  FM_PR_CI_POLICY_SOURCE_IDENTITY=
  case "$source" in /*) ;; *) return 1 ;; esac
  [ -f "$source" ] && [ ! -L "$source" ] \
    && [ "$(fm_pr_file_link_count "$source")" = 1 ] \
    && [ "$(fm_pr_file_mode "$source")" = 600 ] || return 1
  resolved=$(realpath "$source" 2>/dev/null) || return 1
  [ "$resolved" = "$source" ] || return 1
  source_identity=$(fm_pr_file_identity "$source") || return 1
  source_hash=$(fm_pr_sha256 "$source") || return 1
  fm_pr_ci_policy_hash_valid "$source_hash" || return 1
  [ -z "$expected_hash" ] || [ "$source_hash" = "$expected_hash" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  snapshot=$(mktemp "$state/.fm-pr-ci-policy.XXXXXX") || return 1
  if ! cp "$source" "$snapshot" || ! chmod 0600 "$snapshot" \
    || ! fm_pr_private_file_valid "$snapshot" 600 "$state_device";
  then
    rm -f -- "$snapshot"
    return 1
  fi
  snapshot_hash=$(fm_pr_sha256 "$snapshot") || {
    rm -f -- "$snapshot"
    return 1
  }
  if [ "$snapshot_hash" != "$source_hash" ] \
    || [ "$(fm_pr_file_identity "$source")" != "$source_identity" ] \
    || [ "$(fm_pr_sha256 "$source")" != "$source_hash" ] \
    || ! fm_pr_ci_policy_parse "$snapshot" "$expected_repo" '' \
    || { [ -n "$expected_id" ] && [ "$FM_PR_CI_POLICY_ID" != "$expected_id" ]; };
  then
    rm -f -- "$snapshot"
    return 1
  fi
  # These globals are the caller's bound snapshot result.
  # shellcheck disable=SC2034
  FM_PR_CI_POLICY_SNAPSHOT=$snapshot
  # shellcheck disable=SC2034
  FM_PR_CI_POLICY_SOURCE_PATH=$resolved
  # shellcheck disable=SC2034
  FM_PR_CI_POLICY_SOURCE_IDENTITY=$source_identity
  return 0
}

fm_pr_ci_policy_source_unchanged() {  # <source> <identity> <sha256>
  local source=$1 identity=$2 expected_hash=$3
  [ -f "$source" ] && [ ! -L "$source" ] \
    && [ "$(fm_pr_file_link_count "$source")" = 1 ] \
    && [ "$(fm_pr_file_mode "$source")" = 600 ] \
    && [ "$(fm_pr_file_identity "$source")" = "$identity" ] \
    && [ "$(fm_pr_sha256 "$source")" = "$expected_hash" ]
}
