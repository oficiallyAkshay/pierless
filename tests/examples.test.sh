#!/usr/bin/env bash
# tests/examples.test.sh — the Slack failure example must send valid JSON
# even when the reason holds a backslash, a quote, a newline or a tab, and
# the deploy example must name only absolute paths and no sample label.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

tmp="$(new_tmpdir)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<STUB
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-d" ]; then printf '%s' "\$2" > "$tmp/body"; fi
  shift
done
STUB
chmod +x "$tmp/bin/curl"

send() {
  rm -f "$tmp/body"
  PATH="$tmp/bin:$PATH" SLACK_WEBHOOK_URL="https://hooks.invalid/x" \
    PIERLESS_EXIT_CODE=1 PIERLESS_REASON="$1" PIERLESS_RUN_URL="run" \
    bash "$HERE/../examples/on-failure-slack.sh"
}
valid_json() { python3 -c 'import json,sys; json.loads(sys.stdin.read())' < "$tmp/body"; }

send 'plain reason'
valid_json; assert_true "$?" "plain reason: body is valid JSON"
send 'path C:\temp\new "quoted"'
valid_json; assert_true "$?" "backslash and quote: body is valid JSON"
send $'two\nlines'
valid_json; assert_true "$?" "newline: body is valid JSON"
send $'tab\there'
valid_json; assert_true "$?" "tab: body is valid JSON"
send 'ends with backslash\'
valid_json; assert_true "$?" "trailing backslash: body is valid JSON"

# The deploy example must work once copied: nothing is checked out in the
# runner's work folder, so every path it names is absolute.
value() { sed -n "s/^ *$1: *\([^ ]*\).*/\1/p" "$HERE/../examples/deploy.yml" | tr -d "\"'"; }
for key in repo on_failure on_recovery; do
  case "$(value "$key")" in
    /*) pass "deploy example: $key is an absolute path" ;;
    *) fail "deploy example: $key is an absolute path (got [$(value "$key")])" ;;
  esac
done
assert_not_contains "$(value kick)" "com.example" "deploy example: kick names no sample label"

test_summary_and_exit
