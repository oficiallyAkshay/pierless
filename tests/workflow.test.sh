#!/usr/bin/env bash
# tests/workflow.test.sh — .github/workflows/ci.yml: the `ci` gate is the
# one context branch protection requires, so it must wait on every other
# job, and no job may hang without a timeout. Text assertions on the file
# (no actionlint dependency here; the Makefile/CI wire actionlint
# separately, as in tests/action.test.sh).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
CI_FILE="$REPO_ROOT/.github/workflows/ci.yml"
require_script "$CI_FILE"

# Read the ids out of the file rather than listing them here: a job added
# later is then covered the moment it lands, without touching this test.
# Job ids are the only keys indented exactly two spaces under `jobs:`,
# which is the file's last top-level block.
job_ids="$(awk '
  /^jobs:/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { sub(/:.*/, ""); sub(/^  /, ""); print }
' "$CI_FILE")"

# job_block ID — one job's lines, up to the next thing at job level.
job_block() {
  awk -v id="$1" '
    $0 == "  " id ":" { in_block = 1; next }
    in_block && /^  [^ ]/ { in_block = 0 }
    in_block { print }
  ' "$CI_FILE"
}

if printf '%s\n' "$job_ids" | grep -qx 'ci'; then
  pass "workflow: a job named 'ci' exists"
else
  fail "workflow: a job named 'ci' exists (found [$job_ids])"
fi

ci_block="$(job_block ci)"
assert_contains "$ci_block" "if: always()" "workflow: the ci gate runs with if: always()"

ci_needs="$(printf '%s\n' "$ci_block" | grep -E '^    needs:' || true)"
for id in $job_ids; do
  if [ "$id" != "ci" ]; then
    if printf '%s' "$ci_needs" | grep -qE "(^|[^A-Za-z0-9_-])${id}([^A-Za-z0-9_-]|\$)"; then
      pass "workflow: the ci gate needs '$id'"
    else
      fail "workflow: the ci gate needs '$id' (not in [$ci_needs])"
    fi
  fi
done

for id in $job_ids; do
  if job_block "$id" | grep -qE '^    timeout-minutes:'; then
    pass "workflow: job '$id' has a timeout-minutes"
  else
    fail "workflow: job '$id' has a timeout-minutes (none found)"
  fi
done

test_summary_and_exit
