#!/bin/bash
# on_failure / on_recovery command for pierless's action.yml. Pushes one
# notification to an ntfy.sh topic (or a self-hosted ntfy server). Needs
# NTFY_TOPIC_URL (e.g. https://ntfy.sh/your-topic) in the environment.
set -uo pipefail
if [ -z "${NTFY_TOPIC_URL:-}" ]; then
  echo "on-failure-ntfy: NTFY_TOPIC_URL not set, skipping" >&2
  exit 0
fi
if [ "${PIERLESS_EXIT_CODE:-1}" = "0" ]; then
  title="Deploy recovered"
  body="${PIERLESS_RUN_URL:-unknown run}"
  priority="default"
else
  title="Deploy failed (exit ${PIERLESS_EXIT_CODE:-?})"
  body="${PIERLESS_REASON:-see the run log} — ${PIERLESS_RUN_URL:-unknown run}"
  priority="high"
fi
curl -fsS -H "Title: ${title}" -H "Priority: ${priority}" \
  -d "${body}" "${NTFY_TOPIC_URL}" >/dev/null
