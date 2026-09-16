#!/usr/bin/env bash
# bin/uninstall-runner.sh — stop and deregister this Mac's runner.
#
# Boots the LaunchAgent out, removes the registration from GitHub with a
# short-lived removal token, and deletes the plist. The runner directory
# itself (binary, work dir, hooks, .env) is left in place unless --purge is
# given — undoing a registration should not silently delete a checkout's
# worth of state.
#
# Usage: uninstall-runner.sh --repo <owner/name> [--runner-dir <path>] [--purge]

set -euo pipefail

LABEL="pierless.runner"
REPO_SLUG=""
RUNNER_DIR="${HOME:-$PWD}/.pierless/runner"
PURGE=0

usage() {
  cat <<'USAGE'
usage: uninstall-runner.sh --repo <owner/name> [--runner-dir <path>] [--purge]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "uninstall-runner.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "${REPO_SLUG}" ] || { echo "uninstall-runner.sh: refused — --repo is required" >&2; usage >&2; exit 1; }

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }

INSTALLED_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}"
  log "booted out ${LABEL}"
else
  log "${LABEL} was not loaded"
fi

if [ -f "${RUNNER_DIR}/.runner" ]; then
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "uninstall-runner.sh: refused — an authenticated 'gh' is required to request a removal token" >&2
    exit 1
  fi
  log "requesting a removal token for ${REPO_SLUG}..."
  TOKEN="$(gh api -X POST "repos/${REPO_SLUG}/actions/runners/remove-token" --jq .token)"
  [ -n "${TOKEN}" ] || { echo "uninstall-runner.sh: refused — empty removal token from GitHub" >&2; exit 1; }
  (cd "${RUNNER_DIR}" && ./config.sh remove --token "${TOKEN}")
  log "removed runner registration for ${REPO_SLUG}"
else
  log "${RUNNER_DIR}/.runner not found — nothing registered to remove"
fi

if [ -f "${INSTALLED_PLIST}" ]; then
  rm -f "${INSTALLED_PLIST}"
  log "deleted ${INSTALLED_PLIST}"
fi

if [ "${PURGE}" -eq 1 ]; then
  rm -rf "${RUNNER_DIR}"
  log "purged ${RUNNER_DIR}"
else
  log "left ${RUNNER_DIR} in place (pass --purge to delete it)"
fi
