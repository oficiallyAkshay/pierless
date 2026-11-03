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

# Run the action's own steps with every optional input at its declared
# default. GitHub does not expand $HOME in an input default, so the value is
# handed to the steps as the literal text. Against a real fixture repo this
# asserts the checkout stays clean and the markers land under the real HOME.

# input_default NAME — the declared default of input NAME, quotes stripped.
input_default() {
  awk -v want="  $1:" '
    $0 == want { inblock = 1; next }
    inblock && /^  [a-z_]+:/ { exit }
    inblock && /^    default:/ {
      sub(/^    default: */, ""); gsub(/"/, ""); print; exit
    }
  ' "$ACTION_FILE"
}

# step_script NAME — the run: body of the step called NAME, de-indented.
step_script() {
  awk -v want="    - name: $1" '
    $0 == want { instep = 1; next }
    instep && /^    - name:/ { exit }
    instep && /^      run: \|/ { inrun = 1; next }
    inrun { sub(/^        /, ""); print }
  ' "$ACTION_FILE"
}

state_default="$(input_default state_dir)"
base="$(new_tmpdir)"
origin="$base/origin.git"
host="$base/host"
dev="$base/dev"
fake_home="$base/home"
outside="$base/outside"
mkdir -p "$fake_home" "$outside"

git init --bare -q "$origin"
git -C "$origin" symbolic-ref HEAD refs/heads/main
git clone -q "$origin" "$dev" 2>/dev/null
(
  cd "$dev" || exit 1
  git checkout -q -b main
  git config user.email "dev@example.com"
  git config user.name "dev"
  echo one > file.txt
  git add file.txt
  git commit -q -m "first"
  git push -q origin main
)
git clone -q "$origin" "$host"
(
  cd "$dev" || exit 1
  echo two >> file.txt
  git commit -q -am "second"
  git push -q origin main
)

gh_out="$base/github-output"
: > "$gh_out"
(
  cd "$outside" || exit 1
  HOME="$fake_home" \
  PIERLESS_REPO="$host" PIERLESS_BRANCH=main \
  PIERLESS_STATE_DIR="$state_default" \
  PIERLESS_INSTALL=none PIERLESS_PRUNE_WORKTREES=false \
  PIERLESS_ACTION_PATH="$REPO_ROOT" GITHUB_OUTPUT="$gh_out" \
  bash -c "$(step_script Deploy)" >/dev/null 2>&1
)
assert_contains "$(cat "$gh_out")" "exit_code=0" "action defaults: deploy step exits 0"
assert_contains "$(cat "$gh_out")" "deployed=true" "action defaults: deploy step pulled the new commit"
assert_empty "$(git -C "$host" status --porcelain)" "action defaults: checkout is clean after the deploy"
if [ -f "$fake_home/.pierless/last-hooked-sha" ]; then
  pass "action defaults: hook marker sits under \$HOME/.pierless"
else
  fail "action defaults: hook marker sits under \$HOME/.pierless (not found)"
fi

(
  cd "$host" || exit 1
  HOME="$fake_home" PIERLESS_STATE_DIR="$state_default" \
  PIERLESS_ON_FAILURE="" PIERLESS_RUN_URL="run-1" \
  PIERLESS_EXIT_CODE=1 \
  bash -c "$(step_script 'Failure command')" >/dev/null 2>&1
)
assert_empty "$(git -C "$host" status --porcelain)" "action defaults: checkout is clean after the failure step"
if [ -f "$fake_home/.pierless/last-failed" ]; then
  pass "action defaults: last-failed marker sits under \$HOME/.pierless"
else
  fail "action defaults: last-failed marker sits under \$HOME/.pierless (not found)"
fi

(
  cd "$host" || exit 1
  HOME="$fake_home" PIERLESS_STATE_DIR="$state_default" \
  PIERLESS_ON_RECOVERY="" PIERLESS_DEPLOYED=true \
  bash -c "$(step_script 'Recovery command')" >/dev/null 2>&1
)
if [ -f "$fake_home/.pierless/last-failed" ]; then
  fail "action defaults: recovery step clears the marker the failure step wrote"
else
  pass "action defaults: recovery step clears the marker the failure step wrote"
fi

test_summary_and_exit
