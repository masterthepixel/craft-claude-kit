#!/usr/bin/env python3
"""settings_edit: safely add, remove and list hooks in a Claude Code settings.json.

  settings_edit.py add-hook    --settings FILE --event PreToolUse --matcher M --command C [--timeout N] [--backup-tag TAG]
  settings_edit.py remove-hook --settings FILE --event PreToolUse --command-contains STR [--backup-tag TAG]
  settings_edit.py list-hooks  --settings FILE [--json]

Safety rules (this file holds a user's own configuration):
  * A missing FILE is created as {}. A FILE that is not strict JSON (comments, trailing commas, NaN,
    duplicate keys, a non-object top level) is never touched: the command explains and exits 1.
  * Every other key, and the order of keys, hooks and groups, is kept as it was. The indentation style
    and line endings of the existing file are kept too.
  * Before the first change, and only when something will change, FILE.bak-craft-kit-<YYYYmmdd-HHMMSS>
    is written next to FILE. With --backup-tag TAG the name is FILE.bak-craft-kit-TAG, and an existing
    backup of that name is kept as it is, so one installer run (several edits) leaves one backup that
    holds the file as it was before the run.
  * The write is atomic (temp file in the same folder, then os.replace), keeps the file mode, and goes
    through a symlink to the real file, so a settings.json that links into a dotfiles folder stays a link.
  * Re-adding the same matcher+command changes nothing ("unchanged"), so the installer can run twice.

Exit codes: 0 ok (including "unchanged" and "nothing to remove"), 1 refused or failed, 2 usage error.
Python 3.9, standard library only.
"""
import argparse
import json
import math
import os
import re
import sys
import tempfile
import time


class EditError(Exception):
    """A problem to report to the user; nothing has been changed."""


def parse_strict(text):
    def reject_constant(name):
        raise ValueError("%s is not valid JSON" % name)

    def no_duplicates(pairs):
        seen = set()
        for key, _ in pairs:
            if key in seen:
                raise ValueError("duplicate key %r" % key)
            seen.add(key)
        return dict(pairs)

    def finite_float(literal):
        # 1e400 is valid JSON but becomes inf in Python, which json.dumps would write back as the
        # bare token Infinity: not JSON. Refuse such a file instead of corrupting it.
        value = float(literal)
        if not math.isfinite(value):
            raise ValueError("number out of range: %s" % literal)
        return value

    return json.loads(text, object_pairs_hook=no_duplicates, parse_constant=reject_constant,
                      parse_float=finite_float)


def read_raw(real):
    try:
        with open(real, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def load(path):
    """Return (data, raw_bytes_or_None, real_path). raw is None when the file does not exist."""
    real = os.path.realpath(os.path.expanduser(path))
    if os.path.isdir(real):
        raise EditError("%s is a directory, not a settings file" % path)
    try:
        raw = read_raw(real)
    except OSError as exc:
        raise EditError("cannot read %s: %s" % (path, exc))
    if raw is None:
        return {}, None, real
    try:
        data = parse_strict(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise EditError("%s is not valid JSON (%s). Nothing was changed. Fix or move the file, then run "
                        "this again." % (path, exc))
    if not isinstance(data, dict):
        raise EditError("%s does not contain a JSON object at the top level. Nothing was changed." % path)
    return data, raw, real


def detect_style(raw):
    """Indent, line ending and trailing-newline style of an existing file."""
    if raw is None:
        return 2, "\n", True
    text = raw.decode("utf-8")
    m = re.search(r'^([ \t]+)["\]}\[{]', text, re.M)
    indent = 2
    if m:
        lead = m.group(1)
        indent = "\t" if lead.startswith("\t") else min(len(lead), 8)
    eol = "\r\n" if "\r\n" in text else "\n"
    return indent, eol, text.endswith("\n")


def dump(data, raw):
    indent, eol, trailing = detect_style(raw)
    text = json.dumps(data, indent=indent, ensure_ascii=False, allow_nan=False)
    if eol != "\n":
        text = text.replace("\n", eol)
    if trailing:
        text += eol
    return text.encode("utf-8")


def write_atomic(real, content, mode, expected_raw):
    folder = os.path.dirname(real) or "."
    if not os.path.isdir(folder):
        os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".settings-edit-", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if read_raw(real) != expected_raw:
            raise EditError("the settings file changed while it was being edited. Nothing was written; "
                            "run this again.")
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def make_backup(path, raw, mode, tag=None):
    """Copy the previous bytes next to the settings file. Created owner-only first, then given the original
    file's mode, so a private settings file never has a more open backup."""
    base = "%s.bak-craft-kit-%s" % (os.path.abspath(os.path.expanduser(path)), tag or time.strftime("%Y%m%d-%H%M%S"))
    if tag and os.path.lexists(base):
        return base
    candidate = base
    n = 1
    while True:
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            candidate = "%s-%d" % (base, n)
            n += 1
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    os.chmod(candidate, mode)
    return candidate


def current_umask():
    mask = os.umask(0)
    os.umask(mask)
    return mask


def save(path, data, raw, real, tag=None):
    """Write data back (backup first when the file existed). Returns the backup path or None."""
    content = dump(data, raw)
    backup = None
    if raw is not None:
        if content == raw:
            return None
        mode = os.stat(real).st_mode & 0o7777
        backup = make_backup(path, raw, mode, tag)
    else:
        mode = 0o666 & ~current_umask()
    write_atomic(real, content, mode, raw)
    return backup


# ---------------------------------------------------------------------------------------------- operations

def get_event_groups(data, event, create):
    hooks = data.get("hooks")
    if "hooks" not in data:
        if not create:
            return None
        hooks = data["hooks"] = {}
    elif not isinstance(hooks, dict):
        raise EditError('"hooks" in the settings file is not an object. Nothing was changed.')
    groups = hooks.get(event)
    if event not in hooks:
        if not create:
            return None
        groups = hooks[event] = []
    elif not isinstance(groups, list):
        raise EditError('"hooks.%s" in the settings file is not a list. Nothing was changed.' % event)
    return groups


def add_hook(data, event, matcher, command, timeout):
    groups = get_event_groups(data, event, True)
    for group in groups:
        if not isinstance(group, dict) or (group.get("matcher") or "") != matcher:
            continue
        for hook in group.get("hooks") or []:
            if isinstance(hook, dict) and hook.get("command") == command \
                    and hook.get("type", "command") == "command":
                if timeout is not None and hook.get("timeout") != timeout:
                    hook["timeout"] = timeout
                    return "updated"
                return "unchanged"
    entry = {"type": "command", "command": command}
    if timeout is not None:
        entry["timeout"] = timeout
    group = {}
    if matcher:
        group["matcher"] = matcher
    group["hooks"] = [entry]
    groups.append(group)
    return "added"


def remove_hook(data, event, needle):
    groups = get_event_groups(data, event, False)
    if groups is None:
        return 0
    removed = 0
    kept_groups = []
    for group in groups:
        hooks = group.get("hooks") if isinstance(group, dict) else None
        if isinstance(hooks, list):
            kept = [h for h in hooks
                    if not (isinstance(h, dict) and isinstance(h.get("command"), str) and needle in h["command"])]
            gone = len(hooks) - len(kept)
            if gone:
                removed += gone
                if kept:
                    group["hooks"] = kept
                    kept_groups.append(group)
                continue
        kept_groups.append(group)
    if removed:
        top = data["hooks"]
        if kept_groups:
            top[event] = kept_groups
        else:
            del top[event]
            if not top:
                del data["hooks"]
    return removed


def list_hooks(data):
    rows = []
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return rows
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks") or []:
                if isinstance(hook, dict):
                    row = {"event": event, "matcher": group.get("matcher") or "",
                           "type": hook.get("type", "command"), "command": hook.get("command", "")}
                    if "timeout" in hook:
                        row["timeout"] = hook["timeout"]
                    rows.append(row)
    return rows


# ---------------------------------------------------------------------------------------------- CLI

def build_parser():
    parser = argparse.ArgumentParser(prog="settings_edit.py",
                                     description="Safely add, remove and list hooks in a Claude Code settings.json.")
    sub = parser.add_subparsers(dest="action")
    sub.required = True

    p = sub.add_parser("add-hook", help="add a command hook (idempotent)")
    p.add_argument("--settings", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--matcher", default="")
    p.add_argument("--command", required=True)
    p.add_argument("--timeout", type=int)
    p.add_argument("--backup-tag")

    p = sub.add_parser("remove-hook", help="remove every hook whose command contains a string")
    p.add_argument("--settings", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--command-contains", required=True, dest="needle")
    p.add_argument("--backup-tag")

    p = sub.add_parser("list-hooks", help="list the hooks in the file")
    p.add_argument("--settings", required=True)
    p.add_argument("--json", action="store_true")
    return parser


def run(args):
    path = args.settings
    tag = getattr(args, "backup_tag", None)
    if tag is not None and not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", tag):
        build_parser().error("--backup-tag may only contain letters, digits, '.', '_' and '-'")
    data, raw, real = load(path)

    if args.action == "list-hooks":
        rows = list_hooks(data)
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for row in rows:
                print("%s\t%s\t%s" % (row["event"], row["matcher"], row["command"]))
        return 0

    if args.action == "add-hook":
        if args.timeout is not None and args.timeout <= 0:
            build_parser().error("--timeout must be a positive number of seconds")
        status = add_hook(data, args.event, args.matcher, args.command, args.timeout)
        label = "%s: %s [%s] %s" % (status, args.event, args.matcher or "-", args.command)
    else:
        if not args.needle:
            build_parser().error("--command-contains must not be empty")
        count = remove_hook(data, args.event, args.needle)
        status = "removed" if count else "unchanged"
        label = ("removed: %d %s hook(s) containing %r" % (count, args.event, args.needle) if count
                 else "nothing to remove: no %s hook contains %r" % (args.event, args.needle))

    if status == "unchanged":
        print(label)
        return 0
    backup = save(path, data, raw, real, tag)
    print(label)
    if backup:
        print("backup: %s" % backup)
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except EditError as exc:
        sys.stderr.write("settings_edit: %s\n" % exc)
        return 1
    except OSError as exc:
        sys.stderr.write("settings_edit: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
