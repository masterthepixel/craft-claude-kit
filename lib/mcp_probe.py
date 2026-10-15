#!/usr/bin/env python3
"""mcp_probe: a small stdio MCP client that starts a Craft MCP server exactly as it is registered
(same argv as craftkit.expected_registration) and drives it. Used by doctor.sh, the smoke tests and
by maintainers who regenerate data/tools/<app>.json.

  mcp_probe.py --app A --workspace W [--prefix P] [--timeout 60] list-tools [--full] [--first-call STEPS.json]
  mcp_probe.py --app A --workspace W call TOOL --args '{"k":"v"}' [--save-dir DIR] [--keep-binary]
  mcp_probe.py --app A --workspace W run STEPS.json [--keep-going] [--save-dir DIR]
  mcp_probe.py --app A --workspace W snapshot --out data/tools/A.json

Global options may be given before or after the subcommand: --app, --workspace, --prefix
(default ~/.local/bin), --timeout (seconds per call, default 60), --lock, --sandbox-profile,
--wrapper.

Transport: newline-delimited JSON-RPC 2.0 on the server's stdin/stdout (initialize, then the
notifications/initialized notification, then tools/list or tools/call). Server notifications,
non-JSON stdout noise and stderr output are tolerated. The server runs in its own process group,
which is killed on exit, error, timeout and on SIGINT/SIGTERM/SIGHUP, so no process is left behind.

Sandboxed apps (fence "sandbox") are started through THIS kit's bin/craft-sandbox with
CRAFT_SANDBOX_PROFILE pointing at this kit's share/craft.sb, so the probe works from a clean
checkout before install.sh has run (and from the KIT_HOME runtime copy, which mirrors the layout).
--wrapper PATH starts them through that wrapper instead (doctor.sh passes the installed
<prefix>/craft-sandbox, the program Claude Code really runs) and lets it find its own profile.
CLI binaries come from --prefix.

list-tools --first-call STEPS.json also runs the first step of STEPS.json in the same session and
reports it under "firstCall" (exit status stays 0); doctor.sh uses it so a server that starts but
dies on its first real call is caught without --smoke. A first step that uses {root}, {prev} or
{stepN} is not run (reported as skipped), so the call never names a file path.

Steps file (JSON array):
  {"tool": "...", "args": {...}, "expect": {...}, "note": "...", "timeout": 60}
  expect keys: isError (default false), contains / not_contains (string or list of strings, matched
  against the result text), json ({"path.to.field": value}, paths use dots and [n] indexes; a value
  may be an operator object such as {"$gt": 0}, {"$exists": true}, {"$contains": "x"},
  {"$regex": "..."}, {"$ne": v}, {"$gte"|"$lte"|"$lt": n}), image (true: at least one image block).
  Unknown expect keys fail the step. In strings of args and expect: {root} = absolute
  <workspace>/<app>; {prev} = text of the previous step; {prev.a.b} / {stepN.a.b} = value inside the
  JSON result of the previous / N-th (1-based) step. A string that is exactly one placeholder keeps
  the value's type.

Exit codes: 0 ok, 1 tool/protocol error, failed expectation, timeout or server died,
2 usage error (including a malformed steps file), 3 cannot start (CLI not installed, wrapper or
profile missing). Python 3.9+, stdlib only.
"""

import argparse
import atexit
import base64
import collections
import copy
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import craftkit  # noqa: E402

KIT_ROOT = os.path.dirname(_HERE)
PROTOCOL_VERSION = "2025-06-18"
DEFAULT_TIMEOUT = 60.0
MAX_PAGES = 50
MISSING = object()


class ProbeError(Exception):
    exit_code = 1


class UsageProblem(ProbeError):
    exit_code = 2


class StartError(ProbeError):
    exit_code = 3


class ServerExited(ProbeError):
    pass


class CallTimeout(ProbeError):
    pass


class RpcError(ProbeError):
    """A JSON-RPC error response (protocol-level failure)."""

    def __init__(self, code, message, data=None):
        ProbeError.__init__(self, "protocol error %s: %s" % (code, message))
        self.code, self.message, self.data = code, message, data

    def as_dict(self):
        out = {"code": self.code, "message": self.message}
        if self.data is not None:
            out["data"] = self.data
        return out


def _kit_version():
    try:
        with open(os.path.join(KIT_ROOT, "VERSION"), "r", encoding="utf-8") as fh:
            return fh.read().strip() or "0"
    except OSError:
        return "0"


# ---------------------------------------------------------------------------------------------
# launch description (argv comes from craftkit.expected_registration)
# ---------------------------------------------------------------------------------------------

class Launch(object):
    def __init__(self, argv, env, cwd, root, fence, cli):
        self.argv, self.env, self.cwd, self.root, self.fence, self.cli = argv, env, cwd, root, fence, cli


def app_root(workspace, app):
    return os.path.join(craftkit.abs_path(workspace), app)


def default_prefix():
    return os.path.join(os.path.expanduser("~"), ".local", "bin")


def build_launch(app, workspace, prefix=None, lock=None, profile=None, environ=None, wrapper=None):
    """argv/env/cwd to start `app` fenced to <workspace>/<app>. Raises StartError if the pieces are
    not there. The argv is expected_registration's, except that the wrapper is this kit's copy
    (or `wrapper`, which then finds its profile itself, as it does under Claude Code)."""
    prefix = prefix or default_prefix()
    lock = craftkit.load_lock(lock) if lock is None or isinstance(lock, str) else lock
    exp = craftkit.expected_registration(app, workspace, prefix, lock)
    argv = [exp["command"]] + list(exp["args"])
    env = dict(os.environ if environ is None else environ)
    root = app_root(workspace, app)
    fence = craftkit.lock_get(app, "fence", lock)
    cli = os.path.join(craftkit.abs_path(prefix), "%s-cli" % app)
    if not (os.path.isfile(cli) and os.access(cli, os.X_OK)):
        raise StartError("%s is not installed (missing executable %s); run ./install.sh" % (app, cli))
    if os.path.basename(exp["command"]) == craftkit.SANDBOX_WRAPPER and wrapper:
        if not (os.path.isfile(wrapper) and os.access(wrapper, os.X_OK)):
            raise StartError("sandbox wrapper missing or not executable: %s" % wrapper)
        argv[0] = os.path.abspath(wrapper)
    elif os.path.basename(exp["command"]) == craftkit.SANDBOX_WRAPPER:
        wrapper = os.path.join(KIT_ROOT, "bin", "craft-sandbox")
        prof = profile or os.path.join(KIT_ROOT, "share", "craft.sb")
        if not (os.path.isfile(wrapper) and os.access(wrapper, os.X_OK)):
            raise StartError("sandbox wrapper missing or not executable: %s" % wrapper)
        if not os.path.isfile(prof):
            raise StartError("sandbox profile missing: %s" % prof)
        if not os.access("/usr/bin/sandbox-exec", os.X_OK):
            raise StartError("/usr/bin/sandbox-exec not found (macOS only)")
        argv[0] = wrapper
        env["CRAFT_SANDBOX_PROFILE"] = os.path.abspath(prof)
    return Launch(argv, env, root, root, fence, cli)


def ensure_root(root):
    try:
        os.makedirs(root, mode=0o700, exist_ok=True)
    except OSError as exc:
        raise StartError("cannot create workspace folder %s: %s" % (root, exc))


# ---------------------------------------------------------------------------------------------
# MCP client
# ---------------------------------------------------------------------------------------------

_LIVE = []
_LIVE_LOCK = threading.Lock()


def _cleanup_all():
    with _LIVE_LOCK:
        clients = list(_LIVE)
    for c in clients:
        try:
            c.close()
        except Exception:
            pass


atexit.register(_cleanup_all)


class McpClient(object):
    def __init__(self, argv, env=None, cwd=None, timeout=DEFAULT_TIMEOUT, label="server"):
        self.argv, self.env, self.cwd = list(argv), env, cwd
        self.timeout = float(timeout)
        self.label = label
        self.proc = None
        self.pgid = None
        self.server_info = {}
        self.instructions = ""
        self.protocol_version = None
        self.capabilities = {}
        self.notifications = collections.deque(maxlen=200)
        self.noise = collections.deque(maxlen=20)
        self._stderr = collections.deque(maxlen=200)
        self._q = queue.Queue()
        self._next_id = 0
        self._closed = False
        self._threads = []

    # -- lifecycle ----------------------------------------------------------------------------

    def start(self):
        try:
            self.proc = subprocess.Popen(
                self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=self.env, cwd=self.cwd, start_new_session=True, close_fds=True)
        except OSError as exc:
            raise StartError("cannot start %s: %s" % (self.argv[0], exc))
        self.pgid = self.proc.pid
        with _LIVE_LOCK:
            _LIVE.append(self)
        for target in (self._pump_stdout, self._pump_stderr):
            t = threading.Thread(target=target, daemon=True)
            t.start()
            self._threads.append(t)
        return self

    def _pump_stdout(self):
        try:
            for raw in iter(self.proc.stdout.readline, b""):
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    self.noise.append(line[:300])
                    continue
                for msg in (obj if isinstance(obj, list) else [obj]):
                    if isinstance(msg, dict):
                        self._q.put(("msg", msg))
                    else:
                        self.noise.append(line[:300])
        except (OSError, ValueError):
            pass
        finally:
            self._q.put(("eof", None))

    def _pump_stderr(self):
        try:
            for raw in iter(self.proc.stderr.readline, b""):
                self._stderr.append(raw.decode("utf-8", "replace").rstrip()[:1000])
        except (OSError, ValueError):
            pass

    def stderr_tail(self, n=8):
        return "\n".join(list(self._stderr)[-n:])

    def _killpg(self, sig):
        if self.pgid is None:
            return False
        try:
            os.killpg(self.pgid, sig)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def _group_alive(self):
        if self.pgid is None:
            return False
        try:
            os.killpg(self.pgid, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def close(self, grace=2.0):
        """Stop the server and everything it started. Safe to call more than once. The server first
        gets `grace` seconds to exit on stdin EOF; then its whole process group is terminated."""
        if self._closed or self.proc is None:
            return
        self._closed = True
        proc = self.proc
        try:
            proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self._killpg(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if self._group_alive():
            self._killpg(signal.SIGTERM)
            deadline = time.monotonic() + 1.0
            while self._group_alive() and time.monotonic() < deadline:
                time.sleep(0.05)
            if self._group_alive():
                self._killpg(signal.SIGKILL)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self._killpg(signal.SIGKILL)
            proc.wait()
        for t in self._threads:
            t.join(timeout=1.0)
        for stream in (proc.stdout, proc.stderr):
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        with _LIVE_LOCK:
            if self in _LIVE:
                _LIVE.remove(self)

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.close()
        return False

    # -- transport ----------------------------------------------------------------------------

    def _exited_error(self, what):
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        code = self.proc.poll()
        if len(self._threads) > 1:
            self._threads[1].join(timeout=0.3)
        tail = self.stderr_tail()
        msg = "%s exited%s while waiting for %s" % (
            self.label, "" if code is None else " (code %s)" % code, what)
        if tail:
            msg += "\nserver stderr:\n" + tail
        if self.noise:
            msg += "\nnon-JSON stdout:\n" + "\n".join(list(self.noise)[:5])
        if "sandbox_apply" in tail:
            msg += "\nhint: sandbox-exec cannot nest; run this outside another sandbox."
        return ServerExited(msg)

    def _send(self, obj, what):
        data = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            raise self._exited_error(what)

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg, method)

    def _answer_server_request(self, msg):
        if msg.get("method") == "ping":
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": {}}
        else:
            reply = {"jsonrpc": "2.0", "id": msg["id"],
                     "error": {"code": -32601, "message": "Method not found"}}
        try:
            self._send(reply, "reply to %s" % msg.get("method"))
        except ServerExited:
            pass

    def request(self, method, params=None, timeout=None):
        """Send a request, return its `result`. Raises RpcError, CallTimeout or ServerExited."""
        timeout = self.timeout if timeout is None else float(timeout)
        self._next_id += 1
        rid = self._next_id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg, method)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            try:
                if remaining <= 0:
                    raise queue.Empty
                kind, obj = self._q.get(timeout=remaining)
            except queue.Empty:
                err = CallTimeout("%s: no answer to %s within %gs" % (self.label, method, timeout))
                self.close(grace=0.2)
                raise err
            if kind == "eof":
                raise self._exited_error(method)
            if "method" in obj:
                if "id" in obj:
                    self._answer_server_request(obj)
                else:
                    self.notifications.append(obj)
                continue
            if obj.get("id") != rid:
                continue
            if "error" in obj:
                err = obj["error"] if isinstance(obj["error"], dict) else {"message": str(obj["error"])}
                raise RpcError(err.get("code"), err.get("message", ""), err.get("data"))
            res = obj.get("result")
            return res if res is not None else {}

    # -- MCP operations -----------------------------------------------------------------------

    def initialize(self):
        res = self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "craft-claude-kit-probe", "version": _kit_version()},
        })
        self.protocol_version = res.get("protocolVersion")
        self.capabilities = res.get("capabilities") or {}
        info = res.get("serverInfo") or {}
        self.server_info = {"name": info.get("name", ""), "version": info.get("version", "")}
        self.instructions = res.get("instructions") or ""
        self.notify("notifications/initialized")
        return res

    def list_tools(self):
        tools, cursor = [], None
        for _ in range(MAX_PAGES):
            res = self.request("tools/list", {"cursor": cursor} if cursor else {})
            tools.extend(res.get("tools") or [])
            cursor = res.get("nextCursor")
            if not cursor:
                break
        return tools

    def call_tool(self, name, arguments=None, timeout=None):
        return self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)


def _install_signal_handlers():
    def _die(signum, _frame):
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, _die)
        except (ValueError, OSError):
            pass


# ---------------------------------------------------------------------------------------------
# result helpers
# ---------------------------------------------------------------------------------------------

def result_text(result):
    """Text of a tools/call result: its text blocks joined with newlines (structuredContent as
    JSON when there is no text block)."""
    parts = []
    for block in result.get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
        elif block.get("type") == "resource":
            res = block.get("resource") or {}
            if isinstance(res.get("text"), str):
                parts.append(res["text"])
    if not parts and result.get("structuredContent") is not None:
        return json.dumps(result["structuredContent"], ensure_ascii=False)
    return "\n".join(parts)


def result_images(result):
    return [b for b in (result.get("content") or [])
            if isinstance(b, dict) and b.get("type") == "image"]


def parse_json_text(text):
    try:
        return json.loads(text.strip())
    except ValueError:
        return MISSING


def result_json(result):
    sc = result.get("structuredContent")
    if sc is not None:
        return sc
    doc = parse_json_text(result_text(result))
    if doc is MISSING:
        for block in result.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                doc = parse_json_text(block.get("text") or "")
                if doc is not MISSING:
                    break
    return doc


_MIME_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
             "image/svg+xml": "svg", "audio/wav": "wav", "audio/mpeg": "mp3"}


def sanitize_result(result, save_dir=None, tool="result", keep_binary=False):
    """Copy of `result` where image/audio base64 payloads are replaced by a stub (optionally saved
    to save_dir) so a render tool does not flood the terminal."""
    out = copy.deepcopy(result)
    if keep_binary:
        return out
    for i, block in enumerate(out.get("content") or []):
        if not (isinstance(block, dict) and block.get("type") in ("image", "audio")
                and isinstance(block.get("data"), str)):
            continue
        try:
            raw = base64.b64decode(block["data"])
        except (ValueError, TypeError):
            raw = b""
        block["data"] = "<%d bytes elided>" % len(raw)
        block["bytes"] = len(raw)
        if save_dir and raw:
            os.makedirs(save_dir, mode=0o700, exist_ok=True)
            ext = _MIME_EXT.get(block.get("mimeType"), "bin")
            path = os.path.join(save_dir, "%s-%d.%s" % (re.sub(r"[^\w.-]", "_", tool), i, ext))
            with open(path, "wb") as fh:
                fh.write(raw)
            block["savedTo"] = path
    return out


def summarize_tools(tools, full=False):
    out = []
    for t in sorted(tools, key=lambda x: str(x.get("name", ""))):
        schema = t.get("inputSchema") if isinstance(t.get("inputSchema"), dict) else {}
        props = schema.get("properties") if isinstance(schema.get("properties"), dict) else {}
        req = schema.get("required") if isinstance(schema.get("required"), list) else []
        entry = {
            "name": t.get("name", ""),
            "description": t.get("description", "") or "",
            "params": list(props.keys()),
            "required": [str(r) for r in req],
        }
        if full:
            entry["inputSchema"] = schema
        out.append(entry)
    return out


def tools_report(client, full=False):
    return {
        "server": dict(client.server_info),
        "instructions": client.instructions,
        "tools": summarize_tools(client.list_tools(), full=full),
    }


# ---------------------------------------------------------------------------------------------
# JSON paths and expectations
# ---------------------------------------------------------------------------------------------

_PATH_PART = re.compile(r"\[(-?\d+)\]|([^.\[\]]+)")


def json_path(doc, path):
    """Value at a dotted path ("a.b.0.c" or "a.b[0].c"); "" and "$" mean the document itself.
    Returns MISSING if the path does not exist."""
    node = doc
    path = path.strip()
    if path in ("", "$"):
        return node
    if path.startswith("$."):
        path = path[2:]
    for idx, key in _PATH_PART.findall(path):
        if idx != "":
            i = int(idx)
            if isinstance(node, list) and -len(node) <= i < len(node):
                node = node[i]
            else:
                return MISSING
        elif isinstance(node, dict) and key in node:
            node = node[key]
        elif isinstance(node, list) and re.fullmatch(r"-?\d+", key) and -len(node) <= int(key) < len(node):
            node = node[int(key)]
        else:
            return MISSING
    return node


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _loose_equal(actual, expected):
    if isinstance(actual, bool) or isinstance(expected, bool):
        return isinstance(actual, bool) and isinstance(expected, bool) and actual == expected
    return actual == expected


def match_value(actual, expected):
    """(ok, reason). Plain values compare for equality; an object whose keys all start with "$" is
    a set of operators that must all hold."""
    if isinstance(expected, dict) and expected and all(str(k).startswith("$") for k in expected):
        for op, arg in expected.items():
            if op == "$exists":
                ok = (actual is not MISSING) == bool(arg)
            elif actual is MISSING:
                return False, "missing"
            elif op == "$ne":
                ok = not _loose_equal(actual, arg)
            elif op in ("$gt", "$gte", "$lt", "$lte"):
                if not (_is_number(actual) and _is_number(arg)):
                    return False, "%s needs numbers, got %r" % (op, actual)
                ok = {"$gt": actual > arg, "$gte": actual >= arg,
                      "$lt": actual < arg, "$lte": actual <= arg}[op]
            elif op == "$contains":
                ok = (arg in actual) if isinstance(actual, (str, list, dict)) else False
            elif op == "$regex":
                ok = isinstance(actual, str) and re.search(str(arg), actual) is not None
            else:
                return False, "unknown operator %s" % op
            if not ok:
                return False, "%s %r failed for %s" % (op, arg, _short(actual))
        return True, ""
    if actual is MISSING:
        return False, "missing"
    if _loose_equal(actual, expected):
        return True, ""
    return False, "expected %s, got %s" % (_short(expected), _short(actual))


def _short(v, n=120):
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, default=str)
    s = repr(s) if isinstance(v, str) else s
    return s if len(s) <= n else s[:n] + "..."


_EXPECT_KEYS = ("isError", "contains", "not_contains", "json", "image")


def check_expectations(result, expect):
    """List of failure strings (empty = the step passed)."""
    expect = {} if expect is None else expect
    unknown = [k for k in expect if k not in _EXPECT_KEYS]
    if unknown:
        return ["unknown expect key(s): %s (allowed: %s)" % (", ".join(unknown), ", ".join(_EXPECT_KEYS))]
    failures = []
    text = result_text(result)
    want_err = bool(expect.get("isError", False))
    got_err = bool(result.get("isError", False))
    if got_err != want_err:
        failures.append("isError is %s, expected %s%s" % (
            str(got_err).lower(), str(want_err).lower(),
            ": " + text[:300].replace("\n", " ") if got_err else ""))
    for key, negate in (("contains", False), ("not_contains", True)):
        if key not in expect:
            continue
        needles = expect[key] if isinstance(expect[key], list) else [expect[key]]
        for needle in needles:
            present = str(needle) in text
            if present == negate:
                failures.append("text %s %r%s" % (
                    "contains unwanted" if negate else "does not contain", str(needle),
                    "" if negate else " (text starts: %r)" % text[:160]))
    if expect.get("image") is not None:
        has = bool(result_images(result))
        if has != bool(expect["image"]):
            failures.append("image block %s, expected %s" % (
                "present" if has else "absent", "present" if expect["image"] else "absent"))
    if expect.get("json"):
        doc = result_json(result)
        if doc is MISSING:
            failures.append("result is not JSON, cannot check json expectations")
        else:
            for path, want in expect["json"].items():
                ok, why = match_value(json_path(doc, path), want)
                if not ok:
                    failures.append("json %s: %s" % (path, why))
    return failures


# ---------------------------------------------------------------------------------------------
# step templating
# ---------------------------------------------------------------------------------------------

_PLACEHOLDER = re.compile(r"\{(root|prev|step[0-9]+)((?:\.[^\s{}]+)?)\}")


class Context(object):
    """What placeholders can refer to: the app root and the results of the steps run so far."""

    def __init__(self, root):
        self.root = root
        self.history = []

    def record(self, text, doc):
        self.history.append({"text": text, "json": doc})

    def lookup(self, name, path):
        if name == "root":
            if path:
                raise UsageProblem("{root%s}: {root} takes no path" % path)
            return self.root
        if name == "prev":
            if not self.history:
                raise UsageProblem("{prev} used in the first step")
            entry = self.history[-1]
        else:
            n = int(name[4:])
            if not 1 <= n <= len(self.history):
                raise UsageProblem("{%s} refers to a step that has not run yet" % name)
            entry = self.history[n - 1]
        if not path:
            return entry["text"]
        if entry["json"] is MISSING:
            raise UsageProblem("{%s%s}: that step's result is not JSON" % (name, path))
        value = json_path(entry["json"], path[1:])
        if value is MISSING:
            raise UsageProblem("{%s%s}: no such field in that step's result" % (name, path))
        return value


def expand(value, ctx):
    """Apply placeholders to every string inside `value` (dict keys are left alone)."""
    if isinstance(value, str):
        whole = _PLACEHOLDER.fullmatch(value)
        if whole:
            return ctx.lookup(whole.group(1), whole.group(2))

        def sub(m):
            v = ctx.lookup(m.group(1), m.group(2))
            return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
        return _PLACEHOLDER.sub(sub, value)
    if isinstance(value, list):
        return [expand(v, ctx) for v in value]
    if isinstance(value, dict):
        return dict((k, expand(v, ctx)) for k, v in value.items())
    return value


def load_steps(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise UsageProblem("cannot read steps file %s: %s" % (path, exc))
    if isinstance(data, dict) and isinstance(data.get("steps"), list):
        data = data["steps"]
    if not isinstance(data, list) or not data:
        raise UsageProblem("steps file must be a non-empty JSON array: %s" % path)
    for i, step in enumerate(data, 1):
        if not isinstance(step, dict) or not isinstance(step.get("tool"), str) or not step["tool"]:
            raise UsageProblem("step %d: needs a string \"tool\"" % i)
        if not isinstance(step.get("args", {}), dict):
            raise UsageProblem("step %d: \"args\" must be an object" % i)
        if not isinstance(step.get("expect", {}), dict):
            raise UsageProblem("step %d: \"expect\" must be an object" % i)
        bad = [k for k in step if k not in ("tool", "args", "expect", "note", "timeout")]
        if bad:
            raise UsageProblem("step %d: unknown key(s): %s" % (i, ", ".join(bad)))
    return data


def _rpc_result(exc):
    """A tools/call-shaped result for a JSON-RPC error, so steps can expect it."""
    return {"isError": True, "protocolError": exc.as_dict(),
            "content": [{"type": "text", "text": "protocol error %s: %s" % (exc.code, exc.message)}]}


def run_steps(client, steps, root, keep_going=False, save_dir=None, log=None):
    """Run steps in the open session. Returns a report dict; report["ok"] is the verdict."""
    ctx = Context(root)
    report = {"ok": True, "steps": []}
    aborted = False
    for i, step in enumerate(steps, 1):
        entry = {"step": i, "tool": step["tool"], "note": step.get("note", "")}
        report["steps"].append(entry)
        if aborted:
            entry.update(ok=False, skipped=True, failures=["skipped after an earlier failure"])
            continue
        started = time.monotonic()
        try:
            args = expand(step.get("args", {}), ctx)
            expect = expand(step.get("expect", {}), ctx)
            try:
                result = client.call_tool(step["tool"], args, timeout=step.get("timeout"))
            except RpcError as exc:
                result = _rpc_result(exc)
        except UsageProblem as exc:
            entry.update(ok=False, failures=[str(exc)])
            result = None
        except (CallTimeout, ServerExited) as exc:
            entry.update(ok=False, failures=[str(exc)])
            result = None
            aborted = True
        entry["seconds"] = round(time.monotonic() - started, 2)
        if result is not None:
            text = result_text(result)
            doc = result_json(result)
            ctx.record(text, doc)
            failures = check_expectations(result, expect)
            entry.update(ok=not failures, isError=bool(result.get("isError", False)),
                         failures=failures, text=text[:400])
            if save_dir:
                sanitize_result(result, save_dir, "step%d-%s" % (i, step["tool"]))
        else:
            ctx.record("", MISSING)
        if not entry["ok"]:
            report["ok"] = False
            if not keep_going:
                aborted = True
        if log:
            line = "%s step %d %s%s" % ("ok  " if entry["ok"] else "FAIL", i, step["tool"],
                                         " - " + entry["note"] if entry["note"] else "")
            if not entry["ok"] and not entry.get("skipped"):
                line += ": " + "; ".join(entry["failures"])
            log(line)
    return report


# ---------------------------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------------------------

def emit(obj):
    data = json.dumps(obj, indent=2, ensure_ascii=False) + "\n"
    out = getattr(sys.stdout, "buffer", None)
    if out is None:
        sys.stdout.write(data)
        sys.stdout.flush()
        return
    out.write(data.encode("utf-8"))
    out.flush()


def _err(msg):
    sys.stderr.write("mcp_probe: %s\n" % msg)
    sys.stderr.flush()


def _write_json_atomic(path, obj):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def _open_session(ns):
    launch = build_launch(ns.app, ns.workspace, ns.prefix, ns.lock, ns.sandbox_profile, wrapper=ns.wrapper)
    ensure_root(launch.root)
    client = McpClient(launch.argv, env=launch.env, cwd=launch.cwd, timeout=ns.timeout, label=ns.app)
    client.start()
    try:
        client.initialize()
    except BaseException:
        client.close()
        raise
    return launch, client


def first_call(client, steps_path, root):
    """Run only the first step of a smoke file, in the open session, so a server that starts but
    crashes on its first real call (LightCraft under a too-strict sandbox) is caught without the
    full smoke test. Steps that touch disk ({root}) or chain ({prev}) are not run."""
    step = load_steps(steps_path)[0]
    text = json.dumps(step)
    if "{root}" in text or "{prev" in text or "{step" in text:
        return {"ok": False, "skipped": True, "tool": step["tool"],
                "failures": ["the first step uses {root}, {prev} or {stepN}; only --smoke runs it"]}
    return run_steps(client, [step], root)["steps"][0]


def _cmd_list_tools(ns):
    launch, client = _open_session(ns)
    try:
        report = tools_report(client, full=ns.full)
        if ns.first_call:
            report["firstCall"] = first_call(client, ns.first_call, launch.root)
        emit(report)
    finally:
        client.close()
    return 0


def _cmd_call(ns):
    try:
        args = json.loads(ns.args)
    except ValueError as exc:
        raise UsageProblem("--args is not valid JSON: %s" % exc)
    if not isinstance(args, dict):
        raise UsageProblem("--args must be a JSON object")
    args = expand(args, Context(app_root(ns.workspace, ns.app)))
    launch, client = _open_session(ns)
    try:
        try:
            result = client.call_tool(ns.tool, args)
        except RpcError as exc:
            emit({"error": exc.as_dict()})
            return 1
        emit(sanitize_result(result, ns.save_dir, ns.tool, ns.keep_binary))
        return 1 if result.get("isError") else 0
    finally:
        client.close()


def _cmd_run(ns):
    steps = load_steps(ns.steps)
    launch, client = _open_session(ns)
    try:
        report = run_steps(client, steps, launch.root, keep_going=ns.keep_going,
                           save_dir=ns.save_dir, log=_err)
    finally:
        client.close()
    report = dict(app=ns.app, server=client.server_info, **report)
    emit(report)
    return 0 if report["ok"] else 1


def _cmd_snapshot(ns):
    launch, client = _open_session(ns)
    try:
        report = tools_report(client)
    finally:
        client.close()
    _write_json_atomic(ns.out, report)
    _err("wrote %s (%d tools, %s %s)" % (ns.out, len(report["tools"]),
                                         report["server"].get("name"), report["server"].get("version")))
    return 0


def _common_args(p, suppress):
    d = argparse.SUPPRESS if suppress else None

    def add(*names, **kw):
        kw["default"] = d if suppress else kw.get("default")
        p.add_argument(*names, **kw)
    add("--app")
    add("--workspace")
    add("--prefix")
    add("--timeout", type=float, default=DEFAULT_TIMEOUT)
    add("--lock")
    add("--sandbox-profile", dest="sandbox_profile")
    add("--wrapper")


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("mcp_probe: %s\n" % message)
        raise SystemExit(2)


def build_parser():
    p = _Parser(prog="mcp_probe.py", description="Drive a Craft MCP server over stdio (see docstring).")
    _common_args(p, suppress=False)
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("list-tools")
    _common_args(s, suppress=True)
    s.add_argument("--full", action="store_true", help="include each tool's inputSchema")
    s.add_argument("--first-call", dest="first_call", metavar="STEPS.json",
                   help="also run the first step of STEPS.json in the same session (result in firstCall)")
    s.set_defaults(func=_cmd_list_tools)

    s = sub.add_parser("call")
    _common_args(s, suppress=True)
    s.add_argument("tool")
    s.add_argument("--args", default="{}")
    s.add_argument("--save-dir")
    s.add_argument("--keep-binary", action="store_true")
    s.set_defaults(func=_cmd_call)

    s = sub.add_parser("run")
    _common_args(s, suppress=True)
    s.add_argument("steps")
    s.add_argument("--keep-going", action="store_true")
    s.add_argument("--save-dir")
    s.set_defaults(func=_cmd_run)

    s = sub.add_parser("snapshot")
    _common_args(s, suppress=True)
    s.add_argument("--out", required=True)
    s.set_defaults(func=_cmd_snapshot)
    return p


def main(argv=None):
    parser = build_parser()
    ns = parser.parse_args(argv)
    if not ns.app or not ns.workspace:
        parser.error("--app and --workspace are required")
    if not ns.timeout or ns.timeout <= 0:
        parser.error("--timeout must be > 0")
    _install_signal_handlers()
    try:
        return ns.func(ns)
    except craftkit.CraftKitError as exc:
        _err(str(exc))
        return exc.exit_code
    except ProbeError as exc:
        _err(str(exc))
        return exc.exit_code
    except BrokenPipeError:
        return 0
    except KeyboardInterrupt:
        return 130
    finally:
        _cleanup_all()


if __name__ == "__main__":
    sys.exit(main())
