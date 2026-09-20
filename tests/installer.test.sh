#!/usr/bin/env bash
# tests/installer.test.sh — bin/install-runner.sh: dry-run, missing --repo,
# and the sha256-mismatch refusal on a real download path.
#
# No associative arrays, no `set -u` (see tests/lib.sh — bash 3.2 on
# macOS). This test never lets a real run reach registration or
# launchctl: the sha256 mismatch case exits before either.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
INSTALLER="$REPO_ROOT/bin/install-runner.sh"
require_script "$INSTALLER"

stub_gh_ok() {
  stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api) echo "gh-fake-registration-token" ;;
  *) exit 1 ;;
esac
'
}

# --- dry-run: prints every planned action, creates nothing, redacts token ---
runner_dir="$(new_tmpdir)/runner"
stub_gh_ok
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$runner_dir" --dry-run >"$out" 2>"$err"
ec=$?
dry_out="$(cat "$out")"
dry_err="$(cat "$err")"
rm -f "$out" "$err"

assert_exit 0 "$ec" "dry-run: exits 0"
assert_contains "$dry_out" "download" "dry-run: prints the planned download"
assert_contains "$dry_out" "sha256" "dry-run: mentions the sha256 verification step"
assert_contains "$dry_out" "***REDACTED***" "dry-run: registration token is redacted"
assert_not_contains "$dry_out" "gh-fake-registration-token" "dry-run: real token never printed"
assert_contains "$dry_out" "hooks/job-started-gate.sh" "dry-run: prints the hook path"
assert_contains "$dry_out" "verify" "dry-run: prints the verify plan"
if [ -e "$runner_dir" ]; then
  fail "dry-run: creates nothing under --runner-dir (found $runner_dir)"
else
  pass "dry-run: creates nothing under --runner-dir"
fi

# --- --repo missing: non-zero exit, clear line ---
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --dry-run >"$out" 2>"$err"
ec=$?
missing_err="$(cat "$err")"
rm -f "$out" "$err"
if [ "$ec" -eq 0 ]; then
  fail "missing --repo: exits non-zero (got 0)"
else
  pass "missing --repo: exits non-zero"
fi
assert_contains "$missing_err" "--repo is required" "missing --repo: clear line naming the missing flag"

# --- real download path: stubbed curl writes a wrong file -> sha256 mismatch ---
# The script downloads (and verifies) before it ever registers with GitHub,
# so this never reaches gh/config.sh/launchctl — confirmed by the absence
# of any need to stub gh here (a call to gh with no stub would itself fail
# loudly, which the assertions below would catch via the wrong error text).
runner_dir2="$(new_tmpdir)/runner2"
stub_bin curl '
# emulate: curl -fsSL -o <path> <url> — write bogus content regardless of URL
out_path=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out_path="$a"; fi
  prev="$a"
done
[ -n "$out_path" ] && printf "not the real runner tarball\n" > "$out_path"
exit 0
'
out="$(mktemp)"; err="$(mktemp)"
PIERLESS_TEST_RUNNER_VERSION="0.0.0-test" \
PIERLESS_TEST_RUNNER_SHA256="0000000000000000000000000000000000000000000000000000000000aa" \
PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
bash "$INSTALLER" --repo owner/repo --runner-dir "$runner_dir2" >"$out" 2>"$err"
ec=$?
mismatch_out="$(cat "$out")"
mismatch_err="$(cat "$err")"
rm -f "$out" "$err"

if [ "$ec" -eq 0 ]; then
  fail "sha256 mismatch: exits non-zero (got 0)"
else
  pass "sha256 mismatch: exits non-zero"
fi
combined="$mismatch_out
$mismatch_err"
assert_contains "$combined" "sha256 mismatch" "sha256 mismatch: refusal line names it"
assert_not_contains "$combined" "config.sh" "sha256 mismatch: never reaches registration (config.sh)"

# =====================================================================
# Real (non-dry-run) install flow. curl/tar/gh/launchctl/plutil are all
# stubbed; shasum is the REAL binary (used both to compute the fixture's
# expected hash and, inside the script, to verify it — consistent either
# way since it's the same implementation on both sides).
# =====================================================================

FIXTURE_TARBALL_CONTENT="FIXTURE_TARBALL_CONTENT_v1"
FIXTURE_SHA256="$(printf '%s' "$FIXTURE_TARBALL_CONTENT" | shasum -a 256 | awk '{print $1}')"

stub_curl_fixture() {
  stub_bin curl '
out_path=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out_path="$a"; fi
  prev="$a"
done
[ -n "$out_path" ] && printf "%s" "${PIERLESS_TEST_TARBALL_CONTENT:-FIXTURE_TARBALL_CONTENT_v1}" > "$out_path"
exit 0
'
}

stub_tar_fixture() {
  # Emulates extracting the real actions/runner tarball: drops an
  # executable bin/Runner.Listener, a config.sh that records its argv to
  # $CONFIG_CALLS_LOG and touches a real .runner file, and a no-op run.sh.
  stub_bin tar '
dir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
mkdir -p "$dir/bin"
: > "$dir/bin/Runner.Listener"
chmod +x "$dir/bin/Runner.Listener"
cat > "$dir/config.sh" <<CONFIGEOF
#!/usr/bin/env bash
echo "config.sh args: \$*" >> "\${CONFIG_CALLS_LOG:-/dev/null}"
printf "{\"gitHubUrl\": \"https://github.com/fixture/repo\"}" > "\$(dirname "\$0")/.runner"
exit 0
CONFIGEOF
chmod +x "$dir/config.sh"
cat > "$dir/run.sh" <<RUNEOF
#!/usr/bin/env bash
exit 0
RUNEOF
chmod +x "$dir/run.sh"
exit 0
'
}

stub_gh_registration_ok() {
  stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        *registration-token*) echo "gh-fake-registration-token"; exit 0 ;;
      esac
    done
    echo "gh-fake-token"
    exit 0
    ;;
  *) exit 1 ;;
esac
'
}

stub_launchctl_stateful() {
  # print reports "running" once bootstrap has been called (tracked via a
  # state file); bootout clears that state. Every call is logged.
  stub_bin launchctl '
state_file="${LAUNCHCTL_STATE_FILE:-}"
case "$1" in
  print)
    if [ -n "$state_file" ] && [ -f "$state_file" ]; then
      # state = running is printed LAST, not first: the verify step in
      # install-runner.sh pipes this through grep -q, which exits the
      # instant it sees a match. If anything were printed AFTER that
      # match, a slow writer (e.g. under PIERLESS_TRACE_FILE tracing,
      # which adds a DEBUG-trap printf before every line) can still be
      # mid-write when grep closes its end of the pipe, earning a SIGPIPE
      # that pipefail then reports as a failure even though grep matched.
      # Printing the matched line last avoids the race entirely.
      echo "pid = 4242"
      echo "state = running"
      exit 0
    else
      exit 1
    fi
    ;;
  bootstrap)
    [ -n "$state_file" ] && touch "$state_file"
    echo "launchctl $*" >> "${LAUNCHCTL_CALLS_LOG:-/dev/null}"
    exit 0
    ;;
  bootout)
    [ -n "$state_file" ] && rm -f "$state_file"
    echo "launchctl $*" >> "${LAUNCHCTL_CALLS_LOG:-/dev/null}"
    exit 0
    ;;
  *)
    echo "launchctl $*" >> "${LAUNCHCTL_CALLS_LOG:-/dev/null}"
    exit 0
    ;;
esac
'
}

stub_plutil_fixture() {
  # -extract <field> raw [-o -] <plist> — the last argument is always the
  # plist path regardless of which flags precede it.
  stub_bin plutil '
case "$1" in
  -extract)
    field="$2"
    shift 2
    plist=""
    for a in "$@"; do plist="$a"; done
    case "$field" in
      WorkingDirectory)
        grep -A1 "<key>WorkingDirectory</key>" "$plist" | tail -n1 | sed -e "s/^[[:space:]]*<string>//" -e "s/<\/string>[[:space:]]*$//"
        ;;
      EnvironmentVariables.ACTIONS_RUNNER_HOOK_JOB_STARTED)
        grep -A1 "<key>ACTIONS_RUNNER_HOOK_JOB_STARTED</key>" "$plist" | tail -n1 | sed -e "s/^[[:space:]]*<string>//" -e "s/<\/string>[[:space:]]*$//"
        ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  -lint) exit 0 ;;
  *) exit 0 ;;
esac
'
}

run_install_real() {
  # args: any env assignments, then the flags for install-runner.sh after
  # a literal "--".
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
  env "${envs[@]}" bash "$INSTALLER" "${flags[@]}" >"$out" 2>"$err"
  ec=$?
  INSTALL_STDOUT="$(cat "$out")$(cat "$err")"
  INSTALL_EXIT="$ec"
  rm -f "$out" "$err"
}
INSTALL_STDOUT=""
INSTALL_EXIT=""

# --- fresh install end to end, through the verify step ---
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_launchctl_stateful
stub_plutil_fixture
home_a="$(new_tmpdir)"
runner_dir_a="$home_a/runner"
config_calls_a="$(new_tmpdir)/config-calls.log"; : > "$config_calls_a"
launchctl_calls_a="$(new_tmpdir)/launchctl-calls.log"; : > "$launchctl_calls_a"
launchctl_state_a="$(new_tmpdir)/launchctl-state"
run_install_real HOME="$home_a" CONFIG_CALLS_LOG="$config_calls_a" \
  LAUNCHCTL_CALLS_LOG="$launchctl_calls_a" LAUNCHCTL_STATE_FILE="$launchctl_state_a" \
  PIERLESS_TEST_RUNNER_VERSION="1.2.3-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_a"
assert_exit 0 "$INSTALL_EXIT" "fresh install: exits 0"
assert_contains "$INSTALL_STDOUT" "verified: pierless.runner running, hook sha256 matches repo" "fresh install: verify step passes"
if [ -x "$runner_dir_a/hooks/job-started-gate.sh" ]; then
  pass "fresh install: hook installed and executable"
else
  fail "fresh install: hook installed and executable"
fi
assert_contains "$(cat "$runner_dir_a/.env" 2>/dev/null || true)" "ACTIONS_RUNNER_HOOK_JOB_STARTED=" "fresh install: .env carries the hook path"
if [ -f "$home_a/Library/LaunchAgents/pierless.runner.plist" ]; then
  pass "fresh install: plist rendered into Library/LaunchAgents"
else
  fail "fresh install: plist rendered into Library/LaunchAgents"
fi
launchctl_calls_a_content="$(cat "$launchctl_calls_a")"
assert_contains "$launchctl_calls_a_content" "bootstrap" "fresh install: launchctl bootstrap called"
config_calls_a_content="$(cat "$config_calls_a")"
assert_contains "$config_calls_a_content" "--unattended" "fresh install: config.sh called with --unattended"
assert_contains "$config_calls_a_content" "gh-fake-registration-token" "fresh install: config.sh received the registration token"

# --- version-change path: bootout only when the installed plist's
# WorkingDirectory matches this run's --runner-dir ---
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_launchctl_stateful
stub_plutil_fixture

# matching case: bootout happens
home_b="$(new_tmpdir)"
runner_dir_b="$home_b/runner"
mkdir -p "$runner_dir_b" "$home_b/Library/LaunchAgents"
printf 'old-version' > "$runner_dir_b/.runner-version"
: > "$runner_dir_b/bin_marker_unused"
plist_b="$home_b/Library/LaunchAgents/pierless.runner.plist"
{
  echo '<?xml version="1.0"?>'
  echo '<plist><dict>'
  echo '  <key>WorkingDirectory</key>'
  echo "  <string>${runner_dir_b}</string>"
  echo '</dict></plist>'
} > "$plist_b"
launchctl_state_b="$(new_tmpdir)/launchctl-state"; touch "$launchctl_state_b"
launchctl_calls_b="$(new_tmpdir)/launchctl-calls.log"; : > "$launchctl_calls_b"
run_install_real HOME="$home_b" LAUNCHCTL_CALLS_LOG="$launchctl_calls_b" LAUNCHCTL_STATE_FILE="$launchctl_state_b" \
  PIERLESS_TEST_RUNNER_VERSION="2.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_b"
assert_contains "$INSTALL_STDOUT" "version change — booting out" "version change (matching dir): log names the bootout"
launchctl_calls_b_content="$(cat "$launchctl_calls_b")"
matching_bootout_count="$(printf '%s\n' "$launchctl_calls_b_content" | grep -c "bootout gui/$(id -u)/pierless.runner")"
# Section 1's version-change bootout clears the (stubbed) loaded state, so
# section 4's own always-bootout-if-loaded check then finds it already
# unloaded and skips its own call — exactly one bootout either way; what
# differs between this case and the mismatched one below is WHICH step
# logged it (asserted above) and, for the mismatched case, whether the
# version-change step's bootout ran at all.
assert_eq "1" "$matching_bootout_count" "version change (matching dir): bootout ran once (from the version-change check)"

# mismatched case: installed plist points elsewhere, bootout skipped
home_c="$(new_tmpdir)"
runner_dir_c="$home_c/runner"
mkdir -p "$runner_dir_c" "$home_c/Library/LaunchAgents"
printf 'old-version' > "$runner_dir_c/.runner-version"
plist_c="$home_c/Library/LaunchAgents/pierless.runner.plist"
{
  echo '<?xml version="1.0"?>'
  echo '<plist><dict>'
  echo '  <key>WorkingDirectory</key>'
  echo "  <string>/some/other/runner/dir</string>"
  echo '</dict></plist>'
} > "$plist_c"
launchctl_state_c="$(new_tmpdir)/launchctl-state"; touch "$launchctl_state_c"
launchctl_calls_c="$(new_tmpdir)/launchctl-calls.log"; : > "$launchctl_calls_c"
run_install_real HOME="$home_c" LAUNCHCTL_CALLS_LOG="$launchctl_calls_c" LAUNCHCTL_STATE_FILE="$launchctl_state_c" \
  PIERLESS_TEST_RUNNER_VERSION="2.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_c"
assert_contains "$INSTALL_STDOUT" "skipping bootout: installed runner dir is" "version change (mismatched dir): log names the skip"
launchctl_calls_c_content="$(cat "$launchctl_calls_c")"
# Section 4 (render+load) always boots out an already-loaded label before
# re-bootstrapping it, regardless of the version-change logic in section
# 1 — so the mismatched case still shows ONE bootout call (from section
# 4), while the matching case above shows TWO (section 1's version-change
# bootout, plus section 4's). The count is what distinguishes them.
mismatched_bootout_count="$(printf '%s\n' "$launchctl_calls_c_content" | grep -c "bootout gui/$(id -u)/pierless.runner")"
assert_eq "1" "$mismatched_bootout_count" "version change (mismatched dir): only section 4's own bootout ran, not an extra one from the version-change check"

# --- idempotent second run: no re-download, no re-register ---
stub_bin curl 'echo "curl should not be called on an idempotent run" >&2; exit 9'
stub_bin gh 'echo "gh should not be called on an idempotent run" >&2; exit 9'
stub_launchctl_stateful
stub_plutil_fixture
run_install_real HOME="$home_a" LAUNCHCTL_CALLS_LOG="$(new_tmpdir)/launchctl-calls.log" LAUNCHCTL_STATE_FILE="$launchctl_state_a" \
  PIERLESS_TEST_RUNNER_VERSION="1.2.3-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_a"
assert_exit 0 "$INSTALL_EXIT" "idempotent second run: exits 0"
assert_contains "$INSTALL_STDOUT" "already extracted" "idempotent second run: skips the download"
assert_contains "$INSTALL_STDOUT" "already exists — skipping registration" "idempotent second run: skips registration"
assert_not_contains "$INSTALL_STDOUT" "should not be called" "idempotent second run: neither curl nor gh was invoked"

# --- unauthenticated gh refuses registration (after a fresh extraction) ---
stub_curl_fixture
stub_tar_fixture
stub_bin gh '
case "$1" in
  auth) exit 1 ;;
  *) exit 1 ;;
esac
'
stub_launchctl_stateful
stub_plutil_fixture
home_d="$(new_tmpdir)"
runner_dir_d="$home_d/runner"
run_install_real HOME="$home_d" \
  PIERLESS_TEST_RUNNER_VERSION="3.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_d"
if [ "$INSTALL_EXIT" -eq 0 ]; then
  fail "unauthenticated gh: exits non-zero (got 0)"
else
  pass "unauthenticated gh: exits non-zero"
fi
assert_contains "$INSTALL_STDOUT" "an authenticated 'gh' is required to request a registration token" "unauthenticated gh: clear refusal line"
if [ -f "$home_d/Library/LaunchAgents/pierless.runner.plist" ]; then
  fail "unauthenticated gh: never reaches the plist render step (plist exists)"
else
  pass "unauthenticated gh: never reaches the plist render step"
fi

# --- .env key replacement keeps unrelated lines, replaces pierless keys ---
stub_launchctl_stateful
stub_plutil_fixture
home_e="$(new_tmpdir)"
runner_dir_e="$home_e/runner"
mkdir -p "$runner_dir_e/bin"
: > "$runner_dir_e/bin/Runner.Listener"
chmod +x "$runner_dir_e/bin/Runner.Listener"
printf '4.0.0-fixture' > "$runner_dir_e/.runner-version"
printf '{"gitHubUrl": "https://github.com/owner/repo"}' > "$runner_dir_e/.runner"
printf 'MY_CUSTOM_VAR=hello\nPIERLESS_ALLOWED_JOB=stale-job\n' > "$runner_dir_e/.env"
launchctl_state_e="$(new_tmpdir)/launchctl-state"
run_install_real HOME="$home_e" LAUNCHCTL_STATE_FILE="$launchctl_state_e" \
  PIERLESS_TEST_RUNNER_VERSION="4.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_e"
assert_exit 0 "$INSTALL_EXIT" ".env replacement: exits 0 (no curl/gh stub needed — already extracted and registered)"
env_e_content="$(cat "$runner_dir_e/.env" 2>/dev/null || true)"
assert_contains "$env_e_content" "MY_CUSTOM_VAR=hello" ".env replacement: unrelated line preserved"
assert_contains "$env_e_content" "PIERLESS_ALLOWED_JOB=deploy" ".env replacement: pierless-managed key updated to the new value"
assert_not_contains "$env_e_content" "stale-job" ".env replacement: stale pierless-managed value removed"


# --- dry-run: --name/--labels/--workflow/--branch/--job/--path are parsed ---
stub_gh_ok
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$(new_tmpdir)/runner" \
  --name my-runner --labels extra --workflow custom.yml --branch release \
  --job build --path /custom/path --dry-run >"$out" 2>"$err"
flags_ec=$?
flags_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_exit 0 "$flags_ec" "dry-run with every flag: exits 0"
assert_contains "$flags_out" "--name my-runner" "dry-run with every flag: --name flows into the planned config.sh call"
assert_contains "$flags_out" "self-hosted,macOS,extra" "dry-run with every flag: --labels flows into the planned config.sh call"

# --- unknown argument ---
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --bogus-flag >"$out" 2>"$err"
unknown_ec=$?
unknown_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
if [ "$unknown_ec" -eq 0 ]; then
  fail "unknown flag: exits non-zero (got 0)"
else
  pass "unknown flag: exits non-zero"
fi
assert_contains "$unknown_out" "unknown argument" "unknown flag: clear line naming the problem"

# --- non-arm64 platform: dry-run notes it, real run refuses ---
stub_bin uname 'if [ "$1" = "-m" ]; then echo "x86_64"; else /usr/bin/uname "$@"; fi'
stub_gh_ok
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$(new_tmpdir)/runner" --dry-run >"$out" 2>"$err"
nonarm_dryrun_ec=$?
nonarm_dryrun_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_exit 0 "$nonarm_dryrun_ec" "non-arm64 dry-run: still exits 0"
assert_contains "$nonarm_dryrun_out" "this host would be refused" "non-arm64 dry-run: notes the refusal without aborting"

out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$(new_tmpdir)/runner" >"$out" 2>"$err"
nonarm_real_ec=$?
nonarm_real_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
if [ "$nonarm_real_ec" -eq 0 ]; then
  fail "non-arm64 real run: exits non-zero (got 0)"
else
  pass "non-arm64 real run: exits non-zero"
fi
assert_contains "$nonarm_real_out" "refused — this Mac is not arm64" "non-arm64 real run: refuses before touching anything"

# --- arm64 platform: the match arm is a no-op, dry-run reports no refusal ---
# CI's own runners are never arm64 (ubuntu-latest is x86_64; even
# macos-latest's arm64 host would make this pass "by accident" and hide a
# Linux-only gap), so this is stubbed explicitly rather than relying on
# whatever the real host happens to be.
stub_bin uname 'if [ "$1" = "-m" ]; then echo "arm64"; else /usr/bin/uname "$@"; fi'
stub_gh_ok
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$(new_tmpdir)/runner" --dry-run >"$out" 2>"$err"
arm_dryrun_ec=$?
arm_dryrun_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_exit 0 "$arm_dryrun_ec" "arm64 dry-run: exits 0"
assert_contains "$arm_dryrun_out" "dry run complete — nothing created under" "arm64 dry-run: no platform refusal noted"
assert_not_contains "$arm_dryrun_out" "would be refused" "arm64 dry-run: never claims this host would be refused"

# --- dry-run: already-extracted and already-registered plan lines ---
stub_gh_ok
already_dir="$(new_tmpdir)/runner"
mkdir -p "$already_dir/bin"
: > "$already_dir/bin/Runner.Listener"
chmod +x "$already_dir/bin/Runner.Listener"
printf '9.9.9-already' > "$already_dir/.runner-version"
printf '{"gitHubUrl": "https://github.com/owner/repo"}' > "$already_dir/.runner"
out="$(mktemp)"; err="$(mktemp)"
PIERLESS_TEST_RUNNER_VERSION="9.9.9-already" \
  bash "$INSTALLER" --repo owner/repo --runner-dir "$already_dir" --dry-run >"$out" 2>"$err"
already_ec=$?
already_out="$(cat "$out")$(cat "$err")"
rm -f "$out" "$err"
assert_exit 0 "$already_ec" "dry-run already extracted+registered: exits 0"
assert_contains "$already_out" "already extracted at $already_dir — would skip download" "dry-run: notes the extraction would be skipped"
assert_contains "$already_out" "already exists — would skip registration" "dry-run: notes the registration would be skipped"

# --- verify catches a launchd state that never comes up ---
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_bin launchctl '
case "$1" in
  print) exit 1 ;;
  *) exit 0 ;;
esac
'
stub_plutil_fixture
home_f="$(new_tmpdir)"
runner_dir_f="$home_f/runner"
run_install_real HOME="$home_f" \
  PIERLESS_TEST_RUNNER_VERSION="5.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_f"
if [ "$INSTALL_EXIT" -eq 0 ]; then
  fail "verify catches state never running: exits non-zero (got 0)"
else
  pass "verify catches state never running: exits non-zero"
fi
assert_contains "$INSTALL_STDOUT" "verify FAILED" "verify catches state never running: names the failure"
assert_contains "$INSTALL_STDOUT" "does not show state = running" "verify catches state never running: names the specific check"

# --- gate script missing next to install-runner.sh: refuses immediately ---
# GATE_SCRIPT is derived from the running script's own directory
# (SCRIPT_DIR), so copying just install-runner.sh out on its own — without
# its sibling job-started-gate.sh — reproduces a broken/partial checkout.
# The copy keeps a "bin/" path component (coverage-check.py's own coverable
# set is keyed on that) so the coverage trace for this run still attributes
# to the real bin/install-runner.sh line numbers.
nogate_dir="$(new_tmpdir)/no-gate-copy/bin"
mkdir -p "$nogate_dir"
cp "$INSTALLER" "$nogate_dir/install-runner.sh"
chmod +x "$nogate_dir/install-runner.sh"
out="$(mktemp)"; err="$(mktemp)"
bash "$nogate_dir/install-runner.sh" --repo owner/repo --dry-run >"$out" 2>"$err"
nogate_ec=$?
nogate_err="$(cat "$err")"
rm -f "$out" "$err"
if [ "$nogate_ec" -eq 0 ]; then
  fail "gate script missing: exits non-zero (got 0)"
else
  pass "gate script missing: exits non-zero"
fi
assert_contains "$nogate_err" "expected gate script at" "gate script missing: clear line naming the problem"

# --- verify: plist ACTIONS_RUNNER_HOOK_JOB_STARTED doesn't match HOOK_DEST ---
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_launchctl_stateful
stub_bin plutil '
case "$1" in
  -extract)
    case "$2" in
      EnvironmentVariables.ACTIONS_RUNNER_HOOK_JOB_STARTED) printf "%s" "/some/wrong/hook/path" ;;
      *) : ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
'
home_g="$(new_tmpdir)"
runner_dir_g="$home_g/runner"
launchctl_state_g="$(new_tmpdir)/launchctl-state"
run_install_real HOME="$home_g" LAUNCHCTL_STATE_FILE="$launchctl_state_g" \
  PIERLESS_TEST_RUNNER_VERSION="6.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_g"
if [ "$INSTALL_EXIT" -eq 0 ]; then
  fail "verify catches hook path mismatch: exits non-zero (got 0)"
else
  pass "verify catches hook path mismatch: exits non-zero"
fi
assert_contains "$INSTALL_STDOUT" "verify FAILED" "verify catches hook path mismatch: names the failure"
assert_contains "$INSTALL_STDOUT" "plist ACTIONS_RUNNER_HOOK_JOB_STARTED is '/some/wrong/hook/path'" "verify catches hook path mismatch: names the specific check"

# --- verify: installed hook sha256 does not match the repo's gate script ---
# cp is overridden ONLY for the hook-copy destination (everything else
# passes through to the real /bin/cp), so the installed hook ends up with
# different content than bin/job-started-gate.sh — a genuine sha256
# mismatch, not a faked one.
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_launchctl_stateful
stub_plutil_fixture
real_cp="$(command -v cp)"
cp_override_dir="$(new_tmpdir)/cp-override"
mkdir -p "$cp_override_dir"
cat > "$cp_override_dir/cp" <<EOF
#!/usr/bin/env bash
case "\$2" in
  */hooks/job-started-gate.sh) printf 'corrupted hook content for sha256-mismatch test\n' > "\$2"; exit 0 ;;
  *) exec "$real_cp" "\$@" ;;
esac
EOF
chmod +x "$cp_override_dir/cp"
home_h="$(new_tmpdir)"
runner_dir_h="$home_h/runner"
launchctl_state_h="$(new_tmpdir)/launchctl-state"
run_install_real HOME="$home_h" LAUNCHCTL_STATE_FILE="$launchctl_state_h" \
  PATH="$cp_override_dir:$PATH" \
  PIERLESS_TEST_RUNNER_VERSION="7.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_h"
if [ "$INSTALL_EXIT" -eq 0 ]; then
  fail "verify catches hook sha256 mismatch: exits non-zero (got 0)"
else
  pass "verify catches hook sha256 mismatch: exits non-zero"
fi
assert_contains "$INSTALL_STDOUT" "installed hook sha256" "verify catches hook sha256 mismatch: names the specific check"
assert_contains "$INSTALL_STDOUT" "does not match repo copy" "verify catches hook sha256 mismatch: names the mismatch"

# --- verify: .env does not carry the ACTIONS_RUNNER_HOOK_JOB_STARTED line ---
# mv is overridden ONLY for the .env destination (everything else passes
# through to the real /bin/mv), so the installed .env ends up missing the
# line the verify step checks for — a genuine gap, not a faked one.
stub_curl_fixture
stub_tar_fixture
stub_gh_registration_ok
stub_launchctl_stateful
stub_plutil_fixture
real_mv="$(command -v mv)"
mv_override_dir="$(new_tmpdir)/mv-override"
mkdir -p "$mv_override_dir"
cat > "$mv_override_dir/mv" <<EOF
#!/usr/bin/env bash
case "\$2" in
  */.env) printf 'SOME_OTHER_VAR=x\n' > "\$2"; rm -f "\$1"; exit 0 ;;
  *) exec "$real_mv" "\$@" ;;
esac
EOF
chmod +x "$mv_override_dir/mv"
home_i="$(new_tmpdir)"
runner_dir_i="$home_i/runner"
launchctl_state_i="$(new_tmpdir)/launchctl-state"
run_install_real HOME="$home_i" LAUNCHCTL_STATE_FILE="$launchctl_state_i" \
  PATH="$mv_override_dir:$PATH" \
  PIERLESS_TEST_RUNNER_VERSION="8.0.0-fixture" PIERLESS_TEST_RUNNER_SHA256="$FIXTURE_SHA256" \
  PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 \
  -- --repo owner/repo --runner-dir "$runner_dir_i"
if [ "$INSTALL_EXIT" -eq 0 ]; then
  fail "verify catches missing .env line: exits non-zero (got 0)"
else
  pass "verify catches missing .env line: exits non-zero"
fi
assert_contains "$INSTALL_STDOUT" "does not carry ACTIONS_RUNNER_HOOK_JOB_STARTED" "verify catches missing .env line: names the specific check"

test_summary_and_exit
