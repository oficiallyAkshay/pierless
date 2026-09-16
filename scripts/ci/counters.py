#!/usr/bin/env python3
# scripts/ci/counters.py — reads three public counters (GitHub clones over
# the trailing 14 days, npm and PyPI downloads over the trailing 30 days)
# and writes one shields endpoint JSON per counter plus a combined
# "installs" badge. CI runs this on a push to main; nothing in pierless
# itself ever reports anything from a user's machine, so these registry
# and traffic counters are the only usage signal that exists.
#
# A source that cannot be read never costs the badges their value: the
# last published number is reused (read back out of --previous), or 0 is
# used, a ::warning:: explains why, and the run exits 1 so the job stays
# red until the owner fixes the cause while the badges still update.
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT = 20
USER_AGENT = "pierless-counters (+https://github.com/oficiallyAkshay/pierless)"
COLOR = "blue"

# name (as --source names it), output file stem, badge label
SOURCES = (
    ("clones", "clones-14d", "clones (14d)"),
    ("npm", "npm-30d", "npm (30d)"),
    ("pypi", "pypi-30d", "pypi (30d)"),
)

EPILOG = """windows:
  clones (14d)  GitHub's traffic API keeps a trailing 14-day window and
                nothing longer; `count` is every clone in it.
  npm (30d)     npm's downloads point API, last-month = trailing 30 days.
  pypi (30d)    pypistats' recent endpoint, data.last_month = trailing 30
                days. pypistats asks callers not to hit an endpoint more
                than once a day and rate-limits by IP, so this runs on a
                push to main and never on a schedule.

privacy:
  Nothing is collected from users' machines. pierless has no telemetry
  and makes no call home; every number here is a public counter GitHub,
  npm and PyPI already publish, read by CI and written back as badge data.
"""


class Missing(Exception):
    """A counter could not be read; str(exc) is the reason in the warning."""


def read_json(url, headers, source_file):
    if source_file is not None:
        with open(source_file) as f:
            payload = json.load(f)
        # A fixture may stand in for an HTTP error, and raising the real
        # exception keeps the error path under test identical to the live one.
        if isinstance(payload, dict) and "http_status" in payload:
            status = int(payload["http_status"])
            raise urllib.error.HTTPError(url, status, f"HTTP {status}", None, None)
        return payload
    request = urllib.request.Request(url, headers=dict(headers, **{"User-Agent": USER_AGENT}))
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.loads(response.read().decode("utf-8"))


def read_count(service, url, headers, source_file, path, status_reasons):
    try:
        payload = read_json(url, headers, source_file)
    except urllib.error.HTTPError as exc:
        raise Missing(status_reasons.get(exc.code, f"{service} returned HTTP {exc.code}"))
    except urllib.error.URLError as exc:
        raise Missing(f"{service} could not be reached ({exc.reason})")
    except (OSError, ValueError) as exc:
        raise Missing(f"{service} gave a response that could not be read ({exc})")

    dotted = ".".join(path)
    node = payload
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise Missing(f"{service} returned no {dotted}")
        node = node[key]
    if isinstance(node, bool) or not isinstance(node, (int, float)):
        raise Missing(f"{service} returned a non-numeric {dotted}")
    return int(node)


def fetch_clones(repo, source_file):
    token = os.environ.get("TRAFFIC_TOKEN", "").strip()
    # Read before the --source override, so an unset token can never turn
    # into an unauthenticated call and so the missing-token path stays
    # reachable in a test that hands every source a fixture file.
    if not token:
        raise Missing("TRAFFIC_TOKEN is not set")
    return read_count(
        "the GitHub traffic API",
        f"https://api.github.com/repos/{repo}/traffic/clones",
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        source_file,
        ("count",),
        {},
    )


def fetch_npm(name, source_file):
    return read_count(
        "npm",
        f"https://api.npmjs.org/downloads/point/last-month/{name}",
        {},
        source_file,
        ("downloads",),
        {404: f"npm has no package named {name} yet (HTTP 404)"},
    )


def fetch_pypi(name, source_file):
    return read_count(
        "pypistats",
        f"https://pypistats.org/api/packages/{name}/recent",
        {},
        source_file,
        ("data", "last_month"),
        {
            404: f"PyPI has no package named {name} yet (HTTP 404)",
            429: "pypistats rate-limits by IP and throttled this run (HTTP 429)",
        },
    )


def compact(n):
    # Integer arithmetic on tenths: floats round 12345 to 12.299999... and
    # print a digit nobody asked for.
    if n < 1000:
        return str(n)
    tenths = (n + 50) // 100
    whole, frac = tenths // 10, tenths % 10
    return f"{whole}k" if frac == 0 else f"{whole}.{frac}k"


def previous_value(previous_dir, filename):
    if not previous_dir:
        return None
    try:
        with open(os.path.join(previous_dir, filename)) as f:
            raw = json.load(f).get("raw")
    except (OSError, ValueError, AttributeError):
        return None
    return raw if isinstance(raw, int) and not isinstance(raw, bool) else None


def write_json(path, payload):
    with open(path, "w") as f:
        f.write(json.dumps(payload) + "\n")


def main():
    parser = argparse.ArgumentParser(
        prog="counters.py",
        description="Read three public usage counters and write shields endpoint JSON for them.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--repo", required=True, help="owner/name whose clone traffic is read")
    parser.add_argument("--npm", required=True, help="npm package name")
    parser.add_argument("--pypi", required=True, help="PyPI package name")
    parser.add_argument("--out", required=True, help="directory the badge JSON is written to")
    parser.add_argument("--previous", help="directory holding the last run's badge JSON, used when a source is missing")
    parser.add_argument(
        "--source", action="append", default=[], metavar="NAME=FILE",
        help="read NAME (clones, npm, pypi) from FILE instead of over the network",
    )
    args = parser.parse_args()

    names = [name for name, _, _ in SOURCES]
    overrides = {}
    for item in args.source:
        name, sep, path = item.partition("=")
        if not sep or name not in names:
            parser.error(f"--source takes clones=FILE, npm=FILE or pypi=FILE, got {item!r}")
        overrides[name] = path

    fetchers = {
        "clones": lambda source_file: fetch_clones(args.repo, source_file),
        "npm": lambda source_file: fetch_npm(args.npm, source_file),
        "pypi": lambda source_file: fetch_pypi(args.pypi, source_file),
    }

    os.makedirs(args.out, exist_ok=True)
    values, states = {}, {}
    for name, stem, label in SOURCES:
        filename = stem + ".json"
        try:
            values[name], states[name] = fetchers[name](overrides.get(name)), "live"
        except Missing as exc:
            previous = previous_value(args.previous, filename)
            if previous is None:
                values[name], states[name] = 0, "zero"
                print(f"::warning::{name}: {exc}; no previous value, using 0")
            else:
                values[name], states[name] = previous, "reused"
                print(f"::warning::{name}: {exc}; reusing previous value {previous}")
        write_json(os.path.join(args.out, filename), {
            "schemaVersion": 1,
            "label": label,
            "message": str(values[name]),
            "color": COLOR,
            "raw": values[name],
        })

    total = sum(values.values())
    write_json(os.path.join(args.out, "installs.json"), {
        "schemaVersion": 1,
        "label": "installs",
        "message": f"{compact(total)} · 30d + clones 14d",
        "color": COLOR,
        "raw": {
            "clones_14d": values["clones"],
            "npm_30d": values["npm"],
            "pypi_30d": values["pypi"],
            "total": total,
        },
    })

    for name, stem, _ in SOURCES:
        print(f"{stem}={values[name]} ({states[name]})")

    return 0 if all(state == "live" for state in states.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
