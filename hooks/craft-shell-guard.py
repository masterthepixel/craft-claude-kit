#!/usr/bin/env python3
"""craft-shell-guard: Claude Code PreToolUse hook for the tools that run shell commands or start apps
(Bash, mcp__terminal__run_in_terminal, Monitor: their `command`; mcp__computer-use__open_application:
its `app`, read as `open -a <app>`).

The 13 Craft apps are registered as MCP servers that are fenced to one workspace folder each. A Craft app
or CLI started from a shell is not fenced, so it would sidestep that. This hook turns it into a visible,
per-command decision: it ASKS before a Bash command would

  * run a Craft app or CLI (wordcraft, gridcraft, ... and their *-cli binaries, any path, any case),
    including behind wrappers (sudo env nohup time nice timeout gtimeout stdbuf unbuffer arch caffeinate
    xargs exec command ...), inside `bash|sh|zsh|dash -c` strings, `eval`, `$(...)`, backticks, `find -exec`;
  * `open` a Craft .app (or `open -a <Craft app>`);
  * hand a Craft binary or app name to an interpreter code string (python -c, node -e, ruby -e, perl -e,
    php -r), or to osascript / launchctl;
  * call craft-sandbox with a root that is not exactly <workspace>/<one Craft app folder> (also through a
    symlink), which would widen the fence;
  * run a Craft binary through a glob, a brace expansion or ${...} in the command word, decode text into
    a shell (base64 -d, xxd -r, printf escapes), or hand a Craft name to ionice, flock, script, parallel,
    ssh, expect or crontab; or load a LaunchAgents plist with launchctl;
  * cannot be checked in full: a command over 200000 characters, more than 200 nested $(...) bodies, or
    one that needs more than a fixed amount of parsing work asks instead of passing silently.

It never denies, and it fails open on errors: any parse problem or unexpected input exits 0 with no
output, so it cannot break normal shell use. It is a heuristic, not a security boundary: it reads the
command text; it follows a variable set earlier in the same command (W=wordcraft-cli; $W) but not one
from the environment, and it cannot see through aliases, scripts, copies or symlinks of a
binary, or `curl | sh`. The fences (built-in root flags, or the macOS sandbox) are the real control.

Usage (set up by the installer): craft-shell-guard.py --workspace /path/to/craft-workspace
Input: Claude Code hook JSON on stdin. Output: nothing, or one "ask" decision as JSON on stdout.
Python 3.9, standard library only.
"""
import fnmatch
import json
import os
import re
import sys

APPS = "word grid deck pdf photo vector design cad fig film effect light sound".split()
_ALT = "|".join(APPS)

BIN_RE = re.compile(r"^(?:%s)craft(?:-cli)?$" % _ALT, re.I)
APP_OPERAND_RE = re.compile(r"^(?:[\w-]*\.)*(?:%s)craft(?:\.app)?$" % _ALT, re.I)
APP_BUNDLE_RE = re.compile(r"(?:%s)craft\.app$" % _ALT, re.I)
MENTION_RE = re.compile(
    r"(?<![A-Za-z0-9])(?:%s)craft(?:(?:-cli|\.app)(?![A-Za-z0-9])|(?![A-Za-z0-9/-]))" % _ALT, re.I)
APP_DIRS = frozenset(a + "craft" for a in APPS)
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
HEREDOC_RE = re.compile(r"<<(?P<dash>-?)[ \t]*(?:['\"](?P<q>[^'\"\n]*)['\"]|(?P<w>[^\s;&|()<>'\"]+))")
INTERP_RE = re.compile(
    r"^(python[0-9.]*|pypy[0-9.]*|nodejs|node|bun|deno|ruby[0-9.]*|perl[0-9.]*|php[0-9.]*|lua[0-9.]*)$")
SHELLS = frozenset(["bash", "sh", "zsh", "dash", "ksh", "ash", "fish", "csh", "tcsh"])
KEYWORDS = frozenset(["!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "coproc"])
GLOB_CHARS_RE = re.compile(r"[*?\[]")
BRACE_RE = re.compile(r"\{([^{}]*,[^{}]*)\}")
CRAFT_NAMES = [a + "craft" + sfx for a in APPS for sfx in ("", "-cli", ".app")]
DECODERS = frozenset(["base64", "gbase64", "xxd", "openssl", "uudecode", "basenc"])
MENTION_WRAPPERS = frozenset(["ionice", "flock", "script", "parallel", "ssh", "expect", "crontab", "at", "batch"])
CODE_LETTERS = {"python": "c", "pypy": "c", "node": "ep", "nodejs": "ep", "bun": "ep",
                "ruby": "e", "perl": "eE", "php": "r", "lua": "e", "deno": ""}

MAX_DEPTH = 5
MAX_NESTED = 200
MAX_CHARS = 200000
# A fixed amount of work (one tick per command analysed and per 256 characters parsed), not a clock,
# so whether a long command asks does not depend on the machine's speed (B1-HOOK-1). About 1 MB of text.
MAX_TICKS = 4000


def _opts(short="", long="", pos=0, cluster=True):
    return {"short": set(short.split()), "long": set(long.split()), "pos": pos, "cluster": cluster}


WRAPPERS = {
    "sudo": _opts("-u -g -C -D -p -r -R -T -t -U",
                  "--user --group --close-from --chdir --prompt --role --type --other-user "
                  "--command-timeout --chroot"),
    "doas": _opts("-u -C"),
    "env": _opts("-u -C -P", "--unset --chdir --default-signal --ignore-signal --block-signal --argv0"),
    "nohup": _opts(),
    "time": _opts("-f -o", "--format --output"),
    "nice": _opts("-n", "--adjustment"),
    "timeout": _opts("-s -k", "--signal --kill-after", pos=1),
    "stdbuf": _opts("-i -o -e", "--input --output --error"),
    "unbuffer": _opts(),
    "arch": _opts("-arch -d -e", cluster=False),
    "caffeinate": _opts("-t -w"),
    "xargs": _opts("-n -I -L -P -s -E -a -d -J -R -S",
                   "--max-args --replace --max-lines --max-procs --max-chars --eof --arg-file --delimiter"),
    "exec": _opts("-a"),
    "command": _opts(),
    "builtin": _opts(),
    "setsid": _opts(),
    "taskpolicy": _opts("-d -g -c"),
    "sandbox-exec": _opts("-f -p -n -D", cluster=False),
}
ALIASES = {"gtimeout": "timeout", "gstdbuf": "stdbuf", "gnice": "nice", "genv": "env",
           "gnohup": "nohup", "gtime": "time"}


class _Stop(Exception):
    pass


class Ctx(object):
    def __init__(self, workspace, cwd):
        self.workspace = workspace
        self.cwd = cwd
        self.found = []
        self.ticks = 0
        # Shell variables assigned a Craft program name earlier in the command (W=wordcraft-cli).
        self.craft_vars = set()

    def add(self, kind, detail):
        self.found.append((kind, detail))

    def tick(self):
        self.ticks += 1
        if self.ticks > MAX_TICKS:
            raise _Stop()


# ---------------------------------------------------------------------------------------------- parsing

class Cmd(object):
    __slots__ = ("words", "stdin", "piped")

    def __init__(self):
        self.words = []
        self.stdin = []
        self.piped = False


class _Parser(object):
    """A small quote-aware shell tokenizer. It splits a script into simple commands (lists of words),
    collects command-substitution bodies, and attaches here-doc / here-string text to its command.
    Quoted text, comments and redirection targets are never mistaken for command words."""

    def __init__(self, text, ctx):
        self.s = text
        self.n = len(text)
        self.ctx = ctx
        self.cmds = []
        self.nested = []
        self.cur = Cmd()
        self.word = []
        self.in_word = False
        self.redir = False
        self.want_heredoc = None
        self.want_herestr = False
        self.heredocs = []

    def end_word(self):
        if not self.in_word:
            return
        w = "".join(self.word)
        self.word = []
        self.in_word = False
        if self.want_heredoc is not None:
            self.heredocs.append((w, self.want_heredoc, self.cur))
            self.want_heredoc = None
        elif self.want_herestr:
            self.cur.stdin.append(w)
            self.want_herestr = False
        elif self.redir:
            self.redir = False
        else:
            self.cur.words.append(w)

    def end_cmd(self):
        self.end_word()
        self.redir = False
        self.want_heredoc = None
        self.want_herestr = False
        if self.cur.words or self.cur.stdin:
            self.cmds.append(self.cur)
        self.cur = Cmd()

    def skip_heredoc_bodies(self, k, pending):
        """k is just after a newline. Skip the here-document bodies announced on the previous line."""
        s, n = self.s, self.n
        for delim, strip_tabs in pending:
            while k < n:
                e = s.find("\n", k)
                line = s[k:] if e < 0 else s[k:e]
                k = n if e < 0 else e + 1
                if (line.lstrip("\t") if strip_tabs else line) == delim:
                    break
        return k

    def balanced(self, j):
        """j is just after an opening '('. Returns (body, index after the matching ')').
        Quotes and here-documents inside the parentheses are skipped, so an apostrophe in a commit message
        written as $(cat <<'EOF' ... EOF) does not hide the closing parenthesis."""
        s, n = self.s, self.n
        depth = 1
        k = j
        pending = []
        while k < n:
            c = s[k]
            if c == "\\":
                k += 2
                continue
            if c == "'":
                e = s.find("'", k + 1)
                k = n if e < 0 else e + 1
                continue
            if c == '"':
                k += 1
                while k < n and s[k] != '"':
                    k += 2 if s[k] == "\\" else 1
                k += 1
                continue
            if c == "\n" and pending:
                k = self.skip_heredoc_bodies(k + 1, pending)
                pending = []
                continue
            if c == "<" and s.startswith("<<", k) and not s.startswith("<<<", k):
                m = HEREDOC_RE.match(s, k)
                if m:
                    pending.append((m.group("q") if m.group("q") is not None else m.group("w"),
                                    bool(m.group("dash"))))
                    k = m.end()
                    continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return s[j:k], k + 1
            k += 1
        return s[j:], n

    def backtick(self, j):
        """j is just after an opening backtick. Returns (body, index after the closing backtick)."""
        s, n = self.s, self.n
        k = j
        while k < n and s[k] != "`":
            k += 2 if s[k] == "\\" else 1
        return s[j:k].replace("\\`", "`"), min(k + 1, n)

    def substitution(self, body):
        self.nested.append(body)
        return "\x01" + body + "\x02"

    def dquote(self, i):
        s, n = self.s, self.n
        j = i + 1
        buf = []
        while j < n and s[j] != '"':
            c = s[j]
            if c == "\\" and j + 1 < n:
                nxt = s[j + 1]
                if nxt == "\n":
                    pass
                elif nxt in '"\\$`':
                    buf.append(nxt)
                else:
                    buf.append("\\" + nxt)
                j += 2
            elif c == "$" and s.startswith("$(", j):
                body, j = self.balanced(j + 2)
                buf.append(self.substitution(body))
            elif c == "`":
                body, j = self.backtick(j + 1)
                buf.append(self.substitution(body))
            else:
                buf.append(c)
                j += 1
        self.word.append("".join(buf))
        self.in_word = True
        return j + 1

    def read_heredocs(self, i):
        s, n = self.s, self.n
        for delim, strip_tabs, owner in self.heredocs:
            lines = []
            while i < n:
                e = s.find("\n", i)
                line = s[i:] if e < 0 else s[i:e]
                i = n if e < 0 else e + 1
                check = line.lstrip("\t") if strip_tabs else line
                if check == delim:
                    break
                lines.append(line)
            owner.stdin.append("\n".join(lines))
        self.heredocs = []
        return i

    def parse(self):
        s, n = self.s, self.n
        i = 0
        steps = 0
        while i < n:
            steps += 1
            if steps & 255 == 0:
                self.ctx.tick()
            c = s[i]
            if c == "\\":
                if i + 1 < n and s[i + 1] != "\n":
                    self.word.append(s[i + 1])
                    self.in_word = True
                i += 2
            elif c == "'":
                e = s.find("'", i + 1)
                if e < 0:
                    e = n
                self.word.append(s[i + 1:e])
                self.in_word = True
                i = e + 1
            elif c == '"':
                i = self.dquote(i)
            elif c == "$" and s.startswith("$(", i):
                body, i = self.balanced(i + 2)
                self.word.append(self.substitution(body))
                self.in_word = True
            elif c == "$" and i + 1 < n and s[i + 1] == "'":
                e = i + 2
                while e < n and s[e] != "'":
                    e += 2 if s[e] == "\\" else 1
                self.word.append(ansi_c(s[i + 2:e]))
                self.in_word = True
                i = e + 1
            elif c == "$" and i + 1 < n and s[i + 1] == '"':
                i += 1
            elif c == "`":
                body, i = self.backtick(i + 1)
                self.word.append(self.substitution(body))
                self.in_word = True
            elif c in "<>" and s.startswith("(", i + 1):
                body, i = self.balanced(i + 2)
                self.word.append(self.substitution(body))
                self.in_word = True
            elif c in "<>" or (c == "&" and s.startswith(">", i + 1)):
                if self.in_word and "".join(self.word).isdigit():
                    self.word = []
                    self.in_word = False
                else:
                    self.end_word()
                j = i
                while j < n and s[j] in "<>&":
                    j += 1
                if j < n and s[j] == "|" and s[j - 1] == ">":
                    j += 1
                if j < n and s[j] == "-" and s[i:j] == "<<":
                    j += 1
                op = s[i:j]
                i = j
                if op in ("<<", "<<-"):
                    self.want_heredoc = op == "<<-"
                elif op == "<<<":
                    self.want_herestr = True
                else:
                    self.redir = True
            elif c == "#" and not self.in_word:
                e = s.find("\n", i)
                i = n if e < 0 else e
            elif c in " \t\r":
                self.end_word()
                i += 1
            elif c == "\n":
                self.end_cmd()
                i = self.read_heredocs(i + 1) if self.heredocs else i + 1
            elif c == "|" and not s.startswith("||", i):
                self.end_cmd()
                self.cur.piped = True
                i += 2 if s.startswith("|&", i) else 1
            elif c in ";&|()":
                self.end_cmd()
                i += 1
            else:
                self.word.append(c)
                self.in_word = True
                i += 1
        self.end_cmd()
        for delim, strip_tabs, owner in self.heredocs:
            owner.stdin.append("")
        return self.cmds, self.nested


def parse(text, ctx):
    return _Parser(text, ctx).parse()


_SIMPLE_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "e": "\x1b",
               "E": "\x1b", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def ansi_c(body):
    """Decode $'...' (and printf / echo -e) escapes: \\n \\xHH \\NNN \\uHHHH ... Unknown escapes stay."""
    out = []
    i, n = 0, len(body)
    while i < n:
        c = body[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in _SIMPLE_ESC:
            out.append(_SIMPLE_ESC[nxt])
            i += 2
        elif nxt == "x":
            m = re.match(r"[0-9A-Fa-f]{1,2}", body[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
            else:
                out.append("\\x")
                i += 2
        elif nxt in "uU":
            m = re.match(r"[0-9A-Fa-f]{1,%d}" % (4 if nxt == "u" else 8), body[i + 2:])
            if m:
                try:
                    out.append(chr(int(m.group(0), 16)))
                except ValueError:
                    pass
                i += 2 + len(m.group(0))
            else:
                out.append("\\" + nxt)
                i += 2
        elif nxt in "01234567":
            m = re.match(r"0?[0-7]{1,3}", body[i + 1:])
            out.append(chr(int(m.group(0), 8) & 0xFF))
            i += 1 + len(m.group(0))
        else:
            out.append("\\" + nxt)
            i += 2
    return "".join(out)


def brace_expand(word, limit=64):
    """Simple brace expansion ({a,b}c -> ac bc), enough to see a Craft name assembled from braces."""
    out, todo = [], [word]
    while todo and len(out) + len(todo) <= limit:
        w = todo.pop()
        m = BRACE_RE.search(w)
        if not m:
            out.append(w)
            continue
        for alt in m.group(1).split(","):
            todo.append(w[:m.start()] + alt + w[m.end():])
    return out


def craft_pattern(word):
    """A command word that is not literal (glob, braces, ${...}) but can name a Craft binary or app."""
    base = basename(word)
    if "{" in base and "," in base:
        if any(BIN_RE.match(basename(x)) or APP_BUNDLE_RE.search(x) for x in brace_expand(word)):
            return True
    if GLOB_CHARS_RE.search(base):
        try:
            rx = re.compile(fnmatch.translate(base), re.I)
            if any(rx.match(name) for name in CRAFT_NAMES):
                return True
        except re.error:
            pass
    if "$" in base:
        literal = re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$.", "", base)
        if MENTION_RE.search(base) or re.search(r"craft", literal, re.I):
            return True
    return False


# ---------------------------------------------------------------------------------------------- analysis

def basename(token):
    return token.rstrip("/").rsplit("/", 1)[-1]


def expand_path(token, cwd):
    """Expand ~, $HOME, ${HOME} and relative paths. None when the text cannot be resolved statically."""
    if "\x01" in token or "\x02" in token:
        return None
    home = os.path.expanduser("~")
    if token == "~" or token.startswith("~/"):
        token = home + token[1:]
    elif token == "$HOME" or token.startswith("$HOME/"):
        token = home + token[5:]
    elif token == "${HOME}" or token.startswith("${HOME}/"):
        token = home + token[7:]
    if "$" in token or token.startswith("~"):
        return None
    if not os.path.isabs(token):
        if not cwd or not os.path.isabs(cwd):
            return None
        token = os.path.join(cwd, token)
    return os.path.normpath(token)


def workspace_variants(workspace):
    base = os.path.normpath(os.path.expanduser(workspace))
    out = [base]
    try:
        real = os.path.realpath(base)
    except OSError:
        real = base
    if real != base:
        out.append(real)
    return out


def sandbox_root_ok(root, ctx):
    path = expand_path(root, ctx.cwd)
    if path is None:
        return False
    parent, name = os.path.split(path)
    if name not in APP_DIRS:
        return False
    variants = workspace_variants(ctx.workspace)
    ok = os.path.normpath(parent) in variants
    if not ok:
        try:
            ok = os.path.realpath(parent) in variants
        except OSError:
            ok = False
    if not ok:
        return False
    # craft-sandbox resolves ROOT with cd -P: an app folder that is a symlink would carry the fence
    # wherever the link points.
    try:
        real = os.path.realpath(path)
    except OSError:
        return False
    rparent, rname = os.path.split(real)
    return rname in APP_DIRS and (rparent in variants or os.path.realpath(rparent) in variants)


def check_sandbox(args, ctx):
    if not args:
        return
    root = args[0]
    if root in ("-h", "--help"):
        return
    if root.startswith("-") or not sandbox_root_ok(root, ctx):
        shown = root if len(root) <= 80 else root[:77] + "..."
        ctx.add("sandbox", shown)


def unwrap(name, args, ctx):
    """Strip a wrapper command's own options and return the words of the command it runs (maybe [])."""
    spec = WRAPPERS[name]
    letters = set(o[1] for o in spec["short"] if len(o) == 2)
    skip_pos = spec["pos"]
    j = 0
    n = len(args)
    while j < n:
        t = args[j]
        if t == "--":
            j += 1
            break
        if ENV_ASSIGN_RE.match(t):
            j += 1
            continue
        if t.startswith("--") and len(t) > 2:
            opt, eq, val = t.partition("=")
            if name == "env" and opt == "--split-string":
                text = val if eq else (args[j + 1] if j + 1 < n else "")
                return split_words(text, ctx) + args[j + (1 if eq else 2):]
            j += 1 if (eq or opt not in spec["long"]) else 2
            continue
        if t.startswith("-") and len(t) > 1:
            if name == "command" and re.match(r"^-[a-zA-Z]*[vV]", t):
                return []
            if name == "env" and t.startswith("-S"):
                # -S 'cmd args' and the attached form -S'cmd args' (R1-HOOK-6).
                if len(t) > 2:
                    return split_words(t[2:], ctx) + args[j + 1:]
                text = args[j + 1] if j + 1 < n else ""
                return split_words(text, ctx) + args[j + 2:]
            if t in spec["short"]:
                j += 2
            elif spec["cluster"] and len(t) > 2 and re.match(r"^-[A-Za-z]+$", t) and t[-1] in letters:
                j += 2
            else:
                j += 1
            continue
        if skip_pos > 0:
            skip_pos -= 1
            j += 1
            continue
        break
    return args[j:]


def split_words(text, ctx):
    cmds, _ = parse(text, ctx)
    return cmds[0].words if cmds else []


def shell_string(args):
    """The script text given to `sh -c`, or None. Understands clustered flags such as -lc and -ec."""
    j = 0
    n = len(args)
    while j < n:
        t = args[j]
        if t in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            j += 2
        elif t.startswith("--") or t.startswith("+"):
            j += 1
        elif t.startswith("-") and len(t) > 1:
            if "c" in t[1:]:
                return args[j + 1] if j + 1 < n else None
            j += 1
        else:
            return None
    return None


def code_strings(kind, args):
    """Code passed on the command line to an interpreter (-c, -e, -r, --eval ...)."""
    if kind == "deno":
        return args[1:] if args and args[0] == "eval" else []
    letters = CODE_LETTERS[kind]
    out = []
    for j, t in enumerate(args):
        if t == "--":
            break
        if t.startswith("--"):
            opt, eq, val = t.partition("=")
            if opt in ("--eval", "--print", "--command", "--execute"):
                if eq:
                    out.append(val)
                elif j + 1 < len(args):
                    out.append(args[j + 1])
        elif t.startswith("-") and len(t) > 1 and letters:
            body = t[1:]
            if re.match(r"^[A-Za-z]+$", body) and body[-1] in letters:
                if j + 1 < len(args):
                    out.append(args[j + 1])
            else:
                m = re.match(r"^-[A-Za-z]*?([%s])(.+)$" % letters, t, re.S)
                if m:
                    out.append(m.group(2))
    return out


def open_hits(args):
    reveal = False
    hits = []
    operands = []
    j = 0
    n = len(args)
    while j < n:
        t = args[j]
        if t == "--args":
            break
        if t == "--reveal":
            reveal = True
        elif t.startswith("--"):
            pass
        elif t.startswith("-") and len(t) > 1:
            flags = t[1:]
            if "R" in flags:
                reveal = True
            if flags[-1] in "ab" and j + 1 < n:
                app = basename(args[j + 1])
                if APP_OPERAND_RE.match(app):
                    hits.append(app)
                j += 1
        else:
            operands.append(t)
        j += 1
    if reveal:
        return []
    for op in operands:
        b = basename(op)
        if APP_BUNDLE_RE.search(b):
            hits.append(b)
    return hits


VAR_REF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
DECLARE = frozenset(["export", "declare", "typeset", "local", "readonly"])


def note_assignments(words, ctx):
    """Remember variables set to a Craft program name, so a later $W in the command word asks."""
    for w in words:
        if not ENV_ASSIGN_RE.match(w):
            continue
        name, _, value = w.partition("=")
        if MENTION_RE.search(value) or BIN_RE.match(basename(value)):
            ctx.craft_vars.add(name.rstrip("+"))


def xargs_placeholder(args):
    """The replace string of xargs -I/-J/-i/--replace, or None."""
    for j, t in enumerate(args):
        if t in ("-I", "-J") and j + 1 < len(args):
            return args[j + 1]
        if (t.startswith("-I") or t.startswith("-J")) and len(t) > 2:
            return t[2:]
        if t == "-i" or t == "--replace":
            return "{}"
        if t.startswith("-i") and len(t) > 2:
            return t[2:]
        if t.startswith("--replace="):
            return t.split("=", 1)[1] or "{}"
    return None


def xargs_hits(args, stdin, ctx):
    """xargs runs words it reads from its input: ask when that input names a Craft program, or when the
    command it runs takes its program name from the input (xargs -I{} sh -c '{} --version')."""
    if any(MENTION_RE.search(t) for t in stdin):
        ctx.add("mention", "xargs (from its input)")
    ph = xargs_placeholder(args)
    if not ph:
        return
    rest = unwrap("xargs", args, ctx)
    target = rest
    if rest and basename(rest[0]).lower() in SHELLS:
        text = shell_string(rest[1:])
        target = split_words(text, ctx) if text is not None else []
    while target and ENV_ASSIGN_RE.match(target[0]):
        target = target[1:]
    if target and ph in target[0]:
        ctx.add("mention", "xargs, which takes the program name from its input")


def analyze_cmd(words, stdin, ctx, depth):
    ctx.tick()
    i = 0
    while i < len(words) and (ENV_ASSIGN_RE.match(words[i]) or words[i] in KEYWORDS):
        i += 1
    if i >= len(words):
        note_assignments(words, ctx)
        return
    prog = words[i]
    args = words[i + 1:]
    base = basename(prog)
    low = base.lower()
    if low in DECLARE:
        note_assignments(args, ctx)

    if depth > MAX_DEPTH:
        if MENTION_RE.search(" ".join(words)):
            ctx.add("mention", "a deeply nested command")
        return

    if "\x01" in prog:
        if MENTION_RE.search(prog):
            ctx.add("mention", "a computed command name")
        return

    if BIN_RE.match(base):
        ctx.add("run", base)
        return

    if craft_pattern(prog):
        ctx.add("run", "%s (a pattern or variable that can name a Craft binary)" % base[:60])
        return

    if "$" in prog and any(v in ctx.craft_vars for v in VAR_REF_RE.findall(prog)):
        ctx.add("run", "%s (a variable set to a Craft program earlier in the command)" % base[:60])
        return

    low = ALIASES.get(low, low)

    if low == "craft-sandbox":
        check_sandbox(args, ctx)
        return

    if low == "xargs":
        xargs_hits(args, stdin, ctx)

    if low in WRAPPERS:
        rest = unwrap(low, args, ctx)
        if rest and re.search(r"\s", rest[0]):
            analyze_script(" ".join(rest), ctx, depth + 1)
        elif rest:
            analyze_cmd(rest, stdin, ctx, depth + 1)
        return

    if low in SHELLS:
        text = shell_string(args)
        if text is not None:
            analyze_script(text, ctx, depth + 1)
        elif not [a for a in args if not a.startswith("-") and not a.startswith("+")]:
            for body in stdin:
                analyze_script(body, ctx, depth + 1)
        return

    if low == "eval":
        joined = " ".join(args)
        if "\x01" in joined and re.search(r"\b(base64|xxd|openssl|uudecode|basenc)\b", joined):
            ctx.add("decode", "eval of decoded text")
        analyze_script(joined, ctx, depth + 1)
        return

    if low == "su":
        for j, t in enumerate(args):
            if t in ("-c", "--command") and j + 1 < len(args):
                analyze_script(args[j + 1], ctx, depth + 1)
            elif t.startswith("--command="):
                analyze_script(t.split("=", 1)[1], ctx, depth + 1)
        return

    if low == "watch":
        rest = []
        j = 0
        while j < len(args):
            t = args[j]
            if t in ("-n", "--interval") and j + 1 < len(args):
                j += 2
            elif t.startswith("-") and not rest:
                j += 1
            else:
                rest.append(t)
                j += 1
        if rest:
            analyze_script(" ".join(rest), ctx, depth + 1)
        return

    if low in ("find", "gfind"):
        for j, t in enumerate(args):
            if t in ("-exec", "-execdir", "-ok", "-okdir"):
                sub = []
                for u in args[j + 1:]:
                    if u in (";", "+"):
                        break
                    sub.append(u)
                if sub:
                    analyze_cmd(sub, [], ctx, depth + 1)
        return

    if low == "open":
        for hit in open_hits(args):
            ctx.add("open", hit)
        return

    if low in ("osascript", "launchctl"):
        texts = list(args) + list(stdin)
        if any(MENTION_RE.search(t) for t in texts):
            ctx.add("mention", low)
        elif low == "launchctl" and any(a in ("load", "bootstrap", "enable", "submit") for a in args) \
                and any("LaunchAgents" in a or "LaunchDaemons" in a for a in args):
            ctx.add("persist", "launchctl " + " ".join(args)[:80])
        return

    if low in MENTION_WRAPPERS:
        texts = list(args) + list(stdin)
        if any(MENTION_RE.search(t) for t in texts):
            ctx.add("mention", low)
        return

    if INTERP_RE.match(low):
        kind = re.match(r"^[a-z]+", low).group(0)
        if kind in CODE_LETTERS:
            texts = code_strings(kind, args) + list(stdin)
            if any(MENTION_RE.search(t) for t in texts):
                ctx.add("mention", "%s code" % kind)
        return


def pipe_texts(cmd):
    """Text a command writes into a pipe that is visible in the command line: its here-document, or the
    arguments of echo / printf. `echo 'wordcraft-cli x' | sh` is then read as the script it feeds."""
    texts = list(cmd.stdin)
    i = 0
    while i < len(cmd.words) and ENV_ASSIGN_RE.match(cmd.words[i]):
        i += 1
    if i < len(cmd.words):
        prog = basename(cmd.words[i]).lower()
        args = [w for w in cmd.words[i + 1:] if not w.startswith("-")]
        if prog in ("echo", "print"):
            texts.append(ansi_c(" ".join(args)))
        elif prog == "printf" and args:
            texts.extend(ansi_c(a) for a in (args[1:] if "%" in args[0] else args[:1]))
    return texts


def feeds_decoded_text(prev):
    """Does PREV (the command before a pipe into a shell) decode text: base64 -d, xxd -r, openssl -d ...?"""
    i = 0
    while i < len(prev.words) and ENV_ASSIGN_RE.match(prev.words[i]):
        i += 1
    if i >= len(prev.words):
        return False
    prog = basename(prev.words[i]).lower()
    args = prev.words[i + 1:]
    if prog not in DECODERS:
        return False
    return prog == "uudecode" or any(a in ("-d", "-D", "--decode", "-r", "-revert") or
                                     (a.startswith("-") and not a.startswith("--") and ("d" in a[1:] or "r" in a[1:]))
                                     for a in args)


def analyze_script(text, ctx, depth):
    ctx.tick()
    if len(text) > MAX_CHARS:
        # Too long to read in full: ask, and still read the start for a more specific reason.
        ctx.add("unchecked", "a command over %d characters" % MAX_CHARS)
        text = text[:MAX_CHARS]
    if depth > MAX_DEPTH:
        if MENTION_RE.search(text):
            ctx.add("mention", "a deeply nested command")
        return
    cmds, nested = parse(text, ctx)
    if len(nested) > MAX_NESTED:
        ctx.add("unchecked", "more than %d nested $(...) or backtick commands" % MAX_NESTED)
    for body in nested[:MAX_NESTED]:
        analyze_script(body, ctx, depth + 1)
    for i, cmd in enumerate(cmds):
        stdin = cmd.stdin
        if cmd.piped and i > 0:
            stdin = stdin + pipe_texts(cmds[i - 1])
            first = next((w for w in cmd.words if not ENV_ASSIGN_RE.match(w)), "")
            if basename(first).lower() in SHELLS and feeds_decoded_text(cmds[i - 1]):
                ctx.add("decode", "%s | %s" % (basename(cmds[i - 1].words[0]), basename(first)))
        analyze_cmd(cmd.words, stdin, ctx, depth)


# ---------------------------------------------------------------------------------------------- hook I/O

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


def build_reason(found, workspace):
    runs = sorted(set(d for k, d in found if k == "run"))
    opens = sorted(set(d for k, d in found if k == "open"))
    mentions = sorted(set(d for k, d in found if k == "mention"))
    roots = sorted(set(d for k, d in found if k == "sandbox"))
    decodes = sorted(set(d for k, d in found if k == "decode"))
    persists = sorted(set(d for k, d in found if k == "persist"))
    unchecked = sorted(set(d for k, d in found if k == "unchecked"))
    parts = []
    if runs:
        parts.append("this command runs %s directly from the shell, outside the fenced Craft MCP servers"
                     % ", ".join(runs))
    if opens:
        parts.append("this command opens %s, which starts a Craft app outside the fence" % ", ".join(opens))
    if mentions:
        parts.append("this command passes a Craft app name to %s, which could start it outside the fence"
                     % ", ".join(mentions))
    if roots:
        parts.append("craft-sandbox is called with root %s, which is not exactly <workspace>/<one Craft "
                     "app folder>, so it would widen the fence" % ", ".join(repr(r) for r in roots))
    if decodes:
        parts.append("this command runs decoded text (%s), which the guard cannot read" % ", ".join(decodes))
    if persists:
        parts.append("this command loads a launch agent (%s), which can start programs later outside the fence"
                     % ", ".join(persists))
    if unchecked:
        parts.append("this command could not be checked in full (%s)" % ", ".join(unchecked))
    return ("Craft guard: " + "; ".join(parts) + ". Prefer the mcp__<app>__* tools (workspace: %s); "
            "approve only if you intend this." % workspace)


def main(argv):
    try:
        data = json.loads(sys.stdin.read())
        if not isinstance(data, dict):
            return 0
        tool_input = data.get("tool_input")
        if not isinstance(tool_input, dict):
            return 0
        command = tool_input.get("command")
        app = tool_input.get("app")
        if not isinstance(command, str) and isinstance(app, str) and app.strip():
            # computer-use open_application: the same decision as `open -a <app>`.
            command = "open -a '" + app.replace("'", "'\\''") + "'"
        if not isinstance(command, str) or not command.strip():
            return 0
        workspace = parse_workspace(argv)
        cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
        ctx = Ctx(workspace, cwd)
        try:
            analyze_script(command, ctx, 0)
        except _Stop:
            # Over the work limit: keep what was found, and ask rather than pass an unread command.
            if not ctx.found:
                ctx.add("unchecked", "it needs more parsing work than the guard allows")
        if not ctx.found:
            return 0
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "ask",
                                      "permissionDecisionReason": build_reason(ctx.found, workspace)}}
        sys.stdout.write(json.dumps(out))
        sys.stdout.flush()
    except BaseException:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
