#!/usr/bin/env bash
# tests/uninstall.test.sh — bin/uninstall-runner.sh: bootout, removal-token
# request + config.sh remove, plist deletion, --purge vs keep, and the
# missing --repo refusal.
#
# No associative arrays, no `set -u` (see tests/lib.sh — bash 3.2 on
# macOS). HOME is overridden per-case so ${HOME}/Library/LaunchAgents
# (uninstall-runner.sh computes this from $HOME directly, not from
# --runner-dir) never touches the real machine.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
UNINSTALLER="$REPO_ROOT/bin/uninstall-runner.sh"
require_script "$UNINSTALLER"

UNINSTALL_STDOUT=""
UNINSTALL_EXIT=""

stub_launchctl() {
  # print reports loaded when $LAUNCHCTL_STATE_FILE exists; bootout
  # removes that flag file and logs the call to $LAUNCHCTL_CALLS_LOG.
  stub_bin launchctl '
case "$1" in
  print)
    if [ -n "${LAUNCHCTL_STATE_FILE:-}" ] && [ -f "${LAUNCHCTL_STATE_FILE}" ]; then
      exit 0
    else
      exit 1
    fi
    ;;
  bootout)
    echo "bootout $*" >> "${LAUNCHCTL_CALLS_LOG:-/dev/null}"
    [ -n "${LAUNCHCTL_STATE_FILE:-}" ] && rm -f "${LAUNCHCTL_STATE_FILE}"
    exit 0
    ;;
  *) exit 0 ;;
esac
'
}

stub_gh_removal_ok() {
  stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api)
    echo "gh-fake-removal-token"
    exit 0
    ;;
  *) exit 1 ;;
esac
'
}

new_fake_config_sh() {
  # new_fake_config_sh RUNNER_DIR — drops an executable config.sh that
  # records its argv to $CONFIG_CALLS_LOG instead of really deregistering.
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/config.sh" <<CONFIGEOF
#!/usr/bin/env bash
echo "config.sh args: \$*" >> "\${CONFIG_CALLS_LOG:-/dev/null}"
exit 0
CONFIGEOF
  chmod +x "$dir/config.sh"
}

run_uninstall() {
  # args: any env assignments, then the flags for uninstall-runner.sh
  # after a literal "--".
  local envs=() flags=() seen_dashdash=0
  local a
  for a in "$@"; do
    if [ "$seen_dashdash" -eq 1 ]; then
      flags+=("$a")
    elif [ "$a" = "--" ]; then
      seen_dashdash=1
    else
      envs+=("$a")
    fi
  done
  local out err ec
  out="$(mktemp)"; err="$(mktemp)"
  env "${envs[@]}" bash "$UNINSTALLER" "${flags[@]}" >"$out" 2>"$err"
  ec=$?
  UNINSTALL_STDOUT="$(cat "$out")$(cat "$err")"
  UNINSTALL_EXIT="$ec"
  rm -f "$out" "$err"
}

# --- missing --repo: refuses, exits non-zero ---
run_uninstall --
if [ "$UNINSTALL_EXIT" -eq 0 ]; then
  fail "missing --repo: exits non-zero (got 0)"
else
  pass "missing --repo: exits non-zero"
fi
assert_contains "$UNINSTALL_STDOUT" "--repo is required" "missing --repo: clear line naming the missing flag"

# --- loaded: bootout is called and logged ---
stub_launchctl
home1="$(new_tmpdir)"
runner_dir1="$home1/.pierless/runner"
state_file1="$(new_tmpdir)/state"
calls_log1="$(new_tmpdir)/launchctl-calls.log"
touch "$state_file1"
: > "$calls_log1"
run_uninstall HOME="$home1" LAUNCHCTL_STATE_FILE="$state_file1" LAUNCHCTL_CALLS_LOG="$calls_log1" \
  -- --repo owner/repo --runner-dir "$runner_dir1"
assert_contains "$UNINSTALL_STDOUT" "booted out" "loaded: log says booted out"
calls1="$(cat "$calls_log1")"
assert_contains "$calls1" "bootout" "loaded: launchctl bootout was called"

# --- not loaded: says so, bootout never called ---
home2="$(new_tmpdir)"
runner_dir2="$home2/.pierless/runner"
state_file2="$(new_tmpdir)/state-never-created"
calls_log2="$(new_tmpdir)/launchctl-calls.log"
: > "$calls_log2"
run_uninstall HOME="$home2" LAUNCHCTL_STATE_FILE="$state_file2" LAUNCHCTL_CALLS_LOG="$calls_log2" \
  -- --repo owner/repo --runner-dir "$runner_dir2"
assert_contains "$UNINSTALL_STDOUT" "was not loaded" "not loaded: log says so"
calls2="$(cat "$calls_log2")"
assert_empty "$calls2" "not loaded: launchctl bootout never called"

# --- registered: removal token requested, config.sh remove invoked, plist deleted ---
home3="$(new_tmpdir)"
runner_dir3="$home3/.pierless/runner"
mkdir -p "$runner_dir3"
: > "$runner_dir3/.runner"
new_fake_config_sh "$runner_dir3"
config_calls3="$(new_tmpdir)/config-calls.log"
: > "$config_calls3"
mkdir -p "$home3/Library/LaunchAgents"
plist3="$home3/Library/LaunchAgents/pierless.runner.plist"
echo "<plist fixture/>" > "$plist3"
stub_gh_removal_ok
run_uninstall HOME="$home3" CONFIG_CALLS_LOG="$config_calls3" \
  -- --repo owner/repo --runner-dir "$runner_dir3"
assert_exit 0 "$UNINSTALL_EXIT" "registered: exits 0"
assert_contains "$UNINSTALL_STDOUT" "requesting a removal token for owner/repo" "registered: logs the removal-token request"
assert_contains "$UNINSTALL_STDOUT" "removed runner registration for owner/repo" "registered: logs the registration removal"
config_calls_content3="$(cat "$config_calls3")"
assert_contains "$config_calls_content3" "remove" "registered: config.sh was called with remove"
assert_contains "$config_calls_content3" "gh-fake-removal-token" "registered: config.sh received the removal token"
if [ -f "$plist3" ]; then
  fail "registered: deletes the installed plist (still present)"
else
  pass "registered: deletes the installed plist"
fi
assert_contains "$UNINSTALL_STDOUT" "deleted $plist3" "registered: logs the plist deletion"

# --- unauthenticated gh: refuses before touching the plist ---
home4="$(new_tmpdir)"
runner_dir4="$home4/.pierless/runner"
mkdir -p "$runner_dir4"
: > "$runner_dir4/.runner"
mkdir -p "$home4/Library/LaunchAgents"
plist4="$home4/Library/LaunchAgents/pierless.runner.plist"
echo "<plist fixture/>" > "$plist4"
stub_bin gh '
case "$1" in
  auth) exit 1 ;;
  *) exit 1 ;;
esac
'
run_uninstall HOME="$home4" -- --repo owner/repo --runner-dir "$runner_dir4"
if [ "$UNINSTALL_EXIT" -eq 0 ]; then
  fail "unauthenticated gh: exits non-zero (got 0)"
else
  pass "unauthenticated gh: exits non-zero"
fi
assert_contains "$UNINSTALL_STDOUT" "an authenticated 'gh' is required" "unauthenticated gh: clear refusal line"
if [ -f "$plist4" ]; then
  pass "unauthenticated gh: plist left untouched (refused before reaching it)"
else
  fail "unauthenticated gh: plist left untouched (was deleted, should not have been)"
fi

# --- .runner not found: nothing to remove, no gh call needed ---
home5="$(new_tmpdir)"
runner_dir5="$home5/.pierless/runner"
mkdir -p "$runner_dir5"
stub_bin gh 'echo "gh should not be called" >&2; exit 9'
run_uninstall HOME="$home5" -- --repo owner/repo --runner-dir "$runner_dir5"
assert_exit 0 "$UNINSTALL_EXIT" "no .runner: exits 0"
assert_contains "$UNINSTALL_STDOUT" "nothing registered to remove" "no .runner: says nothing to remove"
assert_not_contains "$UNINSTALL_STDOUT" "gh should not be called" "no .runner: gh never invoked"

# --- --purge deletes the runner dir; without it, the dir is kept ---
home6="$(new_tmpdir)"
runner_dir6="$home6/.pierless/runner"
mkdir -p "$runner_dir6"
echo "state" > "$runner_dir6/some-state-file"
run_uninstall HOME="$home6" -- --repo owner/repo --runner-dir "$runner_dir6"
assert_exit 0 "$UNINSTALL_EXIT" "no --purge: exits 0"
if [ -d "$runner_dir6" ]; then
  pass "no --purge: runner dir left in place"
else
  fail "no --purge: runner dir left in place (was removed)"
fi
assert_contains "$UNINSTALL_STDOUT" "left $runner_dir6 in place" "no --purge: log names the kept dir"

home7="$(new_tmpdir)"
runner_dir7="$home7/.pierless/runner"
mkdir -p "$runner_dir7"
echo "state" > "$runner_dir7/some-state-file"
run_uninstall HOME="$home7" -- --repo owner/repo --runner-dir "$runner_dir7" --purge
assert_exit 0 "$UNINSTALL_EXIT" "--purge: exits 0"
if [ -d "$runner_dir7" ]; then
  fail "--purge: deletes the runner dir (still present)"
else
  pass "--purge: deletes the runner dir"
fi
assert_contains "$UNINSTALL_STDOUT" "purged $runner_dir7" "--purge: log names the purge"

# --- --help ---
out="$(mktemp)"
bash "$UNINSTALLER" --help >"$out" 2>&1
help_ec=$?
help_out="$(cat "$out")"
rm -f "$out"
assert_exit 0 "$help_ec" "--help: exits 0"
assert_contains "$help_out" "usage: uninstall-runner.sh" "--help: prints usage"

test_summary_and_exit
