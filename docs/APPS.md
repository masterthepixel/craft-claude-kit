# The 13 Apps

What each app is, which version the kit pins, how it is fenced, how big it is, and the limits worth knowing
before you ask Claude to use it. The limits come from the per-app skills (`skills/craft-<app>/SKILL.md`), whose
statements were checked against the live servers at the pinned versions; where something could not be checked it
says so. Versions, sizes and fences are read from `manifest/apps.lock.json`. See also
[FENCES.md](FENCES.md), [SKILLS.md](SKILLS.md) and [VERIFICATION.md](VERIFICATION.md).

All 13 apps are by their respective authors ([storytold](https://github.com/storytold)), dual-licensed
MIT OR Apache-2.0, and are **not** part of this repository: the installer downloads them from the official GitHub
releases (`https://github.com/storytold/<app>`). The kit is an unofficial, independent project. The authors
describe the apps as alpha or early-development software and publish new releases often, which is why the kit pins the exact versions
below: everything on this page was checked on those versions only, and a newer release can change any of it.

## Summary

| App | Use it for | Pinned | Fence | CLI download | Desktop download | CLI on disk | Tools | Smoke steps |
|---|---|---|---|---|---|---|---|---|
| WordCraft | Word processing: letters, reports | 0.7.0 | roots | 86 MB | 105 MB | 153 MB | 16 | 8 |
| GridCraft | Spreadsheets, formulas, charts | 0.7.0 | sandbox | 11 MB | 25 MB | 29 MB | 21 | 8 |
| DeckCraft | Slide decks | 0.7.0 | sandbox | 68 MB | 81 MB | 137 MB | 25 | 8 |
| PdfCraft | Read, fill, merge, redact PDFs | 0.8.0 | root | 61 MB | 94 MB | 124 MB | 163 | 8 |
| PhotoCraft | Raster images with layers (PSD) | 0.9.0 | roots | 68 MB | 90 MB | 131 MB | 25 | 8 |
| VectorCraft | Logos, icons, illustration | 0.11.0 | roots | 106 MB | 132 MB | 198 MB | 32 | 7 |
| DesignCraft | Page layout: flyers, brochures | 0.8.0 | sandbox | 62 MB | 80 MB | 130 MB | 25 | 7 |
| CADCraft | 2D CAD drafting | 0.7.0 | sandbox | 52 MB | 67 MB | 104 MB | 12 | 8 |
| FigCraft | Interface design (frames, auto layout) | 0.6.0 | sandbox | 78 MB | 94 MB | 162 MB | 18 | 7 |
| FilmCraft | Video editing | 0.8.0 | sandbox | 61 MB | 74 MB | 121 MB | 17 | 8 |
| EffectCraft | Motion graphics, compositing | 0.10.0 | roots | 60 MB | 64 MB | 144 MB | 27 | 8 |
| LightCraft | Raw photo library and developing | 0.8.0 | sandbox | 103 MB | 108 MB | 216 MB | 330 | 6 |
| SoundCraft | Multitrack audio | 0.7.0 | sandbox | 6.7 MB | 23 MB | 18 MB | 17 | 8 |
| **Total** | | | | **821 MB** | **1.0 GB** | **1.7 GB** | | |

Columns:

- **Fence**: `roots` = the app's `--automation-read-root` and `--automation-write-root`; `root` = its `--root`;
  `sandbox` = `craft-sandbox` (macOS `sandbox-exec`, no network). Details and limits: [FENCES.md](FENCES.md).
- **Downloads** are the sizes of the release files on GitHub (decimal megabytes, as GitHub shows them). The command
  line apps and the desktop apps are both fetched by default. A
  re-run downloads only what is missing or at another version.
- **CLI on disk** is the size of the installed `<app>-cli` program, measured on the development machine.
- **Tools** is the number of MCP tools the server lists, from the snapshot in `data/tools/<app>.json`. LightCraft's
  330 is mostly one wrapper per command (`cmd_*`), which is why its skill loads tools by exact name.
- **Smoke steps** is the length of the scripted test in `tests/smoke/<app>.json` that `doctor.sh --smoke` runs.

Everything runs headless. The window-only tools (`click`, `key`, `pointer`, `drag`, `ui_*`, dialogs, and
`screenshot` in WordCraft, DesignCraft, DeckCraft, GridCraft and SoundCraft) do not work; `screenshot` in
VectorCraft and FigCraft does. Eleven apps have a render or preview tool that works (`render_page`,
`render_slide`, `page_render`, `render_preview`, `render`, `render_frame` ..., and FigCraft's `screenshot`).
GridCraft and SoundCraft have none: Claude verifies GridCraft by reading cells back (`read_range`,
`inspect_workbook`) and SoundCraft by reading the session back (`inspect_session`) and checking the peak and
loudness a bounce reports. A few "window-only" tools turned out to run headless in some apps (FigCraft's `key`
and `pointer`, DesignCraft's `pointer` and `select_tool`), and some succeed without doing anything (VectorCraft's
`press_key`, SoundCraft's `transport.play`); each app's skill lists what was observed.

[Back to top](#the-13-apps)

## Behaviors Shared by Most Apps

Found app after app while the skills were checked; each skill states
the app-specific form.

- **A save with no `path` overwrites the file that was opened, in place** (verified in at least eight apps;
  PhotoCraft's rule is narrower: only its own formats). The skills always pass an absolute `path`, and the MCP
  guard asks before a save-style call without one.
- **`~` is not expanded**, and a relative path depends on a working directory the registration does not set (for
  the sandbox apps the wrapper makes it the app folder). The skills use absolute paths.
- **Most saves and exports do not create a missing folder** (they fail with "No such file or directory"). The
  installer creates `in/` and `out/` for this reason. PdfCraft, LightCraft's `export`, SoundCraft's
  `save_session` and FilmCraft's `file.exportMedia` do create it.
- **Success can hide a failure**: WordCraft's `batch` with `keepGoing`, EffectCraft's bad expressions and CADCraft's
  refused `command_line` text all come back without `isError`. Read the result, then inspect, render and look.
- **Some commands discard unsaved work without asking** (`open_document` in WordCraft, `open_project` in EffectCraft,
  `new_session` in SoundCraft).
- **Not run during verification** (printing, scripts, plug-ins, passwords, downloads, deleting for good): they are
  listed under `Never` in each skill, with the reason, and several are on the MCP guard's ask list.

[Back to top](#the-13-apps)

## WordCraft 0.7.0 (Skill `craft-wordcraft`)

Documents in `.docx`; also saves `.pdf`, `.odt`, `.rtf`, `.html`, `.md`, `.tex`, `.txt`, `.png`. Registered with
`--author Claude` so tracked changes and comments are labeled.

- A save into a folder that does not exist fails; `save_document` without `path` on a never-saved document returns
  `saved: false` with no error, and on an opened file overwrites it.
- `open_document` replaces the open document and drops unsaved edits without asking.
- Colors must be `RRGGBB`, `#RRGGBB` or `auto`; arrays are rejected.
- `batch` with `keepGoing` returns `isError: false` even if a command failed.
- Not run: printing, sharing, macros, encryption and protection commands.

[Back to top](#the-13-apps)

## GridCraft 0.7.0 (`craft-gridcraft`)

Spreadsheets in `.xlsx`; saves `.csv`, `.tsv`, `.json`, `.html`; PDF through `file.exportPdf`. Opens more formats
(`.xls`, `.xlsb`, `.ods` per its schema; not tested).

- CSV and TSV save only the active sheet, as displayed text.
- `sort_range` and `filter` take column letters, not header names.
- `open_workbook` on a file that is already open returns the in-memory copy, not the disk.
- Formulas can be tested without changing the sheet (`evaluate_formula`); a bad formula is reported in the result,
  not as a tool error.
- Not run: printing, opening links, automation scripts, sheet protection, undo after deleting a sheet.

[Back to top](#the-13-apps)

## DeckCraft 0.7.0 (`craft-deckcraft`)

Presentations in `.pptx` or `.deckcraft`; exports PDF, PNG, JPEG, outline.

- `new_presentation` takes one of 8 themes (`design.themes`); an unknown theme name is accepted silently and the deck
  falls back to the default. Nine slide layouts.
- PNG export is one slide at scale 2 (1920x1080 for 16:9); `all: true` writes one file per slide.
- `go_to_slide` clamps an out-of-range index; `inspect_slide` errors.
- `call_app` (a raw desktop control call) bypasses the typed tools and is on the guard's ask list.
- Not run: discarding recovery files, charts other than column and pie.

[Back to top](#the-13-apps)

## PdfCraft 0.8.0 (`craft-pdfcraft`)

Existing PDFs: read, search, fill forms, comment, split, merge, mark up and truly redact. With 163 tools it has the
widest surface after LightCraft.

- Redaction: `redact_mark` only marks; `redact_apply` removes the text; after saving, the redacted phrase was gone
  in the reopened file (verified on an SSN pattern). `doc_audit_redactions` flagged the applied box as covered text
  in all four test PDFs where other words shared the line, so read its findings before calling a file clean.
- `doc_save` without `path` writes the opened file in place (it appends a revision); a `path` that exists is
  overwritten without asking. Opening the same file twice gives two document ids.
- **OCR is unavailable on the pinned version**: `ocr_status` reports `available: false` and `ocr_recognize` fails with
  "the text recognition models are not installed". Do not count on OCR.
- Not run: printing, following links, JavaScript, passwords, digital signatures, removing hidden information.

[Back to top](#the-13-apps)

## PhotoCraft 0.9.0 (`craft-photocraft`)

Raster editing with layers, masks, filters and adjustments: `.psd`, `.pcraft` (native), `.png`, `.jpg`, `.tif`,
`.webp`, `.exr`, `.gif`.

- PNG and JPEG saves flatten layers; the result lists a warning for what was dropped.
- Filters and pixel adjustments fail on Type layers. `command_batch` is not transactional and has a 256-step limit.
- File commands that use ambient paths (`file.open`, `file.save`, `file.saveAs`, `file.revealInFinder` ...) are
  refused; the typed tools (`doc_open`, `doc_save`, `doc_export` ...) are the way in. The check fires by command id
  or by a path-like parameter (`path`, `file`, `profile`), so `plugin.install` is refused only when given a `path`;
  its `data` form is not. Printing (`file.print*`, `file.printOneCopy`, `file.printers`) is refused.
- `doc_save` without `path` writes back in place for a PSD, PSB, `.pcraft` or `.ora` document.
- A job started with `wait: false` blocks edits to that document until it finishes or `jobs_cancel`.
- `ui_*` and `control_call` need the desktop app (bridge mode).

[Back to top](#the-13-apps)

## VectorCraft 0.11.0 (`craft-vectorcraft`)

Vector artwork: `.svg`, `.pdf`, `.png` and the native `.vectorcraft`. A fresh server starts with an untitled
612 x 792 artboard.

- PNG export is transparent by default; `options: {background: "white"}` gives an opaque PNG. `scale` is pixels
  per point.
- `export` without `path` returns the data and writes nothing; `save_file` without `path` overwrites the opened file.
- `artboard` is 0-based, `range` is 1-based; a PDF has one page per artboard.
- `add_text` can report `overflow: true`, and `fit: "shrinkText"` still overflowed in a test.
- 749 command ids sit behind `command_run`; `file.print` is enabled and was not run.

[Back to top](#the-13-apps)

## DesignCraft 0.8.0 (`craft-designcraft`)

Print layout in `.designcraft`; exports `.png`, `.jpg`, and PDF.

- PDF is not its own MCP tool: `execute` `file.exportPdf` with a `path` writes one.
- Pages are zero-based; `render_page` is 1x and `export_png` 2x by default.
- `place_image` without `frame` reuses the selected empty frame, so a second call can return the first id.
- `save_document` without `path` overwrites an opened file; on a new document it fails.
- Picture formats: PNG, JPEG, WebP, GIF, TIFF. Not run: printing, packaging, scripts, relinking.

[Back to top](#the-13-apps)

## CADCraft 0.7.0 (`craft-cadcraft`)

2D drafting; opens and saves `.dxf` and `.dwg` (a DWG round trip was verified), exports `.svg`, `.png`, `.pdf`.

- `command_line` takes AutoCAD syntax; a refused line returns an `error` field and no `isError`. A command that
  waits for input takes the next `command_line` text as its answer.
- `execute` silently ignores unknown parameter keys; check with `inspect_drawing`.
- `save` and `render` do not create folders; `save` without `path` overwrites the drawing's own file.
- Plot, publish, LISP, `wblock`, `purge` and `overkill` were not run; the MCP guard does not ask about `PLOT` typed
  into `command_line`.

[Back to top](#the-13-apps)

## FigCraft 0.6.0 (`craft-figcraft`)

Interface design with frames, auto layout, components and prototyping, in the native `.figcraft` format (a zip with
`document.json` and a thumbnail); exports PNG, SVG, PDF. **Not for Figma files.**

- An unknown key in `props` or `set_properties` fails the call and changes nothing.
- `save_file` with a `path` is a save-as and leaves the opened file alone; without `path` it overwrites it.
- `screenshot` works headless. `key` runs menu shortcuts and can have unexpected effects; use `run_command`.
- Plugin, widget and network (`collab.*`, library publishing) commands are on the Never list.

[Back to top](#the-13-apps)

## FilmCraft 0.8.0 (`craft-filmcraft`)

Timeline video editing: import, place, razor, trim, effects, markers, export. Projects are `.fcproj` and live in
memory until saved.

- PNG and H.264 `.mp4` render real frames. A clip with the `mpeg4` video codec imports but renders as "MEDIA
  UNREADABLE" and is listed in `offlineMedia` on export.
- The track name `V1` works; `"Video 1"`, the name `sequence_inspect` shows, is rejected. `timeline.razor` on `V1`
  cuts only the video and the linked audio stays whole; `timeline.trim` on a video clip also trims its linked audio.
- `file.saveAs` overwrites an existing path and fails if the folder is missing; `file.exportMedia` created a
  missing folder (tested with WAV).
- H.264, ProRes and WAV exports ran; `hevc` fails with "no encoder registered"; other formats were not run.
  `ui_*` tools need the live window.

[Back to top](#the-13-apps)

## EffectCraft 0.10.0 (`craft-effectcraft`)

Motion graphics in `.ecproj`: compositions, text and solid layers, keyframes, effects; renders PNG frames. Only the
headless CPU renderer was used.

- A bad expression is stored without an error (`expressionError` is set, `isError` stays false).
- New layers go on top, so layer and effect indexes shift; use ids or re-read `get_layer`.
- `open_project` and `file.closeProject` drop unsaved edits silently. `save_project` without `path` overwrites the
  project's own file. Saves and `render_frame` fail when their folder does not exist.
- Script commands (`run_script`, `script.run`, `file.runScript`, `script_ui`) are refused under the fence.
- Only PNG footage was imported; other formats are untested. `file.import` of a missing file reports it in `errors`
  and leaves `isError` false. `footage.relink` also relinks the other missing files it finds in the same place.

[Back to top](#the-13-apps)

## LightCraft 0.8.0 (`craft-lightcraft`)

Raw and JPEG photo library and developer: import, query, develop, crop, rate, export to `.jpg`, `.png`, `.tif`,
`.webp`. It uses the GPU (Metal) when it can: the smoke test checks that GPU setup works, and on the test machine
`app.gpu` reported "Apple M1 (Metal)".

- The library is in memory: every server start begins empty, so photo ids from earlier sessions are gone.
- `import` in the default mode references files in place; mode `move` removes the source and is on the ask list.
- Export overwrites an existing path, defaults to a 3,000 px long edge and never enlarges; `longEdge: 0` gives the full
  cropped size.
- `crop` takes normalized 0..1 values; pixel values are accepted and stored wrongly.
- The MCP server cannot create an image, so the smoke test checks GPU setup and a keyword round trip rather than a
  render. Raw decoding was not tested (no raw sample).

[Back to top](#the-13-apps)

## SoundCraft 0.7.0 (`craft-soundcraft`)

A digital audio workstation: import audio, edit, mix, bounce, save `.scraft` sessions.

- Imports WAV, AIFF, FLAC, MP3, M4A, CAF and Ogg Vorbis; Ogg Opus fails with "unsupported codec".
- `bounce_mix` does not create folders; the default output is 24-bit, and `bit_depth` is not validated.
- `transport.play` and `transport.record` return `{}` and nothing plays or records.
- `new_session` and `session.revert` discard unsaved edits without asking; a session that was not already saved
  at a path needs `replace: true` to save onto an existing file there. Re-saving a changed session file adds a
  numbered copy in `Backups/` beside it.
- Window-only: `screenshot`, `ui_inspect`, `ui_set`, `menu_invoke`, `click`, `drag`, `key` (they fail with "needs the
  desktop app"). The sandbox refuses reads under the home folder only; system paths stay readable.

[Back to top](#the-13-apps)

## Where These Facts Come From

Each list above is a digest of that app's skill: statements marked "verified" there were produced by driving the
real server with `lib/mcp_probe.py` in a scratch folder at the version shown; statements about things that were
not run say "not run" or "(not verified on vX.Y.Z)". Newer releases of an app can change any of it; the lock pins
the versions these facts were checked on. How the checks were done and what is still open:
[VERIFICATION.md](VERIFICATION.md).

[Back to top](#the-13-apps)
