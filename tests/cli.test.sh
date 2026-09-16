#!/usr/bin/env bash
# tests/cli.test.sh — bin/pierless: --help and an unknown verb.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
CLI="$REPO_ROOT/bin/pierless"
require_script "$CLI"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" --help >"$out" 2>"$err"
ec=$?
help_out="$(cat "$out")"
rm -f "$out" "$err"
assert_exit 0 "$ec" "--help: exits 0"
assert_contains "$help_out" "install" "--help: mentions the install verb"
assert_contains "$help_out" "status" "--help: mentions the status verb"
assert_contains "$help_out" "dry-run" "--help: mentions the dry-run verb"
assert_contains "$help_out" "uninstall" "--help: mentions the uninstall verb"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" bogus-verb >"$out" 2>"$err"
ec=$?
bogus_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 64 "$ec" "unknown verb: exits 64"
assert_contains "$bogus_err" "unknown verb" "unknown verb: clear line naming the problem"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" >"$out" 2>"$err"
ec=$?
rm -f "$out" "$err"
assert_exit 64 "$ec" "no verb given: exits 64"

# --- each verb dispatches to the right sibling script ---
# pierless always execs the SIBLING scripts at its own fixed SCRIPT_DIR
# (not stubs on PATH), so dispatch is proven by each sibling's own
# distinct usage banner, not by a swapped-out fake.

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" install --help >"$out" 2>"$err"
install_ec=$?
install_out="$(cat "$out")"
rm -f "$out" "$err"
assert_exit 0 "$install_ec" "install verb: --help exits 0"
assert_contains "$install_out" "usage: install-runner.sh" "install verb: reaches install-runner.sh"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" status --help >"$out" 2>"$err"
status_ec=$?
status_out="$(cat "$out")"
rm -f "$out" "$err"
assert_exit 0 "$status_ec" "status verb: --help exits 0"
assert_contains "$status_out" "usage: status.sh" "status verb: reaches status.sh"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" uninstall --help >"$out" 2>"$err"
uninstall_ec=$?
uninstall_out="$(cat "$out")"
rm -f "$out" "$err"
assert_exit 0 "$uninstall_ec" "uninstall verb: --help exits 0"
assert_contains "$uninstall_out" "usage: uninstall-runner.sh" "uninstall verb: reaches uninstall-runner.sh"

# --- dry-run verb: install-runner.sh --dry-run, PIERLESS_REPO unset ---
# (no gh stub needed here: install-runner.sh's dry-run path still requests
# a real registration token, so this case gives it an authenticated gh.)
stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api) echo "gh-fake-registration-token" ;;
  *) exit 1 ;;
esac
'
dryrun_home="$(new_tmpdir)"
dryrun_runner_dir="$dryrun_home/runner"
out="$(mktemp)"; err="$(mktemp)"
( env -u PIERLESS_REPO bash "$CLI" dry-run --repo owner/repo --runner-dir "$dryrun_runner_dir" ) >"$out" 2>"$err"
dryrun_ec=$?
dryrun_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_exit 0 "$dryrun_ec" "dry-run verb (no PIERLESS_REPO): exits 0"
assert_contains "$dryrun_out" "dry-run" "dry-run verb (no PIERLESS_REPO): reaches install-runner.sh's dry-run plan"
assert_not_contains "$dryrun_out" "running deploy.sh --dry-run" "dry-run verb (no PIERLESS_REPO): deploy.sh is not invoked"

# --- dry-run verb: PIERLESS_REPO set also reaches deploy.sh ---
dryrun_repo="$(new_tmpdir)/repo"
mkdir -p "$dryrun_repo"
git -C "$dryrun_repo" init -q
git -C "$dryrun_repo" config user.email "t@example.com"
git -C "$dryrun_repo" config user.name "t"
dryrun_home2="$(new_tmpdir)"
out="$(mktemp)"; err="$(mktemp)"
( PIERLESS_REPO="$dryrun_repo" PIERLESS_LOG="$dryrun_home2/deploy.log" PIERLESS_LOCK_DIR="$dryrun_home2/lock"   bash "$CLI" dry-run --repo owner/repo --runner-dir "$dryrun_home2/runner" ) >"$out" 2>"$err"
dryrun2_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_contains "$dryrun2_out" "running deploy.sh --dry-run with PIERLESS_DRY_RUN=1" "dry-run verb (PIERLESS_REPO set): also runs deploy.sh"

test_summary_and_exit
