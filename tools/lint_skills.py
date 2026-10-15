#!/usr/bin/env python3
"""Lint the kit's Claude Code skills against the skills contract.

    python3 tools/lint_skills.py [--data-dir DIR] [--strict] [-q] [PATH ...]

PATH is a SKILL.md file or a directory searched recursively for SKILL.md
(default: the repo's skills/ directory). Exit 0 when there are no errors,
1 when there are errors (or warnings with --strict), 2 on usage errors.

What is checked (errors unless marked warning):
  frontmatter  name is craft-apps or craft-<app> and equals the directory name;
               description starts "Use when", is <= 300 chars, names the app
               (per-app skills); plain values that YAML would misread are rejected.
  body         <= 3800 bytes; only the {{WORKSPACE}} and {{KIT_HOME}} tokens;
               no literal /Users/ or ~/ paths.
  structure    per-app skills: sections "Load first", "Workflow", "Gotchas",
               "Files", "Never" as level-2 headings in that order; exactly one
               `ToolSearch select:` line naming 6-10 tools of the same app;
               4-7 numbered workflow steps; {{WORKSPACE}}/<app> used.
               craft-apps: all 13 apps, {{WORKSPACE}}, {{KIT_HOME}}/doctor.sh and an
               "If a server is missing" section.
  tools        every mcp__<app>__<tool> must exist in data/tools/<app>.json when
               that snapshot exists (error); without a snapshot it is a warning.
  gotchas      every Gotchas bullet says "verified" (or "(not verified on vX.Y.Z)"),
               unless the section has a line saying what it was checked on ("... on vX.Y.Z").
  guard        (skills under this repo's skills/ only) every dotted command id named in
               a Never section must make hooks/craft-mcp-guard.py ask, or be listed in
               hooks/risky-tools.json "never_reviewed" with the reason it is not guarded.
  warnings     backticked snake_case identifiers unknown to the snapshot, missing
               out/ convention, malformed "(not verified ...)".
  denylist     env CRAFT_KIT_EXTRA_DENYLIST (a file of fixed strings, one per line, kept
               outside the repo) makes any line containing an entry an error.

Stdlib only, Python 3.9+.
"""
import argparse
import json
import os
import re
import sys

APPS = [
    "wordcraft", "gridcraft", "deckcraft", "pdfcraft", "photocraft", "vectorcraft",
    "designcraft", "cadcraft", "figcraft", "filmcraft", "effectcraft", "lightcraft",
    "soundcraft",
]
OVERLAP_APPS = {
    "wordcraft", "gridcraft", "deckcraft", "pdfcraft", "figcraft", "photocraft",
    "lightcraft", "filmcraft",
}
MASTER = "craft-apps"
MAX_DESC = 300
MAX_BODY_BYTES = 3800
ALLOWED_TOKENS = ("{{WORKSPACE}}", "{{KIT_HOME}}")
SECTIONS = ["Load first", "Workflow", "Gotchas", "Files", "Never"]
KNOWN_FM_KEYS = {"name", "description"}
MIN_TOOLS, MAX_TOOLS = 6, 10

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP_REF = re.compile(r"mcp__([a-z]+)__([A-Za-z][A-Za-z0-9_]*)")
SNAKE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
NUMBERED = re.compile(r"^\s*\d+[.)]\s+\S")
FM_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*)|[ \t]*)$")
TOKEN_ANY = re.compile(r"\{\{[^{}\n]*\}\}")
NOT_VERIFIED_OK = re.compile(r"\(not verified on v\d+\.\d+\.\d+\)")
GOTCHAS_HEADER = re.compile(r"\bon v\d+\.\d+\.\d+\b", re.IGNORECASE)
COMMAND_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_*|]+)+$")
GUARD = {}


_DENY = []


def denylist():
    """Lower-cased entries of the optional private denylist (env CRAFT_KIT_EXTRA_DENYLIST); never echoed."""
    if not _DENY:
        path = os.environ.get("CRAFT_KIT_EXTRA_DENYLIST", "")
        if path:
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            _DENY.append(line.lower())
            except OSError:
                print("lint_skills: cannot read CRAFT_KIT_EXTRA_DENYLIST", file=sys.stderr)
                sys.exit(2)
        _DENY.append("")  # sentinel: loaded
    return [t for t in _DENY if t]


class Results:
    def __init__(self):
        self.items = []  # (path, line, level, message)

    def add(self, path, line, level, msg):
        self.items.append((path, line, level, msg))

    def count(self, level):
        return sum(1 for it in self.items if it[2] == level)


class Snapshots:
    """Lazy loader for data/tools/<app>.json (output of mcp_probe.py snapshot)."""

    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.cache = {}

    def get(self, app):
        """Return (tool_names, param_names) or None when absent; raises ValueError if unreadable."""
        if app in self.cache:
            val = self.cache[app]
            if isinstance(val, ValueError):
                raise val
            return val
        path = os.path.join(self.data_dir, app + ".json")
        if not os.path.isfile(path):
            self.cache[app] = None
            return None
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            err = ValueError("cannot read snapshot %s: %s" % (path, exc))
            self.cache[app] = err
            raise err
        tools = data.get("tools") if isinstance(data, dict) else data
        names, params = set(), set()
        for tool in tools or []:
            if isinstance(tool, str):
                names.add(tool)
            elif isinstance(tool, dict) and isinstance(tool.get("name"), str):
                names.add(tool["name"])
                for key in ("params", "required"):
                    for p in tool.get(key) or []:
                        if isinstance(p, str):
                            params.add(p)
                        elif isinstance(p, dict) and isinstance(p.get("name"), str):
                            params.add(p["name"])
                props = (tool.get("inputSchema") or {}).get("properties") or {}
                params.update(k for k in props if isinstance(k, str))
        self.cache[app] = (names, params)
        return self.cache[app]

    def union(self):
        names, params = set(), set()
        for app in APPS:
            try:
                got = self.get(app)
            except ValueError:
                got = None
            if got:
                names |= got[0]
                params |= got[1]
        return names, params


def parse_frontmatter(lines, res, path):
    """lines: file lines (no newline). Returns (fields, key_lines, body_start_index) or None."""
    if not lines or lines[0].strip() != "---":
        res.add(path, 1, "error", "file must start with a '---' frontmatter block")
        return None
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        res.add(path, 1, "error", "frontmatter is not closed by a second '---' line")
        return None
    fields, key_lines = {}, {}
    i = 1
    while i < end:
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        m = FM_LINE.match(raw)
        if not m:
            res.add(path, i + 1, "error", "cannot parse frontmatter line (expected 'key: value')")
            i += 1
            continue
        key, val = m.group(1), (m.group(2) or "").rstrip()
        start = i
        i += 1
        folded = val in (">", ">-", ">+")
        literal = val in ("|", "|-", "|+")
        cont = []
        while i < end and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
            if lines[i].strip():
                cont.append(lines[i].strip())
            i += 1
        if folded or literal:
            value = (" " if folded else "\n").join(cont)
        elif val[:1] in ("'", '"'):
            q = val[0]
            joined = " ".join([val] + cont)
            if len(joined) < 2 or joined[-1] != q:
                res.add(path, start + 1, "error", "unterminated quoted value for '%s'" % key)
                value = joined.strip(q)
            else:
                value = joined[1:-1]
                if q == '"':
                    value = value.replace('\\"', '"').replace("\\\\", "\\")
                else:
                    value = value.replace("''", "'")
        else:
            parts = [val] + cont
            for part in parts:
                if ": " in part or part.endswith(":"):
                    res.add(path, start + 1, "error",
                            "unquoted '%s' contains ': ' (invalid YAML); quote the value or rephrase" % key)
                    break
                if " #" in part:
                    res.add(path, start + 1, "error",
                            "unquoted '%s' contains ' #' (YAML would cut it as a comment); quote it" % key)
                    break
            if val and val[0] in "[]{}*&!|>%@`":
                res.add(path, start + 1, "error",
                        "unquoted '%s' starts with a YAML indicator character; quote it" % key)
            value = " ".join(p for p in parts if p)
        if key in fields:
            res.add(path, start + 1, "error", "duplicate frontmatter key '%s'" % key)
        fields[key] = value
        key_lines[key] = start + 1
    return fields, key_lines, end + 1


def find_headings(lines, first_index):
    """Level/text/line for markdown headings after first_index, skipping fenced code."""
    out = []
    fence = False
    for idx in range(first_index, len(lines)):
        line = lines[idx]
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        m = HEADING.match(line)
        if m:
            out.append((len(m.group(1)), m.group(2).strip(), idx + 1))
    return out


def section_lines(lines, headings, pos):
    """Lines (index, text) belonging to headings[pos] up to the next heading of level <= its own."""
    level, _, lineno = headings[pos]
    stop = len(lines)
    for lv, _t, ln in headings[pos + 1:]:
        if lv <= level:
            stop = ln - 1
            break
    return [(i, lines[i]) for i in range(lineno, stop)]


def norm_heading(text):
    return text.strip().rstrip(":").strip().lower()


def check_sections(lines, body_start, app, res, path, headings):
    positions = {}
    for want in SECTIONS:
        found = None
        for pos, (lv, text, ln) in enumerate(headings):
            if norm_heading(text).startswith(want.lower()):
                found = (pos, lv, ln)
                break
        if found is None:
            res.add(path, body_start + 1, "error", "missing section '## %s'" % want)
            continue
        if found[1] != 2:
            res.add(path, found[2], "error", "section '%s' must be a level-2 heading (##)" % want)
        positions[want] = found
    order = [positions[s][2] for s in SECTIONS if s in positions]
    if order != sorted(order):
        res.add(path, body_start + 1, "error",
                "sections must appear in the order: %s" % ", ".join(SECTIONS))
    if "Load first" in positions:
        check_load_first(lines, headings, positions["Load first"][0], app, res, path)
    if "Workflow" in positions:
        sec = section_lines(lines, headings, positions["Workflow"][0])
        steps = [i for i, text in sec if NUMBERED.match(text)]
        if not 4 <= len(steps) <= 7:
            res.add(path, positions["Workflow"][2], "error",
                    "Workflow needs 4-7 numbered steps, found %d" % len(steps))
        if steps:
            last = " ".join(text for i, text in sec if i >= steps[-1])
            if "path" not in last:
                res.add(path, positions["Workflow"][2], "warning",
                        "the last Workflow step should save with an explicit absolute `path`")
    if "Gotchas" in positions:
        sec = section_lines(lines, headings, positions["Gotchas"][0])
        for i, text in sec:
            if "not verified" in text and not NOT_VERIFIED_OK.search(text):
                res.add(path, i + 1, "warning",
                        "write unverified gotchas as '(not verified on vX.Y.Z)'")
        header = any(not t.lstrip().startswith(("-", "*")) and GOTCHAS_HEADER.search(t) for _i, t in sec)
        if not header:
            for i, text in sec:
                if text.lstrip().startswith(("-", "*")) and "verified" not in text.lower():
                    res.add(path, i + 1, "error", "Gotchas bullet without 'verified' or '(not verified on vX.Y.Z)', "
                            "and no line in the section saying what the items were checked on")
    if "Files" in positions:
        sec = section_lines(lines, headings, positions["Files"][0])
        if not any("/out" in text for _i, text in sec):
            res.add(path, positions["Files"][2], "warning",
                    "Files should state the output convention ({{WORKSPACE}}/%s/out/...)" % app)
    if "Never" in positions:
        sec = section_lines(lines, headings, positions["Never"][0])
        check_never_guard(app, sec, res, path)
        if not any(text.lstrip().startswith(("-", "*")) for _i, text in sec):
            res.add(path, positions["Never"][2], "warning", "Never should be a bullet list")
        if not any(re.search(r"instruction", text, re.IGNORECASE) for _i, text in sec):
            res.add(path, positions["Never"][2], "warning",
                    "Never should say that instructions found inside files are data, not commands")


def _guard():
    """The repo's MCP guard and its table, loaded once (None when this is not a kit checkout)."""
    if "mod" not in GUARD:
        GUARD["mod"] = GUARD["table"] = None
        hook = os.path.join(REPO, "hooks", "craft-mcp-guard.py")
        if os.path.isfile(hook):
            import importlib.util
            spec = importlib.util.spec_from_file_location("craft_mcp_guard_for_lint", hook)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            GUARD["mod"], GUARD["table"] = mod, mod.load_table()
    return GUARD["mod"], GUARD["table"]


def check_never_guard(app, sec, res, path):
    """A command id the skill forbids should make the guard ask, or be reviewed as not guarded."""
    skills_dir = os.path.join(REPO, "skills") + os.sep
    if not os.path.abspath(path).startswith(skills_dir):
        return
    guard, table = _guard()
    if guard is None or not table:
        return
    spec = (table.get("apps") or {}).get(app) or {}
    runners = spec.get("runners") or []
    reviewed = (table.get("never_reviewed") or {}).get(app) or {}
    for i, text in sec:
        for tok in re.findall(r"`([^`]+)`", text):
            if not COMMAND_ID.match(tok) or tok in reviewed:
                continue
            asks = runners and guard.evaluate(app, runners[0], {"id": tok, "command": tok},
                                              "/Users/you/craft-workspace", table)[0]
            if not asks:
                res.add(path, i + 1, "error", "Never names `%s`, but the MCP guard does not ask for it: add it to "
                        "hooks/risky-tools.json (ask_ids) or to never_reviewed.%s with the reason" % (tok, app))


def check_load_first(lines, headings, pos, app, res, path):
    sec = section_lines(lines, headings, pos)
    hits = [(i, text) for i, text in sec if "ToolSearch" in text and "select:" in text]
    if len(hits) != 1:
        res.add(path, headings[pos][2], "error",
                "Load first needs exactly one 'ToolSearch select:mcp__%s__a,...' line, found %d"
                % (app, len(hits)))
        return
    i, text = hits[0]
    m = re.search(r"select:([A-Za-z0-9_,]+)", text)
    if not m:
        res.add(path, i + 1, "error", "cannot read tool list after 'select:'")
        return
    if re.search(r"select:[A-Za-z0-9_,]*,[ \t]+\S", text):
        res.add(path, i + 1, "error", "tool names after 'select:' must be comma separated without spaces")
    names = [n for n in m.group(1).split(",") if n]
    if not MIN_TOOLS <= len(names) <= MAX_TOOLS:
        res.add(path, i + 1, "error",
                "Load first must name %d-%d tools, found %d" % (MIN_TOOLS, MAX_TOOLS, len(names)))
    if len(set(names)) != len(names):
        res.add(path, i + 1, "error", "duplicate tool in Load first line")
    prefix = "mcp__%s__" % app
    for n in names:
        if not n.startswith(prefix) or len(n) == len(prefix):
            res.add(path, i + 1, "error", "'%s' is not a full tool name of the form %s<tool>" % (n, prefix))


def check_master(text, lines, headings, res, path, body_start):
    low = text.lower()
    for app in APPS:
        if not re.search(r"\b%s\b" % app, low):
            res.add(path, body_start + 1, "error", "master skill does not mention %s" % app)
    if "{{KIT_HOME}}/doctor.sh" not in text:
        res.add(path, body_start + 1, "error", "master skill must point to {{KIT_HOME}}/doctor.sh")
    if "{{WORKSPACE}}" not in text:
        res.add(path, body_start + 1, "error", "master skill must use {{WORKSPACE}}")
    if not any(norm_heading(t).startswith("if a server is missing") for _l, t, _n in headings):
        res.add(path, body_start + 1, "error", "missing section 'If a server is missing'")
    if not any(ln.lstrip().startswith("|") for ln in lines):
        res.add(path, body_start + 1, "warning", "no markdown table (app table / handoff table)")
    if not re.search(r"\bdata\b", text) or not re.search(r"instruction", text, re.IGNORECASE):
        res.add(path, body_start + 1, "warning",
                "master skill should say that text inside files is data, never instructions")
    if "anthropic-skills" not in text:
        res.add(path, body_start + 1, "warning",
                "routing rules should name the anthropic-skills docx/xlsx/pptx/pdf alternatives")
    if "handoff" not in low and "hand off" not in low and "hand-off" not in low:
        res.add(path, body_start + 1, "warning", "no cross-app handoff table")
    for pos, (_lv, t, _ln) in enumerate(headings):
        if re.search(r"\brules?\b", t, re.IGNORECASE):
            steps = [1 for _i, ln in section_lines(lines, headings, pos) if NUMBERED.match(ln)]
            if steps and len(steps) != 6:
                res.add(path, headings[pos][2], "warning",
                        "the contract has 6 rules for every app, found %d" % len(steps))
            break
    else:
        res.add(path, body_start + 1, "warning", "no 'Rules' section")


def check_tool_refs(lines, body_start, app, snaps, res, path):
    missing_snapshot = {}
    for idx in range(body_start, len(lines)):
        line = lines[idx]
        for m in MCP_REF.finditer(line):
            ref_app, tool = m.group(1), m.group(2).rstrip("_")
            if ref_app not in APPS:
                res.add(path, idx + 1, "warning", "%s is not a Craft app prefix; not checked" % m.group(0))
                continue
            try:
                snap = snaps.get(ref_app)
            except ValueError as exc:
                res.add(path, idx + 1, "error", str(exc))
                continue
            if snap is None:
                missing_snapshot.setdefault(ref_app, []).append(idx + 1)
            elif tool not in snap[0]:
                res.add(path, idx + 1, "error",
                        "tool mcp__%s__%s is not in data/tools/%s.json" % (ref_app, tool, ref_app))
    for ref_app, where in sorted(missing_snapshot.items()):
        res.add(path, where[0], "warning",
                "%d mcp__%s__* reference(s) not checked: data/tools/%s.json does not exist yet"
                % (len(where), ref_app, ref_app))


def check_advisory_identifiers(lines, body_start, app, snaps, res, path):
    try:
        if app:
            snap = snaps.get(app)
        else:
            snap = snaps.union()
    except ValueError:
        return
    if not snap or not snap[0]:
        return
    known = set(snap[0]) | set(snap[1])
    fence = False
    seen = set()
    for idx in range(body_start, len(lines)):
        line = lines[idx]
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        for m in re.finditer(r"`([^`\n]+)`", line):
            ident = m.group(1).strip()
            if ident.startswith("mcp__") or not SNAKE.match(ident):
                continue
            if ident in known or ident in seen:
                continue
            seen.add(ident)
            res.add(path, idx + 1, "warning",
                    "`%s` looks like a tool or parameter but is not in the %s snapshot"
                    % (ident, app or "any"))


def lint_file(path, snaps, res):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        res.add(path, 1, "error", "cannot read file as UTF-8: %s" % exc)
        return
    if "\r\n" in text:
        res.add(path, 1, "warning", "CRLF line endings; use LF")
        text = text.replace("\r\n", "\n")
    lines = text.split("\n")
    parsed = parse_frontmatter(lines, res, path)
    if parsed is None:
        return
    fields, key_lines, body_start = parsed

    for key in fields:
        if key not in KNOWN_FM_KEYS:
            res.add(path, key_lines[key], "warning", "frontmatter key '%s' is not part of the kit contract" % key)

    dirname = os.path.basename(os.path.dirname(os.path.abspath(path)))
    name = fields.get("name", "")
    app = None
    if not name:
        res.add(path, 1, "error", "frontmatter is missing 'name'")
    elif name == MASTER:
        pass
    elif name.startswith("craft-") and name[len("craft-"):] in APPS:
        app = name[len("craft-"):]
    else:
        res.add(path, key_lines.get("name", 1), "error",
                "name '%s' must be %s or craft-<app> (one of the 13 apps)" % (name, MASTER))
    if name and dirname != name:
        res.add(path, key_lines.get("name", 1), "error",
                "directory name '%s' does not match skill name '%s'" % (dirname, name))

    desc = fields.get("description", "")
    dline = key_lines.get("description", 1)
    if not desc:
        res.add(path, 1, "error", "frontmatter is missing 'description'")
    else:
        if "\n" in desc:
            res.add(path, dline, "error", "description must be a single paragraph, not a literal block")
        if not desc.startswith("Use when"):
            res.add(path, dline, "error", "description must start with 'Use when'")
        if len(desc) > MAX_DESC:
            res.add(path, dline, "error", "description is %d chars (max %d)" % (len(desc), MAX_DESC))
        if app:
            if app not in desc.lower():
                res.add(path, dline, "error", "description must name the app (%s)" % app)
            if not re.search(r"\.[A-Za-z0-9]{2,5}\b", desc):
                res.add(path, dline, "warning", "description should name file types (e.g. .docx) or tasks")
            if app in OVERLAP_APPS and not re.search(r"\b(not|instead|except|skip)\b", desc, re.IGNORECASE):
                res.add(path, dline, "warning",
                        "description should say when NOT to use %s (overlap with other tools/skills)" % app)

    body = "\n".join(lines[body_start:])
    size = len(body.encode("utf-8"))
    if size > MAX_BODY_BYTES:
        res.add(path, body_start + 1, "error", "body is %d bytes (max %d)" % (size, MAX_BODY_BYTES))

    full = "\n".join(lines)
    for idx, line in enumerate(lines):
        for m in TOKEN_ANY.finditer(line):
            if m.group(0) not in ALLOWED_TOKENS:
                res.add(path, idx + 1, "error",
                        "unknown token %s (only {{WORKSPACE}} and {{KIT_HOME}} are rendered)" % m.group(0))
        stripped = TOKEN_ANY.sub("", line)
        if "{{" in stripped or "}}" in stripped:
            res.add(path, idx + 1, "error", "unbalanced '{{' or '}}'")
        if "/Users/" in line or re.search(r"(^|[\s`'\"(=:])~/", line):
            res.add(path, idx + 1, "error",
                    "literal personal path (/Users/... or ~/...); use {{WORKSPACE}} / {{KIT_HOME}}")
        if re.search(r"/home/[A-Za-z0-9._-]+", line):
            res.add(path, idx + 1, "warning", "literal /home/<name> path")
        low = line.lower()
        for n, term in enumerate(denylist(), 1):
            if term in low:
                res.add(path, idx + 1, "error", "line contains entry #%d of CRAFT_KIT_EXTRA_DENYLIST" % n)

    headings = find_headings(lines, body_start)
    if app:
        check_sections(lines, body_start, app, res, path, headings)
        if "{{WORKSPACE}}/%s" % app not in full:
            res.add(path, body_start + 1, "error", "skill never uses {{WORKSPACE}}/%s" % app)
        elif "{{WORKSPACE}}/%s/out" % app not in full:
            res.add(path, body_start + 1, "warning",
                    "no {{WORKSPACE}}/%s/out/ output location mentioned" % app)
    elif name == MASTER:
        check_master(full, lines, headings, res, path, body_start)

    check_tool_refs(lines, body_start, app, snaps, res, path)
    if app or name == MASTER:
        check_advisory_identifiers(lines, body_start, app, snaps, res, path)


def collect(paths, res):
    files = []
    for p in paths:
        if os.path.isdir(p):
            found = []
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d != ".git")
                if "SKILL.md" in names:
                    found.append(os.path.join(root, "SKILL.md"))
            if not found:
                res.add(p, 0, "error", "no SKILL.md found under this directory")
            files.extend(sorted(found))
        elif os.path.isfile(p):
            files.append(p)
        else:
            res.add(p, 0, "error", "no such file or directory")
    return files


def display(path):
    try:
        rel = os.path.relpath(path)
    except ValueError:
        return path
    return rel if not rel.startswith("..") else path


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(description="Lint craft-claude-kit skills (see module docstring).")
    ap.add_argument("paths", nargs="*", help="SKILL.md files or directories (default: <repo>/skills)")
    ap.add_argument("--data-dir", default=os.path.join(repo, "data", "tools"),
                    help="directory with <app>.json tool snapshots (default: <repo>/data/tools)")
    ap.add_argument("--strict", action="store_true", help="treat warnings as errors")
    ap.add_argument("-q", "--quiet", action="store_true", help="print errors only")
    args = ap.parse_args(argv)

    paths = args.paths or [os.path.join(repo, "skills")]
    res = Results()
    snaps = Snapshots(args.data_dir)
    files = collect(paths, res)
    for f in files:
        lint_file(f, snaps, res)

    for path, line, level, msg in sorted(res.items, key=lambda it: (it[0], it[1], it[2] != "error")):
        if level == "warning" and args.quiet:
            continue
        where = display(path) + (":%d" % line if line else "")
        print("%s: %s: %s" % (where, level, msg))
    errors, warnings = res.count("error"), res.count("warning")
    print("lint_skills: %d file(s), %d error(s), %d warning(s)" % (len(files), errors, warnings))
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
