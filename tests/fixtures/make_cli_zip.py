#!/usr/bin/env python3
"""Build one fixture CLI release zip (deterministic: same inputs give the same bytes).

  make_cli_zip.py --app wordcraft --version 0.7.0 --fence roots --out FILE
                  [--layout nested|flat] [--no-fence-help] [--evil dotdot|nested-dotdot|abs]

The zip holds tests/fixtures/fake-cli.py (with the app's identity filled in) as an executable named
<app>-cli. layout "nested" mirrors the real releases: <app>-cli-<version>-macos-universal/<app>-cli plus
a README and a licence; "flat" puts <app>-cli at the top of the archive.

--no-fence-help builds a CLI whose --help does not advertise its fence flag(s) (the installer must then
refuse to register it). --evil adds a hostile entry next to the valid CLI so tests can check that the
installer rejects the whole archive: "../x", "<top>/../../x" or an absolute path.

Prints one line of JSON: {"path": ..., "sha256": ..., "size": ...}. Python 3.9+, standard library only.
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATE = (2024, 1, 1, 0, 0, 0)
SENTINEL = "craftkit-zipslip-sentinel.txt"


def _info(name, mode, is_dir=False):
    zi = zipfile.ZipInfo(name, DATE)
    zi.create_system = 3
    zi.compress_type = zipfile.ZIP_DEFLATED
    zi.external_attr = (mode << 16) | (0x10 if is_dir else 0)
    return zi


def build(app, version, fence, out, layout="nested", advertise=True, evil=None):
    with open(os.path.join(HERE, "fake-cli.py"), "r", encoding="utf-8") as fh:
        source = fh.read()
    for token, value in (("@APP@", app), ("@VERSION@", version), ("@FENCE@", fence),
                         ("@ADVERTISE@", "yes" if advertise else "no")):
        source = source.replace(token, value)
    top = "%s-cli-%s-macos-universal" % (app, version)
    prefix = "" if layout == "flat" else top + "/"
    entries = []
    if prefix:
        entries.append((_info(prefix, 0o40755, True), b""))
    entries.append((_info(prefix + app + "-cli", 0o100755), source.encode("utf-8")))
    entries.append((_info(prefix + "README.md", 0o100644),
                    ("# %s-cli %s\n\nFixture build for craft-claude-kit tests. Not a real release.\n" % (app, version)).encode("utf-8")))
    entries.append((_info(prefix + "LICENSE-APACHE", 0o100644), b"Fixture licence placeholder.\n"))
    if evil == "dotdot":
        entries.append((_info("../" + SENTINEL, 0o100644), b"escaped\n"))
    elif evil == "nested-dotdot":
        entries.append((_info(top + "/../../" + SENTINEL, 0o100644), b"escaped\n"))
    elif evil == "abs":
        entries.append((_info("/tmp/" + SENTINEL, 0o100644), b"escaped\n"))
    elif evil:
        raise SystemExit("unknown --evil kind: %s" % evil)
    tmp = "%s.tmp-%d" % (out, os.getpid())
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        for zi, data in entries:
            zf.writestr(zi, data)
    os.replace(tmp, out)
    digest = hashlib.sha256()
    with open(out, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return {"path": os.path.abspath(out), "sha256": digest.hexdigest(), "size": os.path.getsize(out)}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--app", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--fence", required=True, choices=("roots", "root", "sandbox"))
    p.add_argument("--out", required=True)
    p.add_argument("--layout", choices=("nested", "flat"), default="nested")
    p.add_argument("--no-fence-help", action="store_true")
    p.add_argument("--evil", choices=("dotdot", "nested-dotdot", "abs"))
    ns = p.parse_args(argv)
    result = build(ns.app, ns.version, ns.fence, ns.out, ns.layout, not ns.no_fence_help, ns.evil)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
