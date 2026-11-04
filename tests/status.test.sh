#!/usr/bin/env bash
# tests/status.test.sh — bin/status.sh: launchd loaded/not-loaded, the
# GitHub-side status (via a gh stub), the deploy-log tail, and the last
# refusal line pulled from the newest _diag/Runner_*.log fixture.
#
# No associative arrays, no `set -u` (see tests/lib.sh — bash 3.2 on
# macOS). Every scenario gets its own --runner-dir under a fresh tmpdir.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
STATUS_SCRIPT="$REPO_ROOT/bin/status.sh"
require_script "$STATUS_SCRIPT"

STATUS_STDOUT=""
STATUS_EXIT=""

run_status() {
  # args: any PIERLESS_LOADED=1 / other env assignments, then the flags
  # to pass to status.sh after a literal "--".
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
  env "${envs[@]}" bash "$STATUS_SCRIPT" "${flags[@]}" >"$out" 2>"$err"
  ec=$?
  STATUS_STDOUT="$(cat "$out")$(cat "$err")"
  STATUS_EXIT="$ec"
  rm -f "$out" "$err"
}

stub_launchctl() {
  # stub_launchctl LOADED_FLAG_FILE — print exits 0 with a state/pid line
  # when the flag file exists, else exits 1 (label not loaded).
  stub_bin launchctl '
case "$1" in
  print)
    if [ -n "${LAUNCHCTL_LOADED_FILE:-}" ] && [ -f "${LAUNCHCTL_LOADED_FILE}" ]; then
      echo "state = running"
      echo "pid = 4242"
      exit 0
    else
      exit 1
    fi
    ;;
  *) exit 0 ;;
esac
'
}

# --- launchd: loaded shows state/pid ---
stub_launchctl
loaded_flag="$(new_tmpdir)/loaded"
touch "$loaded_flag"
run_status LAUNCHCTL_LOADED_FILE="$loaded_flag" -- --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "state = running" "launchd loaded: shows state = running"
assert_contains "$STATUS_STDOUT" "pid = 4242" "launchd loaded: shows pid"

# --- launchd: not loaded says so ---
run_status LAUNCHCTL_LOADED_FILE="/no/such/flag-$$" -- --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "pierless.runner is not loaded" "launchd not loaded: names the label"

# --- GitHub: --repo given, gh authenticated, prints runner status ---
stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api)
    echo "pierless-mac: online (busy=false)"
    exit 0
    ;;
  *) exit 1 ;;
esac
'
run_status -- --repo owner/repo --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "pierless-mac: online (busy=false)" "GitHub --repo given: prints runner status from gh"

# --- GitHub: gh not authenticated ---
stub_bin gh '
case "$1" in
  auth) exit 1 ;;
  *) exit 1 ;;
esac
'
run_status -- --repo owner/repo --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "gh not authenticated" "GitHub not authenticated: says so"

# --- GitHub: no --repo, no readable .runner -> skip ---
stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api) echo "should not be called"; exit 0 ;;
  *) exit 1 ;;
esac
'
empty_runner_dir="$(new_tmpdir)/runner"
run_status -- --runner-dir "$empty_runner_dir"
assert_contains "$STATUS_STDOUT" "no --repo given and no readable" "GitHub no repo, no .runner: skip line"
assert_not_contains "$STATUS_STDOUT" "should not be called" "GitHub no repo, no .runner: gh api never invoked"

# --- GitHub: --repo read from .runner when not given on the CLI ---
runner_dir_with_reg="$(new_tmpdir)/runner"
mkdir -p "$runner_dir_with_reg"
printf '{"gitHubUrl": "https://github.com/from-runner-file/repo", "agentId": 7}\n' > "$runner_dir_with_reg/.runner"
stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        repos/from-runner-file/repo/*) echo "picked-up-from-dot-runner: online (busy=false)"; exit 0 ;;
      esac
    done
    echo "wrong repo slug reached gh api: $*"
    exit 1
    ;;
  *) exit 1 ;;
esac
'
run_status -- --runner-dir "$runner_dir_with_reg"
assert_contains "$STATUS_STDOUT" "picked-up-from-dot-runner: online (busy=false)" "GitHub repo read from .runner: uses the parsed slug"

# --- deploy log: tail of PIERLESS_LOG ---
log_file="$(new_tmpdir)/runner.log"
printf 'line one\nline two\nline three\nline four\n' > "$log_file"
run_status PIERLESS_LOG="$log_file" -- --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "line two" "deploy log: tail includes line two"
assert_contains "$STATUS_STDOUT" "line three" "deploy log: tail includes line three"
assert_contains "$STATUS_STDOUT" "line four" "deploy log: tail includes line four"
assert_not_contains "$STATUS_STDOUT" "line one" "deploy log: tail -n3 excludes line one"

# --- deploy log: missing file says so ---
run_status HOME="$(new_tmpdir)" -- --runner-dir "$(new_tmpdir)/runner"
assert_contains "$STATUS_STDOUT" "no log at" "deploy log missing: says so"

# --- deploy log: PIERLESS_LOG unset reads $HOME/.pierless/deploy.log, not runner.log ---
home_dir="$(new_tmpdir)"
mkdir -p "$home_dir/.pierless" "$home_dir/runner"
printf 'PULLED 2 commit(s)\n' > "$home_dir/.pierless/deploy.log"
printf 'runner output only\n' > "$home_dir/runner/runner.log"
run_status HOME="$home_dir" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "PULLED 2 commit(s)" "deploy log default: reads HOME/.pierless/deploy.log"
assert_not_contains "$STATUS_STDOUT" "runner output only" "deploy log default: does not read runner.log"
run_status HOME="$home_dir" PIERLESS_LOG="$log_file" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "line four" "deploy log: PIERLESS_LOG overrides the default"
assert_not_contains "$STATUS_STDOUT" "PULLED 2 commit(s)" "deploy log: override hides the default log"

# --- last-failed marker: present, then absent ---
state_dir="$(new_tmpdir)"
printf 'failed-run-marker-42\n' > "$state_dir/last-failed"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$state_dir" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "failed-run-marker-42" "last failed: prints the marker content"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$(new_tmpdir)" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "== last failed ==" "last failed absent: heading shown"
assert_contains "$STATUS_STDOUT" "none" "last failed absent: says none"
assert_exit 0 "$STATUS_EXIT" "fresh install: status exits 0 with no log, marker or sha file"

# --- hooks: last-hooked-sha versus HEAD (match, differ, missing) ---
git_repo="$(new_tmpdir)/checkout"
git init -q "$git_repo"
git -C "$git_repo" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m one
head_sha="$(git -C "$git_repo" rev-parse HEAD)"
sha_state="$(new_tmpdir)"
printf '%s\n' "$head_sha" > "$sha_state/last-hooked-sha"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$sha_state" PIERLESS_REPO="$git_repo" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "hooks: match" "hooks: marker equal to HEAD says match"
printf 'deadbeef\n' > "$sha_state/last-hooked-sha"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$sha_state" PIERLESS_REPO="$git_repo" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "hooks: differ" "hooks: marker not equal to HEAD says differ"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$(new_tmpdir)" PIERLESS_REPO="$git_repo" -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "no last-hooked-sha marker" "hooks: no marker says missing"
run_status HOME="$home_dir" PIERLESS_STATE_DIR="$sha_state" PIERLESS_REPO= -- --runner-dir "$home_dir/runner"
assert_contains "$STATUS_STDOUT" "HEAD unknown" "hooks: marker present but no PIERLESS_REPO says HEAD unknown"

# --- last refusal: newest Runner_*.log's last refusal line ---
diag_runner_dir="$(new_tmpdir)/runner"
mkdir -p "$diag_runner_dir/_diag"
printf 'some noise\npierless gate: refused — old reason (workflow_ref=x)\n' > "$diag_runner_dir/_diag/Runner_20250101-000000-utc.log"
sleep 1
printf 'pierless gate: allowed x\npierless gate: refused — newest reason (workflow_ref=y)\n' > "$diag_runner_dir/_diag/Runner_20250102-000000-utc.log"
run_status -- --runner-dir "$diag_runner_dir"
assert_contains "$STATUS_STDOUT" "newest reason" "last refusal: reads the newest Runner_*.log"
assert_not_contains "$STATUS_STDOUT" "old reason" "last refusal: does not read the older Runner_*.log"

# --- last refusal: diag dir exists, no refusal lines in the newest log ---
clean_diag_dir="$(new_tmpdir)/runner"
mkdir -p "$clean_diag_dir/_diag"
printf 'pierless gate: allowed x\n' > "$clean_diag_dir/_diag/Runner_20250101-000000-utc.log"
run_status -- --runner-dir "$clean_diag_dir"
assert_contains "$STATUS_STDOUT" "no refusal lines in" "last refusal: no matching lines says so"

# --- last refusal: diag dir exists but has no Runner_*.log files at all ---
no_logs_diag_dir="$(new_tmpdir)/runner"
mkdir -p "$no_logs_diag_dir/_diag"
run_status -- --runner-dir "$no_logs_diag_dir"
assert_contains "$STATUS_STDOUT" "no Runner_*.log files in" "last refusal: no matching log files says so"

# --- last refusal: no diag dir at all ---
no_diag_dir="$(new_tmpdir)/runner"
run_status -- --runner-dir "$no_diag_dir"
assert_contains "$STATUS_STDOUT" "no diag dir at" "last refusal: missing _diag dir says so"

# --- --help ---
out="$(mktemp)"
bash "$STATUS_SCRIPT" --help >"$out" 2>&1
help_ec=$?
help_out="$(cat "$out")"
rm -f "$out"
assert_exit 0 "$help_ec" "--help: exits 0"
assert_contains "$help_out" "usage: status.sh" "--help: prints usage"

# --- unknown flag ---
out="$(mktemp)"
bash "$STATUS_SCRIPT" --bogus >"$out" 2>&1
bogus_ec=$?
bogus_out="$(cat "$out")"
rm -f "$out"
if [ "$bogus_ec" -eq 0 ]; then
  fail "unknown flag: exits non-zero (got 0)"
else
  pass "unknown flag: exits non-zero"
fi
assert_contains "$bogus_out" "unknown argument" "unknown flag: clear line naming the problem"

test_summary_and_exit
