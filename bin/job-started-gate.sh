#!/usr/bin/env bash
# bin/job-started-gate.sh — ACTIONS_RUNNER_HOOK_JOB_STARTED gate.
#
# GitHub runs this hook before any workflow step and fails the job on any
# non-zero exit, so a job from any other workflow, branch, fork, or repo
# never runs a single command as this user. It allows exactly one job.
#
# ENV: PIERLESS_ALLOWED_WORKFLOW_REF (required, e.g.
#   owner/repo/.github/workflows/deploy.yml@refs/heads/main),
#   PIERLESS_ALLOWED_REPOSITORY (required, owner/repo),
#   PIERLESS_ALLOWED_REF (default refs/heads/main),
#   PIERLESS_ALLOWED_JOB (default deploy). GITHUB_EVENT_NAME has no
#   override: it must be push, schedule, or workflow_dispatch.
#
# NO NETWORK CALLS, no external command beyond bash builtins — GitHub sets
# no timeout on this hook, so a stalled call here wedges every future job.
#
# PIERLESS_DEBUG=1 prints each comparison to stderr.

set -euo pipefail

ALLOWED_WORKFLOW_REF="${PIERLESS_ALLOWED_WORKFLOW_REF:-}"
ALLOWED_REPOSITORY="${PIERLESS_ALLOWED_REPOSITORY:-}"
ALLOWED_REF="${PIERLESS_ALLOWED_REF:-refs/heads/main}"
ALLOWED_JOB="${PIERLESS_ALLOWED_JOB:-deploy}"

WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
REF="${GITHUB_REF:-}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
JOB="${GITHUB_JOB:-}"

debug() { [ "${PIERLESS_DEBUG:-0}" = "1" ] && printf 'pierless gate: %s\n' "$1" >&2; return 0; }

refuse() {
  printf 'pierless gate: refused — %s (workflow_ref=%s repository=%s ref=%s event=%s job=%s)\n' "$1" "${WORKFLOW_REF:-unset}" "${REPOSITORY:-unset}" "${REF:-unset}" "${EVENT_NAME:-unset}" "${JOB:-unset}" >&2
  exit 1
}

[ -n "${ALLOWED_WORKFLOW_REF}" ] || refuse "PIERLESS_ALLOWED_WORKFLOW_REF is unset or empty"
[ -n "${ALLOWED_REPOSITORY}" ] || refuse "PIERLESS_ALLOWED_REPOSITORY is unset or empty"

debug "workflow_ref '${WORKFLOW_REF:-unset}' vs allowed '${ALLOWED_WORKFLOW_REF}'"
[ -n "${WORKFLOW_REF}" ] || refuse "GITHUB_WORKFLOW_REF is unset or empty"
[ "${WORKFLOW_REF}" = "${ALLOWED_WORKFLOW_REF}" ] || refuse "workflow_ref does not match the allowed ref exactly"

debug "repository '${REPOSITORY:-unset}' vs allowed '${ALLOWED_REPOSITORY}'"
[ -n "${REPOSITORY}" ] || refuse "GITHUB_REPOSITORY is unset or empty"
[ "${REPOSITORY}" = "${ALLOWED_REPOSITORY}" ] || refuse "repository does not match the allowed repository exactly"

debug "ref '${REF:-unset}' vs allowed '${ALLOWED_REF}'"
[ -n "${REF}" ] || refuse "GITHUB_REF is unset or empty"
[ "${REF}" = "${ALLOWED_REF}" ] || refuse "ref does not match the allowed ref exactly"

debug "event_name '${EVENT_NAME:-unset}' vs push|schedule|workflow_dispatch"
[ -n "${EVENT_NAME}" ] || refuse "GITHUB_EVENT_NAME is unset or empty"
case "${EVENT_NAME}" in
  push|schedule|workflow_dispatch) : ;;
  *) refuse "event_name is not push, schedule, or workflow_dispatch" ;;
esac

debug "job '${JOB:-unset}' vs allowed '${ALLOWED_JOB}'"
[ -n "${JOB}" ] || refuse "GITHUB_JOB is unset or empty"
[ "${JOB}" = "${ALLOWED_JOB}" ] || refuse "job does not match the allowed job exactly"

printf 'pierless gate: allowed %s\n' "${WORKFLOW_REF}"
exit 0
