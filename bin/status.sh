#!/usr/bin/env bash
# bin/status.sh — one-shot health read of the runner and the last deploy.
#
# Prints: launchd state and pid, GitHub-side runner status (when --repo is
# given or the runner dir's own registration is readable), the tail of the
# deploy log, and the last refusal line from the newest diag log, if any.
#
# Usage: status.sh [--repo <owner/name>] [--runner-dir <path>]

set -euo pipefail

LABEL="pierless.runner"
REPO_SLUG=""
RUNNER_DIR="${HOME:-$PWD}/.pierless/runner"

usage() {
  cat <<'USAGE'
usage: status.sh [--repo <owner/name>] [--runner-dir <path>]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "status.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

echo "== launchd =="
if PRINT_OUT="$(launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null)"; then
  echo "${PRINT_OUT}" | grep -E 'state|pid' || echo "loaded, but no state/pid line found"
else
  echo "${LABEL} is not loaded"
fi

echo "== GitHub =="
if [ -z "${REPO_SLUG}" ] && [ -f "${RUNNER_DIR}/.runner" ]; then
  REPO_SLUG="$(sed -n 's#.*"gitHubUrl": *"https://github.com/\([^"]*\)".*#\1#p' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
fi
if [ -n "${REPO_SLUG}" ]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "repos/${REPO_SLUG}/actions/runners" --jq '.runners[] | "\(.name): \(.status) (busy=\(.busy))"' 2>/dev/null || echo "could not read runner status from GitHub for ${REPO_SLUG}"
  else
    echo "gh not authenticated — skipping GitHub-side status"
  fi
else
  echo "no --repo given and no readable ${RUNNER_DIR}/.runner — skipping GitHub-side status"
fi

echo "== deploy log =="
LOG_PATH="${PIERLESS_LOG:-${RUNNER_DIR}/runner.log}"
if [ -f "${LOG_PATH}" ]; then
  tail -n 3 "${LOG_PATH}"
else
  echo "no log at ${LOG_PATH}"
fi

echo "== last refusal =="
DIAG_DIR="${RUNNER_DIR}/_diag"
if [ -d "${DIAG_DIR}" ]; then
  # A bash glob, not find | xargs: GNU xargs (the default on Linux) still
  # runs its command once on empty input unless told not to (BSD xargs on
  # macOS does not), which listed the current directory instead of
  # reporting no matches when _diag had no Runner_*.log files at all. The
  # Runner_*.log names are zero-padded UTC timestamps, so the lexically
  # last glob match (bash always expands a glob in sorted order) is the
  # newest one; an unmatched glob is skipped by the -f check below rather
  # than treated as a literal filename.
  NEWEST_DIAG=""
  for _diag_candidate in "${DIAG_DIR}"/Runner_*.log; do
    [ -f "${_diag_candidate}" ] && NEWEST_DIAG="${_diag_candidate}"
  done
  if [ -n "${NEWEST_DIAG}" ]; then
    grep 'pierless gate: refused' "${NEWEST_DIAG}" | tail -n 1 || echo "no refusal lines in ${NEWEST_DIAG}"
  else
    echo "no Runner_*.log files in ${DIAG_DIR}"
  fi
else
  echo "no diag dir at ${DIAG_DIR}"
fi
