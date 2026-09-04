#!/usr/bin/env bash
# Canonical deterministic repository verification for local work and CI.
#
# This command intentionally runs no model and no behavioral test corpus.
# Targeted and full behavioral validation remain explicit fm-test-run.sh calls.
# Usage: fm-verify.sh [--base-ref <git-ref>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

lint_args=(--full)
if [ "$#" -ne 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --base-ref ] && [ -n "$2" ] || {
    echo "error: usage: fm-verify.sh [--base-ref <git-ref>]" >&2
    exit 2
  }
  lint_args=(--base-ref "$2")
fi

cd "$FM_ROOT"
"$FM_ROOT/bin/fm-lint.sh" "${lint_args[@]}"

if ! { [ -f CLAUDE.md ] && [ ! -L CLAUDE.md ] && grep -qxF '@AGENTS.md' CLAUDE.md; }; then
  echo "error: CLAUDE.md must point to AGENTS.md" >&2
  exit 1
fi
[ -L .claude/skills ] && [ "$(readlink .claude/skills)" = ../.agents/skills ] || {
  echo "error: .claude/skills must point to ../.agents/skills" >&2
  exit 1
}

tracked_private=$(git ls-files -- data state config projects .no-mistakes)
if [ -n "$tracked_private" ]; then
  echo "error: private fleet paths are tracked:" >&2
  printf '%s\n' "$tracked_private" >&2
  exit 1
fi

echo "verified: canonical repository checks passed"
