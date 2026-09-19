#!/usr/bin/env bash
# tests/packages.test.sh — the npm and PyPI packages carry the same
# scripts the rest of this suite just tested, and both wrappers reach
# them.
#
# Staging writes into the real worktree rather than a copy, because what
# is under test is the layout the release workflow publishes: bin/ beside
# the wrapper and templates/ one level up from it, which is where
# install-runner.sh looks. The staged copies are git-ignored, and this
# file removes them again on the way out.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
STAGE="$REPO_ROOT/scripts/release/stage.sh"
CHECK_PIN="$REPO_ROOT/scripts/release/check-pin.sh"
NPM_DIR="$REPO_ROOT/packages/npm"
PYPI_PKG="$REPO_ROOT/packages/pypi/src/pierless"
require_script "$STAGE"
require_script "$CHECK_PIN"

VERSION="1.2.3"
PYPROJECT="$REPO_ROOT/packages/pypi/pyproject.toml"

# The two manifests are tracked files and stage.sh stamps a version into
# them, so running the suite must not leave the worktree modified: both
# are copied aside here and put back byte for byte at the end.
manifest_backup="$(new_tmpdir)"
cp "$NPM_DIR/package.json" "$manifest_backup/package.json"
cp "$PYPROJECT" "$manifest_backup/pyproject.toml"

# The tracked manifests hold the placeholder 0.0.0, never a real version,
# so the stamping assertions below can only pass if stage.sh stamped.
assert_contains "$(grep '"version"' "$NPM_DIR/package.json")" '"0.0.0"' "manifests: package.json is committed at 0.0.0"
assert_contains "$(grep '^version = ' "$PYPROJECT")" '"0.0.0"' "manifests: pyproject.toml is committed at 0.0.0"

out="$(mktemp)"; err="$(mktemp)"
bash "$STAGE" "$VERSION" >"$out" 2>"$err"
stage_ec=$?
rm -f "$out" "$err"
assert_exit 0 "$stage_ec" "stage: a well-formed version stages both packages"

# --- the packages hold the repo's scripts, byte for byte ---
assert_empty "$(diff -r "$REPO_ROOT/bin" "$NPM_DIR/bin" 2>&1)" "stage: npm bin/ matches the repo's bin/"
assert_empty "$(diff -r "$REPO_ROOT/templates" "$NPM_DIR/templates" 2>&1)" "stage: npm templates/ matches the repo's templates/"
assert_empty "$(diff -r "$REPO_ROOT/bin" "$PYPI_PKG/bin" 2>&1)" "stage: pypi bin/ matches the repo's bin/"
assert_empty "$(diff -r "$REPO_ROOT/templates" "$PYPI_PKG/templates" 2>&1)" "stage: pypi templates/ matches the repo's templates/"

# --- a second run over an already-staged tree changes nothing ---
bash "$STAGE" "$VERSION" >/dev/null 2>&1
assert_empty "$(diff -r "$REPO_ROOT/bin" "$NPM_DIR/bin" 2>&1)" "stage: staging twice leaves the same tree"

# --- both manifests carry the staged version ---
assert_contains "$(grep '"version"' "$NPM_DIR/package.json")" "\"$VERSION\"" "stage: package.json carries the staged version"
assert_contains "$(grep '^version = ' "$PYPROJECT")" "\"$VERSION\"" "stage: pyproject.toml carries the staged version"

# --- zero runtime dependencies, declared and not merely absent by luck ---
assert_empty "$(grep -E '^[[:space:]]*"(dependencies|devDependencies|peerDependencies|optionalDependencies)"' "$NPM_DIR/package.json")" "npm: no dependency block of any kind"
assert_eq "1" "$(grep -c '^dependencies = \[\]$' "$PYPROJECT")" "pypi: dependencies is declared empty"

# --- a version that is not X.Y.Z stages nothing ---
out="$(mktemp)"; err="$(mktemp)"
bash "$STAGE" 1.2 >"$out" 2>"$err"
short_ec=$?
short_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 64 "$short_ec" "stage: a two-part version is refused as bad configuration"
assert_contains "$short_err" "X.Y.Z" "stage: the refusal names the shape it wanted"

out="$(mktemp)"; err="$(mktemp)"
bash "$STAGE" v1.2.3 >"$out" 2>"$err"
vprefix_ec=$?
rm -f "$out" "$err"
assert_exit 64 "$vprefix_ec" "stage: a v-prefixed tag name is refused (the workflow strips the v first)"

# --- the npm wrapper reaches the bundled CLI ---
if command -v node >/dev/null 2>&1; then
  out="$(mktemp)"; err="$(mktemp)"
  node "$NPM_DIR/cli.js" --help >"$out" 2>"$err"
  node_help_ec=$?
  node_help="$(cat "$out")"
  rm -f "$out" "$err"
  assert_exit 0 "$node_help_ec" "npm wrapper: --help exits 0"
  assert_contains "$node_help" "usage: pierless" "npm wrapper: prints the CLI's own usage"

  out="$(mktemp)"; err="$(mktemp)"
  node "$NPM_DIR/cli.js" bogus-verb >"$out" 2>"$err"
  node_bogus_ec=$?
  rm -f "$out" "$err"
  assert_exit 64 "$node_bogus_ec" "npm wrapper: the CLI's exit status is the wrapper's exit status"
else
  skip "node not on PATH — npm wrapper cases"
fi

# --- the Python wrapper reaches the same CLI, with nothing installed ---
if command -v python3 >/dev/null 2>&1; then
  out="$(mktemp)"; err="$(mktemp)"
  ( cd "$REPO_ROOT" && PYTHONPATH="packages/pypi/src" python3 -m pierless --help ) >"$out" 2>"$err"
  py_help_ec=$?
  py_help="$(cat "$out")"
  rm -f "$out" "$err"
  assert_exit 0 "$py_help_ec" "python wrapper: --help exits 0"
  assert_contains "$py_help" "usage: pierless" "python wrapper: prints the CLI's own usage"

  out="$(mktemp)"; err="$(mktemp)"
  ( cd "$REPO_ROOT" && PYTHONPATH="packages/pypi/src" python3 -m pierless bogus-verb ) >"$out" 2>"$err"
  py_bogus_ec=$?
  rm -f "$out" "$err"
  assert_exit 64 "$py_bogus_ec" "python wrapper: the CLI's exit status survives the exec"
else
  skip "python3 not on PATH — python wrapper cases"
fi

# --- the tarball holds the wrapper, the manifest, the readme and every
# staged script, and nothing else. The expected list is read off the
# staged tree so a new script under bin/ is covered without editing this.
if command -v npm >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  expected="$( { printf 'package.json\nREADME.md\ncli.js\n'; ( cd "$NPM_DIR" && find bin templates -type f ); } | LC_ALL=C sort )"
  actual="$( ( cd "$NPM_DIR" && npm pack --dry-run --json 2>/dev/null ) | python3 -c '
import json, sys
for f in sorted(p["path"] for p in json.load(sys.stdin)[0]["files"]):
    print(f)
' )"
  assert_eq "$expected" "$actual" "npm pack: the tarball lists exactly the wrapper, the manifest, the readme and the staged tree"
else
  skip "npm or python3 not on PATH — npm pack case"
fi

# --- check-pin.sh against three shapes of action file ---
pin_dir="$(new_tmpdir)"
cat > "$pin_dir/match.yml" <<'EOF'
runs:
  using: composite
  steps:
    - name: Deploy
      env:
        PIERLESS_VERSION: "1.2.3"
EOF
sed 's/1\.2\.3/9.9.9/' "$pin_dir/match.yml" > "$pin_dir/differs.yml"
grep -v PIERLESS_VERSION "$pin_dir/match.yml" > "$pin_dir/missing.yml"

bash "$CHECK_PIN" "$VERSION" "$pin_dir/match.yml" >/dev/null 2>&1
assert_exit 0 "$?" "check-pin: the pinned version and the tag agree"

out="$(mktemp)"; err="$(mktemp)"
bash "$CHECK_PIN" "$VERSION" "$pin_dir/differs.yml" >"$out" 2>"$err"
differs_ec=$?
differs_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 1 "$differs_ec" "check-pin: a stale pin fails the release"
assert_contains "$differs_err" "9.9.9" "check-pin: the message names the version it found"

out="$(mktemp)"; err="$(mktemp)"
bash "$CHECK_PIN" "$VERSION" "$pin_dir/missing.yml" >"$out" 2>"$err"
missing_ec=$?
missing_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 1 "$missing_ec" "check-pin: no pin at all fails the release"
assert_contains "$missing_err" "PIERLESS_VERSION" "check-pin: the message names the line to add"

rm -rf "${NPM_DIR:?}/bin" "${NPM_DIR:?}/templates" "${PYPI_PKG:?}/bin" "${PYPI_PKG:?}/templates"
cp "$manifest_backup/package.json" "$NPM_DIR/package.json"
cp "$manifest_backup/pyproject.toml" "$PYPROJECT"

test_summary_and_exit
