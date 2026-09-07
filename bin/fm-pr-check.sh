#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> and matching pr_green_head=<sha>, then atomically arm a
# static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# Active exact-head delivery accepts GitHub pull request URLs only.
# GitLab URL recognition remains inactive migration compatibility in fm-pr-lib.
# An optional private required-check policy is pinned by path, content hash,
# and policy id in task metadata; every later readiness or merge-time check
# reuses that exact identity. See docs/configuration.md.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--required-check-policy <absolute-json>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-ci-policy-lib.sh
. "$SCRIPT_DIR/fm-pr-ci-policy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lifecycle-lock-lib.sh
. "$SCRIPT_DIR/fm-pr-lifecycle-lock-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
shift 2
POLICY_INPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --required-check-policy)
      [ "$#" -ge 2 ] && [ -z "$POLICY_INPUT" ] || {
        echo "error: invalid PR check request" >&2
        exit 2
      }
      POLICY_INPUT=$2
      shift 2
      ;;
    *)
      echo "error: invalid PR check request" >&2
      exit 2
      ;;
  esac
done
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
# Bounded direct-PR currently has one exact-head check source: GitHub.
# The legacy GitLab poll parser remains inactive migration compatibility, but a
# provider with no exact head/check proof is ambiguous and cannot be armed.
if [ "$PROVIDER" != github ]; then
  echo "error: GitLab PR delivery is inactive migration compatibility; exact-head checking supports GitHub only" >&2
  exit 1
fi

META_TMP=
POLICY_SNAPSHOT=
META_LOCK=
META_LOCK_HELD=0
PR_CHECK_LOCK_HELD=0
pr_check_parent_owns_metadata_lock() {
  local lock=$1 owner pid
  [ -L "$lock" ] || return 1
  owner=$(fm_lock_link_owner "$lock") || return 1
  fm_lock_points_to_owner "$lock" "$owner" || return 1
  pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  [ "$pid" = "$PPID" ] \
    && fm_lock_typed_owner_matches "$owner" "$pid" fm-pr-merge.sh
}
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ -z "$POLICY_SNAPSHOT" ] || rm -f -- "$POLICY_SNAPSHOT"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$PR_CHECK_LOCK_HELD" = 1 ]; then
    fm_pr_lifecycle_lock_release "$STATE" "$ID" check || true
    PR_CHECK_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
case "${FM_PR_LIFECYCLE_PARENT_LOCK:-0}" in
  0)
    fm_pr_lifecycle_lock_acquire "$STATE" "$ID" check \
      || { echo "error: PR lifecycle ownership is unavailable" >&2; exit 1; }
    PR_CHECK_LOCK_HELD=1
    ;;
  1)
    fm_pr_lifecycle_parent_owns "$STATE" "$ID" merge \
      || { echo "error: parent PR lifecycle ownership is unavailable" >&2; exit 1; }
    ;;
  *)
    echo "error: invalid parent PR lifecycle ownership request" >&2
    exit 1
    ;;
esac
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
TASK_MODE=$(fm_backend_meta_exact_value "$META" mode 2>/dev/null || true)
case "$TASK_MODE" in
  direct-PR) ;;
  local-only)
    echo "error: task $ID is local-only and is not authorized for remote PR delivery; use bin/fm-merge-local.sh $ID" >&2
    exit 1
    ;;
  *)
    echo "error: task $ID delivery mode is missing, ambiguous, or not direct-PR; remote PR delivery is refused" >&2
    exit 1
    ;;
esac
POLICY_META_STATUS=0
fm_pr_ci_policy_meta_parse "$META" || POLICY_META_STATUS=$?
case "$POLICY_META_STATUS" in
  0)
    POLICY_SOURCE=$FM_PR_CI_META_POLICY_PATH
    POLICY_EXPECTED_ID=$FM_PR_CI_META_POLICY_ID
    POLICY_EXPECTED_HASH=$FM_PR_CI_META_POLICY_HASH
    ;;
  2)
    POLICY_SOURCE=$POLICY_INPUT
    POLICY_EXPECTED_ID=
    POLICY_EXPECTED_HASH=
    ;;
  *)
    echo "error: recorded private required-check policy identity is malformed" >&2
    exit 1
    ;;
esac
if [ -n "$POLICY_SOURCE" ]; then
  fm_pr_ci_policy_snapshot "$POLICY_SOURCE" "$STATE" "$OWNER/$REPO" \
    "$POLICY_EXPECTED_ID" "$POLICY_EXPECTED_HASH" || {
    echo "error: private required-check policy is missing, changed, unsafe, or invalid" >&2
    exit 1
  }
  POLICY_SNAPSHOT=$FM_PR_CI_POLICY_SNAPSHOT
  POLICY_SOURCE=$FM_PR_CI_POLICY_SOURCE_PATH
  POLICY_SOURCE_IDENTITY=$FM_PR_CI_POLICY_SOURCE_IDENTITY
  POLICY_ID=$FM_PR_CI_POLICY_ID
  POLICY_HASH=$FM_PR_CI_POLICY_HASH
  if [ -n "$POLICY_INPUT" ]; then
    POLICY_INPUT_REAL=$(realpath "$POLICY_INPUT" 2>/dev/null) || POLICY_INPUT_REAL=
    [ "$POLICY_INPUT_REAL" = "$POLICY_SOURCE" ] || {
      echo "error: private required-check policy cannot change after it is recorded" >&2
      exit 1
    }
  fi
else
  POLICY_SOURCE_IDENTITY=
  POLICY_ID=
  POLICY_HASH=
fi
META_PREIMAGE_HASH=$(fm_pr_sha256 "$META") || exit 1
META_PREIMAGE_IDENTITY=$(fm_pr_file_identity "$META") || exit 1

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

"$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
[ -n "$WT" ] && [ -d "$WT" ] || {
  echo "error: exact-head PR verification requires the recorded task worktree" >&2
  exit 1
}
command -v gh >/dev/null 2>&1 || {
  echo "error: exact-head PR verification requires gh on PATH" >&2
  exit 1
}
PR_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) || PR_HEAD=
if ! fm_pr_head_valid "$PR_HEAD"; then
  echo "error: could not resolve the exact GitHub PR head" >&2
  exit 1
fi
if [ -n "$POLICY_SNAPSHOT" ]; then
  FM_PR_CI_POLICY_SHA256="$POLICY_HASH" \
    "$SCRIPT_DIR/fm-pr-ci.sh" "$URL" "$PR_HEAD" \
      --attempts "${FM_PR_CI_ATTEMPTS:-30}" --interval "${FM_PR_CI_INTERVAL:-10}" \
      --required-check-policy "$POLICY_SNAPSHOT" || exit 1
  fm_pr_ci_policy_source_unchanged "$POLICY_SOURCE" "$POLICY_SOURCE_IDENTITY" "$POLICY_HASH" || {
    echo "error: private required-check policy changed during exact-head verification" >&2
    exit 1
  }
else
  "$SCRIPT_DIR/fm-pr-ci.sh" "$URL" "$PR_HEAD" \
    --attempts "${FM_PR_CI_ATTEMPTS:-30}" --interval "${FM_PR_CI_INTERVAL:-10}" || exit 1
fi

fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$PR_HEAD" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
case "${FM_PR_METADATA_PARENT_LOCK:-0}" in
  0)
    fm_pr_lifecycle_metadata_lock_acquire "$META" check \
      || { echo "error: task metadata ownership is unavailable" >&2; exit 1; }
    META_LOCK_HELD=1
    ;;
  1)
    pr_check_parent_owns_metadata_lock "$META_LOCK" \
      || { echo "error: parent task metadata ownership is unavailable" >&2; exit 1; }
    ;;
  *)
    echo "error: invalid parent task metadata ownership request" >&2
    exit 1
    ;;
esac
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
[ "$(fm_pr_sha256 "$META")" = "$META_PREIMAGE_HASH" ] \
  && [ "$(fm_pr_file_identity "$META")" = "$META_PREIMAGE_IDENTITY" ] \
  || { echo "error: task metadata changed during exact-head verification" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|pr_green_head=*|pr_ci_policy_path=*|pr_ci_policy_sha256=*|pr_ci_policy_id=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
printf 'pr_green_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
if [ -n "$POLICY_SNAPSHOT" ]; then
  fm_pr_ci_policy_source_unchanged "$POLICY_SOURCE" "$POLICY_SOURCE_IDENTITY" "$POLICY_HASH" || {
    echo "error: private required-check policy changed before its identity was recorded" >&2
    exit 1
  }
  printf 'pr_ci_policy_path=%s\n' "$POLICY_SOURCE" >> "$META_TMP" || exit 1
  printf 'pr_ci_policy_sha256=%s\n' "$POLICY_HASH" >> "$META_TMP" || exit 1
  printf 'pr_ci_policy_id=%s\n' "$POLICY_ID" >> "$META_TMP" || exit 1
fi
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] && [ "$FM_PR_META_HEAD" = "$PR_HEAD" ] \
  && [ "$FM_PR_META_GREEN_HEAD" = "$PR_HEAD" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] && [ "$FM_PR_META_HEAD" = "$PR_HEAD" ] \
  && [ "$FM_PR_META_GREEN_HEAD" = "$PR_HEAD" ] || exit 1
fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
if [ "$META_LOCK_HELD" = 1 ]; then
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
fi
printf 'armed: state/%s.check.sh\n' "$ID"
