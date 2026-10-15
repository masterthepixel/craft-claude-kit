# What Has Been Verified, and What Has Not

This page is the ledger: what was tested, how, on which versions, and what nobody has tried. If another page of
this repository says something works, the evidence is here, or the statement is marked as unverified. Last
updated 2026-10-14, kit version 0.1.0.

**Where this was tested.** One Apple-silicon Mac, macOS 26.6.2 (25G83), Claude Code 2.1.237. Tool versions:
the stock macOS `/bin/bash` 3.2.57, the stock `/usr/bin/python3` 3.9.6 (the test suite was also run with Python
3.14.4), `jq` 1.7.1 (Apple's, in `/usr/bin`) and 1.8.1 (Homebrew). **The 13 apps were the pinned versions** in
`manifest/apps.lock.json`: WordCraft 0.7.0, GridCraft 0.7.0, DeckCraft 0.7.0, PdfCraft 0.8.0, PhotoCraft 0.9.0,
VectorCraft 0.11.0, DesignCraft 0.8.0, CADCraft 0.7.0, FigCraft 0.6.0, FilmCraft 0.8.0, EffectCraft 0.10.0,
LightCraft 0.8.0, SoundCraft 0.7.0. The authors call the apps alpha software and release often, so a newer
release can behave differently from everything below.

**How to read it.**

| Level | Meaning |
|---|---|
| **Automated** | A script in the repository checks it and fails when it breaks. You can re-run it. |
| **Run by hand** | Someone ran the real thing and looked at the result. The commands are given so you can repeat it, but nothing in the repository keeps checking it. |
| **Read, not run** | Taken from a tool's `--help`, a schema or documentation. It may be wrong. |
| **Not verified** | Nobody tried. |

**Who did the checking.** The maintainer and language-model agents working under the maintainer's direction: one
agent per app drove the real server with the kit's own test client (`lib/mcp_probe.py`) in a scratch folder and
recorded what happened. Agents can misread output, and the run logs are not part of the repository. What the
repository does keep, and what you can re-run, is the smoke test, the tool snapshot and the text of each skill.

## At a Glance

| Area | Result | Level |
|---|---|---|
| The kit's own code: installer, uninstaller, doctor, hooks, helpers | Every step of `make test` passes in a fake home: 51 hook tests, 143 helper tests, 147 doctor checks, 56 installer and uninstaller cases (578 checks), 77 tool tests (section 1; run of 2026-10-15) | Automated |
| Same, with only the stock macOS toolchain (Python 3.9.6, jq 1.7.1, bash 3.2) | Passes (section 8) | Automated, run once |
| A real first install of the real downloads on a clean Mac | Run once, on a new macOS standard-user account with no dotfiles and no Claude Code (macOS 26.6.2, Apple Silicon, 2026-10-15), installed with `--no-mcp`: all 13 command-line apps and all 13 desktop apps downloaded, matched their SHA-256 and passed `codesign`; 14 of 14 skills and both hooks registered; `doctor.sh` and `doctor.sh --smoke` passed except the missing Claude Code CLI; a second run changed nothing; `uninstall.sh` left only the workspace and the desktop apps. This run found and fixed the desktop-app signature failure (see CHANGELOG). **Not covered:** MCP registration against a real Claude Code, Intel, macOS 13 to 25 | Run by hand, once |
| The 13 servers start, list tools and do real work | 13 of 13 smoke tests pass (101 steps, 2026-10-15, LightCraft after the Metal fix in section 2); each also fails when made to | Automated (`doctor.sh --smoke`) |
| Statements in the 14 skills | 439 checked against the live servers, 94 corrected, as counted by the per-app checking agents (their logs are not in the repository, so the figures cannot be traced line by line); explicit "not verified" markers remain | Run by hand |
| Sandbox fence, 8 apps | Refuses write, read, network and starting a program through macOS on this Mac; re-tested by `doctor.sh` on yours | Automated probe, plus run by hand |
| Built-in fences, 5 apps | Refuse outside paths and symlinks that lead out; the apps do the enforcing and `doctor.sh` cannot probe them | Run by hand; config only in doctor |
| Hooks | Unit tests pass; **the table of risky tools is known to be incomplete** (section 5) | Automated, incomplete |
| The lock file matches the public release data | Regenerated on 2026-10-14 and compared (section 6) | Run by hand |
| Desktop-app installation (`--gui`) | Fixture disk images only | Partly automated |
| Intel Macs; macOS other than 26.6.2 | **not verified** | Not verified |
| Which skill Claude picks for a request ("routing") | **not measured** | Not verified |
| What a hook's "ask" does in every Claude Code permission mode | **not tested** | Not verified |

[Back to top](#what-has-been-verified-and-what-has-not)

## 1. The Kit Itself

`make test` was last run on 2026-10-15 (macOS 26.6.2, Apple Silicon, the developer's own Python and jq, not under CI, fixtures built by the tests themselves; 0 checks skipped) and every step passed. It never touches the real home folder: the installer
tests run inside `tests/isolated.sh` (a fresh fake home, a fake `claude` that records its calls, tiny fake
downloads with correct checksums, and proxies pointing at a closed port so an accidental download fails at once).

| Step | Result |
|---|---|
| Syntax | 12 shell files and 15 Python files compile; shell files pass a check for constructs that bash 3.2 lacks |
| shellcheck | **skipped**: not installed on the development machine. The CI workflow installs it; run it before a release |
| Skill lint | 14 skills, 0 errors, 0 warnings (also `--strict`) |
| Public-hygiene scan | Clean over the working tree and the git history (this run ignored commit author metadata, as CI does; the full `make scan`, which reads it too, is also clean) |
| Hook tests | 24 for the MCP guard, 27 for the shell guard (each runs many table-driven cases) |
| Helper tests | 90 (lock, registration, local/project-scope overrides, rendering, the MCP test client, expectations) and 48 (the `settings.json` editor, including one backup per run), and 5 for the sandbox profile's Mach rule (only Metal's shader compiler is excepted, and the deny is in force) |
| Doctor tests | 147 checks, including a server whose first real call fails (must FAIL `first-call`), including the live sandbox probe run once with the real profile (must PASS) and once with a profile that allows everything (must FAIL), removal of `_doctor` folders (and leaving alone one doctor did not create), a partial install (`--only`, `--no-skills`, `--no-hook`) that must show no FAIL, and "no server process left behind" |
| Installer and uninstaller | 56 cases (574 checks): help, preflight, dry-run, fresh install, user config preserved, idempotent re-run, registration drift, wrong checksum, zip that tries to leave its folder, missing fence flag (the app must **not** be registered), `--only`, `--no-hook`, `--no-skills`, `--no-mcp`, migration from the hand-made setup, broken `settings.json`, a home folder with spaces, custom paths, a symlinked `settings.json`, upgrade, desktop apps (install, skip, other version), uninstall variants, terminal prompts, a re-run that keeps the previous workspace and app selection (and `--only all`), a kit folder deleted by hand (the hooks must exit 0; the uninstaller run from the clone cleans up), and "the real home is untouched" |
| Tool tests | 77: the skill linter and the public-hygiene scan are shown to catch planted violations |

The installer tests alone took about five minutes. The whole suite was also run with `PATH` limited to
`/usr/bin:/bin:/usr/sbin:/sbin`, so that it used Apple's own `python3` 3.9.6 and `jq` 1.7.1 (result in section 8).
That is the toolchain a new user's Mac has before anything is installed.

What these tests cannot show: that the real GitHub downloads unpack as expected; that the installer's calls to the
**real** `claude mcp add` and `claude mcp remove` are accepted by every Claude Code version (the fake `claude`
only mimics them, and neither the tests nor this review ran the real commands; the hand-made setup the kit was
extracted from used command lines of the same shape); that the desktop disk images mount and verify; and anything
about a clean Mac. The GitHub Actions workflow in `.github/workflows/ci.yml` had not run when this was written,
because the repository had not been pushed.

[Back to top](#what-has-been-verified-and-what-has-not)

## 2. The 13 Servers

The smoke test of each app (`tests/smoke/<app>.json`) starts the real server exactly as `doctor.sh` does,
creates something, saves it to an explicit path inside a scratch `_doctor/` folder, reads it back or renders it,
and checks the content. On 2026-10-14, in a scratch workspace, one server at a time, **all 13 passed** (99 steps),
and each one **also failed with exit status 1** when its first expectation was changed to something impossible, so
the tests can fail (FilmCraft's has since gained an H.264 export and a second render; see below). (The authors of the skills had shown this for nine of them; the other four, VectorCraft,
FilmCraft, EffectCraft and LightCraft, were checked in this pass.) The round-1 review re-ran the 8 sandboxed smoke
tests with the added Mach-lookup rule and reported that all passed; that was wrong for LightCraft. The release
review (2026-10-15) found that under the bare `(deny mach-lookup)` rule LightCraft's first step (`app.gpu`) aborted
the server with exit -6 every time (3 of 3 runs), and passed with that one line removed (6 of 6). The sandbox log
named the cause: Metal's shader compiler, the XPC service `com.apple.MTLCompilerService`, was refused. The
profile now allows exactly that service (rule 4a in `share/craft.sb`). On 2026-10-15, with the shipped profile,
one server at a time: all 8 sandboxed smoke tests passed, LightCraft's three times in a row (`app.gpu` reports
"Apple M1 (Metal)"), the 5 built-in-fence apps passed too (13 of 13, 101 steps), and the `fence-live` probe
for LightCraft and GridCraft still refused all four (write, home read, network, `open` of a probe bundle).

| App | Pinned | Tools | Smoke steps | Statements checked | Corrected | Not verified (read from schemas or not run) |
|---|---|---|---|---|---|---|
| WordCraft | 0.7.0 | 16 | 8 | 36 | 9 | Printing, sharing, macros, encryption and protection; `click`, `key` |
| GridCraft | 0.7.0 | 21 | 8 | 43 | 6 | Printing, opening links, automation scripts, sheet protection, undo after deleting a sheet, reading `.xls`/`.xlsb`/`.ods` |
| DeckCraft | 0.7.0 | 25 | 8 | 30 | 8 | Discarding recovery files, charts other than column and pie, rollback inside a failing batch |
| PdfCraft | 0.8.0 | 163 | 8 | 27 | 5 | Printing, links, JavaScript, passwords, signatures, removing hidden data. **OCR is unavailable in this release** |
| PhotoCraft | 0.9.0 \* | 25 | 8 | 36 | 6 | Plug-ins, actions, droplets, printing, shared presets, PSB write-back |
| VectorCraft | 0.11.0 | 32 | 7 | 30 | 10 | Printing, installing fonts and color profiles, plug-in effects, pointer gestures |
| DesignCraft | 0.8.0 | 25 | 7 | 36 | 6 | Printing, scripts, packaging, relinking, reverting |
| CADCraft | 0.7.0 | 12 | 8 | 30 | 8 | `PLOT` and publishing, LISP, `purge` and `overkill` (and their undo) |
| FigCraft | 0.6.0 | 18 | 7 | 38 | 7 | Plug-ins, widgets, collaboration and publishing, closing with force, reverting, restoring versions, JPEG and WebP export |
| FilmCraft | 0.8.0 \* | 17 | 10 | 35 | 5 | Codecs other than H.264, proxies, transcription, text-to-speech, reopening with unsaved edits |
| EffectCraft | 0.10.0 \* | 27 | 8 | 34 | 8 | Footage other than PNG, script, template and model-download commands, GPU rendering |
| LightCraft | 0.8.0 | 330 | 6 | 28 | 7 | Raw decoding (no raw sample), permanent delete, hand-off to Apple Photos, model downloads, folder moves |
| SoundCraft | 0.7.0 \* | 17 | 8 | 36 | 9 | Score printing, Sibelius export, plug-in rescans, video import, stems |
| **Total** | | | **101** | **439** | **94** | |

\* Re-pinned on 2026-10-15 from PhotoCraft 0.8.2, FilmCraft 0.7.2, EffectCraft 0.9.2 and SoundCraft 0.6.1. The counts in
these four rows are from the first check, on the previous version. Each skill was then re-checked against the new
version: about 45, 38, 40 and 32 statements, of which 7, 11, 1 and 9 were corrected (the checking agents' own counts;
their logs are not in the repository). On the new versions the tool names match the recorded lists, the smoke tests
pass (8, 10, 8 and 8 steps) and the sandbox refuses all four probes for FilmCraft and SoundCraft. The command lists
grew (PhotoCraft +17, FilmCraft +1, EffectCraft +50, SoundCraft +9 commands; none removed). PhotoCraft 0.9.0 still honors
the last of two `--automation-write-root` flags.

Notes on reading the table:

- **"Tools"** is the length of the server's tool list, recorded in `data/tools/<app>.json` (the file `doctor.sh`
  compares against). The snapshot keeps tool names, descriptions and parameter names, not parameter types or
  allowed values, so the drift check does not see a renamed option value.
- **"Corrected"** counts corrections to the skill drafts (some bundle several fixes). They are the reason the
  skills can be trusted more than the first drafts: see section 4.
- **A smoke test proves the path it walks, not the app.** LightCraft's cannot create an image through its MCP
  server, so it checks GPU setup and a keyword round trip, not a render or an export. PdfCraft's `redact_apply` is
  exercised (the redacted phrase was gone from the reopened file), but `doc_audit_redactions` flagged the applied
  box in four of four test files where other words shared the line, for a reason that has not been determined, so its
  findings need reading before a file is called clean.
- **The smoke tests found a real defect once.** With the first version of the sandbox profile, the FilmCraft and
  LightCraft smoke tests failed with `exited (code -11)`. That was fixed in `share/craft.sb` (see
  [FENCES.md](FENCES.md)); both passed again, twice in a row, on 2026-10-14. FilmCraft's H.264 export
  (`file.exportMedia` with `format: "h264"`), one of the calls that crashed under the first profile, is now part
  of its smoke test (10 steps: save as, reopen, export H.264, render again); it passed under the shipped profile on
  2026-10-14 and wrote a 44660-byte `.mp4` (its picture was not inspected). `file.save` (without "as") is not in
  the smoke test and was not run.
- **Window-only tools** (`click`, `key`, `pointer`, `ui_*`, dialogs, and `screenshot` in five apps) fail headless or
  do nothing. Some "window-only" tools turned out to work and some "working" tools do nothing; each skill's `Never`
  section lists what was observed ([APPS.md](APPS.md)).
- **OCR:** PdfCraft's release is documented as including text recognition models, but on the pinned version
  `ocr_status` reports `available: false` and `ocr_recognize` fails with "the text recognition models are not
  installed". The kit does not claim OCR.

[Back to top](#what-has-been-verified-and-what-has-not)

## 3. The Fences

### 3.1 The macOS Sandbox (GridCraft, DeckCraft, DesignCraft, CADCraft, FigCraft, FilmCraft, LightCraft, SoundCraft)

| What | Evidence | Level |
|---|---|---|
| A write outside the app folder, a read of a file under your home folder, a network connection and `open` of a probe bundle (launch through macOS) are each refused | `doctor.sh` runs all four through the registered wrapper for every sandbox app, on every run; the doctor tests also show the probe FAILs under a profile that allows everything. The launch probe was tested by hand against both profiles (2026-10-14): the profile without the Mach rule let the bundle run (marker written), the current one refused it (`open` exit 1) | Automated, plus by hand |
| The same, by hand: reading `/etc/hosts`, listing `/Applications` and `/Users/Shared` work; reading or listing under the home folder, and writing to `/Users/Shared`, fail with `Operation not permitted`; `stat` of the home folder works; writing inside the app folder and inside `/private/tmp` works; a grandchild process is refused too; TCP to `127.0.0.1` and to `192.0.2.1` fails with `Operation not permitted` | Commands in [FENCES.md](FENCES.md), run 2026-10-14 | Run by hand |
| The refusals also show through the real servers | Home-folder access from GridCraft, home reads and writes from CADCraft and FigCraft, reads from DeckCraft, DesignCraft, LightCraft and SoundCraft, a write outside the folder from DeckCraft, a network call from FigCraft | Run by hand, by the skill verifiers |
| All 8 servers start, and do real work, under the profile | The 8 smoke tests | Automated |

Not verified: whether a sandboxed app can reach outside through channels the profile does not restrict (Mach and
XPC services, Apple Events, the pasteboard, launching other programs); behavior on any macOS other than 26.6.2;
whether SoundCraft's server refuses a *write* outside its folder (only its reads were tried through the server; the
doctor probe covers writes); and how long `sandbox-exec` will keep working.

### 3.2 The Apps' Own Flags (WordCraft, PhotoCraft, VectorCraft, EffectCraft, PdfCraft)

| What | Evidence | Level |
|---|---|---|
| The five CLIs list their confinement flags in `--help`, and the other eight list none | `<app>-cli --help`, checked 2026-10-14; the installer repeats it for the five on every run | Automated (installer), run by hand (the eight) |
| Opening `/etc/hosts` is refused | All five, 2026-10-14 | Run by hand |
| Opening a **symlink placed inside the app folder that points at `/etc/hosts`** is refused | All five, 2026-10-14 | Run by hand |
| A path with `..` that leads out of the folder is refused | PdfCraft, 2026-10-14 | Run by hand |
| Saves and other writes to outside paths are refused | The skill verifiers tried saves, exports, imports and (EffectCraft) about a dozen different commands | Run by hand |
| The registration carries your folder in the fence position | `doctor.sh` `fence-config` | Automated; **config only** |

Not verified: that each app enforces its flag in every code path (there are hundreds of commands per app and not
all take paths); races between the check and the use; the network behavior of these five apps, which the kit does
not restrict; channels the flags do not cover (WordCraft's documentation mentions a local socket used by its
Zotero commands); how relative paths resolve when the server is started by Claude Code (the registration sets no
working directory, the probe used the app folder), which is why the skills use absolute paths.

[Back to top](#what-has-been-verified-and-what-has-not)

## 4. The Skills

Each factual sentence in a per-app skill was checked against the running server in a scratch workspace: 439
statements, 94 corrections, between 5 and 10 per skill. The first drafts were written by a model from the
server's tool list and instructions; a lint passed them; they were still wrong in many specific ways. The
kinds of error: over-broad fence claims (every one of the eight sandbox-app drafts), window-only lists wrong in
both directions, defaults nobody mentioned (a save without `path` overwrites; `~` is not expanded; folders are
not created), a feature said to be missing that exists (DesignCraft's PDF export), invented parameter shapes
(WordCraft color arrays), and claims copied from a third-party source.

Where something could not be run (it prints, deletes for good, installs, downloads, needs a window), the skill says
so: explicit `(not verified on vX.Y.Z)` markers, and further `Never` entries that read "not run". The figures 439
and 94 are the totals the checking agents reported per app; how each counted a "statement" was not recorded. Since
round 1 of the review, every Gotchas section either marks each item ("verified" or "(not verified on vX.Y.Z)") or
opens with "Seen on vX.Y.Z (2026-10) unless marked", and the linter fails a skill that does neither. The linter
checks that every tool a skill names exists in the app's snapshot, that the size budget is kept and that the
structure is right ([SKILLS.md](SKILLS.md)). It cannot check truth; only a live server can.

Not verified:

- **Routing overlap (accepted).** "Edit this logo.png" matches both PhotoCraft (raster edits of .png) and
  VectorCraft (logos); PhotoCraft's description now sends logos and vector art to VectorCraft, but no routing test
  shows which one Claude picks.
- **Routing.** Nobody measured whether Claude picks the right skill for a request, or avoids the Craft skills for
  code-generated `.docx`/`.xlsx`/`.pptx`/`.pdf`. The descriptions were reviewed by hand and tried on a few real
  questions.
- **Prompt-injection resistance.** The skills tell Claude to treat file contents as data. That was not tested
  against hostile files.
- **Freshness.** Everything above holds for the pinned versions. A skill is only as good as its last re-check
  ([UPDATING.md](UPDATING.md)).

[Back to top](#what-has-been-verified-and-what-has-not)

## 5. The Hooks

The two hooks are heuristics that ask and never deny, and they fail open ([HOW-IT-WORKS.md](HOW-IT-WORKS.md)).

| What | Evidence | Level |
|---|---|---|
| Unit tests for the shell guard (27) and the MCP guard (24): wrappers, `bash -c`, interpreters, `open`, `craft-sandbox` roots; risky tools, saves without a path, `mode: "move"`, paths outside the folder, a workspace reached through a symlink, malformed and binary input fails open, the guards never answer "deny" | `hooks/tests/` | Automated |
| After install, both hooks are registered with the right matcher and workspace and each answers a canned payload correctly | `doctor.sh` `hooks` checks | Automated |

**Which Never-list ids the guard asks for.** Since round 1 of the review, every dotted command id that a skill's
Never section names either makes the MCP guard ask (the app's `ask`/`ask_ids` rows, the global patterns, or an
argument rule such as FilmCraft `media.makeOffline` with `deleteFiles: true`), or is listed in
`hooks/risky-tools.json` under `never_reviewed` with the reason it is not guarded; `tools/lint_skills.py` fails
otherwise. Guarded now, among others: CADCraft `plot`, `exportpdf`, `publish`, `pdfbook`, `wblock`, `export`,
LISP and their aliases (through `execute`, and typed into `command_line`/`script`, by a word list);
FilmCraft `tts.downloadVoices`, `audio.voiceover.start`, `file.projectManager`, `file.closeProject` with `force`;
PhotoCraft and FigCraft plug-in commands; SoundCraft `file.print_score`, `file.send_to_sibelius`,
`file.export_sibelius`; GridCraft links, scripts and protection; WordCraft `file.encrypt`, `file.share`, macros;
EffectCraft script commands and expressions (also `prop.setExpression` through a runner); PdfCraft form actions
and web links; DesignCraft and DeckCraft `hyperlink.create` with a `url` or `email` (a link that stays in the
saved file); DeckCraft `file.package` (as DesignCraft); CADCraft `ATTACH` typed without the X prefix; and the
UI-level tools that can fire Print or Save: SoundCraft `menu_invoke` (also inside `batch`), VectorCraft
`invoke_menu`, PhotoCraft `ui_menu_invoke`, DesignCraft `dialog_confirm`, and the `key` tools of WordCraft,
DeckCraft, DesignCraft and SoundCraft and FilmCraft `ui_key`. Known remaining gaps: FigCraft `key` and
VectorCraft `press_key` (left out because those two apps do some window work headless, so asking on every key
press could be constant noise; whether a key there can print was not checked, and the guard does not read which
keys are sent), and each server's live command list has not been compared with the table, so ids the
skills do not name are not covered. Prose only (in
`never_reviewed`, with reasons): in-document reverts and discards (`file.revert`, `file.recovery.discard`,
`session.revert`, `version.restore`), app-wide presets and preferences, commands the PhotoCraft server refuses
under the fence, and in-document deletes. The command ids come from the skills, which were written from each
app's live `list_commands`; `data/tools` holds tool names only, so the ids are not re-checked against a
snapshot. The table remains incomplete by design; the fences, not the hooks, are the control.

Not verified: what an "ask" does when Claude Code runs in a permission mode that skips or automates prompts (the
kit's tests do not drive Claude Code); that Claude Code runs the hooks with a 10-second timeout as configured.

[Back to top](#what-has-been-verified-and-what-has-not)

## 6. Pinning and Downloads

| What | Evidence | Level |
|---|---|---|
| `manifest/apps.lock.json` is what the public release data says | `tools/gen-lock.sh` regenerated it from `manifest/pins.txt` on a scratch copy and the result was byte-identical to the committed file (2026-10-14, twice: before and after the license field changed). The script refuses to write an entry whose SHA-256 disagrees with the `SHA256SUMS.txt` published with the release (a consistency check, not provenance). A release without that file only gets a warning, and then GitHub's digest alone is used. Known limit, not fixed yet: any failure to fetch that file (network error, rate limit) is treated the same way, as a warning. The releases report `immutable: false` | Run by hand |
| The 13 installed `<app>-cli` programs on the development machine | Each passes `codesign --verify --strict`, is signed with a Developer ID Application certificate and the hardened runtime, with one Team ID for all 13, and is a universal `x86_64 arm64` binary. They carry `com.apple.provenance` and no `com.apple.quarantine` attribute | Run by hand |
| A wrong checksum deletes the download and fails that app; a zip with absolute paths, `..` parts or symlinks is refused; the installed program must report the pinned version | Installer tests with fixtures | Automated |
| Downloading, hashing and unpacking the **real** assets | Run once on the clean account (2026-10-15): the 13 command-line zips (819 MB) and 13 disk images downloaded, matched the lock, unpacked, and each program reported its pinned version | Run by hand, once |

Not verified: notarization of the command-line programs; whose signature the desktop apps carry (the installer checks
that it is valid, not whose it is). On the clean account `spctl` accepted all 13 desktop apps, and the real disk images
revealed the extended-attribute problem that the fixtures had missed (fixed; see the CHANGELOG).

[Back to top](#what-has-been-verified-and-what-has-not)

## 7. What Is Not Verified, in One List

- The installer's calls to the real `claude mcp add` and `claude mcp remove` on a clean Mac. The one clean-account
  install (section 1) used `--no-mcp`, because that account had no Claude Code.
- Whether macOS asks to confirm the first launch of a desktop app (`spctl` accepted all 13, which is not the same).
- Intel Macs; macOS 13 to 25; macOS later than 26.6.2; Claude Code versions other than 2.1.237.
- Whether `sandbox-exec` keeps working in future macOS releases.
- Whether the five built-in fences hold in every code path of their apps; races; network behavior of those five.
- Apple Events and the pasteboard from a sandboxed app (Mach lookups are denied, and launching a program through
  macOS is refused: tested by hand and by `doctor.sh`).
- Hooks: coverage of the risky-tools table (section 5) and the behavior of "ask" in every permission mode.
- Routing between skills, and resistance to hostile files.
- The printing, scripting, plug-in, password, signing, download and delete-for-good commands of every app.
- Commands that need a window or a running desktop app (`--connect`, `--bridge`, `--control`), by design.
- The GitHub Actions workflow (not yet run). `shellcheck` was run once locally at warning level and was clean.
- Memory and CPU use of 13 servers across several Claude Code sessions.
- Anything about app versions other than the pinned ones.

[Back to top](#what-has-been-verified-and-what-has-not)

## 8. Re-Running It Yourself

```sh
make test                                      # section 1; never touches your real setup (several minutes)
./doctor.sh --smoke                            # section 2 against your own install (writes then removes <workspace>/<app>/_doctor)
python3 lib/mcp_probe.py --app wordcraft --workspace "$(mktemp -d)" list-tools    # what a server offers
```

To run one smoke script by hand with `mcp_probe.py ... run tests/smoke/<app>.json`, create
`<workspace>/<app>/_doctor/` first: the scripts save into it and most apps do not create missing folders (`doctor.sh`
creates and removes it for you).

Show that a smoke test can fail: change the first expectation of a copy to something impossible and expect exit
status 1 ([UPDATING.md](UPDATING.md)). Check the lock: regenerate it on a scratch copy and compare (also in
[UPDATING.md](UPDATING.md)). The sandbox commands of section 3.1 are in [FENCES.md](FENCES.md).

Result of the run with only the stock macOS toolchain on `PATH` (section 1), 2026-10-14:
`env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin make test SCAN_ARGS=--no-commit-meta` used Apple's
`python3` 3.9.6, `jq` 1.7.1 and `/bin/bash` 3.2.57, and every step passed (24 + 27 hook tests, 85 + 45 helper
tests, 102 doctor checks, 36 installer and uninstaller cases, 68 tool tests; the installer tests took about eight
minutes that time). `shellcheck` was skipped there too.

Incorrect statements, and checks that pass when they should not, are welcome as issues;
a false assurance is treated as a vulnerability ([SECURITY.md](../SECURITY.md)).

[Back to top](#what-has-been-verified-and-what-has-not)
