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
