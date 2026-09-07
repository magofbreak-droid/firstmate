#!/usr/bin/env bash
# Behavior tests for the canonical zero-token verifier and exact-head PR CI wait.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bounded-direct-pr)
TMP_ROOT=$(realpath "$TMP_ROOT")
VERIFY="$ROOT/bin/fm-verify.sh"
PR_CI="$ROOT/bin/fm-pr-ci.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"

make_verify_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.agents/skills" "$dir/.claude"
  cp "$VERIFY" "$dir/bin/fm-verify.sh"
  cat > "$dir/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_LINT_ARGS:?}"
printf 'lint-ok\n'
SH
  chmod +x "$dir/bin/fm-verify.sh" "$dir/bin/fm-lint.sh"
  printf '%s\n' '@AGENTS.md' > "$dir/CLAUDE.md"
  ln -s ../.agents/skills "$dir/.claude/skills"
  printf '%s\n' '# fixture' > "$dir/AGENTS.md"
  git -C "$dir" init -q
  git -C "$dir" add AGENTS.md CLAUDE.md .claude/skills bin/fm-lint.sh bin/fm-verify.sh
}

test_canonical_verify_contract() {
  local dir out status lint_args
  dir="$TMP_ROOT/verify"
  make_verify_fixture "$dir"
  lint_args="$dir/lint-args"

  out=$(FM_ROOT_OVERRIDE="$dir" FM_TEST_LINT_ARGS="$lint_args" "$dir/bin/fm-verify.sh" 2>&1) \
    || fail "canonical verifier rejected a valid repository fixture: $out"
  [ "$(cat "$lint_args")" = --full ] \
    || fail "canonical verifier did not select the full repository lint by default"
  assert_contains "$out" "verified: canonical repository checks passed" \
    "canonical verifier did not report its deterministic success"

  out=$(FM_ROOT_OVERRIDE="$dir" FM_TEST_LINT_ARGS="$lint_args" \
    "$dir/bin/fm-verify.sh" --base-ref deadbeef 2>&1) \
    || fail "canonical verifier rejected a supplied PR base: $out"
  [ "$(cat "$lint_args")" = "--base-ref deadbeef" ] \
    || fail "canonical verifier did not forward the exact PR base to lint"

  printf '%s\n' '@WRONG.md' > "$dir/CLAUDE.md"
  status=0
  out=$(FM_ROOT_OVERRIDE="$dir" FM_TEST_LINT_ARGS="$lint_args" "$dir/bin/fm-verify.sh" 2>&1) || status=$?
  expect_code 1 "$status" "canonical verifier must reject a wrong CLAUDE.md target"
  assert_contains "$out" "CLAUDE.md must point to AGENTS.md" \
    "wrong instruction alias refusal was not diagnostic"

  printf '%s\n' '@AGENTS.md' > "$dir/CLAUDE.md"
  mkdir -p "$dir/data"
  printf '%s\n' secret > "$dir/data/tracked.txt"
  git -C "$dir" add -f data/tracked.txt
  status=0
  out=$(FM_ROOT_OVERRIDE="$dir" FM_TEST_LINT_ARGS="$lint_args" "$dir/bin/fm-verify.sh" 2>&1) || status=$?
  expect_code 1 "$status" "canonical verifier must reject tracked private fleet data"
  assert_contains "$out" "private fleet paths are tracked" \
    "tracked-private-path refusal was not diagnostic"
  pass "fm-verify provides one deterministic zero-token repository gate"
}

make_pr_fixture() {
  local dir=$1 head=$2 check_runs=$3 statuses=${4:-}
  mkdir -p "$dir/fakebin" "$dir/home/state" "$dir/wt" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\n' "$check_runs" > "$dir/check-runs"
  printf '%s\n' "$statuses" > "$dir/statuses"
  : > "$dir/requirements"
  : > "$dir/rules"
  : > "$dir/gh.log"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *"/branches/"*"/protection"*)
    if [ "${FM_TEST_CLASSIC_PLAN_UNAVAILABLE:-0}" = 1 ]; then
      printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' >&2
      printf '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'
      exit 1
    fi
    if [ "${FM_TEST_CLASSIC_UNPROTECTED:-0}" = 1 ]; then
      printf 'gh: Branch not protected (HTTP 404)\n' >&2
      exit 1
    fi
    if [ "${FM_TEST_CLASSIC_FORBIDDEN:-0}" = 1 ]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
      printf '{"message":"Resource not accessible by integration","status":"403"}'
      exit 1
    fi
    if [ -n "${FM_TEST_CLASSIC_PAYLOAD:-}" ]; then
      jq_filter=
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --jq ] && [ "$#" -ge 2 ]; then
          jq_filter=$2
          break
        fi
        shift
      done
      [ -n "$jq_filter" ] || exit 2
      "$FM_TEST_REAL_JQ" -r "$jq_filter" "$FM_TEST_CLASSIC_PAYLOAD"
      exit
    fi
    cat "$FM_TEST_REQUIREMENTS"
    ;;
  *"/rules/branches/"*)
    if [ "${FM_TEST_RULES_PLAN_UNAVAILABLE:-0}" = 1 ]; then
      printf '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'
      printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' >&2
      exit 1
    fi
    if [ "${FM_TEST_RULES_FORBIDDEN:-0}" = 1 ]; then
      printf '{"message":"Resource not accessible by integration","status":"403"}'
      printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
      exit 1
    fi
    cat "$FM_TEST_RULES"
    ;;
  *"/check-runs?"*)
    [ -z "${FM_TEST_MUTATE_POLICY:-}" ] || printf ' ' >> "$FM_TEST_MUTATE_POLICY"
    [ -z "${FM_TEST_ABA_MID_HEAD:-}" ] || printf '%s\n' "$FM_TEST_ABA_MID_HEAD" > "$FM_TEST_HEAD"
    cat "$FM_TEST_CHECK_RUNS"
    ;;
  *"/status?"*)
    [ -z "${FM_TEST_ABA_FINAL_HEAD:-}" ] || printf '%s\n' "$FM_TEST_ABA_FINAL_HEAD" > "$FM_TEST_HEAD"
    cat "$FM_TEST_STATUSES"
    ;;
  *" baseRefName "*) printf '%s\n' main ;;
  *" headRefOid "*) cat "$FM_TEST_HEAD" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
}

run_pr_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_HEAD="$dir/head" FM_TEST_CHECK_RUNS="$dir/check-runs" \
    FM_TEST_STATUSES="$dir/statuses" FM_TEST_REQUIREMENTS="$dir/requirements" \
    FM_TEST_RULES="$dir/rules" FM_TEST_REAL_JQ="$(command -v jq)" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_PR_CI_ATTEMPTS=1 FM_PR_CI_INTERVAL=0 \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$@" 2>&1
}

run_pr_ci() {
  local dir=$1 expected=$2 real_jq
  shift 2
  real_jq=$(command -v jq) || return 1
  FM_TEST_HEAD="$dir/head" FM_TEST_CHECK_RUNS="$dir/check-runs" \
    FM_TEST_STATUSES="$dir/statuses" FM_TEST_REQUIREMENTS="$dir/requirements" \
    FM_TEST_RULES="$dir/rules" \
    FM_TEST_CLASSIC_PAYLOAD="${FM_TEST_CLASSIC_PAYLOAD:-}" FM_TEST_REAL_JQ="$real_jq" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CI" https://github.com/example/repo/pull/7 "$expected" \
      --attempts 1 --interval 0 "$@" 2>&1
}

write_private_policy() {
  local path=$1 repository=${2:-example/repo} base=${3:-main}
  cat > "$path" <<JSON
{
  "version": 1,
  "id": "example-main-ci-v1",
  "repository": "$repository",
  "base": "$base",
  "required_checks": [
    {"context": "runtime", "app_id": 15368, "app_slug": "github-actions"},
    {"context": "webui", "app_id": 15368, "app_slug": "github-actions"}
  ]
}
JSON
  chmod 0600 "$path"
}

test_private_plan_policy_contract() {
  local dir out policy sha status
  sha=3333333333333333333333333333333333333333
  dir="$TMP_ROOT/pr-private-policy"
  policy="$dir/policy.json"
  make_pr_fixture "$dir" "$sha" '' ''
  write_private_policy "$policy"
  printf 'result\tcheck\t%s\truntime\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"

  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") \
    || fail "approved private-plan policy rejected exact-head success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=2" \
    "private-plan policy did not verify its declared exact-head checks"

  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "plan-unavailable requirements without an explicit policy must remain unavailable"

  printf '%s\n' '{}' > "$dir/malformed.json"
  chmod 0600 "$dir/malformed.json"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$dir/malformed.json") || status=$?
  expect_code 1 "$status" "a malformed private policy must be refused"
  assert_contains "$out" "private required-check policy is unavailable, unsafe, or invalid" \
    "malformed policy refusal was not diagnostic"

  status=0
  out=$(run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "an explicit private policy must not replace available server requirements"
  assert_contains "$out" "required checks are unavailable for base branch main" \
    "requirement-source switching was not refused"

  status=0
  out=$(FM_TEST_CLASSIC_FORBIDDEN=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "a generic 403 must not activate a private policy"
  assert_contains "$out" "required checks are unavailable for base branch main" \
    "generic permission failure was not kept distinct from plan unavailability"

  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "one unavailable requirement endpoint must not activate a private policy"

  write_private_policy "$dir/wrong-repo.json" other/repo main
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$dir/wrong-repo.json") || status=$?
  expect_code 1 "$status" "a repository-mismatched private policy must be refused"
  assert_contains "$out" "private required-check policy is unavailable, unsafe, or invalid" \
    "repository mismatch did not fail at policy validation"

  write_private_policy "$dir/wrong-base.json" example/repo trunk
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$dir/wrong-base.json") || status=$?
  expect_code 1 "$status" "a base-mismatched private policy must be refused"

  printf 'result\tcheck\t%s\truntime\tcompleted\tsuccess\t99\tgithub-actions\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "a policy provider-id mismatch must not be green"
  assert_contains "$out" "required check provider mismatch: runtime" \
    "policy provider-id mismatch was not diagnostic"

  printf 'result\tcheck\t%s\truntime\tcompleted\tsuccess\t15368\tother-app\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "a policy provider-slug mismatch must not be green"
  assert_contains "$out" "required check provider mismatch: runtime" \
    "policy provider-slug mismatch was not diagnostic"

  printf 'result\tcheck\t%s\truntime\tin_progress\tnone\t15368\tgithub-actions\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "a pending policy check must not be green"
  assert_contains "$out" "check is not terminal-successful: runtime" \
    "pending policy check refusal was not diagnostic"

  printf 'result\tcheck\t%s\truntime\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    FM_TEST_MUTATE_POLICY="$policy" \
    run_pr_ci "$dir" "$sha" --required-check-policy "$policy") || status=$?
  expect_code 1 "$status" "policy bytes changed during a snapshot must be refused"
  assert_contains "$out" "required checks are unavailable for base branch main" \
    "policy mutation did not invalidate the requirement snapshot"
}

test_private_policy_task_continuity() {
  local dir out policy sha status meta
  sha=4444444444444444444444444444444444444444
  dir="$TMP_ROOT/pr-private-policy-task"
  policy="$dir/policy.json"
  meta="$dir/home/state/task-a.meta"
  make_pr_fixture "$dir" "$sha" '' ''
  write_private_policy "$policy"
  printf 'window=fixture\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\n' \
    "$dir/wt" "$dir/project" > "$meta"
  chmod 0600 "$meta"
  printf 'result\tcheck\t%s\truntime\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\twebui\tcompleted\tsuccess\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"

  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/7 \
      --required-check-policy "$policy") \
    || fail "task readiness rejected an approved private policy: $out"
  grep -qxF "pr_ci_policy_path=$policy" "$meta" \
    || fail "task readiness did not pin the canonical policy path"
  grep -Eq '^pr_ci_policy_sha256=[0-9a-f]{64}$' "$meta" \
    || fail "task readiness did not pin the policy bytes"
  grep -qxF 'pr_ci_policy_id=example-main-ci-v1' "$meta" \
    || fail "task readiness did not pin the policy id"

  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/7) \
    || fail "merge-time readiness did not reuse the recorded policy: $out"

  printf ' ' >> "$policy"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/7) || status=$?
  expect_code 1 "$status" "changed recorded policy bytes must stop merge-time readiness"
  assert_contains "$out" "private required-check policy is missing, changed, unsafe, or invalid" \
    "changed recorded policy did not produce a bounded refusal"

  rm -f "$policy"
  status=0
  out=$(FM_TEST_CLASSIC_PLAN_UNAVAILABLE=1 FM_TEST_RULES_PLAN_UNAVAILABLE=1 \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/7) || status=$?
  expect_code 1 "$status" "deleted recorded policy must not return to server requirements"
  assert_contains "$out" "private required-check policy is missing, changed, unsafe, or invalid" \
    "deleted recorded policy did not preserve the task's policy requirement"
}

test_exact_head_green_contract() {
  local dir other out status sha
  sha=1111111111111111111111111111111111111111
  dir="$TMP_ROOT/pr-green"
  make_pr_fixture "$dir" "$sha" '' ''
  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  out=$(run_pr_ci "$dir" "$sha") \
    || fail "exact-head wait rejected terminal success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=1" \
    "exact-head wait did not report the verified identity"
  assert_grep "repos/example/repo/commits/$sha/check-runs?filter=latest&per_page=100" "$dir/gh.log" \
    "exact-head wait did not query check runs by commit SHA"
  assert_grep "repos/example/repo/commits/$sha/status?per_page=100" "$dir/gh.log" \
    "exact-head wait did not query commit statuses by commit SHA"
  assert_grep 'repos/example/repo/branches/main/protection' "$dir/gh.log" \
    "exact-head wait did not query base-branch protection"
  assert_grep 'repos/example/repo/rules/branches/main' "$dir/gh.log" \
    "exact-head wait did not query effective base-branch rules"

  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\tVerify complete main repository\tcompleted\tskipped\t15368\tgithub-actions\n' \
    "$sha" "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  out=$(run_pr_ci "$dir" "$sha") \
    || fail "an optional skipped workflow job blocked required-check success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=1" \
    "exact-head wait counted or rejected a non-required skipped workflow job"

  printf '%s\n' \
    $'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone' \
    $'require\trequired\tnone\tsecurity\tnone\tnone\t42\tnone' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a missing required context must not be green"
  assert_contains "$out" "required check is missing: security" \
    "missing-required-context refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\tany\tnone\n' > "$dir/requirements"
  : > "$dir/check-runs"
  printf 'result\tstatus\t%s\tVerify exact PR head\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a same-named commit status must not prove the canonical workflow"
  assert_contains "$out" "canonical Verify exact PR head result is not an authorized GitHub Actions check run" \
    "same-named-status refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t99\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a provider-mismatched check must not be green"
  assert_contains "$out" "required check provider mismatch: Verify exact PR head" \
    "provider-mismatch refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"

  printf 'result\tcheck\t%s\tVerify exact PR head\tin_progress\tnone\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tpolicy\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "pending checks must not be green"
  assert_contains "$out" "canonical Verify exact PR head check is not terminal-successful" \
    "pending canonical-check refusal was not diagnostic"

  printf 'result\tcheck\t%s\tpolicy\tcompleted\tsuccess\t42\tpolicy-app\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tsecurity\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "an all-pass summary without the canonical job must not be green"
  assert_contains "$out" "canonical Verify exact PR head check is missing" \
    "missing canonical-check refusal was not diagnostic"

  printf '%s\n' 2222222222222222222222222222222222222222 > "$dir/head"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a different PR head must not reuse old green checks"
  assert_contains "$out" "expected head $sha" "wrong-head refusal omitted the expected SHA"

  printf '%s\n' "$sha" > "$dir/head"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tVerify exact PR head\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "duplicate check identities must be ambiguous"
  assert_contains "$out" "ambiguous exact-head check evidence" \
    "duplicate-check refusal did not identify ambiguity"

  : > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "missing checks must not be green"
  assert_contains "$out" "no exact-head checks or statuses were found" \
    "missing-check refusal was not diagnostic"

  other=2222222222222222222222222222222222222222
  printf '%s\n' "$sha" > "$dir/head"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$other" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(FM_TEST_ABA_MID_HEAD="$other" FM_TEST_ABA_FINAL_HEAD="$sha" run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "an A-to-B-to-A PR race must not attach B checks to A"
  assert_contains "$out" "different-head check evidence" \
    "A-to-B-to-A refusal did not identify the different check head"

  printf 'require\trequired\tnone\tsecurity\tnone\tnone\t42\tnone\n' > "$dir/rules"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a ruleset-only missing context must not be green"
  assert_contains "$out" "required check is missing: security" \
    "ruleset-only missing-context refusal was not diagnostic"

  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\tsecurity\tcompleted\tsuccess\t99\tsecurity-app\n' \
    "$sha" "$sha" > "$dir/check-runs"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a ruleset provider mismatch must not be green"
  assert_contains "$out" "required check provider mismatch: security" \
    "ruleset provider mismatch refusal was not diagnostic"

  : > "$dir/requirements"
  printf '%s\n' \
    $'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone' \
    $'require\trequired\tnone\tsecurity\tnone\tnone\t42\tnone' > "$dir/rules"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\nresult\tcheck\t%s\tsecurity\tcompleted\tsuccess\t42\tsecurity-app\n' \
    "$sha" "$sha" > "$dir/check-runs"
  out=$(FM_TEST_CLASSIC_UNPROTECTED=1 run_pr_ci "$dir" "$sha") \
    || fail "ruleset-only required checks rejected terminal success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=2" \
    "ruleset-only exact-head verification did not report green"

  printf '%s\n' '{"required_status_checks":null}' > "$dir/classic-null.json"
  out=$(FM_TEST_CLASSIC_PAYLOAD="$dir/classic-null.json" run_pr_ci "$dir" "$sha") \
    || fail "a valid null classic check set rejected ruleset-only success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=2" \
    "null classic checks did not defer to the effective ruleset requirements"

  printf '%s\n' '{}' > "$dir/classic-malformed.json"
  status=0
  out=$(FM_TEST_CLASSIC_PAYLOAD="$dir/classic-malformed.json" run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a missing classic-check field must remain malformed"
  assert_contains "$out" "required checks are unavailable for base branch main" \
    "malformed classic branch protection was not rejected"

  status=0
  out=$(FM_TEST_CLASSIC_FORBIDDEN=1 run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "classic branch-protection permission errors must remain unavailable"
  assert_contains "$out" "required checks are unavailable for base branch main" \
    "classic branch-protection permission refusal was not diagnostic"
  pass "fm-pr-ci accepts only terminal success for the exact PR head"
}

test_canonical_verify_contract
test_private_plan_policy_contract
test_private_policy_task_continuity
test_exact_head_green_contract
echo "# all bounded direct-PR tests passed"
