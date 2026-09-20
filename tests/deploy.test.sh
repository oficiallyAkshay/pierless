#!/usr/bin/env bash
# tests/deploy.test.sh — bin/deploy.sh: the full deploy-script matrix.
#
# Each case builds a fresh bare "origin" repo, a "host" clone (the thing
# under deploy), and a "dev" clone used to push new commits from —
# entirely under a temp dir, torn down at process exit. No associative
# arrays, no `set -u` (see tests/lib.sh — bash 3.2 on macOS).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
DEPLOY_SCRIPT="$REPO_ROOT/bin/deploy.sh"
require_script "$DEPLOY_SCRIPT"

DEPLOY_STDOUT=""
DEPLOY_STDERR=""
DEPLOY_EXIT=""
DEPLOY_GH_OUTPUT=""

git_quiet() {
  git "$@" >/dev/null 2>&1
}

# new_fixture — sets ORIGIN, HOST, DEV globals to fresh repo paths with one
# commit on main already present in origin and pulled into host.
new_fixture() {
  local base
  base="$(new_tmpdir)"
  ORIGIN="$base/origin.git"
  HOST="$base/host"
  DEV="$base/dev"

  git init --bare -q "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

  git clone -q "$ORIGIN" "$DEV"
  (
    cd "$DEV" || exit 1
    git checkout -q -b main 2>/dev/null || git checkout -q main
    git config user.email "dev@example.com"
    git config user.name "dev"
    echo '{"name":"fixture"}' > package.json
    echo "hello" > README.md
    git add package.json README.md
    git commit -q -m "initial commit"
    git push -q origin main
  )

  git clone -q "$ORIGIN" "$HOST"
  (
    cd "$HOST" || exit 1
    git config user.email "host@example.com"
    git config user.name "host"
  )
}

push_commit_from_dev() {
  local msg="$1"
  (
    cd "$DEV" || exit 1
    git pull -q origin main
    echo "$msg" >> README.md
    git add README.md
    git commit -q -m "$msg"
    git push -q origin main
  )
}

run_deploy() {
  # args after HOST override: any PIERLESS_* env assignments as KEY=VALUE
  local out err ec
  local log lockdir ghoutput statedir
  log="$(mktemp)"
  lockdir="$(new_tmpdir)"
  statedir="$(new_tmpdir)/state"
  ghoutput="$(mktemp)"
  out="$(mktemp)"; err="$(mktemp)"

  ( cd "$HOST" && \
    PIERLESS_REPO="$HOST" \
    PIERLESS_LOG="$log" \
    PIERLESS_LOCK_DIR="$lockdir/lock" \
    PIERLESS_STATE_DIR="$statedir" \
    GITHUB_OUTPUT="$ghoutput" \
    "$@" \
    bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
  ec=$?
  DEPLOY_STATE_DIR="$statedir"

  DEPLOY_STDOUT="$(cat "$out")"
  DEPLOY_STDERR="$(cat "$err")"
  DEPLOY_EXIT="$ec"
  DEPLOY_LOG="$(cat "$log" 2>/dev/null || true)"
  DEPLOY_GH_OUTPUT="$(cat "$ghoutput" 2>/dev/null || true)"
  rm -f "$out" "$err"
}

gh_output_value() {
  # gh_output_value KEY — reads KEY=value from DEPLOY_GH_OUTPUT.
  printf '%s\n' "$DEPLOY_GH_OUTPUT" | sed -n "s/^$1=//p" | tail -n1
}

# bindir_without NAME... — builds a PATH dir containing symlinks for the
# common external commands bin/deploy.sh or this harness shells out to,
# excluding the given NAME(s). Same rationale as the "no gh" case above:
# a hardcoded low-level PATH (e.g. /usr/bin:/bin) isn't reliable across
# hosts — plutil lives at /usr/bin on a Mac and doesn't exist at all on
# ubuntu-latest, so build the allowlist from whatever's actually on PATH
# right now and just leave the excluded name(s) out of it.
bindir_without() {
  local exclude=" $* "
  local dir tool tool_path
  dir="$(new_tmpdir)/bin-without"
  mkdir -p "$dir"
  for tool in bash git date mkdir rm cat grep sed sort tr basename dirname \
              id sleep kill printf cp mv cut head stat gh env true false; do
    case "$exclude" in
      *" $tool "*) continue ;;
    esac
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] && ln -s "$tool_path" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# fake_git_failing PATTERN — writes a `git` wrapper into a fresh temp dir
# that exits 1 when its full argument list (as "$*") matches the given
# case-glob PATTERN (e.g. 'stash push*', or 'merge --ff-only*|stash pop'
# to fail on either), and otherwise execs the real git untouched. Only
# ever put on PATH for the one run_deploy call that needs it — everything
# else in a test (fixture setup, assertions afterward) keeps using the
# real git directly.
fake_git_failing() {
  local pattern="$1" dir real_git esc_pattern
  # Case patterns are single words — an unescaped space would split
  # "checkout main" into two tokens and break the parse, so literal
  # spaces are escaped here while "*" and the "|" alternation stay bare.
  esc_pattern="$(printf '%s' "$pattern" | sed 's/ /\\ /g')"
  dir="$(new_tmpdir)/fake-git-bin"
  mkdir -p "$dir"
  real_git="$(command -v git)"
  cat > "$dir/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  $esc_pattern) exit 1 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$dir/git"
  printf '%s\n' "$dir"
}

# --- up to date ---
new_fixture
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "up to date: exits 0"
assert_contains "$DEPLOY_LOG" "up to date" "up to date: log says up to date"
assert_eq "false" "$(gh_output_value deployed)" "up to date: deployed=false"

# --- one new commit pulls ---
new_fixture
push_commit_from_dev "second commit"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "one commit: exits 0"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "one commit: log says PULLED 1 commit(s)"
assert_eq "true" "$(gh_output_value deployed)" "one commit: deployed=true"
assert_eq "1" "$(gh_output_value commits)" "one commit: commits=1"

# --- dirty tracked file is parked, not re-applied, pull still happens ---
new_fixture
push_commit_from_dev "third commit"
echo "local edit" >> "$HOST/README.md"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "dirty tree: exits 0"
assert_contains "$DEPLOY_LOG" "PARKED" "dirty tree: log says PARKED"
stash_list="$(git -C "$HOST" stash list)"
assert_contains "$stash_list" "pierless park" "dirty tree: stash list has pierless park entry"
readme_after="$(cat "$HOST/README.md")"
assert_not_contains "$readme_after" "local edit" "dirty tree: local edit not re-applied"
assert_contains "$readme_after" "third commit" "dirty tree: upstream commit still pulled"

# --- diverged host refuses, nothing pulled ---
new_fixture
push_commit_from_dev "origin-side commit"
(
  cd "$HOST" || exit 1
  echo "host only" >> README.md
  git add README.md
  git commit -q -m "host-only local commit"
)
before_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env
assert_exit 4 "$DEPLOY_EXIT" "diverged: exits 4"
after_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_head" "$after_head" "diverged: HEAD unchanged, nothing pulled"

# --- stranded branch (merged+deleted upstream) is healed back to main ---
new_fixture
(
  cd "$DEV" || exit 1
  git checkout -q -b feature
  echo "feature work" >> README.md
  git add README.md
  git commit -q -m "feature commit"
  git push -q origin feature
)
(
  cd "$HOST" || exit 1
  git fetch -q origin feature
  git checkout -q feature
)
(
  cd "$DEV" || exit 1
  git checkout -q main
  git merge -q --squash feature
  git commit -q -m "squash-merge feature"
  git push -q origin main
  git push -q origin --delete feature
)
run_deploy env
current_branch="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "main" "$current_branch" "stranded branch: host switched back to main"
assert_exit 0 "$DEPLOY_EXIT" "stranded branch: exits 0"

# --- stranded branch, but the checkout back to main itself fails ---------
new_fixture
(
  cd "$DEV" || exit 1
  git checkout -q -b feature2
  echo "feature2 work" >> README.md
  git add README.md
  git commit -q -m "feature2 commit"
  git push -q origin feature2
)
(
  cd "$HOST" || exit 1
  git fetch -q origin feature2
  git checkout -q feature2
)
(
  cd "$DEV" || exit 1
  git checkout -q main
  git merge -q --squash feature2
  git commit -q -m "squash-merge feature2"
  git push -q origin main
  git push -q origin --delete feature2
)
selfheal_fail_git="$(fake_git_failing 'checkout main')"
before_selfheal_fail_branch="$(git -C "$HOST" symbolic-ref --short HEAD)"
run_deploy env PATH="$selfheal_fail_git:$PATH"
assert_exit 4 "$DEPLOY_EXIT" "self-heal checkout failure: exits 4"
assert_contains "$DEPLOY_LOG" "SELF-HEAL FAILED: could not checkout main from feature2" "self-heal checkout failure: log names the failure"
after_selfheal_fail_branch="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "$before_selfheal_fail_branch" "$after_selfheal_fail_branch" "self-heal checkout failure: still stranded on the old branch"

# --- stranded branch heals to main, but deleting the old branch fails ---
# (checkout succeeds; only `git branch -D` fails — non-fatal, logged.)
new_fixture
(
  cd "$DEV" || exit 1
  git checkout -q -b feature3
  echo "feature3 work" >> README.md
  git add README.md
  git commit -q -m "feature3 commit"
  git push -q origin feature3
)
(
  cd "$HOST" || exit 1
  git fetch -q origin feature3
  git checkout -q feature3
)
(
  cd "$DEV" || exit 1
  git checkout -q main
  git merge -q --squash feature3
  git commit -q -m "squash-merge feature3"
  git push -q origin main
  git push -q origin --delete feature3
)
branchdeletefail_git="$(fake_git_failing 'branch -D feature3')"
run_deploy env PATH="$branchdeletefail_git:$PATH"
assert_exit 0 "$DEPLOY_EXIT" "self-heal, branch delete fails: exits 0 (checkout itself still worked)"
branchdeletefail_current_branch="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "main" "$branchdeletefail_current_branch" "self-heal, branch delete fails: host still switched to main"
assert_contains "$DEPLOY_LOG" "SELF-HEAL: kept stale local branch feature3 (delete failed, non-fatal)" "self-heal, branch delete fails: log names the non-fatal keep"

# --- hook failure: exit 2, pull still happened, later hooks/prune still ran ---
new_fixture
(
  cd "$DEV" || exit 1
  echo '{"name":"fixture","v":2}' > package.json
  git add package.json
  git commit -q -m "bump package.json"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL="package.json=false"
assert_exit 2 "$DEPLOY_EXIT" "hook failure: exits 2"
head_after_hookfail="$(git -C "$HOST" rev-parse HEAD)"
origin_head="$(git -C "$ORIGIN" rev-parse refs/heads/main)"
assert_eq "$origin_head" "$head_after_hookfail" "hook failure: pull happened despite hook failure"
pull_line="$(printf '%s\n' "$DEPLOY_LOG" | grep -n 'PULLED' | head -n1 | cut -d: -f1)"
hook_line="$(printf '%s\n' "$DEPLOY_LOG" | grep -n -i 'hook' | head -n1 | cut -d: -f1)"
if [ -n "$pull_line" ] && [ -n "$hook_line" ]; then
  assert_true "$([ "$pull_line" -lt "$hook_line" ] && echo 0 || echo 1)" "hook failure: log shows pull before the hook line"
else
  fail "hook failure: log order check (missing PULLED or hook line — got: $DEPLOY_LOG)"
fi

# --- lock held by a live owner ---
# deploy.sh has no wait-time override: the 600s cap and 5s poll interval
# are hardcoded. Rather than actually wait 600s, stub `sleep` to a no-op
# so the script's own wait loop runs at full speed while a REAL live
# process (started via the absolute path, before the stub goes on PATH)
# keeps holding the lock the whole time.
new_fixture
lockbase="$(new_tmpdir)"
lockdir="$lockbase/lock"
mkdir -p "$lockdir"
/bin/sleep 300 &
live_owner_pid=$!
echo "$live_owner_pid" > "$lockdir/pid"
stub_bin sleep 'exit 0'
out="$(mktemp)"; err="$(mktemp)"; log="$(mktemp)"; ghoutput="$(mktemp)"
( cd "$HOST" && \
  PIERLESS_REPO="$HOST" \
  PIERLESS_LOG="$log" \
  PIERLESS_LOCK_DIR="$lockdir" \
  GITHUB_OUTPUT="$ghoutput" \
  bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
DEPLOY_EXIT=$?
DEPLOY_LOG="$(cat "$log" 2>/dev/null || true)"
assert_exit 3 "$DEPLOY_EXIT" "live lock: exits 3 (deploy.sh has no wait override; sleep is stubbed to reach the hardcoded 600s cap fast)"
assert_contains "$DEPLOY_LOG" "10 minutes" "live lock: log names the reason"
kill "$live_owner_pid" >/dev/null 2>&1 || true
rm -f "$out" "$err" "$log" "$ghoutput"

# --- stale lock from a dead pid is removed, deploy proceeds ---
new_fixture
push_commit_from_dev "stale-lock commit"
lockbase2="$(new_tmpdir)"
lockdir2="$lockbase2/lock"
mkdir -p "$lockdir2"
( sleep 0.1 & echo $! > "$lockdir2/pid" )
sleep 1
run_deploy env PIERLESS_LOCK_DIR="$lockdir2"
assert_contains "$DEPLOY_LOG" "stale lock" "stale lock: log mentions stale lock removal"
assert_exit 0 "$DEPLOY_EXIT" "stale lock: deploy still proceeds"

# --- stale lock with NO pid file at all (aged past the 600s cap) -------
# A lock dir can exist with no pid file when the owner was killed before
# it got to `echo "$$" > pid` — touch -t (not -d: its date syntax differs
# between BSD and GNU touch) sets a fixed, unambiguously-old mtime the
# same way on both platforms, no epoch arithmetic needed.
new_fixture
push_commit_from_dev "stale-lock-nopid commit"
lockbase3="$(new_tmpdir)"
lockdir3="$lockbase3/lock"
mkdir -p "$lockdir3"
touch -t 202001010000 "$lockdir3"
run_deploy env PIERLESS_LOCK_DIR="$lockdir3"
assert_contains "$DEPLOY_LOG" "stale lock with no pid file removed" "stale lock, no pid file: log names the removal"
assert_exit 0 "$DEPLOY_EXIT" "stale lock, no pid file: deploy still proceeds"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "stale lock, no pid file: deploy actually pulled"

# --- PIERLESS_REPO unset -> bad config ---
new_fixture
out="$(mktemp)"; err="$(mktemp)"
( cd "$HOST" && env -u PIERLESS_REPO bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
DEPLOY_EXIT=$?
assert_exit 64 "$DEPLOY_EXIT" "PIERLESS_REPO unset: exits 64"
rm -f "$out" "$err"

# --- fetch failure ---
new_fixture
mv "$ORIGIN" "${ORIGIN}.gone"
run_deploy env
assert_exit 5 "$DEPLOY_EXIT" "fetch failure: exits 5"
mv "${ORIGIN}.gone" "$ORIGIN" 2>/dev/null || true

# --- PIERLESS_PRUNE_WORKTREES=false skips the prune ---
# The skip note is logged at debug level (deploy.sh's debug() helper only
# writes when PIERLESS_DEBUG=1) — set it so the note is observable.
new_fixture
push_commit_from_dev "prune-skip commit"
run_deploy env PIERLESS_PRUNE_WORKTREES=false PIERLESS_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "prune skipped: exits 0"
assert_contains "$DEPLOY_LOG" "skipping prune" "prune skipped: log names the prune step"

# --- PIERLESS_SERVICES_DIR plist named <self-label>.plist is a hand step ---
# PIERLESS_SERVICES_DIR is documented as repo-relative (deploy.sh's own
# header comment) — an absolute path never matches the relative paths
# `git diff --name-only` reports, so the hook silently no-ops.
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
calls_log="$(new_tmpdir)/launchctl-calls.log"
: > "$calls_log"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist self-label v1/>' > services/ai.pierless.self.plist
  git add services/ai.pierless.self.plist
  git commit -q -m "add self plist"
  git push -q origin main
)
(
  cd "$HOST" || exit 1
  git pull -q origin main
)
(
  cd "$DEV" || exit 1
  echo '<plist self-label v2/>' > services/ai.pierless.self.plist
  git add services/ai.pierless.self.plist
  git commit -q -m "change self plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$calls_log" run_deploy env PIERLESS_SERVICES_DIR="services" PIERLESS_SELF_LABEL="ai.pierless.self"
assert_exit 0 "$DEPLOY_EXIT" "self-plist change: exits 0"
assert_contains "$DEPLOY_LOG" "reload it by hand" "self-plist change: log calls it a hand step"
calls_content="$(cat "$calls_log" 2>/dev/null || true)"
assert_not_contains "$calls_content" "ai.pierless.self" "self-plist change: launchctl never called with the self label"

# --- services hook: a new plist is copied and bootstrapped ---
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
new_plist_home="$(new_tmpdir)"
new_plist_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$new_plist_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist new-daemon v1/>' > services/ai.pierless.newdaemon.plist
  git add services/ai.pierless.newdaemon.plist
  git commit -q -m "add new daemon plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$new_plist_calls" run_deploy env HOME="$new_plist_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "new plist: exits 0"
installed_new_plist="$new_plist_home/Library/LaunchAgents/ai.pierless.newdaemon.plist"
if [ -f "$installed_new_plist" ]; then
  pass "new plist: copy lands in the fake HOME/Library/LaunchAgents"
else
  fail "new plist: copy lands in the fake HOME/Library/LaunchAgents (missing $installed_new_plist)"
fi
new_plist_calls_content="$(cat "$new_plist_calls")"
assert_contains "$new_plist_calls_content" "bootstrap" "new plist: launchctl bootstrap recorded"

# --- services hook: launchctl bootstrap itself fails -> HOOK_FAILED, exit 2 ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist bootstrapfail v1/>' > services/ai.pierless.bootstrapfail.plist
  git add services/ai.pierless.bootstrapfail.plist
  git commit -q -m "add bootstrapfail plist"
  git push -q origin main
)
stub_bin launchctl '
case "$1" in
  bootstrap) exit 1 ;;
  *) exit 0 ;;
esac
'
bootstrapfail_home="$(new_tmpdir)"
run_deploy env HOME="$bootstrapfail_home" PIERLESS_SERVICES_DIR="services"
assert_exit 2 "$DEPLOY_EXIT" "bootstrap fails: exits 2"
assert_contains "$DEPLOY_LOG" "hook: launchctl bootstrap FAILED for ai.pierless.bootstrapfail" "bootstrap fails: log names the failed label"
bootstrapfail_head="$(git -C "$HOST" rev-parse HEAD)"
bootstrapfail_origin_head="$(git -C "$ORIGIN" rev-parse refs/heads/main)"
assert_eq "$bootstrapfail_origin_head" "$bootstrapfail_head" "bootstrap fails: pull still happened despite the hook failure"

# --- services hook: a plist renamed to .plist.disabled is unloaded ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist to-disable v1/>' > services/ai.pierless.tobedisabled.plist
  git add services/ai.pierless.tobedisabled.plist
  git commit -q -m "add tobedisabled plist"
  git push -q origin main
)
( cd "$HOST" || exit 1; git pull -q origin main )
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
disable_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$disable_calls"
(
  cd "$DEV" || exit 1
  git mv services/ai.pierless.tobedisabled.plist services/ai.pierless.tobedisabled.plist.disabled
  git commit -q -m "disable daemon"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$disable_calls" run_deploy env HOME="$(new_tmpdir)" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "disabled plist: exits 0"
assert_contains "$DEPLOY_LOG" "renamed to .disabled" "disabled plist: log calls out the rename"
disable_calls_content="$(cat "$disable_calls")"
assert_contains "$disable_calls_content" "bootout" "disabled plist: launchctl bootout recorded"
assert_contains "$disable_calls_content" "ai.pierless.tobedisabled" "disabled plist: bootout named the right label"

# --- services hook: a deleted plist is unloaded and its copy removed ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist to-delete v1/>' > services/ai.pierless.todelete.plist
  git add services/ai.pierless.todelete.plist
  git commit -q -m "add todelete plist"
  git push -q origin main
)
( cd "$HOST" || exit 1; git pull -q origin main )
delete_home="$(new_tmpdir)"
mkdir -p "$delete_home/Library/LaunchAgents"
echo '<plist stale copy/>' > "$delete_home/Library/LaunchAgents/ai.pierless.todelete.plist"
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
delete_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$delete_calls"
(
  cd "$DEV" || exit 1
  git rm -q services/ai.pierless.todelete.plist
  git commit -q -m "remove todelete plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$delete_calls" run_deploy env HOME="$delete_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "deleted plist: exits 0"
assert_contains "$DEPLOY_LOG" "gone (removed or renamed to .disabled) — unloading" "deleted plist: log calls out the removal"
delete_calls_content="$(cat "$delete_calls")"
assert_contains "$delete_calls_content" "bootout" "deleted plist: launchctl bootout recorded"
if [ -f "$delete_home/Library/LaunchAgents/ai.pierless.todelete.plist" ]; then
  fail "deleted plist: stale copy removed from LaunchAgents (still present)"
else
  pass "deleted plist: stale copy removed from LaunchAgents"
fi

# --- PIERLESS_KICK: kickstart called for every named label ---
new_fixture
push_commit_from_dev "kick commit"
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
kick_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$kick_calls"
LAUNCHCTL_CALLS_LOG="$kick_calls" run_deploy env PIERLESS_KICK="daemon.one daemon.two"
assert_exit 0 "$DEPLOY_EXIT" "kick: exits 0"
kick_calls_content="$(cat "$kick_calls")"
assert_contains "$kick_calls_content" "kickstart -k gui/" "kick: launchctl kickstart -k invoked"
assert_contains "$kick_calls_content" "daemon.one" "kick: daemon.one kicked"
assert_contains "$kick_calls_content" "daemon.two" "kick: daemon.two kicked"

# --- PIERLESS_KICK: kickstart itself fails -> HOOK_FAILED, exit 2 ---
new_fixture
push_commit_from_dev "kickfail commit"
stub_bin launchctl '
case "$1" in
  kickstart) exit 1 ;;
  *) exit 0 ;;
esac
'
run_deploy env PIERLESS_KICK="daemon.fail"
assert_exit 2 "$DEPLOY_EXIT" "kick fails: exits 2"
assert_contains "$DEPLOY_LOG" "hook: kickstart FAILED for daemon.fail" "kick fails: log names the failed label"

# --- PIERLESS_INSTALL=none skips every install hook ---
new_fixture
(
  cd "$DEV" || exit 1
  echo '{"name":"fixture","v":2}' > package.json
  git add package.json
  git commit -q -m "bump package.json"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL=none PIERLESS_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "install=none: exits 0"
assert_contains "$DEPLOY_LOG" "PIERLESS_INSTALL=none, skipping install hooks" "install=none: log names the skip"
assert_not_contains "$DEPLOY_LOG" "hook: install in" "install=none: no install hook ran"

# --- custom glob=command pair runs in the changed file's directory ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p sub
  echo "x" > sub/marker.txt
  git add sub/marker.txt
  git commit -q -m "add marker"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL="marker.txt=touch ran-custom-hook.txt"
assert_exit 0 "$DEPLOY_EXIT" "custom glob: exits 0"
if [ -f "$HOST/sub/ran-custom-hook.txt" ]; then
  pass "custom glob: command ran in the changed file's directory"
else
  fail "custom glob: command ran in the changed file's directory (marker not found)"
fi

# --- install hook: the changed file's directory no longer exists on disk --
# (its only file was deleted in a later commit, so git removed the now-empty
# dir on checkout) -> skip logged, deploy still exits 0.
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p vanishing
  echo "x" > vanishing/marker.txt
  git add vanishing/marker.txt
  git commit -q -m "add vanishing marker"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL="marker.txt=true"
assert_exit 0 "$DEPLOY_EXIT" "vanishing dir setup: first pull exits 0"
(
  cd "$DEV" || exit 1
  git rm -q vanishing/marker.txt
  git commit -q -m "remove vanishing marker"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL="marker.txt=true"
assert_exit 0 "$DEPLOY_EXIT" "vanishing dir: exits 0"
assert_contains "$DEPLOY_LOG" "is not a directory" "vanishing dir: log names the skip"
assert_contains "$DEPLOY_LOG" "hook: skip install" "vanishing dir: log calls it a skip, not a failure"

# --- PIERLESS_DEBUG=1 prints debug lines; unset prints none ---
new_fixture
run_deploy env PIERLESS_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "debug on: exits 0"
assert_contains "$DEPLOY_LOG" "debug: behind=0 ahead=0" "debug on: debug lines present"

new_fixture
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "debug off: exits 0"
assert_not_contains "$DEPLOY_LOG" "debug:" "debug off: no debug lines"

# --- PIERLESS_DRY_RUN=1: deploy.sh has no dry-run support, so it is
# inert — the flag changes nothing and a real deploy still happens.
new_fixture
push_commit_from_dev "dry-run-flag commit"
run_deploy env PIERLESS_DRY_RUN=1
assert_exit 0 "$DEPLOY_EXIT" "PIERLESS_DRY_RUN=1: exits 0 same as without it"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "PIERLESS_DRY_RUN=1: still pulls for real (flag is a no-op in deploy.sh)"
assert_eq "true" "$(gh_output_value deployed)" "PIERLESS_DRY_RUN=1: deployed=true (not a dry run)"

# --- worktree prune: gh reports MERGED for one branch, OPEN for another ---
new_fixture
push_commit_from_dev "worktree-prune commit"
wt_merged="$(new_tmpdir)/wt-merged"
wt_open="$(new_tmpdir)/wt-open"
git -C "$HOST" worktree add -q -b feature-merged "$wt_merged" >/dev/null 2>&1
git -C "$HOST" worktree add -q -b feature-open "$wt_open" >/dev/null 2>&1
stub_bin gh '
case "$1" in
  pr)
    head=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--head" ]; then head="$a"; fi
      prev="$a"
    done
    case "$head" in
      feature-merged) echo "42" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) exit 1 ;;
esac
'
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "worktree prune: exits 0"
assert_contains "$DEPLOY_LOG" "worktree PRUNED" "worktree prune: log names a pruned worktree"
assert_contains "$DEPLOY_LOG" "(feature-merged, merged PR #42)" "worktree prune: merged branch pruned with its PR number"
assert_contains "$DEPLOY_LOG" "clean but no merged PR found, keeping" "worktree prune: open branch kept"
if [ -d "$wt_merged" ]; then
  fail "worktree prune: merged worktree removed (still present)"
else
  pass "worktree prune: merged worktree removed"
fi
if [ -d "$wt_open" ]; then
  pass "worktree prune: open worktree left in place"
else
  fail "worktree prune: open worktree left in place (was removed)"
fi
if git -C "$HOST" rev-parse --verify --quiet refs/heads/feature-merged >/dev/null 2>&1; then
  fail "worktree prune: merged local branch deleted (still exists)"
else
  pass "worktree prune: merged local branch deleted"
fi
if git -C "$HOST" rev-parse --verify --quiet refs/heads/feature-open >/dev/null 2>&1; then
  pass "worktree prune: open local branch kept"
else
  fail "worktree prune: open local branch kept (was deleted)"
fi

# --- worktree prune: merged+clean, but `git worktree remove` itself fails ---
new_fixture
push_commit_from_dev "worktree-prunefail commit"
wt_prunefail="$(new_tmpdir)/wt-prunefail"
git -C "$HOST" worktree add -q -b feature-prunefail "$wt_prunefail" >/dev/null 2>&1
stub_bin gh 'echo "99"; exit 0'
prunefail_git="$(fake_git_failing '*worktree remove*')"
run_deploy env PATH="$prunefail_git:$PATH"
assert_exit 0 "$DEPLOY_EXIT" "worktree prune, remove fails: exits 0 (non-fatal, just skipped)"
# The path git reports may be canonicalized (e.g. /private/var vs /var on
# macOS), so match on the branch name rather than the exact worktree path.
assert_contains "$DEPLOY_LOG" "worktree PRUNE FAILED" "worktree prune, remove fails: log names the failure"
assert_contains "$DEPLOY_LOG" "(feature-prunefail)" "worktree prune, remove fails: log names the failed branch"
if [ -d "$wt_prunefail" ]; then
  pass "worktree prune, remove fails: worktree left in place"
else
  fail "worktree prune, remove fails: worktree left in place (was removed)"
fi
if git -C "$HOST" rev-parse --verify --quiet refs/heads/feature-prunefail >/dev/null 2>&1; then
  pass "worktree prune, remove fails: local branch kept (remove failed before the branch delete)"
else
  fail "worktree prune, remove fails: local branch kept (was deleted)"
fi

# --- PIERLESS_BRANCH tracks a non-main branch end to end ---
base_nb="$(new_tmpdir)"
ORIGIN="$base_nb/origin.git"
HOST="$base_nb/host"
DEV="$base_nb/dev"
git init --bare -q "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$DEV"
(
  cd "$DEV" || exit 1
  git checkout -q -b main 2>/dev/null || git checkout -q main
  git config user.email "dev@example.com"
  git config user.name "dev"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "initial commit on main"
  git push -q origin main
  git checkout -q -b release
  git push -q origin release
)
git clone -q "$ORIGIN" "$HOST"
(
  cd "$HOST" || exit 1
  git config user.email "host@example.com"
  git config user.name "host"
  git fetch -q origin release
  git checkout -q release
)
(
  cd "$DEV" || exit 1
  git checkout -q release
  echo "release work" >> README.md
  git add README.md
  git commit -q -m "release commit"
  git push -q origin release
)
run_deploy env PIERLESS_BRANCH=release
assert_exit 0 "$DEPLOY_EXIT" "non-main branch: exits 0"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "non-main branch: pulled the release-branch commit"
release_branch_after="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "release" "$release_branch_after" "non-main branch: host stayed on release"
readme_on_release="$(cat "$HOST/README.md")"
assert_contains "$readme_on_release" "release work" "non-main branch: release commit content landed"


# --- PIERLESS_REPO points at something that is not a git checkout ---
not_a_repo="$(new_tmpdir)/plainfolder"
mkdir -p "$not_a_repo"
out="$(mktemp)"; err="$(mktemp)"
( PIERLESS_REPO="$not_a_repo" bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
notrepo_ec=$?
notrepo_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 64 "$notrepo_ec" "not a git checkout: exits 64"
assert_contains "$notrepo_err" "is not a git checkout" "not a git checkout: clear line naming the problem"

# --- AHEAD only: local unpushed commits, nothing pulled ---
new_fixture
(
  cd "$HOST" || exit 1
  echo "local only commit" >> README.md
  git add README.md
  git commit -q -m "local-only commit"
)
before_ahead_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "ahead only: exits 0"
assert_contains "$DEPLOY_LOG" "AHEAD 1 (local has un-pushed commits" "ahead only: log names the ahead-only state"
after_ahead_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_ahead_head" "$after_ahead_head" "ahead only: HEAD unchanged"
assert_eq "false" "$(gh_output_value deployed)" "ahead only: deployed=false"

# --- worktree prune: gh missing from PATH skips the whole step ---
# GitHub's own ubuntu-latest runners ship gh on the default PATH, so a
# hardcoded low-level dir list (e.g. /usr/bin:/bin) is not a reliable way
# to make gh absent there — it only worked on this Mac because gh isn't
# under those two dirs locally. Build the "no gh" condition explicitly
# instead: a PATH containing symlinks for only the binaries bin/deploy.sh
# itself calls (bash, to exec the script under the restricted PATH, plus
# every external command the script shells out to), skipping any that
# aren't present on this host, and never gh.
no_gh_bindir="$(new_tmpdir)/no-gh-bin"
mkdir -p "$no_gh_bindir"
for tool in bash git date mkdir rm cat grep sed sort tr basename dirname id sleep kill printf cp stat; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && ln -s "$tool_path" "$no_gh_bindir/$tool"
done
no_gh_path="$no_gh_bindir"
new_fixture
push_commit_from_dev "prune-no-gh commit"
run_deploy env PATH="$no_gh_path"
assert_exit 0 "$DEPLOY_EXIT" "prune without gh: exits 0"
assert_contains "$DEPLOY_LOG" "worktree prune SKIPPED — gh not on PATH" "prune without gh: log names the skip"

# --- worktree prune: a locked worktree is skipped, a dirty one is skipped ---
new_fixture
push_commit_from_dev "prune-locked-dirty commit"
wt_locked="$(new_tmpdir)/wt-locked"
wt_dirty="$(new_tmpdir)/wt-dirty"
git -C "$HOST" worktree add -q -b feature-locked "$wt_locked" >/dev/null 2>&1
git -C "$HOST" worktree add -q -b feature-dirty "$wt_dirty" >/dev/null 2>&1
git -C "$HOST" worktree lock "$wt_locked" >/dev/null 2>&1
echo "uncommitted edit" >> "$wt_dirty/README.md"
stub_bin gh 'echo ""; exit 0'
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "prune locked+dirty: exits 0"
assert_contains "$DEPLOY_LOG" "(feature-locked) — locked by an active session" "prune locked+dirty: locked worktree named and skipped"
assert_contains "$DEPLOY_LOG" "(feature-dirty) — dirty or missing" "prune locked+dirty: dirty worktree named and skipped"
if [ -d "$wt_locked" ]; then
  pass "prune locked+dirty: locked worktree left in place"
else
  fail "prune locked+dirty: locked worktree left in place (was removed)"
fi
if [ -d "$wt_dirty" ]; then
  pass "prune locked+dirty: dirty worktree left in place"
else
  fail "prune locked+dirty: dirty worktree left in place (was removed)"
fi

# ============================================================================
# Parking: decide before touching the tree, park only when a pull is coming
# ============================================================================

# --- dirty tree but nothing to pull: parking is skipped entirely ---
new_fixture
echo "local edit, nothing to pull" >> "$HOST/README.md"
before_dirty_content="$(cat "$HOST/README.md")"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "dirty+up-to-date: exits 0"
assert_contains "$DEPLOY_LOG" "up to date" "dirty+up-to-date: log says up to date"
assert_not_contains "$DEPLOY_LOG" "PARKED" "dirty+up-to-date: no PARKED line"
after_dirty_content="$(cat "$HOST/README.md")"
assert_eq "$before_dirty_content" "$after_dirty_content" "dirty+up-to-date: file left untouched"
stash_list_uptodate="$(git -C "$HOST" stash list)"
assert_empty "$stash_list_uptodate" "dirty+up-to-date: no stash created"

# --- dirty tree and diverged: refused, edit stays in the tree, no stash ---
new_fixture
push_commit_from_dev "diverged-origin commit"
(
  cd "$HOST" || exit 1
  echo "host only commit" >> README.md
  git add README.md
  git commit -q -m "host-only commit for diverged+dirty"
)
echo "uncommitted local edit" >> "$HOST/README.md"
before_diverged_dirty_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env
assert_exit 4 "$DEPLOY_EXIT" "dirty+diverged: exits 4"
after_diverged_dirty_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_diverged_dirty_head" "$after_diverged_dirty_head" "dirty+diverged: HEAD unchanged"
diverged_dirty_readme="$(cat "$HOST/README.md")"
assert_contains "$diverged_dirty_readme" "uncommitted local edit" "dirty+diverged: edit still in the tree"
stash_list_diverged="$(git -C "$HOST" stash list)"
assert_empty "$stash_list_diverged" "dirty+diverged: no stash created"

# --- dirty tree with a pull to do: parked, deployed, on_park hook fires ---
new_fixture
push_commit_from_dev "onpark commit"
echo "local edit before a real pull" >> "$HOST/README.md"
stub_bin record-on-park '{
  echo "FILES:$PIERLESS_PARKED_FILES" >> "$ONPARK_LOG"
  echo "STASH:$PIERLESS_STASH_NAME" >> "$ONPARK_LOG"
  echo "RUNURL:$PIERLESS_RUN_URL" >> "$ONPARK_LOG"
}'
onpark_log="$(new_tmpdir)/onpark.log"
: > "$onpark_log"
ONPARK_LOG="$onpark_log" run_deploy env PIERLESS_ON_PARK="record-on-park" PIERLESS_RUN_URL="https://example.test/run/1"
assert_exit 0 "$DEPLOY_EXIT" "dirty+new commit: exits 0"
assert_contains "$DEPLOY_LOG" "PARKED 1 file(s): README.md" "dirty+new commit: log names the parked file"
stash_list_onpark="$(git -C "$HOST" stash list)"
assert_contains "$stash_list_onpark" "pierless park" "dirty+new commit: stash present"
onpark_content="$(cat "$onpark_log" 2>/dev/null)"
assert_contains "$onpark_content" "FILES:README.md" "dirty+new commit: on_park called with the parked file named"
assert_contains "$onpark_content" "STASH:pierless park" "dirty+new commit: on_park called with the stash name"
assert_contains "$onpark_content" "RUNURL:https://example.test/run/1" "dirty+new commit: on_park sees PIERLESS_RUN_URL when set"

# --- on_park hook fails: non-fatal, deploy still exits 0 ---------------
new_fixture
push_commit_from_dev "onpark-fail commit"
echo "local edit ahead of a failing on_park hook" >> "$HOST/README.md"
stub_bin failing-on-park 'exit 7'
run_deploy env PIERLESS_ON_PARK="failing-on-park"
assert_exit 0 "$DEPLOY_EXIT" "on_park hook fails: still exits 0 (non-fatal)"
assert_contains "$DEPLOY_LOG" "PARKED 1 file(s): README.md" "on_park hook fails: parked file still logged"
assert_contains "$DEPLOY_LOG" "hook: PIERLESS_ON_PARK command failed (non-fatal)" "on_park hook fails: failure line logged"

# --- multiple parked files are all named in the PARKED line -------------
new_fixture
push_commit_from_dev "multi-park commit"
echo "edit one" >> "$HOST/README.md"
echo "new untracked file" > "$HOST/scratch.txt"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "multi-park: exits 0"
assert_contains "$DEPLOY_LOG" "PARKED 2 file(s):" "multi-park: log names 2 files"
assert_contains "$DEPLOY_LOG" "README.md" "multi-park: log lists README.md"
assert_contains "$DEPLOY_LOG" "scratch.txt" "multi-park: log lists scratch.txt"
stash_list_multipark="$(git -C "$HOST" stash list)"
assert_contains "$stash_list_multipark" "pierless park" "multi-park: stash present"

# --- PARK FAILED: git stash push itself fails, deploy refused -----------
new_fixture
push_commit_from_dev "parkfail commit"
echo "local edit that can never be parked" >> "$HOST/README.md"
parkfail_git="$(fake_git_failing 'stash push*')"
before_parkfail_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env PATH="$parkfail_git:$PATH"
assert_exit 4 "$DEPLOY_EXIT" "park failed: exits 4"
assert_contains "$DEPLOY_LOG" "PARK FAILED: git stash push failed" "park failed: log names the failure"
after_parkfail_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_parkfail_head" "$after_parkfail_head" "park failed: HEAD unchanged, nothing pulled"
parkfail_readme="$(cat "$HOST/README.md")"
assert_contains "$parkfail_readme" "local edit that can never be parked" "park failed: edit stays in the tree"

# --- merge fails despite behind-only check: parked edits are restored ---
new_fixture
push_commit_from_dev "mergefail commit"
echo "local edit to restore after a failed merge" >> "$HOST/README.md"
mergefail_git="$(fake_git_failing 'merge --ff-only*')"
before_mergefail_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env PATH="$mergefail_git:$PATH"
assert_exit 4 "$DEPLOY_EXIT" "merge failed: exits 4"
assert_contains "$DEPLOY_LOG" "MERGE FAILED despite behind-only check" "merge failed: log names the failure"
assert_contains "$DEPLOY_LOG" "RESTORED parked edits — no deploy happened" "merge failed: log says edits were restored"
after_mergefail_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_mergefail_head" "$after_mergefail_head" "merge failed: HEAD unchanged"
mergefail_readme="$(cat "$HOST/README.md")"
assert_contains "$mergefail_readme" "local edit to restore after a failed merge" "merge failed: edit restored to the tree"
mergefail_stash_list="$(git -C "$HOST" stash list)"
assert_empty "$mergefail_stash_list" "merge failed: stash popped, nothing left in it"

# --- merge AND the restoring stash pop both fail: edits stay in the stash
new_fixture
push_commit_from_dev "restorefail commit"
echo "local edit stuck in the stash" >> "$HOST/README.md"
restorefail_git="$(fake_git_failing 'merge --ff-only*|stash pop')"
before_restorefail_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env PATH="$restorefail_git:$PATH"
assert_exit 4 "$DEPLOY_EXIT" "restore failed: exits 4"
assert_contains "$DEPLOY_LOG" "RESTORE FAILED: git stash pop failed" "restore failed: log names the failure"
after_restorefail_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_restorefail_head" "$after_restorefail_head" "restore failed: HEAD unchanged"
restorefail_readme="$(cat "$HOST/README.md")"
assert_not_contains "$restorefail_readme" "local edit stuck in the stash" "restore failed: edit not back in the tree (still stashed)"
restorefail_stash_list="$(git -C "$HOST" stash list)"
assert_contains "$restorefail_stash_list" "pierless park" "restore failed: edit still recoverable from the stash"

# --- clean tree with a pull to do: nothing parked, on_park never runs ---
new_fixture
push_commit_from_dev "no-park commit"
stub_bin record-on-park-2 'echo "CALLED" >> "$ONPARK_LOG2"'
onpark_log2="$(new_tmpdir)/onpark2.log"
: > "$onpark_log2"
ONPARK_LOG2="$onpark_log2" run_deploy env PIERLESS_ON_PARK="record-on-park-2"
assert_exit 0 "$DEPLOY_EXIT" "clean+new commit: exits 0"
assert_not_contains "$DEPLOY_LOG" "PARKED" "clean+new commit: no PARKED line"
onpark2_content="$(cat "$onpark_log2" 2>/dev/null)"
assert_empty "$onpark2_content" "clean+new commit: on_park never invoked"

# ============================================================================
# Hook idempotency: resume from the last completed SHA across a crash
# ============================================================================

# --- marker rewound to the pre-pull SHA: hooks re-run for that range, --
# --- and the marker is rewritten back to HEAD ---------------------------
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
resume_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$resume_calls"
resume_home="$(new_tmpdir)"
pre_pull_sha="$(git -C "$HOST" rev-parse HEAD)"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist resume-daemon v1/>' > services/ai.pierless.resume.plist
  git add services/ai.pierless.resume.plist
  git commit -q -m "add resume daemon plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$resume_calls" run_deploy env HOME="$resume_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "hook idempotency: first pull exits 0"
resume_state_dir="$DEPLOY_STATE_DIR"
resume_marker="$resume_state_dir/last-hooked-sha"
post_pull_sha="$(git -C "$HOST" rev-parse HEAD)"
if [ -f "$resume_marker" ]; then
  pass "hook idempotency: marker file written after the first pull"
else
  fail "hook idempotency: marker file written after the first pull (missing $resume_marker)"
fi
assert_eq "$post_pull_sha" "$(cat "$resume_marker" 2>/dev/null)" "hook idempotency: marker matches HEAD after the first pull"

# Rewind the marker to simulate a crash between the fast-forward and its
# hooks finishing, then run again with nothing new to pull.
printf '%s\n' "$pre_pull_sha" > "$resume_marker"
: > "$resume_calls"
LAUNCHCTL_CALLS_LOG="$resume_calls" run_deploy env HOME="$resume_home" PIERLESS_SERVICES_DIR="services" PIERLESS_STATE_DIR="$resume_state_dir"
assert_exit 0 "$DEPLOY_EXIT" "hook idempotency: resume run exits 0"
assert_contains "$DEPLOY_LOG" "hooks: resuming from ${pre_pull_sha}" "hook idempotency: log names the resume point"
resume_calls_content="$(cat "$resume_calls" 2>/dev/null)"
assert_contains "$resume_calls_content" "bootstrap" "hook idempotency: resumed run re-ran the service hook"
assert_eq "$post_pull_sha" "$(cat "$resume_marker" 2>/dev/null)" "hook idempotency: marker rewritten to HEAD after the resume"

# --- up to date, resuming a stale marker's hooks: a hook fails -> exit 2
new_fixture
uptodate_fail_pre_sha="$(git -C "$HOST" rev-parse HEAD)"
(
  cd "$DEV" || exit 1
  echo '{"name":"fixture","v":2}' > package.json
  git add package.json
  git commit -q -m "bump package.json for the resume-hook-failure case"
  git push -q origin main
)
run_deploy env PIERLESS_INSTALL="none"
assert_exit 0 "$DEPLOY_EXIT" "up-to-date resume, hook fails: first (clean) pull exits 0"
uptodate_fail_state_dir="$DEPLOY_STATE_DIR"
uptodate_fail_marker="$uptodate_fail_state_dir/last-hooked-sha"
printf '%s\n' "$uptodate_fail_pre_sha" > "$uptodate_fail_marker"
run_deploy env PIERLESS_INSTALL="package.json=false" PIERLESS_STATE_DIR="$uptodate_fail_state_dir"
assert_exit 2 "$DEPLOY_EXIT" "up-to-date resume, hook fails: exits 2"
assert_contains "$DEPLOY_LOG" "up to date, nothing new to pull — hooks never finished last time" "up-to-date resume, hook fails: log says hooks never finished"
assert_contains "$DEPLOY_LOG" "hooks: resuming from ${uptodate_fail_pre_sha}" "up-to-date resume, hook fails: log names the resume point"
assert_contains "$DEPLOY_LOG" "EXIT 2: a hook failed" "up-to-date resume, hook fails: log names the exit-2 reason"
assert_eq "false" "$(gh_output_value deployed)" "up-to-date resume, hook fails: deployed=false (nothing was pulled)"

# --- a further pull resumes hooks from an even-older stale marker -------
new_fixture
further_resume_c0="$(git -C "$HOST" rev-parse HEAD)"
push_commit_from_dev "further-resume first commit"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "further resume: first pull exits 0"
further_resume_state_dir="$DEPLOY_STATE_DIR"
further_resume_marker="$further_resume_state_dir/last-hooked-sha"
further_resume_c1="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$further_resume_c1" "$(cat "$further_resume_marker" 2>/dev/null)" "further resume: marker matches HEAD after the first pull"
push_commit_from_dev "further-resume second commit"
# Rewind the marker further back than even the previous pull's start —
# simulates a crash that predates the LAST successful deploy, not just
# this one — so this run's own pre-merge SHA (further_resume_c1) is not
# where hooks resume from; the older marker is.
printf '%s\n' "$further_resume_c0" > "$further_resume_marker"
run_deploy env PIERLESS_STATE_DIR="$further_resume_state_dir"
assert_exit 0 "$DEPLOY_EXIT" "further resume: second pull exits 0"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "further resume: second pull log names 1 commit"
assert_contains "$DEPLOY_LOG" "hooks: resuming from ${further_resume_c0}" "further resume: log names the older resume point, not the pre-merge SHA"
further_resume_c2="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$further_resume_c2" "$(cat "$further_resume_marker" 2>/dev/null)" "further resume: marker rewritten to the new HEAD"

# --- marker already equals HEAD, up to date: no hook call at all -------
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
eqhead_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$eqhead_calls"
eqhead_home="$(new_tmpdir)"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist eqhead-daemon v1/>' > services/ai.pierless.eqhead.plist
  git add services/ai.pierless.eqhead.plist
  git commit -q -m "add eqhead daemon plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$eqhead_calls" run_deploy env HOME="$eqhead_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "hook idempotency (marker==HEAD): first pull exits 0"
eqhead_state_dir="$DEPLOY_STATE_DIR"
eqhead_marker="$eqhead_state_dir/last-hooked-sha"
head_after_pull="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$head_after_pull" "$(cat "$eqhead_marker" 2>/dev/null)" "hook idempotency (marker==HEAD): marker matches HEAD after the pull"
: > "$eqhead_calls"
LAUNCHCTL_CALLS_LOG="$eqhead_calls" run_deploy env HOME="$eqhead_home" PIERLESS_SERVICES_DIR="services" PIERLESS_STATE_DIR="$eqhead_state_dir"
assert_exit 0 "$DEPLOY_EXIT" "hook idempotency (marker==HEAD): second run (up to date) exits 0"
assert_contains "$DEPLOY_LOG" "up to date, nothing to deploy" "hook idempotency (marker==HEAD): log says up to date"
assert_not_contains "$DEPLOY_LOG" "hooks: resuming" "hook idempotency (marker==HEAD): no resume line"
eqhead_calls_content="$(cat "$eqhead_calls" 2>/dev/null)"
assert_empty "$eqhead_calls_content" "hook idempotency (marker==HEAD): no launchctl call on the up-to-date run"

# ============================================================================
# Services hook: a plist's log directories exist before it is bootstrapped
# ============================================================================

# --- StandardOutPath/StandardErrorPath point into a not-yet-existing ---
# --- directory: the services hook creates it before bootstrapping ------
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
logdirs_home="$(new_tmpdir)"
not_yet_dir="$(new_tmpdir)/not-yet-created/logs"
logdir_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$logdir_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  {
    echo '<key>StandardOutPath</key>'
    echo "<string>${not_yet_dir}/out.log</string>"
    echo '<key>StandardErrorPath</key>'
    echo "<string>${not_yet_dir}/err.log</string>"
  } > services/ai.pierless.logdirs.plist
  git add services/ai.pierless.logdirs.plist
  git commit -q -m "add logdirs plist"
  git push -q origin main
)
if [ -d "$not_yet_dir" ]; then
  fail "plist log dirs: directory does not exist before the deploy (already present)"
else
  pass "plist log dirs: directory does not exist before the deploy"
fi
LAUNCHCTL_CALLS_LOG="$logdir_calls" run_deploy env HOME="$logdirs_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "plist log dirs: exits 0"
if [ -d "$not_yet_dir" ]; then
  pass "plist log dirs: StandardOutPath/StandardErrorPath directory created before bootstrap"
else
  fail "plist log dirs: StandardOutPath/StandardErrorPath directory created before bootstrap (missing $not_yet_dir)"
fi
logdir_calls_content="$(cat "$logdir_calls" 2>/dev/null)"
assert_contains "$logdir_calls_content" "bootstrap" "plist log dirs: launchctl bootstrap still ran"

# ============================================================================
# extract_plist_value: the plutil path and the grep-fallback path, each
# forced deterministically regardless of what the host actually has on
# PATH (a real Mac has plutil; ubuntu-latest never does).
# ============================================================================

# --- plutil present (stubbed) and succeeds: its value wins, no fallback -
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
plutilok_home="$(new_tmpdir)"
plutilok_out_dir="$(new_tmpdir)/plutil-stub-out"
plutilok_err_dir="$(new_tmpdir)/plutil-stub-err"
stub_bin plutil '
  case "$2" in
    StandardOutPath) printf "%s" "$PLUTILOK_OUT_VAL" ;;
    StandardErrorPath) printf "%s" "$PLUTILOK_ERR_VAL" ;;
  esac
  exit 0
'
plutilok_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$plutilok_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  # Deliberately unparseable as a real plist fragment (no <plist><dict>
  # wrapper) — if the real, unstubbed plutil ever ran against this it
  # would fail and fall through to grep; the stub is what must answer.
  echo '<key>StandardOutPath</key><string>ignored-by-the-stub</string>' > services/ai.pierless.plutilok.plist
  git add services/ai.pierless.plutilok.plist
  git commit -q -m "add plutilok plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$plutilok_calls" \
  PLUTILOK_OUT_VAL="${plutilok_out_dir}/out.log" \
  PLUTILOK_ERR_VAL="${plutilok_err_dir}/err.log" \
  run_deploy env HOME="$plutilok_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "plutil present: exits 0"
if [ -d "$plutilok_out_dir" ]; then
  pass "plutil present: StandardOutPath dir created from the plutil stub's value"
else
  fail "plutil present: StandardOutPath dir created from the plutil stub's value (missing $plutilok_out_dir)"
fi
if [ -d "$plutilok_err_dir" ]; then
  pass "plutil present: StandardErrorPath dir created from the plutil stub's value"
else
  fail "plutil present: StandardErrorPath dir created from the plutil stub's value (missing $plutilok_err_dir)"
fi

# --- plutil present but fails, printing its error on STDOUT (macOS 14
# --- shape): the error text is not taken as a path; grep fallback wins --
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
plutilerr_home="$(new_tmpdir)"
plutilerr_dir="$(new_tmpdir)/plutil-error-fallback-logs"
plutilerr_seen="$(new_tmpdir)/plutil-error-seen"
stub_bin plutil '
  echo "seen" >> "$PLUTILERR_SEEN"
  # macOS 14 prints this on stdout, not stderr, and exits 1.
  echo "$6: Could not extract value, error: No value at that key path or invalid key path: $2"
  exit 1
'
plutilerr_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$plutilerr_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  {
    echo '<key>StandardOutPath</key>'
    echo "<string>${plutilerr_dir}/out.log</string>"
    echo '<key>StandardErrorPath</key>'
    echo "<string>${plutilerr_dir}/err.log</string>"
  } > services/ai.pierless.plutilerr.plist
  git add services/ai.pierless.plutilerr.plist
  git commit -q -m "add plutilerr plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$plutilerr_calls" PLUTILERR_SEEN="$plutilerr_seen" \
  run_deploy env HOME="$plutilerr_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "plutil fails on stdout: exits 0"
if [ -s "$plutilerr_seen" ]; then
  pass "plutil fails on stdout: the plutil stub was actually consulted"
else
  fail "plutil fails on stdout: the plutil stub was actually consulted"
fi
if [ -d "$plutilerr_dir" ]; then
  pass "plutil fails on stdout: grep fallback created the log dir"
else
  fail "plutil fails on stdout: grep fallback created the log dir (missing $plutilerr_dir)"
fi
if [ -d "$DEV/services/ai.pierless.plutilerr.plist: Could not extract value, error: No value at that key path or invalid key path: StandardOutPath" ] \
   || ls -d "$DEV"/services/*"Could not extract"* >/dev/null 2>&1; then
  fail "plutil fails on stdout: no directory was created from the error text"
else
  pass "plutil fails on stdout: no directory was created from the error text"
fi
plutilerr_calls_content="$(cat "$plutilerr_calls" 2>/dev/null)"
assert_contains "$plutilerr_calls_content" "bootstrap" "plutil fails on stdout: launchctl bootstrap still ran"

# --- plutil absent (hidden from PATH): grep fallback extracts the value -
# NOTE: this test builds its own restricted PATH via bindir_without, so it
# writes its own launchctl stub straight into that dir rather than using
# stub_bin — stub_bin's dir is shared across the whole file (the earlier
# "plutil present" test already left a plutil stub in it), and prepending
# it here would silently put plutil right back on PATH.
new_fixture
noplutil_home="$(new_tmpdir)"
noplutil_dir="$(new_tmpdir)/grep-fallback-logs"
noplutil_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$noplutil_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  {
    echo '<key>StandardOutPath</key>'
    echo "<string>${noplutil_dir}/out.log</string>"
    echo '<key>StandardErrorPath</key>'
    echo "<string>${noplutil_dir}/err.log</string>"
  } > services/ai.pierless.noplutil.plist
  git add services/ai.pierless.noplutil.plist
  git commit -q -m "add noplutil plist"
  git push -q origin main
)
noplutil_bindir="$(bindir_without plutil)"
cat > "$noplutil_bindir/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"
exit 0
EOF
chmod +x "$noplutil_bindir/launchctl"
if [ -d "$noplutil_dir" ]; then
  fail "plutil absent: log dir does not exist before the deploy (already present)"
else
  pass "plutil absent: log dir does not exist before the deploy"
fi
LAUNCHCTL_CALLS_LOG="$noplutil_calls" run_deploy env HOME="$noplutil_home" PIERLESS_SERVICES_DIR="services" \
  PATH="$noplutil_bindir"
assert_exit 0 "$DEPLOY_EXIT" "plutil absent: exits 0"
if [ -d "$noplutil_dir" ]; then
  pass "plutil absent: grep fallback still found StandardOutPath/StandardErrorPath and created the dir"
else
  fail "plutil absent: grep fallback still found StandardOutPath/StandardErrorPath and created the dir (missing $noplutil_dir)"
fi
noplutil_calls_content="$(cat "$noplutil_calls" 2>/dev/null)"
assert_contains "$noplutil_calls_content" "bootstrap" "plutil absent: launchctl bootstrap still ran"

# --- only StandardErrorPath is set: StandardOutPath is skipped cleanly --
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
erronly_home="$(new_tmpdir)"
erronly_out_dir="$(new_tmpdir)/erronly-out-should-not-exist"
erronly_err_dir="$(new_tmpdir)/erronly-err"
stub_bin plutil '
  case "$2" in
    StandardErrorPath) printf "%s" "$ERRONLY_ERR_VAL" ;;
    StandardOutPath) printf "" ;;
  esac
  exit 0
'
erronly_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$erronly_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<key>StandardErrorPath</key><string>ignored-by-the-stub</string>' > services/ai.pierless.erronly.plist
  git add services/ai.pierless.erronly.plist
  git commit -q -m "add erronly plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$erronly_calls" \
  ERRONLY_ERR_VAL="${erronly_err_dir}/err.log" \
  run_deploy env HOME="$erronly_home" PIERLESS_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "StandardErrorPath only: exits 0"
if [ -d "$erronly_err_dir" ]; then
  pass "StandardErrorPath only: its log dir is created"
else
  fail "StandardErrorPath only: its log dir is created (missing $erronly_err_dir)"
fi
if [ -d "$erronly_out_dir" ]; then
  fail "StandardErrorPath only: no StandardOutPath dir is invented (found $erronly_out_dir)"
else
  pass "StandardErrorPath only: no StandardOutPath dir is invented"
fi
erronly_calls_content="$(cat "$erronly_calls" 2>/dev/null)"
assert_contains "$erronly_calls_content" "bootstrap" "StandardErrorPath only: launchctl bootstrap still ran"


test_summary_and_exit
