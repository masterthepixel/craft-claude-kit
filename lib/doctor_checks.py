#!/usr/bin/env python3
"""Helpers for doctor.sh. Stdlib only, Python 3.9+.

Check subcommands print one record per line on stdout:
    scope US id US status US detail US hint          (US = \\x1f, status PASS|WARN|FAIL)
and may print "META US key US value" lines that hand a value back to doctor.sh.
They never change anything on disk, except fence-live, which removes the probe file it tried to
create if (and only if) the sandbox failed to refuse the write.

  app-static   --app A --workspace W --prefix P --kit-dir K --kit-home H [--lock L] [--config-dir D]
               [--mcp-skipped]
               cli-installed, workspace, mcp-registered, mcp-shadowed (only when found), fence-config
  probe-result --app A --rc N --out FILE --err FILE --snapshot FILE [--lock L]
               [--workspace W --prefix P] [--wrapper PATH] [--via TEXT]
               server-starts, tools-list, drift
  fence-live   --app A --workspace W --prefix P --kit-dir K --kit-home H [--wrapper PATH]
  smoke-result --app A --rc N --out FILE --err FILE [--workspace W --prefix P --steps FILE] [--wrapper PATH]
  skills       --claude-dir D --workspace W --kit-home H --apps a,b [--source DIR] [--tools-dir DIR]
  hooks        --settings FILE --kit-home H --workspace W --apps a,b
  legacy       --settings FILE --home DIR
  gui          --apps a,b [--lock L] [--receipt FILE] [--gui-dir DIR] [--force]
  report       --in FILE --format json|summary
  run-timeout  SECONDS CMD [ARGS...]      run a command, kill its process group after SECONDS (exit 124)
  json-get     FILE dotted.path           print one value (exit 1 missing, 3 unreadable)
  abspath      PATH                       absolute, ~ expanded, no trailing slash (like craftkit)
"""

import argparse
import json
import os
import plistlib
import re
import shlex
import signal
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

US = "\x1f"
PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
# Full tool names only: a wildcard such as mcp__filmcraft__ui_* is not a reference to one tool.
TOOL_REF_RE = re.compile(r"mcp__([a-z0-9]+)__([A-Za-z0-9_]+)(?![A-Za-z0-9_*])")
TOKEN_RE = re.compile(r"\{\{[^{}\n]*\}\}")
EPERM_TEXT = "Operation not permitted"
SANDBOX_TEMP_WRITABLE = ("/private/tmp", "/private/var/folders", "/dev")
# TEST-NET-1 (RFC 5737): reserved for documentation, never routed. If the fence ever failed, the
# connection attempt would go nowhere; inside a working sandbox it is refused before any packet.
NET_PROBE = ("192.0.2.1", "443")
SHELL_GUARD = "craft-shell-guard.py"
# Tools the shell guard must see: each runs a shell command or starts an app (lib/common.sh).
SHELL_GUARD_TOOLS = ("Bash", "mcp__terminal__run_in_terminal", "Monitor", "mcp__computer-use__open_application")
MCP_GUARD = "craft-mcp-guard.py"
LEGACY_HOOK_PART = os.path.join(".local", "share", "craft-skills", SHELL_GUARD)


# ---------------------------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------------------------

def _clean(value):
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(value)).strip()


def rec(scope, cid, status, detail="", hint=""):
    if status == PASS:
        hint = ""
    sys.stdout.write(US.join([_clean(scope), _clean(cid), status, _clean(detail), _clean(hint)]) + "\n")


def meta(key, value):
    sys.stdout.write(US.join(["META", key, _clean(value), "", ""]) + "\n")


def _short(text, limit=160):
    text = _clean(text)
    return text if len(text) <= limit else text[:limit - 3] + "..."


def _tail(text, lines=3, limit=200):
    rows = [r.strip() for r in str(text).splitlines() if r.strip()]
    return _short(" | ".join(rows[-lines:]), limit)


# ---------------------------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------------------------

def abs_path(path):
    p = os.path.abspath(os.path.expanduser(str(path)))
    return p if p == os.sep else p.rstrip(os.sep)


def _under(path, parent):
    path, parent = os.path.realpath(path), os.path.realpath(parent)
    return path == parent or path.startswith(parent.rstrip(os.sep) + os.sep)


def _kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass


def run(argv, timeout, stdin_text=None, env=None, cwd=None):
    """(rc, stdout, stderr). rc 124 on timeout, 127 if it cannot be started. Own process group."""
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd, start_new_session=True)
    except OSError as exc:
        return 127, "", str(exc)
    data = stdin_text.encode("utf-8") if stdin_text is not None else None
    try:
        out, err = proc.communicate(data, timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        try:
            out, err = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out, err = b"", b""
        rc = 124
    except BaseException:
        _kill_group(proc)
        raise
    return rc, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def first_version(text):
    m = VERSION_RE.search(text or "")
    return m.group(0) if m else ""


def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_lock(path):
    import craftkit
    return craftkit.load_lock(path or None)


def _apps_arg(value):
    return [a for a in (value or "").split(",") if a]


def _quote_argv(argv):
    return " ".join(shlex.quote(a) for a in argv)


def probe_command(app, workspace, prefix, wrapper, tail):
    """A pasteable mcp_probe command line (real paths, no placeholders)."""
    argv = ["python3", os.path.join(_HERE, "mcp_probe.py"), "--app", app]
    argv += ["--workspace", workspace] if workspace else ["--workspace", "WORKSPACE"]
    if prefix:
        argv += ["--prefix", prefix]
    if wrapper:
        argv += ["--wrapper", wrapper]
    return _quote_argv(argv + list(tail))


def installer_hint(kit_dir, app=None):
    """doctor.sh passes the installer it found (repo checkout or the receipt's repoDir).

    --yes: the hint is pasted after reading the FAIL lines, often into a shell without a terminal
    (Claude Code's Bash tool), where install.sh without --yes changes nothing. --only APP only when
    an install receipt exists: before the first install, --only would turn the one-command install
    into a one-app install, because later plain re-runs keep the apps of earlier runs."""
    script = os.environ.get("CRAFT_DOCTOR_INSTALLER") or os.path.join(kit_dir, "install.sh")
    has_receipt = os.environ.get("CRAFT_DOCTOR_RECEIPT_OK", "1") == "1"
    only = " --only %s" % app if app and has_receipt else ""
    if os.path.isfile(script):
        return "re-run %s%s --yes" % (shlex.quote(script), only)
    return "re-run install.sh%s --yes from your clone of craft-claude-kit" % only


# ---------------------------------------------------------------------------------------------
# app-static: cli-installed, workspace, mcp-registered, fence-config
# ---------------------------------------------------------------------------------------------

def _flag_advertised(help_text, flag):
    return re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(flag), help_text) is not None


def _flag_values(args, flag):
    """Every value given for FLAG, in order, in both the "--flag value" and "--flag=value" forms."""
    out = []
    for i, a in enumerate(args):
        if a == flag:
            out.append(args[i + 1] if i + 1 < len(args) else None)
        elif a.startswith(flag + "="):
            out.append(a[len(flag) + 1:])
    return out


def _flag_value(args, flag):
    vals = _flag_values(args, flag)
    return vals[0] if vals else None


def _receipt_app(path, app):
    try:
        doc = load_json(path) if path else None
    except (OSError, ValueError):
        return None
    apps = doc.get("apps") if isinstance(doc, dict) else None
    entry = apps.get(app) if isinstance(apps, dict) else None
    return entry if isinstance(entry, dict) else None


def _sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_app_static(ns):
    import craftkit
    app = ns.app
    lock = load_lock(ns.lock)
    entry = lock["apps"][app]
    version, fence = entry.get("version", ""), entry.get("fence", "")
    prefix, workspace = abs_path(ns.prefix), abs_path(ns.workspace)
    root = os.path.join(workspace, app)
    cli = os.path.join(prefix, "%s-cli" % app)
    hint = installer_hint(ns.kit_dir, app)
    meta("fence", fence)

    # cli-installed
    cli_runs = False
    if not os.path.lexists(cli):
        rec(app, "cli-installed", FAIL, "not found: %s" % cli, hint)
    elif not (os.path.isfile(cli) and os.access(cli, os.X_OK)):
        rec(app, "cli-installed", FAIL, "not an executable file: %s" % cli, hint)
    else:
        rc, out, err = run([cli, "--version"], 30)
        got = first_version(out + "\n" + err)
        if rc == 124:
            rec(app, "cli-installed", FAIL, "%s --version timed out" % cli, hint)
        elif rc != 0:
            rec(app, "cli-installed", FAIL, "%s --version exited %d: %s" % (cli, rc, _tail(err or out)), hint)
        elif got == version:
            cli_runs = True
            entry = _receipt_app(ns.receipt, app)
            want = entry.get("cliSha256") if entry else None
            try:
                have = _sha256(cli)
            except OSError:
                have = ""
            if entry is not None and entry.get("cli") is True and not want:
                rec(app, "cli-installed", WARN, "%s-cli %s; the receipt has no SHA-256 for it (older install), so the "
                    "file cannot be compared with what the kit verified" % (app, got), hint + " (records it)")
            elif want and have != want:
                rec(app, "cli-installed", FAIL, "%s changed since the kit verified and installed it (SHA-256 differs)"
                    % cli, hint + " (replaces it with the verified download)")
            else:
                rec(app, "cli-installed", PASS, "%s-cli %s%s" % (app, got, ", same file the kit verified" if want else ""))
        else:
            cli_runs = True
            rec(app, "cli-installed", FAIL, "%s-cli reports %s, the lock pins %s" % (app, got or "no version", version), hint)
    meta("cli_runs", "1" if cli_runs else "0")

    # workspace
    ws_ok = False
    if os.path.islink(root):
        rec(app, "workspace", FAIL, "%s is a symlink (to %s); the fence would follow it" % (root, os.path.realpath(root)),
            "replace it with a real folder: rm %s && mkdir -m 700 %s" % (shlex.quote(root), shlex.quote(root)))
    elif not os.path.isdir(root):
        rec(app, "workspace", FAIL, "missing: %s" % root, "%s (or mkdir -m 700 %s)" % (hint, shlex.quote(root)))
    else:
        ws_ok = True
        mode = os.stat(root).st_mode & 0o777
        if mode & 0o077:
            rec(app, "workspace", WARN, "%s is mode %03o (other users can look inside)" % (root, mode),
                "chmod 700 %s" % shlex.quote(root))
        else:
            rec(app, "workspace", PASS, "%s (mode %03o)" % (root, mode))
    meta("ws_ok", "1" if ws_ok else "0")

    # mcp-registered
    exp = craftkit.expected_registration(app, workspace, prefix, lock)
    reg, reg_error = None, None
    try:
        reg = craftkit.registered(app, ns.config_dir or None)
    except craftkit.CraftKitError as exc:
        reg_error = str(exc)
    cfg = craftkit.config_file(ns.config_dir or None) if hasattr(craftkit, "config_file") else ".claude.json"
    if reg_error:
        rec(app, "mcp-registered", FAIL, reg_error, "fix the JSON in %s (Claude Code must be able to read it)" % cfg)
    elif reg is None and ns.mcp_skipped:
        rec(app, "mcp-registered", PASS, "not checked: installed with --no-mcp (re-run install.sh without it to register)")
    elif reg is None:
        rec(app, "mcp-registered", FAIL, "no user-scope MCP server named %s in %s" % (app, cfg), hint)
    elif reg == exp:
        meta("reg_ok", "1")
        rec(app, "mcp-registered", PASS, "user scope, fenced to %s" % root)
    else:
        extra = sorted(k for k in reg if k not in ("command", "args", "type"))
        if reg.get("type"):
            why = "registered as type %s, expected stdio" % reg["type"]
        elif reg.get("command") != exp["command"]:
            why = "command is %s, expected %s" % (reg.get("command") or "(none)", exp["command"])
        elif reg.get("args") != exp["args"]:
            why = "arguments are [%s], expected [%s]" % (_quote_argv(reg.get("args", [])), _quote_argv(exp["args"]))
        else:
            why = "has extra settings the kit does not set (%s), for example an environment override of the sandbox profile" % (
                "; ".join("%s: %s" % (k, _short(json.dumps(reg[k], sort_keys=True), 80)) for k in extra))
        rec(app, "mcp-registered", FAIL, "differs from the expected registration: " + why,
            hint + " (it replaces a differing registration)")

    # mcp-shadowed: only reported when found (local/project scope wins over user scope in that folder)
    try:
        others = [o for o in craftkit.shadowing([app], ns.config_dir or None)
                  if {k: v for k, v in o.items() if k not in ("app", "scope", "dir", "file")} != exp]
    except craftkit.CraftKitError:
        others = []
    for o in others[:3]:
        if o["scope"] == "local":
            fix = "cd %s && claude mcp remove %s -s local" % (shlex.quote(o["dir"]), app)
        else:
            fix = "remove %s from %s (or: cd %s && claude mcp remove %s -s project)" % (
                app, shlex.quote(o["file"]), shlex.quote(o["dir"]), app)
        rec(app, "mcp-shadowed", WARN, "also registered at %s scope for %s (%s); in that folder Claude Code uses it "
            "instead of the fenced server" % (o["scope"], o["dir"], _short(_quote_argv([o["command"]] + o["args"]), 80)), fix)
    if len(others) > 3:
        rec(app, "mcp-shadowed", WARN, "%d more %s registrations at local or project scope" % (len(others) - 3, app),
            "list them: claude mcp list (run in each project folder)")

    # fence-config
    fence_ok = False
    if fence in ("roots", "root"):
        flags = ["--automation-read-root", "--automation-write-root"] if fence == "roots" else ["--root"]
        if not cli_runs:
            rec(app, "fence-config", WARN, "not checked: the CLI is not usable, so %s cannot be confirmed" % " ".join(flags),
                "fix cli-installed first")
        else:
            rc, out, err = run([cli, "--help"], 30)
            text = out + "\n" + err
            missing = [f for f in flags if not _flag_advertised(text, f)]
            if rc == 124 or missing:
                rec(app, "fence-config", FAIL,
                    "%s --help does not advertise %s; this app will not be started unfenced" % (cli, " ".join(missing or flags)),
                    "install the pinned version: " + hint)
            else:
                fence_ok = True
                if reg is None or reg_error:
                    rec(app, "fence-config", PASS, "%s advertised (not registered, nothing else to compare)" % " ".join(flags))
                else:
                    # The CLIs honour the LAST occurrence of a fence flag (also --flag=value), so a
                    # second one anywhere moves the fence: each flag must appear exactly once.
                    args = reg.get("args", [])
                    dup = [f for f in flags if len(_flag_values(args, f)) > 1]
                    bad = [f for f in flags if _flag_values(args, f)[-1:] != [root]]
                    if dup:
                        rec(app, "fence-config", FAIL, "registration passes %s more than once; the app uses the last one (%s)"
                            % (" / ".join(dup), ", ".join(str(_flag_values(args, f)[-1]) for f in dup)), hint)
                    elif bad:
                        rec(app, "fence-config", FAIL, "registration does not pass %s %s" % (" / ".join(bad), root), hint)
                    else:
                        rec(app, "fence-config", PASS, "%s %s (config-only: the app enforces its own flag; no live probe)"
                            % (" ".join(flags), root))
    elif fence == "sandbox":
        kit_wrapper = os.path.join(ns.kit_dir, "bin", "craft-sandbox")
        kit_profile = os.path.join(ns.kit_dir, "share", "craft.sb")
        fence_ok = os.access(kit_wrapper, os.X_OK) and os.path.isfile(kit_profile) and os.access("/usr/bin/sandbox-exec", os.X_OK)
        if reg is None or reg_error:
            wrapper = os.path.join(prefix, "craft-sandbox")
            if os.access(wrapper, os.X_OK):
                rec(app, "fence-config", PASS, "wrapper %s present (not registered, nothing else to compare)" % wrapper)
            else:
                rec(app, "fence-config", FAIL, "sandbox wrapper missing: %s" % wrapper, hint)
        else:
            args = reg.get("args", [])
            command = reg.get("command", "")
            if os.path.basename(command) != "craft-sandbox":
                rec(app, "fence-config", FAIL, "registered command %s is not the craft-sandbox wrapper: the server runs unfenced" % command, hint)
            elif not args or args[0] != root:
                rec(app, "fence-config", FAIL, "craft-sandbox root is %s, expected %s" % (args[0] if args else "(none)", root), hint)
            elif not os.access(command, os.X_OK):
                rec(app, "fence-config", FAIL, "registered wrapper %s is missing or not executable" % command, hint)
            elif len(args) < 2 or args[1] != cli:
                rec(app, "fence-config", FAIL, "wrapper runs %s, expected %s" % (args[1] if len(args) > 1 else "(nothing)", cli), hint)
            elif reg.get("env"):
                rec(app, "fence-config", FAIL, "the registration sets environment variables (%s); CRAFT_SANDBOX_PROFILE "
                    "there would replace the kit's sandbox profile" % ", ".join(sorted(reg["env"])), hint)
            else:
                meta("wrapper", command)
                rec(app, "fence-config", PASS, "craft-sandbox root %s" % root)
        if not fence_ok:
            meta("fence_why", "this kit's bin/craft-sandbox, share/craft.sb or /usr/bin/sandbox-exec is missing")
    else:
        rec(app, "fence-config", FAIL, "unknown fence %r in the lock" % fence, "use the lock file shipped with the kit")
    meta("fence_ok", "1" if fence_ok else "0")
    return 0


# ---------------------------------------------------------------------------------------------
# probe-result: server-starts, tools-list, drift
# ---------------------------------------------------------------------------------------------

def _read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _tool_names(doc):
    tools = doc.get("tools") if isinstance(doc, dict) else doc
    names = set()
    for t in tools or []:
        if isinstance(t, dict) and t.get("name"):
            names.add(str(t["name"]))
        elif isinstance(t, str):
            names.add(t)
    return names


def _list(names, limit=8):
    names = sorted(names)
    more = len(names) - limit
    return ", ".join(names[:limit]) + (" (+%d more)" % more if more > 0 else "")


def cmd_probe_result(ns):
    app = ns.app
    lock = load_lock(ns.lock)
    version = lock["apps"][app].get("version", "")
    doc = None
    try:
        doc = json.loads(_read(ns.out)) if ns.rc == 0 else None
    except ValueError:
        doc = None
    via = " (%s)" % ns.via if ns.via else ""
    if not isinstance(doc, dict) or not isinstance(doc.get("server"), dict):
        why = _tail(_read(ns.err)) or ("probe exited %d" % ns.rc)
        rec(app, "server-starts", FAIL, "MCP server did not answer initialize/tools/list%s: %s" % (via, why),
            "see the full error: " + probe_command(app, ns.workspace, ns.prefix, ns.wrapper, ["list-tools"]))
        return 0
    server = doc["server"]
    srv_version = first_version(str(server.get("version", "")))
    rec(app, "server-starts", PASS, "%s %s%s" % (server.get("name", "?"), server.get("version", "?"), via))
    live = _tool_names(doc)
    if live:
        rec(app, "tools-list", PASS, "%d tools" % len(live))
    else:
        rec(app, "tools-list", FAIL, "the server lists no tools", installer_hint(os.path.dirname(_HERE), app))
    fc = doc.get("firstCall")
    if isinstance(fc, dict):
        what = "%s%s" % (fc.get("tool", "?"), " (%s)" % fc["note"] if fc.get("note") else "")
        fails = "; ".join(str(f) for f in fc.get("failures") or []) or "no detail"
        if fc.get("ok"):
            rec(app, "first-call", PASS, "a real call answered: " + fc.get("tool", "?"))
        elif fc.get("skipped"):
            rec(app, "first-call", WARN, "not run: " + fails, "run doctor.sh --smoke to drive the server for real")
        else:
            rec(app, "first-call", FAIL, "the server started but its first real call failed: %s: %s" % (what, _tail(fails)),
                "see docs/TROUBLESHOOTING.md; run doctor.sh --smoke --app %s for the full test" % app)

    problems = []
    if srv_version and srv_version != version:
        problems.append("server reports %s, the lock pins %s" % (srv_version, version))
    snap = None
    if not os.path.isfile(ns.snapshot):
        problems.append("no snapshot %s to compare tool names" % os.path.relpath(ns.snapshot, os.path.dirname(_HERE)))
    else:
        try:
            snap = _tool_names(load_json(ns.snapshot))
        except (OSError, ValueError) as exc:
            problems.append("snapshot unreadable: %s" % exc)
    if snap is not None:
        added, removed = live - snap, snap - live
        if added:
            problems.append("tools added since the snapshot: " + _list(added))
        if removed:
            problems.append("tools removed since the snapshot: " + _list(removed))
    if problems:
        rec(app, "drift", WARN, "; ".join(problems),
            "if the CLI is the pinned version, the kit's data is stale: report it (maintainers: make snapshot)")
    else:
        rec(app, "drift", PASS, "version %s, %d tool names match data/tools/%s.json" % (srv_version or version, len(live), app))
    return 0


# ---------------------------------------------------------------------------------------------
# fence-live: harmless probes through the sandbox wrapper
# ---------------------------------------------------------------------------------------------

def _pick_write_dir(root, workspace, home):
    for cand in (workspace, home, "/Users/Shared"):
        if not cand or not os.path.isdir(cand) or not os.access(cand, os.W_OK):
            continue
        real = os.path.realpath(cand)
        if _under(real, root) or any(_under(real, t) for t in SANDBOX_TEMP_WRITABLE):
            continue
        return cand
    return None


def _pick_read_file(root, home, candidates):
    for cand in candidates:
        if cand and os.path.isfile(cand) and _under(cand, home) and not _under(cand, root):
            return cand
    return None


_PROBE_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>local.craft-claude-kit.doctor-probe.%d</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
"""


def _launch_probe(wrapper, root, home, env):
    """Ask macOS, from inside the sandbox, to start a program (`open` of a bundle). LaunchServices
    starts it from launchd, outside this process tree, so it would not inherit the sandbox; the
    profile must refuse the request (it denies Mach lookups). The bundle is our own two-line shell
    script in a private temp folder that only writes a marker file next to itself; the folder is
    removed afterwards. (`open -a NoSuchApp` is NOT a valid test: it fails the same way either way.)
    Returns (refused|allowed|unclear, text)."""
    import shutil
    import tempfile
    import time
    base = tempfile.gettempdir()
    if _under(base, home) or _under(base, root):
        base = "/private/tmp"
    tmp = tempfile.mkdtemp(prefix="craft-doctor-launch.", dir=base)
    try:
        bundle = os.path.join(tmp, "CraftKitDoctorProbe.app")
        marker = os.path.join(tmp, "launched")
        os.makedirs(os.path.join(bundle, "Contents", "MacOS"))
        with open(os.path.join(bundle, "Contents", "Info.plist"), "w") as fh:
            fh.write(_PROBE_PLIST % os.getpid())
        exe = os.path.join(bundle, "Contents", "MacOS", "probe")
        with open(exe, "w") as fh:
            fh.write("#!/bin/sh\nprintf x > %s\n" % shlex.quote(marker))
        os.chmod(exe, 0o755)
        rc, out, err = run([wrapper, root, "/usr/bin/open", "-g", "-n", bundle], 20, env=env)
        deadline = time.monotonic() + (5 if rc == 0 else 1)
        while not os.path.exists(marker) and time.monotonic() < deadline:
            time.sleep(0.2)
        if os.path.exists(marker):
            return "allowed", "a program started through macOS (open) RAN OUTSIDE the sandbox"
        if rc != 0:
            # Only the sandbox's own refusal counts (B1-FENCE-1): `open` failing for another reason
            # proves nothing about the fence, so it is "unclear" (WARN), never a PASS.
            text = (err or "") + (out or "")
            if "kLSNoExecutableErr" in text or "-10827" in text or EPERM_TEXT in text:
                return "refused", "starting a program through macOS (open)"
            return "unclear", "start a program through macOS: open failed for another reason (%s)" % (_tail(err or out) or "exit %d" % rc)
        return "unclear", "start a program through macOS: open exited 0 but nothing ran (%s)" % (_tail(err or out) or "no output")
    except OSError as exc:
        return "unclear", "start a program through macOS: could not prepare the probe (%s)" % exc
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_fence_live(ns):
    app = ns.app
    workspace, prefix = abs_path(ns.workspace), abs_path(ns.prefix)
    root = os.path.join(workspace, app)
    home = abs_path(os.environ.get("HOME") or os.path.expanduser("~"))
    env = dict(os.environ)
    kit_wrapper = os.path.join(ns.kit_dir, "bin", "craft-sandbox")
    if ns.wrapper and os.access(ns.wrapper, os.X_OK):
        wrapper, how = ns.wrapper, "registered wrapper %s" % ns.wrapper
    elif os.access(os.path.join(prefix, "craft-sandbox"), os.X_OK):
        wrapper = os.path.join(prefix, "craft-sandbox")
        how = "installed wrapper %s" % wrapper
    else:
        wrapper = kit_wrapper
        env.setdefault("CRAFT_SANDBOX_PROFILE", os.path.join(ns.kit_dir, "share", "craft.sb"))
        how = "kit wrapper %s (not installed yet)" % wrapper
    hint = installer_hint(ns.kit_dir)

    rc, out, err = run([wrapper, root, "/usr/bin/true"], 15, env=env)
    if rc != 0:
        rec(app, "fence-live", FAIL, "the sandbox wrapper does not run (%s): %s" % (how, _tail(err or out) or "exit %d" % rc), hint)
        return 0

    refused, allowed, unclear = [], [], []

    wdir = _pick_write_dir(root, workspace, home)
    if wdir is None:
        unclear.append("write: no user-writable folder outside %s and the sandbox's temp areas to try" % root)
    else:
        target = os.path.join(wdir, ".craft-doctor-fence-probe-%d" % os.getpid())
        if os.path.lexists(target):
            unclear.append("write: %s already exists, not touched" % target)
        else:
            try:
                rc, out, err = run([wrapper, root, "/bin/sh", "-c", 'printf x > "$1"', "sh", target], 15, env=env)
            finally:
                created = os.path.lexists(target)
                if created:
                    try:
                        os.unlink(target)
                    except OSError:
                        pass
            if created or rc == 0:
                allowed.append("write to %s was ALLOWED" % wdir)
            elif EPERM_TEXT in err:
                refused.append("write to %s" % wdir)
            else:
                unclear.append("write to %s: %s" % (wdir, _tail(err or out) or "exit %d" % rc))

    rfile = _pick_read_file(root, home, ns.read_candidates)
    if rfile is None:
        unclear.append("read: no kit file under %s to try" % home)
    else:
        rc, out, err = run([wrapper, root, "/usr/bin/head", "-c", "1", rfile], 15, env=env)
        if rc == 0:
            allowed.append("read of %s was ALLOWED" % rfile)
        elif EPERM_TEXT in err:
            refused.append("read of %s" % rfile.replace(home, "~", 1))
        else:
            unclear.append("read of %s: %s" % (rfile, _tail(err or out) or "exit %d" % rc))

    host, port = NET_PROBE
    # -G 3: connect timeout (macOS nc); -w alone does not bound the connect.
    rc, out, err = run([wrapper, root, "/usr/bin/nc", "-v", "-z", "-G", "3", "-w", "3", host, port], 10, env=env)
    if EPERM_TEXT in err:
        refused.append("network connect to %s:%s" % (host, port))
    elif rc == 0 or "succeeded" in (out + err):
        allowed.append("network connect to %s:%s SUCCEEDED" % (host, port))
    else:
        allowed.append("network connect to %s:%s was not refused by the sandbox (%s)"
                       % (host, port, _tail(err or out) or ("timed out" if rc == 124 else "exit %d" % rc)))

    status, text = _launch_probe(wrapper, root, home, env)
    {"refused": refused, "allowed": allowed}.get(status, unclear).append(text)

    if allowed:
        rec(app, "fence-live", FAIL, "; ".join(allowed) + " (%s)" % how,
            "the sandbox profile is not in force: " + hint + ", then run doctor again")
    elif unclear:
        rec(app, "fence-live", WARN, "refused: %s; inconclusive: %s" % (", ".join(refused) or "nothing", "; ".join(unclear)),
            "check the paths above; the probes need a user-writable folder outside the workspace app folder")
    else:
        rec(app, "fence-live", PASS, "refused: %s" % ", ".join(refused))
    return 0


# ---------------------------------------------------------------------------------------------
# smoke-result
# ---------------------------------------------------------------------------------------------

def cmd_smoke_result(ns):
    app = ns.app
    doc = None
    try:
        doc = json.loads(_read(ns.out))
    except ValueError:
        doc = None
    steps = doc.get("steps") if isinstance(doc, dict) else None
    if ns.rc == 0 and isinstance(doc, dict) and doc.get("ok"):
        rec(app, "smoke", PASS, "%d steps passed" % len(steps or []))
        return 0
    detail = ""
    if isinstance(steps, list):
        for s in steps:
            if isinstance(s, dict) and not s.get("ok") and not s.get("skipped"):
                detail = "step %s %s%s: %s" % (s.get("step"), s.get("tool"),
                                               " (%s)" % s["note"] if s.get("note") else "",
                                               "; ".join(str(f) for f in s.get("failures") or []))
                break
    if not detail:
        detail = _tail(_read(ns.err)) or "probe exited %d" % ns.rc
    steps_file = ns.steps or os.path.join(os.path.dirname(_HERE), "tests", "smoke", app + ".json")
    rec(app, "smoke", FAIL, _short(detail, 300),
        "run it by hand: mkdir -p %s && %s" % (
            shlex.quote(os.path.join(ns.workspace or "WORKSPACE", app, "_doctor")),
            probe_command(app, ns.workspace, ns.prefix, ns.wrapper, ["run", steps_file])))
    return 0


# ---------------------------------------------------------------------------------------------
# skills
# ---------------------------------------------------------------------------------------------

def cmd_skills(ns):
    import craftkit
    apps = _apps_arg(ns.apps)
    names = ["craft-apps"] + ["craft-%s" % a for a in apps]
    skills_dir = os.path.join(abs_path(ns.claude_dir), "skills")
    hint = installer_hint(os.path.dirname(_HERE))
    present, missing = {}, []
    for n in names:
        path = os.path.join(skills_dir, n, "SKILL.md")
        if os.path.isfile(path):
            present[n] = _read(path)
        else:
            missing.append(n)
    if missing:
        rec("skills", "installed", FAIL, "%d of %d missing in %s: %s" % (len(missing), len(names), skills_dir, _list(missing, 14)), hint)
    else:
        rec("skills", "installed", PASS, "%d skills in %s" % (len(names), skills_dir))
    if not present:
        return 0

    leftovers = []
    for n, text in sorted(present.items()):
        toks = sorted(set(TOKEN_RE.findall(text)))
        if toks:
            leftovers.append("%s (%s)" % (n, ", ".join(toks)))
    if leftovers:
        rec("skills", "rendered", FAIL, "unreplaced tokens in: " + "; ".join(leftovers), hint)
    else:
        rec("skills", "rendered", PASS, "no {{...}} tokens left")

    source = ns.source if ns.source and os.path.isdir(ns.source) else None
    if source is None:
        rec("skills", "up-to-date", WARN, "not compared: the kit's skill sources were not found (the clone recorded at install time is gone)",
            "run doctor.sh from a clone of craft-claude-kit to compare")
    else:
        changed, nosrc = [], []
        for n, text in sorted(present.items()):
            src = os.path.join(source, n, "SKILL.md")
            if not os.path.isfile(src):
                nosrc.append(n)
                continue
            if craftkit.render_text(_read(src), ns.workspace, ns.kit_home) != text:
                changed.append(n)
        if changed:
            rec("skills", "up-to-date", WARN, "differ from this kit's version (edited or older): " + _list(changed, 14),
                hint + " (it backs up a changed SKILL.md before replacing it)")
        else:
            rec("skills", "up-to-date", PASS, "identical to the rendered sources in %s%s"
                % (source, "; no source for " + _list(nosrc) if nosrc else ""))

    live = {}
    for a in apps:
        path = os.path.join(ns.tools_dir or "", "probe-%s.json" % a)
        try:
            doc = load_json(path)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("server"), dict):
            live[a] = _tool_names(doc)
    if not live:
        rec("skills", "tool-refs", WARN, "not checked: no MCP server answered tools/list", "fix the server-starts lines above")
        return 0
    unknown, unchecked, checked = [], set(), 0
    for n, text in sorted(present.items()):
        for app, tool in sorted(set(TOOL_REF_RE.findall(text))):
            if app not in live:
                unchecked.add(app)
                continue
            checked += 1
            if tool not in live[app]:
                unknown.append("%s: mcp__%s__%s" % (n, app, tool))
    note = "; not checked (server not probed): %s" % ", ".join(sorted(unchecked)) if unchecked else ""
    if unknown:
        rec("skills", "tool-refs", WARN, "%d tool name(s) not offered by the live server: %s%s" % (len(unknown), _list(unknown, 6), note),
            "the skill and the installed app disagree; check cli-installed and drift above")
    elif checked:
        rec("skills", "tool-refs", PASS, "%d mcp__ tool references, all offered by the live servers%s" % (checked, note))
    else:
        rec("skills", "tool-refs", PASS, "the skills name no mcp__ tools of the probed servers%s" % note)
    return 0


# ---------------------------------------------------------------------------------------------
# hooks and legacy
# ---------------------------------------------------------------------------------------------

def _load_settings(path):
    """(data, error). Missing file -> ({}, None)."""
    if not os.path.exists(path):
        return {}, None
    try:
        data = load_json(path)
    except (OSError, ValueError) as exc:
        return None, "%s is not readable strict JSON: %s" % (path, exc)
    return (data if isinstance(data, dict) else {}), None


def _pretool_commands(data):
    """[(matcher, command)] for every PreToolUse command hook."""
    out = []
    hooks = data.get("hooks") if isinstance(data, dict) else None
    groups = hooks.get("PreToolUse") if isinstance(hooks, dict) else None
    for g in groups if isinstance(groups, list) else []:
        if not isinstance(g, dict):
            continue
        for h in g.get("hooks") if isinstance(g.get("hooks"), list) else []:
            if isinstance(h, dict) and isinstance(h.get("command"), str):
                out.append((str(g.get("matcher", "")), h["command"]))
    return out


def _split(command):
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _script_in(command, name):
    for tok in _split(command):
        if os.path.basename(tok) == name:
            return tok
    return None


def _matches(pattern, name):
    """Claude Code matchers: an exact name or a regex for the whole tool name."""
    if pattern == name:
        return True
    try:
        return re.fullmatch(pattern, name) is not None
    except re.error:
        return False


def _ask(stdout):
    try:
        doc = json.loads(stdout)
    except ValueError:
        return None
    hso = doc.get("hookSpecificOutput") if isinstance(doc, dict) else None
    return hso.get("permissionDecision") if isinstance(hso, dict) else None


def _payload(tool, tool_input, cwd):
    return json.dumps({"session_id": "craft-kit-doctor", "transcript_path": os.devnull, "cwd": cwd,
                       "permission_mode": "default", "hook_event_name": "PreToolUse",
                       "tool_name": tool, "tool_input": tool_input})


def _hook_test(script, workspace, cases, python=None):
    """cases: [(label, tool, input, expect_ask)]. Returns list of problems."""
    problems = []
    for label, tool, tool_input, want_ask in cases:
        rc, out, err = run([python or sys.executable, script, "--workspace", workspace], 15,
                           stdin_text=_payload(tool, tool_input, workspace))
        decision = _ask(out) if out.strip() else None
        if rc != 0:
            problems.append("%s: exit %d %s" % (label, rc, _tail(err)))
        elif decision == "deny":
            problems.append("%s: answered deny (the kit's hooks must only ask)" % label)
        elif want_ask and decision != "ask":
            problems.append("%s: expected ask, got %s" % (label, _short(out) or "no output"))
        elif not want_ask and out.strip():
            problems.append("%s: expected no output, got %s" % (label, _short(out)))
    return problems


def cmd_hooks(ns):
    apps = _apps_arg(ns.apps)
    workspace = abs_path(ns.workspace)
    hooks_dir = os.path.join(abs_path(ns.kit_home), "hooks")
    hint = installer_hint(os.path.dirname(_HERE))
    data, error = _load_settings(ns.settings)
    if error:
        rec("hooks", "settings", FAIL, error, "fix the JSON by hand; Claude Code ignores a broken settings file")
        return 0
    entries = _pretool_commands(data)
    sample_app = apps[0] if apps else "wordcraft"
    # The hook command is "python3 <script> ...": test with the python3 that PATH gives (what a
    # Claude Code started from this shell runs). "|| true" in that command hides a python3 that
    # cannot run the script, so this is the only place such a failure shows.
    import shutil
    python = shutil.which("python3")
    if not python:
        rec("hooks", "python3", FAIL, "no python3 on PATH: the hook commands (python3 <script>) cannot run, and "
            "'|| true' hides that, so both hooks are silently off", "xcode-select --install (installs python3)")
        python = sys.executable
    specs = [
        ("shell-guard", SHELL_GUARD, lambda m: all(_matches(m, t) for t in SHELL_GUARD_TOOLS),
         "matcher for " + ", ".join(SHELL_GUARD_TOOLS),
         [("asks on a direct CLI launch", "Bash", {"command": "%s-cli mcp" % sample_app, "description": "doctor"}, True),
          ("stays quiet on ls", "Bash", {"command": "ls -la", "description": "doctor"}, False)]),
        ("mcp-guard", MCP_GUARD,
         lambda m: all(_matches(m, "mcp__%s__save_document" % a) for a in apps) and not _matches(m, "Bash"),
         "matcher covering mcp__<app>__.* for every app",
         [("asks on a path outside the fence", "mcp__%s__open_document" % sample_app, {"path": "/etc/hosts"}, True),
          ("stays quiet on a read-only call", "mcp__%s__inspect_document" % sample_app, {}, False),
          # These two need hooks/risky-tools.json: an emptied or broken table fails here.
          ("asks on a print command (risk table)", "mcp__designcraft__execute", {"command": "file.print"}, True),
          ("asks on a save without a path (risk table)", "mcp__wordcraft__save_document", {}, True)]),
    ]
    for cid, name, matcher_ok, matcher_text, cases in specs:
        expected_script = os.path.join(hooks_dir, name)
        ours, others = [], []
        for matcher, command in entries:
            script = _script_in(command, name)
            if not script:
                continue
            if LEGACY_HOOK_PART in script:
                continue
            (ours if abs_path(script) == expected_script else others).append((matcher, command, script))
        if not ours:
            extra = "; another copy is registered: %s" % others[0][2] if others else ""
            if name == SHELL_GUARD and any(LEGACY_HOOK_PART in c for _m, c in entries):
                extra += "; the older hand-made shell guard is registered instead (the installer migrates it)"
            rec("hooks", cid, FAIL, "%s is not registered in %s%s" % (expected_script, ns.settings, extra), hint)
            continue
        problems = []
        matcher, command, script = ours[0]
        if not matcher_ok(matcher):
            problems.append("matcher %r is not a %s" % (matcher, matcher_text))
        ws = _flag_value(_split(command), "--workspace")
        if ws is None or abs_path(ws) != workspace:
            problems.append("registered for workspace %s, not %s" % (ws or "(none)", workspace))
        if len(ours) > 1:
            problems.append("registered %d times" % len(ours))
        if others:
            problems.append("another copy is also registered: %s" % others[0][2])
        if not os.path.isfile(expected_script):
            rec("hooks", cid, FAIL, "registered, but the script is missing: %s" % expected_script, hint)
            continue
        if problems:
            rec("hooks", cid, WARN, "; ".join(problems), hint)
        else:
            rec("hooks", cid, PASS, "PreToolUse %s -> %s"
                % (matcher if len(matcher) <= 30 else "matcher for all %d apps" % len(apps), expected_script))
        failures = _hook_test(expected_script, workspace, cases, python)
        if failures:
            rec("hooks", cid + "-test", FAIL, "; ".join(failures), hint)
        else:
            rec("hooks", cid + "-test", PASS, "canned payloads: " + ", ".join(c[0] for c in cases))
    _hooks_drift(hooks_dir, ns.receipt, hint)
    return 0


def _hooks_drift(hooks_dir, receipt_path, hint):
    """Hook files changed since install? The hooks do not guard Edit/Write, so this is how a
    rewritten guard or risk table shows (after the fact)."""
    try:
        doc = load_json(receipt_path) if receipt_path and os.path.isfile(receipt_path) else None
    except (OSError, ValueError):
        doc = None
    if not isinstance(doc, dict):
        return
    want = doc.get("hooksSha256")
    if not isinstance(want, dict) or not want:
        rec("hooks", "files", WARN, "the install receipt has no SHA-256 of the hook files (older install), so changes "
            "to them cannot be noticed", hint + " (records them)")
        return
    changed = []
    for name, sha in sorted(want.items()):
        path = os.path.join(hooks_dir, name)
        try:
            if _sha256(path) != sha:
                changed.append(name)
        except OSError:
            changed.append(name + " (missing)")
    if changed:
        rec("hooks", "files", WARN, "changed since install: %s in %s" % (", ".join(changed), hooks_dir),
            hint + " (restores the kit's copies)")
    else:
        rec("hooks", "files", PASS, "%d hook files unchanged since install" % len(want))


def cmd_legacy(ns):
    home = abs_path(ns.home)
    hint = (installer_hint(os.path.dirname(_HERE)) + ": it migrates the old setup (removes the old hook entry and"
            " the old files, and says so if it must keep one that something still uses)")
    found = 0
    for cid, path in (("old-hook-script", os.path.join(home, LEGACY_HOOK_PART)),
                      ("old-profile", os.path.join(home, ".local", "share", "craft-sandbox", "craft.sb"))):
        if os.path.lexists(path):
            found += 1
            rec("legacy", cid, WARN, "file from the old hand-made setup still present: %s" % path, hint)
    data, error = _load_settings(ns.settings)
    if not error:
        for matcher, command in _pretool_commands(data):
            if LEGACY_HOOK_PART in command:
                found += 1
                rec("legacy", "old-hook-entry", WARN, "old hook entry in %s: %s" % (ns.settings, _short(command)), hint)
    if not found:
        rec("legacy", "leftovers", PASS, "no files or hook entries from the old hand-made setup")
    return 0


# ---------------------------------------------------------------------------------------------
# gui
# ---------------------------------------------------------------------------------------------

def _receipt_gui(receipt, app):
    apps = receipt.get("apps") if isinstance(receipt, dict) else None
    entry = apps.get(app) if isinstance(apps, dict) else None
    val = entry.get("gui") if isinstance(entry, dict) else None
    if isinstance(val, dict):
        val = val.get("status") or val.get("action") or val.get("version") or val.get("path")
    if val in (None, False, "", 0):
        return False
    return str(val).strip().lower() not in ("no", "none", "false", "skip", "skipped", "absent", "not-installed",
                                            "not installed", "declined", "failed", "kept", "user", "existing")


def cmd_gui(ns):
    lock = load_lock(ns.lock)
    receipt = {}
    if ns.receipt and os.path.isfile(ns.receipt):
        try:
            receipt = load_json(ns.receipt)
        except (OSError, ValueError):
            receipt = {}
    dirs = [ns.gui_dir] if ns.gui_dir else []
    if not dirs and isinstance(receipt, dict) and receipt.get("guiDir"):
        dirs = [receipt["guiDir"]]
    if not dirs:
        dirs = ["/Applications", os.path.join(os.path.expanduser("~"), "Applications")]
    owned = [a for a in _apps_arg(ns.apps) if _receipt_gui(receipt, a)]
    apps = [a for a in _apps_arg(ns.apps) if ns.force or a in owned]
    if not apps:
        present = []
        for a in _apps_arg(ns.apps):
            bundle = (lock["apps"][a].get("gui") or {}).get("bundle", "")
            if bundle and any(os.path.isdir(os.path.join(d, bundle)) for d in dirs):
                present.append(bundle)
        note = ("; %d Craft desktop app(s) found in %s that the kit did not install and does not manage"
                % (len(present), " or ".join(dirs))) if present else ""
        rec("gui", "desktop-apps", PASS, "none installed by the kit%s (doctor.sh --gui checks them)" % note)
        return 0
    for app in apps:
        gui = lock["apps"][app].get("gui") or {}
        bundle, want = gui.get("bundle", ""), lock["apps"][app].get("version", "")
        path = next((os.path.join(d, bundle) for d in dirs if bundle and os.path.isdir(os.path.join(d, bundle))), None)
        if not path:
            rec("gui", app, FAIL, "%s not found in %s" % (bundle or "(no bundle in lock)", " or ".join(dirs)),
                installer_hint(os.path.dirname(_HERE), app) + " --gui")
            continue
        got = ""
        try:
            with open(os.path.join(path, "Contents", "Info.plist"), "rb") as fh:
                got = str(plistlib.load(fh).get("CFBundleShortVersionString", ""))
        except (OSError, ValueError, plistlib.InvalidFileException):
            got = ""
        rc, out, err = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path], 180)
        if rc != 0:
            why = "%s fails codesign --verify --deep --strict: %s" % (path, _tail(err or out) or "exit %d" % rc)
            src, _o, _e = run(["/usr/sbin/spctl", "--assess", "--type", "execute", path], 60)
            why += "; Gatekeeper (spctl) %s it" % ("accepts" if src == 0 else "does not accept")
            if app in owned:
                rec("gui", app, FAIL, why, "quit the app, move it to the Trash, then " + installer_hint(os.path.dirname(_HERE), app) + " --gui")
            else:
                rec("gui", app, WARN, why + " (not installed by the kit)",
                    "a strict check fails on extra Finder data or edits inside the bundle; for a clean copy, move it to the "
                    "Trash and " + installer_hint(os.path.dirname(_HERE), app) + " --gui")
        elif first_version(got) != want:
            rec("gui", app, WARN, "%s is version %s, the lock pins %s (signature ok)" % (path, got or "?", want),
                "the installer leaves a different version alone; replace it yourself if you want the pinned one")
        else:
            rec("gui", app, PASS, "%s %s, signature ok" % (path, got))
    return 0


# ---------------------------------------------------------------------------------------------
# report, run-timeout, json-get, abspath
# ---------------------------------------------------------------------------------------------

def _records(path):
    out = []
    for line in _read(path).splitlines():
        parts = line.split(US)
        if len(parts) != 5 or parts[0] == "META" or parts[2] not in (PASS, WARN, FAIL):
            continue
        out.append({"scope": parts[0], "id": parts[1], "status": parts[2], "detail": parts[3], "hint": parts[4]})
    return out


def cmd_report(ns):
    checks = _records(ns.infile)
    summary = {"pass": 0, "warn": 0, "fail": 0}
    for c in checks:
        summary[c["status"].lower()] += 1
    if ns.format == "json":
        sys.stdout.write(json.dumps({"summary": summary, "checks": checks}, indent=2, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write("%d pass, %d warn, %d fail\n" % (summary["pass"], summary["warn"], summary["fail"]))
    return 0


def cmd_run_timeout(ns):
    try:
        proc = subprocess.Popen(ns.argv, start_new_session=True)
    except OSError as exc:
        sys.stderr.write("%s: %s\n" % (ns.argv[0], exc))
        return 127

    def _stop(signum, _frame):
        _kill_group(proc)
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _stop)
    try:
        return proc.wait(timeout=ns.seconds)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        proc.wait()
        return 124


def cmd_json_get(ns):
    try:
        node = load_json(ns.file)
    except (OSError, ValueError) as exc:
        sys.stderr.write("doctor_checks: cannot read %s: %s\n" % (ns.file, exc))
        return 3
    for part in ns.path.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            return 1
    if isinstance(node, bool):
        print("true" if node else "false")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node, sort_keys=True))
    elif node is not None:
        print(node)
    return 0


def cmd_abspath(ns):
    print(abs_path(ns.path))
    return 0


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("doctor_checks: %s\n" % message)
        raise SystemExit(2)


def build_parser():
    p = _Parser(prog="doctor_checks.py", description="helpers for doctor.sh (see the module docstring)")
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("app-static")
    for opt in ("--app", "--workspace", "--prefix", "--kit-dir", "--kit-home"):
        s.add_argument(opt, required=True)
    s.add_argument("--lock")
    s.add_argument("--config-dir")
    s.add_argument("--receipt")
    s.add_argument("--mcp-skipped", action="store_true")
    s.set_defaults(func=cmd_app_static)

    s = sub.add_parser("probe-result")
    s.add_argument("--app", required=True)
    s.add_argument("--rc", type=int, required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--err", required=True)
    s.add_argument("--snapshot", required=True)
    s.add_argument("--lock")
    s.add_argument("--workspace")
    s.add_argument("--prefix")
    s.add_argument("--wrapper")
    s.add_argument("--via")
    s.set_defaults(func=cmd_probe_result)

    s = sub.add_parser("fence-live")
    for opt in ("--app", "--workspace", "--prefix", "--kit-dir", "--kit-home"):
        s.add_argument(opt, required=True)
    s.add_argument("--wrapper")
    s.add_argument("--read-candidate", dest="read_candidates", action="append", default=[])
    s.set_defaults(func=cmd_fence_live)

    s = sub.add_parser("smoke-result")
    s.add_argument("--app", required=True)
    s.add_argument("--rc", type=int, required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--err", required=True)
    s.add_argument("--workspace")
    s.add_argument("--prefix")
    s.add_argument("--steps")
    s.add_argument("--wrapper")
    s.set_defaults(func=cmd_smoke_result)

    s = sub.add_parser("skills")
    for opt in ("--claude-dir", "--workspace", "--kit-home", "--apps"):
        s.add_argument(opt, required=True)
    s.add_argument("--source")
    s.add_argument("--tools-dir")
    s.set_defaults(func=cmd_skills)

    s = sub.add_parser("hooks")
    for opt in ("--settings", "--kit-home", "--workspace", "--apps"):
        s.add_argument(opt, required=True)
    s.add_argument("--receipt")
    s.set_defaults(func=cmd_hooks)

    s = sub.add_parser("legacy")
    s.add_argument("--settings", required=True)
    s.add_argument("--home", required=True)
    s.set_defaults(func=cmd_legacy)

    s = sub.add_parser("gui")
    s.add_argument("--apps", required=True)
    s.add_argument("--lock")
    s.add_argument("--receipt")
    s.add_argument("--gui-dir")
    s.add_argument("--force", action="store_true")
    s.set_defaults(func=cmd_gui)

    s = sub.add_parser("report")
    s.add_argument("--in", dest="infile", required=True)
    s.add_argument("--format", choices=("json", "summary"), default="summary")
    s.set_defaults(func=cmd_report)

    s = sub.add_parser("run-timeout")
    s.add_argument("seconds", type=float)
    s.add_argument("argv", nargs=argparse.REMAINDER)
    s.set_defaults(func=cmd_run_timeout)

    s = sub.add_parser("json-get")
    s.add_argument("file")
    s.add_argument("path")
    s.set_defaults(func=cmd_json_get)

    s = sub.add_parser("abspath")
    s.add_argument("path")
    s.set_defaults(func=cmd_abspath)
    return p


def main(argv=None):
    ns = build_parser().parse_args(argv)
    if ns.cmd == "run-timeout":
        if ns.argv and ns.argv[0] == "--":
            ns.argv = ns.argv[1:]
        if not ns.argv:
            sys.stderr.write("doctor_checks: run-timeout needs a command\n")
            return 2
    try:
        return ns.func(ns)
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
