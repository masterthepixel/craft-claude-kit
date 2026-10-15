# How craft-claude-kit Works

What the kit puts on your Mac, how the pieces fit together, and why. Related pages:
[FENCES.md](FENCES.md) (confinement), [SKILLS.md](SKILLS.md) (the 14 skills), [APPS.md](APPS.md) (the 13
apps), [TROUBLESHOOTING.md](TROUBLESHOOTING.md), [UPDATING.md](UPDATING.md) and
[VERIFICATION.md](VERIFICATION.md) (what has and has not been tested).

## The Idea

Each Craft app ships a command-line program, `<app>-cli`, that can run as an MCP server. Claude Code starts
it, talks JSON-RPC to it over stdin and stdout, and the app's engine runs headless (no window). The kit
adds four things around those programs:

1. **Install.** It downloads the 13 programs from the apps' official GitHub releases and refuses any file whose
   SHA-256 differs from the one pinned in `manifest/apps.lock.json`.
2. **Register and fence.** It registers each program with Claude Code (user scope) using a command line that
   confines the server to one folder, `~/craft-workspace/<app>/`. That confinement is the "fence".
3. **Skills.** It installs 14 Claude Code skills that tell Claude which tools to load, in what order to use
   them, and what to avoid.
4. **Hooks.** It installs two PreToolUse hooks that ask you before risky calls. They only ever ask.

`doctor.sh` checks all of it, and `uninstall.sh` removes only what the kit installed.

[Back to top](#how-craft-claude-kit-works)

## Diagram 1: One Tool Call, End to End

```
                +----------------------------------------------------+
   you  ------> |  Claude Code session                               |
                |  reads at start-up (so: open a NEW session):       |
                |    MCP servers  ~/.claude.json            (user)   |
                |    skills       ~/.claude/skills/craft-*           |
                |    hooks        ~/.claude/settings.json            |
                +--------------------------+-------------------------+
                                           |  tool call, for example
                                           |  mcp__gridcraft__save_workbook
                                           v
                +----------------------------------------------------+
                |  PreToolUse hooks   (ask only, fail open, 10 s)    |
                |    Bash            craft-shell-guard.py            |
                |    mcp__<app>__*   craft-mcp-guard.py              |
                +--------------------------+-------------------------+
                                           |  allowed, or you said yes
                                           v  JSON-RPC over stdin/stdout
   +-------------------------------------------------------------------------+
   |  one server process per app, started by Claude Code                      |
   |                                                                         |
   |  fence "roots"    wordcraft-cli mcp --automation-read-root R            |
   |  (4 apps)                           --automation-write-root R           |
   |  fence "root"     pdfcraft-cli mcp --root R                             |
   |  (1 app)                                                                |
   |  fence "sandbox"  craft-sandbox R gridcraft-cli mcp                     |
   |  (8 apps)           '-> sandbox-exec -f craft.sb ... gridcraft-cli mcp  |
   +------------------------------------+------------------------------------+
                                        |  reads and writes only
                                        v
                        ~/craft-workspace/<app>/      in/   out/
                        (R = that folder, mode 700)
```

`R` is `~/craft-workspace/<app>` written as an absolute path (the folder is configurable with
`--workspace`). Registrations use absolute paths everywhere, so your `PATH` does not matter to Claude Code.
Claude Code owns the servers' lifetime; the kit never starts, stops or kills a server (only `doctor.sh` and the
maintainers' test client start one briefly, and they clean up their own process group).

In words:

1. When a session starts, Claude Code loads the registrations, the skills and the hooks. Anything installed
   later is invisible to sessions that are already open.
2. Claude sees the description of every skill. When a task matches (say, a spreadsheet), the body of that
   skill is loaded, and it tells Claude which tools to fetch by exact name (`ToolSearch select:...`).
3. Before a shell call (Bash, `mcp__terminal__run_in_terminal`, `Monitor`, computer-use `open_application`) or any
   `mcp__<app>__*` call, Claude Code runs the matching hook. If the hook says "ask",
   you decide. If it prints nothing, the call goes ahead as normal; the hooks print nothing on any internal error
   (they fail open), and each is registered with a 10-second timeout.
4. The call goes to the server process as JSON-RPC. For a `sandbox` app the process is `craft-sandbox`, which
   changes into the app folder and replaces itself with `sandbox-exec`, which runs the program under the profile
   `share/craft.sb`. For the other five, the program itself is started with the fence flags.
5. The server can read and write the app folder, and (for sandbox apps) the system temp folders, and nothing
   else that the fence covers. [FENCES.md](FENCES.md) says exactly what that means for each app.

[Back to top](#how-craft-claude-kit-works)

## Diagram 2: Where the Pieces Live

```
 YOUR CLONE of the repository (anywhere; after installing you need it only to upgrade)
   install.sh   manifest/apps.lock.json   skills/   hooks/   bin/   share/   lib/   data/   tests/smoke/
        |
        |  install.sh: (1) downloads each <app>-cli zip from github.com and checks its SHA-256
        |  against the lock, (2) copies the runtime files, (3) renders the skills,
        |  (4) registers the servers and the hooks, (5) writes receipt.json
        v
 ~/.local/bin/                                     --prefix
     <app>-cli  (13)         <--- named by the 13 registrations in ~/.claude.json
     craft-sandbox           (a copy of bin/craft-sandbox) ---- loads ----+
                                                                           |
 ~/.local/share/craft-claude-kit/                  CRAFT_KIT_HOME, the RUNTIME COPY
     share/craft.sb          <---------------------------------------------+
     hooks/                  craft-shell-guard.py  craft-mcp-guard.py  risky-tools.json
                             <--- run by two PreToolUse entries in ~/.claude/settings.json
     doctor.sh  uninstall.sh  VERSION  lib/  manifest/apps.lock.json  data/tools/  tests/smoke/
     bin/craft-sandbox       receipt.json  install.log
 ~/.claude/skills/craft-*/SKILL.md   (14, rendered) mention the absolute workspace path
                             and <runtime copy>/doctor.sh; no "~" and no placeholders are left
 ~/craft-workspace/<app>/in/  out/   (mode 700) the only folder each server may use
 /Applications/<App>.app             only with --gui; the kit never launches it
```

Everything the system needs after installation lives at the paths listed below the clone, and none of it in the clone, so
deleting or moving your clone breaks nothing. The paths are the defaults; `--prefix`, `--workspace`, `--gui-dir`,
`CRAFT_KIT_HOME` and `CLAUDE_CONFIG_DIR` move them.

[Back to top](#how-craft-claude-kit-works)

## What Goes Where

| Path (defaults) | What it is | Written by | Removed by `uninstall.sh` |
|---|---|---|---|
| `~/.local/bin/<app>-cli` (13) | The command-line programs | `install.sh` | Yes (not with `--keep-cli`) |
| `~/.local/bin/craft-sandbox` | Sandbox wrapper, a copy of `bin/craft-sandbox` | `install.sh` | Yes, if it is the kit's |
| `~/.local/share/craft-claude-kit/` | Runtime copy, `receipt.json`, `install.log` | `install.sh` | Yes (see below) |
| `~/craft-workspace/<app>/in`, `out` | Your working folders, mode 700 | `install.sh` | **Never** |
| `~/.claude.json` (user scope) | The 13 server registrations | `claude mcp add` / `remove` | Yes, only ones whose command is the kit's |
| `~/.claude/skills/craft-*/SKILL.md` (14) | The rendered skills | `install.sh` | Yes, unless you edited one |
| `~/.claude/settings.json` | Two `PreToolUse` hook entries | `lib/settings_edit.py`, backup first | Yes (the two entries) |
| `/Applications` or `~/Applications` | Desktop apps, only with `--gui` | `install.sh` | Only with `--remove-gui`, to the Trash |

If you set `CLAUDE_CONFIG_DIR`, the skills and `settings.json` live there and the registrations are in
`$CLAUDE_CONFIG_DIR/.claude.json`. `--prefix`, `--workspace`, `--gui-dir` and `CRAFT_KIT_HOME` move the other
rows. The installer shows every path it will touch in its plan before it changes anything.

The kit never edits `~/.claude.json` itself: registrations are made only through the `claude mcp add` and
`claude mcp remove` commands. It edits `settings.json` only to add or remove its own two hook entries, with one
backup per run (`settings.json.bak-craft-kit-<timestamp>`, the file as it was before the run) made before the first
change, and refuses to touch a file that is not strict JSON. Each hook command is
`python3 <kit>/hooks/<script> --workspace <workspace> || true`: Claude Code treats a hook's exit code 2 as "block
this tool call", and python3 exits 2 when the script is missing, so the `|| true` keeps a deleted kit folder from
blocking every Bash or Craft call. The hooks answer only through JSON printed on exit 0, so nothing is lost.

What the MCP guard checks beyond its per-tool table (details and limits in [FENCES.md](FENCES.md) and
[SECURITY.md](../SECURITY.md)): a save or export (a tool or command id whose name contains save, export, bounce,
render, publish or wblock) whose `path` already exists, or whose `path`/`dir` is inside `<app>/in/`; a relative or
`$N.path` placeholder path in a save; each line of a runner's `script`/`steps`/`commands` text, read as
`<command id> {json}`; and, for CADCraft `command_line` and `script`, every typed word compared with a word list of
printing, file and LISP commands and their aliases (a first-word or whole-word heuristic, not a parser; the
aliases were listed by hand from the live command list).

[Back to top](#how-craft-claude-kit-works)

## The Runtime Copy (`CRAFT_KIT_HOME`)

`install.sh` copies the parts of the repository that must keep working after you delete or move your clone
into `~/.local/share/craft-claude-kit/`:

```
doctor.sh  uninstall.sh  VERSION
lib/                  craftkit.py  mcp_probe.py  doctor_checks.py  settings_edit.py  common.sh
manifest/apps.lock.json
data/tools/           one tool snapshot per app (used by the drift check)
tests/smoke/          one smoke-test script per app (used by doctor --smoke)
hooks/                craft-shell-guard.py  craft-mcp-guard.py  risky-tools.json   (not hooks/tests)
share/craft.sb        the sandbox profile
bin/craft-sandbox     the wrapper (PREFIX/craft-sandbox is a copy of this)
receipt.json          what this installation did
install.log           append-only log of every installer run
```

Why a copy: the hook entries in `settings.json`, the skills' `{{KIT_HOME}}` references and the sandbox wrapper
all point at this folder, so they do not break when the clone moves; `doctor.sh` and `uninstall.sh` run from
here; and the profile `craft-sandbox` loads is the one in `share/craft.sb` here. To upgrade you need a clone
again (`git pull && ./install.sh`). The skills are not copied here: they are rendered straight into
`~/.claude/skills/`. `doctor.sh` compares them with the sources in your clone (it finds the clone through
`repoDir` in the receipt) and says so when it cannot.

If you use a `CRAFT_KIT_HOME` other than the default, the installer pins that folder into the copy of the wrapper
it puts in the prefix, so the wrapper finds its profile without that variable being set in Claude Code's
environment. `CRAFT_KIT_HOME` must be a new or empty folder (or an earlier kit folder, recognized by its
`receipt.json` or `install.log`), and must not be or contain `--prefix`, the Claude Code folder or `--gui-dir`:
the uninstaller deletes the kit's files under its fixed names (`bin`, `share`, `hooks`, `lib` ...) inside it. The installer refuses
other folders at preflight.

[Back to top](#how-craft-claude-kit-works)

## The Receipt

`receipt.json` is written atomically at the end of every install run, including a run that partly failed. It is
how `uninstall.sh` knows what the kit owns and how `doctor.sh` finds your workspace and prefix without flags.

```json
{
  "schema": 1,
  "kitVersion": "0.1.0",
  "installedAt": "2026-10-14T09:00:00Z",
  "repoDir": "/Users/you/src/craft-claude-kit",
  "kitHome": "/Users/you/.local/share/craft-claude-kit",
  "workspace": "/Users/you/craft-workspace",
  "prefix": "/Users/you/.local/bin",
  "claudeDir": "/Users/you/.claude",
  "claudeConfigDirEnv": null,
  "claudeJson": "/Users/you/.claude.json",
  "guiDir": "/Applications",
  "lock": "/Users/you/src/craft-claude-kit/manifest/apps.lock.json",
  "apps": { "wordcraft": { "version": "0.7.0", "fence": "roots", "cli": true, "gui": false, "registered": true } },
  "skills": ["craft-apps", "craft-wordcraft"],
  "skillsSha256": { "craft-apps": "<sha256 of the installed file>" },
  "hooks": [ { "matcher": "Bash|mcp__terminal__run_in_terminal|Monitor|mcp__computer-use__open_application", "command": "python3 /Users/you/.local/share/craft-claude-kit/hooks/craft-shell-guard.py --workspace /Users/you/craft-workspace || true" } ],
  "components": { "mcp": true, "skills": true, "hooks": true }
}
```

(Abbreviated: `apps` has one entry per app, `skills` lists all 14 and `hooks` has two entries. The paths are examples.)
The recorded SHA-256 of each installed skill is how the next install, and the uninstaller, can tell "unchanged
since install" from "you edited it". `components` records what `--no-mcp`, `--no-skills` and `--no-hook` left out,
so `doctor.sh` does not report those as failures. A re-run reads `workspace`, `prefix`, `guiDir` and the `apps`
keys back, so the update command keeps your choices.

[Back to top](#how-craft-claude-kit-works)

## What `install.sh` Does, in Order

1. **Preflight.** Checks macOS 13+, `curl`, `unzip`, `shasum`, `jq`, `python3` 3.9+ (and that it runs at all: on a
   Mac without the Command Line Tools `/usr/bin/python3` only offers to install them), and (unless `--no-mcp`) the
   `claude` command and `/usr/bin/sandbox-exec`; with `--gui` also `hdiutil` and `ditto`. It validates every field
   of the lock (sizes are whole numbers, URLs are `https://github.com/`, bundle names are plain `<Name>.app`,
   `extraArgs` is the known per-app list and never a fence flag) and the folders (see `CRAFT_KIT_HOME` above).
   Anything wrong is listed with a fix, and nothing is changed (exit 3).
2. **Plan, read-only.** For each app it checks the installed program: if its SHA-256 is the one the receipt
   recorded when the kit installed it, it compares its `--version` with the lock (skip or upgrade); any other file
   of that name is marked `replace*` and is not run; no file means install. It reads the existing registration and compares it with what the kit would register (add, already
   right, replace, or "no fence flag"), looks at the desktop app, the skills and the hooks, estimates disk space,
   and prints the download sizes and every file or setting it may create or change. `--dry-run` stops here and
   creates nothing, not even a log file.
3. **Confirm.** One prompt. Without a terminal it exits 4 unless `--yes` is given. Desktop apps are asked about
   only when neither `--gui` nor `--no-gui` was given and a terminal is attached.
4. **Runtime.** Copies the runtime files into `CRAFT_KIT_HOME`, installs `craft-sandbox` into the prefix (an
   unrelated file of that name is kept as `craft-sandbox.bak-<timestamp>`), and moves the older hand-made
   `craft-sandbox` profile aside if one is there (see "Migration From an Older Hand-Made Setup" below).
5. **Each app, one at a time.** Download from the lock URL (`curl -fL --proto '=https' --tlsv1.2 --retry 3`, and
   a transfer that stalls under 1 KB/s for 60 s fails and is retried; curl's own reason is shown; only
   `https://github.com/` URLs are accepted); verify the SHA-256 (mismatch: delete the file, fail that app);
   list the zip and refuse absolute paths, `..` parts and symlinks; extract the one file named `<app>-cli`; stage
   it beside its destination; run it with `--version` and require the pinned version; move it into place
   atomically. Then create `<workspace>/<app>/{in,out}` with mode 700, and register the server. The only things
   run from a download are `--version` and `--help`.
6. **Desktop apps** (only if chosen). Download the disk image, verify its SHA-256, mount it read-only and
   `-nobrowse`, copy the bundle with `ditto` to a temporary name, detach (always, also on Ctrl-C), require
   `codesign --verify --deep --strict` to pass, then move it into place and report what `spctl --assess` says. An
   app that is already installed at another version is left alone, with a warning.
7. **Skills.** Renders `skills/*/SKILL.md` (replacing `{{WORKSPACE}}` and `{{KIT_HOME}}`) into
   `~/.claude/skills/<name>/SKILL.md`. Identical: skipped. Different and not the kit's own earlier output: your
   copy is saved as `SKILL.md.bak-<timestamp>` first. A symlinked skill is left alone.
8. **Hooks.** Test-runs each hook script with an empty payload, removes an outdated entry of the kit's own if there
   is one, and adds the two entries through `lib/settings_edit.py` (each with a 10-second timeout).
9. **Receipt and summary.** Writes `receipt.json`, prints a table of what happened per app, and the next steps
   (open a new Claude Code session; run `doctor.sh`).

Properties:

- **Registration is fail-closed.** For `roots` and `root` apps the installer runs `<app>-cli --help` and
  registers the server only if the fence flags are listed. It also checks that the command line it computed
  really contains the workspace folder in the fence position. If either check fails, that app is **not**
  registered (an existing registration is left unchanged, with a warning) and the summary says why. See
  [FENCES.md](FENCES.md).
- **Registration is idempotent.** It reads the current user-scope entry. Identical (command, arguments and no
  extra settings such as `env`): skipped. Different: it runs `claude mcp remove <app> -s user` and then
  `claude mcp add -s user <app> -- <command and args>`, and says so. Before the remove it saves the whole
  previous entry (`env` included) to `<kit folder>/backup/<app>-mcp-<timestamp>.json` (mode 600) and lists it in
  the summary. If the add fails, it re-adds the previous command and arguments (an `env` the old entry had is not
  restored; the message says so); if that fails too, the error names the backup file. A server of that name
  registered at another scope is not touched.
- **One app failing never stops the others.** The summary lists failures, the exit status is 1, and re-running
  repairs only what is missing. Temporary folders and mounted images are cleaned up on exit and on Ctrl-C.
- **Pinned means pinned, and verified means verified.** If a program the kit installed reports any version other
  than the pinned one (older or newer), the plan shows it as an upgrade and replaces it with the pinned version,
  because that is the version the kit's skills and tests were checked against. A program the kit did not install
  (or that changed since) is replaced too, without being run first. The receipt records the SHA-256 of each
  program it installed (`cliSha256`) and the version of each desktop app (`guiVersion`), so the uninstaller
  removes only those exact files and bundles.

[Back to top](#how-craft-claude-kit-works)

## Migration From an Older Hand-Made Setup

The kit was extracted from a hand-made version of the same idea: a hook script at
`~/.local/share/craft-skills/craft-shell-guard.py`, a sandbox profile at
`~/.local/share/craft-sandbox/craft.sb`, a `~/.local/bin/craft-sandbox` wrapper, servers registered by hand and
skills copied by hand. If the installer finds those it keeps registrations that already match, replaces ones that
differ, removes the old hook entry, moves the old hook script and the old profile aside as
`<name>.bak-craft-kit-<timestamp>` (the profile only when nothing outside `--prefix` still uses it), replaces the
old wrapper and the programs it cannot verify, backs up skills that differ, and says what it did. It recognizes the
old files by content (a hook script that mentions Craft and answers PreToolUse; a profile with `(version 1)` and a
`ROOT` parameter); an unrelated file at one of those paths is kept, with a warning. `doctor.sh` reports leftovers
(`legacy` checks) and points back to the installer. (This path is tested against a fake home that contains such
a setup, [VERIFICATION.md](VERIFICATION.md); the author's own machine is the only real setup the migration has encountered.)

[Back to top](#how-craft-claude-kit-works)

## What `doctor.sh` Does

It changes nothing except what `--smoke` creates (and removes). It checks what the receipt lists (the apps of an
`--only` install; not the parts left out with `--no-*`) unless `--app` says otherwise. For the environment, each app, the skills, the
hooks, the desktop apps and old leftovers it prints PASS, WARN or FAIL with a one-line fix, and exits 1 only if
something FAILs. Per app it starts the server for a moment, lists its tools, compares them with
`data/tools/<app>.json`, and for sandbox apps tries four harmless ways out of the sandbox (write outside the folder, read under the home folder, network, start a program through macOS).
The servers it starts are launched with the same arguments as the registration. When the registration is the
expected one, sandbox apps go through the installed `<prefix>/craft-sandbox`, which finds its profile the way it
does under Claude Code, so an outdated wrapper shows up here. Otherwise (not registered yet, or registered
differently) they go through the kit's own copy of the wrapper and profile, and the detail says so.

`--smoke` also drives each server through `tests/smoke/<app>.json` inside `<workspace>/<app>/_doctor/`, a folder
it creates with a marker file and removes afterwards (also on failure or Ctrl-C). A `_doctor` without the marker
(one you made) is left alone and the smoke test is skipped with a WARN; a `_doctor` that is a symlink or a file is a
FAIL and is not touched either. Every check id, what it means and how to fix it:
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). How the sandbox probe works: [FENCES.md](FENCES.md).

[Back to top](#how-craft-claude-kit-works)

## What `uninstall.sh` Does

Reads the receipt (refuses a receipt whose paths look wrong), prints what it will remove and what it keeps, asks
once, then removes in this order:

1. MCP registrations whose command is the kit's: `<prefix>/<app>-cli`, `<prefix>/craft-sandbox`, or a file inside
   the kit folder. A registration of that name that points somewhere else is kept and reported. (A hand-made
   registration that uses exactly `<prefix>/<app>-cli` counts as the kit's.) The plan lists every name it will
   delete inside the kit folder. A receipt whose kit folder contains the prefix, the Claude folder or the
   workspace is refused, and a symlinked kit folder (the receipt's path and this script's real path are the same
   folder) is accepted.
2. The kit's hook entries (with a backup of `settings.json`),
3. The skills that are unchanged since install (an edited or symlinked one is kept),
4. Desktop apps, only with `--remove-gui`, only ones the receipt says the kit installed and still at the version
   it recorded, not running ones, moved to the Trash,
5. The `<app>-cli` programs that still have the SHA-256 the kit recorded (a program you replaced since, or one
   from an older receipt without a SHA-256, is kept and listed), and `craft-sandbox`,
6. The kit folder. Inside its folders (`lib`, `hooks`, `share` ...) it removes only the files the receipt lists
   under `kitFiles` (what the installer copied), so a file you added there is kept and listed, and so is
   `backup/` (the MCP registrations the installer replaced). A receipt from before `kitFiles` existed falls back to
   removing those folders whole. It keeps the folder if a hook still references its scripts (`--keep-hooks`) or
   something failed, so you can run it again.

**It never deletes your workspace**; it prints the path and size.

If the kit folder itself is gone (deleted by hand), `uninstall.sh` run from the clone has no receipt. It takes the
programs folder from the registrations (or `--prefix DIR`), then removes only what clearly belongs to the kit:
hook entries that run scripts from the missing folder, a `craft-sandbox` that carries the kit's marker, and the MCP
servers that run through it. It lists the MCP servers that run a program in that folder directly (they may be
yours) with the `claude mcp remove` command for each, and prints `rm` commands for the skills and programs it
cannot attribute without the receipt. While such a server is still registered it exits 1 and does not claim
success.

[Back to top](#how-craft-claude-kit-works)

## Design Decisions

- **Headless command-line apps by default.** Claude drives an engine, not a window. The desktop apps are
  optional and the kit never launches them. The window-only tools (`click`, `key`, `pointer`, `ui_*`, and
  `screenshot` in some apps) do not work headless; every app except GridCraft and SoundCraft has a render or
  preview tool instead ([APPS.md](APPS.md)).
- **User-scope registration with absolute paths.** One registration works in every project and does not depend on
  `PATH`, the current directory or shell start-up files.
- **Pinned versions and checksums, not "latest".** Skills and tests are checked against specific versions; a new
  upstream release arrives when a new kit release re-pins it ([UPDATING.md](UPDATING.md)).
- **One folder per app.** A server sees only `<workspace>/<app>/`. Cross-app work is explicit copying.
- **The sandbox profile starts from "allow" and subtracts.** The apps are large and load many system
  frameworks; an allow-list profile would break with every release. The profile removes the network, the
  user's own files and writes to the rest of the disk. Cost: system files stay readable, and the temp folders are
  shared ([FENCES.md](FENCES.md)).
- **Hooks only ask, and fail open.** A guard that can block by mistake would make the kit unusable; one that
  asks is a prompt that can be read and overruled. They are heuristics, not a security boundary.
- **No `sudo`, no `curl | sh`, no quarantine or Gatekeeper tricks, no background updater, no telemetry.** The
  only network use is the installer's downloads from `github.com`.
- **Portable tooling.** Shell scripts run on macOS's bash 3.2; Python helpers use only the standard library
  (3.9+). There is nothing to `pip install`.
- **Skills carry only facts that were checked** against the live servers, and do not repeat what a server already
  says about itself ([SKILLS.md](SKILLS.md)).

[Back to top](#how-craft-claude-kit-works)

## What the Kit Does Not Do

It does not configure Claude Desktop or claude.ai, add permission "allow" rules, touch MCP servers it did not
create, manage project-scope or local-scope registrations, launch the desktop apps, audit the Craft apps'
code, or make documents from untrusted sources safe to open. Files are data: the skills tell Claude never to
follow instructions found inside them, which reduces but does not remove the risk of prompt injection through a
file.

[Back to top](#how-craft-claude-kit-works)
