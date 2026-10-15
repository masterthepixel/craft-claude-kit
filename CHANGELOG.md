# Changelog

All notable changes to craft-claude-kit are listed here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version number follows [Semantic Versioning](https://semver.org/). The kit version (the `VERSION` file) is separate from the versions of the Craft apps it installs, which are pinned in `manifest/apps.lock.json`.

## [Unreleased]

Fixes from the first adversarial review (round 1).

### Security

- **Sandbox profile: Mach service lookups are denied.** A sandboxed server could ask macOS (LaunchServices, `open`) to start another program, which then ran outside the sandbox and could read your home folder and use the network. The earlier wording ("no network at all", "children inherit the sandbox") was wrong for that case. `doctor.sh` fence-live now also tries to start a probe bundle through macOS and FAILs if it runs.
- **The lock is validated before anything else, also for `--dry-run`**: every size must be a whole number, every URL `https://github.com/`, every desktop bundle a plain `<Name>.app`, and `extraArgs` only the known per-app list. A tampered lock could previously run a command through `--dry-run` or move a fence with a second `--automation-write-root`.
- **Fence flags must appear exactly once.** `install.sh`, `lib/craftkit.py` and `doctor.sh` refuse a registration with a repeated or `--flag=value` fence flag (the CLIs honor the last one).
- **A program in `--prefix` is kept only if it is the file the kit verified.** The receipt records each CLI's SHA-256 (`cliSha256`); any other file of that name is shown as `replace*`, is not run at plan time, is moved aside to `<app>-cli.bak-craft-kit-<timestamp>` (listed in the summary; uninstall leaves it) and is replaced by the verified download. A matching `--version` alone is not trusted, since the registration will run that file. `doctor.sh` FAILs a changed CLI.
- **Registrations with extra settings** (for example an `env` that overrides the sandbox profile) no longer compare equal: the installer replaces them and `doctor.sh` FAILs them.
- **Hooks:** the shell guard also covers `mcp__terminal__run_in_terminal`, `Monitor` and computer-use `open_application`, and sees globs, brace expansion, `${...}`, `$'...'`, printf escapes, decoded text piped into a shell, more wrappers (`ionice`, `flock`, `script`, `parallel`, `ssh`, `expect`, `crontab`) and LaunchAgents loads. The MCP guard reads runner script text line by line, CADCraft typed command lines (word list), the command ids the skills' Never lists name, PdfCraft form actions and web links, export ids without a path, relative or placeholder save paths, saves onto existing files or into `in/`, and paths with leading spaces. Both ask, instead of passing silently, when a command or its arguments are too large or too deep to check, or the shell check needs more than a fixed amount of parsing work (a work count, not a clock, so the result no longer depends on the machine's speed). `doctor.sh` checks the hook files against SHA-256 values in the receipt and tests the risk table with canned payloads.

- **More MCP calls ask:** DesignCraft and DeckCraft `hyperlink.create` with a `url` or `email`; DeckCraft `file.package`; CADCraft `ATTACH` (without the X); EffectCraft `prop.setExpression`; SoundCraft `menu_invoke` (also in `batch`), VectorCraft `invoke_menu`, PhotoCraft `ui_menu_invoke`, DesignCraft `dialog_confirm`, and the `key` tools of WordCraft, DeckCraft, DesignCraft, SoundCraft and FilmCraft `ui_key`; output folders (`out_dir`, `out`, `dest` ...) of any tool pointing into `in/` (for example PdfCraft `doc_split`); and a path with a newline inside it. Reasons show the end of a long path (the file name), not its start.
- **More shell commands ask:** `W=wordcraft-cli; $W`, `export W=...`, `env -S'...'` with the text attached, and `xargs -I{} sh -c '{} ...'` or xargs fed a Craft name.
- `doctor.sh` fence-live counts the "start a program through macOS" step as refused only on the sandbox's own error text; `open` failing for another reason is now a WARN, not a PASS.
- **Sandbox profile: Metal's shader compiler is the one Mach service allowed** (`com.apple.MTLCompilerService`). Under the blanket Mach-lookup deny, LightCraft aborted (exit -6) on its first GPU call, so any render or export crashed the server; the earlier note that all 8 sandboxed smoke tests passed with the Mach rule was wrong. With the exception all 13 smoke tests pass and the `open` probe is still refused.
- **`doctor.sh` makes one real call per server by default** (`first-call`: the first, in-memory step of the app's smoke test, in the same session as the tool list). A server that starts but crashes on real work, as LightCraft did, is now a FAIL without `--smoke`.
- Documented: the sandbox does not confine signals (a sandboxed program can stop or end your other programs). A signal-deny variant was tested and is not shipped (docs/FENCES.md).

### Fixed

- **Desktop apps: eight of the thirteen failed the signature check on a clean account.** Their disk images carry Finder information on the app's files; `ditto` copied it, and `codesign --verify --strict` rejects it ("detritus not allowed"), so `install.sh --gui` refused wordcraft, gridcraft, deckcraft, photocraft, cadcraft, figcraft, filmcraft and effectcraft. The installer now copies with `ditto --noextattr --norsrc` (neither is part of the signature seal) and names the `codesign` reason when a check fails. The test fixtures now carry the same attribute, so a plain copy fails there too.
- **`install.sh --dry-run` without Claude Code** warns and still prints the plan, instead of stopping with exit 3. A real install still stops.

- **Four apps re-pinned to their current releases:** PhotoCraft 0.9.0, FilmCraft 0.8.0, EffectCraft 0.10.0 and SoundCraft 0.7.0 (they were one release behind). Each new release matched its published `SHA256SUMS.txt`, installed (command-line and desktop app) on a throw-away home, passed its smoke test and kept its tool names; their skills were re-checked against the new versions.
- **Hook table: the id guarded for EffectCraft expressions did not exist.** The table named `layer.setExpression`; the real command id is `prop.setExpression`, so an expression set through `command_run` was not asked about (the `set_property` `expression` argument was). Fixed, and the test now uses the real id. `file.closeAllProjects` with `force: true` now asks like `file.closeProject`.

### Changed

- **Uninstall without the kit folder** takes the programs folder from the registrations (or `--prefix DIR`), removes only the registrations that run through the kit's own wrapper, lists the others with their remove commands, and exits 1 instead of claiming success while one is left.
- **Uninstall** removes a CLI only if it still has the recorded SHA-256, and a desktop app only at the recorded version (`guiVersion`); accepts a kit folder reached through a symlink; lists every name it deletes inside the kit folder; refuses a receipt whose kit folder contains the prefix, the Claude folder or the workspace.
- **Install** refuses a non-empty `CRAFT_KIT_HOME` the kit did not make, and a `CRAFT_KIT_HOME` that is or contains `--prefix`, the Claude Code folder or `--gui-dir`.
- **Legacy files** of a hand-made setup are recognized by content and moved aside as `<name>.bak-craft-kit-<timestamp>` instead of deleted; unrelated files at those paths are kept.
- If replacing a registration fails at `claude mcp add`, the previous one is put back. Before any registration is replaced, the whole old entry (with its `env`) is saved to `<kit folder>/backup/<app>-mcp-<timestamp>.json` (mode 600); if putting it back fails too, the error names that file.
- **Uninstall keeps files you added inside the kit folder.** The receipt lists the files the installer copied (`kitFiles`); uninstall removes only those, lists anything else it finds and keeps the folder. Older receipts fall back to the previous behavior.
- The older hand-made hook script is recognized only by its own name (`craft-shell-guard`) and an ask decision; a hook of yours that merely mentions Craft is kept.
- A stalled download (under 1 KB/s for 60 s) fails and is retried; the failure shows curl's own reason.
- Preflight tells a `python3` that does not run (missing Command Line Tools) apart from an old one.
- The plan table fits 80 columns, says that later plain re-runs keep every app installed so far, and fix hints and re-run commands include `--yes` when there is no terminal. `doctor.sh` before any install prints one FAIL instead of about fifty, and its hints no longer suggest `--only` then.
- `craft-sandbox` says on stderr when it falls back to the profile of an older hand-made setup.
- `lib/settings_edit.py` refuses a `settings.json` with a number too large for a float (it would have written `Infinity`).
- `tools/scan-public.sh` reports binary files and over-long lines instead of skipping them, and its allowlist takes an optional category column. `SCAN_DENY_TERMS=a,b` adds private words (for example your handle) without writing them into the repository.
- `make test` prints how many shell-test checks were skipped.
- `doctor.sh` no longer prints a "no install receipt" WARN next to the "nothing installed" FAIL, and all its re-run hints carry `--yes` when there is no terminal.
- FilmCraft's smoke test now exports H.264 and renders again afterwards.
- README: the clone command uses the published repository URL, and `craft-sandbox` is in the terms list. NOTICE states exactly which names the kit uses.
- `tools/lint_skills.py` requires a verification marker or header in every Gotchas section and checks that each Never-list command id is guarded or reviewed.
- Skills: master routing and rules corrected (GridCraft has no render tool; `doc_audit_redactions` is unreliable on PdfCraft 0.8.0; `/private/tmp` is shared), FilmCraft and LightCraft crash notes corrected, discard-on-open moved into Never lists, PdfCraft form actions and links added to Never.
- Docs: README, SECURITY, FENCES, HOW-IT-WORKS, VERIFICATION, UPDATING and NOTICE updated to match; the brand notice no longer concludes that the kit's use of the upstream name is covered.

## [0.1.0] - 2026-10-14

First release.

### Added

- **`install.sh`**: installs the 13 Craft command-line apps from their official GitHub releases, SHA-256 verified against pinned values; registers each as a user-scope Claude Code MCP server confined to `~/craft-workspace/<app>/`; installs the skills and the hooks; writes a receipt. It prints a plan with download sizes and asks once; it is idempotent (a re-run repairs and upgrades, and keeps the previous workspace, prefix, desktop-app folder and app selection); one failing app does not stop the others; `--dry-run` changes nothing; it refuses to run as root; it warns about same-named servers at local or project scope that override the fenced one; one `settings.json` backup per run. Options: `--yes`, `--dry-run`, `--only` (`--only all`), `--gui`, `--no-gui`, `--workspace`, `--prefix`, `--gui-dir`, `--offline-dir`, `--no-skills`, `--no-hook`, `--no-mcp`, `--help`, `--version`.
- **Optional desktop apps** (`--gui`): disk image checked by SHA-256, mounted read-only, copied, code signature verified. An app that is already installed is never overwritten.
- **Migration** from an older hand-made setup of the same servers (sandbox wrapper and profile, shell-guard hook entry, same-named servers and skills), without duplicates.
- **`uninstall.sh`**: removes only what the receipt says the kit installed. Never deletes the workspace. `--keep-cli`, `--keep-skills`, `--keep-hooks`, `--remove-gui`, `--dry-run`. Run from the clone after the kit folder was deleted by hand, it removes the kit's hook entries, MCP servers and wrapper and lists the rest.
- **`doctor.sh`**: environment, per-app, skills, hooks, desktop-app and leftover checks, each PASS, WARN or FAIL with a fix hint; `--smoke` drives every server through a scripted test in `<workspace>/<app>/_doctor/` (a folder it creates, marks and removes; it never deletes one it did not create); `--json`; `--brief`; `--app`. It checks what the receipt lists (after `--only`, `--no-skills`, `--no-hook` or `--no-mcp`, only what was installed) and starts sandboxed servers through the installed wrapper, as Claude Code does. For sandboxed apps it tries a write outside the folder, a read in the home folder and a network connection, and expects all three to be refused.
- **Fences, failing closed.** Five apps use their own flags (`--automation-read-root` / `--automation-write-root` for WordCraft, PhotoCraft, VectorCraft and EffectCraft; `--root` for PdfCraft) and are not registered unless the program's `--help` lists them. Eight apps (GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft, FilmCraft, LightCraft, SoundCraft) run through `bin/craft-sandbox` and `share/craft.sb`: no network, no reads of the rest of the home folder or `/Volumes`, writes only to the app's folder and the system temp folders. WordCraft is registered with `--author Claude`.
- **14 skills**: `craft-apps` (routing, rules, hand-offs between apps, what to do when a server is missing) and `craft-<app>` for each app, with claims checked against the live servers or marked "(not verified on vX.Y.Z)".
- **2 hooks**, ask-only and fail-open (registered as `python3 <script> ... || true`, so even a deleted script cannot block a tool call): `craft-shell-guard.py` (Bash commands that would start a Craft app or CLI directly) and `craft-mcp-guard.py` (risky Craft MCP calls, saves without a path, paths outside the app's folder). The per-tool table is `hooks/risky-tools.json`.
- **Tool snapshots** (`data/tools/<app>.json`) and **smoke tests** (`tests/smoke/<app>.json`) for all 13 apps, recorded from the real servers; `mcp_probe.py` drives a server exactly as it is registered.
- **Tests and tooling**: `make test` (syntax, bash 3.2 compatibility, shellcheck when installed, hook tests, helper tests, install/uninstall/doctor end-to-end tests in a throw-away fake home, skill lint, public-hygiene scan), `make lint`, `make smoke`, `make snapshot`, `make lock`; a macOS CI workflow.

### Pinned Craft App Versions

| App | Version | App | Version |
|---|---|---|---|
| WordCraft | 0.7.0 | CADCraft | 0.7.0 |
| GridCraft | 0.7.0 | FigCraft | 0.6.0 |
| DeckCraft | 0.7.0 | FilmCraft | 0.8.0 |
| PdfCraft | 0.8.0 | EffectCraft | 0.10.0 |
| PhotoCraft | 0.9.0 | LightCraft | 0.8.0 |
| VectorCraft | 0.11.0 | SoundCraft | 0.7.0 |
| DesignCraft | 0.8.0 | | |

### Known Limitations

- macOS 13 or newer only. Verified on one Apple silicon Mac running macOS 26; Intel Macs and macOS 13 to 25 have not been tried.
- A first install of the real downloads on a clean machine has not been run; the download path is covered by local fixtures.
- The servers are headless: window tools (`click`, `key`, `pointer`, `ui_*`, and `screenshot` in WordCraft, DesignCraft, DeckCraft, GridCraft and SoundCraft) do not work. Live-window modes (`--connect`, `--bridge`) are not used.
- `sandbox-exec` is deprecated by Apple. It works on current macOS and may be removed later.
- PdfCraft 0.8.0: OCR reports itself unavailable.
- The hooks are heuristics, not a security boundary.
