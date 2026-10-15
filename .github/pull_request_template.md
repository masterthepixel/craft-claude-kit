## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `make test` passes on macOS (it runs syntax checks, shellcheck when installed, the skill linter, the public-hygiene scan and all tests).
- [ ] I ran the installer, uninstaller and doctor only through `tests/isolated.sh` (a throwaway HOME), never against my real `~/.claude`.
- [ ] No personal data in files: no `/Users/<name>` paths, real e-mail addresses, host names, IPs or tokens. `tools/scan-public.sh` is clean. (Tip: commit with your GitHub `noreply` address to keep your private e-mail out of history.)
- [ ] Shell code is bash 3.2 compatible; Python code is stdlib only and works on Python 3.9.
- [ ] Skills: `python3 tools/lint_skills.py skills` is clean. Every tool name was checked against the live server (`make snapshot` refreshes `data/tools/`), or the gotcha is marked "(not verified on vX.Y.Z)".
- [ ] Claims are honest: nothing is described as "secure" or "safe" without its precise guarantee and limits. Hooks stay ask-only and fail-open.
- [ ] Docs and `CHANGELOG.md` are updated when behavior changes.
- [ ] New third-party GitHub Actions (if any) are pinned to a full commit SHA with the tag in a comment.

## How I tested it

<!-- Commands you ran and what you saw. Redact personal paths. -->
