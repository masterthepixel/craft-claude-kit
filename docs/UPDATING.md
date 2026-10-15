# Updating

Two audiences: [people who use the kit](#for-users-upgrading) and [maintainers who re-pin it](#for-maintainers-moving-the-pins).
Background: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). The kit installs the app versions it was verified against, not
"latest": a new upstream release reaches users when a new kit release re-pins it. The Craft apps describe
themselves as alpha software and release often, so expect re-pins to be frequent and expect each one to need the
checks below; what a re-pin does and does not prove is in [VERIFICATION.md](VERIFICATION.md).

## For Users: Upgrading

```sh
cd craft-claude-kit
git pull                    # or: git fetch --tags && git checkout vX.Y.Z   to stay on a release
./install.sh --dry-run      # read the plan; nothing is changed
./install.sh                # do it
# then open a NEW Claude Code session and run:
~/.local/share/craft-claude-kit/doctor.sh
```

The installer is the updater: it is idempotent, so running it again repairs what is missing and skips what is up to
date. Nothing updates in the background. What a re-run does to each part:

| Part | On re-run |
|---|---|
| `<app>-cli` programs | Skipped when the file still has the SHA-256 the kit recorded when it installed it and `--version` shows the pinned version; **upgraded** when it is the kit's file at another version (the plan shows `0.8.1 -> 0.8.0` style lines before it asks). A file of that name the kit did not install, or cannot verify, is shown as `replace*`: it is not run, it is moved aside to `<app>-cli.bak-craft-kit-<timestamp>` (the summary lists it; uninstall leaves it), and the verified download takes its place. A matching `--version` alone is not trusted, because the server registration will run that file |
| MCP registrations | Skipped if identical to what the kit would register; if different (a new workspace, a changed fence, a new kit release) it saves the old entry to `~/.local/share/craft-claude-kit/backup/<app>-mcp-<timestamp>.json`, runs `claude mcp remove <app> -s user` and then `claude mcp add`, and says so. Servers the kit did not create are not touched |
| Skills | Re-rendered; identical ones are skipped; one you edited is first saved as `SKILL.md.bak-<timestamp>` |
| Hooks | Re-registered; an outdated entry of the kit's own is removed first; a backup of `settings.json` is made before any change |
| Runtime copy in `~/.local/share/craft-claude-kit` and `craft-sandbox` | Files that differ are replaced |
| Desktop apps (`--gui`) | Skipped at the pinned version; **left alone**, with a warning, at any other version. To switch: quit the app, move it to the Trash yourself, re-run with `--gui` |
| Your workspace and the files in it | Never touched |

Notes:

- `./install.sh --only wordcraft,pdfcraft` limits the apps; the skills and hooks are still refreshed.
- **Downgrading** works the same way: check out an older tag, run `./install.sh`. The plan will show the programs
  that change. Documents saved by a newer app version may not open in an older one; the kit cannot check that.
- To see what is installed against what is pinned without changing anything: `./doctor.sh` (`cli-installed` shows
  a mismatch) or `./install.sh --dry-run`.
- If you move your clone, nothing breaks: everything the system uses is in `~/.local/share/craft-claude-kit`. You
  need a clone again only to upgrade.
- **Newer app versions than the pin** are not supported. You can try one by editing `manifest/pins.txt` and
  running `tools/gen-lock.sh` (needs the GitHub CLI), then `./install.sh`. Expect `doctor.sh` to show drift, and the
  skills' statements (checked on the pinned version) may be wrong for it.
- A changelog of kit releases is in [CHANGELOG.md](../CHANGELOG.md).

[Back to top](#updating)

## For Maintainers: Moving the Pins

Everything is driven by `manifest/pins.txt` (one `app version` per line) and the lock `manifest/apps.lock.json`
generated from it. Never edit the lock by hand: its SHA-256 values are what the installer trusts.

### 1. Choose Versions and Regenerate the Lock

```sh
$EDITOR manifest/pins.txt        # or skip this and re-pin everything to the newest releases:
tools/gen-lock.sh                # pins.txt  ->  manifest/apps.lock.json   (make lock)
tools/gen-lock.sh --latest       # ignore pins.txt, lock each app's latest release  (make lock LATEST=1)
git diff manifest/apps.lock.json
```

`gen-lock.sh` needs `gh` (authenticated; it only reads public release metadata), `jq` and `curl`. For every app it
reads the release by tag, picks exactly one `<app>-cli-<version>-macos-universal.zip` and one
`<app>-<version>-macos-universal.dmg` (anything else aborts), takes the SHA-256 from the GitHub API and
cross-checks it against the `SHA256SUMS.txt` that upstream publishes with the release (a mismatch aborts; a release
without that file only warns and uses the API digest). It rewrites all 13 entries each time, so review the diff:
versions, tags, sizes, hashes, and nothing else. The license string is read from the upstream repository (the
value `MIT OR Apache-2.0` when it has both a `LICENSE-MIT` and a `LICENSE-APACHE` file, otherwise GitHub's own
detection), so a license change upstream shows up in the diff too: read it. The per-app fence mode and extra
arguments (WordCraft's `--author Claude`) are not upstream data: they live in the `meta()` table inside
`tools/gen-lock.sh`. If a new release adds a confinement flag to an app that is currently `sandbox`, or renames
one, change that table and regenerate.

To check an existing lock instead of changing it, run the script on a scratch copy and compare (anyone with `gh`
can do this; it reads only public release metadata):

```sh
S=$(mktemp -d); mkdir "$S/tools" "$S/manifest"
cp tools/gen-lock.sh "$S/tools/"; cp manifest/pins.txt manifest/apps.lock.json "$S/manifest/"
(cd "$S" && bash tools/gen-lock.sh) && cmp "$S/manifest/apps.lock.json" manifest/apps.lock.json && echo "lock reproduced"
```

### 2. Install the New Programs Into a Throw-Away Place

This downloads the real files (about 819 MB) but touches none of your real setup, because `HOME` is a temporary
folder and the installer is told to skip registration, skills and hooks:

```sh
T=$(mktemp -d)
HOME="$T" CRAFT_KIT_HOME="$T/kit" ./install.sh --yes --no-gui --no-mcp --no-skills --no-hook \
    --prefix "$T/bin" --workspace "$T/ws"
```

If any app fails here, the summary says why (a SHA-256 mismatch, a changed zip layout, a program that reports another
version). Fix the lock, not the installer, unless the release layout really changed.

### 3. Refresh the Tool Snapshots and Read the Diff

```sh
make snapshot CRAFT_PREFIX="$T/bin"              # all 13; or: make snapshot SNAPSHOT_APPS="wordcraft pdfcraft" CRAFT_PREFIX=...
git diff --stat data/tools
git diff data/tools/<app>.json
```

`data/tools/<app>.json` holds the server name and version, the server's own `instructions` text, and for each tool its
name, description, parameter names and required parameters. It does **not** hold input schemas or enum values, so a
renamed enum value will not show up here. The diff is the first place to see added and removed tools, changed
descriptions and changed server instructions. `doctor.sh` compares only server version and tool names against it.

### 4. Re-Check the Skills

```sh
make lint-skills            # a skill that names a removed tool is an error
```

Then, per app whose version moved: re-run the statements in its `Gotchas` that say "verified", and the workflow, against
the new server (see "Evidence: How a Gotcha Earns Its Place" in [SKILLS.md](SKILLS.md)). Pay attention to anything the new server instructions now
say (a gotcha may have become redundant), to tools in `Load first`, and to `Never` entries (a command may have been
renamed or added). Update the version in every `(not verified on vX.Y.Z)` you re-examined, and in the skill's own
"verified on" lines. Keep the budgets (body 3,800 bytes).

### 5. Review the Hook Table

`hooks/risky-tools.json` lists, per app, tools and command ids that need an "ask", save-style tools that must carry a
`path`, and risky arguments, and records the versions it was written against (`captured.versions`). Compare the new
command lists (`list_commands` / `command_list`, or the snapshot) with the old for anything that prints, deletes for
good, empties a trash, opens a link, downloads, runs script code, sets passwords or talks to another application, and add
entries. Then `python3 hooks/tests/test_mcp_guard.py`. The hooks are heuristics; this table is where their coverage grows.

### 6. Smoke-Test Before and After

Without installing anything for real, drive each new program through its scripted test, in the throw-away place:

```sh
for a in $(python3 lib/craftkit.py apps); do
  mkdir -p "$T/ws/$a/_doctor"
  if python3 lib/mcp_probe.py --app "$a" --workspace "$T/ws" --prefix "$T/bin" run "tests/smoke/$a.json" >/dev/null
  then echo "ok   $a"; else echo "FAIL $a"; fi
done
```

(`doctor.sh --smoke` does the same against the installed apps, creating and removing `_doctor/` itself; `make smoke`
runs it.) A sandbox app that crashes with `code -11` points at the profile ([FENCES.md](FENCES.md)).

A test that cannot fail proves nothing. After you change a smoke script, show that it can fail by making its first
expectation impossible and checking that the run exits 1:

```sh
jq '.[0].expect.contains = "__never__"' tests/smoke/wordcraft.json > "$T/neg.json"
python3 lib/mcp_probe.py --app wordcraft --workspace "$T/ws" --prefix "$T/bin" run "$T/neg.json"; echo "exit $?"   # must print exit 1
```

### 7. Whole Test Suite and Docs

```sh
make test                    # syntax, bash 3.2 check, shellcheck (if installed), skill lint, public-hygiene scan,
                             # hook tests, helper tests, installer end-to-end tests with fixtures
```

It takes several minutes on an Apple-silicon laptop (the installer tests alone took about five). `shellcheck` is
optional locally and is skipped with a note when it is not installed (`brew install shellcheck`); install it
before a release, because it is the one step a local run can silently miss.

`make test` never touches your real setup: the installer tests run in a fake home with a fake `claude` and tiny fake
downloads. The fixture lock is derived from the real lock and rebuilt when it changes (`tests/test_install.sh` runs
`tests/fixtures/build.sh` first; run it yourself with `--force` if in doubt), so versions need no manual change
there. Then update the places that quote versions and sizes:

- `README.md` (download sizes table), `docs/APPS.md` (versions, sizes, tool counts, per-app limits), and
  `docs/VERIFICATION.md` (versions, date, results). A quick table of lock values:
  `jq -r '.apps | to_entries[] | "\(.key) \(.value.version) \(.value.fence) \(.value.cli.size) \(.value.gui.size)"' manifest/apps.lock.json`
- `hooks/risky-tools.json` `captured.versions`;
- `CHANGELOG.md`.

### 8. Release Checklist

1. `git status` is clean apart from the intended changes; `make test` passes locally, and CI is green
   (`.github/workflows/ci.yml` runs `make test SCAN_ARGS=--no-commit-meta` on macOS and a skill lint plus shellcheck
   on Linux).
2. `make scan`: the full public-hygiene scan, including the **whole git history** and commit author metadata. It must be
   clean before anything is published. Keep private strings in a denylist file outside the repository and set
   `CRAFT_KIT_EXTRA_DENYLIST` ([SKILLS.md](SKILLS.md)), or pass them as `SCAN_DENY_TERMS=a,b` (for example
   the maintainer's own handle, which public text must not contain unless that is decided on purpose).
   If the repository moves, update the clone URL in README.md and CONTRIBUTING.md.
3. On a Mac: `./install.sh --dry-run` from a fresh clone, `./doctor.sh --smoke` against real installs. At least once per
   release, do a real first install on a clean user account: the kit's tests cover the download path only with fixtures
   ([VERIFICATION.md](VERIFICATION.md)).
4. Bump `VERSION` (it is the kit's own version, shown by `install.sh --version`, recorded in the receipt, and compared
   by `doctor.sh`). Suggested: patch for fixes, minor for re-pins and new features, major for anything that changes
   the install layout or the receipt.
5. Move the `CHANGELOG.md` entries under the new version and date.
6. Commit, tag `vX.Y.Z` (annotated), push, and publish the release notes from the changelog.

### If the Receipt Format or Install Layout Changes

`uninstall.sh` and `doctor.sh` read a receipt written by an earlier version. Keep reading `schema: 1` receipts, or bump
`schema` and make both tools handle the old one, and cover it in `tests/test_install.sh` (the `upgrade` and `legacy`
cases are the template). The installer rewrites the receipt on every run, which is how old installs migrate.

Fields added without a schema change (readers tolerate their absence): `apps.<app>.cliSha256` (SHA-256 of the
program the kit installed), `apps.<app>.guiVersion` (version of the desktop app the kit installed) and
`hooksSha256`. Consequences for an install made before they existed, until the next `./install.sh` run records
them: the next run replaces each `<app>-cli` once with the verified download (it cannot tell the old file is the
kit's; about 819 MB for all 13), `uninstall.sh` keeps the programs (no checksum to prove they are the kit's) and,
with `--remove-gui`, keeps the desktop apps (no recorded version), and `doctor.sh` WARNs that the checksums are
missing.

[Back to top](#updating)

## Adding a 14th App

The installer and the doctor read the app list from the lock, and the uninstaller reads the receipt plus
`CK_APPS_ALL` in `lib/common.sh`, so most of the work is data and tests. Places that hold the list of apps:

| File | What to add |
|---|---|
| `manifest/pins.txt`, `tools/gen-lock.sh` | The pin, the `APPS` list and a `meta()` line (bundle name, fence mode, extra arguments, description); then regenerate the lock |
| `lib/common.sh` | `CK_APPS_ALL` (also builds the MCP hook matcher) |
| `hooks/craft-mcp-guard.py`, `hooks/craft-shell-guard.py` | `APPS` (the shell guard uses the short name: `word` for `wordcraft`) |
| `hooks/risky-tools.json` | An `apps.<app>` entry: `runners`, `ask`, `save`, `args` |
| `tools/lint_skills.py`, `Makefile` | `APPS` (and `OVERLAP_APPS` if it overlaps other tools) |
| `data/tools/<app>.json` | `make snapshot SNAPSHOT_APPS=<app>` |
| `tests/smoke/<app>.json` | A 6 to 8 step scripted test that writes only under `{root}/_doctor/` |
| `skills/craft-<app>/SKILL.md`, `skills/craft-apps/SKILL.md` | The skill and a row in the master skill's table |
| Tests and fixtures | The hard-coded app lists in `tests/test_install.sh`, `tests/test_craftkit.py`, `tests/test_tools.sh`, `tests/isolated.sh`, `tests/fixtures/build.sh` and the hook tests |
| `README.md`, `SECURITY.md`, `NOTICE.md`, `docs/APPS.md`, `docs/FENCES.md`, `docs/VERIFICATION.md` | The tables, the fence list, the attribution and the verification matrix |

Run `make test` and fix what the tests point out; the "13" in prose (README, docs, skills) should also be searched for and updated.
Retiring an app is the same list in reverse; its users need an `uninstall`-style note in the changelog, because the
installer does not remove programs for apps that left the lock.

[Back to top](#updating)

## When Upstream Changes Something Under You

| What changed | What you will see | What to do |
|---|---|---|
| A fence flag was renamed or removed | The installer will not register that app (`NOT registered (fail-closed)`), and `doctor.sh` FAILs `fence-config` | Decide the new fence: update the app's mode and flags (`tools/gen-lock.sh` `meta()`, `lib/craftkit.py` if a new mode is needed), the tests, and [FENCES.md](FENCES.md) |
| An asset was renamed | `gen-lock.sh` aborts ("expected exactly one asset matching ...") | Adjust the patterns in `gen-lock.sh` |
| A release asset was replaced under the same tag | Users see a SHA-256 mismatch | Investigate before re-locking; a silent replacement is a reason to look closely, not to re-pin quickly |
| A tool was renamed or removed | `make lint-skills` errors; `doctor.sh` WARNs `drift` and `tool-refs` | Update the skills and the snapshot |
| A program crashes under the sandbox profile | Smoke tests fail with `code -11` or similar | See [FENCES.md](FENCES.md#what-went-wrong-once-and-what-it-taught); loosen the profile as little as possible and add a smoke step that would have caught it |
| Apple changes `sandbox-exec` | `doctor.sh` FAILs `sandbox-exec` or `fence-live` | [FENCES.md](FENCES.md#sandbox-exec-is-deprecated) |

[Back to top](#updating)
