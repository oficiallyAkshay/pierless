#!/usr/bin/env bash
# tests/coverage-check.test.sh — scripts/ci/coverage-check.py against a
# hand-written xtrace file (a fake bin/deploy.sh plus "+trace:" lines, no
# real bash run needed) and a fake diff (--diff-file, no real git
# needed): both numbers land right, and both exit paths (pass, fail on
# --min-changed) fire correctly. A separate end-to-end case at the
# bottom runs a real traced test file through tests/run.sh.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/coverage-check.py"
require_script "$SCRIPT"

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 not on PATH"; exit 0; }

dir="$(new_tmpdir)"
mkdir -p "$dir/bin" "$dir/coverage"

# bin/deploy.sh: lines 2-11 are coverable (line 1 is the shebang, a
# comment); the trace below hits 2, 4, 6, 8, 10 — 5 of 10 => 50.0%.
cat > "$dir/bin/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo one
echo two
echo three
echo four
echo five
echo six
echo seven
echo eight
echo nine
echo ten
EOF

# One line written with a doubled "+" to cover the nesting-depth case
# bash's xtrace produces for a nested function/subshell call.
cat > "$dir/coverage/trace.log" <<EOF
+trace:$dir/bin/deploy.sh:2:echo one
+trace:$dir/bin/deploy.sh:4:echo three
++trace:$dir/bin/deploy.sh:6:echo five
+trace:$dir/bin/deploy.sh:8:echo seven
+trace:$dir/bin/deploy.sh:10:echo nine
EOF

cat > "$dir/diff-fail.txt" <<'EOF'
diff --git a/bin/deploy.sh b/bin/deploy.sh
index abc..def 100644
--- a/bin/deploy.sh
+++ b/bin/deploy.sh
@@ -9,0 +10,2 @@ some context
+echo added1
+echo added2
EOF
cat > "$dir/diff-pass.txt" <<'EOF'
diff --git a/bin/deploy.sh b/bin/deploy.sh
index abc..def 100644
--- a/bin/deploy.sh
+++ b/bin/deploy.sh
@@ -9,0 +10,1 @@ some context
+echo added1
EOF
cat > "$dir/diff-other-file.txt" <<'EOF'
diff --git a/README.md b/README.md
index abc..def 100644
--- a/README.md
+++ b/README.md
@@ -1,0 +2,1 @@
+hello
EOF

run_check() {
  ( cd "$dir" && python3 "$SCRIPT" "$@" )
}

out="$(run_check --diff-file "$dir/diff-fail.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "total=50.0%" "coverage: total line coverage computed from the trace file"
assert_contains "$out" "changed=50.0% (1/2)" "coverage: changed-line coverage counts only the two added lines"
assert_exit 1 "$ec" "coverage: exits 1 when changed coverage is below --min-changed"
assert_contains "$(cat "$dir/coverage/summary.json")" '"changed": 50.0' "coverage: summary.json records the changed percentage"

out="$(run_check --diff-file "$dir/diff-pass.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "changed=100.0% (1/1)" "coverage: a fully-covered added line scores 100%"
assert_exit 0 "$ec" "coverage: exits 0 when changed coverage meets --min-changed"

out="$(run_check --diff-file "$dir/diff-other-file.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "changed=n/a" "coverage: a diff with no bin/ lines reports changed=n/a"
assert_exit 0 "$ec" "coverage: zero changed coverable lines passes regardless of --min-changed"

out="$(run_check)"
ec=$?
assert_contains "$out" "total=50.0%" "coverage: total is still reported with no --base or --diff-file"
assert_contains "$out" "changed=n/a" "coverage: changed-lines bar is skipped with no --base or --diff-file"
assert_exit 0 "$ec" "coverage: no --min-changed given never fails the run"
assert_contains "$(cat "$dir/coverage/summary.json")" '"changed": null' "coverage: summary.json changed is null when skipped"

help_out="$(python3 "$SCRIPT" --help 2>&1)"
assert_contains "$help_out" "usage" "coverage: --help prints usage"

# --- --min-total: fails/exits 1 below the threshold, passes at/above it ---
out="$(run_check --min-total 60)"
ec=$?
assert_contains "$out" "total=50.0%" "min-total: total is still 50.0% (5/10 lines traced)"
assert_exit 1 "$ec" "min-total: exits 1 when total coverage is below --min-total"

out="$(run_check --min-total 50)"
ec=$?
assert_exit 0 "$ec" "min-total: exits 0 when total coverage exactly meets --min-total"

out="$(run_check --min-total 40)"
ec=$?
assert_exit 0 "$ec" "min-total: exits 0 when total coverage is above --min-total"

out="$(run_check)"
ec=$?
assert_exit 0 "$ec" "min-total: no --min-total given never fails the run on total coverage alone"

# --min-changed and --min-total are independent gates: both apply together.
out="$(run_check --diff-file "$dir/diff-pass.txt" --min-changed 90 --min-total 60)"
ec=$?
assert_exit 1 "$ec" "min-total: still fails on total even when --min-changed passes"

out="$(run_check --diff-file "$dir/diff-fail.txt" --min-changed 90 --min-total 40)"
ec=$?
assert_exit 1 "$ec" "min-total: still fails on --min-changed even when total passes"

# --- end-to-end: a real traced run of one small test file, through the
# real tests/run.sh + scripts/ci/trace.sh, no fixture trace file ---
e2e_dir="$(new_tmpdir)"
mkdir -p "$e2e_dir/bin" "$e2e_dir/tests" "$e2e_dir/scripts/ci" "$e2e_dir/coverage"
cp "$REPO_ROOT/bin/job-started-gate.sh" "$e2e_dir/bin/"
cp "$REPO_ROOT/tests/lib.sh" "$REPO_ROOT/tests/gate.test.sh" "$REPO_ROOT/tests/run.sh" "$e2e_dir/tests/"
cp "$REPO_ROOT/scripts/ci/trace.sh" "$SCRIPT" "$e2e_dir/scripts/ci/"

e2e_run_out="$(cd "$e2e_dir" && PIERLESS_TRACE_FILE="$e2e_dir/coverage/trace.log" bash tests/run.sh 2>&1)"
e2e_run_ec=$?
assert_exit 0 "$e2e_run_ec" "end-to-end: gate.test.sh still passes while traced"

# bin/ holds only job-started-gate.sh here, so the overall total is that
# file's own coverage.
e2e_check_out="$(cd "$e2e_dir" && python3 scripts/ci/coverage-check.py --trace coverage/trace.log)"
assert_not_contains "$e2e_check_out" "total=0.0%" "end-to-end: a real traced gate.test.sh run yields non-zero bin/job-started-gate.sh coverage"

# --- lines bash can never trace are not counted against a file ---
# A usage heredoc's body is data handed to cat, and a case arm's pattern
# is not a command: bash traces neither, so a script fully exercised by
# its tests must still score 100%.
shape_dir="$(new_tmpdir)"
mkdir -p "$shape_dir/bin" "$shape_dir/coverage"
cat > "$shape_dir/bin/shapes.sh" <<'EOF'
#!/usr/bin/env bash
usage() {
  cat <<'USAGE'
usage: shapes <verb>
  run  do the thing
USAGE
}
case "$1" in
  run)
    echo running
    ;;
  *)
    usage
    ;;
esac
EOF

# Every line the shell actually runs, and nothing else.
cat > "$shape_dir/coverage/trace.log" <<EOF
+trace:$shape_dir/bin/shapes.sh:2:usage
+trace:$shape_dir/bin/shapes.sh:3:cat
+trace:$shape_dir/bin/shapes.sh:8:case
+trace:$shape_dir/bin/shapes.sh:10:echo running
+trace:$shape_dir/bin/shapes.sh:13:usage
EOF

shape_out="$(cd "$shape_dir" && python3 "$SCRIPT" --trace coverage/trace.log --list-uncovered)"
assert_contains "$shape_out" "total=100.0%" "coverage: heredoc bodies and case patterns are not coverable lines"
assert_not_contains "$shape_out" "shapes.sh:" "coverage: nothing untraceable is reported as uncovered"

# --- look-alikes stay coverable ---
# A multi-line command substitution's last line ends in ")" like a case
# pattern but is a command bash runs; a "<<" inside quotes, a comment,
# arithmetic or a "<<<" here-string opens no heredoc, so the lines after
# it still count. Each untraced one must be reported.
look_dir="$(new_tmpdir)"
mkdir -p "$look_dir/bin" "$look_dir/coverage"
cat > "$look_dir/bin/looks.sh" <<'EOF'
#!/usr/bin/env bash
x=$(printf a \
  | tr a b)
echo "a <<EOF"
grep b <<<"$x"
y=$(( 1 << 2 ))
echo done # <<EOF
echo last
case "$1" in
  run)
    z=$(printf a \
      | tr a b)
    ;;
esac
cat <<END-X
body
END-X
echo tail
EOF

# Only the first command is traced: every other line must show up.
cat > "$look_dir/coverage/trace.log" <<EOF
+trace:$look_dir/bin/looks.sh:2:x=b
EOF

look_out="$(cd "$look_dir" && python3 "$SCRIPT" --trace coverage/trace.log --list-uncovered)"
assert_contains "$look_out" "looks.sh:3" "coverage: a command substitution's closing line outside a case is coverable"
assert_contains "$look_out" "looks.sh:5" "coverage: a quoted <<EOF opens no heredoc"
assert_contains "$look_out" "looks.sh:6" "coverage: a <<< here-string opens no heredoc"
assert_contains "$look_out" "looks.sh:7" "coverage: an arithmetic << opens no heredoc"
assert_contains "$look_out" "looks.sh:8" "coverage: a <<EOF in a trailing comment opens no heredoc"
assert_contains "$look_out" "looks.sh:12" "coverage: a command substitution's closing line inside a case arm is coverable"
assert_not_contains "$look_out" "looks.sh:16" "coverage: a hyphenated heredoc word opens a body that is not coverable"
assert_contains "$look_out" "looks.sh:18" "coverage: the line after a hyphenated heredoc's terminator is coverable"

test_summary_and_exit
