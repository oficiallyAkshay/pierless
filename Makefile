# Makefile — the same checks CI runs, runnable locally.
#
# hooks   installs the pre-commit hooks into this clone, once
# check   hooks + actionlint (if present) + tests
# test    tests/run.sh alone
# lint    hooks + actionlint (if present), no tests
# coverage  tests/run.sh under bash's own line tracing +
#           scripts/ci/coverage-check.py — no kcov, no container
#
# pre-commit itself is one line: `uv tool install pre-commit`, or
# `pipx install pre-commit`.

SHELL := /bin/bash

WORKFLOW_FILES := $(wildcard .github/workflows/*.yml)

.PHONY: check test lint coverage hooks

check: lint test

hooks:
	pre-commit install

test:
	bash tests/run.sh

lint:
	@echo "==> pre-commit run --all-files"
	pre-commit run --all-files
	@if command -v actionlint >/dev/null 2>&1; then \
		echo "==> actionlint"; \
		actionlint $(WORKFLOW_FILES); \
	else \
		echo "==> actionlint not on PATH — skipping (CI installs it; see CONTRIBUTING.md)"; \
	fi
	# action.yml is a composite-action definition, not a workflow file:
	# actionlint has no standalone schema for it and misparses it as a
	# malformed workflow if handed the path directly (tried; every
	# top-level key past 'name' errors as "missing jobs/on section").
	# It only validates a composite action in context, when a real
	# workflow's step does `uses: ./` — tests/action.test.sh covers
	# action.yml's shape instead (composite, required inputs, no
	# third-party uses:, no checkout).

coverage:
	@mkdir -p coverage
	PIERLESS_TRACE_FILE="$(CURDIR)/coverage/trace.log" bash tests/run.sh
	python3 scripts/ci/coverage-check.py --trace coverage/trace.log
