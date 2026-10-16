# craft-claude-kit

> **Unofficial community project.** Not affiliated with, endorsed by or supported by Anthropic or the authors of the Craft apps (storytold). "Claude" and "Craft" appear only to say what the kit works with.

Give Claude Code the 13 [Craft apps](https://github.com/storytold): word processor, spreadsheet, slides, PDF, image, vector drawing, page layout, CAD, interface design, video, motion graphics, raw photos and audio.

One command downloads and checks them, plugs each into Claude Code as an MCP server fenced to its own folder, and installs the skills that teach Claude to use them.

Contents: [Quick start](#quick-start) | [What you get](#what-you-get) | [Requirements](#requirements) | [Install options](#install-options) | [Download sizes](#download-sizes) | [First Steps](#first-things-to-try) | [Verify](#verify) | [Update](#update) | [Uninstall](#uninstall) | [Platforms](#supported-platforms) | [Security](#security) | [Testing](#what-has-and-has-not-been-tested) | [FAQ](#faq) | [License](#license)

---

## Quick Start

**You need** macOS 13 or newer and the Claude Code CLI (`claude`). The installer checks both and says how to fix a miss.

**1. Install**

```sh
git clone https://github.com/masterthepixel/craft-claude-kit.git
cd craft-claude-kit && ./install.sh
```

**2. Open a new Claude Code session.** Servers and skills load at start-up, so a session that was already open will not see them.

**3. Check that it worked**

```sh
~/.local/share/craft-claude-kit/doctor.sh
```

`install.sh` shows a plan first (what it will download, where it will write, which Claude Code settings it will touch), asks once, and changes nothing until you say yes. It is safe to run again: it repairs what is missing and skips what is up to date. macOS only. Unofficial: see [Not affiliated](#not-affiliated).

[Back to top](#craft-claude-kit)

---

## What You Get

- **13 apps**, installed as headless command-line programs (the desktop `.app` versions are optional, `--gui`).
- **13 MCP servers**, registered with Claude Code at user scope, each limited to its own folder, `~/craft-workspace/<app>/` (8 by the macOS sandbox, 5 by the app's own folder flags; see [Security](#security)).
- **14 Claude Code skills**: `craft-apps` (when to use which app, the rules, hand-offs between apps) and one `craft-<app>` per app (which tools to load, a workflow, verified gotchas, what never to do).
- **2 safety hooks** that ask before risky things (see [Security](#security)). They ask; they never block.
- **`doctor.sh`**, which checks all of it, and **`uninstall.sh`**, which removes only what the kit installed.

Terms used below:
- **MCP** (Model Context Protocol): how Claude Code talks to outside tools. Each Craft app is registered as one MCP server.
- **receipt**: `receipt.json`, the file `install.sh` writes listing what it installed (with checksums); `doctor.sh` and `uninstall.sh` read it.
- **fence**: the limit on which folder an app's server may touch (see [Security](#security) and [docs/FENCES.md](docs/FENCES.md)).
- **craft-sandbox**: the wrapper that runs a sandboxed app under macOS `sandbox-exec` with the profile `share/craft.sb`; installed into the `--prefix` folder (default `~/.local/bin`).
- **user scope**: a Claude Code MCP registration available in every project, kept in `~/.claude.json`.
- **PreToolUse hook**: a Claude Code setting that runs a script before a tool call; the kit's two hooks ask before risky calls.
- **kit runtime copy**: the copy of `doctor.sh`, `uninstall.sh` and their helpers in `~/.local/share/craft-claude-kit`.

| App | Use it for | How it is fenced |
|---|---|---|
| WordCraft | Word processing: letters, reports (`.docx`, can save PDF) | the app's own root flags |
| GridCraft | Spreadsheets, formulas, charts (`.xlsx`, `.csv`) | macOS sandbox |
| DeckCraft | Slide decks (`.pptx`) | macOS sandbox |
| PdfCraft | Read, merge, fill and redact PDFs | the app's own `--root` flag |
| PhotoCraft | Raster image editing with layers (PSD) | the app's own root flags |
| VectorCraft | Logos, icons, illustration (SVG, PDF) | the app's own root flags |
| DesignCraft | Page layout: flyers, brochures | macOS sandbox |
| CADCraft | 2D CAD drafting | macOS sandbox |
| FigCraft | Interface design: frames, auto layout (its own format, not Figma files) | macOS sandbox |
| FilmCraft | Video editing | macOS sandbox |
| EffectCraft | Motion graphics and compositing | the app's own root flags |
| LightCraft | Raw photo library and developing | macOS sandbox |
| SoundCraft | Multitrack audio | macOS sandbox |

[Back to top](#craft-claude-kit)

## Requirements

- A Mac running **macOS 13 or newer** (Apple Silicon or Intel).
- **Claude Code** installed and working (`claude --version`). Claude Desktop and claude.ai are not supported. The installer needs the `claude` command to register the servers; `--no-mcp` skips both the check and the registration.
- Tools the installer checks for first, each with a fix hint if missing: `curl`, `unzip`, `shasum` (ship with macOS), `python3` 3.9 or newer (`xcode-select --install`), `jq` (included in macOS 15 and newer; otherwise `brew install jq`), `/usr/bin/sandbox-exec` (ships with macOS). With `--gui` also `hdiutil` and `ditto` (ship with macOS).
- An internet connection to `github.com` during install, and free disk space: see [Download sizes](#download-sizes).
- No `sudo` (the scripts refuse to run as root). The kit itself needs no Node, Docker or Homebrew packages (apart from `jq` on macOS 14 and older).

[Back to top](#craft-claude-kit)

## Install Options

```sh
./install.sh --dry-run          # show the plan, change nothing
./install.sh                    # show the plan, ask once, install
./install.sh --yes --gui        # no questions, command-line apps and desktop apps
./install.sh --only wordcraft,pdfcraft
```

Run from a terminal, it asks `[y] yes  [g] yes, and the desktop apps too  [N] no`. Without a terminal (a script, or Claude Code's Bash tool) it refuses to guess and exits with code 4 unless you pass `--yes`; `--yes` alone does not include the desktop apps.

A re-run keeps what the previous install used: its workspace, `--prefix` and `--gui-dir`, and every app installed by any earlier run. `--only` adds apps to that set and never removes one; no option removes a single app from it (`--only all` selects all 13). The plan shows the set at the top, and a first `--only` run says that later plain re-runs keep it.

| Option | What it does |
|---|---|
| `-y`, `--yes` | Do not ask; install as planned (desktop apps only with `--gui`). |
| `--dry-run` | Print the plan and exit. Creates no folders, no log, no downloads. It validates the lock file first, and runs only the programs the kit itself verified and installed (`<app>-cli --version` / `--help`); any other file in `--prefix` is not run. |
| `--only a,b` | Only these apps (skills and hooks are still installed). `--only all` selects all 13. |
| `--gui` / `--no-gui` | Also install the desktop apps / do not install or ask about them. |
| `--workspace DIR` | Workspace root, one folder per app. Default `~/craft-workspace`. |
| `--prefix DIR` | Where the `<app>-cli` programs and `craft-sandbox` go. Default `~/.local/bin`. |
| `--gui-dir DIR` | Where desktop apps go. Default `/Applications` if you can write there, else `~/Applications`. |
| `--offline-dir DIR` | Take release files from `DIR/<file name>` instead of downloading. Checksums are still verified. |
| `--no-skills` | Do not install the skills. |
| `--no-hook` | Do not install the two hooks. |
| `--no-mcp` | Do not register the MCP servers (also skips the check for `claude`). |
| `-h`, `--help` / `--version` | Help / print the kit version. |

Environment: `CRAFT_KIT_HOME` (kit runtime folder, default `~/.local/share/craft-claude-kit`; it must be a new or empty folder, or an earlier kit folder, and must not contain `--prefix`, the Claude Code folder or `--gui-dir`, because `uninstall.sh` deletes what is inside it), `CLAUDE_CONFIG_DIR` (Claude Code config folder, default `~/.claude`), `CLAUDE_BIN` (Claude Code command, default `claude`), `NO_COLOR` (no color), `FORCE_COLOR=1` (keep color when the output is piped, for example into `tee`). Three more exist for tests: `CRAFT_KIT_LOCK` (another lock file), `CRAFT_KIT_OFFLINE_DIR` (same as `--offline-dir`) and `CRAFT_KIT_GUI_DIR` (the default desktop-app folder instead of `/Applications`).

Exit codes: `0` ok, `1` something failed (the others still finished), `2` usage error, `3` a requirement is missing, `4` declined or no terminal and no `--yes`.

Where things go:

| What | Where |
|---|---|
| The 13 programs and `craft-sandbox` | `~/.local/bin` (`--prefix`). They do not need to be on your `PATH`. |
| Kit runtime copy, `doctor.sh`, `uninstall.sh`, `receipt.json`, `install.log` | `~/.local/share/craft-claude-kit` |
| Your files for each app | `~/craft-workspace/<app>/in/` and `out/` (mode 700; existing files are never touched) |
| MCP servers | Claude Code's user-scope config, changed only through `claude mcp add` / `claude mcp remove` |
| Skills | `~/.claude/skills/craft-*/SKILL.md` |
| Hooks | two `PreToolUse` entries in `~/.claude/settings.json` (one timestamped backup per run, made before the first change) |
| Desktop apps (only with `--gui`) | `/Applications` or `~/Applications` |

[Back to top](#craft-claude-kit)

## Download Sizes

The installer downloads each file from the official GitHub release and refuses it unless its SHA-256 matches the one pinned in [`manifest/apps.lock.json`](manifest/apps.lock.json).

| App | Version | Command-line app | Desktop app (optional) |
|---|---|---|---|
| WordCraft | 0.7.0 | 86 MB | 105 MB |
| GridCraft | 0.7.0 | 11 MB | 25 MB |
| DeckCraft | 0.7.0 | 68 MB | 81 MB |
| PdfCraft | 0.8.0 | 61 MB | 94 MB |
| PhotoCraft | 0.9.0 | 68 MB | 90 MB |
| VectorCraft | 0.11.0 | 106 MB | 132 MB |
| DesignCraft | 0.8.0 | 62 MB | 80 MB |
| CADCraft | 0.7.0 | 52 MB | 67 MB |
| FigCraft | 0.6.0 | 78 MB | 94 MB |
| FilmCraft | 0.8.0 | 61 MB | 74 MB |
| EffectCraft | 0.10.0 | 60 MB | 64 MB |
| LightCraft | 0.8.0 | 103 MB | 108 MB |
| SoundCraft | 0.7.0 | 6.7 MB | 23 MB |
| **Total** | | **821 MB** | **1.0 GB** |

Sizes are decimal megabytes, as GitHub shows them. Unpacked, the 13 command-line programs took about 1.7 GB on the machine this was developed on, and the 13 desktop apps about 2 GB. The plan warns you if free space looks too low. A program the kit verified and installed earlier (same SHA-256 as recorded in the receipt) is skipped, so a re-run downloads nothing. A program of that name that the kit did not install, or that changed since, is replaced by the verified download (marked `replace*` in the plan), and it is not run before that. A download that stalls (under 1 KB/s for a minute) fails and is retried.

[Back to top](#craft-claude-kit)

## First Things to Try

Open a new Claude Code session and ask in plain words. Naming the app helps, and Claude also picks one when the task is clearly a document, spreadsheet, PDF and so on.

1. *"Use WordCraft to write a one-page project status report with a heading and three short sections. Render it to check the layout, then save it as a .docx in my Craft workspace."*
2. *"Use GridCraft to build a monthly budget: income, six expense lines, a totals row with formulas and a column chart. Render it and save it as an .xlsx."*
3. *"I want to merge two PDFs. Ask me before copying ~/Downloads/a.pdf and ~/Downloads/b.pdf into PdfCraft's folder, then merge them into one file."*

How files move: an app can only see `~/craft-workspace/<app>/`. To work on one of your files, Claude asks to **copy** it into that app's `in/` folder (it never moves it). Results are written to `out/` as `<name>-YYYYMMDD-HHMM.<ext>`, and Claude tells you the full path. It never saves over an input.

[Back to top](#craft-claude-kit)

## Verify

```sh
~/.local/share/craft-claude-kit/doctor.sh            # all checks
~/.local/share/craft-claude-kit/doctor.sh --smoke    # also drive each server once with a small scripted test
~/.local/share/craft-claude-kit/doctor.sh --app wordcraft,pdfcraft
~/.local/share/craft-claude-kit/doctor.sh --brief    # only the WARN and FAIL lines, and a count per section
~/.local/share/craft-claude-kit/doctor.sh --json
claude mcp list                                      # the 13 servers should be listed
```

Inside a Claude Code session, `/mcp` lists the servers.

`doctor.sh` prints PASS, WARN or FAIL for each check, with a one-line `fix:` hint for anything that is not a pass, and exits 1 only if something FAILs. By default it checks what the install receipt says the kit installed: after `--only` just those apps, and not the skills, hooks or registrations you left out with `--no-skills`, `--no-hook` or `--no-mcp`. It checks:

- **environment**: macOS version, required tools, `claude`, the workspace folder (mode 700).
- **each app**: the program is installed at the pinned version; the MCP registration is exactly what the kit would register for your workspace (and no same-named server at local or project scope overrides it); the server starts and lists tools, launched the way Claude Code launches it (sandboxed apps through the installed `craft-sandbox`), and answers one real call in that session (the first, in-memory step of its smoke test, such as a new blank document or LightCraft's GPU setup; nothing is saved); the fence is configured. That one call catches a server that starts but crashes on real work; only `--smoke` saves, reopens and renders files, so run it once after installing. For the 8 sandboxed apps it also **tries these ways out** through the sandbox: write outside the folder, read a file in your home folder, open a network connection, and start a program through macOS (`open` of a tiny bundle doctor writes to a temp folder). It expects each attempt to be refused; other channels are not tested. For the other 5 it can only check the configuration, and says so.
- **skills**: all 14 installed, identical to the kit's sources, no leftover `{{...}}` placeholders, and every tool they mention exists in the live server.
- **hooks**: both registered, scripts present, and each answers a made-up payload correctly.
- **desktop apps** (when installed), and leftovers of an older hand-made setup.

A `WARN drift` line means the installed program's tool list differs from the one the kit recorded. It is information, not a failure. `--smoke` writes only inside `~/craft-workspace/<app>/_doctor/`, a folder it creates, marks and removes afterwards; it leaves alone a `_doctor` folder it did not create.

[Back to top](#craft-claude-kit)

## Update

```sh
cd craft-claude-kit && git pull && ./install.sh
```

A re-run uses the same workspace, `--prefix`, `--gui-dir` and app selection as before (see [Install options](#install-options)). It upgrades any app whose installed version differs from the version this kit pins, re-registers servers whose command line differs, refreshes the skills (a skill you edited is first copied to `SKILL.md.bak-<timestamp>`), re-registers the hooks and refreshes the runtime copy. Nothing updates in the background. The kit installs the versions it was verified against, not "latest": new upstream releases arrive when a new kit release re-pins them.

Desktop apps that are already installed at another version are left alone, with a warning. To switch, quit the app, move it to the Trash yourself and re-run with `--gui`.

[Back to top](#craft-claude-kit)

## Uninstall

```sh
~/.local/share/craft-claude-kit/uninstall.sh --dry-run    # show what would be removed
~/.local/share/craft-claude-kit/uninstall.sh
```

It reads the receipt the installer wrote and removes only what the kit owns: MCP servers whose command points into the kit's folders (never a registration you made yourself), the `craft-*` skills (one you edited is kept), the kit's two hook entries (with a backup of `settings.json`), `craft-sandbox`, the command-line programs the kit installed (one you replaced since, or one from an older receipt without a checksum, is kept), and the kit folder. Options: `-y`/`--yes`, `--keep-cli`, `--keep-skills`, `--keep-hooks`, and `--remove-gui`, which moves the desktop apps *the kit installed* to the Trash (not any that are running). **Your workspace is never deleted**; the uninstaller prints its path and size. Exit codes: `0` ok, `1` something could not be removed, `2` usage error, `3` no usable receipt, `4` declined or no terminal and no `--yes`. Open a new Claude Code session afterwards.

Deleted `~/.local/share/craft-claude-kit` by hand? Run `./uninstall.sh` from your clone. Without the receipt it removes what clearly belongs to the kit (its hook entries, its `craft-sandbox` and the MCP servers that run through it) and lists, with the commands to remove them, the MCP servers that point into the programs folder, the skills and the programs it cannot attribute; it exits 1 while such a server is still registered. It finds the programs folder from the registrations; pass `--prefix DIR` if that fails. A symlinked kit folder (for example a dotfiles-managed `~/.local`) is handled; the clone's `uninstall.sh` always works. Until then the hooks do no harm: their command ends in `|| true`, so a missing script never blocks a tool call. For a complete removal, run `./install.sh` first (it restores the receipt), then the uninstaller.

[Back to top](#craft-claude-kit)

## Supported Platforms

**macOS 13 or newer only**, Apple Silicon or Intel (the Craft downloads are "macos-universal" builds). It will not work on Linux or Windows: the programs are macOS builds and the fences use macOS `sandbox-exec`. The installer stops with a clear message on other systems. It targets **Claude Code** (the `claude` command line tool); it does not configure Claude Desktop.

[Back to top](#craft-claude-kit)

## Security

The short version: each server is confined to one folder, the installer only fetches pinned and checksummed files from GitHub, and two hooks add a second look at risky actions. None of this makes untrusted files harmless. Full details and how to report a problem: [SECURITY.md](SECURITY.md).

- **Downloads.** Only `https://github.com/...` release URLs from the lock file. Every file must match its pinned SHA-256 or it is deleted and that app fails. Zips with absolute paths, `..` parts or symlinks are refused. The only things run from a download are `--version` and `--help`. A matching checksum proves you got the file this kit pinned. It does not prove the upstream software is free of bugs: the kit does not audit the Craft apps.
- **No privileges, no shortcuts.** No `sudo`, no `curl | sh`. Claude Code's settings are edited only to add two hook entries (after a backup), MCP servers only through `claude mcp add/remove`. The kit adds no permission "allow" rules, so Claude Code's normal permission prompts still apply.
- **Fence for 8 apps: a macOS sandbox** (`craft-sandbox` plus `share/craft.sb`). Enforced by the kernel for the server and the programs it starts itself: no network; no reading anything else under your home folder or `/Volumes`; writing only to the app's folder, the system temp folders and a few device files; and no Mach service lookups (except Metal's shader compiler, which GPU apps need), so it cannot ask macOS to start another program outside the sandbox (an earlier profile allowed that, and such a program could read your home folder and use the network; tested, see [docs/FENCES.md](docs/FENCES.md)). Apple Events and the pasteboard were not tested separately. Limits: system files, `/Applications` and similar are still readable; `/private/tmp` is writable and shared with every other process, including the other sandboxed apps; `sandbox-exec` is deprecated by Apple and could disappear in a future macOS (the wrapper then fails closed, and `doctor.sh` tells you); and it cannot stop Claude changing the document it was given.
- **Fence for 5 apps: the app's own flags** (`--automation-read-root` and `--automation-write-root` for WordCraft, PhotoCraft, VectorCraft and EffectCraft; `--root` for PdfCraft). The installer refuses to register such an app unless its `--help` lists the flags. Whether the app enforces them correctly is up to the app; `doctor.sh` checks configuration only. These five are not network-restricted by this kit.
- **Hooks are heuristics.** One watches shell commands (the Bash tool, the terminal tool `run_in_terminal`, `Monitor`, and computer-use `open_application`) that would start a Craft app or CLI directly (which would skip the fence); `computer_batch` and other tools are not inspected. The other watches Craft MCP calls: printing, permanent delete, scripts, downloads, saves without an explicit path, `mode: "move"` imports, and any path argument that does not resolve inside that app's folder. They only ever *ask*, they fail open on any error (even a deleted script: the command ends in `|| true`), and they read text, so they can be fooled. The fences are the real control.
- **Files are data.** The skills tell Claude to treat text inside opened documents as data, never as instructions. That lowers the risk of prompt injection through a file; it does not remove it.
- **Attribution.** WordCraft is registered with `--author Claude`, so tracked changes and comments it makes are labelled.

[Back to top](#craft-claude-kit)

## What Has and Has Not Been Tested

| Tested | How |
|---|---|
| Installer, uninstaller, doctor, hooks, helpers | Automated tests (`make test`), run in a throw-away fake home with a fake `claude` and tiny fake downloads. They never touch your real Claude config. |
| The 13 servers | Driven for real, one at a time, at the pinned versions, on one Apple Silicon Mac running macOS 26: tool lists recorded in `data/tools/`, skill claims checked against the live server, and each app's smoke test (`tests/smoke/<app>.json`, 6 to 10 steps) passes under the shipped sandbox profile (13 of 13, re-run on 2026-10-15; see [docs/VERIFICATION.md](docs/VERIFICATION.md)). |
| A first install on a clean account | Run once, on a new macOS user account with no dotfiles and no Claude Code (macOS 26.6.2, Apple Silicon, 2026-10-15): the real downloads for all 13 command-line apps and all 13 desktop apps installed, skills and hooks registered, `doctor.sh --smoke` passed, a second run changed nothing, and `uninstall.sh` removed what the kit installed. That account had no Claude Code, so it used `--no-mcp`. |
| A second Mac, with Claude Code | The maintainer's second Mac (Mac mini, Apple Silicon, macOS 27.0.1, 2026-10-15), with Claude Code already installed (2.1.296 at install time; it updated itself to 2.1.301 before the doctor run). A public `git clone` and `./install.sh`: 13 of 13 apps, all 13 MCP servers registered through the real `claude mcp add`, 14 of 14 skills, 2 of 2 hooks. Then `doctor.sh --smoke` in a new Claude Code session: 152 pass, 0 warn, 0 fail. WordCraft wrote a one-page `.docx` into its `out/` folder. The shell hook showed its prompt before `wordcraft-cli --version` in accept-edits mode and in auto mode. |
| Fences | Sandbox refusals (writing outside the folder, reading your home folder, using the network, starting a program through macOS) were observed on real sandboxed servers during development. `doctor.sh` repeats the test on your machine. |

| Not tested yet | Notes |
|---|---|
| Outside testers | Both real runs were on the maintainer's own Macs. Nobody else has run it yet. |
| Intel Macs, and macOS 13 to 25 or later than 27 | The builds are universal and the kit uses only tools from macOS 13, but it has not been run there. |
| Launching the desktop apps | The kit installs them and checks their signature, but never launches them. macOS accepted all 13 (`spctl`); whether it asks you to confirm a first launch was not tested. |
| Newer upstream releases | The kit pins versions; a new release can change tool names or behaviour. `doctor.sh` shows drift. |

Known limits: the servers are headless, so window tools (`click`, `key`, `pointer`, `ui_*`, and `screenshot` in WordCraft, DesignCraft, DeckCraft, GridCraft and SoundCraft) do not work; most apps have a render or preview tool that does (GridCraft is read back with `read_range`, SoundCraft checked with `bounce_mix`). The sandbox has no network, so the apps' live-window modes (`--connect`, `--bridge`) are not used, by design. On the pinned PdfCraft 0.8.0, OCR reports itself unavailable. Details and evidence: [docs/VERIFICATION.md](docs/VERIFICATION.md).

[Back to top](#craft-claude-kit)

## FAQ

**Do I need the desktop apps?** No. Claude uses the command-line programs, which work without a window. The desktop apps are for opening documents yourself; add `--gui` if you want them.

**Can Claude open an app window or use a running app?** Not through this kit. The servers are headless and the sandbox has no network.

**Where do my files go?** See [First things to try](#first-things-to-try): copy into `~/craft-workspace/<app>/in/`, results in `out/`.

**The servers or skills do not show up in Claude Code.** They load at session start, so open a new session. Then run `claude mcp list` and `doctor.sh`. If you use `CLAUDE_CONFIG_DIR`, set it the same way for the installer, `doctor.sh` and Claude Code; `doctor.sh` warns when they disagree.

**Claude Code stopped and asked me something.** That is one of the two hooks (or Claude Code's own permission prompt). Read the reason it shows and decide. The hooks never deny.

**I set the same servers up by hand earlier.** The installer recognises that older layout (a `craft-sandbox` wrapper and profile, a `craft-shell-guard` hook, same-named servers and skills), keeps registrations that already match, replaces ones that differ, removes the old hook entry, moves the old files it recognises by content aside as `<name>.bak-craft-kit-<timestamp>` (an unrelated file of the same name is kept), replaces programs it cannot verify, and says what it did. Skills that differ are backed up first.

**Can I move the workspace?** Re-run with `--workspace DIR`. Registrations and hooks move to the new folder; your files stay where they are, and you move them yourself.

**Can I install without internet?** Download the release files yourself, put them in one folder under their original names (for example `wordcraft-cli-0.7.0-macos-universal.zip`, and `wordcraft-0.7.0-macos-universal.dmg` for the desktop app) and pass `--offline-dir`. Checksums are still verified.

**Does the kit collect or send anything?** No telemetry. The only network use is the installer's downloads from `github.com`. (`doctor.sh` makes one connection attempt to a reserved test address from *inside* the sandbox, which must be refused.) The 8 sandboxed apps cannot use the network, neither directly nor through a program they ask macOS to start (the Mach-lookup rule; doctor tests both); the other 5 are not restricted by the kit, so check those apps' own documentation if that matters to you.

**Install said something failed.** One app failing never stops the others. The summary lists what failed, with a fix for each; fix it and re-run, and finished parts are skipped. The log is `~/.local/share/craft-claude-kit/install.log`.

[Back to top](#craft-claude-kit)

## Alpha Software

The Craft apps describe themselves as alpha or early-development software (it depends on the app), and this kit inherits their maturity: expect rough edges, and expect upstream behaviour to change quickly (new releases often arrive daily). The kit pins the versions it was verified against, so you stay on a known-good set until you choose to update. See [docs/VERIFICATION.md](docs/VERIFICATION.md) for exactly what was tested.

[Back to top](#craft-claude-kit)

## Not Affiliated

craft-claude-kit is an independent community project. It is **not affiliated with, endorsed by or supported by** the authors of the Craft apps ([storytold](https://github.com/storytold)) or by Anthropic. It does not contain or redistribute their software: the installer downloads it from the official GitHub releases. Product names belong to their owners and are used only to say what works with what. Report problems in an app to its authors; report problems with the install, skills or hooks here.

[Back to top](#craft-claude-kit)

## Contributing

Bug reports and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). `make test` runs everything locally without touching your real setup. The skills' format rules are in [skills/README.md](skills/README.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

[Back to top](#craft-claude-kit)

## License

The kit is [MIT licensed](LICENSE). The Craft apps it installs are dual-licensed MIT OR Apache-2.0 by their authors, and are not part of this repository: see [NOTICE.md](NOTICE.md).

[Back to top](#craft-claude-kit)
