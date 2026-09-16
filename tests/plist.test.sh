#!/usr/bin/env bash
# tests/plist.test.sh — templates/launchd.plist.tmpl: every placeholder
# replaced, the required keys present, and (macOS only) plutil -lint clean.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/launchd.plist.tmpl"
require_script "$TEMPLATE"

dir="$(new_tmpdir)"
rendered="$dir/rendered.plist"

sed \
  -e "s|@@LABEL@@|pierless.runner|g" \
  -e "s|@@RUNNER_DIR@@|/Users/tester/.pierless/runner|g" \
  -e "s|@@HOOK@@|/Users/tester/.pierless/runner/hooks/job-started-gate.sh|g" \
  -e "s|@@ALLOWED_WORKFLOW_REF@@|owner/repo/.github/workflows/deploy.yml@refs/heads/main|g" \
  -e "s|@@ALLOWED_REPOSITORY@@|owner/repo|g" \
  -e "s|@@ALLOWED_REF@@|refs/heads/main|g" \
  -e "s|@@ALLOWED_JOB@@|deploy|g" \
  -e "s|@@LOG@@|/Users/tester/.pierless/runner/runner.log|g" \
  -e "s|@@PATH@@|/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin|g" \
  -e "s|@@HOME@@|/Users/tester|g" \
  "$TEMPLATE" > "$rendered"

content="$(cat "$rendered")"

assert_not_contains "$content" "@@" "plist: no unreplaced @@placeholder@@ remains"
assert_contains "$content" "<key>KeepAlive</key>" "plist: KeepAlive key present"
assert_contains "$content" "ACTIONS_RUNNER_HOOK_JOB_STARTED" "plist: ACTIONS_RUNNER_HOOK_JOB_STARTED present"
assert_contains "$content" "/bin/bash" "plist: /bin/bash present"
assert_contains "$content" "<string>-c</string>" "plist: uses -c"
assert_not_contains "$content" "<string>-lc</string>" "plist: never uses -lc"
assert_contains "$content" "pierless.runner" "plist: label substituted"
assert_contains "$content" "owner/repo/.github/workflows/deploy.yml@refs/heads/main" "plist: allowed workflow ref substituted"

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$rendered" >/dev/null 2>&1; then
    pass "plist: plutil -lint passes"
  else
    fail "plist: plutil -lint failed: $(plutil -lint "$rendered" 2>&1)"
  fi
else
  skip "plist: plutil not on PATH (non-macOS) — lint skipped"
fi

test_summary_and_exit
