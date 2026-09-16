#!/bin/bash
# bin/deploy.sh — fast-forward PIERLESS_REPO from its origin remote, run the
# configured hooks, exit non-zero on anything that needs a human. Safe to run
# by hand, from cron, or from the pierless GitHub Action; idempotent, and
# never rewrites history — refuse, never force.
#
# Env (all PIERLESS_*; everything optional except REPO):
#   PIERLESS_REPO            required. Path to the git checkout to deploy.
#   PIERLESS_BRANCH          default main. Branch to track and fast-forward to.
#   PIERLESS_LOG             default $HOME/.pierless/deploy.log
#   PIERLESS_LOCK_DIR        default $HOME/.pierless/lock
#   PIERLESS_STATE_DIR       default $HOME/.pierless. Holds last-hooked-sha,
#                             the SHA whose hooks + prune last finished (see
#                             "Hook idempotency" below).
#   PIERLESS_INSTALL         newline "glob=command" pairs; command runs in the
#                             directory of each changed file whose basename
#                             matches glob. Default: package.json and
#                             package-lock.json => npm install --no-audit
#                             --no-fund. Literal "none" disables.
#   PIERLESS_SERVICES_DIR    repo-relative folder of launchd plists; unset
#                             skips daemon load/unload entirely. Before a
#                             plist is bootstrapped its StandardOutPath and
#                             StandardErrorPath directories are created.
#   PIERLESS_KICK            space-separated launchd labels to kickstart -k
#                             after any pull that moved HEAD; unset skips.
#   PIERLESS_PRUNE_WORKTREES true (default) or false.
#   PIERLESS_SELF_LABEL      default pierless.runner. A plist named for this
#                             label is never loaded/unloaded from in here.
#   PIERLESS_ON_PARK         command run once, after a deploy that parked
#                             edits and then actually fast-forwarded. Gets
#                             PIERLESS_PARKED_FILES (newline list),
#                             PIERLESS_STASH_NAME, and PIERLESS_RUN_URL
#                             (copied from this script's own env if set,
#                             else empty). Unset means no command.
#   PIERLESS_RUN_URL         optional; not used directly, only forwarded to
#                             PIERLESS_ON_PARK when it runs.
#   PIERLESS_TRIGGER         default manual. Logged only.
#   PIERLESS_STDOUT          "1" mirrors every log line to stdout too.
#   PIERLESS_DEBUG           "1" logs every decision, one line each.
#
# GITHUB_OUTPUT (when set) gets: deployed=true|false, commits=N.
#
# Exit codes: 0 up to date or deployed clean; 2 a hook failed (every other
# hook and the prune still ran first); 3 lock held by a live owner past
# 600s; 4 refused — diverged, a fast-forward that should have worked
# didn't (parked edits, if any, are popped straight back first), or the
# stash push itself failed; 5 fetch failed; 64 bad configuration.
#
# Safety: never force-pushes or resets. The working tree is left alone
# until we already know a fast-forward is about to happen — up to date,
# diverged, and a failed fetch never touch it. Only then, if the tree is
# dirty, is it stashed (never re-applied by this script — recover it
# yourself with the git stash command) — unless that fast-forward then
# fails, in which case the stash is popped straight back and nothing was
# deployed.
#
# Hook idempotency: the SHA whose hooks (install/services) and prune last
# finished running is kept at PIERLESS_STATE_DIR/last-hooked-sha, written
# only once they all finish. When that marker is present and does not
# match current HEAD — even on a run that pulls nothing new — hooks run
# again for <marker>..HEAD instead of being skipped, so a crash between a
# fast-forward and its hooks finishing is caught up next run rather than
# silently skipped forever.

set -uo pipefail

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# --- Configuration ---------------------------------------------------------
REPO="${PIERLESS_REPO:-}"
if [ -z "${REPO}" ]; then
  echo "[$(ts)] PIERLESS_REPO is not set — refusing to guess a checkout" >&2
  exit 64
fi
if ! git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[$(ts)] PIERLESS_REPO=${REPO} is not a git checkout" >&2
  exit 64
fi

LOG="${PIERLESS_LOG:-${HOME}/.pierless/deploy.log}"
mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true

log() {
  local line
  line="[$(ts)] $*"
  echo "${line}" >> "${LOG}"
  [ "${PIERLESS_STDOUT:-}" = "1" ] && echo "${line}"
  return 0
}

debug() {
  [ "${PIERLESS_DEBUG:-}" = "1" ] && log "debug: $*"
  return 0
}

PIERLESS_TRIGGER="${PIERLESS_TRIGGER:-manual}"
log "trigger=${PIERLESS_TRIGGER} repo=${REPO}"

LOCK_DIR="${PIERLESS_LOCK_DIR:-${HOME}/.pierless/lock}"
PIERLESS_SELF_LABEL="${PIERLESS_SELF_LABEL:-pierless.runner}"
PIERLESS_PRUNE_WORKTREES="${PIERLESS_PRUNE_WORKTREES:-true}"
BRANCH="${PIERLESS_BRANCH:-main}"

PIERLESS_STATE_DIR="${PIERLESS_STATE_DIR:-${HOME}/.pierless}"
HOOK_MARKER_FILE="${PIERLESS_STATE_DIR}/last-hooked-sha"
LAST_HOOKED_SHA=""
if [ -f "${HOOK_MARKER_FILE}" ]; then
  LAST_HOOKED_SHA="$(tr -d '[:space:]' < "${HOOK_MARKER_FILE}" 2>/dev/null || true)"
fi

write_output() {
  local deployed="$1" commits="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "deployed=${deployed}"
      echo "commits=${commits}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

# --- Hook + prune helpers ---------------------------------------------
# Defined ahead of the lock/fetch/compare flow below because both the
# "up to date but hooks never finished" path and the normal "behind, pull
# it" path call into these.

HOOK_FAILED=0

# write_marker SHA — records the SHA whose hooks + prune just finished,
# via a temp-file-then-rename so a crash mid-write never leaves a
# half-written marker that would be read back as a valid (wrong) SHA.
write_marker() {
  local sha="$1"
  mkdir -p "${PIERLESS_STATE_DIR}" 2>/dev/null || true
  if printf '%s\n' "${sha}" > "${HOOK_MARKER_FILE}.tmp" 2>/dev/null \
     && mv -f "${HOOK_MARKER_FILE}.tmp" "${HOOK_MARKER_FILE}" 2>/dev/null; then
    debug "hook marker: recorded ${sha}"
  else
    log "hook marker: failed to write ${HOOK_MARKER_FILE}"
  fi
}

run_install_hooks() {
  local pre="$1" changed="$2"
  local spec="${PIERLESS_INSTALL:-}"
  if [ -z "${spec}" ]; then
    spec="package.json=npm install --no-audit --no-fund
package-lock.json=npm install --no-audit --no-fund"
  fi
  if [ "${spec}" = "none" ]; then
    debug "PIERLESS_INSTALL=none, skipping install hooks"
    return
  fi

  local combos=""
  local line glob command bname dir
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    glob="${line%%=*}"
    command="${line#*=}"
    [ -z "${glob}" ] && continue
    while IFS= read -r f; do
      [ -z "${f}" ] && continue
      bname="$(basename "${f}")"
      case "${bname}" in
        ${glob}) ;;
        *) continue ;;
      esac
      dir="$(dirname "${f}")"
      combos="${combos}${dir}"$'\t'"${command}"$'\n'
    done <<< "${changed}"
  done <<< "${spec}"

  [ -z "${combos}" ] && return

  local seen_combo target
  seen_combo="$(printf '%s' "${combos}" | sort -u)"
  while IFS=$'\t' read -r dir command; do
    [ -z "${dir}" ] && continue
    target="${REPO}/${dir}"
    target="${target%/.}"
    if [ ! -d "${target}" ]; then
      log "hook: skip install — ${target} is not a directory"
      continue
    fi
    log "hook: install in ${target}: ${command}"
    if ! (cd "${target}" && eval "${command}" >> "${LOG}" 2>&1); then
      log "hook: install FAILED in ${target}"
      HOOK_FAILED=1
    fi
  done <<< "${seen_combo}"
}

# extract_plist_value PLIST KEY — prints the string value of KEY inside
# PLIST. plutil (present on every macOS this targets) does the real
# extraction; a plain grep of the <string> line right after the <key>
# line covers a box or CI runner without plutil on PATH, or a plist
# fragment plutil can't parse as a whole document.
extract_plist_value() {
  local plist="$1" key="$2" val=""
  # Trust plutil only when it exits 0. On macOS 14 a missing key or an
  # unparseable file prints the error text on STDOUT, exactly where the
  # value would go, so "non-empty output" is not "a value" — only the
  # exit status says whether the text is one.
  if command -v plutil >/dev/null 2>&1; then
    if ! val="$(plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null)"; then
      val=""
    fi
  fi
  if [ -z "${val}" ]; then
    val="$(grep -A1 "<key>${key}</key>" "${plist}" 2>/dev/null \
      | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' \
      | head -n1)"
  fi
  printf '%s' "${val}"
}

# ensure_plist_log_dirs PLIST — creates the parent directories of a
# plist's StandardOutPath/StandardErrorPath before it is bootstrapped, so
# launchd doesn't silently drop a daemon's first output because the
# directory never existed.
ensure_plist_log_dirs() {
  local plist="$1" key val
  for key in StandardOutPath StandardErrorPath; do
    val="$(extract_plist_value "${plist}" "${key}")"
    if [ -n "${val}" ]; then
      mkdir -p "$(dirname "${val}")" 2>/dev/null || true
    fi
  done
}

run_service_hooks() {
  local pre="$1"
  local dir="${PIERLESS_SERVICES_DIR:-}"
  if [ -z "${dir}" ]; then
    debug "PIERLESS_SERVICES_DIR unset, skipping daemon load/unload"
    return
  fi

  local dir_escaped
  dir_escaped=$(printf '%s' "${dir}" | sed 's/[.[\*^$/]/\\&/g')
  local plist_changes
  plist_changes=$(git diff --name-only --no-renames "${pre}" HEAD 2>>"${LOG}" \
    | grep -E "^${dir_escaped}/[^/]+\\.plist\$" || true)
  [ -z "${plist_changes}" ] && { debug "no plist changes under ${dir}"; return; }

  log "hook: plist changes: $(echo "${plist_changes}" | tr '\n' ' ')"
  local target_dir="${HOME}/Library/LaunchAgents"
  mkdir -p "${target_dir}" 2>/dev/null || true

  local fname label uid src
  uid="$(id -u)"
  while IFS= read -r plist_path; do
    [ -z "${plist_path}" ] && continue
    fname="$(basename "${plist_path}")"
    label="${fname%.plist}"
    if [ "${label}" = "${PIERLESS_SELF_LABEL}" ]; then
      log "hook: ${fname} changed — the runner's own definition is never reloaded from inside a deploy; reload it by hand"
      continue
    fi
    src="${REPO}/${plist_path}"
    if [ -f "${src}" ]; then
      log "hook: loading ${fname}"
      launchctl bootout "gui/${uid}/${label}" >> "${LOG}" 2>&1 || true
      ensure_plist_log_dirs "${src}"
      cp "${src}" "${target_dir}/${fname}"
      if ! launchctl bootstrap "gui/${uid}" "${target_dir}/${fname}" >> "${LOG}" 2>&1; then
        log "hook: launchctl bootstrap FAILED for ${label}"
        HOOK_FAILED=1
      fi
    else
      log "hook: ${fname} gone (removed or renamed to .disabled) — unloading ${label}"
      launchctl bootout "gui/${uid}/${label}" >> "${LOG}" 2>&1 || true
      rm -f "${target_dir}/${fname}"
    fi
  done <<< "${plist_changes}"
}

run_kick() {
  local labels="${PIERLESS_KICK:-}"
  [ -z "${labels}" ] && { debug "PIERLESS_KICK unset, skipping kickstart"; return; }
  local uid label
  uid="$(id -u)"
  for label in ${labels}; do
    log "hook: kickstart -k ${label}"
    if ! launchctl kickstart -k "gui/${uid}/${label}" >> "${LOG}" 2>&1; then
      log "hook: kickstart FAILED for ${label}"
      HOOK_FAILED=1
    fi
  done
}

prune_worktrees() {
  if [ "${PIERLESS_PRUNE_WORKTREES}" != "true" ]; then
    debug "PIERLESS_PRUNE_WORKTREES=${PIERLESS_PRUNE_WORKTREES}, skipping prune"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    log "worktree prune SKIPPED — gh not on PATH, cannot confirm a branch's PR merged"
    return
  fi
  local pruned=0 skipped=0
  local wt br wt_base lock_file merged_pr
  while IFS= read -r line; do
    case "${line}" in
      worktree*) wt="${line#worktree }" ;;
      branch*)
        br="${line#branch refs/heads/}"
        if [ "${wt}" = "${REPO}" ] || [ "${br}" = "${BRANCH}" ]; then
          wt=""; br=""; continue
        fi
        if ! git -C "${REPO}" rev-parse --verify --quiet "refs/remotes/origin/${br}" >/dev/null 2>&1; then
          wt_base=$(basename "${wt}")
          lock_file="${REPO}/.git/worktrees/${wt_base}/locked"
          if [ -f "${lock_file}" ]; then
            log "worktree SKIP ${wt} (${br}) — locked by an active session"
            skipped=$((skipped + 1))
          elif [ -d "${wt}" ] && (cd "${wt}" && [ -z "$(git status --porcelain 2>/dev/null)" ]); then
            merged_pr=$(gh pr list --head "${br}" --state merged --json number --jq '.[0].number // empty' 2>>"${LOG}")
            if [ -z "${merged_pr}" ]; then
              log "worktree SKIP ${wt} (${br}) — clean but no merged PR found, keeping"
              skipped=$((skipped + 1))
            elif git -C "${REPO}" worktree remove "${wt}" >> "${LOG}" 2>&1 \
               && git -C "${REPO}" branch -D "${br}" >> "${LOG}" 2>&1; then
              log "worktree PRUNED ${wt} (${br}, merged PR #${merged_pr})"
              pruned=$((pruned + 1))
            else
              log "worktree PRUNE FAILED ${wt} (${br})"
              skipped=$((skipped + 1))
            fi
          else
            log "worktree SKIP ${wt} (${br}) — dirty or missing"
            skipped=$((skipped + 1))
          fi
        fi
        wt=""; br=""
        ;;
    esac
  done < <(git -C "${REPO}" worktree list --porcelain)
  [ "${pruned}" -gt 0 ] || [ "${skipped}" -gt 0 ] && log "worktree cleanup: pruned=${pruned} skipped=${skipped}"
  return 0
}

# --- Cross-process lock ----------------------------------------------------
# mkdir is atomic even across processes, so its success/failure IS the lock.
# A held lock survives a SIGKILL or power loss with nothing left to release
# it, so a pid is written on acquisition: while waiting, a lock whose owner
# pid no longer exists (or whose dir predates any pid file by more than the
# 600s cap when no pid file was ever written) is stale, removed, and retried
# immediately rather than counted against the wait budget. A LIVE owner
# still makes us wait out the full 600s cap before we give up.
LOCK_PID_FILE="${LOCK_DIR}/pid"
LOCK_ACQUIRED=0
LOCK_WAITED=0
until mkdir "${LOCK_DIR}" 2>/dev/null; do
  if [ -f "${LOCK_PID_FILE}" ]; then
    owner_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
    if [ -n "${owner_pid}" ] && ! kill -0 "${owner_pid}" 2>/dev/null; then
      log "stale lock from pid ${owner_pid} removed"
      rm -rf "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi
  elif [ -e "${LOCK_DIR}" ]; then
    # GNU stat first: on Linux `stat -f %m` is the filesystem's mount point,
    # not an mtime, and BSD stat rejects -c, so each form fails cleanly on the
    # other platform. A non-numeric answer is treated as unknown, never aged.
    lock_mtime="$(stat -c %Y "${LOCK_DIR}" 2>/dev/null || stat -f %m "${LOCK_DIR}" 2>/dev/null || echo "")"
    case "${lock_mtime}" in *[!0-9]*|"") lock_mtime="" ;; esac
    if [ -n "${lock_mtime}" ] && [ $(( $(date +%s) - lock_mtime )) -ge 600 ]; then
      log "stale lock with no pid file removed"
      rm -rf "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi
  fi
  if [ "${LOCK_WAITED}" -ge 600 ]; then
    log "another deploy has held the lock for 10 minutes — refusing"
    exit 3
  fi
  sleep 5
  LOCK_WAITED=$((LOCK_WAITED + 5))
done
LOCK_ACQUIRED=1
echo "$$" > "${LOCK_PID_FILE}"
[ "${LOCK_WAITED}" -gt 0 ] && log "lock waited ${LOCK_WAITED}s"
debug "lock acquired at ${LOCK_DIR}"

release_lock() {
  if [ "${LOCK_ACQUIRED:-0}" -eq 1 ]; then
    rm -rf "${LOCK_DIR}" 2>/dev/null || true
  fi
}
trap release_lock EXIT

cd "${REPO}" || { log "FATAL: cannot cd to ${REPO}"; exit 64; }

# --- Fetch -------------------------------------------------------------
# Nothing above this point touches the working tree, and nothing below it
# does either until we know — from the compare, right after this — that a
# fast-forward is actually about to happen.
if ! git fetch --prune origin --quiet 2>> "${LOG}"; then
  log "FETCH FAILED: git fetch --prune origin"
  write_output false 0
  exit 5
fi
debug "fetch --prune origin OK"

# --- Self-heal: checkout stranded on a squash-merged branch -----------
# A worktree left on a feature branch whose PR has since squash-merged has
# no origin/<branch> ref left (branch deleted on merge) and a HEAD that has
# diverged from origin/${BRANCH} — ff-only would refuse forever.
CURRENT_BRANCH=$(git symbolic-ref --short -q HEAD || echo "")
if [ -n "${CURRENT_BRANCH}" ] && [ "${CURRENT_BRANCH}" != "${BRANCH}" ]; then
  if ! git rev-parse --verify --quiet "refs/remotes/origin/${CURRENT_BRANCH}" >/dev/null 2>&1; then
    log "SELF-HEAL: HEAD on ${CURRENT_BRANCH} (origin ref gone, likely squash-merged) — switching to ${BRANCH}"
    if git checkout "${BRANCH}" >> "${LOG}" 2>&1; then
      if git branch -D "${CURRENT_BRANCH}" >> "${LOG}" 2>&1; then
        log "SELF-HEAL: deleted stale local branch ${CURRENT_BRANCH}"
      else
        log "SELF-HEAL: kept stale local branch ${CURRENT_BRANCH} (delete failed, non-fatal)"
      fi
    else
      log "SELF-HEAL FAILED: could not checkout ${BRANCH} from ${CURRENT_BRANCH}"
      write_output false 0
      exit 4
    fi
  fi
fi

# --- Compare: decide BEFORE touching anything whether a pull is needed -
BEHIND=$(git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null || echo "?")
AHEAD=$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo "?")
debug "behind=${BEHIND} ahead=${AHEAD}"
CURRENT_SHA=$(git rev-parse HEAD)

if [ "${BEHIND}" = "0" ] && [ "${AHEAD}" = "0" ]; then
  # Up to date: no fast-forward, so the working tree is never touched.
  # But a prior run may have crashed after pulling and before its hooks
  # (or prune) finished — the marker still names that older SHA, so catch
  # those hooks up now even though there is nothing new to pull.
  RESUME_PRE=""
  if [ -n "${LAST_HOOKED_SHA}" ] && [ "${LAST_HOOKED_SHA}" != "${CURRENT_SHA}" ] \
     && git rev-parse --verify --quiet "${LAST_HOOKED_SHA}" >/dev/null 2>&1; then
    RESUME_PRE="${LAST_HOOKED_SHA}"
  fi
  if [ -z "${RESUME_PRE}" ]; then
    log "up to date, nothing to deploy"
    write_output false 0
    exit 0
  fi
  log "up to date, nothing new to pull — hooks never finished last time"
  log "hooks: resuming from ${RESUME_PRE}"
  CHANGED=$(git diff --name-only "${RESUME_PRE}" HEAD 2>>"${LOG}")
  run_install_hooks "${RESUME_PRE}" "${CHANGED}"
  run_service_hooks "${RESUME_PRE}"
  prune_worktrees
  write_marker "${CURRENT_SHA}"
  if [ "${HOOK_FAILED}" -eq 1 ]; then
    log "EXIT 2: a hook failed — see FAILED lines above (every remaining hook and the prune still ran)"
    write_output false 0
    exit 2
  fi
  write_output false 0
  exit 0
fi

if [ "${BEHIND}" = "0" ] && [ "${AHEAD}" != "0" ]; then
  log "AHEAD ${AHEAD} (local has un-pushed commits — not pulling)"
  write_output false 0
  exit 0
fi

if [ "${AHEAD}" != "0" ]; then
  log "DIVERGED: ahead ${AHEAD}, behind ${BEHIND} of origin/${BRANCH} — fast-forward refused, needs a hand"
  write_output false 0
  exit 4
fi

# --- Behind only: a fast-forward is happening. Park a dirty tree now, --
# --- never before this point. --------------------------------------
PRE_MERGE_SHA="${CURRENT_SHA}"
PARKED_COUNT=0
PARKED_FILES=""
STASH_MSG=""
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  PARKED_FILES="$(git status --porcelain 2>/dev/null | cut -c4-)"
  PARKED_COUNT=$(printf '%s\n' "${PARKED_FILES}" | grep -c .)
  STASH_MSG="pierless park $(ts)"
  if git stash push --include-untracked -m "${STASH_MSG}" >> "${LOG}" 2>&1; then
    debug "parked ${PARKED_COUNT} file(s) ahead of the fast-forward — stash=\"${STASH_MSG}\""
  else
    log "PARK FAILED: git stash push failed — deploy blocked, needs a hand on the box"
    write_output false 0
    exit 4
  fi
else
  debug "working tree clean, nothing to park"
fi

if git merge --ff-only "origin/${BRANCH}" >> "${LOG}" 2>&1; then
  log "PULLED ${BEHIND} commit(s)"
  NEW_HEAD=$(git rev-parse HEAD)

  HOOK_RANGE_PRE="${PRE_MERGE_SHA}"
  if [ -n "${LAST_HOOKED_SHA}" ] && [ "${LAST_HOOKED_SHA}" != "${NEW_HEAD}" ] \
     && git rev-parse --verify --quiet "${LAST_HOOKED_SHA}" >/dev/null 2>&1; then
    HOOK_RANGE_PRE="${LAST_HOOKED_SHA}"
    log "hooks: resuming from ${LAST_HOOKED_SHA}"
  fi

  CHANGED=$(git diff --name-only "${HOOK_RANGE_PRE}" HEAD 2>>"${LOG}")
  run_install_hooks "${HOOK_RANGE_PRE}" "${CHANGED}"
  run_service_hooks "${HOOK_RANGE_PRE}"
  run_kick
  prune_worktrees
  write_marker "${NEW_HEAD}"

  if [ "${PARKED_COUNT}" -gt 0 ]; then
    names_joined="$(printf '%s' "${PARKED_FILES}" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
    log "PARKED ${PARKED_COUNT} file(s): ${names_joined} — stash=\"${STASH_MSG}\" (left in the stash; this script never restores it)"
    if [ -n "${PIERLESS_ON_PARK:-}" ]; then
      log "hook: running PIERLESS_ON_PARK"
      if ! ( export PIERLESS_PARKED_FILES="${PARKED_FILES}"
             export PIERLESS_STASH_NAME="${STASH_MSG}"
             export PIERLESS_RUN_URL="${PIERLESS_RUN_URL:-}"
             eval "${PIERLESS_ON_PARK}" ) >> "${LOG}" 2>&1; then
        log "hook: PIERLESS_ON_PARK command failed (non-fatal)"
      fi
    fi
  fi

  if [ "${HOOK_FAILED}" -eq 1 ]; then
    log "EXIT 2: a hook failed — see FAILED lines above (every remaining hook and the prune still ran)"
    write_output true "${BEHIND}"
    exit 2
  fi
  write_output true "${BEHIND}"
  exit 0
else
  log "MERGE FAILED despite behind-only check — fast-forward should have worked"
  if [ "${PARKED_COUNT}" -gt 0 ]; then
    if git stash pop >> "${LOG}" 2>&1; then
      log "RESTORED parked edits — no deploy happened"
    else
      log "RESTORE FAILED: git stash pop failed — parked edits remain in stash=\"${STASH_MSG}\", needs a hand on the box"
    fi
  fi
  write_output false 0
  exit 4
fi
