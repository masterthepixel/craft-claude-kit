---
name: Bug report
about: The installer, doctor, a skill, a hook or an MCP registration does not work as documented
title: "[bug] "
labels: bug
assignees: ""
---

<!--
Security problem (a way out of a fence, a hook that can be abused, a tampered download)?
Do not open a public issue. Follow SECURITY.md instead.

Before you paste anything below: remove your user name, home folder path (/Users/<name>), e-mail
addresses, host names and any token. Replace them with /Users/you, you@example.com and so on.
-->

## What happened

## What you expected

## Steps to reproduce

1.
2.
3.

## Environment

- macOS version and chip (`sw_vers`, `uname -m`):
- Claude Code version (`claude --version`):
- Kit version (`cat VERSION` in the repo):
- How you ran the installer (flags, e.g. `--gui`, `--workspace`, `--only`):
- App(s) affected:

## Diagnostics

Paste the output of `./doctor.sh` (from the repo, or from the install folder after an install).
Add `--smoke` if the problem is that a server starts but does not behave, and `--json` if the output is long.

```text

```

## Anything else
