<h1 align="center">⚓ pierless</h1>

<p align="center"><b>Merge to main. Your Mac is running it seconds later.</b></p>

<p align="center"><img alt="Merge it. Pierless takes it from there: it deploys instantly, fixes stuck deploys and dropped daemons on its own, reinstalls only what changed, and stays quiet unless something is red. No pier, no port: it drops anchor itself" src="assets/readme/hero.svg" width="900"></p>

<p align="center">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/license-MIT-2f6f4e?logo=opensourceinitiative&logoColor=white"></a>
  <a href="CONTRIBUTING.md#what-ci-runs"><img alt="coverage" src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/badges/coverage.json"></a>
  <a href="#security-and-limits"><img alt="inbound ports" src="https://img.shields.io/badge/inbound%20ports-0-brightgreen"></a>
  <a href="#security-and-limits"><img alt="secrets to rotate" src="https://img.shields.io/badge/secrets%20to%20rotate-0-blueviolet"></a>
  <a href="#security-and-limits"><img alt="runtime dependencies" src="https://img.shields.io/badge/runtime%20dependencies-0-ff69b4"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/oficiallyAkshay/pierless"><img alt="OpenSSF Scorecard" src="https://api.scorecard.dev/projects/github.com/oficiallyAkshay/pierless/badge"></a>
</p>

<p align="center">
  <a href="https://github.com/oficiallyAkshay/clonometer"><img alt="clones of this repository, last seven days and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white"></a>
  <a href="#badges"><img alt="views of this repository, last seven days and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.badge&label=views&logo=github&logoColor=white"></a>
</p>

pierless turns a GitHub self-hosted runner into a deploy-only agent for one Mac: the Mac that runs your agents, daemons, loops, and dashboards.

## Features

- 🚀 **Deploys in seconds.** Merge to main, and your Mac is running it before you have switched tabs.
- 🖥️ **Built for your Mac.** One box, registered once, kept on the workflow and branch you named.
- 🩹 **Heals itself.** A stranded branch or a dropped daemon is put right on the next run, no page needed.
- 🔒 **Nothing listens.** No inbound port, no tunnel, no secret to rotate.
- ✅ **Claims are proven.** Inbound ports, secrets to rotate and runtime tools are checked by a test on every run, not typed by hand.

## Fit

Use it when:

- Your Mac already runs a GitHub Actions self-hosted runner for a private repo.
- You want a merge to reach it in seconds, without opening a port or keeping a deploy key.
- A stuck deploy or a dropped daemon should heal itself, not page you.

Look elsewhere when:

- Your target is Linux or Windows: pierless is built on launchd, macOS only.
- You deploy containers across a fleet of servers: [basecamp/kamal](https://github.com/basecamp/kamal) fits that shape.
- You want the runner and the gate built for you, with nothing to script: pierless is the script.

Install it by cloning this repo onto the Mac and running its install command, which registers the runner and puts the gate outside every checkout so no branch can edit it. Add `oficiallyAkshay/pierless@v1` to your own deploy workflow next; every option is documented in `examples/deploy.yml`.

## How it compares

| | [oficiallyAkshay/pierless](https://github.com/oficiallyAkshay/pierless) | [basecamp/kamal](https://github.com/basecamp/kamal) | [actions/runner](https://github.com/actions/runner) |
| --- | --- | --- | --- |
| Installation | Shell | Gem | Binary |
| Target | Your Mac | Any server | Any machine |
| Container runtime | None | Docker | None |
| Inbound port | None | SSH | None |
| Self-heal | ✅ | ❌ | ❌ |

## Security and limits

The installer needs `gh` signed in once. It mints a runner registration token, used immediately and never written to disk. The deploy step uses only `GITHUB_TOKEN`. It already has one, granted to its own run.

- ❌ opens an inbound port
- ❌ calls out before the gate decides whether a job may run
- ❌ force-resets a diverged checkout
- ❌ overwrites uncommitted edits it has not just stashed
- ❌ writes the runner's registration token to disk
- ❌ sends telemetry

By default a failed deploy runs nothing. `on_failure` names the alert, `on_recovery` the all-clear. By default finished worktrees are pruned; `prune_worktrees: false` keeps them. By default dependencies reinstall only where a manifest changed; `install: none` turns that off.

## Badges

Click a badge for its recipe; Both is the recommended shape.

<table width="100%">
  <tr>
    <th></th>
    <th align="center">This week</th>
    <th align="center">All time</th>
    <th align="center">Both</th>
  </tr>
  <tr>
    <th align="left">Clones</th>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.last7_short&label=clones&suffix=%20this%20week&logo=github&logoColor=white"><img alt="Clones, this week" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.last7_short&label=clones&suffix=%20this%20week&logo=github&logoColor=white"></a></td>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.total_short&label=clones&suffix=%20all-time&logo=github&logoColor=white"><img alt="Clones, all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.total_short&label=clones&suffix=%20all-time&logo=github&logoColor=white"></a></td>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white"><img alt="Clones, this week and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/clones.json&query=$.badge&label=clones&logo=github&logoColor=white"></a></td>
  </tr>
  <tr>
    <th align="left">Views</th>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.last7_short&label=views&suffix=%20this%20week&logo=github&logoColor=white"><img alt="Views, this week" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.last7_short&label=views&suffix=%20this%20week&logo=github&logoColor=white"></a></td>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.total_short&label=views&suffix=%20all-time&logo=github&logoColor=white"><img alt="Views, all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.total_short&label=views&suffix=%20all-time&logo=github&logoColor=white"></a></td>
    <td align="center"><a href="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.badge&label=views&logo=github&logoColor=white"><img alt="Views, this week and all time" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/oficiallyAkshay/pierless/badges/views.json&query=$.badge&label=views&logo=github&logoColor=white"></a></td>
  </tr>
</table>
