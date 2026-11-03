# Architecture

Two diagrams, moved here from the README: how a merge reaches the Mac, and what one deploy run does step by step. Both are reference material for CONTRIBUTING.md, not the README's shape.

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

## Rolling back

Every pulled deploy writes the commit it left and the commit it reached on its `PULLED` log line, as `PIERLESS_FROM_SHA=` and `PIERLESS_TO_SHA=`. The action also returns them as the `from_sha` and `to_sha` outputs, and the `on_failure` command gets them as `PIERLESS_FROM_SHA` and `PIERLESS_TO_SHA`. Both are empty when the run pulled nothing. To find the last good commit, read the `PULLED` line in the deploy log (`~/.pierless/deploy.log` by default).

**Preferred: revert on main.** Revert the bad commit in a pull request and merge it. The next deploy pulls the revert like any other commit, so the Mac, its hooks and its marker all move forward together. Nothing on the Mac changes by hand.

**Manual: reset the Mac to a named commit.** Use this only while the revert is not merged yet. On the Mac, in the checkout, run `git reset --hard <PIERLESS_FROM_SHA>`. Three things to know, all as the script behaves today:

- The checkout is now behind `origin/main` again. The next deploy pulls the bad commit back unless the revert is on main by then.
- The script parks uncommitted edits in a stash named `pierless park` and never restores it. A reset does not restore it either. Run `git stash list` and apply what you need by hand.
- The script refuses a checkout that has diverged from `origin/main` (exit 4, a `DIVERGED` log line). A checkout that is only ahead is left alone (an `AHEAD` log line, exit 0). Do not commit on the Mac to roll back.

The hook marker (`last-hooked-sha` in the state directory) still names the last commit whose hooks finished. Hooks do not run for a reset. Run the install or daemon steps for the older commit by hand if the bad commit changed a manifest or a daemon definition.
