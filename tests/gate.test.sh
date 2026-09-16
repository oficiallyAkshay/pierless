#!/usr/bin/env bash
# tests/gate.test.sh — bin/job-started-gate.sh: allow/refuse matrix.
#
# No associative arrays, no `set -u`: this repo's system bash target is
# macOS's bash 3.2, which has neither (see tests/lib.sh for the empty-
# array-under-set-u pitfall).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/bin/job-started-gate.sh"
require_script "$GATE_SCRIPT"

ALL_KEYS="PIERLESS_ALLOWED_WORKFLOW_REF PIERLESS_ALLOWED_REPOSITORY GITHUB_WORKFLOW_REF GITHUB_REPOSITORY GITHUB_REF GITHUB_EVENT_NAME GITHUB_JOB"

default_value() {
  case "$1" in
    PIERLESS_ALLOWED_WORKFLOW_REF) echo "owner/repo/.github/workflows/deploy.yml@refs/heads/main" ;;
    PIERLESS_ALLOWED_REPOSITORY) echo "owner/repo" ;;
    GITHUB_WORKFLOW_REF) echo "owner/repo/.github/workflows/deploy.yml@refs/heads/main" ;;
    GITHUB_REPOSITORY) echo "owner/repo" ;;
    GITHUB_REF) echo "refs/heads/main" ;;
    GITHUB_EVENT_NAME) echo "push" ;;
    GITHUB_JOB) echo "deploy" ;;
  esac
}

GATE_STDOUT=""
GATE_STDERR=""
GATE_EXIT=""

run_gate_env() {
  # args: any number of "KEY=VALUE" pairs, passed through env -i.
  # BASH_ENV/PIERLESS_TRACE_FILE are forwarded too (when set) so a
  # traced run still traces the gate script through this clean-env
  # wrapper — they're plumbing for the test run, not gate inputs.
  local out err ec
  local trace_args=()
  [ -n "${BASH_ENV:-}" ] && trace_args+=("BASH_ENV=$BASH_ENV")
  [ -n "${PIERLESS_TRACE_FILE:-}" ] && trace_args+=("PIERLESS_TRACE_FILE=$PIERLESS_TRACE_FILE")
  out="$(mktemp)"; err="$(mktemp)"
  if env -i PATH="$PATH" "${trace_args[@]}" "$@" bash "$GATE_SCRIPT" >"$out" 2>"$err"; then
    ec=0
  else
    ec=$?
  fi
  GATE_STDOUT="$(cat "$out")"
  GATE_STDERR="$(cat "$err")"
  GATE_EXIT="$ec"
  rm -f "$out" "$err"
}

# run_with_overrides UNSET_KEY OVERRIDE_KEY OVERRIDE_VALUE
# Builds the full correct env from defaults, drops UNSET_KEY (if
# non-empty), and replaces OVERRIDE_KEY's value with OVERRIDE_VALUE (if
# non-empty).
run_with_overrides() {
  local unset_key="$1" override_key="$2" override_val="$3"
  local args=()
  local k v
  for k in $ALL_KEYS; do
    if [ -n "$unset_key" ] && [ "$k" = "$unset_key" ]; then
      continue
    fi
    v="$(default_value "$k")"
    if [ -n "$override_key" ] && [ "$k" = "$override_key" ]; then
      v="$override_val"
    fi
    args+=("$k=$v")
  done
  run_gate_env "${args[@]}"
}

# --- allow with all five right ---
run_with_overrides "" "" ""
assert_exit 0 "$GATE_EXIT" "allow: all correct values exits 0"
assert_contains "$GATE_STDOUT" "allowed" "allow: stdout announces allowed"
assert_empty "$GATE_STDERR" "allow: stderr empty on allow"

# --- refuse on each wrong value ---
run_with_overrides "" "PIERLESS_ALLOWED_WORKFLOW_REF" "owner/repo/.github/workflows/other.yml@refs/heads/main"
assert_exit 1 "$GATE_EXIT" "refuse: wrong PIERLESS_ALLOWED_WORKFLOW_REF"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong allowed workflow ref)"
assert_contains "$GATE_STDERR" "refused —" "refuse: names the reason (wrong allowed workflow ref)"
assert_contains "$GATE_STDERR" "workflow_ref does not match" "refuse: specific reason (wrong allowed workflow ref)"

run_with_overrides "" "PIERLESS_ALLOWED_REPOSITORY" "owner/other-repo"
assert_exit 1 "$GATE_EXIT" "refuse: wrong PIERLESS_ALLOWED_REPOSITORY"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong allowed repository)"
assert_contains "$GATE_STDERR" "repository does not match" "refuse: specific reason (wrong allowed repository)"

run_with_overrides "" "GITHUB_WORKFLOW_REF" "owner/repo/.github/workflows/deploy.yml@refs/heads/other"
assert_exit 1 "$GATE_EXIT" "refuse: wrong GITHUB_WORKFLOW_REF"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong workflow ref)"
assert_contains "$GATE_STDERR" "workflow_ref does not match" "refuse: specific reason (wrong workflow ref)"

run_with_overrides "" "GITHUB_REPOSITORY" "someone/else"
assert_exit 1 "$GATE_EXIT" "refuse: wrong GITHUB_REPOSITORY"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong repository)"
assert_contains "$GATE_STDERR" "repository does not match" "refuse: specific reason (wrong repository)"

run_with_overrides "" "GITHUB_REF" "refs/heads/other"
assert_exit 1 "$GATE_EXIT" "refuse: wrong GITHUB_REF"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong ref)"
assert_contains "$GATE_STDERR" "ref does not match" "refuse: specific reason (wrong ref)"

run_with_overrides "" "GITHUB_REF" "refs/heads/main-evil"
assert_exit 1 "$GATE_EXIT" "refuse: ref named as a prefix of the allowed branch (main-evil)"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (main-evil ref)"
assert_contains "$GATE_STDERR" "ref does not match" "refuse: specific reason (main-evil ref)"

run_with_overrides "" "GITHUB_EVENT_NAME" "pull_request"
assert_exit 1 "$GATE_EXIT" "refuse: pull_request event"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (pull_request event)"
assert_contains "$GATE_STDERR" "event_name is not push" "refuse: specific reason (pull_request event)"

run_with_overrides "" "GITHUB_JOB" "build"
assert_exit 1 "$GATE_EXIT" "refuse: wrong GITHUB_JOB"
assert_empty "$GATE_STDOUT" "refuse: stdout empty (wrong job)"
assert_contains "$GATE_STDERR" "job does not match" "refuse: specific reason (wrong job)"

# --- refuse on each unset/missing variable ---
for k in $ALL_KEYS; do
  run_with_overrides "$k" "" ""
  assert_exit 1 "$GATE_EXIT" "refuse: $k unset"
  assert_empty "$GATE_STDOUT" "refuse: stdout empty ($k unset)"
  assert_contains "$GATE_STDERR" "refused —" "refuse: names the reason ($k unset)"
done

# --- override knobs honored ---
custom_ref_args=()
for k in $ALL_KEYS; do
  v="$(default_value "$k")"
  [ "$k" = "GITHUB_REF" ] && v="refs/heads/custom"
  custom_ref_args+=("$k=$v")
done
custom_ref_args+=("PIERLESS_ALLOWED_REF=refs/heads/custom")
run_gate_env "${custom_ref_args[@]}"
assert_exit 0 "$GATE_EXIT" "override: PIERLESS_ALLOWED_REF honored with matching GITHUB_REF"
assert_contains "$GATE_STDOUT" "allowed" "override: stdout announces allowed (custom ref)"

custom_job_args=()
for k in $ALL_KEYS; do
  v="$(default_value "$k")"
  [ "$k" = "GITHUB_JOB" ] && v="custom-job"
  custom_job_args+=("$k=$v")
done
custom_job_args+=("PIERLESS_ALLOWED_JOB=custom-job")
run_gate_env "${custom_job_args[@]}"
assert_exit 0 "$GATE_EXIT" "override: PIERLESS_ALLOWED_JOB honored with matching GITHUB_JOB"

# without the override knob, the default (main / deploy) is still enforced
nooverride_ref_args=()
for k in $ALL_KEYS; do
  v="$(default_value "$k")"
  [ "$k" = "GITHUB_REF" ] && v="refs/heads/custom"
  nooverride_ref_args+=("$k=$v")
done
run_gate_env "${nooverride_ref_args[@]}"
assert_exit 1 "$GATE_EXIT" "override: default ref still enforced when PIERLESS_ALLOWED_REF is not set"

test_summary_and_exit
