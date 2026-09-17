#!/usr/bin/env bash
# scripts/release/stage.sh <version> — put the repo's bin/ and templates/
# inside both package trees and stamp <version> into both manifests.
#
# The packages hold no source of their own: they carry a copy of the
# scripts the tests just ran against, so the only way a published package
# can differ from the tested tree is a stage that never happened. The
# copies are git-ignored and re-made from scratch on every run, which is
# why this deletes before it copies — a script deleted from bin/ must not
# survive inside a package from an earlier stage.
#
# Runs on a stock runner: sed and cp only, no jq, no npm, no python3.

set -euo pipefail

VERSION="${1:-}"

if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "stage.sh: version must be X.Y.Z (no leading v, no suffix), got '${VERSION}'" >&2
  exit 64
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

NPM_DIR="${ROOT}/packages/npm"
PYPI_DIR="${ROOT}/packages/pypi/src/pierless"

for dest in "${NPM_DIR}" "${PYPI_DIR}"; do
  for sub in bin templates; do
    rm -rf "${dest:?}/${sub}"
    mkdir -p "${dest}/${sub}"
    cp -R "${ROOT}/${sub}/." "${dest}/${sub}/"
  done
done

# Both stamps rewrite one anchored line each, so a version string that
# also appears in a description, a URL or a dependency is never touched.
stamp() {
  local file="$1" expr="$2" tmp
  tmp="${file}.stage.tmp"
  sed -e "${expr}" "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

stamp "${NPM_DIR}/package.json" 's|^\(  "version": "\)[^"]*\(",\)$|\1'"${VERSION}"'\2|'
stamp "${ROOT}/packages/pypi/pyproject.toml" 's|^version = "[^"]*"$|version = "'"${VERSION}"'"|'

# A sed that matched nothing leaves a 0.0.0 package looking staged, so the
# stamp is read back rather than assumed.
grep -q "\"version\": \"${VERSION}\"" "${NPM_DIR}/package.json" \
  || { echo "stage.sh: package.json has no version line to stamp" >&2; exit 1; }
grep -q "^version = \"${VERSION}\"$" "${ROOT}/packages/pypi/pyproject.toml" \
  || { echo "stage.sh: pyproject.toml has no version line to stamp" >&2; exit 1; }

echo "stage.sh: staged bin/ and templates/ into both packages at ${VERSION}"
