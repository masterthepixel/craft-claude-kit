#!/usr/bin/env python3
"""Unit tests for lib/craftkit.py and lib/mcp_probe.py.

No network, no real Craft servers, nothing outside temp dirs. The MCP client is exercised against a
small fake stdio server written to a temp dir. Run:

    python3 -m unittest discover -s tests -p 'test_craftkit.py'     (or: python3 tests/test_craftkit.py)
"""

import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LIB = os.path.join(REPO, "lib")
sys.path.insert(0, LIB)

import craftkit  # noqa: E402
import mcp_probe  # noqa: E402

CRAFTKIT_PY = os.path.join(LIB, "craftkit.py")
PROBE_PY = os.path.join(LIB, "mcp_probe.py")
REAL_LOCK = os.path.join(REPO, "manifest", "apps.lock.json")

FENCE_LOCK = {
    "schema": 1,
    "owner": "example",
    "apps": {
        "alpha": {"version": "1.2.3", "fence": "roots", "extraArgs": ["--author", "Claude"],
                  "cli": {"asset": "alpha-cli.zip", "url": "https://example.invalid/alpha.zip", "size": 10,
                          "sha256": "0" * 64}},
        "beta": {"version": "2.0.0", "fence": "root", "extraArgs": [], "flag": True},
        "gamma": {"version": "3.0.0", "fence": "sandbox", "extraArgs": ["--x", "1"]},
    },
}


def run(script, args, env_extra=None, env_drop=("CRAFT_KIT_LOCK", "CLAUDE_CONFIG_DIR"), stdin=None, timeout=60):
    env = dict(os.environ)
    for k in env_drop:
        env.pop(k, None)
    env.update(env_extra or {})
    p = subprocess.run([sys.executable, script] + list(args), env=env, input=stdin,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                       timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE,
                        universal_newlines=True).stdout.strip()
    return bool(st) and "Z" not in st


def wait_dead(pid, seconds=5.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return not pid_alive(pid)


def read_int(path):
    with open(path, "r") as fh:
        return int(fh.read())


def wait_for(path, seconds=10.0, contains=None):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if os.path.exists(path):
            if contains is None:
                return True
            with open(path, "r") as fh:
                if contains in fh.read():
                    return True
        time.sleep(0.05)
    return False


class TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="craftkit-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *parts):
        return os.path.join(self.tmp, *parts)

    def write(self, rel, text):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)
        return p

    def write_json(self, rel, obj):
        return self.write(rel, json.dumps(obj))


# ---------------------------------------------------------------------------------------------
# craftkit: expected / registered / render / lock-get
# ---------------------------------------------------------------------------------------------

class TestExpected(TmpCase):
    def test_roots_fence_with_extra_args_after_fence_flags(self):
        r = craftkit.expected_registration("alpha", "/w", "/p", FENCE_LOCK)
        self.assertEqual(r, {"command": "/p/alpha-cli",
                             "args": ["mcp", "--automation-read-root", "/w/alpha",
                                      "--automation-write-root", "/w/alpha", "--author", "Claude"]})

    def test_root_fence(self):
        r = craftkit.expected_registration("beta", "/w", "/p", FENCE_LOCK)
        self.assertEqual(r, {"command": "/p/beta-cli", "args": ["mcp", "--root", "/w/beta"]})

    def test_sandbox_fence_goes_through_wrapper(self):
        r = craftkit.expected_registration("gamma", "/w", "/p", FENCE_LOCK)
        self.assertEqual(r, {"command": "/p/craft-sandbox",
                             "args": ["/w/gamma", "/p/gamma-cli", "mcp", "--x", "1"]})

    def test_paths_are_normalised(self):
        r = craftkit.expected_registration("beta", "/w//sub/../ws/", "/p/", FENCE_LOCK)
        self.assertEqual(r["command"], "/p/beta-cli")
        self.assertEqual(r["args"][-1], "/w/ws/beta")

    def test_relative_and_tilde_workspace_become_absolute(self):
        old = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, old)
        rel = craftkit.expected_registration("beta", "ws", "bin", FENCE_LOCK)
        self.assertEqual(rel["args"][-1], os.path.join(self.tmp, "ws", "beta"))
        self.assertEqual(rel["command"], os.path.join(self.tmp, "bin", "beta-cli"))
        home = craftkit.expected_registration("beta", "~/ws", "~/bin", FENCE_LOCK)
        self.assertEqual(home["args"][-1], os.path.join(os.path.expanduser("~"), "ws", "beta"))

    def test_unknown_app_and_bad_fence(self):
        with self.assertRaises(craftkit.UsageError):
            craftkit.expected_registration("nope", "/w", "/p", FENCE_LOCK)
        bad = json.loads(json.dumps(FENCE_LOCK))
        bad["apps"]["alpha"]["fence"] = "open"
        with self.assertRaises(craftkit.InputFileError):
            craftkit.expected_registration("alpha", "/w", "/p", bad)

    def test_extra_args_may_not_carry_fence_flags(self):
        # The CLIs honour the LAST --automation-write-root (and the "=" form), so a fence flag in
        # extraArgs would silently move the fence (R1-SUPPLY-2).
        for extra in (["--automation-write-root", "/"], ["--automation-write-root=/"], ["--root=/x"],
                      ["--root", "/x"], ["--automation-read-root", "/"]):
            bad = json.loads(json.dumps(FENCE_LOCK))
            bad["apps"]["alpha"]["extraArgs"] = extra
            bad["apps"]["gamma"]["extraArgs"] = extra
            for app in ("alpha", "gamma"):
                with self.assertRaises(craftkit.InputFileError, msg=(app, extra)):
                    craftkit.expected_registration(app, "/w", "/p", bad)
        self.assertFalse(craftkit.is_fence_flag("--author"))
        self.assertFalse(craftkit.is_fence_flag("--rooted"))

    def test_lock_may_be_a_path(self):
        p = self.write_json("lock.json", FENCE_LOCK)
        r = craftkit.expected_registration("beta", "/w", "/p", p)
        self.assertEqual(r["args"], ["mcp", "--root", "/w/beta"])

    def test_every_real_app_matches_its_fence(self):
        lock = craftkit.load_lock(REAL_LOCK)
        self.assertEqual(len(lock["apps"]), 13)
        for app, entry in lock["apps"].items():
            r = craftkit.expected_registration(app, "/Users/you/craft-workspace", "/Users/you/.local/bin", lock)
            root = "/Users/you/craft-workspace/%s" % app
            fence = entry["fence"]
            if fence == "roots":
                self.assertEqual(r["command"], "/Users/you/.local/bin/%s-cli" % app)
                self.assertEqual(r["args"][:5], ["mcp", "--automation-read-root", root,
                                                  "--automation-write-root", root])
                self.assertEqual(r["args"][5:], entry["extraArgs"])
            elif fence == "root":
                self.assertEqual(r["args"], ["mcp", "--root", root] + entry["extraArgs"])
            else:
                self.assertEqual(r["command"], "/Users/you/.local/bin/craft-sandbox")
                self.assertEqual(r["args"], [root, "/Users/you/.local/bin/%s-cli" % app, "mcp"]
                                 + entry["extraArgs"])
            for a in [r["command"]] + r["args"]:
                if a.startswith("/"):
                    self.assertFalse(a.endswith("/"), a)

    def test_cli_prints_compact_sorted_json(self):
        lock = self.write_json("lock.json", FENCE_LOCK)
        code, out, err = run(CRAFTKIT_PY, ["expected", "--app", "beta", "--workspace", "/w",
                                           "--prefix", "/p", "--lock", lock])
        self.assertEqual(code, 0, err)
        self.assertEqual(out.strip(), '{"args": ["mcp", "--root", "/w/beta"], "command": "/p/beta-cli"}')

    def test_cli_usage_and_lock_errors(self):
        lock = self.write_json("lock.json", FENCE_LOCK)
        code, _, err = run(CRAFTKIT_PY, ["expected", "--app", "zzz", "--workspace", "/w", "--prefix", "/p",
                                         "--lock", lock])
        self.assertEqual(code, 2)
        self.assertIn("unknown app", err)
        code, _, _ = run(CRAFTKIT_PY, ["expected", "--app", "beta"])
        self.assertEqual(code, 2)
        bad = self.write_json("bad.json", {"schema": 2, "apps": {"a": {}}})
        code, _, err = run(CRAFTKIT_PY, ["expected", "--app", "a", "--workspace", "/w", "--prefix", "/p",
                                         "--lock", bad])
        self.assertEqual(code, 3)
        self.assertIn("schema", err)

    def test_lock_precedence_flag_over_env_over_default(self):
        env_lock = self.write_json("env.json", FENCE_LOCK)
        other = dict(FENCE_LOCK, apps={"beta": dict(FENCE_LOCK["apps"]["beta"], extraArgs=["--flag"])})
        flag_lock = self.write_json("flag.json", other)
        args = ["expected", "--app", "beta", "--workspace", "/w", "--prefix", "/p"]
        _, out, _ = run(CRAFTKIT_PY, args, {"CRAFT_KIT_LOCK": env_lock})
        self.assertEqual(json.loads(out)["args"], ["mcp", "--root", "/w/beta"])
        _, out, _ = run(CRAFTKIT_PY, args + ["--lock", flag_lock], {"CRAFT_KIT_LOCK": env_lock})
        self.assertEqual(json.loads(out)["args"], ["mcp", "--root", "/w/beta", "--flag"])
        code, _, _ = run(CRAFTKIT_PY, ["expected", "--app", "wordcraft", "--workspace", "/w", "--prefix", "/p"])
        self.assertEqual(code, 0)


class TestRegistered(TmpCase):
    def config(self, servers, **extra):
        data = {"numStartups": 3, "mcpServers": servers}
        data.update(extra)
        return self.write_json("cfg/.claude.json", data)

    def test_returns_command_and_args(self):
        self.config({"x": {"type": "stdio", "command": "/p/x-cli", "args": ["mcp", "--root", "/w/x"], "env": {}}})
        self.assertEqual(craftkit.registered("x", self.path("cfg")),
                         {"command": "/p/x-cli", "args": ["mcp", "--root", "/w/x"]})

    def test_none_when_missing(self):
        self.assertIsNone(craftkit.registered("x", self.path("nowhere")))
        self.config({"y": {"command": "c", "args": []}})
        self.assertIsNone(craftkit.registered("x", self.path("cfg")))
        self.write_json("cfg2/.claude.json", ["not", "a", "dict"])
        self.assertIsNone(craftkit.registered("x", self.path("cfg2")))

    def test_only_user_scope_counts(self):
        self.config({}, projects={"/some/project": {"mcpServers": {"x": {"command": "/evil", "args": []}}}})
        self.assertIsNone(craftkit.registered("x", self.path("cfg")))

    def test_invalid_json_is_an_error(self):
        self.write("cfg/.claude.json", "{not json")
        with self.assertRaises(craftkit.InputFileError):
            craftkit.registered("x", self.path("cfg"))

    def test_non_stdio_entry_is_visibly_different(self):
        self.config({"x": {"type": "http", "url": "https://example.invalid/mcp"}})
        r = craftkit.registered("x", self.path("cfg"))
        self.assertEqual(r["command"], "")
        self.assertEqual(r["args"], [])
        self.assertEqual(r["type"], "http")

    def test_env_override_is_kept_and_compares_unequal(self):
        # An env override (for example a permissive CRAFT_SANDBOX_PROFILE) changes the fence (R1-CONFIG-3).
        base = {"type": "stdio", "command": "/p/beta-cli", "args": ["mcp", "--root", "/w/beta"]}
        self.config({"beta": dict(base, env={"CRAFT_SANDBOX_PROFILE": "/private/tmp/permissive.sb"})})
        reg = craftkit.registered("beta", self.path("cfg"))
        self.assertEqual(reg["env"], {"CRAFT_SANDBOX_PROFILE": "/private/tmp/permissive.sb"})
        self.assertNotEqual(reg, craftkit.expected_registration("beta", "/w", "/p", FENCE_LOCK))
        self.config({"beta": dict(base, env={})})
        self.assertEqual(craftkit.registered("beta", self.path("cfg")),
                         craftkit.expected_registration("beta", "/w", "/p", FENCE_LOCK))

    def test_env_dir_and_explicit_dir(self):
        self.config({"x": {"command": "/from-env", "args": []}})
        self.write_json("other/.claude.json", {"mcpServers": {"x": {"command": "/explicit", "args": []}}})
        old = os.environ.get("CLAUDE_CONFIG_DIR")

        def restore():
            if old is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = old
        self.addCleanup(restore)
        os.environ["CLAUDE_CONFIG_DIR"] = self.path("cfg")
        self.assertEqual(craftkit.registered("x")["command"], "/from-env")
        self.assertEqual(craftkit.registered("x", self.path("other"))["command"], "/explicit")

    def test_cli_exit_codes_and_equality_with_expected(self):
        lock = self.write_json("lock.json", FENCE_LOCK)
        code, _, err = run(CRAFTKIT_PY, ["registered", "--app", "beta", "--config-dir", self.path("cfg")])
        self.assertEqual(code, 1)
        self.assertIn("no user-scope registration", err)
        _, expected, _ = run(CRAFTKIT_PY, ["expected", "--app", "beta", "--workspace", "/w", "--prefix", "/p",
                                           "--lock", lock])
        exp = json.loads(expected)
        self.config({"beta": {"type": "stdio", "command": exp["command"], "args": exp["args"], "env": {}}})
        code, reg, _ = run(CRAFTKIT_PY, ["registered", "--app", "beta", "--config-dir", self.path("cfg")])
        self.assertEqual(code, 0)
        self.assertEqual(reg, expected)
        self.write("cfg/.claude.json", "{broken")
        code, _, err = run(CRAFTKIT_PY, ["registered", "--app", "beta", "--config-dir", self.path("cfg")])
        self.assertEqual(code, 3)
        self.assertIn("cannot read", err)

    def test_cli_honours_claude_config_dir_env(self):
        self.config({"beta": {"command": "/c", "args": ["a"]}})
        code, out, _ = run(CRAFTKIT_PY, ["registered", "--app", "beta"], {"CLAUDE_CONFIG_DIR": self.path("cfg")})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"command": "/c", "args": ["a"]})


class TestShadowed(TmpCase):
    def test_local_and_project_scope_registrations_are_found(self):
        proj = self.path("proj")
        self.write_json("proj/.mcp.json", {"mcpServers": {"beta": {"command": "/unfenced", "args": []}}})
        self.write_json("cfg/.claude.json", {"mcpServers": {}, "projects": {
            proj: {"mcpServers": {"beta": {"type": "stdio", "command": "/bin/echo", "args": ["x"]}, "other": {}}},
            "/no/such/folder": {"mcpServers": {}}}})
        found = craftkit.shadowing(["beta", "alpha"], self.path("cfg"))
        self.assertEqual([(f["scope"], f["dir"], f["command"]) for f in found],
                         [("local", proj, "/bin/echo"), ("project", proj, "/unfenced")])
        self.assertEqual(craftkit.shadowing(["beta"], self.path("nowhere")), [])

    def test_cli_leaves_out_entries_equal_to_the_expected_registration(self):
        lock = self.write_json("lock.json", FENCE_LOCK)
        _, expected, _ = run(CRAFTKIT_PY, ["expected", "--app", "beta", "--workspace", "/w", "--prefix", "/p", "--lock", lock])
        exp = json.loads(expected)
        self.write_json("cfg/.claude.json", {"projects": {
            "/a": {"mcpServers": {"beta": {"command": exp["command"], "args": exp["args"]}}},
            "/b": {"mcpServers": {"beta": {"command": "/bin/echo", "args": []}}},
            "/c": {"mcpServers": {"beta": {"command": exp["command"], "args": exp["args"],
                                           "env": {"CRAFT_SANDBOX_PROFILE": "/x.sb"}}}}}})
        code, out, _ = run(CRAFTKIT_PY, ["shadowed", "--apps", "beta", "--config-dir", self.path("cfg"),
                                         "--workspace", "/w", "--prefix", "/p", "--lock", lock])
        self.assertEqual(code, 0)
        self.assertEqual([f["dir"] for f in json.loads(out)], ["/b", "/c"])


class TestRender(TmpCase):
    def test_replaces_all_tokens(self):
        text = "a {{WORKSPACE}}/x b {{KIT_HOME}}/y c {{ WORKSPACE }} d {{WORKSPACE}}"
        out = craftkit.render_text(text, "/Users/you/ws/", "/Users/you/kit")
        self.assertEqual(out, "a /Users/you/ws/x b /Users/you/kit/y c /Users/you/ws d /Users/you/ws")

    def test_single_pass_does_not_reexpand(self):
        out = craftkit.render_text("{{WORKSPACE}}", "/w/{{KIT_HOME}}", "/k")
        self.assertEqual(out, "/w/{{KIT_HOME}}")

    def test_other_tokens_untouched_and_found(self):
        out = craftkit.render_text("{{WORKSPACE}} {{OTHER}} {x} {\"a\":{\"b\":1}}", "/w", "/k")
        self.assertEqual(craftkit.leftover_tokens(out), ["{{OTHER}}"])
        self.assertEqual(craftkit.leftover_tokens('{"a":{"b":{"c":1}}} {x}'), [])

    def test_cli_renders_file(self):
        src = self.write("in/SKILL.md", "---\nname: x\n---\nroot={{WORKSPACE}}/x kit={{KIT_HOME}}\n")
        out = self.path("deep", "er", "SKILL.md")
        code, _, err = run(CRAFTKIT_PY, ["render", "--workspace", "/Users/you/ws/", "--kit-home", "/Users/you/k",
                                         "--in", src, "--out", out])
        self.assertEqual(code, 0, err)
        with open(out) as fh:
            self.assertEqual(fh.read(), "---\nname: x\n---\nroot=/Users/you/ws/x kit=/Users/you/k\n")
        self.assertEqual(os.listdir(os.path.dirname(out)), ["SKILL.md"])
        old = os.umask(0o022)
        try:
            out2 = self.path("m", "SKILL.md")
            run(CRAFTKIT_PY, ["render", "--workspace", "/w", "--kit-home", "/k", "--in", src, "--out", out2])
        finally:
            os.umask(old)
        self.assertEqual(os.stat(out2).st_mode & 0o777, 0o644)

    def test_cli_fails_and_writes_nothing_on_leftover_token(self):
        src = self.write("in/SKILL.md", "ok {{WORKSPACE}} but {{TYPO}} and {{TYPO}}\n")
        out = self.path("o", "SKILL.md")
        code, _, err = run(CRAFTKIT_PY, ["render", "--workspace", "/w", "--kit-home", "/k", "--in", src,
                                         "--out", out])
        self.assertEqual(code, 1)
        self.assertIn("{{TYPO}}", err)
        self.assertFalse(os.path.exists(out))

    def test_cli_stdin_stdout_and_missing_input(self):
        code, out, _ = run(CRAFTKIT_PY, ["render", "--workspace", "/w", "--kit-home", "/k", "--in", "-",
                                         "--out", "-"], stdin="{{KIT_HOME}}!")
        self.assertEqual((code, out), (0, "/k!"))
        code, _, err = run(CRAFTKIT_PY, ["render", "--workspace", "/w", "--kit-home", "/k",
                                         "--in", self.path("missing"), "--out", self.path("x")])
        self.assertEqual(code, 3)
        self.assertIn("cannot read", err)

    def test_every_real_skill_renders_clean_when_present(self):
        skills = os.path.join(REPO, "skills")
        if not os.path.isdir(skills):
            self.skipTest("no skills yet")
        for name in sorted(os.listdir(skills)):
            md = os.path.join(skills, name, "SKILL.md")
            if not os.path.isfile(md):
                continue
            with open(md, encoding="utf-8") as fh:
                text = fh.read()
            rendered = craftkit.render_text(text, "/Users/you/craft-workspace", "/Users/you/.local/share/ck")
            self.assertEqual(craftkit.leftover_tokens(rendered), [], name)


class TestLockGet(TmpCase):
    def setUp(self):
        TmpCase.setUp(self)
        self.lock = self.write_json("lock.json", FENCE_LOCK)

    def get(self, *args):
        return run(CRAFTKIT_PY, ["lock-get", "--lock", self.lock] + list(args))

    def test_scalar_fields(self):
        self.assertEqual(self.get("--app", "alpha", "--field", "cli.url")[1], "https://example.invalid/alpha.zip\n")
        self.assertEqual(self.get("--app", "alpha", "--field", "cli.size")[1], "10\n")
        self.assertEqual(self.get("--app", "beta", "--field", "flag")[1], "true\n")
        self.assertEqual(self.get("--app", "gamma", "--field", "fence")[1], "sandbox\n")

    def test_list_field_prints_json_and_index_works(self):
        self.assertEqual(json.loads(self.get("--app", "alpha", "--field", "extraArgs")[1]), ["--author", "Claude"])
        self.assertEqual(self.get("--app", "alpha", "--field", "extraArgs.1")[1], "Claude\n")
        self.assertEqual(self.get("--app", "beta", "--field", "extraArgs")[1], "[]\n")

    def test_root_field_without_app(self):
        self.assertEqual(self.get("--field", "owner")[1], "example\n")

    def test_errors(self):
        code, _, err = self.get("--app", "alpha", "--field", "gui.url")
        self.assertEqual(code, 1)
        self.assertIn("no such field", err)
        self.assertEqual(self.get("--app", "zzz", "--field", "fence")[0], 2)
        self.assertEqual(self.get("--app", "alpha")[0], 2)

    def test_apps_lists_in_lock_order(self):
        code, out, _ = run(CRAFTKIT_PY, ["apps", "--lock", self.lock])
        self.assertEqual((code, out.split()), (0, ["alpha", "beta", "gamma"]))

    def test_real_lock_is_complete(self):
        lock = craftkit.load_lock(REAL_LOCK)
        self.assertEqual(sorted(lock["apps"]), sorted(
            "wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft "
            "filmcraft effectcraft lightcraft soundcraft".split()))
        for app, e in lock["apps"].items():
            self.assertRegex(e["cli"]["sha256"], r"^[0-9a-f]{64}$", app)
            self.assertTrue(e["cli"]["url"].startswith("https://github.com/storytold/%s/" % app), app)
            self.assertIn(e["version"], e["cli"]["asset"], app)
            self.assertIn(e["fence"], craftkit.FENCES, app)


# ---------------------------------------------------------------------------------------------
# mcp_probe: pure helpers (steps templating, expectations, JSON paths)
# ---------------------------------------------------------------------------------------------

def tool_result(text="", is_error=False, **extra):
    r = {"content": [{"type": "text", "text": text}], "isError": is_error}
    r.update(extra)
    return r


class TestTemplating(unittest.TestCase):
    def ctx(self):
        c = mcp_probe.Context("/ws/app")
        c.record('{"id": 7, "doc": {"pages": [3, 4], "name": "n"}, "s": "x"}',
                 {"id": 7, "doc": {"pages": [3, 4], "name": "n"}, "s": "x"})
        c.record("plain text", mcp_probe.MISSING)
        return c

    def test_root_and_prev_text(self):
        c = self.ctx()
        self.assertEqual(mcp_probe.expand("{root}/out/a.docx", c), "/ws/app/out/a.docx")
        self.assertEqual(mcp_probe.expand("got: {prev}!", c), "got: plain text!")

    def test_prev_suffix_is_not_a_path(self):
        self.assertEqual(mcp_probe.expand("{prev}.txt", self.ctx()), "plain text.txt")

    def test_step_references_and_typed_values(self):
        c = self.ctx()
        self.assertEqual(mcp_probe.expand("{step1.id}", c), 7)
        self.assertEqual(mcp_probe.expand("{step1.doc.pages[1]}", c), 4)
        self.assertEqual(mcp_probe.expand("{step1.doc.pages.0}", c), 3)
        self.assertEqual(mcp_probe.expand("{step1.doc}", c), {"pages": [3, 4], "name": "n"})
        self.assertEqual(mcp_probe.expand("id={step1.id}", c), "id=7")
        self.assertEqual(mcp_probe.expand("d={step1.doc.pages}", c), "d=[3, 4]")

    def test_recurses_into_containers_but_not_keys(self):
        c = self.ctx()
        out = mcp_probe.expand({"{root}": ["{root}", {"p": "{root}/x", "n": 5, "b": True}]}, c)
        self.assertEqual(out, {"{root}": ["/ws/app", {"p": "/ws/app/x", "n": 5, "b": True}]})

    def test_unknown_braces_left_alone(self):
        c = self.ctx()
        self.assertEqual(mcp_probe.expand("{foo} {rootx} {{root}}", c), "{foo} {rootx} {/ws/app}")
        self.assertEqual(mcp_probe.expand('{"a": 1}', c), '{"a": 1}')

    def test_errors(self):
        empty = mcp_probe.Context("/r")
        with self.assertRaises(mcp_probe.UsageProblem):
            mcp_probe.expand("{prev}", empty)
        c = self.ctx()
        for bad in ("{step3}", "{step0}", "{prev.x}", "{step2.x}", "{step1.nope}", "{root.x}"):
            with self.assertRaises(mcp_probe.UsageProblem, msg=bad):
                mcp_probe.expand(bad, c)


class TestJsonPathAndMatch(unittest.TestCase):
    DOC = {"a": {"b": [10, {"c": "deep"}]}, "n": 5, "t": True, "z": None, "list": [1, 2, 3]}

    def test_paths(self):
        g = mcp_probe.json_path
        self.assertEqual(g(self.DOC, "a.b.0"), 10)
        self.assertEqual(g(self.DOC, "a.b[1].c"), "deep")
        self.assertEqual(g(self.DOC, "$.a.b[-1].c"), "deep")
        self.assertEqual(g(self.DOC, "list.2"), 3)
        self.assertIsNone(g(self.DOC, "z"))
        self.assertIs(g(self.DOC, "a.x"), mcp_probe.MISSING)
        self.assertIs(g(self.DOC, "list[9]"), mcp_probe.MISSING)
        self.assertIs(g(self.DOC, "n.deeper"), mcp_probe.MISSING)
        self.assertEqual(g(self.DOC, "$"), self.DOC)
        self.assertEqual(g([5, 6], "[1]"), 6)

    def test_equality_and_bool_int_distinction(self):
        m = mcp_probe.match_value
        self.assertTrue(m(5, 5)[0])
        self.assertTrue(m(3.0, 3)[0])
        self.assertFalse(m(True, 1)[0])
        self.assertFalse(m(1, True)[0])
        self.assertTrue(m(True, True)[0])
        self.assertTrue(m(None, None)[0])
        self.assertFalse(m(mcp_probe.MISSING, None)[0])
        self.assertTrue(m({"x": [1]}, {"x": [1]})[0])
        self.assertFalse(m("a", "b")[0])

    def test_operators(self):
        m = mcp_probe.match_value
        self.assertTrue(m(5, {"$gt": 4, "$lt": 6})[0])
        self.assertFalse(m(5, {"$gt": 5})[0])
        self.assertTrue(m(5, {"$gte": 5, "$lte": 5})[0])
        self.assertFalse(m("5", {"$gt": 1})[0])
        self.assertFalse(m(True, {"$gt": 0})[0])
        self.assertTrue(m(mcp_probe.MISSING, {"$exists": False})[0])
        self.assertTrue(m(0, {"$exists": True})[0])
        self.assertFalse(m(mcp_probe.MISSING, {"$exists": True})[0])
        self.assertTrue(m("hello", {"$contains": "ell"})[0])
        self.assertTrue(m([1, 2], {"$contains": 2})[0])
        self.assertFalse(m(5, {"$contains": 5})[0])
        self.assertTrue(m("v1.2", {"$regex": r"^v\d"})[0])
        self.assertFalse(m(12, {"$regex": "1"})[0])
        self.assertTrue(m(1, {"$ne": 2})[0])
        self.assertFalse(m(1, {"$ne": 1})[0])
        self.assertFalse(m(1, {"$nope": 1})[0])
        # a plain dict that merely has "$" in a value is data, not operators
        self.assertTrue(m({"a": "$x"}, {"a": "$x"})[0])


class TestExpectations(unittest.TestCase):
    chk = staticmethod(mcp_probe.check_expectations)

    def test_default_is_no_error(self):
        self.assertEqual(self.chk(tool_result("fine"), {}), [])
        self.assertEqual(self.chk(tool_result("fine"), None), [])
        fails = self.chk(tool_result("it broke", True), {})
        self.assertEqual(len(fails), 1)
        self.assertIn("it broke", fails[0])

    def test_expected_error(self):
        self.assertEqual(self.chk(tool_result("denied", True), {"isError": True, "contains": "denied"}), [])
        self.assertTrue(self.chk(tool_result("fine"), {"isError": True}))

    def test_contains_and_not_contains(self):
        r = tool_result("alpha beta")
        self.assertEqual(self.chk(r, {"contains": "beta", "not_contains": "gamma"}), [])
        self.assertEqual(self.chk(r, {"contains": ["alpha", "beta"], "not_contains": ["x", "y"]}), [])
        self.assertTrue(self.chk(r, {"contains": "gamma"}))
        self.assertTrue(self.chk(r, {"not_contains": "alpha"}))
        self.assertTrue(self.chk(r, {"contains": ["alpha", "gamma"]}))

    def test_json_expectations_from_text(self):
        r = tool_result(json.dumps({"cells": 4, "r": {"v": [1, 2]}, "ok": True}))
        self.assertEqual(self.chk(r, {"json": {"cells": 4, "r.v[1]": 2, "ok": True, "cells2": {"$exists": False}}}), [])
        fails = self.chk(r, {"json": {"cells": 5, "missing": 1}})
        self.assertEqual(len(fails), 2)
        self.assertTrue(self.chk(tool_result("not json"), {"json": {"a": 1}}))

    def test_json_prefers_structured_content(self):
        r = tool_result("ignored", structuredContent={"k": 1})
        self.assertEqual(self.chk(r, {"json": {"k": 1}}), [])

    def test_image(self):
        img = {"content": [{"type": "image", "data": "AAAA", "mimeType": "image/png"}], "isError": False}
        self.assertEqual(self.chk(img, {"image": True}), [])
        self.assertTrue(self.chk(tool_result("x"), {"image": True}))
        self.assertTrue(self.chk(img, {"image": False}))

    def test_unknown_key_fails(self):
        fails = self.chk(tool_result("x"), {"contain": "x"})
        self.assertEqual(len(fails), 1)
        self.assertIn("unknown expect key", fails[0])

    def test_text_helpers(self):
        r = {"content": [{"type": "text", "text": "a"}, {"type": "image", "data": ""},
                         {"type": "text", "text": "b"},
                         {"type": "resource", "resource": {"text": "c", "uri": "u"}}]}
        self.assertEqual(mcp_probe.result_text(r), "a\nb\nc")
        self.assertEqual(mcp_probe.result_text({"content": [], "structuredContent": {"a": 1}}), '{"a": 1}')
        self.assertEqual(mcp_probe.result_json(tool_result('{"a": 1}')), {"a": 1})
        self.assertIs(mcp_probe.result_json(tool_result("nope")), mcp_probe.MISSING)


class TestStepsFile(TmpCase):
    def test_valid_forms(self):
        steps = [{"tool": "t", "args": {"a": 1}, "expect": {}, "note": "n", "timeout": 5}]
        self.assertEqual(mcp_probe.load_steps(self.write_json("a.json", steps)), steps)
        self.assertEqual(mcp_probe.load_steps(self.write_json("b.json", {"steps": steps})), steps)

    def test_invalid(self):
        bad = [
            ("missing.json", None),
            ("e.json", []),
            ("o.json", {"tool": "x"}),
            ("n.json", [{"args": {}}]),
            ("a.json", [{"tool": "x", "args": [1]}]),
            ("x.json", [{"tool": "x", "expect": "no"}]),
            ("k.json", [{"tool": "x", "bogus": 1}]),
        ]
        for name, content in bad:
            p = self.path(name)
            if content is not None:
                self.write_json(name, content)
            with self.assertRaises(mcp_probe.UsageProblem, msg=name):
                mcp_probe.load_steps(p)
        with open(self.path("junk.json"), "w") as fh:
            fh.write("{oops")
        with self.assertRaises(mcp_probe.UsageProblem):
            mcp_probe.load_steps(self.path("junk.json"))


class TestResultHelpers(TmpCase):
    def test_sanitize_elides_and_saves_images(self):
        png = b"\x89PNG\r\n\x1a\n" + b"x" * 40
        r = {"content": [{"type": "text", "text": "hi"},
                         {"type": "image", "data": base64.b64encode(png).decode(), "mimeType": "image/png"}],
             "isError": False}
        out = mcp_probe.sanitize_result(r, self.path("imgs"), "render page")
        blk = out["content"][1]
        self.assertEqual(blk["bytes"], len(png))
        self.assertNotIn(base64.b64encode(png).decode(), json.dumps(out))
        with open(blk["savedTo"], "rb") as fh:
            self.assertEqual(fh.read(), png)
        self.assertTrue(blk["savedTo"].endswith(".png"))
        self.assertIn("data", r["content"][1])
        self.assertEqual(r["content"][1]["data"], base64.b64encode(png).decode())
        kept = mcp_probe.sanitize_result(r, keep_binary=True)
        self.assertEqual(kept["content"][1]["data"], base64.b64encode(png).decode())

    def test_summarize_tools_sorted_with_params(self):
        tools = [
            {"name": "zeta", "description": "z", "inputSchema": {"type": "object", "properties": {"b": {}, "a": {}},
                                                                    "required": ["a"]}},
            {"name": "alpha"},
        ]
        s = mcp_probe.summarize_tools(tools)
        self.assertEqual([t["name"] for t in s], ["alpha", "zeta"])
        self.assertEqual(s[0], {"name": "alpha", "description": "", "params": [], "required": []})
        self.assertEqual(s[1]["params"], ["b", "a"])
        self.assertEqual(s[1]["required"], ["a"])
        self.assertNotIn("inputSchema", s[1])
        self.assertIn("inputSchema", mcp_probe.summarize_tools(tools, full=True)[1])


# ---------------------------------------------------------------------------------------------
# mcp_probe: launch description (argv must come from expected_registration)
# ---------------------------------------------------------------------------------------------

class TestBuildLaunch(TmpCase):
    def setUp(self):
        TmpCase.setUp(self)
        self.prefix = self.path("bin")
        os.makedirs(self.prefix)
        for app in ("alpha", "beta", "gamma"):
            p = os.path.join(self.prefix, "%s-cli" % app)
            with open(p, "w") as fh:
                fh.write("#!/bin/sh\nexit 0\n")
            os.chmod(p, 0o755)
        self.ws = self.path("ws")

    def test_roots_and_root_argv_is_exactly_the_registration(self):
        for app in ("alpha", "beta"):
            exp = craftkit.expected_registration(app, self.ws, self.prefix, FENCE_LOCK)
            la = mcp_probe.build_launch(app, self.ws, self.prefix, FENCE_LOCK, environ={})
            self.assertEqual(la.argv, [exp["command"]] + exp["args"])
            self.assertEqual(la.root, os.path.join(self.ws, app))
            self.assertEqual(la.cwd, la.root)
            self.assertNotIn("CRAFT_SANDBOX_PROFILE", la.env)

    def test_sandbox_uses_kit_wrapper_and_profile_but_same_arguments(self):
        exp = craftkit.expected_registration("gamma", self.ws, self.prefix, FENCE_LOCK)
        la = mcp_probe.build_launch("gamma", self.ws, self.prefix, FENCE_LOCK, environ={"PATH": "/usr/bin"})
        self.assertEqual(la.argv[0], os.path.join(REPO, "bin", "craft-sandbox"))
        self.assertEqual(la.argv[1:], exp["args"])
        self.assertEqual(la.argv[1], os.path.join(self.ws, "gamma"))
        self.assertEqual(la.argv[2], os.path.join(self.prefix, "gamma-cli"))
        self.assertEqual(la.env["CRAFT_SANDBOX_PROFILE"], os.path.join(REPO, "share", "craft.sb"))
        self.assertEqual(la.env["PATH"], "/usr/bin")

    def test_explicit_profile_and_missing_profile(self):
        prof = self.write("p.sb", "(version 1)\n")
        la = mcp_probe.build_launch("gamma", self.ws, self.prefix, FENCE_LOCK, profile=prof, environ={})
        self.assertEqual(la.env["CRAFT_SANDBOX_PROFILE"], prof)
        with self.assertRaises(mcp_probe.StartError):
            mcp_probe.build_launch("gamma", self.ws, self.prefix, FENCE_LOCK, profile=self.path("none.sb"),
                                   environ={})

    def test_missing_cli_is_a_start_error_and_creates_nothing(self):
        with self.assertRaises(mcp_probe.StartError) as cm:
            mcp_probe.build_launch("alpha", self.ws, self.path("empty"), FENCE_LOCK, environ={})
        self.assertEqual(cm.exception.exit_code, 3)
        self.assertIn("not installed", str(cm.exception))
        self.assertFalse(os.path.exists(self.ws))

    def test_non_executable_cli_is_a_start_error(self):
        os.chmod(os.path.join(self.prefix, "beta-cli"), 0o644)
        with self.assertRaises(mcp_probe.StartError):
            mcp_probe.build_launch("beta", self.ws, self.prefix, FENCE_LOCK, environ={})


# ---------------------------------------------------------------------------------------------
# a fake stdio MCP server
# ---------------------------------------------------------------------------------------------

FAKE_SERVER = r'''
import base64, json, os, subprocess, sys, time

def log(obj):
    p = os.environ.get("FAKE_LOG")
    if p:
        with open(p, "a") as fh:
            fh.write(json.dumps(obj) + "\n")

pidfile = os.environ.get("FAKE_PID")
if pidfile:
    with open(pidfile, "w") as fh:
        fh.write(str(os.getpid()))
log({"argv": sys.argv[1:], "cwd": os.getcwd()})

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def schema(props, req=()):
    return {"type": "object", "properties": dict((k, {"type": "string"}) for k in props), "required": list(req)}

PAGE1 = [{"name": "zeta", "description": "last", "inputSchema": schema(["b", "a"], ["a"])},
         {"name": "echo", "description": "echo text", "inputSchema": schema(["text"], ["text"])}]
PAGE2 = [{"name": "alpha", "description": "first", "inputSchema": schema([])}]

initialized = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    log({"recv": msg})
    method, mid = msg.get("method"), msg.get("id")
    if method is None:
        continue
    if method == "notifications/initialized":
        initialized = True
        continue
    if method == "initialize":
        sys.stdout.write("plain stdout noise, not JSON\n")
        sys.stdout.flush()
        sys.stderr.write("warming up\n")
        sys.stderr.flush()
        send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "hi"}})
        send({"jsonrpc": "2.0", "id": "srv-1", "method": "ping"})
        send({"jsonrpc": "2.0", "id": "srv-2", "method": "roots/list"})
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake", "version": "9.9.9"}, "instructions": "fake instructions"}})
        continue
    if not initialized:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32002, "message": "not initialized"}})
        continue
    if method == "tools/list":
        if (msg.get("params") or {}).get("cursor") == "p2":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": PAGE2}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": PAGE1, "nextCursor": "p2"}})
        continue
    if method != "tools/call":
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "no such method"}})
        continue
    name = msg["params"]["name"]
    args = msg["params"].get("arguments") or {}
    def ok(text, **kw):
        r = {"content": [{"type": "text", "text": text}], "isError": False}
        r.update(kw)
        send({"jsonrpc": "2.0", "id": mid, "result": r})
    if name == "echo":
        ok(args.get("text", ""))
    elif name == "json":
        ok(json.dumps({"a": {"b": [10, 20]}, "n": 5, "s": "hi", "id": 42}))
    elif name == "argv":
        ok(json.dumps(sys.argv[1:]))
    elif name == "fail":
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "boom"}], "isError": True}})
    elif name == "rpcerror":
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "bad params", "data": {"x": 1}}})
    elif name == "image":
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [
            {"type": "text", "text": "rendered"},
            {"type": "image", "data": base64.b64encode(b"\x89PNG" + b"0" * 60).decode(), "mimeType": "image/png"}]}})
    elif name == "spawn":
        child = subprocess.Popen(["sleep", "300"])
        with open(args["pidfile"], "w") as fh:
            fh.write(str(child.pid))
        ok("spawned")
    elif name == "hang":
        time.sleep(3600)
    elif name == "die":
        sys.stderr.write("fatal: kaboom\n")
        sys.stderr.flush()
        sys.exit(3)
    else:
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "unknown tool " + name}], "isError": True}})
'''


class FakeServerCase(TmpCase):
    def setUp(self):
        TmpCase.setUp(self)
        self.server_py = self.write("fake_server.py", FAKE_SERVER)
        self.log = self.path("fake.log")
        self.pidfile = self.path("fake.pid")
        self.env = dict(os.environ, FAKE_LOG=self.log, FAKE_PID=self.pidfile)

    def client(self, timeout=10, argv_extra=()):
        c = mcp_probe.McpClient([sys.executable, self.server_py] + list(argv_extra), env=self.env, cwd=self.tmp,
                                timeout=timeout, label="fake")
        self.addCleanup(c.close)
        return c

    def log_lines(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as fh:
            return [json.loads(x) for x in fh if x.strip()]

    def server_pid(self):
        return read_int(self.pidfile)


class TestClient(FakeServerCase):
    def test_handshake_order_and_server_info(self):
        c = self.client().start()
        c.initialize()
        self.assertEqual(c.server_info, {"name": "fake", "version": "9.9.9"})
        self.assertEqual(c.instructions, "fake instructions")
        self.assertEqual(c.protocol_version, "2025-03-26")
        tools = c.list_tools()
        self.assertEqual([t["name"] for t in tools], ["zeta", "echo", "alpha"])
        methods = [m["recv"].get("method") for m in self.log_lines() if "recv" in m and "method" in m["recv"]]
        self.assertEqual(methods, ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        init = [m["recv"] for m in self.log_lines() if m.get("recv", {}).get("method") == "initialize"][0]
        self.assertIn("protocolVersion", init["params"])
        self.assertIn("capabilities", init["params"])
        self.assertIn("name", init["params"]["clientInfo"])
        self.assertNotIn("id", [m["recv"] for m in self.log_lines()
                                if m.get("recv", {}).get("method") == "notifications/initialized"][0])

    def test_tolerates_noise_notifications_and_answers_server_requests(self):
        c = self.client().start()
        c.initialize()
        c.list_tools()
        recvs = [m["recv"] for m in self.log_lines() if "recv" in m]
        pong = [r for r in recvs if r.get("id") == "srv-1"]
        self.assertEqual(pong[0].get("result"), {})
        nope = [r for r in recvs if r.get("id") == "srv-2"]
        self.assertEqual(nope[0]["error"]["code"], -32601)
        self.assertTrue(any("not JSON" in n for n in c.noise))
        self.assertTrue(any(n.get("method") == "notifications/message" for n in c.notifications))
        self.assertIn("warming up", c.stderr_tail())

    def test_call_results_and_errors(self):
        c = self.client().start()
        c.initialize()
        self.assertEqual(mcp_probe.result_text(c.call_tool("echo", {"text": "hello"})), "hello")
        self.assertTrue(c.call_tool("fail")["isError"])
        with self.assertRaises(mcp_probe.RpcError) as cm:
            c.call_tool("rpcerror")
        self.assertEqual((cm.exception.code, cm.exception.message, cm.exception.data), (-32602, "bad params", {"x": 1}))
        res = c.call_tool("image")
        self.assertEqual(len(mcp_probe.result_images(res)), 1)

    def test_timeout_kills_server_and_children(self):
        c = self.client(timeout=0.6).start()
        c.initialize()
        c.call_tool("spawn", {"pidfile": self.path("child.pid")})
        child = read_int(self.path("child.pid"))
        self.assertTrue(pid_alive(child))
        t0 = time.monotonic()
        with self.assertRaises(mcp_probe.CallTimeout):
            c.call_tool("hang")
        self.assertLess(time.monotonic() - t0, 6)
        self.assertTrue(wait_dead(self.server_pid()))
        self.assertTrue(wait_dead(child), "child of the server survived the timeout")

    def test_per_call_timeout_overrides_default(self):
        c = self.client(timeout=30).start()
        c.initialize()
        t0 = time.monotonic()
        with self.assertRaises(mcp_probe.CallTimeout):
            c.call_tool("hang", timeout=0.4)
        self.assertLess(time.monotonic() - t0, 6)

    def test_server_death_reports_stderr_and_exit_code(self):
        c = self.client().start()
        c.initialize()
        with self.assertRaises(mcp_probe.ServerExited) as cm:
            c.call_tool("die")
        self.assertIn("code 3", str(cm.exception))
        self.assertIn("fatal: kaboom", str(cm.exception))

    def test_close_reaps_group_even_after_clean_stdin_eof(self):
        c = self.client().start()
        c.initialize()
        c.call_tool("spawn", {"pidfile": self.path("child.pid")})
        child = read_int(self.path("child.pid"))
        c.close()
        self.assertTrue(wait_dead(self.server_pid()))
        self.assertTrue(wait_dead(child), "background child survived close()")
        c.close()

    def test_server_runs_in_its_own_process_group(self):
        c = self.client().start()
        c.initialize()
        self.assertNotEqual(os.getpgid(c.proc.pid), os.getpgrp())
        self.assertEqual(os.getpgid(c.proc.pid), c.proc.pid)

    def test_bad_executable_is_a_start_error(self):
        c = mcp_probe.McpClient([self.path("no-such-binary")], timeout=2)
        with self.assertRaises(mcp_probe.StartError):
            c.start()


# ---------------------------------------------------------------------------------------------
# mcp_probe command line, end to end against the fake server installed as <app>-cli
# ---------------------------------------------------------------------------------------------

class TestProbeCli(FakeServerCase):
    APP = "alpha"

    def setUp(self):
        FakeServerCase.setUp(self)
        self.prefix = self.path("bin")
        os.makedirs(self.prefix)
        cli = os.path.join(self.prefix, "%s-cli" % self.APP)
        with open(cli, "w") as fh:
            fh.write("#!/bin/sh\nexec '%s' '%s' \"$@\"\n" % (sys.executable.replace("'", "'\\''"),
                                                           self.server_py.replace("'", "'\\''")))
        os.chmod(cli, 0o755)
        self.lock = self.write_json("lock.json", {"schema": 1, "owner": "x", "apps": {
            self.APP: {"version": "1", "fence": "roots", "extraArgs": ["--author", "Claude"]}}})
        self.ws = self.path("ws")
        self.root = os.path.join(self.ws, self.APP)

    def probe(self, *args, **kw):
        base = ["--app", self.APP, "--workspace", self.ws, "--prefix", self.prefix, "--lock", self.lock]
        return run(PROBE_PY, base + list(args), self.env, **kw)

    def assert_server_gone(self):
        self.assertTrue(wait_for(self.pidfile))
        self.assertTrue(wait_dead(self.server_pid()), "server process left behind")

    def test_list_tools(self):
        code, out, err = self.probe("list-tools")
        self.assertEqual(code, 0, err)
        data = json.loads(out)
        self.assertEqual(data["server"], {"name": "fake", "version": "9.9.9"})
        self.assertEqual(data["instructions"], "fake instructions")
        self.assertEqual([t["name"] for t in data["tools"]], ["alpha", "echo", "zeta"])
        zeta = data["tools"][2]
        self.assertEqual((zeta["params"], zeta["required"], zeta["description"]), (["b", "a"], ["a"], "last"))
        self.assertNotIn("inputSchema", zeta)
        code, out, _ = self.probe("list-tools", "--full")
        self.assertIn("inputSchema", json.loads(out)["tools"][2])
        self.assert_server_gone()

    def test_server_is_started_with_the_registered_fence_argv(self):
        self.probe("list-tools")
        exp = craftkit.expected_registration(self.APP, self.ws, self.prefix, self.lock)
        started = [m for m in self.log_lines() if "argv" in m][0]
        self.assertEqual(started["argv"], exp["args"])
        self.assertEqual(started["argv"][:5], ["mcp", "--automation-read-root", self.root,
                                                "--automation-write-root", self.root])
        self.assertEqual(started["argv"][5:], ["--author", "Claude"])
        self.assertEqual(os.path.realpath(started["cwd"]), os.path.realpath(self.root))
        self.assertEqual(os.stat(self.root).st_mode & 0o777, 0o700)

    def test_options_work_before_and_after_the_subcommand(self):
        code, out, err = run(PROBE_PY, ["list-tools", "--app", self.APP, "--workspace", self.ws,
                                        "--prefix", self.prefix, "--lock", self.lock, "--timeout", "20"], self.env)
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["server"]["name"], "fake")

    def test_call_ok_error_and_protocol_error(self):
        code, out, _ = self.probe("call", "echo", "--args", '{"text": "hi {root}"}')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["content"][0]["text"], "hi " + self.root)
        code, out, _ = self.probe("call", "fail")
        self.assertEqual(code, 1)
        self.assertTrue(json.loads(out)["isError"])
        code, out, _ = self.probe("call", "rpcerror")
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["error"]["code"], -32602)
        self.assert_server_gone()

    def test_call_elides_and_saves_images(self):
        code, out, _ = self.probe("call", "image", "--save-dir", self.path("imgs"))
        self.assertEqual(code, 0)
        blk = json.loads(out)["content"][1]
        self.assertEqual(blk["bytes"], 64)
        self.assertTrue(os.path.exists(blk["savedTo"]))
        code, out, _ = self.probe("call", "image", "--keep-binary")
        self.assertGreater(len(json.loads(out)["content"][1]["data"]), 60)

    def write_steps(self, steps):
        return self.write_json("steps.json", steps)

    def test_run_steps_passes_with_templating(self):
        steps = self.write_steps([
            {"tool": "json", "args": {}, "expect": {"json": {"a.b[1]": 20, "n": {"$gt": 4}, "id": 42}},
             "note": "json"},
            {"tool": "echo", "args": {"text": "id={prev.id}"}, "expect": {"contains": "id=42"}},
            {"tool": "echo", "args": {"text": "{step1.s}|{prev}|{root}"},
             "expect": {"contains": "hi|id=42|" + self.root}},
            {"tool": "fail", "args": {}, "expect": {"isError": True, "contains": "boom"}},
            {"tool": "rpcerror", "args": {}, "expect": {"isError": True, "contains": "bad params"}},
            {"tool": "image", "args": {}, "expect": {"image": True, "contains": "rendered"}},
        ])
        code, out, err = self.probe("run", steps)
        self.assertEqual(code, 0, err + out)
        report = json.loads(out)
        self.assertTrue(report["ok"])
        self.assertEqual([s["ok"] for s in report["steps"]], [True] * 6)
        self.assertEqual(report["app"], self.APP)
        self.assertIn("ok   step 1 json - json", err)
        self.assert_server_gone()

    def test_run_steps_failing_expectation_stops_and_exits_1(self):
        steps = self.write_steps([
            {"tool": "echo", "args": {"text": "one"}, "expect": {"contains": "WRONG"}},
            {"tool": "echo", "args": {"text": "two"}},
        ])
        code, out, err = self.probe("run", steps)
        self.assertEqual(code, 1)
        report = json.loads(out)
        self.assertFalse(report["ok"])
        self.assertFalse(report["steps"][0]["ok"])
        self.assertTrue(report["steps"][1]["skipped"])
        self.assertIn("FAIL step 1", err)
        recv = [m["recv"] for m in self.log_lines() if m.get("recv", {}).get("method") == "tools/call"]
        self.assertEqual(len(recv), 1)

    def test_run_steps_keep_going(self):
        steps = self.write_steps([
            {"tool": "echo", "args": {"text": "one"}, "expect": {"contains": "WRONG"}},
            {"tool": "echo", "args": {"text": "two"}, "expect": {"contains": "two"}},
        ])
        code, out, _ = self.probe("run", steps, "--keep-going")
        self.assertEqual(code, 1)
        report = json.loads(out)
        self.assertEqual([s["ok"] for s in report["steps"]], [False, True])

    def test_unexpected_tool_error_fails_a_step_by_default(self):
        code, out, _ = self.probe("run", self.write_steps([{"tool": "fail", "args": {}}]))
        self.assertEqual(code, 1)
        self.assertIn("isError is true", json.loads(out)["steps"][0]["failures"][0])

    def test_bad_placeholder_fails_the_step_not_the_probe(self):
        steps = self.write_steps([{"tool": "echo", "args": {"text": "{prev}"}}])
        code, out, _ = self.probe("run", steps)
        self.assertEqual(code, 1)
        self.assertIn("first step", json.loads(out)["steps"][0]["failures"][0])

    def test_step_timeout_aborts_run_and_kills_server(self):
        steps = self.write_steps([
            {"tool": "hang", "args": {}, "timeout": 0.5},
            {"tool": "echo", "args": {"text": "never"}},
        ])
        t0 = time.monotonic()
        code, out, _ = self.probe("run", steps)
        self.assertEqual(code, 1)
        self.assertLess(time.monotonic() - t0, 10)
        report = json.loads(out)
        self.assertIn("no answer", report["steps"][0]["failures"][0])
        self.assertTrue(report["steps"][1]["skipped"])
        self.assert_server_gone()

    def test_global_timeout_flag(self):
        t0 = time.monotonic()
        code, _, err = self.probe("call", "hang", "--timeout", "0.7")
        self.assertEqual(code, 1)
        self.assertIn("no answer", err)
        self.assertLess(time.monotonic() - t0, 10)
        self.assert_server_gone()

    def test_server_dying_mid_call_exits_1_with_stderr(self):
        code, _, err = self.probe("call", "die")
        self.assertEqual(code, 1)
        self.assertIn("fatal: kaboom", err)

    def test_list_tools_first_call(self):
        ok = self.write_json("ok.json", [{"tool": "echo", "args": {"text": "hi"}, "expect": {"contains": "hi"}},
                                         {"tool": "die"}])
        code, out, err = self.probe("list-tools", "--first-call", ok)
        self.assertEqual(code, 0, err)
        data = json.loads(out)
        self.assertEqual(len(data["tools"]), 3)
        self.assertTrue(data["firstCall"]["ok"], data["firstCall"])
        self.assertEqual(data["firstCall"]["tool"], "echo")
        self.assert_server_gone()
        # a server that starts and lists tools but dies on its first real call
        dies = self.write_json("dies.json", [{"tool": "die"}])
        code, out, err = self.probe("list-tools", "--first-call", dies)
        self.assertEqual(code, 0, err)
        fc = json.loads(out)["firstCall"]
        self.assertFalse(fc["ok"])
        self.assertIn("exited", " ".join(fc["failures"]))
        # steps that name the workspace or chain results are only run by --smoke
        for text in ("{root}/x", "{prev}", "{step1.a}"):
            f = self.write_json("p.json", [{"tool": "echo", "args": {"text": text}}])
            code, out, err = self.probe("list-tools", "--first-call", f)
            self.assertEqual(code, 0, err)
            fc = json.loads(out)["firstCall"]
            self.assertTrue(fc["skipped"], (text, fc))
        self.assertFalse([m for m in self.log_lines() if m.get("recv", {}).get("method") == "tools/call"
                          and m["recv"]["params"]["arguments"].get("text", "").startswith("{")])

    def test_snapshot_writes_sorted_file_atomically(self):
        out_file = self.path("data", "tools", "alpha.json")
        code, out, err = self.probe("snapshot", "--out", out_file)
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "")
        with open(out_file, encoding="utf-8") as fh:
            snap = json.load(fh)
        self.assertEqual([t["name"] for t in snap["tools"]], ["alpha", "echo", "zeta"])
        self.assertEqual(snap["server"]["version"], "9.9.9")
        self.assertEqual(sorted(os.listdir(os.path.dirname(out_file))), ["alpha.json"])

    def test_usage_errors_exit_2_and_start_nothing(self):
        for args in (["call", "echo", "--args", "{nope"], ["call", "echo", "--args", "[1]"],
                     ["call", "echo", "--args", '{"t": "{prev}"}'], ["run", self.path("missing.json")],
                     ["run", self.write_json("empty.json", [])]):
            code, _, err = self.probe(*args)
            self.assertEqual(code, 2, (args, err))
        self.assertFalse(os.path.exists(self.pidfile))
        code, _, _ = run(PROBE_PY, ["list-tools", "--app", self.APP], self.env)
        self.assertEqual(code, 2)
        code, _, _ = run(PROBE_PY, ["--app", self.APP, "--workspace", self.ws, "--timeout", "0", "list-tools"],
                         self.env)
        self.assertEqual(code, 2)
        code, _, _ = self.probe("call")
        self.assertEqual(code, 2)

    def test_not_installed_exits_3_and_creates_no_workspace(self):
        code, _, err = run(PROBE_PY, ["--app", self.APP, "--workspace", self.ws, "--prefix", self.path("empty"),
                                      "--lock", self.lock, "list-tools"], self.env)
        self.assertEqual(code, 3)
        self.assertIn("not installed", err)
        self.assertFalse(os.path.exists(self.ws))

    def test_unknown_app_exits_2(self):
        code, _, _ = run(PROBE_PY, ["--app", "zzz", "--workspace", self.ws, "--prefix", self.prefix,
                                    "--lock", self.lock, "list-tools"], self.env)
        self.assertEqual(code, 2)

    def test_sigterm_to_the_probe_takes_the_server_group_down(self):
        env = dict(os.environ, FAKE_LOG=self.log, FAKE_PID=self.pidfile)
        env.pop("CRAFT_KIT_LOCK", None)
        proc = subprocess.Popen(
            [sys.executable, PROBE_PY, "--app", self.APP, "--workspace", self.ws, "--prefix", self.prefix,
             "--lock", self.lock, "call", "hang"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        try:
            self.assertTrue(wait_for(self.log, contains='"tools/call"'), "probe never reached the call")
            pid = self.server_pid()
            self.assertTrue(pid_alive(pid))
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=15)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        self.assertEqual(proc.returncode, 128 + signal.SIGTERM)
        self.assertTrue(wait_dead(pid), "server survived SIGTERM of the probe")


if __name__ == "__main__":
    unittest.main(verbosity=2)
