#!/usr/bin/env python3
"""Tests for hooks/craft-shell-guard.py (plain unittest; run: python3 hooks/tests/test_shell_guard.py).

The hook is exercised the way Claude Code runs it: a subprocess that reads the hook JSON on stdin and
prints either nothing (silent) or one "ask" decision. Groups:

  ASK        commands that must prompt (the 12 original ones, then wrappers, interpreters, craft-sandbox ...)
  SILENT     commands that must pass without a word (the 12 original ones, then false-positive controls)
  MALFORMED  input that must fail open (exit 0, no output)

HOME and the workspace are fake (/Users/you) so the results do not depend on the machine running them.
"""
import json
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "craft-shell-guard.py")
HOME = "/Users/you"
WS = HOME + "/craft-workspace"
ENV = dict(os.environ, HOME=HOME)

ASK_ORIGINAL = [
    "wordcraft-cli --version",
    "~/.local/bin/gridcraft-cli mcp",
    "cd /tmp && photocraft-cli info x.psd",
    "/Applications/WordCraft.app/Contents/MacOS/WordCraft --control 7981",
    "open -a WordCraft",
    "open /Applications/DeckCraft.app",
    "bash -c 'vectorcraft-cli mcp'",
    "echo hi; soundcraft-cli x",
    "nohup deckcraft --control 7990 &",
    "FOO=1 lightcraft-cli export",
    "sudo filmcraft-cli run",
    "cat f | pdfcraft-cli text",
]

ASK_WRAPPERS = [
    "timeout 5 wordcraft-cli x",
    "gtimeout -k 2 5 wordcraft-cli x",
    "timeout --foreground -s KILL 10s gridcraft-cli mcp",
    "stdbuf -oL gridcraft-cli mcp",
    "stdbuf -i0 -o0 -e0 gridcraft-cli mcp",
    "unbuffer pdfcraft-cli text f.pdf",
    "nice -n 10 wordcraft-cli x",
    "nice -10 wordcraft-cli x",
    "caffeinate -i deckcraft-cli x",
    "caffeinate -t 60 deckcraft-cli x",
    "arch -arm64 filmcraft-cli x",
    "arch -arch x86_64 filmcraft-cli x",
    "xargs -n1 photocraft-cli",
    "xargs -I {} photocraft-cli {}",
    "exec figcraft-cli mcp",
    "command effectcraft-cli x",
    "env -i FOO=1 cadcraft-cli x",
    "/usr/bin/env wordcraft-cli x",
    "time wordcraft-cli x",
    "sudo -u me gridcraft-cli",
    "sudo -nu me gridcraft-cli x",
    "sudo -E -H lightcraft-cli x",
    "echo hi && FOO=bar sudo -E nohup nice wordcraft-cli x",
    "gtimeout 10 sudo -u me bash -c 'figcraft-cli'",
    "sandbox-exec -f /tmp/x.sb ~/.local/bin/gridcraft-cli mcp",
    "su -c 'wordcraft-cli x' root",
    "watch -n 5 wordcraft-cli x",
    "env -S 'wordcraft-cli x'",
]

ASK_SHELL_FORMS = [
    "bash -c \"bash -c 'gridcraft-cli x'\"",
    "sh -lc 'wordcraft-cli'",
    "zsh -ic 'photocraft-cli x'",
    "dash -c 'wordcraft-cli x'",
    "echo \"$(wordcraft-cli --version)\"",
    "x=`wordcraft-cli --version`",
    "cat <(wordcraft-cli info x.docx)",
    "find . -name '*.docx' -exec wordcraft-cli {} \\;",
    "find . -type f -execdir pdfcraft-cli text {} +",
    "eval \"wordcraft-cli x\"",
    "bash <<< 'wordcraft-cli x'",
    "bash <<'EOF'\nwordcraft-cli x\nEOF",
    "if wordcraft-cli --version; then echo ok; fi",
    "(cd /tmp && wordcraft-cli x)",
    "for f in *.docx; do wordcraft-cli \"$f\"; done",
    "true || wordcraft-cli x",
    "ls | xargs -n1 wordcraft-cli",
    "\"$HOME/.local/bin/wordcraft-cli\" mcp",
    "./wordcraft-cli",
    "WORDCRAFT-CLI --version",
    "$(dirname \"$0\")/wordcraft-cli x",
    "wordcraft-cli x > out.txt 2>&1",
    "$'wordcraft-cli' --version",
    "sudo -i 'wordcraft-cli x'",
    "echo 'wordcraft-cli x' | bash",
    "printf '%s\\n' 'gridcraft-cli mcp' | sh",
    "cat <<EOF | sh\nwordcraft-cli\nEOF",
    "echo \"os.system('pdfcraft-cli')\" | python3",
    "git commit -m \"$(cat <<'EOF'\nfix: don't call it\nEOF\n)\" && wordcraft-cli x",
    "ls |& wordcraft-cli x",
    "ls || wordcraft-cli x",
]

ASK_OPEN = [
    "open -a \"WordCraft\" ~/craft-workspace/wordcraft/in/a.docx",
    "open -na DesignCraft",
    "open -b com.example.vectorcraft",
    "open -a /Applications/PhotoCraft.app",
]

ASK_INTERPRETERS = [
    "osascript -e 'tell application \"WordCraft\" to activate'",
    "osascript -e 'tell application \"FigCraft\" to quit'",
    "launchctl submit -l x -- /usr/local/bin/figcraft-cli mcp",
    "python3 -c \"import os; os.system('pdfcraft-cli x')\"",
    "python3 -c 'import subprocess; subprocess.run([\"wordcraft-cli\"])'",
    "node -e \"require('child_process').execSync('lightcraft-cli x')\"",
    "node -pe \"require('child_process').execSync('lightcraft-cli x')\"",
    "ruby -e 'system(\"soundcraft-cli\")'",
    "perl -e 'exec \"cadcraft-cli\"'",
    "php -r 'system(\"deckcraft-cli\");'",
    "python3 - <<'EOF'\nimport os\nos.system('wordcraft-cli')\nEOF",
    "zsh -c 'osascript -e \"tell application \\\"WordCraft\\\" to quit\"'",
]

ASK_SANDBOX = [
    "craft-sandbox /tmp ~/.local/bin/wordcraft-cli mcp",
    "craft-sandbox / /bin/ls",
    "craft-sandbox ~ /bin/ls",
    "craft-sandbox ~/craft-workspace /bin/ls",
    "craft-sandbox ~/craft-workspace/wordcraft/.. /bin/ls",
    "craft-sandbox ~/craft-workspace/wordcraft/in /bin/ls",
    "craft-sandbox ~/craft-workspace/notanapp /bin/ls",
    "craft-sandbox /Users/you/other/wordcraft /bin/ls",
    "craft-sandbox ~/x /bin/cat f",
    "craft-sandbox \"$WORKSPACE/wordcraft\" /bin/ls",
    "craft-sandbox -x ~/craft-workspace/wordcraft /bin/ls",
    "~/.local/bin/craft-sandbox /Users/you /usr/bin/id",
    "sudo craft-sandbox /tmp /bin/cat x",
    "bash -c 'craft-sandbox / /bin/ls'",
    "craft-sandbox ./wordcraft /bin/ls",
]

# Round-1 review cases (R1-INJECT-6, R1-HOOK-6): expansion and decoding forms, more wrappers, persistence.
ASK_EVASIONS = [
    "${B}craft-cli --version",
    "w?rdcraft-cli --version",
    "/usr/local/bin/word*-cli --version",
    "{wordcraft-cli,--version}",
    "{word,}craft-cli --version",
    "${NOPE:-wordcraft-cli} --version",
    "$'\\x77ordcraft-cli' --version",
    "bash -c $'\\x77ordcraft-cli --version'",
    "printf '\\167ordcraft-cli --version' | sh",
    "echo d29yZGNyYWZ0LWNsaQ== | base64 -d | sh",
    "echo d29yZGNyYWZ0LWNsaQ== | base64 --decode | bash",
    "xxd -r -p hex.txt | sh",
    "eval \"$(echo d29yZGNyYWZ0LWNsaQ== | base64 -d)\"",
    "ionice -c3 wordcraft-cli x",
    "flock /tmp/l wordcraft-cli x",
    "script -q /dev/null wordcraft-cli x",
    "parallel wordcraft-cli ::: a b",
    "ssh host wordcraft-cli x",
    "echo '* * * * * wordcraft-cli x' | crontab -",
    "launchctl load ~/Library/LaunchAgents/x.plist",
    "launchctl bootstrap gui/501 ~/Library/LaunchAgents/x.plist",
    # R1-HOOK-6 round 2: variable set earlier, attached env -S, xargs taking the program from its input
    "W=wordcraft-cli; $W --version",
    "W=wordcraft-cli; ${W} --version",
    "export W=/Users/you/.local/bin/gridcraft-cli && \"$W\" mcp",
    "env -S'wordcraft-cli --version'",
    "ls | xargs -I{} sh -c '{} --version'",
    "find . -name x | xargs -I % bash -c '% mcp'",
    "echo wordcraft-cli | xargs -I{} sh -c '{} --version'",
]

# Known evasions: still silent on purpose (a text heuristic cannot follow them). Listed so a change
# is noticed; docs/FENCES.md names them.
KNOWN_GAPS = [
    "$W --version",
    "python3 -c \"import os; os.system('\\x77ordcraft-cli --version')\"",
    "python3 -c \"import os; os.system('word' + 'craft-cli --version')\"",
    "cp ~/.local/bin/wordcraft-cli /tmp/x && /tmp/x --version",
    "ln -s ~/.local/bin/wordcraft-cli /tmp/x && /tmp/x --version",
]

SILENT_ORIGINAL = [
    "ls ~/.local/bin/wordcraft-cli",
    "grep -n wordcraft docs.md",
    'git commit -m "docs: wordcraft-cli notes"',
    "~/.local/bin/craft-sandbox ~/craft-workspace/wordcraft /bin/cat f",
    "./craft-mcp-install.sh --apply",
    "cat ~/craft-workspace/wordcraft/x.docx",
    "gh api repos/storytold/wordcraft/contents/README.md",
    "claude mcp list",
    "brew list",
    "echo craft",
    "",
    "mdfind -name CADCraft.app",
]

SILENT_CONTROLS = [
    'git commit -m "feat; wordcraft-cli support"',
    "echo \"run wordcraft-cli --version later\"",
    "echo 'gridcraft-cli mcp' >> notes.txt",
    "which wordcraft-cli",
    "command -v wordcraft-cli",
    "type -a wordcraft-cli",
    "man wordcraft-cli",
    "rg -n 'wordcraft-cli' docs",
    "cat docs/wordcraft.md",
    "cd ~/craft-workspace/wordcraft && ls out",
    "cp ~/Downloads/a.docx ~/craft-workspace/wordcraft/in/",
    "ls /Applications | grep -i craft",
    "codesign --verify --deep --strict /Applications/WordCraft.app",
    "open -R /Applications/WordCraft.app",
    "open https://github.com/storytold/wordcraft",
    "open ~/craft-workspace/wordcraft/out/report.pdf",
    "python3 lib/mcp_probe.py --app wordcraft list-tools",
    "python3 -c \"print('hello')\"",
    "python3 -m unittest hooks/tests/test_shell_guard.py",
    "node -e \"console.log(1)\"",
    "bash -c 'ls ~/craft-workspace'",
    "osascript -e 'display dialog \"hi\"'",
    "launchctl list",
    "echo hi > wordcraft-cli",
    "ls # wordcraft-cli x",
    "sudo -u me ls",
    "timeout 5 sleep 1",
    "nice -n 5 make test",
    "xargs grep wordcraft-cli",
    "find . -name 'wordcraft*' -print",
    "find . -exec grep -l wordcraft-cli {} \\;",
    "craft-sandbox ~/craft-workspace/gridcraft ~/.local/bin/gridcraft-cli mcp",
    "craft-sandbox \"$HOME/craft-workspace/pdfcraft/\" /bin/ls",
    "craft-sandbox /Users/you/craft-workspace/soundcraft /bin/ls",
    "craft-sandbox --help",
    "craft-sandbox",
    "curl -fL https://github.com/storytold/wordcraft/releases/download/v0.7.0/x.zip -o /tmp/w.zip",
    "shasum -a 256 /tmp/wordcraft-cli",
    "chmod +x ~/.local/bin/wordcraft-cli",
    "cat <<EOF\nwordcraft-cli x\nEOF",
    "echo 'wordcraft-cli' | tee notes",
    "grep -r 'wordcraft-cli' . | head",
    "diff wordcraft-cli.old wordcraft-cli.new",
    "tail -f /tmp/wordcraft.log",
    "FOO=wordcraft-cli echo hi",
    "W=wordcraft-cli; echo $W",
    "ls | xargs -I{} sh -c 'cat {}'",
    "xargs -I{} cp {} /tmp/x",
    "ls \"$(pwd)/wordcraft\"",
    "git log --oneline -- skills/craft-wordcraft/SKILL.md",
    "sh -c 'echo \"wordcraft-cli is not run here\"'",
    "mkdir -p ~/craft-workspace/wordcraft/in",
    "echo 'tell application \"WordCraft\"' > x.scpt",
    "bash script.sh wordcraft-cli",
    "git commit -m \"$(cat <<'EOF'\nfix: don't call wordcraft-cli directly\nEOF\n)\"",
    "cat > notes.md <<'EOF'\nuse wordcraft-cli (it's fine)\nEOF",
    "echo 'hello' | bash",
    "echo wordcraft-cli | tee notes.txt",
    "echo wordcraft-cli | grep word",
    "ls || echo wordcraft-cli",
    "osascript -e 'tell application \"Finder\" to reveal POSIX file \"/Users/you/craft-workspace/wordcraft/out\"'",
    "python3 -c \"open('/Users/you/craft-workspace/wordcraft/out/x.txt')\"",
    "python3 -c \"print('wordcraft-notes')\"",
    "unterminated 'quote wordcraft",
    "ls *.docx",
    "cat {a,b}.txt",
    "echo aGVsbG8= | base64 -d",
    "base64 -d in.b64 > out.bin",
    "echo $'a\\tb'",
    "ssh host ls",
    "crontab -l",
    "launchctl list | grep craft",
    "eval \"$(ssh-agent -s)\"",
]

MALFORMED = [
    "not json",
    "",
    "[]",
    "null",
    "{}",
    '"wordcraft-cli"',
    "[1,2",
    '{"tool_input": null}',
    '{"tool_input": {}}',
    '{"tool_input": {"command": 5}}',
    '{"tool_input": {"command": null}}',
    '{"tool_input": {"command": ["wordcraft-cli"]}}',
    '{"tool_input": "wordcraft-cli"}',
    '{"tool_name": "Bash"}',
    '{"tool_input": {"command": "   "}}',
]


def run_hook(stdin, args=None, cwd_field=None, env=None):
    if isinstance(stdin, str):
        stdin = stdin.encode("utf-8")
    cmd = [sys.executable, HOOK] + (args if args is not None else ["--workspace", WS])
    t0 = time.time()
    p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env or ENV)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.time() - t0


def payload(command, cwd=None):
    d = {"tool_name": "Bash", "tool_input": {"command": command}, "hook_event_name": "PreToolUse"}
    if cwd:
        d["cwd"] = cwd
    return json.dumps(d)


CACHE = {}


def decision(command, **kw):
    if not kw and command in CACHE:
        return CACHE[command]
    rc, out, err, _ = run_hook(payload(command), **kw)
    return rc, out, err


def prefetch(commands):
    """Run the default-argument cases four at a time; the individual assertions then read the cache."""
    from concurrent.futures import ThreadPoolExecutor
    todo = [c for c in dict.fromkeys(commands) if c not in CACHE]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for c, res in zip(todo, pool.map(lambda c: run_hook(payload(c))[:3], todo)):
            CACHE[c] = res


class ShellGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        prefetch(ASK_ORIGINAL + ASK_WRAPPERS + ASK_SHELL_FORMS + ASK_OPEN + ASK_INTERPRETERS + ASK_SANDBOX
                 + ASK_EVASIONS + KNOWN_GAPS + SILENT_ORIGINAL + SILENT_CONTROLS)

    def assert_ask(self, command, **kw):
        rc, out, err = decision(command, **kw)
        self.assertEqual(rc, 0, "exit code for %r: %s" % (command, err))
        self.assertTrue(out.strip(), "expected an ask for %r" % command)
        body = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(body["hookEventName"], "PreToolUse")
        self.assertEqual(body["permissionDecision"], "ask", command)
        self.assertTrue(body["permissionDecisionReason"].startswith("Craft guard:"), command)

    def assert_silent(self, command, **kw):
        rc, out, err = decision(command, **kw)
        self.assertEqual(rc, 0, "exit code for %r: %s" % (command, err))
        self.assertEqual(out.strip(), "", "expected silence for %r, got %s" % (command, out))

    def test_ask_original(self):
        for c in ASK_ORIGINAL:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_ask_wrappers(self):
        for c in ASK_WRAPPERS:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_ask_shell_forms(self):
        for c in ASK_SHELL_FORMS:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_ask_open(self):
        for c in ASK_OPEN:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_ask_interpreters_osascript_launchctl(self):
        for c in ASK_INTERPRETERS:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_ask_craft_sandbox_wrong_root(self):
        for c in ASK_SANDBOX:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_silent_original(self):
        for c in SILENT_ORIGINAL:
            with self.subTest(command=c):
                self.assert_silent(c)

    def test_silent_false_positive_controls(self):
        for c in SILENT_CONTROLS:
            with self.subTest(command=c):
                self.assert_silent(c)

    def test_malformed_input_fails_open(self):
        for raw in MALFORMED:
            with self.subTest(raw=raw):
                rc, out, err, _ = run_hook(raw)
                self.assertEqual(rc, 0)
                self.assertEqual(out.strip(), "")

    def test_binary_and_invalid_utf8_input_fails_open(self):
        for raw in (b"\xff\xfe\x00garbage", b'{"tool_input": {"command": "\xff wordcraft-cli"}}',
                    b"\x00" * 1000):
            with self.subTest(raw=raw[:20]):
                rc, out, err, _ = run_hook(raw)
                self.assertEqual(rc, 0)
                self.assertEqual(out.strip(), "")

    def test_never_denies(self):
        for c in ASK_ORIGINAL + ASK_WRAPPERS + ASK_SANDBOX:
            rc, out, err = decision(c)
            if out.strip():
                self.assertNotIn("deny", json.dumps(json.loads(out)).lower())

    def test_reason_names_the_offender(self):
        rc, out, _ = decision("timeout 5 wordcraft-cli x")
        self.assertIn("wordcraft-cli", json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"])
        rc, out, _ = decision("craft-sandbox /tmp /bin/ls")
        reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("craft-sandbox", reason)
        self.assertIn("/tmp", reason)
        self.assertIn(WS, reason)

    def test_unrelated_tool_input_keys_are_ignored(self):
        raw = json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls", "description": "wordcraft-cli"}})
        rc, out, _, _ = run_hook(raw)
        self.assertEqual((rc, out.strip()), (0, ""))

    def test_workspace_argument_forms(self):
        cmd = "craft-sandbox /srv/ws/wordcraft /bin/ls"
        self.assert_ask(cmd)
        self.assert_silent(cmd, args=["--workspace", "/srv/ws"])
        self.assert_silent(cmd, args=["--workspace=/srv/ws"])
        self.assert_silent(cmd, args=["--workspace", "/srv/ws/"])
        self.assert_ask(cmd, args=["--workspace", "/srv/other"])
        self.assert_silent("craft-sandbox ~/craft-workspace/wordcraft /bin/ls", args=[])
        self.assert_ask("craft-sandbox ~/elsewhere/wordcraft /bin/ls", args=[])

    def test_workspace_given_through_a_symlink(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "real", "ws")
            os.makedirs(real)
            link = os.path.join(tmp, "link")
            os.symlink(real, link)
            for ws, root in ((link, os.path.join(real, "gridcraft")), (real, os.path.join(link, "gridcraft"))):
                with self.subTest(ws=ws, root=root):
                    self.assert_silent("craft-sandbox %s /bin/ls" % root, args=["--workspace", ws])

    def test_relative_sandbox_root_uses_cwd_from_the_payload(self):
        cmd = "craft-sandbox ./wordcraft /bin/ls"
        rc, out, _, _ = run_hook(payload(cmd, cwd=WS))
        self.assertEqual((rc, out.strip()), (0, ""))
        rc, out, _, _ = run_hook(payload(cmd, cwd=HOME))
        self.assertTrue(out.strip())
        rc, out, _, _ = run_hook(payload(cmd))
        self.assertTrue(out.strip())

    def test_ask_expansion_decoding_and_other_wrappers(self):
        for c in ASK_EVASIONS:
            with self.subTest(command=c):
                self.assert_ask(c)

    def test_known_gaps_are_still_silent(self):
        for c in KNOWN_GAPS:
            with self.subTest(command=c):
                self.assert_silent(c)

    def test_other_shell_tools_and_open_application(self):
        for tool in ("mcp__terminal__run_in_terminal", "Monitor"):
            with self.subTest(tool=tool):
                d = {"tool_name": tool, "tool_input": {"command": "wordcraft-cli --version"}}
                rc, out, _, _ = run_hook(json.dumps(d))
                self.assertIn('"ask"', out)
        for app, asks in (("WordCraft", True), ("wordcraft", True), ("Finder", False), ("It's App", False)):
            with self.subTest(app=app):
                d = {"tool_name": "mcp__computer-use__open_application", "tool_input": {"app": app}}
                rc, out, _, _ = run_hook(json.dumps(d))
                self.assertEqual(rc, 0)
                self.assertEqual(bool(out.strip()), asks, out)

    def test_symlinked_app_folder_widens_the_fence(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            ws = os.path.join(os.path.realpath(tmp), "ws")
            os.makedirs(os.path.join(ws, "gridcraft"))
            os.makedirs(os.path.join(tmp, "elsewhere"))
            os.symlink(os.path.join(tmp, "elsewhere"), os.path.join(ws, "filmcraft"))
            args = ["--workspace", ws]
            rc, out, _, _ = run_hook(payload("craft-sandbox %s/gridcraft /bin/ls" % ws), args=args)
            self.assertEqual(out.strip(), "")
            rc, out, _, _ = run_hook(payload("craft-sandbox %s/filmcraft /bin/ls" % ws), args=args)
            self.assertIn("widen the fence", out)

    def test_large_and_pathological_commands_stay_fast_and_fail_open(self):
        cases = [
            "echo hi; " * 20000,
            "(" * 5000 + "ls" + ")" * 5000,
            "$(" * 400 + "ls" + ")" * 400,
            "bash -c '" * 50 + "ls" + "'" * 50,
            "'" * 3001,
            "a" * 300000,
        ]
        for c in cases:
            with self.subTest(size=len(c)):
                rc, out, err, secs = run_hook(payload(c))
                self.assertEqual(rc, 0, err)
                self.assertLess(secs, 1.5)
                if out.strip():
                    self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "ask")
        # A Craft call past the length cap, or after 200 nested bodies, must not pass silently
        # (R1-HOOK-5, B1-INJECT-3).
        for c in ("a" * 200001 + ";wordcraft-cli --version", "$(true)" * 200 + "$(wordcraft-cli --version)",
                  "x" * 300000):
            with self.subTest(size=len(c)):
                rc, out, err, secs = run_hook(payload(c))
                self.assertEqual(rc, 0, err)
                self.assertLess(secs, 1.5)
                self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "ask")

    def test_a_finding_survives_a_time_budget_stop(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("craft_shell_guard_under_test", HOOK)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        ctx = guard.Ctx(WS, None)
        guard.analyze_script("wordcraft-cli x", ctx, 0)
        ctx.ticks = guard.MAX_TICKS
        with self.assertRaises(guard._Stop):
            guard.analyze_script("ls; " * 1000, ctx, 0)
        self.assertTrue(ctx.found)
        import io
        old_in, old_out, old_budget = sys.stdin, sys.stdout, guard.MAX_TICKS
        try:
            guard.MAX_TICKS = 0
            sys.stdin = io.StringIO(payload("wordcraft-cli x"))
            sys.stdout = buf = io.StringIO()
            guard.main(["x", "--workspace", WS])
        finally:
            sys.stdin, sys.stdout, guard.MAX_TICKS = old_in, old_out, old_budget
        self.assertIn('"ask"', buf.getvalue())

    def test_typical_command_is_fast(self):
        times = []
        for _ in range(5):
            rc, out, _, secs = run_hook(payload("ls -la && git status"))
            times.append(secs)
        self.assertLess(min(times), 0.5)

    def test_deeply_nested_shell_strings_that_mention_a_craft_app_still_ask(self):
        cmd = "bash -c \"bash -c \\\"bash -c 'bash -c \\\\\\\"sh -c \\\\\\\\\\\\\\\"sh -c wordcraft-cli\\\\\\\\\\\\\\\"\\\\\\\"'\\\"\""
        self.assert_ask(cmd)


def load_guard():
    import importlib.util
    spec = importlib.util.spec_from_file_location("craft_shell_guard_under_test", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CombinationTests(unittest.TestCase):
    """In-process sweep: every app name in every spelling behind every wrapper must ask, and the same
    spellings as plain arguments of harmless commands must stay silent."""

    @classmethod
    def setUpClass(cls):
        cls.guard = load_guard()
        cls.apps = "word grid deck pdf photo vector design cad fig film effect light sound".split()

    def asks(self, command):
        os.environ["HOME"] = HOME
        ctx = self.guard.Ctx(WS, HOME + "/proj")
        self.guard.analyze_script(command, ctx, 0)
        return bool(ctx.found)

    def spellings(self, app):
        return [app + "craft-cli", app.capitalize() + "Craft", app + "craft", "~/.local/bin/" + app + "craft-cli",
                "/Applications/%sCraft.app/Contents/MacOS/%sCraft" % (app.capitalize(), app.capitalize())]

    def test_every_spelling_behind_every_wrapper_asks(self):
        wrappers = ["", "sudo ", "sudo -u me ", "env FOO=1 ", "nohup ", "time ", "nice -n 5 ", "timeout 5 ",
                    "gtimeout -k 1 5 ", "stdbuf -oL ", "unbuffer ", "arch -arm64 ", "caffeinate -i ", "exec ",
                    "command ", "xargs ", "xargs -n1 ", "FOO=bar ", "sudo -E nohup nice ", "env -i PATH=/bin "]
        prefixes = ["", "cd /tmp && ", "ls | ", "echo x; ", "(", "{ ", "true && "]
        misses = []
        for app in self.apps:
            for spelling in self.spellings(app):
                for w in wrappers:
                    for pre in prefixes:
                        cmd = pre + w + spelling + " --version" + (")" if pre == "(" else "")
                        if not self.asks(cmd):
                            misses.append(cmd)
        self.assertEqual(misses[:10], [])

    def test_every_spelling_as_an_argument_of_a_harmless_command_is_silent(self):
        harmless = ["ls ", "grep -rn ", "cat ", "echo ", "git add ", "cp ", "rm -f ", "chmod 644 ", "head ",
                    "wc -l ", "stat ", "file ", "diff ", "git log -- ", "rg ", "shasum ", "touch ", "mkdir -p ",
                    "tail -f ", "codesign -dv ", "du -sh ", "which ", "type ", "ln -s x "]
        wrong = []
        for app in self.apps:
            for spelling in self.spellings(app):
                for h in harmless:
                    for suffix in ("", " | head", " > /tmp/out", " 2>&1"):
                        if self.asks(h + spelling + suffix):
                            wrong.append(h + spelling + suffix)
        self.assertEqual(wrong[:10], [])


class CaseCountTests(unittest.TestCase):
    def test_enough_cases(self):
        ask = len(ASK_ORIGINAL + ASK_WRAPPERS + ASK_SHELL_FORMS + ASK_OPEN + ASK_INTERPRETERS + ASK_SANDBOX)
        silent = len(SILENT_ORIGINAL + SILENT_CONTROLS)
        self.assertEqual(len(ASK_ORIGINAL), 12)
        self.assertEqual(len(SILENT_ORIGINAL), 12)
        self.assertGreaterEqual(len(MALFORMED), 5)
        self.assertGreaterEqual(ask + silent + len(MALFORMED), 60)


if __name__ == "__main__":
    unittest.main(verbosity=1)
