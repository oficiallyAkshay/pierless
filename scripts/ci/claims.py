#!/usr/bin/env python3
# scripts/ci/claims.py — proves the README's claim badges from the code
# itself, and writes the shields endpoint JSON those badges read.
#
# One implementation per claim, shared by tests/claims.test.sh and by CI,
# so a badge can never say something the test did not just prove. A claim
# that fails writes no badge and exits non-zero.
#
#   runtime tools     every command bin/* invokes is on an explicit
#                     allowlist, and every allowlist entry is still used
#   inbound ports     nothing shipped opens a listening socket
#   secrets to rotate the registration token is never written to disk and
#                     no long-lived secret is declared anywhere
#
# Usage:
#   claims.py [--repo-root DIR] [--bin-dir DIR] [--allowlist FILE]
#             [--claim tools|ports|secrets|all]
#             [--facts FILE] [--badges DIR] [--report]
#
# stdlib only, no network.
import argparse
import json
import os
import re
import sys

# --- The command scanner ---------------------------------------------------
#
# A bash script's external dependencies are the first word of each simple
# command. Finding those words needs real quote, substitution and heredoc
# tracking — a line-based grep reads `npm` out of a quoted default string
# and misses `tr` inside a "$( )" — so this is a small tokeniser rather
# than a regex. It is deliberately strict: a construct it cannot place is
# reported as `unclassified` and fails the claim, never skipped, because a
# silent skip is exactly how an undeclared dependency would hide.


BASE_MARKER = "base"
BUNDLED_MARKER = "bundled"


class ScanError(Exception):
    """An unterminated quote or substitution: the file cannot be read
    honestly, so nothing is claimed about it."""


# Words bash runs itself. None of them is a tool anyone has to install.
BUILTINS = set("""
if fi for while case esac local export echo printf read cd set shift return
exit trap test [ ]] : true false eval source . unset declare readonly break
continue wait kill let getopts pwd umask ulimit hash type command builtin
mapfile readarray caller compgen dirs pushd popd then else do done elif
until in function select time
""".split()) | {"[[", "!"}

# Keywords and prefixes after which the NEXT word is itself a command.
# Without these the scanner would read `until` as the command and never
# see the `mkdir` that follows it.
PREFIXES = {
    "exec", "env", "nohup", "xargs", "sudo", "then", "else", "do", "!",
    "time", "command", "type", "builtin", "if", "elif", "while", "until",
}

# Prefixes that take their own flags first: `command -v plutil`, `xargs -0 ls`.
FLAG_TAKING_PREFIXES = {"command", "type", "builtin", "env", "xargs", "nohup", "sudo"}

# Prefixes that are themselves a program someone has to have.
EXTERNAL_PREFIXES = {"env", "xargs", "nohup", "sudo"}

# Keywords followed by a name or a word list, never by a command.
NOT_A_COMMAND_NEXT = {"for", "select", "function", "fi", "done", "in"}

ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
COMMAND_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.+-]*$")
FUNCTION_RE = re.compile(
    r"^[ \t]*(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*\(\)[ \t]*\{",
    re.MULTILINE,
)
FUNCTION_KEYWORD_RE = re.compile(r"^[ \t]*function[ \t]+([A-Za-z_][A-Za-z0-9_.-]*)", re.MULTILINE)
REDIRECT_RE = re.compile(r"[0-9]*(?:>>|>&|<&|<<<|<<-|<<|>|<)")
SHEBANG_RE = re.compile(r"^#![ \t]*(\S+)(?:[ \t]+(\S+))?")


class Tokenizer:
    """Splits one bash text into words, operators and redirections, and
    collects the bodies of command substitutions to be tokenised in turn
    (each is its own command context)."""

    def __init__(self, text, start_line=1):
        self.text = text
        self.i = 0
        self.n = len(text)
        self.line = start_line
        self.tokens = []
        self.subs = []
        self.word = []
        self.in_word = False
        self.pending_heredocs = []

    # -- helpers --
    def _advance_to(self, j):
        self.line += self.text.count("\n", self.i, j)
        self.i = j

    def _flush(self):
        if self.in_word:
            self.tokens.append(("word", "".join(self.word), self.word_line))
        self.word = []
        self.in_word = False

    def _add(self, s):
        if not self.in_word:
            self.word_line = self.line
            self.in_word = True
        self.word.append(s)

    def _skip_single(self, i):
        j = self.text.find("'", i + 1)
        if j == -1:
            raise ScanError("unterminated single quote at line %d" % self.line)
        return j + 1

    def _skip_dollar_single(self, i):
        j = i + 2
        while j < self.n:
            if self.text[j] == "\\":
                j += 2
                continue
            if self.text[j] == "'":
                return j + 1
            j += 1
        raise ScanError("unterminated $'...' at line %d" % self.line)

    def _skip_dquote(self, i):
        """Returns the index past the closing quote, recording any command
        substitution inside it — a "$( )" still runs commands."""
        j = i + 1
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                j += 2
                continue
            if c == "$" and self.text[j : j + 2] == "$(":
                j = self._take_substitution(j)
                continue
            if c == "$" and self.text[j : j + 2] == "${":
                j = self._match(j + 1, "{", "}")
                continue
            if c == "`":
                j = self._take_backtick(j)
                continue
            if c == '"':
                return j + 1
            j += 1
        raise ScanError("unterminated double quote at line %d" % self.line)

    def _match(self, i, open_ch, close_ch):
        """Index past the balanced close of text[i] == open_ch."""
        depth = 0
        j = i
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                j = self._skip_single(j)
                continue
            if c == '"':
                j = self._skip_dquote(j)
                continue
            if c == "`":
                j = self._take_backtick(j)
                continue
            if c == open_ch:
                depth += 1
            elif c == close_ch:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        raise ScanError("unbalanced %s%s at line %d" % (open_ch, close_ch, self.line))

    def _take_substitution(self, i):
        """text[i:i+2] == '$(' — records the body as its own command
        context and returns the index past the closing paren."""
        end = self._match(i + 1, "(", ")")
        body = self.text[i + 2 : end - 1]
        self.subs.append((body, self.line + self.text.count("\n", self.i, i)))
        return end

    def _take_backtick(self, i):
        j = self.text.find("`", i + 1)
        if j == -1:
            raise ScanError("unterminated backtick at line %d" % self.line)
        self.subs.append((self.text[i + 1 : j], self.line))
        return j + 1

    def _take_arithmetic(self, i):
        """$(( )) is arithmetic, not a command list, but it can still carry
        a "$( )" of its own: keep those, drop the arithmetic itself."""
        end = self._match(i + 1, "(", ")")
        inner = Tokenizer(self.text[i + 3 : end - 2], self.line)
        inner.run()
        self.subs.extend(inner.subs)
        return end

    def _consume_heredocs(self):
        for delim, quoted in self.pending_heredocs:
            body = []
            while self.i < self.n:
                nl = self.text.find("\n", self.i)
                stop = self.n if nl == -1 else nl + 1
                raw = self.text[self.i : stop]
                self._advance_to(stop)
                if raw.strip() == delim:
                    break
                body.append(raw)
            if not quoted:
                inner = Tokenizer("".join(body), self.line)
                inner.run()
                self.subs.extend(inner.subs)
        self.pending_heredocs = []

    def _read_heredoc_delim(self):
        j = self.i
        while j < self.n and self.text[j] in " \t":
            j += 1
        start = j
        quoted = False
        while j < self.n and self.text[j] not in " \t\n;&|()<>":
            if self.text[j] in "\"'":
                quoted = True
            j += 1
        word = self.text[start:j]
        self._advance_to(j)
        return word.strip("\"'"), quoted

    # -- main loop --
    def run(self):
        t = self.text
        while self.i < self.n:
            c = t[self.i]
            if c == "\\" and self.i + 1 < self.n:
                if t[self.i + 1] == "\n":
                    self._advance_to(self.i + 2)
                    continue
                self._add(t[self.i : self.i + 2])
                self.i += 2
                continue
            if c == "#" and not self.in_word:
                nl = t.find("\n", self.i)
                self._advance_to(self.n if nl == -1 else nl)
                continue
            if c == "'":
                j = self._skip_single(self.i)
                self._add(t[self.i : j])
                self._advance_to(j)
                continue
            if c == '"':
                j = self._skip_dquote(self.i)
                self._add(t[self.i : j])
                self._advance_to(j)
                continue
            if c == "`":
                j = self._take_backtick(self.i)
                self._add(t[self.i : j])
                self._advance_to(j)
                continue
            if c == "$":
                two, three = t[self.i : self.i + 2], t[self.i : self.i + 3]
                if three == "$((":
                    j = self._take_arithmetic(self.i)
                elif two == "$(":
                    j = self._take_substitution(self.i)
                elif two == "${":
                    j = self._match(self.i + 1, "{", "}")
                elif two == "$'":
                    j = self._skip_dollar_single(self.i)
                else:
                    self._add(c)
                    self.i += 1
                    continue
                self._add(t[self.i : j])
                self._advance_to(j)
                continue
            if c in "<>" or (c.isdigit() and REDIRECT_RE.match(t, self.i) and not self.in_word):
                m = REDIRECT_RE.match(t, self.i)
                if m:
                    self._flush()
                    op = m.group(0)
                    self.tokens.append(("redirect", op, self.line))
                    self._advance_to(m.end())
                    if op.lstrip("0123456789") in ("<<", "<<-"):
                        delim, quoted = self._read_heredoc_delim()
                        self.pending_heredocs.append((delim, quoted))
                    continue
                self._add(c)
                self.i += 1
                continue
            if c in " \t":
                self._flush()
                self.i += 1
                continue
            if c == "\n":
                self._flush()
                self.tokens.append(("op", "\n", self.line))
                self._advance_to(self.i + 1)
                if self.pending_heredocs:
                    self._consume_heredocs()
                continue
            if c in ";&|(){}":
                self._flush()
                two = t[self.i : self.i + 2]
                if two in (";;", "&&", "||"):
                    self.tokens.append(("op", two, self.line))
                    self.i += 2
                else:
                    self.tokens.append(("op", c, self.line))
                    self.i += 1
                continue
            self._add(c)
            self.i += 1
        self._flush()
        if self.pending_heredocs:
            self._consume_heredocs()
        return self.tokens, self.subs


def token_streams(text, start_line=1):
    """Every command context in `text`: the text itself, then each command
    substitution it contains, recursively."""
    out = []
    pending = [(text, start_line)]
    while pending:
        body, line = pending.pop(0)
        tok = Tokenizer(body, line)
        tokens, subs = tok.run()
        out.append(tokens)
        pending.extend(subs)
    return out


def function_names(text):
    return set(FUNCTION_RE.findall(text)) | set(FUNCTION_KEYWORD_RE.findall(text))


class FileScan(object):
    def __init__(self, path):
        self.path = path
        self.commands = set()
        self.paths = set()
        self.unclassified = []


def scan_file(path):
    """The set of command names one script invokes."""
    with open(path, "r") as fh:
        text = fh.read()
    scan = FileScan(path)
    funcs = function_names(text)

    # The interpreter is a dependency too, and the shebang is the one
    # "comment" that runs something.
    m = SHEBANG_RE.match(text)
    if m:
        interp = os.path.basename(m.group(1))
        scan.commands.add(interp)
        if interp == "env" and m.group(2):
            scan.commands.add(m.group(2))

    for tokens in token_streams(text):
        _extract(tokens, funcs, scan)
    return scan


def _extract(tokens, funcs, scan):
    cmd_pos = True
    skip_flags = False
    skip_next = False
    case_stack = []
    for kind, val, line in tokens:
        if kind == "redirect":
            skip_next = True
            continue
        if kind == "op":
            if case_stack and case_stack[-1] == "pattern":
                # `|` separates case patterns; only `)` ends them.
                if val == ")":
                    case_stack[-1] = "body"
                    cmd_pos = True
                continue
            if val == ";;" and case_stack:
                case_stack[-1] = "pattern"
                cmd_pos = False
                continue
            cmd_pos = True
            skip_flags = False
            skip_next = False
            continue
        if skip_next:
            skip_next = False
            continue
        if val == "esac":
            # Checked ahead of the pattern state: `esac` arrives exactly
            # where a pattern would, and a case block that never closes
            # swallows the rest of the file.
            if case_stack:
                case_stack.pop()
            cmd_pos = False
            continue
        if case_stack and case_stack[-1] == "subject":
            if val == "in":
                case_stack[-1] = "pattern"
            continue
        if case_stack and case_stack[-1] == "pattern":
            continue
        if not cmd_pos:
            continue
        if skip_flags and val.startswith("-"):
            continue
        skip_flags = False
        if val == "case":
            case_stack.append("subject")
            cmd_pos = False
            continue
        if val in PREFIXES:
            skip_flags = val in FLAG_TAKING_PREFIXES
            if val in EXTERNAL_PREFIXES:
                scan.commands.add(val)
            continue
        if ASSIGNMENT_RE.match(val):
            # `IFS= read -r line`: an assignment prefixes a command.
            continue
        if val in NOT_A_COMMAND_NEXT or val in BUILTINS:
            cmd_pos = False
            continue
        cmd_pos = False
        if val in funcs:
            continue
        if val[0] in "$\"'-":
            # An expansion or a quoted path: whatever it runs is decided at
            # run time, not here, and every such word in this repo is a
            # path into the repo itself.
            continue
        if "/" in val:
            scan.paths.add(val)
            continue
        if COMMAND_NAME_RE.match(val):
            scan.commands.add(val)
            continue
        scan.unclassified.append((line, val))


# --- Claim A: runtime tools ------------------------------------------------


def read_allowlist(path):
    """name -> marker ("" for a tool the user installs, "base" for one that
    ships with macOS, "bundled" for one the runner tarball brings)."""
    entries = {}
    with open(path, "r") as fh:
        for raw in fh:
            body, _, comment = raw.partition("#")
            name = body.strip()
            if not name:
                continue
            marker = comment.split()[0] if comment.split() else ""
            entries[name] = marker if marker in (BASE_MARKER, BUNDLED_MARKER) else ""
    return entries


def check_runtime_tools(bin_dir, allowlist_path):
    """Both directions: nothing invoked is unlisted, nothing listed is unused."""
    failures = []
    entries = read_allowlist(allowlist_path)
    names = sorted(
        f for f in os.listdir(bin_dir) if os.path.isfile(os.path.join(bin_dir, f))
    )
    found = {}
    used = set()
    for name in names:
        scan = scan_file(os.path.join(bin_dir, name))
        found[name] = sorted(scan.commands | scan.paths)
        used |= scan.commands | scan.paths
        for line, word in scan.unclassified:
            failures.append(
                "%s:%d: unclassified word %r — the scanner will not guess "
                "whether it is a command" % (name, line, word)
            )
    for tool in sorted(used):
        if tool not in entries:
            failures.append(
                "%s is invoked by bin/ but is not on %s"
                % (tool, os.path.basename(allowlist_path))
            )
    for tool in sorted(entries):
        if tool not in used:
            failures.append(
                "%s is on %s but no script under bin/ uses it — a stale claim"
                % (tool, os.path.basename(allowlist_path))
            )
    facts = {
        "runtime_tools": sorted(t for t in used if entries.get(t, "") == ""),
        "base_tools": sorted(t for t in used if entries.get(t) == BASE_MARKER),
        "bundled_tools": sorted(t for t in used if entries.get(t) == BUNDLED_MARKER),
        "scanned": names,
        "per_file": found,
    }
    return failures, facts


# --- Claim B: no inbound port ----------------------------------------------

# Case-sensitive on purpose: `Runner.Listener` is the runner's own binary
# name, not a socket, and lowercase `listen` must not match it.
LISTENER_NEEDLES = [
    "nc -l",
    "ncat",
    "socat",
    "http.server",
    "SimpleHTTPServer",
    "listen",
    "Listeners",
    "Sockets",
    "python3 -m http",
    "ruby -run",
    "php -S",
    "--port",
    "--listen",
]


def shipped_files(repo_root):
    out = []
    for rel in ("bin", "templates", "examples"):
        d = os.path.join(repo_root, rel)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                if os.path.isfile(p):
                    out.append(p)
    action = os.path.join(repo_root, "action.yml")
    if os.path.isfile(action):
        out.append(action)
    return out


def check_no_inbound_port(repo_root):
    failures = []
    for path in shipped_files(repo_root):
        with open(path, "r") as fh:
            lines = fh.read().splitlines()
        for number, line in enumerate(lines, 1):
            for needle in LISTENER_NEEDLES:
                if needle in line:
                    failures.append(
                        "%s:%d: %r opens or names a listening socket"
                        % (os.path.relpath(path, repo_root), number, needle)
                    )
    return failures


# --- Claim C: no long-lived secret -----------------------------------------

SECRET_INPUT_RE = re.compile(r"token|secret|password", re.IGNORECASE)
ALLOWED_WORKFLOW_SECRETS = {"GITHUB_TOKEN", "TRAFFIC_TOKEN"}
WORKFLOW_SECRET_RE = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")


def _segments(tokens):
    """Simple commands: the words between two separators, with the
    redirections that command carries."""
    segs = []
    words, redirects, line = [], [], 0
    skip_next = False
    for kind, val, tline in tokens:
        if kind == "redirect":
            redirects.append(val)
            skip_next = True
            continue
        if kind == "op":
            if words:
                segs.append((line, words, redirects))
            words, redirects = [], []
            skip_next = False
            continue
        if skip_next:
            skip_next = False
            continue
        if not words:
            line = tline
        words.append(val)
    if words:
        segs.append((line, words, redirects))
    return segs


def token_variable(text, source_hint):
    """The variable an installer puts a short-lived GitHub token in, read
    off the code rather than assumed."""
    for tokens in token_streams(text):
        for line, words, _ in _segments(tokens):
            if words and ASSIGNMENT_RE.match(words[0]) and source_hint in words[0]:
                return words[0].split("=", 1)[0].rstrip("+")
    return None


def check_token_never_written(path, source_hint, rel):
    """Every use of the token variable is a guard, its own assignment from
    `gh api`, or the config.sh command line — and none of them redirects to
    a file."""
    failures = []
    with open(path, "r") as fh:
        text = fh.read()
    var = token_variable(text, source_hint)
    if var is None:
        return ["%s: no assignment of a %s found — cannot judge the claim" % (rel, source_hint)], None
    refs = ("$" + var, "${" + var + "}")
    seen_config = False
    for tokens in token_streams(text):
        for line, words, redirects in _segments(tokens):
            if not any(ref in w for w in words for ref in refs):
                continue
            head = words[0]
            file_redirects = [r for r in redirects if "&" not in r]
            if file_redirects:
                failures.append(
                    "%s:%d: a command handling %s redirects to a file (%s)"
                    % (rel, line, var, " ".join(file_redirects))
                )
            if ASSIGNMENT_RE.match(head) and head.split("=", 1)[0].rstrip("+") == var:
                if "gh api" not in head:
                    failures.append(
                        "%s:%d: %s is assigned from something other than `gh api`"
                        % (rel, line, var)
                    )
                continue
            if head in ("[", "test"):
                continue
            if head.endswith("config.sh") and "--token" in words:
                seen_config = True
                continue
            failures.append(
                "%s:%d: %s reaches `%s`, which is neither a guard nor the "
                "config.sh command line" % (rel, line, var, head)
            )
    if not seen_config:
        failures.append(
            "%s: %s never reaches a config.sh --token command line — the "
            "claim describes code that is no longer there" % (rel, var)
        )
    return failures, var


def check_action_declares_no_secret(repo_root):
    failures = []
    path = os.path.join(repo_root, "action.yml")
    if not os.path.isfile(path):
        return ["action.yml is missing — cannot judge the claim"]
    with open(path, "r") as fh:
        lines = fh.read().splitlines()
    in_inputs = False
    for number, line in enumerate(lines, 1):
        if "secrets." in line:
            failures.append("action.yml:%d: reads a repository secret" % number)
        if re.match(r"^[A-Za-z_]", line):
            in_inputs = line.startswith("inputs:")
            continue
        if in_inputs:
            m = re.match(r"^  ([A-Za-z_][A-Za-z0-9_]*):", line)
            if m and SECRET_INPUT_RE.search(m.group(1)):
                failures.append(
                    "action.yml:%d: input %r asks the caller for a secret"
                    % (number, m.group(1))
                )
    return failures


def check_workflow_secrets(repo_root):
    failures = []
    path = os.path.join(repo_root, ".github", "workflows", "ci.yml")
    if not os.path.isfile(path):
        return [".github/workflows/ci.yml is missing — cannot judge the claim"]
    with open(path, "r") as fh:
        lines = fh.read().splitlines()
    for number, line in enumerate(lines, 1):
        for name in WORKFLOW_SECRET_RE.findall(line):
            if name not in ALLOWED_WORKFLOW_SECRETS:
                failures.append(
                    "ci.yml:%d: uses secrets.%s, which is a secret someone "
                    "has to rotate" % (number, name)
                )
    return failures


def check_no_long_lived_secret(repo_root):
    failures = []
    installer = os.path.join(repo_root, "bin", "install-runner.sh")
    if not os.path.isfile(installer):
        return ["bin/install-runner.sh is missing — cannot judge the claim"]
    installer_failures, _ = check_token_never_written(
        installer, "registration-token", "bin/install-runner.sh"
    )
    failures.extend(installer_failures)
    uninstaller = os.path.join(repo_root, "bin", "uninstall-runner.sh")
    if os.path.isfile(uninstaller):
        uninstall_failures, _ = check_token_never_written(
            uninstaller, "remove-token", "bin/uninstall-runner.sh"
        )
        failures.extend(uninstall_failures)
    failures.extend(check_action_declares_no_secret(repo_root))
    failures.extend(check_workflow_secrets(repo_root))
    return failures


# --- Badges ----------------------------------------------------------------


def write_badge(badge_dir, name, label, message, color):
    path = os.path.join(badge_dir, name)
    with open(path, "w") as fh:
        json.dump(
            {"schemaVersion": 1, "label": label, "message": message, "color": color},
            fh,
            sort_keys=True,
        )
        fh.write("\n")
    return path


# --- CLI -------------------------------------------------------------------


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.dirname(os.path.dirname(here))
    parser = argparse.ArgumentParser(description="prove the README's claim badges")
    parser.add_argument("--repo-root", default=default_root)
    parser.add_argument("--bin-dir", default=None)
    parser.add_argument("--allowlist", default=None)
    parser.add_argument("--claim", default="all", choices=("all", "tools", "ports", "secrets"))
    parser.add_argument("--facts", default=None)
    parser.add_argument("--badges", default=None)
    parser.add_argument("--report", action="store_true", help="print the commands found per file")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.repo_root)
    bin_dir = args.bin_dir or os.path.join(root, "bin")
    allowlist = args.allowlist or os.path.join(root, "tests", "claims", "runtime-tools.txt")
    want = args.claim
    if args.badges:
        os.makedirs(args.badges, exist_ok=True)

    failed = False
    facts = {}

    if want in ("all", "tools"):
        try:
            failures, facts = check_runtime_tools(bin_dir, allowlist)
        except ScanError as exc:
            failures, facts = ["runtime tools: %s" % exc], {}
        if args.report:
            for name, cmds in sorted(facts.get("per_file", {}).items()):
                print("%s: %s" % (name, " ".join(cmds)))
        _report("runtime tools", failures)
        if failures:
            failed = True
        elif args.badges:
            write_badge(
                args.badges,
                "runtime-tools.json",
                "runtime tools",
                " · ".join(facts["runtime_tools"]) or "0",
                "blue",
            )

    if want in ("all", "ports"):
        failures = check_no_inbound_port(root)
        _report("inbound ports", failures)
        if failures:
            failed = True
        elif args.badges:
            write_badge(args.badges, "inbound-ports.json", "inbound ports", "0", "brightgreen")

    if want in ("all", "secrets"):
        try:
            failures = check_no_long_lived_secret(root)
        except ScanError as exc:
            failures = ["secrets to rotate: %s" % exc]
        _report("secrets to rotate", failures)
        if failures:
            failed = True
        elif args.badges:
            write_badge(
                args.badges, "secrets-to-rotate.json", "secrets to rotate", "0", "brightgreen"
            )

    if args.facts and facts:
        published = dict(facts)
        published.pop("per_file", None)
        with open(args.facts, "w") as fh:
            json.dump(published, fh, indent=2, sort_keys=True)
            fh.write("\n")

    return 1 if failed else 0


def _report(claim, failures):
    if failures:
        print("%s: NOT PROVEN" % claim, file=sys.stderr)
        for line in failures:
            print("  - %s" % line, file=sys.stderr)
    else:
        print("%s: proven" % claim)


if __name__ == "__main__":
    sys.exit(main())
