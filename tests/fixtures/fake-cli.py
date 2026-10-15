#!/usr/bin/env python3
"""Fixture stand-in for @APP@-cli. NOT a Craft app: it exists so the kit's installer and doctor
tests can run offline, in seconds, without the real (large) releases.

tests/fixtures/make_cli_zip.py fills the @TOKENS@ below and zips the result.

  <app>-cli --version     prints "<app>-cli <version>" (the format of the real CLIs)
  <app>-cli --help        advertises the confinement flag(s) of its fence mode (see FENCE)
  <app>-cli mcp [fence flags] [--author NAME]
                          a minimal MCP server on stdio (newline-delimited JSON-RPC 2.0):
                          initialize, ping, tools/list (echo, info), tools/call.
                          Fails closed like the kit expects: without its fence flag(s) it refuses to start.

Python 3.9+, standard library only.
"""
import json
import sys

APP = "@APP@"
VERSION = "@VERSION@"
FENCE = "@FENCE@"  # roots | root | sandbox
ADVERTISE = "@ADVERTISE@"  # "yes": --help lists the fence flags, "no": it does not (fail-closed tests)

NAME = APP + "-cli"
DEFAULT_PROTOCOL = "2024-11-05"

TOOLS = [
    {
        "name": "echo",
        "description": "Echo the given text back (fixture tool).",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "Text to echo."}},
            "required": ["text"],
        },
    },
    {
        "name": "info",
        "description": "Report the fixture app name, version and the folder(s) it was started with.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def help_text():
    lines = [
        "%s %s (fixture build for craft-claude-kit tests, not a real Craft app)" % (NAME, VERSION),
        "",
        "USAGE:",
        "  %s mcp [OPTIONS]      MCP server on stdio" % NAME,
        "  %s --version" % NAME,
        "  %s --help" % NAME,
    ]
    opts = []
    if ADVERTISE == "yes":
        if FENCE == "roots":
            opts.append("  --automation-read-root DIR    confine the files the server reads to DIR")
            opts.append("  --automation-write-root DIR   confine the files the server writes to DIR")
        elif FENCE == "root":
            opts.append("  --root DIR                    confine the files the server reads and writes to DIR")
    if APP == "wordcraft":
        opts.append("  --author NAME                 name used for tracked changes and comments")
    if opts:
        lines.append("")
        lines.append("MCP OPTIONS:")
        lines.extend(opts)
    return "\n".join(lines) + "\n"


def die(message, code=2):
    sys.stderr.write("%s: %s\n" % (NAME, message))
    sys.exit(code)


def parse_mcp(argv):
    roots = {"--automation-read-root": [], "--automation-write-root": [], "--root": []}
    author = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in roots or arg == "--author":
            if i + 1 >= len(argv):
                die("%s needs a value" % arg)
            if arg == "--author":
                author = argv[i + 1]
            else:
                roots[arg].append(argv[i + 1])
            i += 2
        else:
            die("unknown option for mcp: %s" % arg)
    if FENCE == "roots" and not (roots["--automation-read-root"] and roots["--automation-write-root"]):
        die("refusing to start without --automation-read-root and --automation-write-root")
    if FENCE == "root" and not roots["--root"]:
        die("refusing to start without --root")
    return roots, author


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def reply(msg_id, result):
    send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def fail(msg_id, code, message):
    send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": bool(is_error)}


def serve(roots, author):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            fail(None, -32700, "parse error")
            continue
        if not isinstance(msg, dict):
            fail(None, -32600, "invalid request")
            continue
        if "id" not in msg:
            continue  # notification (notifications/initialized, cancelled, ...): no reply
        msg_id = msg["id"]
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "initialize":
            reply(msg_id, {
                "protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": NAME, "version": VERSION},
                "instructions": "Fixture server for %s %s. It only echoes." % (APP, VERSION),
            })
        elif method == "ping":
            reply(msg_id, {})
        elif method == "tools/list":
            reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            if name == "echo":
                reply(msg_id, text_result("echo: %s" % args.get("text", "")))
            elif name == "info":
                reply(msg_id, text_result(json.dumps({
                    "app": APP, "version": VERSION, "fence": FENCE, "author": author,
                    "roots": {k: v for k, v in roots.items() if v},
                }, sort_keys=True)))
            else:
                reply(msg_id, text_result("unknown tool: %s" % name, is_error=True))
        else:
            fail(msg_id, -32601, "method not found: %s" % method)


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(help_text())
        return 0
    if argv[0] in ("--version", "-V", "version"):
        sys.stdout.write("%s %s\n" % (NAME, VERSION))
        return 0
    if argv[0] == "mcp":
        if len(argv) > 1 and argv[1] in ("-h", "--help"):
            sys.stdout.write(help_text())
            return 0
        roots, author = parse_mcp(argv[1:])
        try:
            serve(roots, author)
        except (BrokenPipeError, KeyboardInterrupt):
            pass
        return 0
    die("unknown command: %s" % argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
