#!/usr/bin/env bash
# Tests for doctor.sh and lib/doctor_checks.py (bash 3.2).
#
# Part 1 (always runs): usage handling and the doctor_checks.py helpers on throwaway files, with
#   HOME pointed at a temp folder. The fence-live checks run the real /usr/bin/sandbox-exec through
#   this kit's bin/craft-sandbox: once with share/craft.sb (must PASS) and once with a profile that
#   allows everything (must FAIL).
# Part 2 (end to end): every doctor.sh run goes through tests/isolated.sh (fake HOME, fake claude,
#   fixture apps, offline downloads): before install, after install.sh --yes, from the KIT_HOME
#   runtime copy, --smoke cleanup, and two deliberate breakages. Skipped with a note while
#   tests/isolated.sh, tests/fixtures/apps.lock.json or install.sh is missing.
set -euo pipefail

REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/doctor.sh
CHECKS=$REPO/lib/doctor_checks.py
T=$(mktemp -d "${TMPDIR:-/tmp}/test-doctor.XXXXXX")
T=$(cd -P "$T" && pwd)
trap 'rm -rf "$T"' EXIT
PASSES=0 FAILS=0 SKIPS=0
US=$'\037'

ok() { PASSES=$((PASSES + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'skip  %s\n' "$1"; }
check() { # DESC CMD... : ok if CMD succeeds
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

expect_rc() { # WANT DESC CMD...
  local want=$1 desc=$2 rc=0
  shift 2
  "$@" > "$T/out" 2> "$T/err" < /dev/null || rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "$desc" "exit $rc, wanted $want: $(head -c 400 "$T/err")"; fi
}

# record FILE SCOPE ID -> "STATUS<US>DETAIL" of the first matching record, or MISSING
record() {
  local s i st d
  while IFS=$US read -r s i st d _ || [ -n "$s" ]; do
    if [ "$s" = "$2" ] && [ "$i" = "$3" ]; then printf '%s%s%s' "$st" "$US" "$d"; return 0; fi
  done < "$1"
  printf 'MISSING'
}
expect_rec() { # FILE SCOPE ID WANT DESC
  local got
  got=$(record "$1" "$2" "$3")
  if [ "${got%%"$US"*}" = "$4" ]; then ok "$5"; else bad "$5" "$2/$3: ${got//$US/: }"; fi
}
expect_meta() { # FILE KEY WANT DESC
  if grep -q "^META${US}$2${US}$3${US}" "$1"; then ok "$4"; else bad "$4" "META $2 != $3 in: $(tr "$US" ' ' < "$1" | head -c 400)"; fi
}

# jexpect JSON LOCK EXPECTATION... ; expectations: scope/id=STATUS[|STATUS], where scope may be
# @all (every app in LOCK), @sandbox / @flags (apps by fence); plus "nocrash" and "summary".
cat > "$T/jexpect.py" <<'EOF'
import json, sys
path, lock_path, exps = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    doc = json.load(open(path))
except ValueError as exc:
    print("FAIL\tvalid JSON\t%s" % exc)
    sys.exit(0)
apps = json.load(open(lock_path))["apps"]
idx = {}
for c in doc["checks"]:
    idx.setdefault((c["scope"], c["id"]), c)
for e in exps:
    if e == "nocrash":
        hits = [c["detail"] for c in doc["checks"] if "crashed" in c["detail"]]
        print(("FAIL\t%s\t%s" % (e, hits[0][:300])) if hits else "ok\t%s" % e)
        continue
    if e == "summary":
        n = {"pass": 0, "warn": 0, "fail": 0}
        for c in doc["checks"]:
            n[c["status"].lower()] += 1
        good = n == doc["summary"] and all(set(c) == {"scope", "id", "status", "detail", "hint"} for c in doc["checks"])
        print(("ok\t%s" % e) if good else "FAIL\t%s\t%s vs %s" % (e, doc["summary"], n))
        continue
    key, want = e.rsplit("=", 1)
    scope, cid = key.split("/", 1)
    if scope == "@all":
        scopes = list(apps)
    elif scope == "@sandbox":
        scopes = [a for a, v in apps.items() if v.get("fence") == "sandbox"]
    elif scope == "@flags":
        scopes = [a for a, v in apps.items() if v.get("fence") in ("roots", "root")]
    else:
        scopes = [scope]
    wrong = []
    for s in scopes:
        c = idx.get((s, cid))
        st = c["status"] if c else "MISSING"
        if st not in want.split("|"):
            wrong.append("%s/%s=%s %s" % (s, cid, st, (c or {}).get("detail", "")[:200]))
    print(("FAIL\t%s\t%s" % (e, " ; ".join(wrong[:3]))) if wrong else "ok\t%s" % e)
EOF
jexpect() { # LABEL JSON LOCK EXPECTATION...
  local label=$1 res e detail
  shift
  if [ ! -s "$1" ]; then bad "$label: output exists" "$1 is empty"; return 0; fi
  while IFS=$'\t' read -r res e detail; do
    if [ "$res" = ok ]; then ok "$label: $e"; else bad "$label: $e" "$detail"; fi
  done < <(python3 "$T/jexpect.py" "$@")
}

# ------------------------------------------------------------------------------------------------
echo "== part 1: usage and helpers"
mkdir -p "$T/home"
export HOME="$T/home"
expect_rc 0 "--help exits 0" "$DOCTOR" --help
check "--help documents --smoke" grep -q -- '--smoke' "$T/out"
expect_rc 0 "--version exits 0" "$DOCTOR" --version
expect_rc 2 "unknown option exits 2" "$DOCTOR" --no-such-option
expect_rc 2 "unknown app exits 2" "$DOCTOR" --app no-such-app
expect_rc 2 "--workspace without a value exits 2" "$DOCTOR" --workspace

printf 'env%sa%sPASS%sd1%s\nwordcraft%sb%sWARN%sd2%sh2\nMETA%sx%sy%s%s\nhooks%sc%sFAIL%sd3%sh3\n' \
  "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" > "$T/records"
python3 "$CHECKS" report --in "$T/records" --format json > "$T/report.json"
if python3 - "$T/report.json" <<'EOF'; then ok "report: JSON shape and counts"; else bad "report: JSON shape and counts" "$(cat "$T/report.json")"; fi
import json, sys
d = json.load(open(sys.argv[1]))
assert d["summary"] == {"pass": 1, "warn": 1, "fail": 1}, d
assert [c["id"] for c in d["checks"]] == ["a", "b", "c"], d
assert d["checks"][1] == {"scope": "wordcraft", "id": "b", "status": "WARN", "detail": "d2", "hint": "h2"}
EOF
check "report: summary line" [ "$(python3 "$CHECKS" report --in "$T/records" --format summary)" = "1 pass, 1 warn, 1 fail" ]

start=$(date +%s)
expect_rc 124 "run-timeout kills a command that runs too long" python3 "$CHECKS" run-timeout 1 /bin/sleep 20
check "run-timeout returns promptly" [ $(( $(date +%s) - start )) -lt 10 ]
expect_rc 3 "run-timeout passes the exit code through" python3 "$CHECKS" run-timeout 5 /bin/sh -c 'exit 3'

printf '{"a":{"b":[10,{"c":"x"}]},"t":true}\n' > "$T/j.json"
check "json-get: nested path" [ "$(python3 "$CHECKS" json-get "$T/j.json" a.b.1.c)" = x ]
expect_rc 1 "json-get: missing path exits 1" python3 "$CHECKS" json-get "$T/j.json" a.zzz

# app-static: a fake roots-fenced CLI with and without its fence flags (fail-closed).
LOCK=$REPO/manifest/apps.lock.json
mkdir -p "$T/prefix" "$T/ws/wordcraft" "$T/cfg"
chmod 700 "$T/ws/wordcraft"
WVER=$(python3 "$REPO/lib/craftkit.py" lock-get --app wordcraft --field version --lock "$LOCK")
cat > "$T/prefix/wordcraft-cli" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "wordcraft-cli $WVER" ;;
  --help) echo "wordcraft-cli mcp [--automation-read-root DIR] [--automation-write-root DIR]" ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$T/prefix/wordcraft-cli"
python3 - "$REPO" "$T" <<'EOF'
import json, subprocess, sys
repo, t = sys.argv[1:]
exp = json.loads(subprocess.check_output(["python3", repo + "/lib/craftkit.py", "expected", "--app", "wordcraft",
                                          "--workspace", t + "/ws", "--prefix", t + "/prefix"]))
json.dump({"mcpServers": {"wordcraft": {"type": "stdio", "command": exp["command"], "args": exp["args"], "env": {}}}},
          open(t + "/cfg/.claude.json", "w"))
EOF
RECEIPT_ARG=()
static() {
  python3 "$CHECKS" app-static --app wordcraft --workspace "$T/ws" --prefix "$T/prefix" --kit-dir "$REPO" \
    --kit-home "$T/home/kit" --lock "$LOCK" --config-dir "$T/cfg" ${RECEIPT_ARG[@]+"${RECEIPT_ARG[@]}"} > "$T/static" 2> "$T/static.err"
}
static
expect_rec "$T/static" wordcraft cli-installed PASS "app-static: cli-installed PASS at the lock version"
expect_rec "$T/static" wordcraft workspace PASS "app-static: workspace PASS (mode 700)"
expect_rec "$T/static" wordcraft mcp-registered PASS "app-static: matching registration PASS"
expect_rec "$T/static" wordcraft fence-config PASS "app-static: advertised fence flags PASS"
expect_meta "$T/static" fence_ok 1 "app-static: fence confirmed -> probe allowed"

# cli-installed compares the file with the SHA-256 the installer recorded (R1-SUPPLY-4).
cli_sha=$(shasum -a 256 "$T/prefix/wordcraft-cli" | cut -d' ' -f1)
printf '{"schema":1,"apps":{"wordcraft":{"cli":true,"cliSha256":"%s"}}}\n' "$cli_sha" > "$T/receipt.json"
RECEIPT_ARG=(--receipt "$T/receipt.json")
static
expect_rec "$T/static" wordcraft cli-installed PASS "app-static: CLI equal to the recorded SHA-256 PASSes"
printf '{"schema":1,"apps":{"wordcraft":{"cli":true,"cliSha256":"%064d"}}}\n' 0 > "$T/receipt.json"
static
expect_rec "$T/static" wordcraft cli-installed FAIL "app-static: CLI changed since install (SHA-256 differs) FAILs"
printf '{"schema":1,"apps":{"wordcraft":{"cli":true}}}\n' > "$T/receipt.json"
static
expect_rec "$T/static" wordcraft cli-installed WARN "app-static: older receipt without a SHA-256 WARNs"
RECEIPT_ARG=()

# A repeated or --flag=value fence flag: the CLI honours the last one, so it moves the fence (B1-SUPPLY-4).
cp "$T/cfg/.claude.json" "$T/cfg/.claude.json.good"
for extra in '["--automation-write-root", "/"]' '["--automation-write-root=/"]'; do
  python3 - "$T/cfg/.claude.json" "$extra" <<'EOF'
import json, sys
p, extra = sys.argv[1], json.loads(sys.argv[2])
d = json.load(open(p)); d["mcpServers"]["wordcraft"]["args"] += extra; json.dump(d, open(p, "w"))
EOF
  static
  expect_rec "$T/static" wordcraft fence-config FAIL "app-static: extra $extra in the registration FAILs fence-config"
  expect_rec "$T/static" wordcraft mcp-registered FAIL "app-static: extra $extra in the registration FAILs mcp-registered"
  cp "$T/cfg/.claude.json.good" "$T/cfg/.claude.json"
done
# An env override (for example a permissive CRAFT_SANDBOX_PROFILE) is not the kit's registration (R1-CONFIG-3).
python3 - "$T/cfg/.claude.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["mcpServers"]["wordcraft"]["env"] = {"CRAFT_SANDBOX_PROFILE": "/private/tmp/permissive.sb"}; json.dump(d, open(p, "w"))
EOF
static
expect_rec "$T/static" wordcraft mcp-registered FAIL "app-static: a registration with an env override FAILs"
check "app-static: the detail names the extra env setting" grep -q 'CRAFT_SANDBOX_PROFILE' "$T/static"
check "app-static: env override -> not 'started as registered'" sh -c '! grep -q "^META${2}reg_ok${2}1" "$1"' _ "$T/static" "$US"
cp "$T/cfg/.claude.json.good" "$T/cfg/.claude.json"

# A symlinked app folder would carry the fence elsewhere (R1-HOOK-8).
mv "$T/ws/wordcraft" "$T/ws-real-wordcraft"
ln -s "$T/ws-real-wordcraft" "$T/ws/wordcraft"
static
expect_rec "$T/static" wordcraft workspace FAIL "app-static: a symlinked app folder FAILs"
rm "$T/ws/wordcraft"
mv "$T/ws-real-wordcraft" "$T/ws/wordcraft"

# Fix hints: --yes (a pasted re-run must work without a terminal), and no --only before the first
# install (R1-UX-4, B1-UX-3).
mv "$T/prefix/wordcraft-cli" "$T/prefix/wordcraft-cli.away"
CRAFT_DOCTOR_RECEIPT_OK=0 static
check "hints before the first install: --yes and no --only" sh -c 'grep -q -- "--yes" "$1" && ! grep -q -- "--only" "$1"' _ "$T/static"
CRAFT_DOCTOR_RECEIPT_OK=1 static
check "hints after an install: --only APP --yes" grep -q -- '--only wordcraft --yes' "$T/static"
mv "$T/prefix/wordcraft-cli.away" "$T/prefix/wordcraft-cli"

sed -i '' 's/--automation-read-root DIR\] //' "$T/prefix/wordcraft-cli"
static
expect_rec "$T/static" wordcraft fence-config FAIL "app-static: missing fence flag in --help FAILs"
expect_meta "$T/static" fence_ok 0 "app-static: unconfirmed fence -> server is not started (fail closed)"

python3 - "$T/cfg/.claude.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"]["wordcraft"]["args"] = ["mcp"]; json.dump(d, open(p, "w"))
EOF
static
expect_rec "$T/static" wordcraft mcp-registered FAIL "app-static: unfenced registration FAILs"
chmod 755 "$T/ws/wordcraft"
static
expect_rec "$T/static" wordcraft workspace WARN "app-static: group/other-readable app folder WARNs"
rm "$T/prefix/wordcraft-cli"
static
expect_rec "$T/static" wordcraft cli-installed FAIL "app-static: missing CLI FAILs"
expect_meta "$T/static" cli_runs 0 "app-static: missing CLI -> server is not started"

# fence-live through the real sandbox: kit profile must hold, an allow-everything profile must not.
SBX=$(python3 -c 'import json,sys; print(next(a for a,v in json.load(open(sys.argv[1]))["apps"].items() if v.get("fence")=="sandbox"))' "$LOCK")
mkdir -p "$T/ws/$SBX" "$T/home/kit"
echo 0.0.0 > "$T/home/kit/VERSION"
fence() {
  python3 "$CHECKS" fence-live --app "$SBX" --workspace "$T/ws" --prefix "$T/prefix" --kit-dir "$REPO" \
    --kit-home "$T/home/kit" --read-candidate "$T/home/kit/VERSION" > "$T/fence" 2> "$T/fence.err"
}
if [ -x /usr/bin/sandbox-exec ]; then
  ( unset CRAFT_SANDBOX_PROFILE; fence )
  expect_rec "$T/fence" "$SBX" fence-live PASS "fence-live: write, read and network refused with share/craft.sb"
  printf '(version 1)\n(allow default)\n' > "$T/open.sb"
  CRAFT_SANDBOX_PROFILE=$T/open.sb fence
  expect_rec "$T/fence" "$SBX" fence-live FAIL "fence-live: an allow-everything profile is detected"
  left=''
  for f in /Users/Shared/.craft-doctor-fence-probe-*; do if [ -e "$f" ]; then left="$left $f"; fi; done
  check "fence-live: removes the probe file the open profile let it write" [ -z "$left" ]
else
  skip "fence-live: /usr/bin/sandbox-exec not available"
fi

# The launch step counts as refused only on the sandbox's own error text; `open` failing for another
# reason must not PASS it (B1-FENCE-1). Shim wrappers run nothing in a sandbox and fail `open` themselves.
launch_probe() { # MESSAGE -> prints the probe verdict
  printf '#!/bin/sh\nshift\n[ "$1" = /usr/bin/open ] || exec "$@"\necho "$CK_SHIM_MSG" >&2\nexit 1\n' > "$T/shim-wrapper"
  chmod 755 "$T/shim-wrapper"
  CK_SHIM_MSG=$1 python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import doctor_checks as d
print(d._launch_probe(sys.argv[2], sys.argv[3], sys.argv[4], dict(os.environ))[0])' "$REPO/lib" "$T/shim-wrapper" "$T/ws/$SBX" "$T/home"
}
got=$(launch_probe "unrelated failure")
check "fence-live: open failing for an unrelated reason is unclear, not refused (B1-FENCE-1)" [ "$got" = unclear ]
got=$(launch_probe "The application cannot be opened. kLSNoExecutableErr: The executable is missing (-10827)")
check "fence-live: the sandbox's own refusal text counts as refused" [ "$got" = refused ]

# hooks and legacy: the repo's own hook scripts answer the canned payloads.
apps_csv=$(python3 "$REPO/lib/craftkit.py" apps --lock "$LOCK" | paste -sd, -)
apps_re=$(printf '%s' "$apps_csv" | tr ',' '|')
python3 - "$T/settings.json" "$REPO" "$T/ws" "$apps_re" "$T/home" <<'EOF'
import json, shlex, sys
path, repo, ws, apps, home = sys.argv[1:]
def cmd(s):
    return "python3 %s --workspace %s" % (shlex.quote(repo + "/hooks/" + s), shlex.quote(ws))
json.dump({"model": "keep-me", "hooks": {"PreToolUse": [
    {"matcher": "Bash|mcp__terminal__run_in_terminal|Monitor|mcp__computer-use__open_application",
     "hooks": [{"type": "command", "command": cmd("craft-shell-guard.py")}]},
    {"matcher": "mcp__(%s)__.*" % apps, "hooks": [{"type": "command", "command": cmd("craft-mcp-guard.py")}]},
    {"matcher": "Bash", "hooks": [{"type": "command",
                                   "command": "python3 %s/.local/share/craft-skills/craft-shell-guard.py" % home}]}]}},
          open(path, "w"))
EOF
cp "$T/settings.json" "$T/settings.before"
python3 "$CHECKS" hooks --settings "$T/settings.json" --kit-home "$REPO" --workspace "$T/ws" --apps "$apps_csv" > "$T/hooks" 2>&1
for id in shell-guard shell-guard-test mcp-guard mcp-guard-test; do
  expect_rec "$T/hooks" hooks "$id" PASS "hooks: $id PASS with the repo's hook scripts"
done
# The old matcher (Bash only) misses the other shell-running tools (R1-HOOK-2).
python3 - "$T/settings.json" "$T/settings.bashonly.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["hooks"]["PreToolUse"][0]["matcher"] = "Bash"; json.dump(d, open(sys.argv[2], "w"))
EOF
python3 "$CHECKS" hooks --settings "$T/settings.bashonly.json" --kit-home "$REPO" --workspace "$T/ws" --apps "$apps_csv" > "$T/hooks" 2>&1
expect_rec "$T/hooks" hooks shell-guard WARN "hooks: a Bash-only shell-guard matcher WARNs"
# An emptied risk table or a changed hook file shows up (R1-HOOK-3).
mkdir -p "$T/kit3/hooks"
cp "$REPO"/hooks/*.py "$REPO"/hooks/risky-tools.json "$T/kit3/hooks/"
python3 - "$T/kit3" <<'EOF'
import hashlib, json, os, sys
k = sys.argv[1]
sha = {n: hashlib.sha256(open(os.path.join(k, "hooks", n), "rb").read()).hexdigest()
       for n in ("craft-shell-guard.py", "craft-mcp-guard.py", "risky-tools.json")}
json.dump({"schema": 1, "apps": {}, "hooksSha256": sha}, open(os.path.join(k, "receipt.json"), "w"))
EOF
sed "s#$REPO/hooks/#$T/kit3/hooks/#g" "$T/settings.json" > "$T/settings.kit3.json"
python3 "$CHECKS" hooks --settings "$T/settings.kit3.json" --kit-home "$T/kit3" --workspace "$T/ws" --apps "$apps_csv" \
  --receipt "$T/kit3/receipt.json" > "$T/hooks" 2>&1
expect_rec "$T/hooks" hooks mcp-guard-test PASS "hooks: the kit's table answers the canned table cases"
expect_rec "$T/hooks" hooks files PASS "hooks: unchanged hook files PASS against the receipt"
printf '{}\n' > "$T/kit3/hooks/risky-tools.json"
python3 "$CHECKS" hooks --settings "$T/settings.kit3.json" --kit-home "$T/kit3" --workspace "$T/ws" --apps "$apps_csv" \
  --receipt "$T/kit3/receipt.json" > "$T/hooks" 2>&1
expect_rec "$T/hooks" hooks mcp-guard-test FAIL "hooks: an emptied risk table FAILs the canned table cases"
expect_rec "$T/hooks" hooks files WARN "hooks: a hook file changed since install WARNs"
python3 "$CHECKS" legacy --settings "$T/settings.json" --home "$T/home" > "$T/legacy" 2>&1
expect_rec "$T/legacy" legacy old-hook-entry WARN "legacy: old hook entry WARNs"
check "hooks/legacy: settings.json left unchanged" cmp -s "$T/settings.json" "$T/settings.before"
printf '{"hooks": ' > "$T/settings.json"
python3 "$CHECKS" hooks --settings "$T/settings.json" --kit-home "$REPO" --workspace "$T/ws" --apps "$apps_csv" > "$T/hooks" 2>&1
expect_rec "$T/hooks" hooks settings FAIL "hooks: unparseable settings.json FAILs"

# skills: rendered copies PASS; an edit WARNs; a leftover token FAILs.
mkdir -p "$T/claude/skills"
for d in "$REPO"/skills/*/; do
  n=$(basename "$d")
  [ -f "$d/SKILL.md" ] || continue
  mkdir -p "$T/claude/skills/$n"
  python3 "$REPO/lib/craftkit.py" render --workspace "$T/ws" --kit-home "$T/home/kit" --in "$d/SKILL.md" --out "$T/claude/skills/$n/SKILL.md"
done
skills() {
  python3 "$CHECKS" skills --claude-dir "$T/claude" --workspace "$T/ws" --kit-home "$T/home/kit" \
    --apps "$apps_csv" --source "$REPO/skills" --tools-dir "$T/none" > "$T/skills" 2>&1
}
skills
expect_rec "$T/skills" skills installed PASS "skills: all 14 present"
expect_rec "$T/skills" skills rendered PASS "skills: no tokens left"
expect_rec "$T/skills" skills up-to-date PASS "skills: identical to the rendered sources"
echo "edited" >> "$T/claude/skills/craft-$SBX/SKILL.md"
echo "{{WORKSPACE}}" >> "$T/claude/skills/craft-apps/SKILL.md"
rm -r "$T/claude/skills/craft-wordcraft"
skills
expect_rec "$T/skills" skills installed FAIL "skills: a missing skill FAILs"
expect_rec "$T/skills" skills rendered FAIL "skills: a leftover {{token}} FAILs"
expect_rec "$T/skills" skills up-to-date WARN "skills: an edited skill WARNs"

# ------------------------------------------------------------------------------------------------
echo "== part 2: end to end through tests/isolated.sh"
ISO=$REPO/tests/isolated.sh
FIXLOCK=$REPO/tests/fixtures/apps.lock.json
# The fixtures are gitignored and built on first use; a fresh clone must not silently skip part 2.
if [ -f "$ISO" ] && [ ! -f "$FIXLOCK" ] && [ -f "$REPO/tests/fixtures/build.sh" ]; then
  /bin/bash "$REPO/tests/fixtures/build.sh" --quiet || true
fi
missing=''
[ -x "$ISO" ] || [ -f "$ISO" ] || missing="$missing tests/isolated.sh"
[ -f "$FIXLOCK" ] || missing="$missing tests/fixtures/apps.lock.json"
[ -f "$REPO/install.sh" ] || missing="$missing install.sh"
if [ -n "$missing" ]; then
  if [ -n "${CI:-}" ]; then bad "end-to-end doctor tests: missing$missing"; else skip "end-to-end doctor tests: missing$missing"; fi
else
  SBX=$(python3 -c 'import json,sys; print(next(a for a,v in json.load(open(sys.argv[1]))["apps"].items() if v.get("fence")=="sandbox"))' "$FIXLOCK")
  mkdir -p "$T/e2e"
  cat > "$T/scenario.sh" <<'EOF'
# Runs inside tests/isolated.sh. $1 = results folder, $2 = repo, $3 = a sandbox-fenced app.
set -u
out=$1 repo=$2 app=$3
run() { # NAME ARGS... : doctor.sh --json into NAME.json, exit code into NAME.rc
  local name=$1 rc=0
  shift
  "$@" > "$out/$name.json" 2> "$out/$name.err" < /dev/null || rc=$?
  echo "$rc" > "$out/$name.rc"
}
run pre "$repo/doctor.sh" --json
rc=0; NO_COLOR=1 "$repo/doctor.sh" > "$out/pre.txt" 2>&1 < /dev/null || rc=$?; echo "$rc" > "$out/pre-text.rc"
rc=0; "$repo/install.sh" --yes > "$out/install.log" 2>&1 < /dev/null || rc=$?; echo "$rc" > "$out/install.rc"
run post "$repo/doctor.sh" --json
kh=${CRAFT_KIT_HOME:-$HOME/.local/share/craft-claude-kit}
run runtime "$kh/doctor.sh" --json
NO_COLOR=1 "$repo/doctor.sh" --app "$app" > "$out/table.txt" 2>&1 < /dev/null || true
run smoke "$repo/doctor.sh" --json --smoke
ws=$(python3 "$repo/lib/doctor_checks.py" json-get "$kh/receipt.json" workspace 2>/dev/null || echo "$HOME/craft-workspace")
ls -d "$ws"/*/_doctor > "$out/smoke-left.txt" 2>/dev/null || true
printf '(version 1)\n(allow default)\n' > "$HOME/open.sb"
CRAFT_SANDBOX_PROFILE=$HOME/open.sb run open "$repo/doctor.sh" --json --app "$app"
# a server that starts but whose first real call fails (LightCraft under a too-strict profile)
mkdir -p "$HOME/badsmoke" "$HOME/rootsmoke"
printf '[{"tool": "no-such-tool", "args": {}, "note": "fails"}]\n' > "$HOME/badsmoke/$app.json"
printf '[{"tool": "echo", "args": {"text": "{root}"}, "note": "names the workspace"}]\n' > "$HOME/rootsmoke/$app.json"
CRAFT_KIT_SMOKE_DIR=$HOME/badsmoke run badfirst "$repo/doctor.sh" --json --app "$app"
CRAFT_KIT_SMOKE_DIR=$HOME/rootsmoke run rootfirst "$repo/doctor.sh" --json --app "$app"
cfg=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
python3 - "$cfg" "$app" <<'PY'
import json, sys
p, app = sys.argv[1:]
d = json.load(open(p))
d["mcpServers"][app]["args"][0] = "/tmp"
json.dump(d, open(p, "w"))
PY
run rereg "$repo/doctor.sh" --json --app "$app"
mkdir -p "$ws/$app/_doctor" && echo mine > "$ws/$app/_doctor/keep-me.txt"
run foreign "$repo/doctor.sh" --json --smoke --app "$app"
[ -f "$ws/$app/_doctor/keep-me.txt" ] && echo kept > "$out/foreign-kept.txt"
# a partial install on purpose: one app, no skills, no hooks, in a second kit home and Claude config
export CRAFT_KIT_HOME=$HOME/kit2 CLAUDE_CONFIG_DIR=$HOME/claude2
rc=0; "$repo/install.sh" --yes --only "$app" --no-skills --no-hook --workspace "$HOME/ws2" > "$out/partial-install.log" 2>&1 < /dev/null || rc=$?
echo "$rc" > "$out/partial-install.rc"
run partial "$HOME/kit2/doctor.sh" --json
pgrep -fl "$(basename "$HOME")" > "$out/orphans.txt" 2>/dev/null || true
EOF
  rc=0
  "$ISO" /bin/bash "$T/scenario.sh" "$T/e2e" "$REPO" "$SBX" > "$T/e2e.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then ok "isolated scenario ran"; else bad "isolated scenario ran" "exit $rc: $(tail -n 5 "$T/e2e.log")"; fi
  E=$T/e2e

  check "before install: exit 1" [ "$(cat "$E/pre.rc" 2>/dev/null)" = 1 ]
  jexpect "before install" "$E/pre.json" "$FIXLOCK" summary nocrash "@all/cli-installed=FAIL" "env/receipt=WARN" "@all/server-starts=WARN"
  # Text mode before install: one clear FAIL instead of ~50 per-app lines (R1-UX-1).
  check "before install, text: exit 1" [ "$(cat "$E/pre-text.rc" 2>/dev/null)" = 1 ]
  check "before install, text: one 'nothing installed' FAIL and no per-app FAIL lines" \
    sh -c '[ "$(grep -c "^  FAIL" "$1")" = 1 ] && grep -q "nothing installed here" "$1"' _ "$E/pre.txt"
  check "before install, text: no separate 'no install receipt' WARN next to that FAIL (B1-UX-2)" \
    sh -c '[ "$(grep -c "no install receipt" "$1")" = 1 ]' _ "$E/pre.txt"
  check "before install, text: the hint works without a terminal (--yes, R1-UX-4)" \
    sh -c 'grep "nothing installed here" -A2 "$1" | grep -q -- "--yes"' _ "$E/pre.txt"
  if python3 - "$E/pre.json" <<'EOF'; then ok "before install: no fix hint suggests --only (B1-UX-3)"; else bad "before install: no fix hint suggests --only (B1-UX-3)"; fi
import json, sys
sys.exit(1 if any("--only" in c["hint"] for c in json.load(open(sys.argv[1]))["checks"]) else 0)
EOF

  if [ "$(cat "$E/install.rc" 2>/dev/null)" = 0 ]; then ok "install.sh --yes (fixtures) exit 0"
  else bad "install.sh --yes (fixtures) exit 0" "$(tail -n 8 "$E/install.log" 2>/dev/null)"; fi

  CORE="@all/cli-installed=PASS @all/workspace=PASS @all/mcp-registered=PASS @all/fence-config=PASS
        @all/server-starts=PASS @all/tools-list=PASS @all/first-call=PASS @sandbox/fence-live=PASS
        skills/installed=PASS skills/rendered=PASS hooks/shell-guard=PASS hooks/shell-guard-test=PASS
        hooks/mcp-guard=PASS hooks/mcp-guard-test=PASS legacy/leftovers=PASS"
  # shellcheck disable=SC2086
  jexpect "after install" "$E/post.json" "$FIXLOCK" summary nocrash $CORE env/kit=PASS env/lock=PASS \
    env/receipt=PASS env/workspace=PASS env/craft-sandbox=PASS env/sandbox-profile=PASS skills/up-to-date=PASS
  # shellcheck disable=SC2086
  jexpect "from the runtime copy" "$E/runtime.json" "$FIXLOCK" summary nocrash $CORE
  for name in post runtime; do
    if python3 - "$E/$name.json" "$(cat "$E/$name.rc" 2>/dev/null)" <<'EOF'; then ok "$name: exit code matches the FAIL count"; else bad "$name: exit code matches the FAIL count"; fi
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if (sys.argv[2] == "0") == (d["summary"]["fail"] == 0) and sys.argv[2] in ("0", "1") else 1)
EOF
  done

  if grep -q "^$SBX\$" "$E/table.txt" && grep -qE '^[0-9]+ pass, [0-9]+ warn, [0-9]+ fail$' "$E/table.txt"; then
    ok "table output: app header and summary line"
  else
    bad "table output: app header and summary line" "$(head -c 400 "$E/table.txt")"
  fi
  if grep -q "$(printf '\033')" "$E/table.txt"; then bad "table output: no colour codes when not a tty"; else ok "table output: no colour codes when not a tty"; fi

  jexpect "--smoke" "$E/smoke.json" "$FIXLOCK" summary nocrash "@all/smoke=PASS"
  jexpect "first real call fails" "$E/badfirst.json" "$FIXLOCK" summary nocrash "$SBX/first-call=FAIL" "$SBX/server-starts=PASS"
  check "first real call fails: exit 1" [ "$(cat "$E/badfirst.rc" 2>/dev/null)" = 1 ]
  jexpect "first step names the workspace: not run" "$E/rootfirst.json" "$FIXLOCK" summary nocrash "$SBX/first-call=WARN"
  if [ -s "$E/smoke-left.txt" ]; then bad "--smoke removes every _doctor folder" "$(cat "$E/smoke-left.txt")"
  else ok "--smoke removes every _doctor folder"; fi

  jexpect "open sandbox profile" "$E/open.json" "$FIXLOCK" nocrash "$SBX/fence-live=FAIL" "env/sandbox-profile=WARN"
  jexpect "changed registration" "$E/rereg.json" "$FIXLOCK" nocrash "$SBX/mcp-registered=FAIL" "$SBX/fence-config=FAIL"
  jexpect "a _doctor folder doctor did not create" "$E/foreign.json" "$FIXLOCK" nocrash "$SBX/smoke=WARN"
  check "--smoke leaves a _doctor folder it did not create alone" [ -f "$E/foreign-kept.txt" ]
  check "partial install (--only, --no-skills, --no-hook): exit 0" [ "$(cat "$E/partial-install.rc" 2>/dev/null)" = 0 ]
  jexpect "doctor after a partial install" "$E/partial.json" "$FIXLOCK" nocrash "env/apps=PASS" "$SBX/mcp-registered=PASS" \
    "skills/installed=PASS" "hooks/hooks=PASS"
  check "doctor after a partial install: no FAIL, exit 0" [ "$(cat "$E/partial.rc" 2>/dev/null)" = 0 ]
  if [ -s "$E/orphans.txt" ]; then bad "no server process left behind" "$(cat "$E/orphans.txt")"
  else ok "no server process left behind"; fi
fi

echo
echo "test_doctor: $PASSES passed, $FAILS failed, $SKIPS skipped"
[ "$FAILS" = 0 ]
