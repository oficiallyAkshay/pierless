#!/usr/bin/env bash
# tests/claims.test.sh — the three claims the README badges make, proven
# against the real tree by scripts/ci/claims.py and then against fixtures
# that MUST fail. A claim that cannot fail proves nothing, so every check
# here is run in both directions.
#
#   runtime tools     bin/* invokes nothing that is not on
#                     tests/claims/runtime-tools.txt, and nothing on that
#                     list is unused
#   inbound ports     nothing shipped opens a listening socket
#   secrets to rotate the registration token never reaches disk, and no
#                     long-lived secret is declared anywhere
#
# The fixtures under "scanner" are the constructs that actually fooled an
# earlier version of the scanner while it was being written against the
# real scripts: a case block that swallowed the rest of the file, a
# heredoc body, a two-line quoted default, and `xargs -0 ls`.
#
# No associative arrays and no `set -u`: macOS's bash 3.2 (see tests/lib.sh).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/claims.py"
ALLOWLIST="$REPO_ROOT/tests/claims/runtime-tools.txt"
require_script "$SCRIPT"
require_script "$ALLOWLIST"

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 not on PATH"; exit 0; }

CLAIMS_STDOUT=""
CLAIMS_STDERR=""
CLAIMS_EXIT=""

run_claims() {
  local out err ec
  out="$(mktemp)"; err="$(mktemp)"
  if python3 "$SCRIPT" "$@" >"$out" 2>"$err"; then
    ec=0
  else
    ec=$?
  fi
  CLAIMS_STDOUT="$(cat "$out")"
  CLAIMS_STDERR="$(cat "$err")"
  CLAIMS_EXIT="$ec"
  rm -f "$out" "$err"
}

# json_field FILE KEY — the value as python's ascii() renders it, so a
# non-ASCII separator survives a C-locale runner intact.
json_field() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
v = d[sys.argv[2]]
sys.stdout.write(" ".join(v) if isinstance(v, list) else ascii(v))' "$1" "$2"
}

exists() {
  if [ -e "$1" ]; then echo 0; else echo 1; fi
}

# --- The real tree ---------------------------------------------------------
real="$(new_tmpdir)"
run_claims --repo-root "$REPO_ROOT" --facts "$real/facts.json" --badges "$real/badges"
assert_exit 0 "$CLAIMS_EXIT" "real tree: every claim is proven"
assert_empty "$CLAIMS_STDERR" "real tree: nothing reported on stderr"
assert_contains "$CLAIMS_STDOUT" "runtime tools: proven" "real tree: runtime tools proven"
assert_contains "$CLAIMS_STDOUT" "inbound ports: proven" "real tree: inbound ports proven"
assert_contains "$CLAIMS_STDOUT" "secrets to rotate: proven" "real tree: secrets to rotate proven"

assert_eq "gh git" "$(json_field "$real/facts.json" runtime_tools)" \
  "facts: the only tools a person must install are gh and git"
assert_contains " $(json_field "$real/facts.json" base_tools) " " launchctl " \
  "facts: launchctl is counted as shipping with macOS"
assert_not_contains " $(json_field "$real/facts.json" base_tools) " " git " \
  "facts: git is not counted as shipping with macOS"
assert_contains "$(json_field "$real/facts.json" scanned)" "deploy.sh" \
  "facts: deploy.sh was scanned"
assert_contains "$(json_field "$real/facts.json" scanned)" "job-started-gate.sh" \
  "facts: the gate was scanned"

# --- The badges the README reads -------------------------------------------
assert_eq 0 "$(exists "$real/badges/runtime-tools.json")" "badge: runtime-tools.json written"
assert_eq 0 "$(exists "$real/badges/inbound-ports.json")" "badge: inbound-ports.json written"
assert_eq 0 "$(exists "$real/badges/secrets-to-rotate.json")" "badge: secrets-to-rotate.json written"

assert_eq "1" "$(json_field "$real/badges/runtime-tools.json" schemaVersion)" "badge: shields endpoint schema"
assert_eq "'runtime tools'" "$(json_field "$real/badges/runtime-tools.json" label)" "badge: runtime tools label"
assert_eq "'gh \\xb7 git'" "$(json_field "$real/badges/runtime-tools.json" message)" "badge: runtime tools message"
assert_eq "'blue'" "$(json_field "$real/badges/runtime-tools.json" color)" "badge: runtime tools color"

assert_eq "'inbound ports'" "$(json_field "$real/badges/inbound-ports.json" label)" "badge: inbound ports label"
assert_eq "'0'" "$(json_field "$real/badges/inbound-ports.json" message)" "badge: inbound ports message"
assert_eq "'brightgreen'" "$(json_field "$real/badges/inbound-ports.json" color)" "badge: inbound ports color"

assert_eq "'secrets to rotate'" "$(json_field "$real/badges/secrets-to-rotate.json" label)" "badge: secrets to rotate label"
assert_eq "'0'" "$(json_field "$real/badges/secrets-to-rotate.json" message)" "badge: secrets to rotate message"
assert_eq "'brightgreen'" "$(json_field "$real/badges/secrets-to-rotate.json" color)" "badge: secrets to rotate color"

# --- Claim A: the scanner, against fixtures --------------------------------
fix="$(new_tmpdir)"
mkdir -p "$fix/bin"
cat > "$fix/bin/sample.sh" <<'FIXTURE'
#!/usr/bin/env bash
# alpha is named in this comment and nowhere else
greet() { printf '%s\n' "$1"; }
NAME=beta
greet "$NAME"
true && bravo --now
CHECKED="$(charlie -n 1)"
case "$NAME" in
  beta) delta ;;
  *) echo nothing ;;
esac
echo $(( 1 + 2 ))
cat <<'HELP'
hotel: a heredoc body is text, not code
HELP
SPEC="one=india --flag
two=india --flag"
xargs -0 ls -t < /dev/null
command -v foxtrot >/dev/null
./vendor/tool.sh --run
FIXTURE

pass_list="$fix/pass.txt"
cat > "$pass_list" <<'LIST'
bravo
charlie
delta
foxtrot
bash  # base
env   # base
cat   # base
ls    # base
xargs # base
./vendor/tool.sh  # bundled
LIST

run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/bin" \
  --allowlist "$pass_list" --facts "$fix/facts.json"
assert_exit 0 "$CLAIMS_EXIT" "scanner: a fixture whose allowlist matches exactly passes"
assert_eq "bravo charlie delta foxtrot" "$(json_field "$fix/facts.json" runtime_tools)" \
  "scanner: finds a command after && , inside \$( ), in a case body, and after command -v"

# Every name below appears in the fixture as something that is NOT a
# command. Listing them makes the run fail as unused — which is the proof
# that the scanner never counted them.
not_a_command="$fix/not-a-command.txt"
cp "$pass_list" "$not_a_command"
{
  echo "greet"
  echo "alpha"
  echo "NAME"
  echo "hotel"
  echo "india"
  echo "nothing"
} >> "$not_a_command"
run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/bin" --allowlist "$not_a_command"
assert_exit 1 "$CLAIMS_EXIT" "scanner: names that are not commands are reported as stale entries"
assert_contains "$CLAIMS_STDERR" "greet is on" "scanner: a function defined in the file is not an external command"
assert_contains "$CLAIMS_STDERR" "alpha is on" "scanner: a comment line is ignored"
assert_contains "$CLAIMS_STDERR" "NAME is on" "scanner: an assignment is ignored"
assert_contains "$CLAIMS_STDERR" "hotel is on" "scanner: a heredoc body is ignored"
assert_contains "$CLAIMS_STDERR" "india is on" "scanner: a two-line quoted default is ignored"
assert_contains "$CLAIMS_STDERR" "nothing is on" "scanner: an argument is not a command"

unlisted="$fix/unlisted.txt"
grep -v '^bravo$' "$pass_list" > "$unlisted"
run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/bin" --allowlist "$unlisted"
assert_exit 1 "$CLAIMS_EXIT" "scanner: an unlisted command fails the claim"
assert_contains "$CLAIMS_STDERR" "bravo is invoked by bin/ but is not on" "scanner: names the unlisted command"
assert_contains "$CLAIMS_STDERR" "runtime tools: NOT PROVEN" "scanner: says which claim failed"

stale="$fix/stale.txt"
cp "$pass_list" "$stale"
echo "zulu" >> "$stale"
run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/bin" --allowlist "$stale"
assert_exit 1 "$CLAIMS_EXIT" "scanner: an unused allowlist entry fails the claim"
assert_contains "$CLAIMS_STDERR" "zulu is on" "scanner: names the stale entry"
assert_contains "$CLAIMS_STDERR" "a stale claim" "scanner: says why an unused entry matters"

# A word it cannot place is reported, never skipped.
mkdir -p "$fix/odd"
cat > "$fix/odd/odd.sh" <<'ODD'
#!/usr/bin/env bash
@@PLACEHOLDER@@ --run
ODD
run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/odd" --allowlist "$pass_list"
assert_exit 1 "$CLAIMS_EXIT" "scanner: a word it cannot classify fails the claim"
assert_contains "$CLAIMS_STDERR" "unclassified word" "scanner: names the word it could not classify"

no_badge="$fix/badges"
run_claims --claim tools --repo-root "$REPO_ROOT" --bin-dir "$fix/bin" \
  --allowlist "$unlisted" --badges "$no_badge"
assert_eq 1 "$(exists "$no_badge/runtime-tools.json")" "badge: a failed claim writes no badge"

# --- Claim B: no inbound port ----------------------------------------------
ports="$(new_tmpdir)"
mkdir -p "$ports/bin" "$ports/templates" "$ports/examples" "$ports/.github/workflows"
printf '#!/usr/bin/env bash\necho fine\n' > "$ports/bin/clean.sh"
run_claims --claim ports --repo-root "$ports"
assert_exit 0 "$CLAIMS_EXIT" "ports: a tree with no listener passes"

for pair in "bin/listener.sh:nc -l 9000" \
            "templates/thing.tmpl:<key>Sockets</key>" \
            "examples/serve.sh:python3 -m http.server 8080" \
            "bin/tunnel.sh:socat TCP-LISTEN:1234,fork -" \
            "bin/flagged.sh:myserver --port 8080"; do
  rel="${pair%%:*}"
  body="${pair#*:}"
  printf '%s\n' "$body" > "$ports/$rel"
  run_claims --claim ports --repo-root "$ports"
  assert_exit 1 "$CLAIMS_EXIT" "ports: $rel opening a listener fails the claim"
  assert_contains "$CLAIMS_STDERR" "$rel" "ports: names the file that opens a listener"
  rm -f "$ports/$rel"
done

printf 'runs:\n  using: composite\n' > "$ports/action.yml"
run_claims --claim ports --repo-root "$ports"
assert_exit 0 "$CLAIMS_EXIT" "ports: the fixture passes again once the listeners are gone"

# `Runner.Listener` is the runner's own binary, not a socket: the search is
# case-sensitive so that the real installer is not a false positive.
printf '%s\n' '[ -x "${RUNNER_DIR}/bin/Runner.Listener" ] || exit 1' > "$ports/bin/runner.sh"
run_claims --claim ports --repo-root "$ports"
assert_exit 0 "$CLAIMS_EXIT" "ports: Runner.Listener is not read as a listening socket"

# --- Claim C: no long-lived secret -----------------------------------------
sec="$(new_tmpdir)"
mkdir -p "$sec/bin" "$sec/.github/workflows"
cp "$REPO_ROOT/bin/install-runner.sh" "$REPO_ROOT/bin/uninstall-runner.sh" "$sec/bin/"
cp "$REPO_ROOT/action.yml" "$sec/action.yml"
cp "$REPO_ROOT/.github/workflows/ci.yml" "$sec/.github/workflows/ci.yml"
run_claims --claim secrets --repo-root "$sec"
assert_exit 0 "$CLAIMS_EXIT" "secrets: a copy of the real tree passes"

printf '%s\n' 'printf "%s" "${TOKEN}" > "${RUNNER_DIR}/token"' >> "$sec/bin/install-runner.sh"
run_claims --claim secrets --repo-root "$sec"
assert_exit 1 "$CLAIMS_EXIT" "secrets: writing the token to a file fails the claim"
assert_contains "$CLAIMS_STDERR" "redirects to a file" "secrets: names the redirect that would persist the token"
cp "$REPO_ROOT/bin/install-runner.sh" "$sec/bin/install-runner.sh"

printf '%s\n' 'log "the token is ${TOKEN}"' >> "$sec/bin/install-runner.sh"
run_claims --claim secrets --repo-root "$sec"
assert_exit 1 "$CLAIMS_EXIT" "secrets: handing the token to any other command fails the claim"
assert_contains "$CLAIMS_STDERR" "which is neither a guard nor the" "secrets: names the command the token reached"
cp "$REPO_ROOT/bin/install-runner.sh" "$sec/bin/install-runner.sh"

python3 - "$sec/action.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, "w").write(text.replace("inputs:\n", "inputs:\n  github_token:\n    required: true\n", 1))
PY
run_claims --claim secrets --repo-root "$sec"
assert_exit 1 "$CLAIMS_EXIT" "secrets: an action input asking for a token fails the claim"
assert_contains "$CLAIMS_STDERR" "asks the caller for a secret" "secrets: names the offending input"
cp "$REPO_ROOT/action.yml" "$sec/action.yml"

printf '%s\n' '          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}' >> "$sec/.github/workflows/ci.yml"
run_claims --claim secrets --repo-root "$sec"
assert_exit 1 "$CLAIMS_EXIT" "secrets: a workflow secret other than the two allowed ones fails the claim"
assert_contains "$CLAIMS_STDERR" "uses secrets.DEPLOY_KEY" "secrets: names the secret someone would have to rotate"
cp "$REPO_ROOT/.github/workflows/ci.yml" "$sec/.github/workflows/ci.yml"

# TRAFFIC_TOKEN is a read-only counter token: allowed, and still allowed
# when the claim is otherwise untouched.
printf '%s\n' '          TRAFFIC: ${{ secrets.TRAFFIC_TOKEN }}' >> "$sec/.github/workflows/ci.yml"
run_claims --claim secrets --repo-root "$sec"
assert_exit 0 "$CLAIMS_EXIT" "secrets: the read-only traffic token is allowed"

test_summary_and_exit
