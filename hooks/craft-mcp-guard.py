#!/usr/bin/env python3
"""craft-mcp-guard: Claude Code PreToolUse hook for the Craft MCP servers (mcp__<app>__<tool>).

Each Craft app is registered as an MCP server fenced to its own workspace folder. The fence stops file
access outside the folder, but some calls are still worth a human look first. This hook ASKS (it never
denies) before a call that

  * has a side effect outside the document: printing, permanent delete, empty trash, following a link,
    adding to Apple Photos, model or data-set downloads, running script code, setting or removing document
    passwords, signing (the per-tool table is hooks/risky-tools.json);
  * saves without an explicit `path` (a save-style tool such as doc_save, save_file, save_workbook,
    save_document, save_presentation, save_project, save_session or an export), which overwrites the opened
    file in place or lets the app pick the location;
  * asks for an import with mode "move", or for conflict "overwrite";
  * saves or exports to a relative or placeholder path ($1.path), to a file that already exists, or into
    <app>/in/ (the input copies);
  * asks for an import with mode "move", or for conflict "overwrite";
  * passes any string argument that looks like a path (starts with /, ~, ./, ../ or file://, or has a ".."
    segment) and does not resolve to somewhere under <workspace>/<that app>. The path is normalised
    lexically first (so ".." cannot climb out), then real paths are compared, so an alias of the
    workspace path is accepted and a symlink inside the folder that leads outside is noticed. For the
    apps whose server does not run in its app folder, a relative path under a path key also asks;
  * has arguments too large or too deep to check in full (it asks rather than staying silent).

Script text is read too: each line (or ';' segment) of a runner's `script`/`steps`/`commands` string is
taken as "<command id> {json args}", and for CADCraft every word typed into `command_line`/`script` is
compared with its list of printing, file and LISP commands (a word-list heuristic, not a parser).

It fails open on errors: a malformed payload, a missing or broken table, or any internal error exits 0
with no output, so it can never block a call by accident. It is a heuristic, not a security boundary:
only the listed tools, command ids and argument names are examined, and free-text arguments (text,
title ...) of other tools are not treated as paths.

Usage (set up by the installer): craft-mcp-guard.py --workspace /path/to/craft-workspace
Input: Claude Code hook JSON on stdin. Output: nothing, or one "ask" decision as JSON on stdout.
Python 3.9, standard library only.
"""
import json
import os
import re
import sys
import urllib.parse

APPS = ("wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft "
        "filmcraft effectcraft lightcraft soundcraft").split()
TOOL_RE = re.compile(r"^mcp__(%s)__(.+)$" % "|".join(APPS))
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*://")
TILDE_USER_RE = re.compile(r"^~[\w.\-]+(/|$)")

DEFAULT_CONTENT_KEYS = frozenset(["text", "texts", "title", "body", "caption", "contents", "content", "label",
                                  "description", "alt", "comment", "note", "message", "query", "find",
                                  "replace", "pattern", "words", "expression", "script", "code", "csv", "d",
                                  "formula", "input", "value", "values", "data", "base64", "template",
                                  "name", "author", "reason", "filter", "search"])
MAX_NODES = 20000
MAX_DEPTH = 20
MAX_REASONS = 6
MAX_PATH_REASONS = 3
MAX_PATH_CHECKS = 500
TOO_BIG = "the arguments are too large or too deep to check in full"
PATH_KEYS = frozenset(["path", "paths", "dir", "file", "files", "folder", "out", "output", "dest", "destination"])
# Servers that resolve a relative path inside their own app folder: the sandboxed ones (craft-sandbox
# starts them in <workspace>/<app>) and the two whose roots make paths root-relative. Overridable in
# the table (global.relative_to_app_folder).
DEFAULT_RELATIVE_OK = frozenset("filmcraft lightcraft designcraft cadcraft deckcraft figcraft gridcraft "
                                "soundcraft pdfcraft photocraft".split())
SCRIPT_KEYS = frozenset(["script", "steps", "commands"])
# A bare relative name counts as a file path only with a file extension ("report.docx", "in/a.png"),
# so property paths such as EffectCraft's "transform/position" stay quiet.
FILE_EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
WRITE_NAME_RE = re.compile(r"save|export|bounce|render|publish|wblock")
OUT_KEYS = frozenset(["out_dir", "outdir", "output_dir", "out", "output", "dest", "destination", "folder"])
ENTRY_RE = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_.\-]*)\s*(.*?)\s*$", re.S)


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def norm_tool(name):
    low = name.lower()
    if low.startswith("cmd_"):
        low = low[4:]
    return norm(low)


def load_table():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "risky-tools.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def collect_nodes(args):
    """([(key, value)] for every node under the tool arguments, truncated). List items inherit their
    list's key. Nodes are visited in document order; past MAX_NODES or MAX_DEPTH the walk stops and
    truncated is True, so the caller can ask instead of judging a partial view."""
    out = []
    truncated = False
    stack = [(None, args, 0)]
    while stack:
        key, val, depth = stack.pop()
        if len(out) >= MAX_NODES or depth > MAX_DEPTH:
            truncated = True
            if len(out) >= MAX_NODES:
                break
            continue
        out.append((key, val))
        if isinstance(val, dict):
            for k, v in reversed(list(val.items())):
                stack.append((str(k), v, depth + 1))
        elif isinstance(val, list):
            for v in reversed(val):
                stack.append((key, v, depth + 1))
    return out, truncated


def iter_nodes(args):
    return collect_nodes(args)[0]


def script_entry(seg):
    """(command id, parsed JSON args or None) for "id {json}", or None."""
    m = ENTRY_RE.match(seg)
    if not m:
        return None
    rest, args = m.group(2), None
    if rest.startswith("{"):
        try:
            args = json.loads(rest)
        except ValueError:
            args = None
    return m.group(1), args


def script_entries(text):
    """Each line of script text as (id, args); a line that is not "id {json}" is split on ';'."""
    entries = []
    for line in str(text).splitlines()[:2000]:
        first = script_entry(line)
        if first is None or (";" not in line or first[1] is not None):
            if first is not None:
                entries.append(first)
            continue
        for seg in line.split(";"):
            e = script_entry(seg)
            if e is not None:
                entries.append(e)
    return entries


def looks_like_path(s):
    # A newline inside the value does not make it prose: '<root>/a\n/../../etc' still resolves outside
    # (R1-HOOK-7). Only the ends are stripped.
    s = s.strip() if isinstance(s, str) else s
    if not s or len(s) > 4096 or "\x00" in s:
        return False
    if SCHEME_RE.match(s):
        return s[:7].lower() == "file://"
    if s.startswith(("/", "./", "../", "~/")) or s in ("~", ".."):
        return True
    if TILDE_USER_RE.match(s):
        return True
    return ".." in re.split(r"[\\/]", s)


def show(v):
    """A long value for a reason text: keep its end, which names the file (the start is the workspace)."""
    v = v.strip()
    return v if len(v) <= 80 else "..." + v[-77:]


def resolve(s, root):
    """Lexical absolute path for s, or None when it cannot be inside any workspace folder."""
    t = s.strip()
    if t[:7].lower() == "file://":
        rest = t[7:].split("?", 1)[0].split("#", 1)[0]
        if not rest.startswith("/"):
            host, _, tail = rest.partition("/")
            if host.lower() not in ("", "localhost"):
                return None
            rest = "/" + tail
        t = urllib.parse.unquote(rest)
    elif t == "~" or t.startswith("~/"):
        t = os.path.expanduser("~") + t[1:]
    elif t.startswith("~"):
        return None
    if not os.path.isabs(t):
        t = os.path.join(root, t)
    return os.path.normpath(t)


def app_root(workspace, app):
    return os.path.join(os.path.normpath(os.path.expanduser(workspace)), app)


def inside(path, root):
    return path == root or path.startswith(root + os.sep)


def truthy(val):
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return val != 0
    return isinstance(val, str) and val.strip().lower() in ("true", "yes", "1", "on")


def path_state(nodes, keys):
    """none (no non-empty value), relative (a relative path or a $placeholder/{template}) or ok."""
    vals = [v.strip() for k, v in nodes if k in keys and isinstance(v, str) and v.strip()]
    if not vals:
        return "none"
    for v in vals:
        if "$" in v or "{" in v or not (v.startswith("/") or v.startswith("~/") or v[:7].lower() == "file://"):
            return "relative"
    return "ok"


def save_reason(shown, state, why, keys):
    if state == "none":
        return "%s %s" % (shown, why)
    if state == "relative":
        return ("%s has a relative or placeholder %s, so the app resolves it itself; use an absolute path in the "
                "app's out/ folder" % (shown, "/".join(sorted(keys))))
    return None


def rule_applies(rule, names):
    scope = rule.get("tools")
    if not scope:
        return True
    return bool(set(norm_tool(t) for t in scope) & set(names))


def as_dict(x):
    return x if isinstance(x, dict) else {}


def as_list(x):
    return x if isinstance(x, list) else []


def call_pairs(app, tool, nodes, table):
    """[(normalised name, shown name, is_id, own_nodes)]: the tool itself, and for a runner every command
    id in its arguments, including each line of script text. own_nodes are the nodes that belong to that
    entry (the JSON after an id in script text), or None for the whole call. Also returns the extra
    nodes found in script text, for the path check."""
    glob = as_dict(table.get("global"))
    spec = as_dict(as_dict(table.get("apps")).get(app))
    tname = norm_tool(tool)
    pairs = [(tname, tool, False, None)]
    extra = []
    if tname in set(norm_tool(r) for r in as_list(spec.get("runners")) if isinstance(r, str)):
        id_keys = set(as_list(glob.get("id_keys"))) | set(as_list(glob.get("id_list_keys"))) | set(["tool"])
        for key, val in nodes:
            if not isinstance(val, str) or not val.strip() or len(val) > 200000:
                continue
            if key in id_keys and len(val) <= 120 and not re.search(r"\s", val):
                pairs.append((norm_tool(val), val, True, None))
            elif key in id_keys or key in SCRIPT_KEYS:
                for ident, args in script_entries(val):
                    own = iter_nodes(args) if args is not None else []
                    pairs.append((norm_tool(ident), ident, True, own))
                    extra.extend(own)
    return pairs, extra


def command_text_reasons(app, tool, nodes, table):
    """CADCraft-style command lines: every typed word is compared with the table's word lists (long
    names anywhere, short aliases only as a line's first word), "(" starts a LISP expression, and every
    path-like word is returned for the fence check. A heuristic, not a parser."""
    spec = as_dict(as_dict(as_dict(table.get("apps")).get(app)).get("command_text"))
    if norm_tool(tool) not in set(norm_tool(t) for t in as_list(spec.get("tools")) if isinstance(t, str)):
        return [], []
    words = dict((norm(k), v) for k, v in as_dict(spec.get("words")).items())
    first = dict((norm(k), v) for k, v in as_dict(spec.get("first_words")).items())
    key = spec.get("key", "text")
    reasons, paths = [], []
    for k, val in nodes:
        if k != key or not isinstance(val, str):
            continue
        for line in val.splitlines()[:5000]:
            toks = line.split()
            for i, tok in enumerate(toks):
                n = norm(tok.lstrip("-_.'"))
                why = words.get(n) or (first.get(n) if i == 0 else None)
                if why:
                    reasons.append("%s %r: %s" % (tool, tok, why))
                elif tok.startswith("("):
                    reasons.append("%s %r: %s" % (tool, tok[:40], spec.get("lisp_why", "starts a LISP expression")))
                if looks_like_path(tok):
                    paths.append((key, tok))
    return reasons, paths


def table_reasons(app, tool, nodes, table, pairs=None):
    """Reasons from hooks/risky-tools.json: risky tools or commands, saves without a path, risky arguments."""
    glob = as_dict(table.get("global"))
    spec = as_dict(as_dict(table.get("apps")).get(app))
    reasons = []

    if pairs is None:
        pairs = call_pairs(app, tool, nodes, table)[0]
    names = [p[0] for p in pairs]

    ask = dict((norm_tool(k), v) for k, v in list(as_dict(spec.get("ask")).items()) + list(as_dict(spec.get("ask_ids")).items()))
    for nm, shown, _, _ in pairs:
        if nm in ask:
            reasons.append("%s %s" % (shown, ask[nm]))
    for pat in as_list(glob.get("ask_command_patterns")):
        rx = re.compile(pat["pattern"])
        for nm, shown, _, _ in pairs:
            if nm not in ask and rx.search(nm):
                reasons.append("%s %s" % (shown, pat["why"]))

    save = dict((norm_tool(k), v) for k, v in as_dict(spec.get("save")).items())
    for nm, shown, _, own in pairs:
        rule = as_dict(save.get(nm))
        if rule:
            keys = set(rule.get("any_of") or ["path"])
            r = save_reason(shown, path_state(nodes if own is None else own, keys),
                            rule.get("why", "is called without an explicit path"), keys)
            if r:
                reasons.append(r)
    sp = as_dict(glob.get("save_command_patterns"))
    if sp.get("pattern"):
        rx = re.compile(sp["pattern"])
        skip = set(norm(x) for x in as_list(sp.get("exclude")) if isinstance(x, str))
        for nm, shown, is_id, own in pairs:
            if is_id and rx.search(nm) and nm not in save and nm not in skip and nm not in ask:
                keys = set(sp.get("any_of") or ["path"])
                r = save_reason(shown, path_state(nodes if own is None else own, keys),
                                sp.get("why", "is called without an explicit path"), keys)
                if r:
                    reasons.append(r)

    for rule in as_list(glob.get("ask_args")) + as_list(spec.get("args")):
        rule = as_dict(rule)
        if not rule.get("arg") or not rule_applies(rule, names):
            continue
        want = str(rule["arg"]).lower()
        for key, val in nodes:
            if key is None or key.lower() != want:
                continue
            hit = False
            if "equals" in rule:
                hit = isinstance(val, str) and val.strip().lower() == str(rule["equals"]).lower()
            elif rule.get("truthy"):
                hit = truthy(val)
            elif rule.get("present"):
                hit = val is not None
            if hit:
                reasons.append("%s: %s" % (tool, rule.get("why", "risky argument %s" % rule["arg"])))
                break
    return reasons


def path_reasons(app, nodes, workspace, content_keys, relative_ok=True, extra=()):
    """Any path-like string argument that does not resolve under <workspace>/<app>. The path is normalised
    lexically (so '..' cannot climb out), then real paths are compared, which accepts an alias of the
    workspace path (/tmp versus /private/tmp) and notices a symlink inside the folder that leads outside.
    extra: (key, value) pairs found in script or command text, checked even under content keys. When the
    server does not resolve relative paths in its app folder (relative_ok False), a relative value under
    a path key asks too."""
    root = app_root(workspace, app)
    real_root = os.path.realpath(root)
    reasons = []
    seen = set()
    checks = [(k, v, False) for k, v in nodes] + [(k, v, True) for k, v in extra]
    for key, val, forced in checks:
        if not isinstance(val, str):
            continue
        if not forced and key is not None and key in content_keys:
            continue
        if not looks_like_path(val):
            v = val.strip()
            if (not relative_ok and key in PATH_KEYS and v and len(v) <= 1024 and v.isprintable()
                    and not SCHEME_RE.match(v) and not re.search(r"\s", v) and FILE_EXT_RE.search(v)
                    and (key, val) not in seen):
                seen.add((key, val))
                reasons.append("relative path %r = %r: the %s server resolves it from its own working folder, not %s"
                               % (key, show(v), app, root))
            continue
        if (key, val) in seen:
            continue
        seen.add((key, val))
        if len(seen) > MAX_PATH_CHECKS:
            reasons.append("too many path arguments to check in full")
            break
        resolved = resolve(val, root)
        if resolved is not None and inside(os.path.realpath(resolved), real_root):
            v = val.strip()
            if not relative_ok and key in PATH_KEYS and not (v.startswith(("/", "~")) or v[:7].lower() == "file://"):
                reasons.append("relative path %r = %r: the %s server resolves it from its own working folder, not %s"
                               % (key, show(v), app, root))
            continue
        if len(reasons) < MAX_PATH_REASONS:
            reasons.append("argument %r = %r is not under %s" % (key or "(value)", show(val), root))
        else:
            reasons.append("more path arguments outside the workspace")
            break
    return reasons


def write_target_reasons(app, pairs, nodes, workspace):
    """A save or export to a file that already exists, or into <app>/in/ (the input copies). Output-folder
    keys (out_dir, dest, ...) are checked for any tool, because tools such as pdfcraft doc_split write there
    without a save-like name (B1-SKILLS-1); 'path' is not, since read tools (doc_open) use it."""
    writes = any(WRITE_NAME_RE.search(nm) for nm, _, _, _ in pairs)
    root = app_root(workspace, app)
    real_in = os.path.realpath(os.path.join(root, "in"))
    reasons = []
    for key, val in nodes:
        if not isinstance(val, str) or not looks_like_path(val):
            continue
        if not ((writes and key in ("path", "dir", "folder")) or key in OUT_KEYS):
            continue
        resolved = resolve(val, root)
        if resolved is None:
            continue
        real = os.path.realpath(resolved)
        if inside(real, real_in):
            reasons.append("%r writes into %s/in/, the folder of input copies" % (show(val), app))
        elif writes and key == "path" and os.path.lexists(real) and not os.path.isdir(real):
            reasons.append("%r already exists and would be overwritten" % show(val))
        if len(reasons) >= MAX_PATH_REASONS:
            break
    return reasons


def evaluate(app, tool, args, workspace, table):
    nodes, truncated = collect_nodes(args)
    reasons = []
    if truncated:
        reasons.append(TOO_BIG)
    pairs, extra = [(norm_tool(tool), tool, False, None)], []
    try:
        pairs, extra = call_pairs(app, tool, nodes, table)
    except Exception:
        pass
    try:
        reasons.extend(table_reasons(app, tool, nodes, table, pairs))
    except Exception:
        pass
    try:
        more, paths = command_text_reasons(app, tool, nodes, table)
        reasons.extend(more)
        extra = list(extra) + paths
    except Exception:
        pass
    try:
        glob = as_dict(table.get("global"))
        content = set(k for k in as_list(glob.get("content_keys")) if isinstance(k, str))
        rel = set(a for a in as_list(glob.get("relative_to_app_folder")) if isinstance(a, str)) or DEFAULT_RELATIVE_OK
        reasons.extend(path_reasons(app, nodes, workspace, content or DEFAULT_CONTENT_KEYS, app in rel, extra))
    except Exception:
        pass
    try:
        reasons.extend(write_target_reasons(app, pairs, nodes + list(extra), workspace))
    except Exception:
        pass
    unique = []
    for r in reasons:
        if r not in unique:
            unique.append(r)
    return unique, app_root(workspace, app)


def parse_workspace(argv):
    ws = None
    args = argv[1:]
    for j, a in enumerate(args):
        if a == "--workspace" and j + 1 < len(args):
            ws = args[j + 1]
        elif a.startswith("--workspace="):
            ws = a.split("=", 1)[1]
    if not ws:
        ws = os.path.join(os.path.expanduser("~"), "craft-workspace")
    return os.path.normpath(os.path.expanduser(ws))


def main(argv):
    try:
        data = json.loads(sys.stdin.read())
        if not isinstance(data, dict):
            return 0
        name = data.get("tool_name")
        tool_input = data.get("tool_input")
        if not isinstance(name, str) or not isinstance(tool_input, dict):
            return 0
        m = TOOL_RE.match(name)
        if not m:
            return 0
        app, tool = m.group(1), m.group(2)
        reasons, root = evaluate(app, tool, tool_input, parse_workspace(argv), load_table())
        if not reasons:
            return 0
        shown = reasons[:MAX_REASONS]
        extra = len(reasons) - len(shown)
        text = ("Craft guard: %s%s. The %s server is fenced to %s; approve only if you intend this."
                % ("; ".join(shown), " (+%d more)" % extra if extra > 0 else "", app, root))
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "ask",
                                      "permissionDecisionReason": text}}
        sys.stdout.write(json.dumps(out))
        sys.stdout.flush()
    except BaseException:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
