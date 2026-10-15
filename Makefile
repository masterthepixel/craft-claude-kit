# craft-claude-kit developer tasks. Written for GNU make 3.81 (what macOS ships) and bash 3.2.
#
#   make test        everything below except smoke; runs every step even if one fails, then summarises
#   make lint        lint_skills + scan-public
#   make smoke       ./doctor.sh --smoke against the REAL installed apps (maintainers)
#   make snapshot    regenerate data/tools/<app>.json from the real servers (maintainers)
#   make lock        regenerate manifest/apps.lock.json from manifest/pins.txt (maintainers; LATEST=1 to re-pin)
#
# make scan SCAN_ARGS=--no-commit-meta   ignore commit author e-mails (what CI does for contributors' PRs)
# make scan SCAN_DENY_TERMS=name1,name2  also fail on these words (your handle, host names) without writing them
#   into the repo; CRAFT_KIT_EXTRA_DENYLIST=/path/outside/repo does the same from a file (tools/scan-public.sh).
# Single steps: syntax bash32 shellcheck lint-skills scan unit-hooks unit-python unit-shell
# Tests are discovered, not listed: tests/test_*.sh, tests/test_*.py, hooks/tests/test_*.py (test-*.py too).
# A Python test must run as a script (end it with unittest.main() or sys.exit(...)).
# shellcheck is optional locally (skipped with a note when missing); CI installs it.

SHELL := /bin/bash
export PYTHONDONTWRITEBYTECODE := 1

APPS := wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft filmcraft effectcraft lightcraft soundcraft
SNAPSHOT_APPS ?= $(APPS)
SHELLCHECK_FLAGS ?= -x
SCAN_ARGS ?=
SH_FILES := $(shell find . -path ./.git -prune -o -type f -name '*.sh' -print | sort) $(wildcard bin/craft-sandbox)
PY_FILES := $(shell find . -path ./.git -prune -o -type f -name '*.py' -print | sort)

# Constructs that bash 3.2 (macOS /bin/bash) does not have. `bash -n` cannot see most of them.
BASH4_RE := (declare|typeset|local)[[:space:]]+-[a-zA-Z]*[AnN]|(^|[^A-Za-z_])(mapfile|readarray|coproc)([^A-Za-z_]|$$)|\$$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)[^}]*\}|&>>|\[\[[[:space:]]+-v[[:space:]]|\|&|;;&|globstar|wait[[:space:]]+-n|EPOCH(SECONDS|REALTIME)|\$$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAaKk]\}

.PHONY: help test lint smoke snapshot lock syntax bash32 shellcheck lint-skills scan unit-hooks unit-python unit-shell
.DEFAULT_GOAL := help

help:
	@sed -n '3,8p' Makefile | sed 's/^# \{0,1\}//'

test:
	@fail=""; \
	for step in syntax bash32 shellcheck lint-skills scan unit-hooks unit-python unit-shell; do \
	  printf '\n==> make %s\n' "$$step"; \
	  $(MAKE) --no-print-directory "$$step" || fail="$$fail $$step"; \
	done; \
	echo; \
	if [ -n "$$fail" ]; then echo "make test: FAILED steps:$$fail"; exit 1; fi; \
	echo "make test: all steps passed"

lint: lint-skills scan

syntax:
	@set -e; \
	for f in $(SH_FILES); do /bin/bash -n "$$f" || { echo "bash -n failed: $$f"; exit 1; }; done; \
	python3 -c 'import sys; [compile(open(f, "rb").read(), f, "exec") for f in sys.argv[1:]]' $(PY_FILES); \
	echo "syntax ok: $(words $(SH_FILES)) shell file(s), $(words $(PY_FILES)) python file(s)"

bash32:
	@bad=0; \
	for f in $(SH_FILES); do \
	  hits=$$(grep -nE '$(BASH4_RE)' "$$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true); \
	  if [ -n "$$hits" ]; then echo "bash 3.2 incompatible construct in $$f:"; echo "$$hits"; bad=1; fi; \
	done; \
	if [ "$$bad" = 0 ]; then echo "bash 3.2 compatibility ok"; fi; \
	exit $$bad

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck $(SHELLCHECK_FLAGS) $(SH_FILES) && echo "shellcheck ok"; \
	else \
	  echo "shellcheck not installed, skipped (brew install shellcheck)"; \
	fi

lint-skills:
	@python3 tools/lint_skills.py skills

scan:
	@/bin/bash tools/scan-public.sh $(SCAN_ARGS)

unit-hooks:
	@set -e; n=0; \
	for t in $$(find hooks/tests -type f \( -name 'test_*.py' -o -name 'test-*.py' \) 2>/dev/null | sort); do \
	  n=$$((n + 1)); echo "-- $$t"; python3 "$$t"; \
	done; \
	echo "hooks tests: $$n file(s)"

unit-python:
	@set -e; n=0; \
	for t in $$(find tests -maxdepth 1 -type f -name 'test_*.py' 2>/dev/null | sort); do \
	  n=$$((n + 1)); echo "-- $$t"; python3 "$$t"; \
	done; \
	echo "python tests: $$n file(s)"

# Skipped checks print a line starting with "skip"; their count is shown so a local run cannot hide them
# (R1-HYGIENE-1). Under CI a missing e2e prerequisite is a failure, not a skip (tests/test_doctor.sh).
unit-shell:
	@set -eo pipefail; n=0; skips=0; log=$$(mktemp "$${TMPDIR:-/tmp}/craft-unit-shell.XXXXXX"); \
	trap 'rm -f "$$log"' EXIT; \
	for t in $$(find tests -maxdepth 1 -type f -name 'test_*.sh' 2>/dev/null | sort); do \
	  n=$$((n + 1)); echo "-- $$t"; /bin/bash "$$t" 2>&1 | tee "$$log"; \
	  skips=$$((skips + $$(grep -c '^skip ' "$$log" || true))); \
	done; \
	echo "shell tests: $$n file(s), $$skips skipped check(s)"; \
	if [ "$$skips" -gt 0 ]; then echo "NOTE: $$skips check(s) were skipped; see the 'skip' lines above"; fi

smoke:
	./doctor.sh --smoke

snapshot:
	@set -e; \
	ws=$$(mktemp -d "$${TMPDIR:-/tmp}/craft-snapshot.XXXXXX"); \
	trap 'rm -rf "$$ws"' EXIT; \
	mkdir -p data/tools; \
	for a in $(SNAPSHOT_APPS); do \
	  echo "snapshot $$a"; \
	  python3 lib/mcp_probe.py --app "$$a" --workspace "$$ws" $(if $(CRAFT_PREFIX),--prefix "$(CRAFT_PREFIX)") snapshot --out "data/tools/$$a.json"; \
	done

lock:
	./tools/gen-lock.sh $(if $(LATEST),--latest)
