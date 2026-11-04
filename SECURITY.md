# Security

## Supported versions

The current `main` branch and the latest tag. Nothing older gets a fix.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository:
<https://github.com/oficiallyAkshay/pierless/security/advisories/new>

Never open a public issue for a vulnerability. Expect an acknowledgement
within seven days.

## Scope

pierless runs a self-hosted GitHub Actions runner and a deploy gate on
one Mac. The only secrets it ever touches are the runner registration
token, used once at install time and never stored, and the
`GITHUB_TOKEN` the deploy workflow already has. The gate itself
makes no network calls and runs no external command beyond bash
builtins.

One residual risk: the runner downloads the `uses:` actions of a job into
`_work/_actions` before the gate runs, so a refused job can leave
downloaded files on disk as the runner's user. Only code that can reach
the runner's job queue can trigger this, nothing from the download runs,
and the files stay in `_work`.
