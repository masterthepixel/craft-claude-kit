# Contributing to craft-claude-kit

Contributions are welcome. This project installs third-party programs, registers them with an AI agent and ships instructions that steer that agent, so the bar is "correct, honest and checkable", not "big". Small pull requests with a clear test are the easiest to accept.

To report a security problem, do **not** open an issue: follow [SECURITY.md](SECURITY.md).

## Ground Rules

1. **Honest text.** Never call something "secure" or "safe" without its precise guarantee and its limits. Say what was verified and how; mark the rest `(not verified on vX.Y.Z)`. The hooks are heuristics, the fences are the real control, and `sandbox-exec` is deprecated by Apple: state this wherever relevant.
2. **Fences fail closed, hooks fail open.** If a server cannot be confined, it is not registered. A hook only ever asks, never denies, and any error in a hook must end silently.
3. **No personal data, ever.** No `/Users/<name>` paths (use `/Users/you` or `$HOME`), real e-mail addresses, host names, IP addresses, tokens or internal ticket numbers. `tools/scan-public.sh` enforces this over the tree and the git history; it cannot read binary files, so it reports each one (`[binary-file]`) for you to review by hand and allowlist by path, and reports any line over 20000 characters (`[long-line]`), of which it scans only the start.
4. **Small and dependency-free.** Shell is bash 3.2 (what macOS ships). Python is the standard library only and runs on Python 3.9. No `pip`, no `npm`, no `sudo`, no `curl | sh`.
5. **Never touch your real setup while developing.** Run the installer, uninstaller and doctor through `tests/isolated.sh` (see below).
6. **Unofficial.** The kit does not redistribute the Craft apps; it downloads them from their official GitHub releases and checks pinned SHA-256 values. Do not add binaries or copies of upstream files to this repository.

By contributing you agree that your work is released under the repository's license (see [LICENSE](LICENSE)).

## Set Up

You need a Mac (macOS 13 or newer) because the tests use `hdiutil`, `codesign` and `sandbox-exec`. Linux can run only the skill linter and shellcheck (that is what the second CI job does).

```sh
git clone https://github.com/masterthepixel/craft-claude-kit.git
cd craft-claude-kit
make test
```

There is no build step. `make test` takes several minutes (about 7 on the maintainer's laptop; the installer end-to-end tests are the long part). Needed tools:

| Tool | Notes |
|---|---|
| `bash` 3.2, `make` 3.81 | The versions macOS ships; do not rely on newer ones |
| `python3` 3.9 or newer | The macOS Command Line Tools one is fine |
| `jq` | macOS 15 and newer include it; otherwise `brew install jq` |
| `curl`, `unzip`, `shasum`, `git` | Ship with macOS |
| `shellcheck` | Optional locally (`brew install shellcheck`), always run in CI |
| `gh` (authenticated) | Only for `make lock` (reads public release metadata) |
| Claude Code | Not needed for development: tests use a fake `claude` |

You do **not** need the Craft apps to develop or to run `make test`. Tests use tiny fake archives built by `tests/fixtures/build.sh` and never download the real releases.

## Repository Map

| Path | What it is |
|---|---|
| `install.sh`, `uninstall.sh`, `doctor.sh` | The three commands users run; `lib/common.sh` is shared shell code |
| `lib/craftkit.py` | Reads the lock, computes the exact server command per app, reads the Claude config, renders skills |
| `lib/mcp_probe.py` | A small MCP client that starts a server exactly as registered and drives it (doctor, smoke tests, snapshots) |
| `lib/doctor_checks.py` | The checks behind `doctor.sh` |
| `lib/settings_edit.py` | Safe, backed-up edits of Claude Code `settings.json` hooks |
| `bin/craft-sandbox`, `share/craft.sb` | The macOS sandbox wrapper and its profile (8 apps) |
| `hooks/` | The two ask-only hooks, their risk table `risky-tools.json`, and their tests |
| `skills/` | The 14 Claude Code skills (sources, with `{{WORKSPACE}}` and `{{KIT_HOME}}` tokens); see `skills/README.md` |
| `manifest/` | `pins.txt` (the versions we support) and the generated `apps.lock.json`; never edit the lock by hand |
| `data/tools/<app>.json` | Snapshot of each server's tool names and parameters, used for drift checks |
| `tests/` | Installer, doctor and unit tests, `isolated.sh`, fixtures; `tests/smoke/<app>.json` are scripted sessions against the real servers |
| `tools/` | `lint_skills.py`, `scan-public.sh`, `gen-lock.sh` |
| `docs/` | Longer documents: `HOW-IT-WORKS`, `FENCES`, `SKILLS`, `APPS`, `UPDATING`, `TROUBLESHOOTING`, and `VERIFICATION` |

## Make Targets

| Target | What it does |
|---|---|
| `make test` | Everything below except `smoke`; runs every step even if one fails, then lists the failed steps |
| `make lint` | `lint-skills` and `scan` |
| `make syntax` | `bash -n` on every shell file and a Python compile of every `.py` |
| `make bash32` | Greps for constructs that bash 3.2 lacks (associative arrays, `mapfile`, `${var,,}`, `&>>`, and so on) |
| `make shellcheck` | shellcheck on all shell files (skipped with a note if not installed) |
| `make lint-skills` | `python3 tools/lint_skills.py skills`, the skill contract |
| `make scan` | `tools/scan-public.sh`: personal paths, e-mails, IPs, host names, secrets, in the tree and in the git history |
| `make unit-hooks`, `make unit-python`, `make unit-shell` | Tests discovered by name: `hooks/tests/test_*.py`, `tests/test_*.py`, `tests/test_*.sh` |
| `make smoke` | `./doctor.sh --smoke` against the **real** installed apps (maintainers) |
| `make snapshot` | Regenerate `data/tools/<app>.json` from the real servers (maintainers) |
| `make lock` | Regenerate `manifest/apps.lock.json` from `manifest/pins.txt` (maintainers; `LATEST=1` re-pins everything to the newest releases, then review the diff) |

`make scan SCAN_ARGS=--no-commit-meta` ignores commit author e-mails; that is what CI does for pull requests, because your commit e-mail is yours to choose. (Recommendation: commit with a GitHub `noreply` address to keep a private address out of the history.) For things only you know are private, set `CRAFT_KIT_EXTRA_DENYLIST=/path/outside/the/repo/denylist.txt`, one fixed string per line; the scan refuses a denylist inside the repository.

CI (`.github/workflows/ci.yml`) runs `make test` on macOS and the skill linter plus shellcheck on Linux. Third-party GitHub Actions are pinned to a full commit SHA, with the tag in a comment; keep it that way.

## Running Things Safely: `tests/isolated.sh`

`tests/isolated.sh COMMAND...` runs a command with a throw-away `HOME`, a fake `claude` that records every call and edits a fake `.claude.json`, the fixture lock and archives, and no usable network. Every run of `install.sh`, `uninstall.sh` or `doctor.sh` that is not `--help` or `--dry-run` goes through it:

```sh
tests/isolated.sh ./install.sh --yes --no-gui          # a full install into a fake home
tests/isolated.sh bash -c './install.sh --yes --no-gui >/dev/null && "$HOME/.local/share/craft-claude-kit/doctor.sh"'
KEEP_TEMP=1 tests/isolated.sh ./install.sh --yes       # keep the fake home to look around (the path is printed)
```

Because the fixture CLIs are fakes that list two tools, doctor shows WARN lines about drift and tool references in that environment. That is expected there.

`./install.sh --dry-run` changes nothing, so it is safe on your real machine, and a good way to see the plan.

## Tests

| File | Covers |
|---|---|
| `tests/test_install.sh` | The installer and uninstaller end to end, in cases: `help preflight dry-run lifecycle bad-sha zip-slip fence-fail only no-flags legacy bad-settings spaces custom-paths settings-symlink upgrade gui uninstall-options tty real-home`. Run one with `bash tests/test_install.sh lifecycle`, list with `-l`, show passing checks with `-v` |
| `tests/test_doctor.sh` | doctor's checks, including the live sandbox probes (a profile that allows everything must FAIL) |
| `tests/test_tools.sh` | Proves that `lint_skills.py` and `scan-public.sh` really catch what they claim to catch |
| `tests/test_craftkit.py`, `tests/test_settings_edit.py` | The Python helpers |
| `hooks/tests/test_shell_guard.py`, `test_mcp_guard.py` | The hooks: what must ask, what must stay silent, malformed input must fail open |
| `tests/smoke/<app>.json` | Not run by `make test`: scripted sessions that need the real apps (`make smoke`) |

Python tests run as scripts (`python3 hooks/tests/test_mcp_guard.py -k save` runs the tests whose name contains `save`). A test file must end with `unittest.main()` or `sys.exit(...)`, because `make` discovers and runs it by name.

When you fix a bug, add the case that would have caught it. When you change a hook, add both a "must ask" and a "must stay silent" case. A test that cannot fail proves nothing: when you write a smoke test, also run it once with a deliberately wrong expectation and check that it fails.

## Style

- **Shell:** `#!/usr/bin/env bash`, `set -euo pipefail`, bash 3.2 only (`make bash32` greps for the usual offenders; with `set -u` an empty array needs the `${arr[@]+"${arr[@]}"}` form), shellcheck clean, quote everything, absolute paths for anything destructive. Comments explain *why*, not what.
- **Python:** standard library only, Python 3.9 (no `match`, no runtime `X | Y` type unions), no third-party imports. Hooks must be fail-open: wrap the work, return 0, print nothing on error.
- **Anything that deletes or overwrites:** it must check the path is absolute, normalized, and inside a folder the kit owns, and must be covered by a test. See `ck_safe_rm_rf` in `lib/common.sh`.
- **Messages for users:** say what happened, then the fix, in one line each (`FAIL ...` then `fix: ...`). No jargon without a clue.
- **Docs:** short sentences, concrete commands you have run, no marketing words. Do not describe a control by its intent; describe its guarantee and its limit. No emoji.
- **Commits:** a clear imperative subject, one logical change each.

## Skills

The 14 skills are part of the product, and a wrong sentence in one makes an agent do the wrong thing. The format and the reasoning are in [docs/SKILLS.md](docs/SKILLS.md) and `skills/README.md`; `tools/lint_skills.py` (part of `make test`) enforces the form: frontmatter, a description that starts "Use when" and says when *not* to use the skill, a body of at most 3800 bytes, the five sections in order, one `ToolSearch select:` line with real tool names, and no personal paths.

The linter checks form; the contributor checks truth. Every factual sentence in a skill must have been seen to be true on the live server, or be marked `(not verified on vX.Y.Z)`. Check claims with the probe, in a scratch workspace, one server at a time (the probe kills the server when it exits):

```sh
WS=$(mktemp -d)
mkdir -p "$WS/wordcraft/_doctor"          # the smoke tests save here; the probe does not create it
python3 lib/mcp_probe.py --app wordcraft --workspace "$WS" list-tools
python3 lib/mcp_probe.py --app wordcraft --workspace "$WS" call list_commands --args '{}'
python3 lib/mcp_probe.py --app wordcraft --workspace "$WS" run tests/smoke/wordcraft.json
```

The probe needs the app's command-line tool in `~/.local/bin` (or `--prefix DIR`). Check the failure cases as well as the success: what the server says for a bad path, a missing folder, a `~` path, a save without `path`. Never aim the probe at your real workspace, and never launch the desktop apps.

## Propose a New App

Open an issue first. The kit can support a Craft app when all of this is true:

- It is released on GitHub by the upstream project, with a command-line tool as its own release asset, a `SHA256SUMS.txt`, and an `mcp` subcommand that serves MCP over stdio;
- You have read `<app>-cli mcp --help` and can say whether it has a confinement flag. If it has, the fence is `roots` or `root` and the installer must check that exact flag; if it has none, it gets the `sandbox` fence and must start and pass a smoke test under `share/craft.sb` (watch for crashes; see [docs/LESSONS.md](docs/LESSONS.md));
- You are willing to review every tool for effects outside the document (printing, permanent deletes, scripts, downloads, talking to other programs) and to verify its skill against the live server.

The app list is repeated in about a dozen files, and the complete checklist is in [docs/UPDATING.md](docs/UPDATING.md#adding-a-14th-app). A pull request that adds an app without its skill, snapshot, smoke test and hook review will be sent back.

## Propose a Version Bump

The lock pins the versions the kit has been checked against, so a bump is a re-check, not a one-line change. The procedure (edit `manifest/pins.txt`, `make lock`, install into a throw-away place, `make snapshot`, re-check the skills, the hook table and the fence flags, smoke tests, changelog) is in [docs/UPDATING.md](docs/UPDATING.md#for-maintainers-moving-the-pins). In the pull request say what you ran and what you saw. "Bumped, tests pass" is not enough for an app: a fence regression would not show up in `make test`. Never edit `manifest/apps.lock.json` by hand.

## Pull Request Checklist

The pull request template lists the same items; the short version:

- [ ] `make test` passes on macOS.
- [ ] Installer, uninstaller and doctor were run only through `tests/isolated.sh` (or `--dry-run`).
- [ ] `tools/scan-public.sh` is clean: no personal data in files or in commit messages.
- [ ] Shell is bash 3.2 compatible and shellcheck-clean; Python is stdlib only and works on 3.9.
- [ ] Skills lint clean, and every changed claim was checked against the live server or marked not verified.
- [ ] Nothing is described as secure or safe without its guarantee and its limits; hooks stay ask-only and fail-open.
- [ ] A test covers the change (and a failing case for a bug fix).
- [ ] Docs and `CHANGELOG.md` are updated when behavior changes.
- [ ] New GitHub Actions, if any, are pinned to a commit SHA.

## Getting Help

Open an issue with the output of `./doctor.sh` (personal paths replaced by `/Users/you`). This is a volunteer project; courteous communication is expected.
