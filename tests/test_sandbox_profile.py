#!/usr/bin/env python3
"""Regression tests for share/craft.sb's Mach-lookup rule.

The blanket (deny mach-lookup) closes the LaunchServices route out of the sandbox; Metal's shader
compiler is the one service GPU apps need (LightCraft aborts with exit -6 without it). These tests fail
if the exception disappears, if it is widened, or if the deny stops being in force."""
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE = os.path.join(REPO, "share", "craft.sb")
WRAPPER = os.path.join(REPO, "bin", "craft-sandbox")
METAL = "com.apple.MTLCompilerService"


def rules():
    out = []
    with open(PROFILE) as fh:
        for line in fh:
            line = line.split(";", 1)[0].strip()
            if line:
                out.append(line)
    return out


class TestProfileText(unittest.TestCase):
    def test_blanket_mach_deny_present(self):
        self.assertIn("(deny mach-lookup)", rules())

    def test_only_metal_compiler_is_allowed(self):
        allows = [r for r in rules() if r.startswith("(allow mach-lookup")]
        self.assertEqual(allows, ['(allow mach-lookup (xpc-service-name "%s"))' % METAL])

    def test_exception_comes_after_the_deny(self):
        r = rules()
        deny = r.index("(deny mach-lookup)")
        allow = next(i for i, x in enumerate(r) if x.startswith("(allow mach-lookup"))
        self.assertLess(deny, allow, "rules are last-match-wins; an allow before the deny is dead")

    def test_no_mach_wildcards(self):
        for r in rules():
            if "mach" in r:
                self.assertIsNone(re.search(r"global-name-regex|xpc-service-name-regex|global-name-prefix", r), r)


@unittest.skipUnless(sys.platform == "darwin" and os.access("/usr/bin/sandbox-exec", os.X_OK), "macOS only")
class TestProfileLive(unittest.TestCase):
    def run_sandboxed(self, *argv):
        root = tempfile.mkdtemp(prefix="craft-sb-test.")
        try:
            env = dict(os.environ, CRAFT_SANDBOX_PROFILE=PROFILE)
            return subprocess.run([WRAPPER, root] + list(argv), env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        finally:
            os.rmdir(root)

    def test_mach_deny_in_force(self):
        # User-name lookups go through a Mach service; under the deny `id -un` falls back to the number.
        p = self.run_sandboxed("/usr/bin/id", "-un")
        self.assertTrue(p.stdout.strip().isdigit() or p.returncode != 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
