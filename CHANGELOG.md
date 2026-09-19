# Changelog

One line per merged change, newest first. No version numbers here.

- The same pre-commit hooks run locally and in CI from one config: secrets, shellcheck, markdown lint. CI also scans the whole history for secrets and lints the workflows.
- A push to main writes four public counters (clones over 14 days, npm and PyPI downloads over 30 days, and their total) as badge data; nothing runs on a user's machine to report anything.
- The project is pierless, formerly gangplank: the command, every PIERLESS_ variable, the state dir ~/.pierless, the runner label and the launchd label pierless.runner change with it; an existing runner is uninstalled with the old copy and installed again with this one.
- The coverage badge reads the published number through the badge service (the old link pointed one folder too high and never rendered), and the zero-is-good badges carry a colour each instead of one grey.
- A plist whose log path plutil cannot read gets its log folder from the fallback reader on macOS 14 too; plutil there prints its error on stdout, and only its exit status is trusted now.
- A stale lock with no pid file is aged correctly on Linux too; the old stat call read the mount point there and aborted the deploy.
- Tests for every parking, restore, resume and log-dir path in deploy.sh; the coverage checker's --list-uncovered prints the changed lines a PR still misses.
- The code: gate, deploy step as a composite action, installer, CLI, tests, CI and coverage config.
- The deploy hook plist step creates a plist's StandardOutPath/StandardErrorPath directories before bootstrapping it.
- Hook and prune runs resume from the last completed SHA after a crash, even on a run that pulls nothing new (PIERLESS_STATE_DIR/last-hooked-sha).
- Deploy only parks a dirty tree once it knows a fast-forward is happening, pops the stash back if that fast-forward then fails, and can run a PIERLESS_ON_PARK/on_park command once a parked deploy lands.
- Contribution runbook, CI and test plan, PR template.
- README with the system and deploy diagrams.
