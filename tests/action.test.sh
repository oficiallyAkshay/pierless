#!/usr/bin/env bash
# tests/action.test.sh — action.yml: composite, required inputs present,
# no third-party `uses:`, no checkout step. Text assertions on the file
# (no actionlint dependency here; the Makefile/CI wire actionlint
# separately).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION_FILE="$REPO_ROOT/action.yml"
require_script "$ACTION_FILE"

content="$(cat "$ACTION_FILE")"

assert_contains "$content" "using: composite" "action: is a composite action"

for input in repo on_failure on_recovery on_park state_dir; do
  if printf '%s\n' "$content" | grep -qE "^  ${input}:"; then
    pass "action: input '${input}' present"
  else
    fail "action: input '${input}' present (not found)"
  fi
done

assert_contains "$content" "PIERLESS_ON_PARK: \${{ inputs.on_park }}" "action: on_park input mapped to PIERLESS_ON_PARK env"
assert_contains "$content" "PIERLESS_STATE_DIR: \${{ inputs.state_dir }}" "action: state_dir input mapped to PIERLESS_STATE_DIR env on the deploy step"

# No third-party `uses:` at all — this action never checks anything out
# and calls no other action.
uses_lines="$(printf '%s\n' "$content" | grep -E '^\s*uses:' || true)"
assert_empty "$uses_lines" "action: no 'uses:' of any action (third-party or otherwise)"

assert_not_contains "$content" "actions/checkout" "action: no checkout step"

test_summary_and_exit
