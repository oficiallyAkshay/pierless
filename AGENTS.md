# AGENTS.md

The short version for an agent working in this repo. CONTRIBUTING.md carries the full runbook, CI shape and test plan; `docs/architecture.md` carries the two system diagrams.

## Before you change anything

- Branch off `main`. Nothing is committed straight to it.
- State what changes for the person running pierless, in one sentence, before writing code.
- Write the test first, in `tests/`. `tests/run.sh` runs every `tests/*.test.sh` file.

## Local checks, before every PR

`make hooks` once per clone, then `make check` (pre-commit hooks, actionlint, tests) and `make coverage` (adds the line-coverage gate). All three must pass.

## Rules that keep this repo small

- No new runtime dependency: bash, git and the GitHub runner, nothing else.
- The gate (`bin/job-started-gate.sh`) makes no network call and runs no external command.
- Every machine-specific value comes from config or the environment, never a hardcoded person, channel or host.
- No release labels or version bumps in a PR. Releases are cut from a tag, by the owner only.

## Where things live

- `bin/` the gate, the deploy script, the installer, the CLI.
- `action.yml` the composite action wrapping `bin/deploy.sh`.
- `tests/` one `*.test.sh` file per script.
- `.github/workflows/` `ci.yml` is the required gate; `release.yml`, `clonometer.yml`, `codeql.yml` and `scorecard.yml` run on their own triggers.
- `docs/architecture.md` the system and deploy-flow diagrams.

Full detail: CONTRIBUTING.md.
