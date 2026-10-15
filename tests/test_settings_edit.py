#!/usr/bin/env python3
"""Tests for lib/settings_edit.py (plain unittest; run: python3 tests/test_settings_edit.py).

Every test works on a throw-away folder; nothing outside it is read or written."""
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "lib", "settings_edit.py"))
CMD = "python3 /kit/hooks/craft-shell-guard.py --workspace /ws"
CMD2 = "python3 /kit/hooks/craft-mcp-guard.py --workspace /ws"
MCP_MATCHER = "mcp__(wordcraft|gridcraft)__.*"
BACKUP_RE = re.compile(r"\.bak-craft-kit-\d{8}-\d{6}(-\d+)?$")


def load_module():
    spec = importlib.util.spec_from_file_location("settings_edit_under_test", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="se-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, "settings.json")

    def run_cli(self, *args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        return p.returncode, p.stdout, p.stderr

    def add(self, command=CMD, matcher="Bash", event="PreToolUse", timeout=None, path=None):
        args = ["add-hook", "--settings", path or self.path, "--event", event, "--matcher", matcher,
                "--command", command]
        if timeout is not None:
            args += ["--timeout", str(timeout)]
        return self.run_cli(*args)

    def remove(self, needle, event="PreToolUse", path=None):
        return self.run_cli("remove-hook", "--settings", path or self.path, "--event", event,
                            "--command-contains", needle)

    def write(self, text, path=None, mode=None):
        p = path or self.path
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(text if isinstance(text, bytes) else text.encode("utf-8"))
        if mode is not None:
            os.chmod(p, mode)
        return p

    def read(self, path=None):
        with open(path or self.path, "rb") as f:
            return f.read()

    def load(self, path=None):
        return json.loads(self.read(path).decode("utf-8"))

    def backups(self, folder=None):
        folder = folder or self.tmp
        return sorted(n for n in os.listdir(folder) if BACKUP_RE.search(n))

    def leftovers(self, folder=None):
        return [n for n in os.listdir(folder or self.tmp) if n.endswith(".tmp") or n.startswith(".settings-edit")]


SAMPLE = {
    "env": {"FOO": "bar", "UNICODE": "café — 日本"},
    "permissions": {"allow": ["Bash(ls:*)", "Read"], "deny": []},
    "hooks": {
        "PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "prettier --write"}]}],
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "other-guard.sh", "timeout": 3}]},
            {"matcher": "Edit", "hooks": [{"type": "command", "command": "lint-first.sh"}]},
        ],
        "Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}],
    },
    "statusLine": {"type": "command", "command": "status.sh"},
    "model": "opus",
}


class MissingAndNewFile(Base):
    def test_missing_file_is_created(self):
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        self.assertTrue(out.startswith("added"), out)
        self.assertEqual(self.load(), {"hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": CMD}]}]}})
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.leftovers(), [])

    def test_missing_file_gets_normal_new_file_permissions(self):
        mask = os.umask(0)
        os.umask(mask)
        self.add()
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o666 & ~mask)

    def test_missing_parent_folder_is_created(self):
        path = os.path.join(self.tmp, "nested", ".claude", "settings.json")
        rc, out, err = self.add(path=path)
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.isfile(path))

    def test_remove_and_list_on_a_missing_file_do_not_create_it(self):
        rc, out, err = self.remove("anything")
        self.assertEqual(rc, 0, err)
        self.assertIn("nothing to remove", out)
        rc, out, err = self.run_cli("list-hooks", "--settings", self.path)
        self.assertEqual((rc, out.strip()), (0, ""))
        self.assertFalse(os.path.exists(self.path))

    def test_empty_object_file(self):
        self.write("{}\n")
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.load()["hooks"]["PreToolUse"][0]["hooks"][0]["command"], CMD)
        self.assertEqual(len(self.backups()), 1)


class InvalidFilesAreNeverTouched(Base):
    BAD = [
        ("trailing comma", b'{"a": 1,}'),
        ("truncated", b'{"a": '),
        ("comment", b'// hi\n{"a": 1}'),
        ("block comment", b'{"a": 1 /* x */}'),
        ("single quotes", b"{'a': 1}"),
        ("NaN", b'{"a": NaN}'),
        ("Infinity", b'{"a": Infinity}'),
        ("duplicate key", b'{"a": 1, "a": 2}'),
        ("nested duplicate key", b'{"hooks": {"x": 1, "x": 2}}'),
        ("top-level list", b"[]"),
        ("top-level string", b'"x"'),
        ("top-level null", b"null"),
        ("empty file", b""),
        ("whitespace only", b"  \n"),
        ("invalid utf-8", b'{"a": "\xff\xfe"}'),
        ("byte order mark", b'\xef\xbb\xbf{"a": 1}'),
        ("hooks is a list", b'{"hooks": []}'),
        ("hooks is null", b'{"hooks": null}'),
        ("event is an object", b'{"hooks": {"PreToolUse": {}}}'),
        ("event is a string", b'{"hooks": {"PreToolUse": "x"}}'),
        # Valid JSON, but Python reads it as inf and would write back the bare token Infinity (R1-CONFIG-7).
        ("out-of-range number", b'{"budget": 1e400}'),
        ("out-of-range negative number", b'{"hooks": {}, "x": -1E999}'),
    ]

    def test_add_aborts_and_changes_nothing(self):
        for label, raw in self.BAD:
            with self.subTest(case=label):
                self.write(raw)
                rc, out, err = self.add()
                self.assertEqual(rc, 1, (out, err))
                self.assertEqual(self.read(), raw)
                self.assertEqual(self.backups(), [])
                self.assertEqual(self.leftovers(), [])
                self.assertTrue(err.strip())
                self.assertEqual(out.strip(), "")

    def test_remove_and_list_abort_on_unparsable_files(self):
        for label, raw in self.BAD[:16]:
            with self.subTest(case=label):
                self.write(raw)
                self.assertEqual(self.remove("x")[0], 1)
                self.assertEqual(self.run_cli("list-hooks", "--settings", self.path)[0], 1)
                self.assertEqual(self.read(), raw)
                self.assertEqual(self.backups(), [])

    def test_the_message_explains_what_to_do(self):
        self.write(b'{"a": 1,}')
        rc, out, err = self.add()
        self.assertIn("not valid JSON", err)
        self.assertIn("Nothing was changed", err)

    def test_large_exponent_numbers_keep_their_value(self):
        # Accepted: 1E2 is rewritten as 100.0 when the file changes (same value, other spelling).
        self.write(b'{"budget": 1E2}')
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.load()["budget"], 100.0)
        self.assertNotIn(b"Infinity", self.read())

    def test_a_directory_is_refused(self):
        os.mkdir(self.path)
        rc, out, err = self.add()
        self.assertEqual(rc, 1)
        self.assertIn("directory", err)


class PreservationAndOrder(Base):
    def test_unrelated_hooks_and_keys_are_preserved_in_order(self):
        self.write(json.dumps(SAMPLE, indent=2, ensure_ascii=False) + "\n")
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        after = self.load()
        expected = json.loads(json.dumps(SAMPLE))
        expected["hooks"]["PreToolUse"].append(
            {"matcher": "Bash", "hooks": [{"type": "command", "command": CMD}]})
        self.assertEqual(after, expected)
        self.assertEqual(list(after), list(SAMPLE))
        self.assertEqual(list(after["hooks"]), list(SAMPLE["hooks"]))
        self.assertEqual(list(after["hooks"]["PreToolUse"][0]), ["matcher", "hooks"])
        self.assertEqual([g["hooks"][0]["command"] for g in after["hooks"]["PreToolUse"]],
                         ["other-guard.sh", "lint-first.sh", CMD])
        self.assertIn("café — 日本".encode("utf-8"), self.read())

    def test_two_hooks_land_as_separate_groups_after_the_users_own(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        self.add()
        self.add(CMD2, MCP_MATCHER)
        groups = self.load()["hooks"]["PreToolUse"]
        self.assertEqual([g.get("matcher") for g in groups], ["Bash", "Edit", "Bash", MCP_MATCHER])
        self.assertEqual(groups[2]["hooks"][0]["command"], CMD)
        self.assertEqual(groups[3]["hooks"][0]["command"], CMD2)

    def test_a_new_event_is_appended_after_existing_events(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        rc, out, err = self.add(event="UserPromptSubmit", matcher="")
        self.assertEqual(rc, 0, err)
        hooks = self.load()["hooks"]
        self.assertEqual(list(hooks)[-1], "UserPromptSubmit")
        self.assertEqual(hooks["UserPromptSubmit"], [{"hooks": [{"type": "command", "command": CMD}]}])

    def test_hooks_key_is_added_at_the_end_when_missing(self):
        self.write('{"model": "opus", "env": {}}\n')
        self.add()
        self.assertEqual(list(self.load()), ["model", "env", "hooks"])

    def test_same_command_with_another_matcher_is_a_new_entry(self):
        self.add()
        rc, out, err = self.add(matcher="Write")
        self.assertTrue(out.startswith("added"), out)
        self.assertEqual([g["matcher"] for g in self.load()["hooks"]["PreToolUse"]], ["Bash", "Write"])

    def test_same_matcher_with_another_command_is_a_new_entry(self):
        self.add()
        rc, out, err = self.add(command=CMD2)
        self.assertTrue(out.startswith("added"), out)
        self.assertEqual(len(self.load()["hooks"]["PreToolUse"]), 2)

    def test_existing_identical_entry_written_by_hand_is_recognised(self):
        data = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "other.sh"}, {"type": "command", "command": CMD}]}]}}
        raw = json.dumps(data, indent=2).encode() + b"\n"
        self.write(raw)
        rc, out, err = self.add()
        self.assertTrue(out.startswith("unchanged"), out)
        self.assertEqual(self.read(), raw)

    def test_timeout_is_written_and_updated(self):
        self.add(timeout=5)
        self.assertEqual(self.load()["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"], 5)
        rc, out, err = self.add(timeout=5)
        self.assertTrue(out.startswith("unchanged"), out)
        rc, out, err = self.add(timeout=9)
        self.assertTrue(out.startswith("updated"), out)
        self.assertEqual(self.load()["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"], 9)
        rc, out, err = self.add()
        self.assertTrue(out.startswith("unchanged"), out)

    def test_indentation_line_endings_and_trailing_newline_follow_the_file(self):
        base = {"model": "opus", "hooks": {}}
        for label, indent, eol, trailing in (("4 spaces", 4, "\n", True), ("tab", "\t", "\n", True),
                                             ("no trailing newline", 2, "\n", False), ("crlf", 2, "\r\n", True)):
            with self.subTest(style=label):
                text = json.dumps(base, indent=indent).replace("\n", eol) + (eol if trailing else "")
                self.write(text)
                self.add()
                raw = self.read().decode("utf-8")
                self.assertEqual(raw.endswith(eol), trailing)
                if eol == "\r\n":
                    self.assertNotIn("\n", raw.replace("\r\n", ""))
                unit = indent if indent == "\t" else " " * indent
                self.assertIn(eol + unit + '"model"', raw)
                self.assertEqual(self.load()["hooks"]["PreToolUse"][0]["hooks"][0]["command"], CMD)


class Idempotency(Base):
    def test_re_adding_changes_nothing_and_makes_no_backup(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        self.add()
        raw = self.read()
        mtime = os.stat(self.path).st_mtime_ns
        for _ in range(3):
            rc, out, err = self.add()
            self.assertEqual(rc, 0, err)
            self.assertTrue(out.startswith("unchanged"), out)
        self.assertEqual(self.read(), raw)
        self.assertEqual(os.stat(self.path).st_mtime_ns, mtime)
        self.assertEqual(len(self.backups()), 1)

    def test_a_hand_formatted_file_is_not_reformatted_when_nothing_changes(self):
        raw = ('{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s"}]}]},'
               '   "model":"opus"}' % CMD).encode()
        self.write(raw)
        rc, out, err = self.add()
        self.assertTrue(out.startswith("unchanged"), out)
        self.assertEqual(self.read(), raw)
        self.assertEqual(self.backups(), [])


class Removal(Base):
    def test_remove_drops_the_entry_its_empty_group_event_and_hooks_key(self):
        self.add()
        rc, out, err = self.remove("craft-shell-guard.py")
        self.assertEqual(rc, 0, err)
        self.assertIn("removed: 1", out)
        self.assertEqual(self.load(), {})

    def test_remove_keeps_everything_else(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        self.add()
        self.add(CMD2, MCP_MATCHER)
        rc, out, err = self.remove("craft-shell-guard.py")
        self.assertEqual(rc, 0, err)
        after = self.load()
        expected = json.loads(json.dumps(SAMPLE))
        expected["hooks"]["PreToolUse"].append(
            {"matcher": MCP_MATCHER, "hooks": [{"type": "command", "command": CMD2}]})
        self.assertEqual(after, expected)
        self.assertEqual(list(after["hooks"]["PreToolUse"][-1]), ["matcher", "hooks"])

    def test_remove_keeps_sibling_hooks_in_the_same_group(self):
        legacy = "python3 /home/u/.local/share/craft-skills/craft-shell-guard.py"
        data = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "keep-me.sh", "timeout": 2},
            {"type": "command", "command": legacy},
            {"type": "command", "command": "keep-me-too.sh"}]}, "not-a-group", 5]}}
        self.write(json.dumps(data, indent=2) + "\n")
        rc, out, err = self.remove("craft-skills/craft-shell-guard.py")
        self.assertEqual(rc, 0, err)
        after = self.load()["hooks"]["PreToolUse"]
        self.assertEqual([h["command"] for h in after[0]["hooks"]], ["keep-me.sh", "keep-me-too.sh"])
        self.assertEqual(after[0]["hooks"][0]["timeout"], 2)
        self.assertEqual(after[1:], ["not-a-group", 5])

    def test_remove_matches_across_matchers_and_counts(self):
        self.add()
        self.add(matcher="Write")
        rc, out, err = self.remove("craft-shell-guard.py")
        self.assertIn("removed: 2", out)
        self.assertEqual(self.load(), {})

    def test_remove_without_a_match_changes_nothing_and_makes_no_backup(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        raw = self.read()
        rc, out, err = self.remove("not-there.py")
        self.assertEqual(rc, 0, err)
        self.assertIn("nothing to remove", out)
        self.assertEqual(self.read(), raw)
        self.assertEqual(self.backups(), [])
        rc, out, err = self.remove("lint-first.sh", event="PostToolUse")
        self.assertIn("nothing to remove", out)
        self.assertEqual(self.read(), raw)

    def test_remove_is_scoped_to_the_event(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        rc, out, err = self.remove("notify.sh", event="PreToolUse")
        self.assertIn("nothing to remove", out)
        rc, out, err = self.remove("notify.sh", event="Stop")
        self.assertIn("removed: 1", out)
        self.assertNotIn("Stop", self.load()["hooks"])

    def test_remove_then_add_round_trips(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        before = self.load()
        self.add()
        self.remove("craft-shell-guard.py")
        self.assertEqual(self.load(), before)


class Backups(Base):
    def test_backup_is_created_once_per_change_and_holds_the_previous_bytes(self):
        original = (json.dumps(SAMPLE, indent=2) + "\n").encode()
        self.write(original)
        rc, out, err = self.add()
        self.assertEqual(len(self.backups()), 1)
        first = os.path.join(self.tmp, self.backups()[0])
        self.assertIn("backup: " + first, out)
        with open(first, "rb") as f:
            self.assertEqual(f.read(), original)
        after_add = self.read()
        self.add()
        self.add()
        self.assertEqual(len(self.backups()), 1)
        self.remove("not-there")
        self.assertEqual(len(self.backups()), 1)
        self.remove("craft-shell-guard.py")
        self.assertEqual(len(self.backups()), 2)
        self.assertIn(after_add, [self.read(os.path.join(self.tmp, b)) for b in self.backups()])

    def test_backups_made_in_the_same_second_do_not_overwrite_each_other(self):
        self.write("{}\n")
        for i in range(4):
            self.add(command="cmd-%d" % i)
        names = self.backups()
        self.assertEqual(len(names), 4)
        self.assertEqual(len(set(names)), 4)

    def test_backup_keeps_the_file_mode(self):
        self.write("{}\n", mode=0o600)
        self.add()
        backup = os.path.join(self.tmp, self.backups()[0])
        self.assertEqual(stat.S_IMODE(os.stat(backup).st_mode), 0o600)

    def test_no_backup_for_a_new_file(self):
        self.add()
        self.assertEqual(self.backups(), [])

    def test_backup_tag_makes_one_backup_per_run_holding_the_state_before_the_run(self):
        original = b"{}\n"
        self.write(original)
        for i in range(3):
            rc, out, err = self.run_cli("add-hook", "--settings", self.path, "--event", "PreToolUse",
                                        "--matcher", "Bash", "--command", "cmd-%d" % i, "--backup-tag", "20260101-000000")
            self.assertEqual(rc, 0, err)
        rc, out, err = self.run_cli("remove-hook", "--settings", self.path, "--event", "PreToolUse",
                                    "--command-contains", "cmd-1", "--backup-tag", "20260101-000000")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.backups(), ["settings.json.bak-craft-kit-20260101-000000"])
        self.assertEqual(self.read(os.path.join(self.tmp, self.backups()[0])), original)

    def test_backup_tag_is_validated(self):
        self.write("{}\n")
        rc, out, err = self.run_cli("add-hook", "--settings", self.path, "--event", "PreToolUse",
                                    "--matcher", "Bash", "--command", "x", "--backup-tag", "../evil")
        self.assertEqual(rc, 2)
        self.assertEqual(self.backups(), [])


class FileModeAndAtomicity(Base):
    def test_existing_file_mode_is_kept(self):
        for mode in (0o600, 0o640, 0o644, 0o660, 0o664):
            with self.subTest(mode=oct(mode)):
                self.write(json.dumps({"n": mode}) + "\n", mode=mode)
                self.add(command="cmd-%o" % mode)
                self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), mode)

    def test_no_temp_files_are_left_behind(self):
        self.write("{}\n")
        self.add()
        self.remove("craft-shell-guard.py")
        self.add()
        self.assertEqual(self.leftovers(), [])

    def test_write_is_refused_when_the_file_changed_underneath(self):
        mod = load_module()
        self.write('{"a": 1}\n')
        with self.assertRaises(mod.EditError):
            mod.write_atomic(self.path, b'{"a": 2}\n', 0o644, b'{"a": 0}\n')
        self.assertEqual(self.read(), b'{"a": 1}\n')
        self.assertEqual(self.leftovers(), [])

    def test_write_is_refused_when_a_new_file_appeared_underneath(self):
        mod = load_module()
        self.write('{"a": 1}\n')
        with self.assertRaises(mod.EditError):
            mod.write_atomic(self.path, b'{"a": 2}\n', 0o644, None)
        self.assertEqual(self.read(), b'{"a": 1}\n')

    def test_unwritable_folder_is_reported_not_crashed(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores folder permissions")
        folder = os.path.join(self.tmp, "ro")
        os.mkdir(folder)
        path = self.write("{}\n", path=os.path.join(folder, "settings.json"))
        os.chmod(folder, 0o500)
        self.addCleanup(os.chmod, folder, 0o700)
        rc, out, err = self.add(path=path)
        self.assertEqual(rc, 1)
        self.assertTrue(err.strip())
        self.assertEqual(self.read(path), b"{}\n")


class Symlinks(Base):
    def test_a_symlinked_settings_file_is_written_through(self):
        real_dir = os.path.join(self.tmp, "dotfiles")
        os.mkdir(real_dir)
        real = self.write(json.dumps(SAMPLE, indent=2) + "\n", path=os.path.join(real_dir, "claude-settings.json"),
                          mode=0o640)
        link_dir = os.path.join(self.tmp, "home-claude")
        os.mkdir(link_dir)
        link = os.path.join(link_dir, "settings.json")
        os.symlink(real, link)
        original = self.read(real)
        rc, out, err = self.add(path=link)
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link), os.path.realpath(real))
        self.assertEqual(self.load(real)["hooks"]["PreToolUse"][-1]["hooks"][0]["command"], CMD)
        self.assertEqual(self.load(link), self.load(real))
        self.assertEqual(stat.S_IMODE(os.stat(real).st_mode), 0o640)
        backups = self.backups(link_dir)
        self.assertEqual(len(backups), 1)
        self.assertTrue(backups[0].startswith("settings.json.bak-craft-kit-"))
        self.assertFalse(os.path.islink(os.path.join(link_dir, backups[0])))
        with open(os.path.join(link_dir, backups[0]), "rb") as f:
            self.assertEqual(f.read(), original)
        self.assertEqual(self.backups(real_dir), [])
        self.assertEqual(self.leftovers(real_dir), [])
        self.assertEqual(self.leftovers(link_dir), [])

    def test_chained_symlinks(self):
        real = self.write("{}\n", path=os.path.join(self.tmp, "a", "real.json"))
        os.symlink(real, os.path.join(self.tmp, "b.json"))
        os.symlink(os.path.join(self.tmp, "b.json"), self.path)
        self.add()
        self.assertTrue(os.path.islink(self.path))
        self.assertIn("hooks", self.load(real))

    def test_a_symlink_to_a_missing_file_creates_the_target(self):
        target = os.path.join(self.tmp, "dotfiles", "settings.json")
        os.makedirs(os.path.dirname(target))
        os.symlink(target, self.path)
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.islink(self.path))
        self.assertIn("hooks", self.load(target))

    def test_an_invalid_file_behind_a_symlink_is_untouched(self):
        real = self.write(b'{"a": 1,}', path=os.path.join(self.tmp, "real.json"))
        os.symlink(real, self.path)
        rc, out, err = self.add()
        self.assertEqual(rc, 1)
        self.assertEqual(self.read(real), b'{"a": 1,}')
        self.assertTrue(os.path.islink(self.path))


class ListHooks(Base):
    def test_text_output(self):
        self.write(json.dumps(SAMPLE, indent=2) + "\n")
        self.add()
        rc, out, err = self.run_cli("list-hooks", "--settings", self.path)
        self.assertEqual(rc, 0, err)
        lines = out.splitlines()
        self.assertIn("PreToolUse\tBash\tother-guard.sh", lines)
        self.assertIn("PreToolUse\tBash\t" + CMD, lines)
        self.assertIn("Stop\t\tnotify.sh", lines)
        self.assertEqual(len(lines), 5)

    def test_json_output(self):
        self.add(timeout=7)
        rc, out, err = self.run_cli("list-hooks", "--settings", self.path, "--json")
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out), [{"event": "PreToolUse", "matcher": "Bash", "type": "command",
                                            "command": CMD, "timeout": 7}])

    def test_list_does_not_modify_the_file(self):
        self.write(json.dumps(SAMPLE, indent=4))
        raw = self.read()
        mtime = os.stat(self.path).st_mtime_ns
        self.run_cli("list-hooks", "--settings", self.path)
        self.assertEqual((self.read(), os.stat(self.path).st_mtime_ns), (raw, mtime))
        self.assertEqual(self.backups(), [])


class UsageErrors(Base):
    def test_exit_code_2(self):
        cases = [
            [],
            ["bogus"],
            ["add-hook"],
            ["add-hook", "--event", "PreToolUse", "--command", "x"],
            ["add-hook", "--settings", self.path, "--command", "x"],
            ["add-hook", "--settings", self.path, "--event", "PreToolUse"],
            ["add-hook", "--settings", self.path, "--event", "PreToolUse", "--command", "x", "--timeout", "0"],
            ["add-hook", "--settings", self.path, "--event", "PreToolUse", "--command", "x", "--timeout", "abc"],
            ["remove-hook", "--settings", self.path, "--event", "PreToolUse"],
            ["remove-hook", "--settings", self.path, "--event", "PreToolUse", "--command-contains", ""],
            ["list-hooks"],
        ]
        for args in cases:
            with self.subTest(args=args):
                rc, out, err = self.run_cli(*args)
                self.assertEqual(rc, 2, (out, err))
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(self.backups(), [])


class Scale(Base):
    def test_a_large_settings_file(self):
        big = {"env": dict(("K%d" % i, "v" * 50) for i in range(5000)), "hooks": {}}
        self.write(json.dumps(big, indent=2) + "\n")
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        after = self.load()
        self.assertEqual(after["env"], big["env"])
        self.assertEqual(list(after["env"]), list(big["env"]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
