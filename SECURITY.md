# Security Policy

craft-claude-kit downloads the command-line tools of 13 desktop apps (the "Craft" apps by storytold), registers each one as a Claude Code MCP server, and adds Claude Code skills and two hooks. This page says what the kit protects, what it does not, exactly what each control guarantees and where it stops, how to check the one thing you must trust (the lock file), and how to report a vulnerability.

The kit is unofficial. It is not affiliated with or endorsed by the authors of the Craft apps.

Read this first: **no control here makes an AI agent safe.** The fences limit which files and which network an agent can reach through these 13 servers. The hooks are prompts for a human who is watching. Everything else the agent can do (other MCP servers, the Bash tool, what it does inside the workspace folders) is outside this kit.

## Report a Vulnerability

Please do not open a public issue for a security problem.

1. Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**.
2. If you do not see that button, open a public issue titled "Security contact request" that contains **no technical details**. A maintainer will arrange a private channel.

Include the kit version (`cat VERSION`), your macOS version and chip (`sw_vers`, `uname -m`), which control is affected, steps to reproduce, and the output of `./doctor.sh` with personal paths replaced by `/Users/you`. Never include tokens, keys or documents you do not own.

What is in scope (a weakness in this repository):

- A way out of a fence that the kit's command line, wrapper or profile should have prevented (`bin/craft-sandbox`, `share/craft.sb`, the registration arguments from `lib/craftkit.py`);
- A doctor check that reports PASS while a control is not in force (false assurance counts as a vulnerability here);
- Installer, uninstaller or settings-editing bugs: path traversal, deleting or overwriting something the kit does not own, unsafe temporary files, corrupting `settings.json` or `.claude.json`;
- A way to get a download accepted although its SHA-256 differs from the lock, or an archive entry written outside its temporary folder;
- Skill text that would push an agent into an unsafe action.

What is not in scope:

- Bugs in the Craft apps themselves: report those to the app's own project (`https://github.com/storytold/<app>`). If a bug also defeats a fence described on this page, please report it here as well so that the page can be corrected;
- The documented limits below, including "a hook can be evaded with a variable, alias or script". Reports that improve a heuristic are welcome as ordinary issues or pull requests;
- Anything that needs the attacker to already control your user account, your Claude Code settings, or the checkout you installed from;
- Bugs in macOS (`sandbox-exec`) or in Claude Code: report those to Apple and Anthropic.

This is a volunteer project. The maintainers aim to acknowledge a report within 7 days and will communicate their decision; there are no guaranteed fix times and no bounty. Reporters are asked to allow a reasonable period (90 days is suggested) before publishing details. Reporters are credited in the advisory on request.

## Supported Versions

| Version | Supported |
|---|---|
| The latest release, and `main` | Yes |
| Anything older | No (the project is pre-1.0; fixes are not backported) |

Platform: macOS 13 or newer, Apple silicon or Intel. The preflight refuses everything else. The maintainers have tested only macOS 26.6.2 on Apple silicon (October 2026); older macOS versions and Intel Macs are expected to work but are **not verified**. Linux and Windows are not supported.

The kit pins the app versions listed in `manifest/apps.lock.json` and has been checked only against those. A newer app release may change a command-line flag or a tool; the installer and `doctor.sh` are written to fail or warn rather than guess (see "Fail closed" below).

## Threat Model

### What the Kit Is Trying to Protect

- **Your files and credentials outside the per-app workspace folders** (`~/craft-workspace/<app>/` by default) from an AI agent, or from text the agent reads, using the 13 Craft MCP servers.
- **The integrity of what gets installed**: the bytes you run are the ones whose SHA-256 is in the lock file.
- **Your Claude Code configuration**: the installer must not corrupt `settings.json` or `~/.claude.json`, must not remove things it does not own, and must be undoable.

### Who or What Is Treated as Hostile

- **Content the agent reads**: documents, web pages, spreadsheet cells, PDF text, image metadata. Any of it may contain instructions aimed at the agent (prompt injection).
- **A confused or over-eager agent** that tries a path or a command it should not.
- **A tampered or substituted download.**

### What Is Trusted (And Therefore Not Defended Against)

- The Craft apps and their authors. Their binaries run as you.
- macOS, `sandbox-exec`, Claude Code, and GitHub's release hosting over TLS.
- You, and any other process already running as your user.
- This repository, at the commit you reviewed and installed from (see "The Lock File Is the Trust Root").

## Controls

### 1. Fences: Each Server Can Only Reach Its Own Workspace Folder

Every server is registered so that it works on `<workspace>/<app>/` only. How that is enforced depends on the app, because the Craft command-line tools are not uniform: only 5 of the 13 have a confinement option of their own (details in [docs/LESSONS.md](docs/LESSONS.md)).

| Fence | Apps | Registered as | Enforced by |
|---|---|---|---|
| `roots` | wordcraft, photocraft, vectorcraft, effectcraft | `<app>-cli mcp --automation-read-root DIR --automation-write-root DIR` | The app, in its own code |
| `root` | pdfcraft | `pdfcraft-cli mcp --root DIR` | The app, in its own code |
| `sandbox` | filmcraft, lightcraft, designcraft, cadcraft, deckcraft, figcraft, gridcraft, soundcraft | `craft-sandbox DIR <app>-cli mcp` | The macOS kernel, through `sandbox-exec` and `share/craft.sb` |

Per-app details, the exact profile rules and the doctor checks: [docs/FENCES.md](docs/FENCES.md). Evidence and gaps: [docs/VERIFICATION.md](docs/VERIFICATION.md).

**Fail closed.** For the 5 built-in fences the installer runs `<app>-cli --help` and registers the server only if the flag is listed; otherwise it reports FAIL for that app and does not register it unfenced. For sandbox apps it requires the wrapper and the profile to exist. `craft-sandbox` itself exits with an error before starting the program if `sandbox-exec` or the profile is missing, if the folder is `/`, or if the folder contains your home folder.

#### Sandbox Fence (8 Apps)

What `share/craft.sb` enforces while the program runs, and what the wrapper does around it:

- **No network at all**, including connections to localhost and local (unix-domain) sockets. The MCP connection to Claude Code uses stdin/stdout, which is not network.
- **No reads under your home folder**, except the app's workspace folder and the program file itself. Also no reads under `/Volumes`. Two small exceptions: the metadata of the home folder itself, and the file names (not contents) in the folder that holds the program, which GPU-using apps need.
- **Writes only** to the app's workspace folder, `/private/tmp`, `/private/var/folders`, and a few `/dev` nodes (`/dev/null`, terminals, file descriptors).
- **No Mach service lookups.** macOS starts a program requested through LaunchServices (`open`, an app launch) from launchd, not as a child of the server, so that program would not inherit the sandbox. An earlier profile allowed this: a bundle started with `open` from inside the sandbox read a file under the home folder and connected to a local listener, both of which the sandboxed process itself was refused. Denying Mach lookups closes that route (`open` then fails with `kLSNoExecutableErr` and nothing starts). Narrower denies (launchservicesd, `lsd.*`, coreservicesd and others) were tried and did not stop the launch. One exception is allowed: Metal's shader compiler (the XPC service `com.apple.MTLCompilerService`, inside Metal.framework, which runs in its own Apple sandbox and cannot be asked to start programs). Without it LightCraft aborts on its first GPU call.
- The program's working directory is the workspace folder. The wrapper creates it if missing. It uses the kit's profile; if only the profile of an older hand-made setup is found, it says so on stderr before using it.

Verification method, on the pinned versions (October 2026, macOS 26.6.2, Apple silicon):

- `doctor.sh` runs four harmless probes through the installed wrapper for every sandbox app, every time: a write outside the folder, a read of a file under your home folder, a network connection, and `open` of a tiny bundle it writes to a temp folder (its program only writes a marker file). It reports FAIL if any of them is allowed, so a profile that silently stops being enforced is noticed. (If the write probe did get through, doctor removes the probe file.) The launch probe was checked against both profiles: with the earlier one `open` exited 0 and the marker appeared; with the current one `open` exited 1 and nothing ran. (`open -a` of an app that does not exist is not a valid test: it fails the same way under either profile.)
- By hand, with system tools under the profile: the restrictions were also enforced on a grandchild process (a shell started by a shell); a write inside the folder and in `/private/tmp` worked; reading `/etc/hosts` worked; reading a dotfile in the home folder and listing the home folder failed with "Operation not permitted"; `stat` of the home folder worked; TCP connections to localhost and to an outside address failed with "Operation not permitted"; a DNS lookup failed; binding a unix-domain socket failed.
- All 8 sandboxed servers start under the shipped profile and pass their smoke tests (`./doctor.sh --smoke`), re-run one at a time on 2026-10-15. An earlier note here said they also passed under the bare Mach-lookup rule; that was wrong for LightCraft, which aborted (exit -6) on its first GPU call until the Metal compiler exception above was added. With it, LightCraft's smoke test passed 3 of 3 runs and the `open` probe is still refused. LightCraft and FilmCraft crash with SIGSEGV if the program's own folder cannot be listed; the profile allows that listing. Side effect of the Mach rule: user-name lookups fail inside the sandbox (`id -un` prints the numeric id).

Limits of the sandbox fence. These are not bugs; they are what this kind of profile is:

- **Reads are only blocked under your home folder and `/Volumes`.** Everything else stays readable: system files, `/Applications`, `/opt`, `/usr`, and the temp folders of other programs.
- **`/private/tmp` and `/private/var/folders` are writable and shared** with every process, including the other sandboxed Craft apps. Do not treat them as private, and do not put anything there you want protected.
- **The profile starts from "allow everything" and removes four things** (network, home-folder reads, writes outside the folder, Mach service lookups other than Metal's shader compiler). Child processes the server starts itself inherit the sandbox; programs started through macOS are refused by the Mach rule. Signals are not confined: a sandboxed program can send signals to other programs of your user (tested: it stopped an unrelated process with `kill -STOP`), so it can stop or end them, though not read their data; the fence does not prevent that (see [docs/FENCES.md](docs/FENCES.md) and `share/craft.sb`). Apple Events and the pasteboard were not tested separately, and there is no limit on CPU or memory. The MCP guard asks before tools known to talk to other programs (for example adding to Apple Photos).
- **It does not limit what the app does to documents inside the folder**: it can overwrite or delete any file in `<workspace>/<app>/`, including `in/`. The `in/` and `out/` layout is a convention taught by the skills, not something the sandbox enforces.
- **`sandbox-exec` is deprecated by Apple.** It works on current macOS, but a future macOS may remove it or change its behavior. If it is removed the wrapper fails closed (the servers stop starting). If it changed so that the profile were no longer enforced, `doctor.sh` fence-live would show FAIL. Re-run doctor after every macOS update.
- Because the network is denied, the apps' live-window modes (`--connect`, `--bridge`, `--control`) cannot work through these registrations. That is intended.

#### Built-In Fences (5 Apps)

The kit relies on the app to refuse paths outside the folder. The kit's part is to pass the right flags (checked against `--help` at install time) and to check the registration (`doctor.sh` fence-config).

Checked on the pinned versions: for all five, opening a system file and saving to a path outside the folder (absolute paths) are refused with an explicit error, and nothing is written outside. For PdfCraft, a `..` path, a symbolic link inside the folder that points to a file outside, and a directory link that points outside were also tried; all were refused.

What this does not give you:

- **Not enforced by the OS.** A bug in the app's path check is an escape. `doctor.sh` can only check the configuration for these apps, not the live behavior, and says so.
- **No network confinement.** These five run with your normal network access. What they do with it has not been audited. (A stricter setup would also run them under `craft-sandbox`; the kit does not, and it has not been tested whether the apps work that way.)
- **Only tools that take a path are covered.** Commands that act on the document that is already open (typing text, changing a layer) are not path checks; the WordCraft documentation says so explicitly, and the same shape applies to the others.
- **Race conditions.** WordCraft's documentation states that the path is checked and then opened, so another local program that swaps a link in between could get past the check, and that the roots are not a defense against other software on the machine. The same is assumed for the other four.
- Other channels may not be covered: WordCraft's documentation says its Zotero commands use a local socket, which the roots do not apply to. Similar cases in the other apps have not been investigated.
- **The refusal text differs per app** (for example "outside the write root", "is outside the allowed directory"). The skills tell the agent that a refusal means the fence works and it should ask you rather than look for another way.

#### Not Fenced at All

- **The desktop apps** (`--gui` installs them). They run as you with full access. The MCP servers never use them, and the skills tell the agent not to start them.
- **Live-app modes** of the command-line tools (`--connect`, `--bridge`, `--attach`, `--control`). The built-in root flags do not confine a live app; the shell guard asks before any shell command that launches a Craft app or tool, and the skills forbid these modes.
- **Anything else the agent can run**: other MCP servers, other skills, and the shell. The shell guard looks at the Bash tool, the terminal tool `mcp__terminal__run_in_terminal`, `Monitor`, and computer-use `open_application` (read as `open -a <app>`); it cannot see `computer_batch` or what an app does once it runs.

### 2. Hooks: Two Ask-Only Guards

`install.sh` registers two `PreToolUse` hooks in your Claude Code `settings.json`. Both **only ever ask**: they never deny. Both **fail open**: a malformed payload, a missing table, a timeout or any internal error ends with no output and no effect, so a bug in a hook cannot lock you out of a tool.

- **`craft-shell-guard.py`** (matcher `Bash|mcp__terminal__run_in_terminal|Monitor|mcp__computer-use__open_application`) asks when a shell command would start a Craft app or tool directly. It matches all 13 names and their `-cli` forms at any path, case-insensitively, including behind wrappers (`sudo`, `env`, `nohup`, `time`, `nice`, `timeout`, `xargs`, `exec`, `command`, and similar), inside `bash -c` strings, `eval`, `$(...)`, backticks and `find -exec`, `open` of a Craft `.app`, interpreter code strings (`python -c`, `node -e`, and so on) and `osascript`/`launchctl` that mention one, and `craft-sandbox` called with a folder that is not exactly `<workspace>/<one app>` (also when that app folder is a symlink). It also asks for a command word built from a glob, braces or `${...}` that can name a Craft binary, `$'...'` and printf escapes that decode to one, decoded text piped into a shell (`base64 -d | sh`, `xxd -r | sh`), `ionice`, `flock`, `script`, `parallel`, `ssh`, `expect` or `crontab` given a Craft name, and `launchctl load` of a LaunchAgents plist. Reason: a Craft tool started from a shell is not fenced.
- **`craft-mcp-guard.py`** (matcher `mcp__(<the 13 names>)__.*`) asks before a Craft MCP call that: runs a tool the table in `hooks/risky-tools.json` marks as having effects outside the document (print, permanent delete, empty trash, open a link, add to Apple Photos, model or data downloads, run script code, set or remove document passwords, sign); saves or exports **without an explicit `path`**, which overwrites the opened file in place; imports with mode `move` or asks for `conflict: overwrite`; or passes any string argument that looks like a path (starts with `/`, `~`, `./`, `../` or `file://`, or contains a `..` segment, also after leading spaces) and does not resolve inside `<workspace>/<that app>`. Paths are normalized first, then compared as real paths, so a symlink inside the folder that leads outside is noticed. It also asks for a save or export to a relative or placeholder path, to a file that already exists, or into `<app>/in/`; for command ids named in the skills' Never lists (print, plug-ins, scripts, passwords, publishing, voice downloads ...); for PdfCraft form actions and links that would act when the saved PDF is used; for each line of a runner's `script` text read as `<command id> {json}`; and for CADCraft words typed into `command_line` or `script` that print, write other files or run LISP.

What a hook guarantees: if the script runs and recognizes the pattern, Claude Code is told to ask you, with a reason. Nothing more.

Limits:

- **They are heuristics, not a security boundary.** The shell guard reads command text. It follows a variable set earlier in the same command (`W=wordcraft-cli; $W`), but not one that comes from the environment, and it cannot see through aliases, shell scripts, a copied or symlinked binary, a program name built inside interpreter code (`python3 -c` with `\x77ordcraft-cli` or `'word' + 'craft-cli'`), or `curl | sh`. The MCP guard examines only the tools, command ids and argument names in its table; free-text arguments of other tools are not treated as paths. The CADCraft check is a word list, not a parser. The per-tool table was captured from the pinned versions and is incomplete by design; `hooks/risky-tools.json` lists, under `never_reviewed`, the Never-list ids it deliberately does not ask for, with the reason.
- **Over a size limit they ask instead of judging a partial view**: a shell command over 200000 characters or with more than 200 nested `$(...)`, a shell check that needs more than a fixed amount of parsing work (a work count, not a clock, so the result does not depend on the machine), or MCP arguments over 20000 nodes, 20 levels deep or 500 path arguments.
- **The hooks do not guard Edit or Write.** An agent could rewrite the hook scripts or `hooks/risky-tools.json` in the kit folder, or `settings.json`. The installer records the SHA-256 of the three hook files in the receipt; `doctor.sh` WARNs when they changed and FAILs its canned payloads when the risk table no longer answers them. That notices tampering after the fact; it does not prevent it.
- **The hook command is `python3 <script> ... || true`.** If the `python3` that Claude Code finds cannot run the script, `|| true` hides it and the hook is silently off. `doctor.sh` tests the hooks with the `python3` on its own `PATH` and FAILs when there is none; a Claude Code started with a different `PATH` is not covered.
- **What "ask" does depends on Claude Code.** In permission modes that skip or automate prompts, an ask may not reach a human. Not every mode has been tested. If you run Claude Code without prompts, do not count on the hooks; the fences still apply.
- They cover only the server names the installer registers (`wordcraft`, `gridcraft`, and so on) and only the Claude Code configuration folder they were installed into.
- The workspace path is written into the hook command at install time. If you move the workspace, run the installer again; `doctor.sh` warns about a mismatch.

Checks: unit tests in `hooks/tests/`, and `doctor.sh` sends each installed hook a canned payload and requires the right answer.

### 3. Download Pinning

`manifest/apps.lock.json` records, for each app, the exact version, the release URL, the size and the SHA-256 of the CLI zip and of the desktop disk image. `tools/gen-lock.sh` generates it (never edit it by hand) from the digest GitHub publishes for each release asset, and aborts if that digest disagrees with the `SHA256SUMS.txt` published with the same release. This is a consistency check between two upstream sources, not provenance. Known limit (not fixed yet): when fetching `SHA256SUMS.txt` fails for any reason (network error, rate limit), the script treats it like a release without that file and only warns, then uses GitHub's digest alone. The upstream releases also report `immutable: false`, so their assets can be replaced without a new tag: a re-pin after such a change shows up only in the git diff of `apps.lock.json`, which reviewers must read.

What the installer does with it:

- Validates it before anything else, also for `--dry-run`: schema, app names, versions, fences, every asset name, size (a whole number of bytes), SHA-256 and URL (`https://github.com/` only), the desktop bundle name (a plain `<Name>.app`), and `extraArgs` (only the per-app list the installer knows: `--author Claude` for WordCraft; never a fence flag). A lock that fails exits 3 before the plan;
- Downloads only over HTTPS (`--proto '=https' --proto-redir '=https' --tlsv1.2`), and only from URLs that start with `https://github.com/`;
- Compares the SHA-256 of the downloaded file with the lock; on a mismatch it deletes the file and reports FAIL for that app;
- Lists the zip before extracting and refuses absolute paths, `..` parts and symbolic links, requires exactly one `<app>-cli` entry, extracts only that entry into a private temporary folder, and installs it atomically (temporary file in the target folder, mode 755, `mv`);
- Runs the new program with `--version` and requires the pinned version string before it replaces anything;
- For desktop apps: mounts the disk image read-only without opening it (`hdiutil attach -nobrowse -readonly -noautoopen`), copies the `.app` to a temporary name, detaches, requires `codesign --verify --deep --strict` to pass, and reports what `spctl --assess` says. It leaves an app of a different version alone and warns.

What the guarantee is: the bytes that get installed are the bytes whose hash is in the lock at the commit you installed from. What it is not:

- **It is not proof that the vendor is trustworthy.** The digest and the `SHA256SUMS.txt` come from the same upstream release. If the upstream release or account were compromised before the pin, the pin would faithfully record the bad file.
- **The installer does not check who signed a command-line tool.** Inspected by hand: the 13 installed CLIs carry a valid Developer ID signature with the hardened runtime, all with the same Team ID (`codesign -dv --verbose=2 <path>` shows it). The installer relies on the SHA-256 alone for CLIs. For desktop apps it checks that the signature is valid, not whose it is.
- **Files fetched with `curl` carry no quarantine flag**, so macOS Gatekeeper does not evaluate them at first launch. The SHA-256 check replaces that.
- **The new CLI is run once before it is trusted by the installer:** `--version`, and for the five built-in fences `--help`, outside any sandbox, after the hash check. A binary that passes the hash check is code you have chosen to run.
- **An installed CLI is kept only if it is the file the kit verified.** The receipt records the SHA-256 of each CLI the kit installed. A re-run (and `--dry-run`) runs `--version`/`--help` only on a file with that SHA-256 and skips it as up to date; any other file of that name (installed by hand, by an older setup, or changed since) is shown as `replace*` in the plan, is not run, and is replaced by the verified download. `doctor.sh` FAILs when the file differs from the recorded SHA-256 and WARNs when an older receipt has none. Any process running as you can still replace `~/.local/bin/<app>-cli` between runs; the kit notices on the next run, it does not prevent it.

### 4. How the Installer Treats Your Machine

- No `sudo`, no `curl | sh`, no changes outside user-owned folders. No network access other than the HTTPS downloads from the lock.
- It prints a plan first (what it will download, with sizes, and every file and setting it will touch) and asks once. Without a terminal it exits with code 4 unless `--yes` is given. `--dry-run` writes, creates and downloads nothing; it does validate the lock and run `--version`/`--help` of CLIs the kit verified earlier (no other file is run).
- `CRAFT_KIT_HOME` must be new, empty or an earlier kit folder, and must not be or contain `--prefix`, the Claude Code folder or `--gui-dir` (the installer refuses otherwise), because `uninstall.sh` deletes the kit's fixed names inside it. `uninstall.sh` also refuses a receipt whose kit folder contains the prefix, the Claude folder or the workspace.
- Files of an older hand-made setup are recognized by content, not only by path, and moved aside (`<name>.bak-craft-kit-<time>`), never deleted; an unrelated file at one of those paths is kept with a warning.
- If replacing a differing MCP registration fails at the `add` step, the installer puts the previous command and arguments back (its `env`, if it had one, is not restored; the message says so).
- `settings.json` is edited only by `lib/settings_edit.py`: it refuses to touch a file that is not strict JSON, writes a timestamped backup (`settings.json.bak-craft-kit-<time>`) before the first change, replaces the file atomically (also when it is a symbolic link), keeps every other key, and is idempotent.
- MCP servers are added and removed only through `claude mcp add|remove -s user` for the kit's own 13 names. A different existing registration under one of those names is replaced, and the installer says so.
- Skills are rendered into `~/.claude/skills/craft-*`; a changed existing copy is backed up first.
- Workspace folders are created with mode 700.
- A receipt (`~/.local/share/craft-claude-kit/receipt.json`) records what was installed. `uninstall.sh` removes only what the receipt says the kit owns: registrations that point into the kit's folders, the kit's skills and hook entries, the CLIs that still have the SHA-256 the kit recorded, the sandbox wrapper and profile; desktop apps only with `--remove-gui` and only at the version the kit installed (moved to the Trash). **It never deletes the workspace.** Without a receipt (kit folder deleted by hand) it removes only the hook entries, its wrapper and the registrations through that wrapper, and lists the rest.
- Temporary folders are private (`mktemp -d`) and removed on exit and on Ctrl-C.
- Tests run the installer, uninstaller and doctor only inside `tests/isolated.sh`: a throw-away home folder, a fake `claude`, and tiny fixture archives. A test checks that a real home folder is left untouched.

## The Lock File Is the Trust Root

`install.sh` believes `manifest/apps.lock.json` completely. That file decides which URLs are downloaded, which hash is accepted, which fence is used for each app and which extra arguments are added to the server command. The installer's URL check only requires `https://github.com/`, not a particular project. **A fork or a modified copy of this repository can ship a different lock** that points at different binaries (with matching hashes) or weakens a fence, and everything above would still pass, because the installer would be checking your download against the fork's own numbers. Treat the checkout like any other code you are about to run: it installs programs, registers them with Claude Code and installs skills that steer an agent.

Before installing from a source you do not already trust:

1. Get the repository from the project you intend to use, and pin it to a tag or commit you have looked at.
2. Every download URL must be an upstream release. This prints nothing but the confirmation when it is true:

   ```sh
   jq -r '.apps[] | .cli.url, .gui.url' manifest/apps.lock.json | grep -v '^https://github.com/storytold/' || echo "all URLs point at github.com/storytold"
   ```

3. Check that the lock is what the public release data says. `tools/gen-lock.sh` reads only public GitHub metadata (it needs `gh`, `jq` and `curl`) and rewrites the lock from `manifest/pins.txt`. Run it from a copy of the script you trust, on a scratch copy of the repository, then compare:

   ```sh
   git diff --exit-code manifest/apps.lock.json   # no output means it matches
   ```

   On the day it was written, regenerating the lock reproduced the committed file byte for byte.
4. Read `install.sh`, `lib/`, `bin/craft-sandbox`, `share/craft.sb`, `hooks/` and `skills/` before you run anything. The `--dry-run` plan lists every file and setting that would change.
5. Run `./install.sh --dry-run` first: it validates the lock before printing the plan, and runs no program the kit has not verified itself. Run `./doctor.sh` afterwards.

Releases of the kit itself are not signed. There is no signature to verify beyond what Git and GitHub give you.

## What Has Not Been Verified

What was tested, and how, is in [docs/VERIFICATION.md](docs/VERIFICATION.md). Stated explicitly, so that nothing is assumed:

- Intel Macs, and macOS versions other than 26.6.2.
- Fence behavior for every tool of every app. Opening and saving with absolute paths was checked for the five built-in fences, the sandbox by probe, and the smoke sequences of all 13. Not every path-taking command was tried, nor were symbolic-link and race cases for the four `roots` apps.
- Whether the five built-in-fence apps make network connections, and whether the sandboxed apps can use Apple Events or the pasteboard to reach files the profile blocks (Mach lookups, and with them launching programs through macOS, are denied and tested).
- How the hooks behave in every Claude Code permission mode.
- Newer versions of the apps than the ones in the lock.
- The security of the Craft apps themselves.

## Practical Advice

- Keep prompts on for anything you would not want done twice. The fences limit blast radius; they do not make actions reversible.
- Copy files into `<workspace>/<app>/in/` rather than moving them, and keep originals elsewhere. The agent can still change or delete anything inside the workspace.
- Treat everything in `out/` as untrusted output of an agent that may have read hostile content, especially before opening it in another program. Generated documents can contain links and other active content.
- Do not install the desktop apps unless you need them (`--no-gui`). They are not fenced.
- Re-run `./doctor.sh` after a macOS update, after an app update and after changing the workspace. Run `./doctor.sh --smoke` to see each server do real work.
- Do not paste crash reports or full command output into issues without removing your user name and paths.
