# Fences: How Each Server Is Confined, and What That Does and Does Not Guarantee

Every Craft MCP server is registered so that it can only reach one folder, `<workspace>/<app>/` (default
`~/craft-workspace/<app>/`). This page says how, per app, what you can rely on, what you cannot, and how
`doctor.sh` checks it. Note the limits: a fence narrows what the apps can touch, it does not make
untrusted files harmless. Overview: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Evidence and gaps:
[VERIFICATION.md](VERIFICATION.md). Threat model and how to report a problem: [SECURITY.md](../SECURITY.md).

**The short version.**

- Five apps (WordCraft, PhotoCraft, VectorCraft, EffectCraft, PdfCraft) have a confinement option of their own.
  The kit passes it and checks that it is passed. The app does the enforcing; the kit cannot see inside it.
- Eight apps (GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft, FilmCraft, LightCraft, SoundCraft) have none.
  The kit runs them inside a macOS sandbox. The kernel enforces it, `doctor.sh` tests it on your machine, and it
  has two known weaknesses: system files stay readable, and `/private/tmp` is writable and **shared**.
- `sandbox-exec`, which the sandbox uses, is deprecated by Apple. It works on current macOS; it may not forever.
- Nothing here stops Claude from changing or deleting the files inside an app's own folder.

## The Three Modes

| Mode | Apps | Registered command | Who enforces it |
|---|---|---|---|
| `roots` | WordCraft, PhotoCraft, VectorCraft, EffectCraft | `<app>-cli mcp --automation-read-root R --automation-write-root R` | The app, inside its own process |
| `root` | PdfCraft | `pdfcraft-cli mcp --root R` | The app, inside its own process |
| `sandbox` | GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft, FilmCraft, LightCraft, SoundCraft | `craft-sandbox R <app>-cli mcp` | The macOS kernel, through `sandbox-exec` |

`R` is the app's absolute folder. WordCraft is registered with the extra argument `--author Claude` after its
fence flags, so tracked changes and comments it makes are labeled; the lock file (`extraArgs`) is where such
arguments live. `extraArgs` may never carry a fence flag (`--root`, `--automation-*`, also as `--flag=value`): the
installed PhotoCraft (0.8.2 and again 0.9.0) was observed to honor the **last** `--automation-write-root` when given two, and the
`=` form too, so a second flag would silently move the fence. The installer accepts only the per-app list it
knows (`--author Claude` for WordCraft), `lib/craftkit.py` refuses fence flags there, the installer requires each
fence flag exactly once at its fixed place, and `doctor.sh` fails `fence-config` on a duplicate or `=` form.

**Why these modes.** The kit uses the app's own confinement flags where its `--help` advertises them, and wraps
the app in a sandbox where it does not. Checked on 2026-10-14 against the installed, pinned versions: the first
five apps list the flags and the other eight list none. The mode of each app is a field in
`manifest/apps.lock.json`, so a future release that adds a flag can be moved to the app's own fence by changing
the lock.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Per App

| App | Mode | Why | What was seen when a path was outside the folder | `doctor.sh` live probe |
|---|---|---|---|---|
| WordCraft | `roots` | `--help` lists both root flags (and says they are an error together with `--connect`) | `automation path rejected: outside the read root` / `write root` | None (config only) |
| PhotoCraft | `roots` | `--help` lists both root flags | `absolute paths must be inside the automation root`; commands that use ambient paths (`file.open`, `file.save` ...) are refused outright | None (config only) |
| VectorCraft | `roots` | `--help` lists both root flags; they imply `--headless` | `automation path rejected: outside the read root` / `write root` | None (config only) |
| EffectCraft | `roots` | `--help` lists both root flags; script-running commands are refused under them | `outside the automation roots` | None (config only) |
| PdfCraft | `root` | `--help` lists `--root` | `is outside the allowed directory` | None (config only) |
| GridCraft | `sandbox` | `--help` lists no confinement flag | `Operation not permitted` | Write, read, network, launch |
| DeckCraft | `sandbox` | None listed | `Operation not permitted` | Write, read, network, launch |
| DesignCraft | `sandbox` | None listed | `Operation not permitted` | Write, read, network, launch |
| CADCraft | `sandbox` | None listed | `Operation not permitted` | Write, read, network, launch |
| FigCraft | `sandbox` | None listed | `Operation not permitted` | Write, read, network, launch |
| FilmCraft | `sandbox` | None listed; the app does not restrict paths itself, only the sandbox does | `Operation not permitted` | Write, read, network, launch |
| LightCraft | `sandbox` | None listed | `Operation not permitted` | Write, read, network, launch |
| SoundCraft | `sandbox` | None listed (trust the `--help` of the exact version you install, not the app's documentation) | `Operation not permitted` | Write, read, network, launch |

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Fail Closed

- For `roots` and `root` apps the installer runs `<app>-cli --help` and registers the server **only** if the flag
  or flags are listed. If a future version renames them, that app is not registered (an existing registration is
  left as it was, with a warning) and the summary says so. `doctor.sh` repeats the check as `fence-config`.
- For `sandbox` apps the installer registers only when `craft-sandbox` and `craft.sb` are installed. At run time
  `craft-sandbox` exits non-zero **before** the program starts if it cannot find `/usr/bin/sandbox-exec`, the
  profile, or the program; it never runs the program unfenced.
- The installer also checks that the command line it computed has the workspace folder in the fence position
  before it calls `claude mcp add`.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Modes 1 and 2: The App's Own Flags

**What you get.** The app checks the paths its tools read or write against the folder you gave it. The kit passes
the same folder as read root and write root. What the CLIs' own help promises varies: WordCraft's and
VectorCraft's say the roots cover the files the agent's commands read and write, "links followed" (a symlink that
leads out is not an exit), and "a root left out grants none of its access"; EffectCraft's adds that scripts are
refused; PhotoCraft's and PdfCraft's help only list the flags. Note on VectorCraft: without these flags it
would first try to connect to a running desktop app on a local port; the flags imply `--headless`, so the
registered server never does.

First-hand check on 2026-10-14 (scratch folder, pinned versions, macOS 26.6.2): for each of the five apps, opening
`/etc/hosts` by its absolute path was refused, and so was opening a **symbolic link placed inside the app folder
that points at `/etc/hosts`**. For PdfCraft a path with a `..` segment that leads out of the folder was refused too.
Earlier checks by the maintainers also refused saves to paths outside the folder, and EffectCraft refused every
outside read or write command they tried (about a dozen, including saves, frame exports and imports).

**What you do not get.**

- The kit cannot check enforcement from outside. `doctor.sh` confirms the flags are advertised and the
  registration carries your folder (`fence-config`, "config-only: the app enforces its own flag; no live probe").
  Whether an app enforces its flags in every code path is the app's responsibility. The kit's evidence is the
  refusals above and the per-app checks in [VERIFICATION.md](VERIFICATION.md), not a code audit.
- Nothing stops these five apps from using the network or reading other files through some path that the flag does
  not cover. The kit does not sandbox them. Commands that take no path (typing text, changing a layer) act on
  the open document and are not path checks.
- A server started by hand from a shell (for example `photocraft-cli mcp` with no flags) is not fenced at all. That
  is why one of the two hooks asks before any Bash command that starts a Craft program.
- Inside the folder everything is allowed, including `in/`. The convention "never write into `in/`, never save over
  an input" is in the skills; it is not enforced.
- Where relative paths land is determined by the app: PdfCraft resolves them from its root (verified), the others were
  only tested with the app folder as working directory, and the registration does not set one. The skills
  therefore tell Claude to use absolute paths only, and the MCP guard asks when WordCraft, VectorCraft or
  EffectCraft gets a relative file path, and when any save or export gets one.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Mode 3: The macOS Sandbox

`craft-sandbox` (installed to the prefix, a copy of `bin/craft-sandbox`) resolves symlinks to find the real
program, creates and enters the root folder, and runs the program under `/usr/bin/sandbox-exec` with the profile
`share/craft.sb`. It refuses `/` and any folder that contains your home folder as a root. It looks for the profile
in this order and uses the first it finds: `$CRAFT_SANDBOX_PROFILE` (a test hook; if set it must exist, and
`doctor.sh` warns when it is set), `<kit home>/share/craft.sb`, `share/craft.sb` next to the script, and the profile
of the older hand-made setup (it then says so on stderr: "kit profile not found, using the older profile ...",
because that file is not the kit's and may have other rules). The profile (read the file; it is short and
commented) does five things:

| Rule | Effect |
|---|---|
| `(deny network*)` | No network at all, including local (unix-domain) sockets. The server talks to Claude Code over stdin and stdout, which is not network. This also disables the apps' own `--connect` and bridge modes. |
| `(deny file-read* ...)` for your home folder and `/Volumes`, then allow `ROOT` and the program file | The process cannot read your other files, or external drives and network shares. Reading the *metadata* of the home folder itself stays allowed because path lookups need it. |
| `(allow file-read* (literal BINDIR))` | The program may list its own folder (that one directory entry, which reveals file names there, not their contents). GPU apps look next to their executable while Metal starts and crashed with SIGSEGV without this (see "What Went Wrong Once, and What It Taught" below). |
| `(deny file-write* ...)` except `ROOT`, `/private/tmp`, `/private/var/folders`, `/dev/null`, `/dev/tty`, `/dev/ttysN`, `/dev/fd/N` | The process can write only to its folder, the system temp folders and the device nodes a command-line program uses. |
| `(deny mach-lookup)` | No Mach service lookups. A program started through LaunchServices (`open`, an app launch) is started by launchd, not as a child of the server, so it would not inherit the sandbox; this rule makes such a request fail. Narrower denies (launchservicesd, `lsd.*`, coreservicesd, notification_center, logd and others) were tried one by one and did not stop the launch. Side effect: user-name lookups fail inside the sandbox (`id -un` prints the numeric id). |
| `(allow mach-lookup (xpc-service-name "com.apple.MTLCompilerService"))` | The one exception: Metal's shader compiler, an Apple XPC service inside Metal.framework that runs in its own Apple sandbox and cannot be asked to start other programs. Without it LightCraft aborts (exit -6) on its first GPU call; the sandbox log names this service as the refused lookup. The `open` probe is still refused with it in place (2026-10-15). |

**What you get.** Enforced by the kernel for the server process and the child processes it starts itself: no
network; no reading of anything else under your home folder or `/Volumes`; no writing outside the folder and the
temp areas; no Mach lookups (except Metal's shader compiler), so it cannot have macOS start another program outside the sandbox. Before the
Mach rule existed that was a real way out: a bundle started with `open` from inside the sandbox ran with
launchd as its parent, read a file under the home folder and connected to a local listener, both of which the
sandboxed process itself was refused. The read and network guarantees therefore hold for programs started
through macOS only with the Mach rule in force (`doctor.sh` tests it). The wrapper changes into the root folder
before it starts the program, so relative paths land inside it.

First-hand check on 2026-10-14: a few harmless commands run through `bin/craft-sandbox` with a scratch folder as
the root, on macOS 26.6.2:

| Command | Result |
|---|---|
| Read `/etc/hosts` | Allowed |
| List `/Applications`, list `/Users/Shared` | Allowed |
| Read a dotfile in the home folder | Refused: `Operation not permitted` |
| List the home folder; list `~/.local/bin` | Refused: `Operation not permitted` |
| `stat` the home folder | Allowed |
| Write inside the root folder; write inside `/private/tmp` | Allowed |
| Write to `/Users/Shared` | Refused: `Operation not permitted` |
| The same dotfile read, started by a shell started by a shell | Refused (children inherit the sandbox) |
| TCP connect to `127.0.0.1` and to `192.0.2.1` | Refused: `Operation not permitted` (the same connect to `192.0.2.1` **outside** the sandbox ends with "Operation timed out", which is how `doctor.sh` tells them apart) |
| `open -g -n` of a small app bundle whose program writes a marker file | Earlier profile (no Mach rule): `open` exit 0, the program ran (outside the sandbox). Current profile: `open` exit 1, `kLSNoExecutableErr`, nothing ran |

Maintainers also saw these refusals through the real servers while checking the skills (home-folder access from
GridCraft, reads and writes under the home folder from CADCraft and FigCraft, reads from DeckCraft, DesignCraft,
LightCraft and SoundCraft, a write outside the folder from DeckCraft, a network call from FigCraft). Not every
refusal was tried on every server: for SoundCraft only reads were tried through the server, and writes are
covered by the `doctor.sh` probe. `doctor.sh` re-tests write, read, network and launch-through-macOS on your machine (below).

**What you do not get.**

- **Everything outside your home folder and `/Volumes` is still readable**: system files, `/Applications`, `/opt`,
  `/usr`, `/Users/Shared`, `/private/tmp` and so on (see the table above).
- **The profile starts from "allow default" and subtracts.** Only the rules in the table apply. Child processes
  inherit the sandbox. Apple Events and the pasteboard were not tested separately (Mach lookups, which most of
  them need, are denied).
- **Signals are not confined.** A sandboxed program can send signals to other programs of your user (tested on
  2026-10-14: a sandboxed shell stopped an unrelated `sleep` with `kill -STOP`). It cannot read their data, but it
  can stop or end them. A variant of the profile that adds `(deny signal)` and `(allow signal (target self))`
  refused that kill and passed the smoke tests of 7 of the 8 sandboxed servers; it was tested before the Metal
  exception existed, when LightCraft failed under every profile, so it was never checked against LightCraft and is not shipped. The hooks ask about the tools that talk to other programs on purpose (adding to
  Apple Photos, printing, running scripts).
- **It does not stop Claude from changing, or destroying, the documents inside the folder.** It limits where the
  damage can land.
- **It is not proof against a determined attacker.** `sandbox-exec` profiles are a private, undocumented
  interface of macOS. The profile is a default tested against what these apps do, not a certified
  isolation boundary.

### The Shared `/private/tmp` Caveat

The sandbox profile lets every sandboxed server write to `/private/tmp` and `/private/var/folders`, because
macOS frameworks keep caches and temporary files there and fail without them. Those folders are shared with
every other process on your Mac, **including the other seven sandboxed Craft servers**, which can also read
them. Consequences:

- A file a Craft app writes to `/tmp` or a temp folder is not protected by the fence, and is visible to other
  programs and other Craft apps. Do not save outputs there. The skills tell Claude to write to
  `<workspace>/<app>/out/` and note that `out/` is a convention, not a fence.
- One sandboxed app could, in principle, leave data in `/private/tmp` for another to read. The fence is per
  app for the workspace folders only.
- Verified for FilmCraft: an import from, and a frame export to, `/private/tmp` both worked. Verified for the
  other sandbox apps that were checked (GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft): writes to
  `/private/tmp` are allowed.
- The five apps with their own flags do not rely on this exception: their root flags decide.

### `sandbox-exec` Is Deprecated

Apple's own manual page for `sandbox-exec` begins "execute within a sandbox (DEPRECATED)" and says developers
should adopt App Sandbox instead. App Sandbox applies to apps their developers sign and ship; it cannot be applied
by a third party to someone else's command-line program, so there is no supported replacement for this use. The tool still
ships and works on macOS 26.6.2 (the version this was verified on), but:

- Apple may remove it, or change how profiles behave, in a future macOS. Because the interface is private, a
  working profile today is not a promise about tomorrow.
- If it disappears, the failure is closed: the installer's preflight reports `/usr/bin/sandbox-exec is missing`,
  `craft-sandbox` refuses to start, `doctor.sh` fails `sandbox-exec` and `fence-live`, and the eight sandboxed apps
  stop working. They never silently run unfenced.
- `doctor.sh` runs a live test of the sandbox on every run, so a macOS update that changes behavior shows up as a
  FAIL rather than as a surprise. Run it after every macOS update.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## How `doctor.sh` Verifies a Fence

| Check | Applies to | What it does |
|---|---|---|
| `fence-config` | All | roots/root: runs `<app>-cli --help` and requires the flags, then requires the registration to pass your folder to each flag. sandbox: requires the registered command to be `craft-sandbox`, with your folder as its root and `<app>-cli` as the program; requires the kit's wrapper, profile and `sandbox-exec`. |
| `workspace` | All | The app folder exists and is a real folder (a symlink there is a FAIL, because the fence would follow it); WARN if other users can look inside (mode 700 is expected). |
| `fence-live` | sandbox apps | Runs four harmless probes through the registered wrapper and requires the sandbox to refuse each one. |
| `server-starts`, `smoke` | All | Start the server and drive it. They use the registration's arguments, except that sandbox apps go through the kit's own copy of the wrapper and profile. |

The four `fence-live` probes:

1. **Write.** `printf x > <probe file>` into the workspace root, your home folder or `/Users/Shared` (the first one
   that is writable and outside the app folder and outside the sandbox's temp areas). Must be refused. If it is
   ever allowed, doctor deletes the file and reports FAIL.
2. **Read.** `head -c 1` of one file the kit itself installed under your home folder (outside the app folder).
   Must be refused.
3. **Network.** `nc -z` to `192.0.2.1:443` (a reserved documentation address that is never routed). Must be refused
   by the sandbox before any packet leaves.
4. **Launch through macOS.** doctor writes a tiny app bundle into a private temp folder (its program is a two-line
   shell script that only writes a marker file next to it), runs `open -g -n <bundle>` through the wrapper, and
   requires `open` to fail and the marker never to appear. FAIL if the marker appears. The temp folder is removed
   afterwards. (`open -a NoSuchApp` would not be a valid test: it prints the same error under either profile.)

Result: PASS if all four are refused; FAIL if the wrapper does not run, if the write or read is allowed, or if the
network attempt is not refused by the sandbox; WARN if a probe could not be tried (for example there is no folder
to write into, or no kit file under your home folder) and nothing was allowed.

**For `roots` and `root` apps there is no live probe.** `doctor.sh` states this in the check output.

The doctor's own test suite runs the live probe twice: once with the real profile (must PASS) and once with a
profile that allows everything (must FAIL), so the check is known to be able to fail. Observed on the development
machine (macOS 26.6.2, Apple Silicon, 2026-10-14): `fence-live` PASS for all eight sandbox apps. Re-run for LightCraft and
GridCraft with the Metal exception (2026-10-15): PASS, all four probes refused.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## What Went Wrong Once, and What It Taught

The first version of the profile denied reads under your home folder without an exception for the program's own
folder (`~/.local/bin`). LightCraft and FilmCraft crashed with SIGSEGV (server exit code -11) during GPU setup
(the crash reports were in Metal and VideoToolbox code), which showed up only when saving, rendering or exporting,
far from the cause. The fix is the `BINDIR` rule above. `tests/smoke/lightcraft.json` starts with the GPU call
that crashed and `tests/smoke/filmcraft.json` saves, reopens and renders, so both would catch the regression.

With the current profile, all 13 smoke tests, including these two, pass on macOS 26.6.2 (re-run one at a time on
2026-10-15, after the Metal exception was added; LightCraft passed three times in a row). Two lessons shaped the design: keep the profile small,
and keep `doctor.sh --smoke` so that "the server starts" and "the server works inside the fence" are separate
questions. Other GPU or video apps could hit a *different* member of the same class on another macOS version;
`fence-live` would not notice (the fence would still hold), only the smoke tests would. If you see `code -11`
anyway, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Beyond the Fences

- **Claude Code's own tools are not fenced by this kit.** Claude can still read and write wherever Claude Code's
  own permissions allow, with the Bash, Read, Write and Edit tools. The fences confine only the 13 Craft servers.
- **The hooks are a second look, not a fence.** `craft-shell-guard.py` runs for exactly these tools: Bash,
  `mcp__terminal__run_in_terminal`, `Monitor` and `mcp__computer-use__open_application` (its `app` is read as
  `open -a <app>`); `computer_batch` and every other tool are not inspected. It asks before a command would run a
  Craft program directly (including behind `sudo`, `env`, `nohup`, `xargs`, `ionice`, `flock`, `script`, `parallel`,
  `ssh`, `expect`, `bash -c` and similar), open a Craft `.app`, or call `craft-sandbox` with a root other than one
  app folder. It also sees globs, brace expansion, `${...}` and `$'...'` in the command word, printf escapes, and
  decoded text piped into a shell (`base64 -d | sh`). `craft-mcp-guard.py` asks before risky Craft MCP calls and
  before any path argument that does not resolve inside that app's folder. Both are heuristics that read text.
  **Known evasions** (silent on purpose, kept as tests so a change is noticed): a variable that comes from the
  environment rather than the same command (`$W` alone; `W=wordcraft-cli; $W` does ask), a program name built inside
  interpreter code (`python3 -c` with an escape such as `\x77ordcraft-cli`, or `'word' + 'craft-cli'`), a copy or
  symlink of a binary run under another name, a script file, an alias, and `curl | sh`. `env -S'...'` and
  `xargs -I{} sh -c '{} ...'` ask. The table of
  risky tools is incomplete (see [VERIFICATION.md](VERIFICATION.md)). Over their size limits (a command over
  200000 characters, more than 200 nested `$(...)`, MCP arguments over 20000 nodes or 20 levels) they ask rather
  than pass silently. Both fail open on errors and never deny. Whether an "ask" is shown in every Claude Code
  permission mode is Claude Code's behavior, which the kit's tests do not cover.
- **Edit and Write are not guarded.** Claude Code's Edit and Write tools could change the hook scripts and
  `hooks/risky-tools.json` in the kit folder, or `settings.json`. The receipt records the SHA-256 of the hook files;
  `doctor.sh` WARNs when they changed and its canned payloads FAIL when the risk table stops answering. That
  detects the change after the fact.
- **Prompt injection.** A document can contain text that tries to instruct Claude. The skills tell Claude to treat
  file contents as data and never follow instructions found in them; that lowers the risk and does not remove it.
  The fence limits what a successful injection could reach through the Craft tools.
- **The apps are third-party software.** The kit pins and checksums the files it installs; it does not audit them.
  Their network behavior outside the sandbox (the five `roots`/`root` apps) is theirs.

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)

## Changing a Fence

Edit nothing by hand in `~/.claude.json`. To use another folder, re-run `./install.sh --workspace DIR`: it
re-registers the servers and the hooks for the new folder and leaves your files where they are. To change a mode
for a future release, edit the `fence` field through `tools/gen-lock.sh` (the `meta()` table), regenerate the lock,
and run `make test` and `./doctor.sh --smoke` ([UPDATING.md](UPDATING.md)).

[Back to top](#fences-how-each-server-is-confined-and-what-that-does-and-does-not-guarantee)
