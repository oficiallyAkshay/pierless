#!/usr/bin/env bash
# scripts/release/check-pin.sh <version> [action-file] — the version the
# composite action pins and the tag being released must be the same string.
#
# The action runs a published version of pierless, so a tag pushed while
# action.yml still names the previous one would ship a release whose
# action keeps deploying the code before it. This runs before anything is
# published, so the fix is a commit and a new tag, not a yanked release.

set -euo pipefail

VERSION="${1:-}"
ACTION_FILE="${2:-action.yml}"

[ -n "${VERSION}" ] || {
  echo "check-pin.sh: usage: check-pin.sh <version> [action-file]" >&2
  exit 64
}
[ -f "${ACTION_FILE}" ] || {
  echo "check-pin.sh: no such file: ${ACTION_FILE}" >&2
  exit 64
}

PINNED="$(sed -n 's|^[[:space:]]*PIERLESS_VERSION:[[:space:]]*"\([^"]*\)".*$|\1|p' "${ACTION_FILE}" | head -n 1)"

if [ -z "${PINNED}" ]; then
  echo "check-pin.sh: ${ACTION_FILE} carries no PIERLESS_VERSION: \"X.Y.Z\" line — add it, merge it, then tag ${VERSION}" >&2
  exit 1
fi

if [ "${PINNED}" != "${VERSION}" ]; then
  echo "check-pin.sh: ${ACTION_FILE} pins PIERLESS_VERSION ${PINNED}, but the tag being released is ${VERSION}" >&2
  exit 1
fi

echo "check-pin.sh: ${ACTION_FILE} pins PIERLESS_VERSION ${PINNED}"
