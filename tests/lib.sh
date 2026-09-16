#!/usr/bin/env bash
# tests/lib.sh — tiny assertion library for pierless tests. No bats.
#
# Sourced by every tests/*.test.sh. Each test file runs as its own bash
# process (invoked by tests/run.sh), so the counters below are private to
# one file's run.

set -o pipefail
# NOTE: no `set -u` — macOS ships bash 3.2, where an EMPTY array
# expansion (e.g. "${arr[@]}" on a zero-element array) throws "unbound
# variable" under -u even though the array is defined. Every script in
# this repo targets bash 3.2 (no associative arrays either); required
# env vars are still checked explicitly with ${VAR:-} guards.

PIERLESS_TEST_COUNT=0
PIERLESS_TEST_FAILURES=0
PIERLESS_TEST_TMPDIRS=()
PIERLESS_TEST_STUB_DIR=""

pass() {
  PIERLESS_TEST_COUNT=$((PIERLESS_TEST_COUNT + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  PIERLESS_TEST_COUNT=$((PIERLESS_TEST_COUNT + 1))
  PIERLESS_TEST_FAILURES=$((PIERLESS_TEST_FAILURES + 1))
  printf 'not ok - %s\n' "$1"
}

skip() {
  printf 'skip - %s\n' "$1"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values equal}"
  if [ "$expected" = "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (expected [$expected], got [$actual])"
  fi
}

assert_exit() {
  local expected="$1" actual="$2" msg="${3:-exit code}"
  assert_eq "$expected" "$actual" "$msg"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-contains}"
  case "$haystack" in
    *"$needle"*) pass "$msg" ;;
    *) fail "$msg (expected to contain [$needle], got [$haystack])" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-does not contain}"
  case "$haystack" in
    *"$needle"*) fail "$msg (expected NOT to contain [$needle], got [$haystack])" ;;
    *) pass "$msg" ;;
  esac
}

assert_empty() {
  local actual="$1" msg="${2:-empty}"
  if [ -z "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (expected empty, got [$actual])"
  fi
}

assert_true() {
  local cond="$1" msg="${2:-condition true}"
  if [ "$cond" = "0" ]; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

# new_tmpdir — creates a temp dir, tracks it for cleanup on exit, prints path.
new_tmpdir() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pierless-test.XXXXXX")"
  PIERLESS_TEST_TMPDIRS+=("$d")
  printf '%s\n' "$d"
}

_pierless_test_cleanup() {
  local d
  for d in "${PIERLESS_TEST_TMPDIRS[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap _pierless_test_cleanup EXIT

# stub_bin NAME BODY — puts a fake executable named NAME first on PATH.
# BODY is the script body (no shebang needed). Calling it again for the
# same NAME overwrites the stub. All stubs share one dir prepended once.
stub_bin() {
  local name="$1" body="$2"
  if [ -z "$PIERLESS_TEST_STUB_DIR" ]; then
    PIERLESS_TEST_STUB_DIR="$(new_tmpdir)"
    export PATH="$PIERLESS_TEST_STUB_DIR:$PATH"
  fi
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$PIERLESS_TEST_STUB_DIR/$name"
  chmod +x "$PIERLESS_TEST_STUB_DIR/$name"
}

# require_script PATH — prints a skip note and exits 0 (whole file skipped)
# when the sibling script under test is not yet on disk. Keeps the test
# file itself always runnable and always syntax-checked.
require_script() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo "SKIP - $path not present yet (not yet runnable)"
    exit 0
  fi
}

test_summary_and_exit() {
  printf -- '--- %d assertion(s), %d failed ---\n' "$PIERLESS_TEST_COUNT" "$PIERLESS_TEST_FAILURES"
  [ "$PIERLESS_TEST_FAILURES" -eq 0 ]
}
