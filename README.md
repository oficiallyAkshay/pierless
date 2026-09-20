# pierless

Merge to main. Your Mac is running it seconds later. No open port, no tunnel, no secret to rotate.

<p align="center"><img alt="Merge it. Pierless takes it from there: it deploys instantly, fixes stuck deploys and dropped daemons on its own, reinstalls only what changed, and stays quiet unless something is red. No pier, no port: it drops anchor itself" src="assets/readme/hero.svg" width="900"></p>

![inbound ports](https://img.shields.io/badge/inbound%20ports-0-brightgreen) ![secrets to rotate](https://img.shields.io/badge/secrets%20to%20rotate-0-blueviolet) ![runtime dependencies](https://img.shields.io/badge/runtime%20dependencies-0-ff69b4) ![platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20launchd-blue) ![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen) ![coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FoficiallyAkshay%2Fpierless%2Fbadges%2Fbadges%2Fcoverage.json) ![clones](<https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white>) ![license](https://img.shields.io/badge/license-MIT-orange)

pierless turns a GitHub self-hosted runner into a deploy-only agent for one Mac: the Mac that runs your agents, daemons, loops, and dashboards.

Two things stay true at once. Merged PRs land on the box by themselves. Edits you make by hand on the box are never overwritten and never block a deploy.

## What it adds

The runner and git move the bytes. pierless adds the rules:

- **One door.** The gate refuses every job except one workflow on one branch. Fails closed. No network calls.
- **Never force.** Diverged, fetch failed, cannot fast-forward: the run goes red and says why. No reset, ever.
- **Park, never overwrite.** Uncommitted edits on the box go into a named stash, only when a pull is actually happening. If the pull fails, they come straight back.
- **Self-heal.** A box stranded on a squash-merged branch is put back on main and deployed.
- **Install only what moved.** Dependencies reinstall only where a manifest changed.
- **Daemons ship with their code.** A new or changed launchd plist loads on the deploy that carries it. Rename it to `.disabled` and it unloads.
- **Kick what launchd drops.** Coalesced file events lose a restart; pierless kicks the daemon you name.
- **Prune finished worktrees.** Only when the PR merged, the tree is clean, and no session holds it.
- **Alert on failure only.** Your command runs once on a red deploy, your recovery command once on the next green. Silence otherwise.

## Use it

On the Mac, once:

```bash
git clone https://github.com/oficiallyAkshay/pierless ~/.pierless/src
~/.pierless/src/bin/pierless install --repo you/your-repo
```

Registers the runner, runs it under launchd, and installs the gate outside every checkout so no branch can edit it. The other verbs: `status`, `dry-run`, `uninstall`.

In your repo, `.github/workflows/deploy.yml` (every option in `examples/deploy.yml`):

```yaml
on:
  push: { branches: [main] }
  schedule: [{ cron: "17 * * * *" }]
concurrency: { group: deploy, cancel-in-progress: false }
jobs:
  deploy:
    runs-on: [self-hosted, macOS, pierless]
    steps:
      - uses: oficiallyAkshay/pierless@v0
        with:
          repo: /Users/you/your-checkout
```

Done.

## How it sits

Nothing on the Mac listens. The runner asks GitHub for work; the gate decides whether it may run.

```mermaid
flowchart LR
  subgraph GH[GitHub]
    PR[Pull request] -->|merge| M[main]
    M -->|push event| Q[Actions job queue]
  end
  subgraph MAC[Your Mac]
    R[Self-hosted runner<br/>launchd service] --> G{Gate<br/>one workflow, one branch}
    G -->|refused| X[Job fails before any step]
    G -->|allowed| D[Deploy script]
    D --> C[(Repo checkout)]
    D --> H[Hooks<br/>install deps · load daemons · kick]
    H --> S[launchd daemons]
  end
  Q -.->|outbound long-poll<br/>no inbound port| R
  D -->|only on failure| SL[Your alert command]
```


## One deploy

Every branch off the happy path ends red with its cause.

```mermaid
flowchart TD
  A[Job assigned to the runner] --> B{Gate<br/>deploy workflow on main?}
  B -- no --> B1[Refused. Red before any step]
  B -- yes --> C[Fetch, prune gone branches]
  C --> D{Checkout left on a<br/>squash-merged branch?}
  D -- yes --> D1[Switch back to main]
  D -- no --> E
  D1 --> E{Uncommitted edits?}
  E -- yes --> E1[Park under a named stash]
  E -- no --> F
  E1 --> F{Fast-forward possible?}
  F -- no, diverged --> F1[Stop. Red with the cause]
  F -- yes --> G[Fast-forward pull]
  G --> H[Install deps where a manifest changed]
  H --> I[Load new or changed daemons<br/>unload the ones renamed to disabled]
  I --> J[Kick the daemon launchd would coalesce]
  J --> K[Prune worktrees whose PR merged]
  K --> L{Any hook failed?}
  L -- yes --> L1[Red. Your alert command runs once]
  L -- no --> M[Green. Your recovery command runs if a failure preceded it]
```


## License

MIT
