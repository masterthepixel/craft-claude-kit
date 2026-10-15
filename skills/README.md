# Skills

14 Claude Code skills: `craft-apps` (routing, rules, handoffs) and `craft-<app>` for each of the 13 apps.
These are sources. `install.sh` renders them into `$CLAUDE_CONFIG_DIR/skills/` (default `~/.claude/skills/`).
Edit them here, not in the installed copy; re-run `install.sh` to refresh.

## Tokens
Sources never contain a literal personal path. Two tokens are allowed, and nothing else in `{{...}}`:

| Token | Becomes |
|---|---|
| `{{WORKSPACE}}` | Absolute workspace folder (`--workspace`, default `~/craft-workspace`) |
| `{{KIT_HOME}}` | Absolute kit runtime copy (default `~/.local/share/craft-claude-kit`) |

`python3 lib/craftkit.py render` replaces them and fails if any `{{...}}` is left. Installed copies are
backed up to `SKILL.md.bak-<timestamp>` before they are overwritten; `doctor.sh` warns when an installed
copy differs from its rendered source.

## Description Rules
The description decides when Claude loads the skill. It must:
- Start with `Use when`, stay within 300 characters and be one line;
- Name the app and the file types or tasks (`.docx`, "redact", "color grade");
- Where another tool overlaps, say when NOT to use this one (plain code-generated .docx/.xlsx/.pptx/.pdf
  go to the anthropic-skills docx/xlsx/pptx/pdf skills; Figma files to the figma skills);
- Avoid `: ` and ` #` unquoted (invalid YAML).

## Body Rules
Body under 3800 bytes. Per-app sections, in order: `Load first` (one `ToolSearch select:` line, 6 to 10 full
tool names), `Workflow` (4 to 7 numbered steps, ending with a save to an absolute `path` under `out/`),
`Gotchas` (facts the server's own instructions do not state; unverified ones end `(not verified on vX.Y.Z)`),
`Files`, `Never`. The master skill has routing, the app table with fences, rules, intake/output convention,
a handoff table and `If a server is missing`.

## Lint
`python3 tools/lint_skills.py [--strict] [-q] [PATH ...]` (also run by `make lint` and `make test`).
- Errors fail the build: frontmatter, size, tokens, personal paths, section order, tool count, a tool that
  does not exist in `data/tools/<app>.json`.
- Warnings are advice (unverified identifiers, missing `out/` convention); `--strict` fails on them too.
- `data/tools/<app>.json` is the tool snapshot from `lib/mcp_probe.py snapshot`; refresh it after every app
  update, then re-run the lint to see which skill text drifted.
