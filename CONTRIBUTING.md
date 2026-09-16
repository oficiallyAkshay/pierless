# Contributing

pierless is a few hundred lines of shell and one workflow file. Keeping it that small is the point. The bar for a change: it makes a deploy safer, or the tool simpler.

## The runbook for a change

1. **Branch** from `main`. Name it for the outcome, not the file.
2. **Say what changes for the person running it** in one sentence before you write code. If you cannot, the change is not ready.
3. **Write the test first**, in `tests/`. Tests spawn the real script with a temp repo and stubbed `launchctl`/`gh`; they never reimplement a script's logic. A gate change gets a refuse case and an allow case.
4. **Run the local checks**: `make check` runs shellcheck, actionlint, the tests, and coverage, the same commands CI runs.
5. **Open the PR** with the template filled in: what changes for the operator, what does not change, how to undo it.
6. **CI must be green** on every check before merge. Nothing is merged with a check skipped.
7. **No release labels, no version bumps in PRs.** Releases are cut separately; a PR never carries release metadata.

## What CI runs

Every check runs in parallel on each PR; a typical run finishes in under two minutes.

| Check | Runs on | Blocks merge |
|---|---|---|
| shellcheck, `--severity=error`, every script | Linux | yes |
| actionlint, every workflow file | Linux | yes |
| tests: gate, deploy script, installer dry-run, workflow shape | Linux and macOS | yes |
| coverage: bash line tracing over the test run, changed lines at or above 90 percent, badge published on main | Linux | yes |
| plist lint for the launchd definition | macOS | yes |
| `ci` gate: passes only when every check above reports success | Linux | yes, and it is the only check merge asks for |

The checks above feed the gate, which fails on any one of them that is red, skipped or cancelled. That is why the branch rule names one context and not six: a check added later is covered the moment it is wired into the gate's `needs:`, and `tests/workflow.test.sh` fails if one is left out.

The macOS job is the only one that touches launchd, and only in dry-run. Nothing in CI registers a runner or talks to a real repo.

## Test plan a change must satisfy

| Area | Must be covered |
|---|---|
| Gate | allow on the exact workflow, branch, event, job and repository; refuse on each mismatch and on each missing variable; refuse on a branch named with the allowed branch as a prefix |
| Deploy script | fast-forward, diverged, dirty tree parked, stranded branch healed, hook failure exits non-zero after the remaining hooks run, second run waits on the lock |
| Hooks | install only where a manifest changed; load a new daemon definition; unload one renamed to disabled; the runner's own definition is never reloaded from inside a deploy |
| Installer | dry-run creates nothing and prints every action with the token redacted; checksum mismatch refuses; verify step fails when the gate on disk differs from the repo copy |
| Workflow | the queue never cancels a running deploy; the failure command runs once; the recovery command runs only after a real pull |

## Rules that keep it small

- The gate makes no network calls and runs no external command beyond bash builtins. It has no timeout, so it must finish on its own.
- No new runtime dependencies. bash, git, and the GitHub runner, nothing else.
- Every machine-specific value comes from the config file or the environment. Nothing in the code names a person, a channel, or a host.
- A comment explains why, never what. If the what needs a comment, the code is wrong.

## Reporting a problem

Open an issue with the failing step's output from the GitHub run and the output of `pierless status`. Never paste anything from your `.env`.

## Releasing

Releases are cut from a tag, not from a PR. First merge a PR that sets `PIERLESS_VERSION` in `action.yml` to the version you are about to release (a later change adds that line to the deploy step's `env`); `scripts/release/check-pin.sh` refuses the release when that value is missing or names a different version, so the composite action can never point at code the tag did not publish. Then push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.

`.github/workflows/release.yml` takes it from there. It checks the pin, runs the whole suite, copies `bin/` and `templates/` into both package trees with `scripts/release/stage.sh`, stamps the version into `package.json` and `pyproject.toml`, publishes `pierless` to npm and to PyPI, cuts the GitHub release with the CHANGELOG lines added since the previous version tag, and only then moves the floating `v0` tag onto the new commit. Both registries are reached by trusted publishing, which means an OIDC token minted for that workflow file and its `release` environment: nothing long-lived is stored in this repo, and there is no token to rotate.

The owner does the manual half once, before the first tag. npm has no pending-publisher flow, so the first version must be published by hand: `npm login`, then `npm publish` from a staged `packages/npm`. After that, on npmjs.com, add a trusted publisher to the package for this repository, workflow `release.yml`, environment `release`. On PyPI the same pair is registered up front as a pending publisher for the name `pierless`, with the same workflow file and environment, and the first tag then claims the name. Both the workflow filename and the environment name are part of what the registries trust, so renaming either one means updating the publisher entry on both sites.

## License

By contributing you agree your work is released under the MIT license in this repo.
