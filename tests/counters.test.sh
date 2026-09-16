#!/usr/bin/env bash
# tests/counters.test.sh — scripts/ci/counters.py driven entirely from
# fixture response bodies (--source NAME=FILE), so no test here can reach
# api.github.com, api.npmjs.org or pypistats.org. The fixtures double as
# the documentation of the three response shapes the script reads, and
# {"http_status": N} stands in for an HTTP error from that endpoint.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/counters.py"
require_script "$SCRIPT"

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 not on PATH"; exit 0; }

dir="$(new_tmpdir)"
fix="$dir/fixtures"
mkdir -p "$fix"

write_clones() {
  printf '{"count": %s, "uniques": 7, "clones": []}\n' "$1" > "$fix/clones.json"
}
write_npm() {
  printf '{"downloads": %s, "start": "2026-08-18", "end": "2026-09-16", "package": "pierless"}\n' "$1" > "$fix/npm.json"
}
write_pypi() {
  printf '{"data": {"last_day": 3, "last_week": 20, "last_month": %s}, "package": "pierless", "type": "recent_downloads"}\n' "$1" > "$fix/pypi.json"
}

sources=(--source "clones=$fix/clones.json" --source "npm=$fix/npm.json" --source "pypi=$fix/pypi.json")

counters() {
  python3 "$SCRIPT" --repo owner/pierless --npm pierless --pypi pierless "$@" 2>&1
}
# A token is only a stand-in here: clones still comes from a fixture file.
with_token() { ( export TRAFFIC_TOKEN="dummy-token"; counters "$@" ); }
without_token() { ( unset TRAFFIC_TOKEN; counters "$@" ); }

jfield() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
jraw() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["raw"][sys.argv[2]])' "$1" "$2"; }

# --- all three live ---
write_clones 42
write_npm 100
write_pypi 7
live_out_dir="$dir/live"
out="$(with_token "${sources[@]}" --out "$live_out_dir")"
ec=$?
assert_exit 0 "$ec" "counters: exits 0 when all three sources are live"

assert_eq "clones (14d)" "$(jfield "$live_out_dir/clones-14d.json" label)" "counters: the clones badge is labelled with its window"
assert_eq "42" "$(jfield "$live_out_dir/clones-14d.json" message)" "counters: the clones badge shows the plain count"
assert_eq "blue" "$(jfield "$live_out_dir/clones-14d.json" color)" "counters: the clones badge is blue"
assert_eq "1" "$(jfield "$live_out_dir/clones-14d.json" schemaVersion)" "counters: the clones badge is shields endpoint JSON"
assert_eq "42" "$(jfield "$live_out_dir/clones-14d.json" raw)" "counters: the clones badge carries its raw number for the next run"

assert_eq "npm (30d)" "$(jfield "$live_out_dir/npm-30d.json" label)" "counters: the npm badge is labelled with its window"
assert_eq "100" "$(jfield "$live_out_dir/npm-30d.json" message)" "counters: the npm badge shows last-month downloads"
assert_eq "pypi (30d)" "$(jfield "$live_out_dir/pypi-30d.json" label)" "counters: the pypi badge is labelled with its window"
assert_eq "7" "$(jfield "$live_out_dir/pypi-30d.json" message)" "counters: the pypi badge shows data.last_month"

assert_eq "installs" "$(jfield "$live_out_dir/installs.json" label)" "counters: the combined badge is labelled installs"
assert_eq "149 · 30d + clones 14d" "$(jfield "$live_out_dir/installs.json" message)" "counters: the combined badge sums the three counters and names the windows"
assert_eq "blue" "$(jfield "$live_out_dir/installs.json" color)" "counters: the combined badge is blue"
assert_eq "42" "$(jraw "$live_out_dir/installs.json" clones_14d)" "counters: installs raw keeps the clone count"
assert_eq "100" "$(jraw "$live_out_dir/installs.json" npm_30d)" "counters: installs raw keeps the npm count"
assert_eq "7" "$(jraw "$live_out_dir/installs.json" pypi_30d)" "counters: installs raw keeps the pypi count"
assert_eq "149" "$(jraw "$live_out_dir/installs.json" total)" "counters: installs raw keeps the unformatted total"

assert_contains "$out" "clones-14d=42 (live)" "counters: the summary marks a fetched clones count live"
assert_contains "$out" "npm-30d=100 (live)" "counters: the summary marks a fetched npm count live"
assert_contains "$out" "pypi-30d=7 (live)" "counters: the summary marks a fetched pypi count live"
assert_not_contains "$out" "::warning::" "counters: an all-live run prints no warning"

# --- the k-suffix boundaries ---
fmt_run=0
assert_total() {
  local clones="$1" npm="$2" pypi="$3" expected="$4" d
  fmt_run=$((fmt_run + 1))
  d="$dir/fmt$fmt_run"
  write_clones "$clones"
  write_npm "$npm"
  write_pypi "$pypi"
  with_token "${sources[@]}" --out "$d" >/dev/null
  assert_eq "$expected · 30d + clones 14d" "$(jfield "$d/installs.json" message)" \
    "counters: a total of $((clones + npm + pypi)) reads as $expected"
  assert_eq "$((clones + npm + pypi))" "$(jraw "$d/installs.json" total)" \
    "counters: the raw total behind $expected is the exact sum"
}
assert_total 999 0 0 999
assert_total 600 400 0 1k
assert_total 1000 200 34 1.2k
assert_total 12000 300 45 12.3k
assert_total 50000 40000 10000 100k

# --- a previous run to fall back on ---
write_clones 500
write_npm 100
write_pypi 7
prev="$dir/previous"
with_token "${sources[@]}" --out "$prev" >/dev/null

# --- clones missing because the token is not set ---
unset_out_dir="$dir/no-token"
out="$(without_token "${sources[@]}" --out "$unset_out_dir" --previous "$prev")"
ec=$?
assert_exit 1 "$ec" "counters: exits 1 when a source is missing, after writing every file"
assert_contains "$out" "::warning::clones: TRAFFIC_TOKEN is not set; reusing previous value 500" \
  "counters: an unset TRAFFIC_TOKEN reuses the last published clone count and says why"
assert_eq "500" "$(jfield "$unset_out_dir/clones-14d.json" message)" "counters: the clones badge still carries the reused value"
assert_eq "607 · 30d + clones 14d" "$(jfield "$unset_out_dir/installs.json" message)" "counters: the combined badge counts the reused value"
assert_contains "$out" "clones-14d=500 (reused)" "counters: the summary marks a fallen-back clones count reused"
assert_contains "$out" "npm-30d=100 (live)" "counters: one missing source leaves the other two live"

# --- npm 404 with nothing to fall back on ---
printf '{"http_status": 404}\n' > "$fix/npm.json"
notpub_out_dir="$dir/npm-404"
out="$(with_token "${sources[@]}" --out "$notpub_out_dir")"
ec=$?
assert_exit 1 "$ec" "counters: a 404 from npm fails the run"
assert_contains "$out" "::warning::npm: npm has no package named pierless yet (HTTP 404); no previous value, using 0" \
  "counters: an unpublished npm package falls back to 0 and says why"
assert_eq "0" "$(jfield "$notpub_out_dir/npm-30d.json" message)" "counters: the npm badge reads 0 while the package does not exist"
assert_eq "507" "$(jraw "$notpub_out_dir/installs.json" total)" "counters: the combined badge still totals the sources that did answer"
assert_contains "$out" "npm-30d=0 (zero)" "counters: the summary marks a floored npm count zero"

# --- pypistats rate-limiting this IP ---
write_npm 100
printf '{"http_status": 429}\n' > "$fix/pypi.json"
throttled_out_dir="$dir/pypi-429"
out="$(with_token "${sources[@]}" --out "$throttled_out_dir" --previous "$prev")"
ec=$?
assert_exit 1 "$ec" "counters: a 429 from pypistats fails the run"
assert_contains "$out" "::warning::pypi: pypistats rate-limits by IP and throttled this run (HTTP 429); reusing previous value 7" \
  "counters: a throttled pypistats call reuses the last published download count"
assert_eq "7" "$(jfield "$throttled_out_dir/pypi-30d.json" message)" "counters: the pypi badge holds its previous number through a 429"
assert_contains "$out" "pypi-30d=7 (reused)" "counters: the summary marks a throttled pypi count reused"

# --- no token and no clones fixture: nothing is requested at all ---
write_pypi 7
offline_out_dir="$dir/offline"
out="$(without_token --source "npm=$fix/npm.json" --source "pypi=$fix/pypi.json" --out "$offline_out_dir")"
ec=$?
assert_exit 1 "$ec" "counters: a tokenless run with no clones fixture still exits 1"
assert_contains "$out" "::warning::clones: TRAFFIC_TOKEN is not set; no previous value, using 0" \
  "counters: with no token the traffic API is never called, so the reason is the missing token and not an HTTP status"
assert_not_contains "$out" "could not be reached" "counters: a tokenless run never attempts the request"
assert_contains "$out" "clones-14d=0 (zero)" "counters: a tokenless clones count is reported as zero"
assert_eq "107" "$(jraw "$offline_out_dir/installs.json" total)" "counters: every badge file is written even when a source is missing"

# --- documentation ---
help_out="$(python3 "$SCRIPT" --help 2>&1)"
assert_contains "$help_out" "usage" "counters: --help prints usage"
assert_contains "$help_out" "trailing 14-day window" "counters: --help documents the clones window"
assert_contains "$help_out" "trailing 30 days" "counters: --help documents the download window"
assert_contains "$help_out" "Nothing is collected from users' machines" "counters: --help says the tool collects nothing from users"

test_summary_and_exit
