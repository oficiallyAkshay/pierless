#!/usr/bin/env bash
# bin/install-runner.sh — idempotent installer for this Mac's GitHub
# Actions self-hosted runner.
#
# Steps: download the pinned actions/runner release (verify sha256, skip
# when already extracted at this version) → register with GitHub via a
# short-lived token from `gh api` → install the gate outside the checkout
# and point ACTIONS_RUNNER_HOOK_JOB_STARTED at that copy, so a merged
# branch can never edit the gate that is about to judge it → render and
# load the LaunchAgent → verify every piece actually took.
#
# UNSUPPORTED: hand-starting the runner (`cd <runner-dir> && ./run.sh`)
# outside launchd. <runner-dir>/.env — the only place
# ACTIONS_RUNNER_HOOK_JOB_STARTED is set on the launchd path — is read by
# the plist's command line, not by run.sh itself, so a hand-started runner
# picks up no hook and runs every job it is handed UNGATED.
#
# RESIDUAL: a refused job's `uses:` actions are still downloaded into
# <runner-dir>/_work/_actions before the gate ever runs — the runner
# prepares the job's action directory before invoking
# ACTIONS_RUNNER_HOOK_JOB_STARTED. Nothing from a refused job executes, but
# an attacker-chosen tarball still lands on disk as this user.
#
# The registration token is passed to config.sh as a CLI flag, config.sh's
# only input channel for it — briefly visible to `ps` on this host for the
# life of that one command (a short-lived token, not a long-lived secret).
#
# The version-change bootout only runs after the download's sha256 has
# verified, and only when the CURRENTLY INSTALLED plist's WorkingDirectory
# matches this run's --runner-dir. A prior version booted out the live
# LaunchAgent before the download was verified and regardless of which
# runner dir it pointed at, so a test run against a temp --runner-dir could
# still stop a real, unrelated runner on the same Mac.
#
# PIERLESS_TEST_RUNNER_VERSION / PIERLESS_TEST_RUNNER_SHA256 are TEST-ONLY
# overrides for RUNNER_VERSION / RUNNER_SHA256 below, so a test can exercise
# the download/verify/extract flow against a small fixture instead of the
# real multi-hundred-megabyte tarball. Never set them outside a test.
#
# PIERLESS_TEST_SKIP_PLATFORM_CHECK=1 is a TEST-ONLY override that skips
# the "refuse on non-arm64" check below entirely, so a test running on a
# non-arm64 host (e.g. Linux CI) can reach the download/verify step to
# exercise the sha256-mismatch refusal. Never set it outside a test.
#
# In --dry-run mode the non-arm64 refusal does not abort: it prints the
# whole plan and ends with one NOTE line saying this host would be
# refused, still exiting 0, so a dry run on any CI OS documents the full
# plan. A real (non-dry-run) run keeps refusing first, before anything
# else, and exits non-zero.
#
# Usage: install-runner.sh --repo <owner/name> [--runner-dir <path>]
#   [--name <name>] [--labels <csv>] [--workflow <file.yml>]
#   [--branch <name>] [--job <name>] [--path <PATH value>] [--dry-run]

set -euo pipefail

# Pinned actions/runner release. Bump both together; verify against
# https://github.com/actions/runner/releases (osx-arm64 sha256 lives in
# that release's notes). PIERLESS_TEST_RUNNER_VERSION /
# PIERLESS_TEST_RUNNER_SHA256 are test-only overrides — see header.
RUNNER_VERSION="${PIERLESS_TEST_RUNNER_VERSION:-2.337.0}"
RUNNER_SHA256="${PIERLESS_TEST_RUNNER_SHA256:-5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2}"

DRY_RUN=0
REPO_SLUG=""
RUNNER_DIR="${HOME:-$PWD}/.pierless/runner"
RUNNER_NAME="pierless-$(hostname -s 2>/dev/null || echo mac)"
LABELS="pierless"
WORKFLOW="deploy.yml"
BRANCH="main"
JOB="deploy"
BAKED_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
LABEL="pierless.runner"
INSTALLED_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SCRIPT="${SCRIPT_DIR}/job-started-gate.sh"
TEMPLATE="${SCRIPT_DIR}/../templates/launchd.plist.tmpl"

usage() {
  cat <<'USAGE'
usage: install-runner.sh --repo <owner/name> [--runner-dir <path>]
         [--name <name>] [--labels <csv>] [--workflow <file.yml>]
         [--branch <name>] [--job <name>] [--path <PATH value>] [--dry-run]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
    --name) RUNNER_NAME="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --job) JOB="$2"; shift 2 ;;
    --path) BAKED_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-runner.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
plan() { printf '[%s] [dry-run] %s\n' "$(ts)" "$*"; }

[ -n "${REPO_SLUG}" ] || { echo "install-runner.sh: refused — --repo is required" >&2; usage >&2; exit 1; }

if [ ! -x "${GATE_SCRIPT}" ]; then
  echo "install-runner.sh: expected gate script at ${GATE_SCRIPT} (not found or not executable)" >&2
  exit 1
fi

# All labels always also carry self-hosted and macOS, matching how GitHub
# routes jobs to this class of runner regardless of what --labels adds.
FULL_LABELS="self-hosted,macOS,${LABELS}"
ALLOWED_WORKFLOW_REF="${REPO_SLUG}/.github/workflows/${WORKFLOW}@refs/heads/${BRANCH}"
ALLOWED_REF="refs/heads/${BRANCH}"

PLATFORM_REFUSAL_REASON=""
if [ "${PIERLESS_TEST_SKIP_PLATFORM_CHECK:-0}" != "1" ]; then
  case "$(uname -m)" in
    arm64) ;;
    *)
      PLATFORM_REFUSAL_REASON="this Mac is not arm64 (uname -m = $(uname -m)); Intel Macs need a different runner asset (actions-runner-osx-x64), not the one pinned here"
      if [ "${DRY_RUN}" -eq 0 ]; then
        echo "install-runner.sh: refused — ${PLATFORM_REFUSAL_REASON}" >&2
        exit 1
      fi
      ;;
  esac
fi

# --- 1. Download the pinned release ---------------------------------------
ASSET_NAME="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ASSET_NAME}"
VERSION_MARKER="${RUNNER_DIR}/.runner-version"

log "pinned runner version: ${RUNNER_VERSION} (${ASSET_NAME})"

ALREADY_EXTRACTED=0
if [ -x "${RUNNER_DIR}/bin/Runner.Listener" ] && [ -f "${VERSION_MARKER}" ] \
  && [ "$(cat "${VERSION_MARKER}" 2>/dev/null || true)" = "${RUNNER_VERSION}" ]; then
  ALREADY_EXTRACTED=1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  if [ "${ALREADY_EXTRACTED}" -eq 1 ]; then
    plan "runner version ${RUNNER_VERSION} already extracted at ${RUNNER_DIR} — would skip download"
  else
    plan "would create ${RUNNER_DIR}, download ${ASSET_NAME}, verify sha256 ${RUNNER_SHA256}, and extract into ${RUNNER_DIR}"
  fi
else
  mkdir -p "${RUNNER_DIR}"
  if [ "${ALREADY_EXTRACTED}" -eq 1 ]; then
    log "runner version ${RUNNER_VERSION} already extracted at ${RUNNER_DIR} — skipping download"
  else
    TARBALL="${RUNNER_DIR}/${ASSET_NAME}"
    log "downloading ${DOWNLOAD_URL}"
    curl -fsSL -o "${TARBALL}" "${DOWNLOAD_URL}"
    ACTUAL_SHA="$(shasum -a 256 "${TARBALL}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
    if [ "${ACTUAL_SHA}" != "${RUNNER_SHA256}" ]; then
      rm -f "${TARBALL}"
      echo "install-runner.sh: refused — sha256 mismatch for ${ASSET_NAME} (expected ${RUNNER_SHA256}, got ${ACTUAL_SHA})" >&2
      exit 1
    fi
    log "sha256 verified for ${ASSET_NAME}"

    # Only stop the LIVE LaunchAgent once the download has verified, and
    # only when it is actually running THIS run's --runner-dir — otherwise
    # a run against an unrelated or temp --runner-dir (e.g. a test) would
    # stop a real, unrelated runner on the same Mac.
    if [ -f "${INSTALLED_PLIST}" ]; then
      INSTALLED_WORKING_DIR="$(plutil -extract WorkingDirectory raw -o - "${INSTALLED_PLIST}" 2>/dev/null || true)"
      if [ "${INSTALLED_WORKING_DIR}" = "${RUNNER_DIR}" ]; then
        if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
          log "version change — booting out ${LABEL} before extracting over it"
          launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
        fi
      else
        log "skipping bootout: installed runner dir is ${INSTALLED_WORKING_DIR:-<unset>}, this run targets ${RUNNER_DIR}"
      fi
    fi

    tar -xzf "${TARBALL}" -C "${RUNNER_DIR}"
    printf '%s' "${RUNNER_VERSION}" > "${VERSION_MARKER}"
    log "extracted runner ${RUNNER_VERSION} into ${RUNNER_DIR}"
  fi
fi

# --- 2. Register with GitHub ---------------------------------------------
CONFIG_ALREADY=0
[ -f "${RUNNER_DIR}/.runner" ] && CONFIG_ALREADY=1

if [ "${CONFIG_ALREADY}" -eq 1 ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    plan "${RUNNER_DIR}/.runner already exists — would skip registration"
  else
    log "${RUNNER_DIR}/.runner already exists — skipping registration"
  fi
else
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "install-runner.sh: refused — an authenticated 'gh' is required to request a registration token" >&2
    exit 1
  fi
  log "requesting a registration token for ${REPO_SLUG}..."
  CONFIG_CMD_DISPLAY="./config.sh --unattended --url https://github.com/${REPO_SLUG} --token ***REDACTED*** --name ${RUNNER_NAME} --labels ${FULL_LABELS} --replace --work _work"
  if [ "${DRY_RUN}" -eq 1 ]; then
    TOKEN="$(gh api -X POST "repos/${REPO_SLUG}/actions/runners/registration-token" --jq .token)"
    [ -n "${TOKEN}" ] || { echo "install-runner.sh: refused — empty registration token from GitHub" >&2; exit 1; }
    plan "would run (in ${RUNNER_DIR}): ${CONFIG_CMD_DISPLAY}"
  else
    TOKEN="$(gh api -X POST "repos/${REPO_SLUG}/actions/runners/registration-token" --jq .token)"
    [ -n "${TOKEN}" ] || { echo "install-runner.sh: refused — empty registration token from GitHub" >&2; exit 1; }
    log "running: ${CONFIG_CMD_DISPLAY}"
    (cd "${RUNNER_DIR}" && ./config.sh --unattended --url "https://github.com/${REPO_SLUG}" --token "${TOKEN}" --name "${RUNNER_NAME}" --labels "${FULL_LABELS}" --replace --work _work)
  fi
fi

# --- 3. Install the job-started hook OUTSIDE the checkout -----------------
HOOK_DEST="${RUNNER_DIR}/hooks/job-started-gate.sh"
ENV_FILE="${RUNNER_DIR}/.env"

if [ "${DRY_RUN}" -eq 1 ]; then
  plan "would install hook at ${HOOK_DEST} and write PIERLESS_ALLOWED_* + ACTIONS_RUNNER_HOOK_JOB_STARTED into ${ENV_FILE}"
else
  mkdir -p "${RUNNER_DIR}/hooks"
  cp "${GATE_SCRIPT}" "${HOOK_DEST}"
  chmod 0755 "${HOOK_DEST}"
  TMP_ENV="$(mktemp)"
  if [ -f "${ENV_FILE}" ]; then
    grep -vE '^(ACTIONS_RUNNER_HOOK_JOB_STARTED|PIERLESS_ALLOWED_WORKFLOW_REF|PIERLESS_ALLOWED_REPOSITORY|PIERLESS_ALLOWED_REF|PIERLESS_ALLOWED_JOB)=' "${ENV_FILE}" > "${TMP_ENV}" || true
  fi
  {
    printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "${HOOK_DEST}"
    printf 'PIERLESS_ALLOWED_WORKFLOW_REF=%s\n' "${ALLOWED_WORKFLOW_REF}"
    printf 'PIERLESS_ALLOWED_REPOSITORY=%s\n' "${REPO_SLUG}"
    printf 'PIERLESS_ALLOWED_REF=%s\n' "${ALLOWED_REF}"
    printf 'PIERLESS_ALLOWED_JOB=%s\n' "${JOB}"
  } >> "${TMP_ENV}"
  mv "${TMP_ENV}" "${ENV_FILE}"
  log "hook installed at ${HOOK_DEST}; ${ENV_FILE} updated"
fi

# --- 4. Render and load the LaunchAgent ------------------------------------
LOG_PATH="${RUNNER_DIR}/runner.log"

if [ "${DRY_RUN}" -eq 1 ]; then
  plan "would render ${TEMPLATE} to ${INSTALLED_PLIST}"
  plan "would run: launchctl bootout gui/\$(id -u)/${LABEL} (if loaded), then launchctl bootstrap gui/\$(id -u) ${INSTALLED_PLIST}"
  plan "would verify: plist exists, launchctl print gui/\$(id -u)/${LABEL} shows state = running, installed hook sha256 matches repo copy, plist and .env both name ${HOOK_DEST}"
  if [ -n "${PLATFORM_REFUSAL_REASON}" ]; then
    plan "install-runner.sh: dry run complete — NOTE: this host would be refused: ${PLATFORM_REFUSAL_REASON}"
  else
    plan "install-runner.sh: dry run complete — nothing created under ${RUNNER_DIR}"
  fi
  exit 0
fi

mkdir -p "$(dirname "${INSTALLED_PLIST}")"
sed \
  -e "s|@@LABEL@@|${LABEL}|g" \
  -e "s|@@RUNNER_DIR@@|${RUNNER_DIR}|g" \
  -e "s|@@HOOK@@|${HOOK_DEST}|g" \
  -e "s|@@ALLOWED_WORKFLOW_REF@@|${ALLOWED_WORKFLOW_REF}|g" \
  -e "s|@@ALLOWED_REPOSITORY@@|${REPO_SLUG}|g" \
  -e "s|@@ALLOWED_REF@@|${ALLOWED_REF}|g" \
  -e "s|@@ALLOWED_JOB@@|${JOB}|g" \
  -e "s|@@LOG@@|${LOG_PATH}|g" \
  -e "s|@@PATH@@|${BAKED_PATH}|g" \
  -e "s|@@HOME@@|${HOME}|g" \
  "${TEMPLATE}" > "${INSTALLED_PLIST}"
log "rendered plist to ${INSTALLED_PLIST}"

if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
fi
launchctl bootstrap "gui/$(id -u)" "${INSTALLED_PLIST}"
log "loaded LaunchAgent: ${LABEL}"

launchctl print "gui/$(id -u)/${LABEL}" | grep -E 'state|pid' || true

# --- 5. Verify the install actually took ----------------------------------
VERIFY_FAILURES=()

[ -f "${INSTALLED_PLIST}" ] || VERIFY_FAILURES+=("${INSTALLED_PLIST} does not exist")

if ! launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -q 'state = running'; then
  VERIFY_FAILURES+=("launchctl print gui/$(id -u)/${LABEL} does not show state = running")
fi

if [ -f "${INSTALLED_PLIST}" ]; then
  INSTALLED_HOOK_PATH="$(plutil -extract EnvironmentVariables.ACTIONS_RUNNER_HOOK_JOB_STARTED raw "${INSTALLED_PLIST}" 2>/dev/null || true)"
  if [ "${INSTALLED_HOOK_PATH}" != "${HOOK_DEST}" ]; then
    VERIFY_FAILURES+=("plist ACTIONS_RUNNER_HOOK_JOB_STARTED is '${INSTALLED_HOOK_PATH:-<unset>}', expected ${HOOK_DEST}")
  fi
fi

INSTALLED_HOOK_SHA="$(shasum -a 256 "${HOOK_DEST}" 2>/dev/null | awk '{print $1}')"
REPO_HOOK_SHA="$(shasum -a 256 "${GATE_SCRIPT}" | awk '{print $1}')"
if [ "${INSTALLED_HOOK_SHA:-}" != "${REPO_HOOK_SHA}" ]; then
  VERIFY_FAILURES+=("installed hook sha256 (${INSTALLED_HOOK_SHA:-<missing>}) does not match repo copy (${REPO_HOOK_SHA})")
fi

if ! grep -q "^ACTIONS_RUNNER_HOOK_JOB_STARTED=${HOOK_DEST}$" "${ENV_FILE}" 2>/dev/null; then
  VERIFY_FAILURES+=("${ENV_FILE} does not carry ACTIONS_RUNNER_HOOK_JOB_STARTED=${HOOK_DEST}")
fi

if [ "${#VERIFY_FAILURES[@]}" -gt 0 ]; then
  echo "install-runner.sh: verify FAILED:" >&2
  for f in "${VERIFY_FAILURES[@]}"; do
    echo "  - ${f}" >&2
  done
  exit 1
fi

log "verified: ${LABEL} running, hook sha256 matches repo, plist and .env both point at ${HOOK_DEST}"
