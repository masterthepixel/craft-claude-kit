#!/usr/bin/env python3
"""craftkit: the small, stdlib-only helper behind install.sh, doctor.sh and the MCP probe.

Command line (every subcommand prints JSON or plain text on stdout, diagnostics on stderr):

  craftkit.py expected   --app A --workspace W --prefix P [--lock FILE]
      JSON {"args": [...], "command": "..."}: what the user-scope MCP registration SHOULD be.
  craftkit.py registered --app A [--config-dir D]
      JSON of the same shape for the registration that exists in <D>/.claude.json (or
      ~/.claude.json). Exit 1 if there is none, exit 3 if the config cannot be read or parsed.
  craftkit.py render     --workspace W --kit-home K --in FILE --out FILE
      Replaces {{WORKSPACE}} and {{KIT_HOME}}; exit 1 (and writes nothing) if any {{...}} remains.
      "-" means stdin / stdout.
  craftkit.py lock-get   --app A --field cli.url [--lock FILE]
      Prints one field of the lock (dotted path). Without --app the path starts at the lock root.
  craftkit.py apps       [--lock FILE]
      Prints the app names of the lock, one per line, in lock order.
  craftkit.py shadowed   --apps a,b [--config-dir D] [--workspace W --prefix P] [--lock FILE]
      JSON list of local-scope (.claude.json "projects") and project-scope (<project>/.mcp.json)
      registrations of these apps; Claude Code prefers them over the user-scope server in that
      folder. With --workspace/--prefix, entries equal to the expected registration are left out.

`expected` and `registered` print compact, key-sorted JSON in the same format, so a shell string
comparison of the two outputs is a valid equality test.

Exit codes: 0 ok, 1 not found / failed, 2 usage error, 3 unreadable or invalid input file.

Module API: load_lock, expected_registration, registered, render_text (plus leftover_tokens,
registered_entry, lock_get, app_names, shadowing). Python 3.9+, no third-party packages.
"""

import argparse
import json
import os
import re
import sys

SUPPORTED_SCHEMA = 1
FENCES = ("roots", "root", "sandbox")
CONFIG_NAME = ".claude.json"
SANDBOX_WRAPPER = "craft-sandbox"

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LOCK = os.path.join(os.path.dirname(_HERE), "manifest", "apps.lock.json")

_TOKEN_RE = re.compile(r"\{\{\s*(WORKSPACE|KIT_HOME)\s*\}\}")
_ANY_TOKEN_RE = re.compile(r"\{\{[^{}\n]*\}\}")


class CraftKitError(Exception):
    """A problem to report to the user (exit 1)."""

    exit_code = 1


class UsageError(CraftKitError):
    exit_code = 2


class InputFileError(CraftKitError):
    """A file we were pointed at is unreadable or not what it should be (exit 3)."""

    exit_code = 3


def _abs(path):
    """Absolute, normalised, no trailing slash, ~ expanded. Not resolved through symlinks."""
    if path is None or str(path) == "":
        raise UsageError("empty path")
    p = os.path.abspath(os.path.expanduser(str(path)))
    return p if p == os.sep else p.rstrip(os.sep)


abs_path = _abs


# ---------------------------------------------------------------------------------------------
# lock
# ---------------------------------------------------------------------------------------------

def lock_path(path=None):
    """Lock file location: explicit path, else $CRAFT_KIT_LOCK, else <kit>/manifest/apps.lock.json."""
    if path:
        return str(path)
    env = os.environ.get("CRAFT_KIT_LOCK")
    return env if env else DEFAULT_LOCK


def load_lock(path=None):
    """Load and validate the lock (schema 1). Raises InputFileError if unusable."""
    p = lock_path(path)
    try:
        with open(p, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        raise InputFileError("lock file not found: %s" % p)
    except (OSError, ValueError) as exc:
        raise InputFileError("cannot read lock file %s: %s" % (p, exc))
    if not isinstance(data, dict) or data.get("schema") != SUPPORTED_SCHEMA:
        raise InputFileError("unsupported lock file (need schema %d): %s" % (SUPPORTED_SCHEMA, p))
    if not isinstance(data.get("apps"), dict) or not data["apps"]:
        raise InputFileError("lock file has no apps: %s" % p)
    return data


def _as_lock(lock):
    if lock is None or isinstance(lock, (str, bytes, os.PathLike)):
        return load_lock(lock)
    return lock


def app_names(lock=None):
    return list(_as_lock(lock)["apps"].keys())


def _app_entry(lock, app):
    apps = lock["apps"]
    if app not in apps:
        raise UsageError("unknown app %r (known: %s)" % (app, ", ".join(sorted(apps))))
    return apps[app]


def lock_get(app, field, lock=None):
    """Value at a dotted path inside the app's lock entry (app=None: from the lock root)."""
    data = _as_lock(lock)
    node = _app_entry(data, app) if app else data
    for part in str(field).split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            raise CraftKitError("no such field %r for %s" % (field, app or "lock"))
    return node


# ---------------------------------------------------------------------------------------------
# expected registration
# ---------------------------------------------------------------------------------------------

def expected_registration(app, workspace, prefix, lock=None):
    """The registration (command + args) that confines `app` to <workspace>/<app>.

    roots   <prefix>/<app>-cli mcp --automation-read-root R --automation-write-root R [extra]
    root    <prefix>/<app>-cli mcp --root R [extra]
    sandbox <prefix>/craft-sandbox R <prefix>/<app>-cli mcp [extra]
    """
    entry = _app_entry(_as_lock(lock), app)
    fence = entry.get("fence")
    if fence not in FENCES:
        raise InputFileError("lock entry for %s has unknown fence %r" % (app, fence))
    extra = entry.get("extraArgs") or []
    if not isinstance(extra, list) or not all(isinstance(a, str) for a in extra):
        raise InputFileError("lock entry for %s: extraArgs must be a list of strings" % app)
    bad = [a for a in extra if is_fence_flag(a)]
    if bad:
        # A repeated or "=" form fence flag after ours would win (the CLIs honour the last one).
        raise InputFileError("lock entry for %s: extraArgs may not carry fence flags: %s" % (app, ", ".join(bad)))
    pfx = _abs(prefix)
    root = os.path.join(_abs(workspace), app)
    cli = os.path.join(pfx, "%s-cli" % app)
    if fence == "roots":
        command, args = cli, ["mcp", "--automation-read-root", root, "--automation-write-root", root]
    elif fence == "root":
        command, args = cli, ["mcp", "--root", root]
    else:
        command, args = os.path.join(pfx, SANDBOX_WRAPPER), [root, cli, "mcp"]
    return {"command": command, "args": args + list(extra)}


def is_fence_flag(arg):
    """--root, --automation-* (also in the --flag=value form): flags only the fence may set."""
    return arg == "--root" or arg.startswith("--root=") or arg.startswith("--automation-")


def fence_flags(app, lock=None):
    """Flags the CLI's --help must advertise for the app's fence (empty for sandbox)."""
    fence = _app_entry(_as_lock(lock), app).get("fence")
    if fence == "roots":
        return ["--automation-read-root", "--automation-write-root"]
    if fence == "root":
        return ["--root"]
    return []


# ---------------------------------------------------------------------------------------------
# registered registration (user scope)
# ---------------------------------------------------------------------------------------------

def config_file(config_dir=None):
    """<D>/.claude.json for an explicit dir or $CLAUDE_CONFIG_DIR, else ~/.claude.json."""
    d = config_dir or os.environ.get("CLAUDE_CONFIG_DIR")
    if d:
        return os.path.join(_abs(d), CONFIG_NAME)
    return os.path.join(os.path.expanduser("~"), CONFIG_NAME)


def registered_entry(app, config_dir=None):
    """The raw user-scope mcpServers entry for `app` (dict), or None if there is none."""
    path = config_file(config_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise InputFileError("cannot read Claude config %s: %s" % (path, exc))
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    if not isinstance(servers, dict):
        return None
    entry = servers.get(app)
    return entry if isinstance(entry, dict) else None


def registered(app, config_dir=None):
    """{"command", "args"} of the user-scope registration, or None. Project/local scopes are
    ignored on purpose: only the user-scope entry is what this kit manages."""
    entry = registered_entry(app, config_dir)
    return None if entry is None else _normalise(entry)


def _normalise(entry):
    """command, args, a non-stdio type, and every other non-empty key (env, cwd, ...): an env
    override such as CRAFT_SANDBOX_PROFILE changes the fence, so it must not compare equal."""
    args = entry.get("args")
    out = {
        "command": entry.get("command") if isinstance(entry.get("command"), str) else "",
        "args": [str(a) for a in args] if isinstance(args, list) else [],
    }
    kind = entry.get("type")
    if kind not in (None, "stdio"):
        out["type"] = str(kind)
    for key, value in entry.items():
        if key not in ("command", "args", "type") and value not in (None, "", [], {}):
            out[key] = value
    return out


def _servers(doc):
    servers = doc.get("mcpServers") if isinstance(doc, dict) else None
    return servers if isinstance(servers, dict) else {}


def shadowing(apps, config_dir=None):
    """Registrations of `apps` at local scope (.claude.json "projects".<dir>.mcpServers) and project
    scope (<dir>/.mcp.json, for each folder .claude.json knows). In that folder Claude Code uses
    them instead of the user-scope server, so they bypass the kit's fence unless they are identical.
    Returns [{"app", "scope": "local"|"project", "dir", "file", "command", "args"}]."""
    path = config_file(config_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as exc:
        raise InputFileError("cannot read Claude config %s: %s" % (path, exc))
    projects = data.get("projects") if isinstance(data, dict) else None
    out = []
    for folder, entry in sorted(projects.items() if isinstance(projects, dict) else []):
        local = _servers(entry)
        project = {}
        if isinstance(folder, str) and os.path.isabs(folder):
            mcp_json = os.path.join(folder, ".mcp.json")
            try:
                with open(mcp_json, "r", encoding="utf-8") as fh:
                    project = _servers(json.load(fh))
            except (OSError, ValueError):
                project = {}
        for app in apps:
            for scope, servers, where in (("local", local, path), ("project", project, os.path.join(str(folder), ".mcp.json"))):
                if isinstance(servers.get(app), dict):
                    item = {"app": app, "scope": scope, "dir": folder, "file": where}
                    item.update(_normalise(servers[app]))
                    out.append(item)
    return out


# ---------------------------------------------------------------------------------------------
# skill rendering
# ---------------------------------------------------------------------------------------------

def render_text(text, workspace, kit_home):
    """Replace {{WORKSPACE}} and {{KIT_HOME}} (single pass) with absolute paths, no trailing slash.
    Other tokens are left alone; use leftover_tokens() to find them."""
    values = {"WORKSPACE": _abs(workspace), "KIT_HOME": _abs(kit_home)}
    return _TOKEN_RE.sub(lambda m: values[m.group(1)], text)


def leftover_tokens(text):
    """Every {{...}} token still present in `text`, in order of appearance."""
    return _ANY_TOKEN_RE.findall(text)


def _write_atomic(path, text):
    if path == "-":
        sys.stdout.write(text)
        sys.stdout.flush()
        return
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------------------------

def _dump(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


def _cmd_expected(ns):
    print(_dump(expected_registration(ns.app, ns.workspace, ns.prefix, ns.lock)))
    return 0


def _cmd_registered(ns):
    reg = registered(ns.app, ns.config_dir)
    if reg is None:
        sys.stderr.write("craftkit: no user-scope registration for %s in %s\n"
                         % (ns.app, config_file(ns.config_dir)))
        return 1
    print(_dump(reg))
    return 0


def _cmd_render(ns):
    try:
        if ns.infile == "-":
            text = sys.stdin.read()
        else:
            with open(ns.infile, "r", encoding="utf-8", newline="") as fh:
                text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise InputFileError("cannot read %s: %s" % (ns.infile, exc))
    out = render_text(text, ns.workspace, ns.kit_home)
    left = leftover_tokens(out)
    if left:
        sys.stderr.write("craftkit: unresolved token(s) in %s: %s\n"
                         % (ns.infile, ", ".join(sorted(set(left)))))
        return 1
    _write_atomic(ns.outfile, out)
    return 0


def _cmd_lock_get(ns):
    value = lock_get(ns.app, ns.field, ns.lock)
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(_dump(value))
    elif value is None:
        print("")
    else:
        print(value)
    return 0


def _cmd_shadowed(ns):
    apps = [a for a in (ns.apps or "").split(",") if a]
    found = shadowing(apps, ns.config_dir)
    if ns.workspace and ns.prefix:
        lock = load_lock(ns.lock)
        keep = []
        for item in found:
            exp = expected_registration(item["app"], ns.workspace, ns.prefix, lock)
            reg = {k: v for k, v in item.items() if k not in ("app", "scope", "dir", "file")}
            if reg != exp:
                keep.append(item)
        found = keep
    print(json.dumps(found, sort_keys=True, ensure_ascii=False))
    return 0


def _cmd_apps(ns):
    for name in app_names(ns.lock):
        print(name)
    return 0


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("craftkit: %s\n" % message)
        raise SystemExit(2)


def build_parser():
    p = _Parser(prog="craftkit.py", description="craft-claude-kit helper (see the module docstring)")
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("expected", help="print the registration an app SHOULD have")
    s.add_argument("--app", required=True)
    s.add_argument("--workspace", required=True)
    s.add_argument("--prefix", required=True)
    s.add_argument("--lock")
    s.set_defaults(func=_cmd_expected)

    s = sub.add_parser("registered", help="print the user-scope registration that exists")
    s.add_argument("--app", required=True)
    s.add_argument("--config-dir")
    s.set_defaults(func=_cmd_registered)

    s = sub.add_parser("render", help="fill {{WORKSPACE}} / {{KIT_HOME}} in a file")
    s.add_argument("--workspace", required=True)
    s.add_argument("--kit-home", required=True)
    s.add_argument("--in", dest="infile", required=True)
    s.add_argument("--out", dest="outfile", required=True)
    s.set_defaults(func=_cmd_render)

    s = sub.add_parser("lock-get", help="print a field of the lock")
    s.add_argument("--app")
    s.add_argument("--field", required=True)
    s.add_argument("--lock")
    s.set_defaults(func=_cmd_lock_get)

    s = sub.add_parser("shadowed", help="local/project-scope registrations that override the user-scope one")
    s.add_argument("--apps", required=True)
    s.add_argument("--config-dir")
    s.add_argument("--workspace")
    s.add_argument("--prefix")
    s.add_argument("--lock")
    s.set_defaults(func=_cmd_shadowed)

    s = sub.add_parser("apps", help="list the app names in the lock")
    s.add_argument("--lock")
    s.set_defaults(func=_cmd_apps)
    return p


def main(argv=None):
    ns = build_parser().parse_args(argv)
    try:
        return ns.func(ns)
    except CraftKitError as exc:
        sys.stderr.write("craftkit: %s\n" % exc)
        return exc.exit_code
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
