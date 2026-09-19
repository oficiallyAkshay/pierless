# Handoff (throwaway)

Where work on this repo stopped on 2026-09-17 and what is next, collected from several build sessions. The newest entry wins where two disagree. Delete this file once the items are picked up; it is not documentation.

## pierless, formerly gangplank (from the clonometer session; see also memory `pierless-project.md`)

### What's left
- Adopt clonometer: add the ten-line consumer workflow pinned by SHA and the `$.badge` recipe badge. WARNING: pierless's CI already force-pushes an orphan `badges` branch holding only `badges/coverage.svg` and `badges/coverage.json`. Clonometer's default storage branch is also `badges`. Clonometer preserves files it finds on the branch, but pierless's coverage job rebuilds the branch from scratch, which would delete the ledger, and the next clonometer run would then see a 404 and restart the lifetime count at zero. Use `branch: clonometer` (or any other name) in pierless's workflow, or change pierless's coverage publish to preserve existing files the way clonometer's publish step does (fetch depth one, `git checkout FETCH_HEAD -- .`, then overwrite its own files).
- `TRAFFIC_TOKEN` on pierless: fine-grained, Administration read and Contents write, that repository only. One token scoped to several repos also works; paste it per repo.
- Still open from the pierless session (owner by hand): first manual `npm publish`, then the npm trusted publisher; PyPI pending publisher for `pierless`; tick "Publish this Action to the GitHub Marketplace" on the v0.2.0 release (2FA is now on, which that needs); the private consumer's second pin PR when v0.2.0 renames the env vars to `PIERLESS_*`.
- Self-fetch idea applies here too if the owner wants pierless's own clone count to measure runs: a bash step reading `github.action_repository` and `github.action_ref` through `env:` and a depth-one `git fetch` of the pinned commit; never `actions/checkout` with those contexts (it fetches itself).

### Learnings that carry over
- The gh token now has the workflow scope, so Dependabot bumps of workflow pins can be merged with `gh pr merge --auto --rebase`; pushing workflow files still needs gh's token in an `http.extraheader` because the keychain helper holds an older token.
- Group Dependabot updates (`groups: {actions: {patterns: ["*"]}}`) so a week is one PR per ecosystem.
- Cache `~/.cache/pre-commit` keyed on the hook config if a hook builds from source; it was 21 seconds of a 45 second job on clonometer.



---

## pierless, formerly gangplank (from the readmerlin build session, memory only, nothing verified live)

- Repo github.com/oficiallyAkshay/pierless, local clone `pierless`, plan file `~/.claude/plans/structured-marinating-popcorn.md`. Never reintroduce the gangplank name.
- Owner steps recorded as open: first manual `npm publish` then the npm trusted publisher (workflow release.yml, environment release); PyPI pending publisher for `pierless`; `TRAFFIC_TOKEN` secret; tick the Marketplace box on the v0.2.0 release.
- Ruleset "main" still required the six old job names until a single `ci` gate job lands. Check whether that happened.
- v0.2.0 renames env vars to `PIERLESS_*`. the private consumer repo then needs a second PR: bump the pin in `.github/workflows/deploy.yml`, rename `GANGPLANK_*` in `scripts/deploy-alert.sh` and `GANGPLANK_COMMITS` in deploy.yml. the private consumer PR #1557 re-pinned to the rewritten v0.1.1 commit; confirm it merged.
- Cross-repo adoption not started: clonometer consumer workflow and badge, a readmerlin pass over its README plus the readme-check workflow, a herofold hero once that skill exists.



---

## pierless, formerly gangplank (written by the pierless build session, 2026-09-17, paused by the owner mid-run)

### State
- Repo github.com/oficiallyAkshay/pierless (public, renamed from gangplank 2026-09-16: the old name was taken on npm, PyPI and as a GitHub org, which also blocks a Marketplace listing). Local clone `pierless`, worktrees under `.claude/worktrees/` (excluded via `.git/info/exclude`). Plan with contracts and citations: `~/.claude/plans/structured-marinating-popcorn.md`. Memory: `pierless-project.md`. Source handoff: the boomerang session scratchpad `GANGPLANK-HANDOFF.md`.
- Done: history rewritten with git-filter-repo mailmap (every commit on the no-reply identity, tags v0/v0.1.0/v0.1.1/v0.1.2 moved, v0.1.1 commit is now 60e44e5374e3ba01b99736454b439e3a2a4ad45e); legacy branch protection replaced by ruleset "main" id 23569212 (PR required, only required check `ci`, rebase merge only); squash off; topics set.
- Merged: #7 tree rename (gangplank to pierless, GANGPLANK_ to PIERLESS_, ~/.pierless, label pierless.runner), #8 `ci` gate job plus timeouts, #9 `scripts/ci/counters.py` plus tests (script only, not wired into ci.yml yet).
- the private consumer consumer fixed: the private consumer repo PR #1557 merged, deploy.yml pins `oficiallyAkshay/pierless@60e44e5…  # v0.1.1`. the consumer's own notes records the rename and what the v0.2.0 bump must change.

### Open PRs (nothing armed for auto-merge)
- **#12 claims** (`tests/claims.test.sh`, `scripts/ci/claims.py`, allowlist): verifier PASSED every item, rebased, green. Before merging: its commit trailer says `Claude Opus 5 (1M context)`; amend to `Claude Fable 5.1`, force-push with lease, then `gh pr merge 12 --auto --rebase`.
- **#11 pre-commit parity** (`.pre-commit-config.yaml`: gitleaks v8.30.1, shellcheck-py v0.11.0.1-1, markdownlint-cli2 v0.23.2; CI `checks` job replaces shellcheck and actionlint jobs; plist-lint folded into the macOS test leg; MD013, MD012, MD041 disabled with reasons in `.github/.markdownlint.jsonc`): built and green, NOT verified yet. Send a read-only verifier, then merge.
- **#10 packages** (npm and PyPI wrappers, `scripts/release/stage.sh`, `check-pin.sh`, `release.yml` with OIDC, `deploy` verb): Opus verifier FAILED it on three must-fix items, everything else passed:
  1. `scripts/ci/coverage-check.py:32` case-pattern rule is not scoped to `case` blocks; it wrongly excludes executed code at `bin/deploy.sh:243` (a continuation line ending in `)`).
  2. `scripts/ci/coverage-check.py:31` heredoc regex is unanchored: it matches the tail of `<<<word`, arithmetic `<<`, and `<<` inside strings or trailing comments, which would drop the rest of a file from the coverage denominator. Fix the header comment at lines 28-30 too.
  3. Both manifests are committed at `1.2.3` (the test fixture's version) instead of `0.0.0`, so the stamping assertions and stage.sh's read-back guard pass vacuously.
  Nice to have: negative tests for those regex cases, `chmod +x tests/packages.test.sh`, pin `npm@11` instead of `npm@latest`, make the release job re-runnable (`gh release create` is not idempotent).
- All three add a CHANGELOG line at the top, so each needs a rebase after another merges (GitHub runs no checks on a conflicting PR).

### What's left, in order
1. Fix and merge #10, verify and merge #11, amend and merge #12.
2. PR "secrets scan over history": in the `checks` job, checkout with `fetch-depth: 0`, `gitleaks/gitleaks-action` pinned by SHA (v3), `GITHUB_TOKEN` env, `pull-requests: read`; run `gitleaks git --no-banner .` locally first and stop on any finding rather than allowlisting.
3. PR "badges job": one job on push to main (needs coverage) writes coverage.json, the four counter files (`counters.py`, snippet in PR #9's body, `--previous` from the badges branch) and the three claim badges (`claims.py --badges`) in ONE commit to the orphan `badges` branch. Two jobs pushing that branch would race.
4. PR "dependency audit": `npm audit` on the staged package, `pip-audit` on the built wheel, blocking.
5. PR "the Action uses the package": `PIERLESS_VERSION: "X.Y.Z"` in action.yml's deploy step env; step runs `npx --yes pierless@$V deploy`, falls back to `uvx pierless@$V deploy`, fails loud naming node or uv; `branding` icon anchor, color blue; `tests/action.test.sh` still asserts no `uses:`; `check-pin.sh` already gates the release on this line.
6. PR "README" (conductor writes it, produce and check it with readmerlin): three-beat opening kept; badge row CI status, coverage, installs (endpoint `installs.json`, `logo=github`, links to the section), npm version, PyPI version, runtime tools, inbound ports, secrets to rotate, platform, license; install block becomes `npx pierless install --repo you/your-repo` and the uvx twin; short "How usage is counted" section (clones 14 days, npm and PyPI 30 days, refreshed on push to main only, nothing collected from users' machines, the Action needs node or uv on the runner Mac).
7. Release v0.2.0 (tag push runs release.yml), verify both one-liners from a clean shell, run the Action from a throwaway repo, read the first counters, closing report. Baseline reading 2026-09-16: 133 clones, 15 uniques over 14 days, mostly its own CI.
8. the private consumer PR 2 after v0.2.0: bump the pin, rename `GANGPLANK_*` in `scripts/deploy-alert.sh`, the `GANGPLANK_COMMITS` env and the `id: gangplank` step in deploy.yml, update the runner-gate test. the private consumer's gates need a `Map:` line in the PR body, the `smriti:pending` label swapped (used `smriti:incomplete:single-session-build-task`), and a one-bullet landing record under the consumer's own notes in the shape `- YYYY-MM-DD ET ,  map-sync ,  <branch>: …`, summary at most 400 bytes; arm auto-merge through the GraphQL mutation with SQUASH.
9. Owner decision to raise: clonometer now exists. pierless's `counters.py` reads the 14-day clone window itself; adopting the clonometer action would give a lifetime ledger and count pierless as a clonometer consumer. Decide before PR 3.
10. Owner steps: `npm login`, one manual `npm publish` of the staged package, then the trusted publisher on npmjs.com (workflow `release.yml`, environment `release`); PyPI pending publisher for `pierless` with the same pair; fine-grained PAT (Administration read, this repo) as secret `TRAFFIC_TOKEN`; tick "Publish this Action to the GitHub Marketplace" on the v0.2.0 release (2FA).



---

## pierless, formerly gangplank (from the hero skill session, live check only, 2026-09-17)

- The pierless build session's entry above is the authority. Follow its order and its verifier verdicts. This entry adds only what a live check showed.
- Live on 2026-09-17: repo public, local main equals origin at `abe8884`, tags stop at v0.1.2, PRs 10, 11 and 12 are all still open with green checks.
- Green checks do not mean mergeable. PR 10 failed its verifier on three must-fix items, PR 11 has no verifier yet, PR 12 passed and needs only the trailer amended. Details are in the build session's entry.
- The clonometer session's warning also stands: pierless force-pushes an orphan `badges` branch, so a clonometer adoption must use a different storage branch or a preserving publish step.
- Never reintroduce the gangplank name anywhere.



---

## Owner steps (from the cross-repo checklist)

| Repo | Step only the owner can do |
|---|---|
| pierless | `npm login` and publish; npm trusted publisher; PyPI pending publisher; `TRAFFIC_TOKEN`; Marketplace tick on v0.2.0 |

---

## pierless addendum (from the pierless session, answering the other sessions' open questions)

- Confirmed live: the single `ci` gate job landed (PR #8) and ruleset 23569212 now requires only `ci`. the private consumer PR #1557 merged on 2026-09-16 23:13 UTC.
- Badges branch constraint, agreeing with the clonometer session's warning: today the coverage job rebuilds the orphan `badges` branch from scratch on every push to main. The planned single badges job (pierless item 3) must instead fetch the branch, keep every file it finds, and add or replace only its own files. That is required if clonometer is adopted (its ledger lives on that branch) and harmless if not. Builder brief for that PR: start from `git fetch origin badges` into a temp worktree, never `git init` a fresh one; one commit per run; the `--previous` dir for `counters.py` is that same checkout.
- If clonometer is adopted, drop the clones fetcher from `counters.py` and have `installs.json` read clonometer's `clones.json` (`total` or `window.count`) from the same branch, so there is one source for clones. The label then changes from "clones 14d" to whatever window is chosen; update the "How usage is counted" section to match.
- Cross-repo adoption for pierless, none started: clonometer consumer workflow, a readmerlin pass plus its readme-check workflow (part of the README PR), a herofold hero.
- Dependabot: pierless has `.github/dependabot.yml` for github-actions only, ungrouped. Add the grouping the clonometer session recommends in the secrets-scan PR or its own small PR.


