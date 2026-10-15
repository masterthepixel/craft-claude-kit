# Troubleshooting

Start here, whatever is wrong:

```sh
~/.local/share/craft-claude-kit/doctor.sh              # everything
~/.local/share/craft-claude-kit/doctor.sh --app gridcraft   # one app (comma-separate several)
~/.local/share/craft-claude-kit/doctor.sh --json       # machine-readable, for a bug report
```

Before the first install, run `./doctor.sh` from your clone instead. Every line is `PASS`, `WARN` or `FAIL`, and
every non-pass line has a `fix:` hint. Exit status: 0 if nothing FAILs (WARN does not fail), 1 if something FAILs,
2 for a usage error. Fix the first FAIL, then run it again: later lines often depend on earlier ones.

Other options: `--brief` (only WARN and FAIL lines, plus a count of passed checks per section), `--smoke` (also drive each server with its scripted test), `--workspace DIR` and `--prefix DIR`
(default: the install receipt's, else `~/craft-workspace` and `~/.local/bin`), `--gui` and `--gui-dir DIR` (check the
desktop apps even if the receipt does not list them). `--json` prints `{"summary": {...}, "checks": [{scope, id,
status, detail, hint}]}`. `doctor.sh` changes nothing, except that it starts each server for a moment and (with
`--smoke`) writes and then removes a `_doctor` folder.

Contents: [Quick Answers](#quick-answers) | [Every Doctor Check](#every-doctor-check) |
[Installer Messages](#installer-messages) | [Messages You May See From the Apps](#messages-you-may-see-from-the-apps) |
[Gatekeeper and macOS Prompts](#gatekeeper-and-macos-prompts) | [Uninstaller](#uninstaller) |
[Reporting a Problem](#reporting-a-problem)

## Quick Answers

**The servers or skills do not appear in Claude Code.** Claude Code reads MCP servers, skills and hooks when a
session starts. Open a **new** session after installing, upgrading or changing anything. Then:

- `claude mcp list` should list the 13 servers; inside Claude Code, `/mcp` does too. `claude mcp get <app>` shows
  the command line Claude Code will use.
- Run `doctor.sh`. `mcp-registered` says whether the registration is there and correct.
- If you use `CLAUDE_CONFIG_DIR`, set it the same way for the installer, `doctor.sh` and Claude Code. The installer
  records which config it used; `doctor.sh` warns (`claude-config`) when your shell uses another. Registrations
  then live in `$CLAUDE_CONFIG_DIR/.claude.json`, not `~/.claude.json`.
- The kit manages **user scope** only. A server of the same name registered at local scope (`claude mcp add`
  without `-s`, stored per folder in `.claude.json`) or project scope (`.mcp.json`) wins in that folder, and it is
  not fenced unless it is identical. The installer's plan and `doctor.sh` (`mcp-shadowed`) warn about the ones they
  can see: local scope for any folder, project scope for folders Claude Code has recorded. If
  `claude mcp get <app>` shows a command that is not the kit's, that is why.

**`/mcp` shows a server as failed or disconnected.** Run `doctor.sh --app <app>`. Its `server-starts` check starts
the server with the same arguments as the registration and prints the error if it does not answer. The usual
causes: the program was deleted or replaced (`cli-installed`), the app folder was removed (`workspace`), the
sandbox wrapper or profile is gone (`env/craft-sandbox`, `env/sandbox-profile`), or a sandboxed app is crashing
with `code -11` (see [Sandbox Problems](#sandbox-problems)). Fix it, then open a new session.

**`claude: command not found`, or the installer says "Claude Code CLI not found".** The installer needs the
`claude` command to register servers. Install Claude Code, open a new terminal so `PATH` is refreshed, check
`command -v claude`, and re-run. If it is installed somewhere unusual: `CLAUDE_BIN=/full/path/to/claude ./install.sh`.
To install the programs, skills and hooks without registering servers, pass `--no-mcp` (then register later by
re-running without it).

**`jq` is missing.** macOS 15 and newer ship `/usr/bin/jq`; on older macOS run `brew install jq`. The installer,
uninstaller and doctor all need it.

**`python3` is missing or too old.** The kit needs 3.9 or newer. `xcode-select --install` installs the Command Line
Tools, which include `python3`. Check with `python3 --version`.

**`PATH` problems.** The kit does not rely on `PATH` for the servers: every registration uses absolute paths, so
`~/.local/bin` need not be on your `PATH` for Claude Code to start them. `PATH` matters in three places only: the
installer must find `claude`, `curl`, `jq` and `python3`; the two hooks run `python3`, resolved from the environment
Claude Code was started in; and running `<app>-cli` by hand needs the prefix on `PATH` (the shell guard hook will ask
before Claude does that). If Claude Code shows hook errors on every tool call, check that `python3` is on the `PATH`
it was started with.

**Claude Code stopped and asked for confirmation.** One of the two hooks, or Claude Code's own permission prompt. The hook's
reason starts with "Craft guard:" and says what it noticed (a command that would launch a Craft program from a
shell, a save without a path, a path outside the app folder ...). Decide. The hooks never deny, and the kit adds no
permission rules. They are heuristics, so they can also ask about harmless things.

**Removing the hooks.** Re-installing with `--no-hook` does not remove existing entries. To remove them:

```sh
K=~/.local/share/craft-claude-kit
for h in craft-shell-guard.py craft-mcp-guard.py; do
  python3 "$K/lib/settings_edit.py" remove-hook --settings ~/.claude/settings.json \
    --event PreToolUse --command-contains "$K/hooks/$h"
done
```

(Use `$CLAUDE_CONFIG_DIR/settings.json` if you set that variable. The command backs up `settings.json` first.)
`doctor.sh` will then FAIL the `hooks` checks, which is accurate.

**A tool failed with "Operation not permitted" or "outside the ... root".** The fence is working: the path is not
in that app's folder. Copy the file into `~/craft-workspace/<app>/in/` (Claude should ask first) and use that path.

**A save failed with "No such file or directory".** The `out/` folder does not exist inside the app folder
(`mkdir -p ~/craft-workspace/<app>/out`), or the path is wrong. The installer creates `in/` and `out/`; some apps do not
create missing parent folders themselves. Also make sure the path is absolute: no app expands `~`.

**The server dies with "exited (code -11)".** See [Sandbox Problems](#sandbox-problems).

**Everything worked, then stopped after a macOS update.** Run `doctor.sh`. The `sandbox-exec`, `fence-live` and
`server-starts` lines show whether the sandbox or a program changed behavior. `sandbox-exec` is deprecated by
Apple ([FENCES.md](FENCES.md#sandbox-exec-is-deprecated)).

**Many `<app>-cli mcp` processes are running, and the Mac is slow.** Every Claude Code session starts its
own copy of each server it uses, and each copy is a separate process (memory use was not measured). Check with
`pgrep -fl -- '-cli mcp'`. Closing the sessions you do not need ends their servers. A server left behind by a
crashed session can be ended manually (`kill <pid>`); the kit never kills processes itself, because it cannot know
which ones belong to which session.

**Linux, Windows, Intel Macs and older macOS.** Linux and Windows are not
supported (the programs are macOS builds and the fences use macOS `sandbox-exec`); the installer stops with a
message. Intel Macs and macOS 13 to 25 are expected to work (the downloads are universal and the kit uses only
tools that ship since macOS 13) but have not been tried. See [VERIFICATION.md](VERIFICATION.md).

[Back to top](#troubleshooting)

## Every Doctor Check

Checks are grouped by scope: `env`, one block per app (named by the app), `skills`, `hooks`, `gui`, `legacy`. If a
check cannot run because an earlier one failed, it is a WARN that says so.

### `env`

| Id | Status | Meaning and fix |
|---|---|---|
| `python3` (before anything else) | FAIL | `python3` is missing, older than 3.9, or the kit's `lib/doctor_checks.py` is missing. `xcode-select --install`, or re-clone / re-run the installer. |
| `macos` | FAIL | Not macOS, or older than 13. Linux and Windows are unsupported. |
| `arch` | WARN | Not `arm64` or `x86_64`. The Craft builds are universal for those two. |
| `sandbox-exec` | FAIL | `/usr/bin/sandbox-exec` is missing, so the eight sandboxed apps cannot be fenced and will not start. |
| `tool-curl`, `tool-unzip`, `tool-shasum`, `tool-jq`, `tool-python3` | FAIL | The tool is not on `PATH`; the installer needs it. The hint names the fix (`xcode-select --install`, `brew install jq`). |
| `claude` | FAIL / WARN | FAIL: the Claude Code CLI is not found (`CLAUDE_BIN` or `PATH`). WARN: it is found but does not report a version; reinstall it. |
| `kit` | FAIL | The copy of the kit doctor runs from is incomplete (a file under `lib/`, `bin/`, `share/` or `manifest/` is missing). Re-clone, or re-run `install.sh` to refresh `~/.local/share/craft-claude-kit`. |
| `lock` | FAIL | `manifest/apps.lock.json` cannot be read or has no apps. Re-clone. |
| `receipt` | WARN | No receipt (not installed yet, or installed with another `CRAFT_KIT_HOME`), an unreadable one, or one written by another kit version. Run `install.sh`. |
| `claude-config` | WARN | The kit was installed into a different Claude config folder than this shell uses. Start Claude Code (and doctor) with the same `CLAUDE_CONFIG_DIR`, or re-run the installer in the right environment. |
| `workspace` | FAIL / WARN | FAIL: the workspace folder is missing (`--workspace DIR` if you installed elsewhere). WARN: its mode lets other users look inside (`chmod 700`, or re-run `install.sh`, which makes the kit's folders private). |
| `craft-sandbox` | FAIL / WARN | Shown only if a sandboxed app is selected. FAIL: the wrapper `PREFIX/craft-sandbox` is missing. WARN: it differs from the kit's `bin/craft-sandbox` (older or edited). Claude Code runs the sandboxed servers through it, and an older wrapper can make GPU work crash (seen with LightCraft; `--smoke` shows it). Re-run `install.sh`. |
| `sandbox-profile` | FAIL / WARN | Shown with `craft-sandbox`. FAIL: no profile at `~/.local/share/craft-claude-kit/share/craft.sb`. WARN: it differs from the kit's, only the older hand-made profile exists, or `CRAFT_SANDBOX_PROFILE` is set in this shell and overrides the kit's (unset it unless you mean it). |

### Each App

| Id | Status | Meaning and fix |
|---|---|---|
| `cli-installed` | FAIL / WARN | FAIL: `<prefix>/<app>-cli` is missing, not executable, hangs on `--version`, reports a version other than the one in the lock, or is not the file the kit verified (its SHA-256 differs from the receipt's). `./install.sh --only <app> --yes` installs the pinned, verified version. (If you deliberately run a newer program, this is expected; the kit's skills were checked against the pinned one.) WARN: the receipt is older and has no SHA-256 to compare; a re-run records it. |
| `workspace` | FAIL / WARN | FAIL: the app folder is missing, or is a **symlink** (a fence would follow it; replace it with a real folder). WARN: mode lets others look inside. |
| `mcp-registered` | FAIL / PASS | PASS with "not checked" after an install with `--no-mcp`. FAIL: no user-scope server with this name in `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), or it differs from what the kit would register for your workspace (the detail shows which part: type, command, or arguments), or the config file is not valid JSON. `./install.sh --only <app>` re-registers it (replacing a differing one). |
| `mcp-shadowed` | WARN | Shown only when found: the app is also registered at local scope (for one folder) or in a project's `.mcp.json`, with a different command. In that folder Claude Code uses that one, unfenced. The `fix:` line has the `claude mcp remove ... -s local` command (or names the `.mcp.json`). |
| `fence-config` | FAIL / WARN | See [FENCES.md](FENCES.md). roots/root apps: FAIL if `--help` does not list the flag (the app is not started unfenced) or the registration does not pass your folder to it; WARN if the program is not usable so the flag cannot be checked. sandbox apps: FAIL if the registered command is not `craft-sandbox` (the server would run **unfenced**), its root is not your app folder, or it runs a different program; or if the wrapper is missing. |
| `server-starts` | FAIL / WARN | FAIL: the server did not answer `initialize` or `tools/list`. The detail says how it was started (as registered, or as the installer would register it when the registration differs); the `fix:` line is the exact `mcp_probe.py ... list-tools` command that shows the full error. WARN: not started because `cli-installed`, `workspace` or `fence-config` failed first. |
| `tools-list` | FAIL | The server started but lists no tools. |
| `drift` | WARN | The server's version differs from the lock, or its tool names differ from the kit's recorded snapshot (the detail lists those added and removed), or there is no snapshot. It is informational. If the program is the pinned version, the kit's data is stale: please report it. |
| `fence-live` | FAIL / WARN | Sandbox apps only. FAIL: the wrapper does not run, or the write, read, network or launch-through-macOS probe was **not** refused. The sandbox is not in force; do not use the app until fixed. WARN: a probe could not be tried (no folder to write to, no kit file under your home folder) and nothing was allowed. [FENCES.md](FENCES.md) explains the probes. |
| `smoke` | FAIL / WARN | With `--smoke`. FAIL: a step failed (the detail names step, tool and reason; the `fix:` line is the exact command to rerun it by hand), or `<workspace>/<app>/_doctor` exists and is a symlink or a file (remove it). WARN: no smoke script, not run because an earlier check failed, or a `_doctor` folder that doctor did not create already exists (`doctor.sh` leaves it alone; rename or remove it). `doctor.sh` creates `_doctor` with a marker file and removes it afterwards; a marked folder left by an interrupted run is replaced. |

### `skills`

| Id | Status | Meaning and fix |
|---|---|---|
| `installed` | FAIL / PASS | PASS with "not checked" after an install with `--no-skills`. FAIL: some of the 14 `craft-*` skills are missing in `~/.claude/skills` (or `$CLAUDE_CONFIG_DIR/skills`). Re-run `install.sh`. |
| `rendered` | FAIL | An installed skill still contains a `{{...}}` token, so it was copied rather than rendered. Re-run `install.sh`. |
| `up-to-date` | WARN | An installed skill differs from the kit's rendered source (you edited it, or it is older). Re-run `install.sh`; yours is saved as `SKILL.md.bak-<timestamp>`. WARN "not compared" when it cannot find the kit's skill sources (the clone recorded at install time is gone); run doctor from a clone to compare. |
| `tool-refs` | WARN | A skill names a tool the live server does not offer (the app version and the skill disagree), or no server answered so nothing was checked. Fix `cli-installed` / `drift` first. |

### `hooks`

| Id | Status | Meaning and fix |
|---|---|---|
| `settings` | FAIL | `settings.json` is not strict JSON (comments, trailing commas ...). Claude Code ignores a broken file. Fix it by hand; the kit will not touch it. |
| `hooks` | PASS | "not checked": installed with `--no-hook`. |
| `shell-guard`, `mcp-guard` | FAIL / WARN | FAIL: the hook is not registered (the detail says so when only the older hand-made shell guard is registered: re-run `install.sh` to migrate), or is registered but its script is missing from `~/.local/share/craft-claude-kit/hooks/`. WARN: the matcher is wrong (`Bash\|mcp__terminal__run_in_terminal\|Monitor\|mcp__computer-use__open_application`; or `mcp__(wordcraft\|...)__.*` for all apps; an older install registered `Bash` only), it is registered for another workspace, twice, or another copy is also registered. Re-run `install.sh`. |
| `shell-guard-test`, `mcp-guard-test` | FAIL | `doctor.sh` fed the script canned payloads (two of them need `hooks/risky-tools.json`) and the answer was wrong: it exited non-zero, answered "deny" (the kit's hooks must only ask), asked when it should stay quiet, or stayed quiet when it should ask. Usually a broken `python3` or an edited risk table; otherwise a bug: please report it. |
| `python3` | FAIL | No `python3` on `PATH`: the hook commands cannot run, and `\|\| true` hides that. `xcode-select --install`. |
| `files` | WARN | A hook file in the kit folder changed since install (its SHA-256 differs from the receipt), or the receipt is older and has none. Re-run `install.sh` to restore and record them. |

### `gui` and `legacy`

| Id | Status | Meaning and fix |
|---|---|---|
| `desktop-apps` | PASS | No desktop apps were installed by the kit. The detail counts the Craft desktop apps it found that the kit does not manage; add `--gui` to `doctor.sh` to check them. |
| `<app>` (scope `gui`) | FAIL / WARN | FAIL: the `.app` bundle is not found, or `codesign --verify --deep --strict` fails on an app the kit installed. A strict-check failure on an app you installed yourself is a WARN (often extra Finder data in the bundle; the detail says whether Gatekeeper still accepts it). Also WARN: the bundle is a different version than the pin (the installer leaves such apps alone; replace it yourself if you want the pinned one). |
| `old-hook-script`, `old-profile`, `old-hook-entry` | WARN | Files or a hook entry from an older hand-made version of this setup are still present. Re-run `install.sh`; it migrates them. |
| `leftovers` | PASS | Nothing from the older setup. |

If a line says `doctor_checks.py <name> crashed`, that is a bug in the kit; please report it with the output.

[Back to top](#troubleshooting)

## Installer Messages

The installer prints `OK`, `--` (skipped), `WARN` and `FAIL` lines. A failing app never stops the others; the summary
at the end repeats the failures, and the exit status is 1 (0 ok, 2 usage, 3 preflight, 4 declined). Fix the cause and
run it again: finished parts are skipped. The log is `~/.local/share/craft-claude-kit/install.log`.

| You see | Cause and fix |
|---|---|
| `Cannot install yet:` then a list (exit 3) | A required tool, the Claude Code CLI, an unwritable folder or an old macOS. Each item has a `fix:`. Nothing was changed. |
| `Not running in an interactive terminal, so nothing was changed.` (exit 4) | It will not guess without a terminal. Re-run with `--yes` (add `--gui` for desktop apps). |
| `--workspace must be a folder of its own ...`, `the workspace ... must not be inside the kit folder` or `... inside the kit checkout` | Pick a dedicated folder such as `~/craft-workspace`; not your home folder, not under `--prefix`, not under the kit's runtime folder (uninstall removes that), not inside your clone (a relative `--workspace` is taken from the current folder). |
| `do not run this with sudo or as root` (exit 3) | Run it as yourself, without `sudo`. With `sudo` the files would belong to root but land in your home folder. |
| `Did not understand "...", so this is taken as No.` | Answer `y`, `g` or `n` at the prompt. |
| `Same settings as your previous install` | A re-run reuses the previous workspace, `--prefix`, `--gui-dir` and `--only` selection. Pass an option to change it; `--only all` for all 13 apps. |
| `registered again at local or project scope` | See `mcp-shadowed` above; the plan prints the fix for each one. |
| `download failed: <url> (<reason>)` | The reason is curl's own: a network or proxy problem reaching `github.com`, a captive portal, TLS, or a full disk (`df -h`). A download that stalls (under 1 KB/s for a minute) also ends here, after retries. Fix it and re-run. To install from files you downloaded yourself, see `--offline-dir` below. |
| `SHA-256 mismatch for <file> ... the file was deleted` | The download is not the file the kit pinned. Re-run once. If it repeats, **do not use the file and do not edit the lock**: upstream may have replaced a release asset. Open an issue. |
| `the zip contains absolute paths, '..' parts or symlinks; refused` | The archive is not what was pinned. Do not use it; open an issue. |
| `expected exactly one <app>-cli inside <zip>` / `the downloaded program does not report version X` | The release layout or version is not what the lock says. Open an issue. |
| `'<app>-cli --help' does not list <flag>, so the server cannot be confined; NOT registered (fail-closed)` | The installed program does not advertise its fence flag (a different version, or upstream renamed it). The existing registration, if any, is left as it was. Install the pinned version (`--only <app>`) or open an issue. |
| `the computed command line does not confine the server ...` / `the sandbox wrapper or its profile is missing; NOT registered` | An internal check refused to register an unfenced command. Re-run; if it persists, attach `./install.sh --dry-run` output to an issue. |
| `cannot read ~/.claude.json` | The file is not valid JSON. Claude Code writes it; fix or restore it, then re-run. |
| `'claude mcp add' failed: ...` / `could not remove the old registration` | The Claude Code command failed; the message after the colon is Claude Code's. Check `claude --version`, then run the printed command by hand. |
| `the registration did not take effect in <file>` | The installer and Claude Code use different config folders. Set `CLAUDE_CONFIG_DIR` identically for both. |
| `<settings.json> cannot be edited safely, hooks not changed: ... line N column M ...` | The kit edits `settings.json` only as strict JSON (no comments, no trailing commas, no duplicate keys). Fix the spot the message names; the rest of the install continued. Re-run to add the hooks. |
| `<hook>.py does not run with this python3 ...; not registered` | A broken or very old `python3`. Fix it, re-run. |
| `<skill>: ... is a symlink; left alone` | You linked that skill from somewhere (a dotfiles repo). The kit will not write through it. Remove the link to let the kit manage the skill. |
| `<App>.app is already in <dir> at version X; left untouched (the kit pins Y)` | By design. To switch, quit the app, move it to the Trash yourself, re-run with `--gui`. |
| `code signature check failed for <App>.app; not installed` | The copy taken from the disk image did not pass `codesign --verify --deep --strict`. Nothing was installed. Re-run once; if it repeats, open an issue with the output of `codesign --verify --deep --strict --verbose=2` on the mounted app. (Desktop installation has been tested only with fixture images; see [VERIFICATION.md](VERIFICATION.md).) |
| `low disk space: about X needed, Y free` | The estimate is rough and conservative (unpacked programs are about 1.7 GB for all 13). Free space or install fewer apps with `--only`. |

Offline or restricted network: download the release files yourself (names as in the lock, for example
`wordcraft-cli-0.7.0-macos-universal.zip`), put them in one folder, and pass `--offline-dir DIR`. The SHA-256 of each
file is still checked against the lock.

[Back to top](#troubleshooting)

## Messages You May See From the Apps

| Message | What it means |
|---|---|
| `automation path rejected: outside the read root` / `... write root` | WordCraft or VectorCraft: the fence refused a path. Use a file inside `~/craft-workspace/<app>/`. |
| `absolute paths must be inside the automation root` | PhotoCraft: same. |
| `outside the automation roots` | EffectCraft: same. |
| `is outside the allowed directory` | PdfCraft: same. |
| `Operation not permitted` | A sandboxed app (GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft, FilmCraft, LightCraft, SoundCraft) tried to read or write outside its folder, or to use the network. Same cure: keep files in the app folder. |
| `No such file or directory` on a save or export | The destination folder is missing, or the path is relative or starts with `~`. Make the folder; use an absolute path. |
| `... exited (code -11)` | The server crashed; see below. |

### Sandbox Problems

- **`craft-sandbox: sandbox profile craft.sb not found`** or **`/usr/bin/sandbox-exec is not available`.**
  The profile lives at `~/.local/share/craft-claude-kit/share/craft.sb`; re-run `install.sh` to restore it. If
  `sandbox-exec` is gone, the sandboxed apps cannot run: the wrapper fails closed instead of running them without
  the fence. See [FENCES.md](FENCES.md).
- **`craft-sandbox: refusing ROOT=...`.** The root must be an absolute folder that is not `/` and does not contain
  your home folder. Registrations the kit creates always satisfy this.
- **The server exits with `code -11` (SIGSEGV), usually on saving, rendering or exporting.** In the first version of
  the profile this happened to LightCraft and FilmCraft because the sandbox denied listing the program's own
  folder during GPU setup; it showed up only when a call reached the GPU code, not at start-up. The current
  `share/craft.sb` has the fix (the `BINDIR` rule), and on macOS 26.6.2 both pass their smoke tests.
  If you see it: run `doctor.sh --smoke --app lightcraft,filmcraft`; check that `sandbox-profile` is PASS (a stale
  profile in `~/.local/share/craft-claude-kit/share/` or a leftover `CRAFT_SANDBOX_PROFILE` in your environment
  would bring the old behavior back); re-run `install.sh`. If it still crashes, another sandboxed app may need
  another read the profile denies: macOS writes a crash report to `~/Library/Logs/DiagnosticReports` and the sandbox
  log names the denial (`/usr/bin/log show --last 5m --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "deny"' --style compact`;
  use the full path, because `log` is a shell builtin in zsh). Both contain your paths, so read them before attaching
  anything to an issue and cut what you do not want public. Never work around it by starting the program outside
  the fence.
- **The server exits with `code -6` (SIGABRT) on its first GPU call** (LightCraft `app.gpu`, rendering or
  exporting; `doctor.sh` shows it as `first-call` FAIL). Under a profile that denies every Mach lookup, Metal cannot
  reach its shader compiler (`com.apple.MTLCompilerService`) and aborts the process. The current `share/craft.sb`
  allows exactly that service (rule 4a). A stale profile (an older kit copy, the hand-made
  `~/.local/share/craft-sandbox/craft.sb`, or a leftover `CRAFT_SANDBOX_PROFILE`) brings it back: re-run `install.sh`,
  then `doctor.sh --smoke --app lightcraft`. The sandbox log names the refused lookup (command above).
- **`fence-live` FAIL.** Do not use the sandboxed apps until it passes: the sandbox did not refuse something it
  should. Re-run `install.sh` (it replaces a changed profile or wrapper), then `doctor.sh`. If it still fails after
  a macOS update, the sandbox behavior changed; please report your macOS version.

[Back to top](#troubleshooting)

## Gatekeeper and macOS Prompts

**Command-line programs.** The installer downloads with `curl`, which does not mark files as quarantined, so
Gatekeeper normally stays silent. On the development machine all 13 installed `<app>-cli` programs were signed with a
Developer ID Application certificate (the same Team ID for all 13), had the hardened runtime flag, passed
`codesign --verify --strict` and carried no quarantine attribute (re-checked on 2026-10-14; they are universal
`x86_64 arm64` binaries). Whether they are *notarized* was not checked. You can check yours:

```sh
codesign -dv --verbose=2 ~/.local/bin/wordcraft-cli 2>&1 | grep -E 'Authority|TeamIdentifier|flags'
codesign --verify --strict ~/.local/bin/wordcraft-cli && echo signature ok
xattr ~/.local/bin/wordcraft-cli           # com.apple.quarantine would be unexpected; com.apple.provenance is added by macOS itself
```

`spctl --assess --type execute` on a bare command-line program prints "rejected (the code is valid but does not seem
to be an app)". That is normal for any non-app executable and is not an error. If macOS does show a "cannot be
opened because the developer cannot be verified" dialog for a `<app>-cli`, the file probably did not come from this
installer (or was copied through a browser or a sync tool that adds the quarantine flag). Do not turn Gatekeeper
off. Re-run `./install.sh --only <app>` so the program is the pinned, checksummed file, and check the signature as
above. The kit never removes quarantine attributes and never disables Gatekeeper.

**Desktop apps (`--gui`).** The installer verifies the bundle with `codesign --verify --deep --strict` before
installing it and prints what `spctl --assess` says. If it says "Gatekeeper does not pre-approve it", macOS may ask you
to confirm the first launch: use the system's own route (right-click the app, Open; or System Settings, Privacy &
Security, "Open Anyway") once you have checked the signature. The kit never launches the desktop apps itself. Desktop
installation was tested only with fixture disk images, not with the real ones (see
[VERIFICATION.md](VERIFICATION.md)).

**Other prompts.** Because the servers run as children of Claude Code, macOS may ask whether your terminal or Claude
Code may access protected folders if you put the workspace in Desktop, Documents, Downloads or iCloud Drive. Keeping
the default `~/craft-workspace` avoids that (general macOS behavior, not specifically tested with the kit).

[Back to top](#troubleshooting)

## Uninstaller

| You see | Cause and fix |
|---|---|
| `No receipt at ..., so it is not known what the kit installed.` (exit 3) | The receipt is missing. Run `./install.sh` from the clone once (it rewrites the receipt), then uninstall. |
| `The receipt ... cannot be trusted` (exit 3) | A path in it looks wrong (not absolute, a system folder, your home folder itself, the prefix or Claude folder inside the kit folder ...), or it was written for another kit folder. Run `./uninstall.sh` from your clone of the kit (it always works), or re-run `./install.sh` from it, then uninstall. A kit folder reached through a symlink (for example a dotfiles-managed `~/.local`) is accepted. |
| `Claude Code CLI not found; registrations left in place` | Remove them yourself with the printed `claude mcp remove <app> -s user` commands. |
| `<skill> kept: it was changed after install` | By design; delete `~/.claude/skills/<skill>` yourself if you do not want it. |
| `desktop apps that are running now (quit them first)` | Quit them and run again with `--remove-gui`. |
| `kept <kit folder> so the uninstaller can be run again` | Something failed, or `--keep-hooks` was given and a hook still points into that folder. Fix, then run again. |
| `cleanup without a receipt` | You ran `./uninstall.sh` from the clone after the kit folder was deleted. It removes the kit's hook entries, its `craft-sandbox` and the MCP servers that run through it, lists the other Craft MCP servers in the programs folder with their `claude mcp remove` commands (exit 1 while they remain), and prints `rm` commands for the skills and programs (it cannot prove they are the kit's). It takes the programs folder from the registrations; pass `--prefix DIR` if that is wrong. For a full removal run `./install.sh` first, then uninstall. |
| `Nothing to uninstall: ... does not exist, and ... has no hook entry of the kit ...` | No sign of the kit: no kit folder, no hook entry pointing into it, no kit `craft-sandbox`. |

Your workspace is never deleted. To start completely fresh: `uninstall.sh`, then `./install.sh`.

[Back to top](#troubleshooting)

## Reporting a Problem

Open an issue (templates are in `.github/ISSUE_TEMPLATE/`) with: macOS version and chip (`sw_vers`, `uname -m`), Claude
Code version (`claude --version`), the kit version (`cat VERSION`), the exact command you ran, and the failing
output. `doctor.sh --json` is the most useful attachment; `~/.local/share/craft-claude-kit/install.log` too. Both
contain your user name and paths: read them and replace anything private (for example `/Users/you`) before posting.
Do not attach documents from your workspace. Problems inside an app itself belong to that app's authors:
[APPS.md](APPS.md) links their repositories.

[Back to top](#troubleshooting)
