#!/usr/bin/env bash
# scripts/ci/trace.sh — sourced via BASH_ENV by every non-interactive bash
# the test run starts. This IS how coverage is measured: each bash process
# appends its own trace lines to one shared file, and
# scripts/ci/coverage-check.py turns "+trace:<path>:<lineno>:" lines back
# into per-file executed-line sets. No container, no kcov.

[ -n "${PIERLESS_TRACE_FILE:-}" ] || return 0
[ -z "${_PIERLESS_TRACED:-}" ] || return 0
_PIERLESS_TRACED=1

# {fd}>>/BASH_XTRACEFD need bash 4.1+; macOS's bash 3.2 has neither, so
# a DEBUG trap there writes the same line shape straight to a fixed fd.
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
  exec {fd}>>"$PIERLESS_TRACE_FILE"
  BASH_XTRACEFD=$fd
  PS4='+trace:${BASH_SOURCE}:${LINENO}:'
  set -x
else
  exec 9>>"$PIERLESS_TRACE_FILE"
  set -o functrace
  trap 'printf "+trace:%s:%s:\n" "$BASH_SOURCE" "$LINENO" >&9' DEBUG
fi
