#!/usr/bin/env bash
# tests/lib.test.sh — tests/lib.sh itself. A deleted script under test
# must fail its test file: tests/run.sh counts any output line starting
# with the skip prefix as not yet runnable, so a skip would keep CI green.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

dir="$(new_tmpdir)"
out="$(bash -c 'source "$1"; require_script "$2"; echo "after require_script"' _ "$HERE/lib.sh" "$dir/gone.sh" 2>&1)"
ec=$?
if [ "$ec" -ne 0 ]; then
  pass "require_script: a missing script exits non-zero"
else
  fail "require_script: a missing script exits non-zero (got 0)"
fi
assert_not_contains "$out" "after require_script" "require_script: a missing script stops the file"
assert_contains "$out" "$dir/gone.sh" "require_script: the message names the missing path"
if printf '%s\n' "$out" | grep -q '^SKIP - '; then
  fail "require_script: a missing script is not reported as a skip"
else
  pass "require_script: a missing script is not reported as a skip"
fi

out="$(bash -c 'source "$1"; require_script "$1"; echo "after require_script"' _ "$HERE/lib.sh" 2>&1)"
assert_exit 0 "$?" "require_script: a present script lets the file run"
assert_contains "$out" "after require_script" "require_script: a present script continues"

test_summary_and_exit
