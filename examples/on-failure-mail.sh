#!/bin/bash
# on_failure / on_recovery command for pierless's action.yml. Sends one
# email via the box's own `mail` (or `mailx`) command. Needs MAIL_TO set;
# mail delivery itself is whatever this Mac already has configured
# (sendmail, postfix, an SMTP relay) — pierless does not set that up.
set -uo pipefail
if [ -z "${MAIL_TO:-}" ]; then
  echo "on-failure-mail: MAIL_TO not set, skipping" >&2
  exit 0
fi
if [ "${PIERLESS_EXIT_CODE:-1}" = "0" ]; then
  subject="Deploy recovered"
  body="${PIERLESS_RUN_URL:-unknown run}"
else
  subject="Deploy failed (exit ${PIERLESS_EXIT_CODE:-?})"
  body="${PIERLESS_REASON:-see the run log}
${PIERLESS_RUN_URL:-unknown run}"
fi
printf '%s\n' "${body}" | mail -s "${subject}" "${MAIL_TO}"
