#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2015,SC2016,SC2034,SC2046,SC2086,SC2155,SC2317
# End-to-end tests of install.sh and uninstall.sh, written from the contract (SPEC sections 3-5) without reading the
# installer's code. Everything runs inside tests/isolated.sh: a fresh fake HOME, a fake `claude` that records every
# call and edits a fake .claude.json, tiny fake CLI zips and disk images for all 13 apps (tests/fixtures/build.sh), and
# no network (downloads come from tests/fixtures/out; proxies point at a closed port).
#
#   tests/test_install.sh [-v] [-l] [CASE ...]
#     -v        also print every passing check
#     -l        list the cases
#     CASE      run only these cases (default: all)
#   TEST_BASH=/path/to/bash   run the installer and the tests with another bash (default /bin/bash: bash 3.2 on macOS)
#   RUN_TIMEOUT=240           seconds before a single installer run is killed
#   KEEP_TEMP=1               keep the sandbox (isolated.sh prints its path)
#
# Prints "PASS <case> (<n> checks)" or "FAIL <case> (<k> of <n> checks failed)" per case, details of each failed check
# before it, and a total. Exit status is 1 if any case failed. Checks whose wording or behaviour is inferred rather than
# stated in the contract carry "(inferred)" in their description: adjust them if the contract is the one that is right.
# Bash 3.2 compatible.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P)
SELF=$SELF_DIR/$(basename "$0")
REPO=$(cd "${CRAFT_TEST_REPO:-$SELF_DIR/..}" && pwd -P)
FIX=$SELF_DIR/fixtures
BASH_UT=${TEST_BASH:-/bin/bash}
INSTALL=$REPO/install.sh
UNINSTALL=$REPO/uninstall.sh
VERBOSE=${VERBOSE:-0}
LIST=0
ONLY_CASES=''

TESTS="help preflight dry-run lifecycle bad-sha zip-slip fence-fail only no-flags legacy bad-settings spaces custom-paths settings-symlink upgrade gui uninstall-options tty rerun kit-deleted bad-lock fence-override planted-cli restore-registration python-stub kit-home-guard symlinked-local env-override gui-replaced legacy-profile-notice plan-width kit-extra-file real-home"

usage() {
  sed -n '3,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case $1 in
    -v | --verbose) VERBOSE=1 ;;
    -l | --list) LIST=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *) ONLY_CASES="$ONLY_CASES $1" ;;
  esac
  shift
done

if [ "$LIST" = 1 ]; then
  for name in $TESTS; do echo "$name"; done
  exit 0
fi

# ------------------------------------------------------------------------------------------------------------------
# outer mode: build the fixtures and re-run this script inside tests/isolated.sh
# ------------------------------------------------------------------------------------------------------------------
if [ -z "${CRAFT_TEST_ROOT:-}" ]; then
  for f in "$INSTALL" "$UNINSTALL"; do
    if [ ! -f "$f" ]; then
      echo "FAIL missing $f: nothing to test"
      exit 1
    fi
  done
  /bin/bash "$FIX/build.sh" --quiet || {
    echo "FAIL could not build the fixtures (tests/fixtures/build.sh)"
    exit 1
  }
  if [ "$VERBOSE" = 1 ]; then set -- -v; else set --; fi
  for name in $ONLY_CASES; do set -- "$@" "$name"; done
  exec "$SELF_DIR/isolated.sh" "$BASH_UT" "$SELF" "$@"
fi

# ------------------------------------------------------------------------------------------------------------------
# inner mode (inside the sandbox)
# ------------------------------------------------------------------------------------------------------------------
T=$CRAFT_TEST_ROOT
STATE=$T/state
RESULTS=$STATE/results.txt
: > "$RESULTS"
DEF_PATH=$PATH
DEF_LOCK=$CRAFT_KIT_LOCK
DEF_OFF=$CRAFT_KIT_OFFLINE_DIR
DEF_CLAUDE_BIN=$CLAUDE_BIN
RUN_TIMEOUT=${RUN_TIMEOUT:-240}
RUN_N=0
RC=0
OUTF=$STATE/out.none
: > "$OUTF"
WORLD_N=0
CASE=''
CHECKS=0
FAILS=0

APPS="wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft filmcraft effectcraft lightcraft soundcraft"
# The shell guard covers every tool that runs a shell command or starts an app (R1-HOOK-2).
SHELL_MATCHER='Bash|mcp__terminal__run_in_terminal|Monitor|mcp__computer-use__open_application'
NL='
'

# ---- worlds ----------------------------------------------------------------------------------------------------------
detach_images() {
  command -v hdiutil > /dev/null 2>&1 || return 0
  local mp
  hdiutil info 2> /dev/null | awk -F'\t' -v root="$T/" '$1 ~ /^\/dev\/disk/ && index($0, root) { print $NF }' |
    while IFS= read -r mp; do
      [ -n "$mp" ] && hdiutil detach -force -quiet "$mp" > /dev/null 2>&1 || true
    done
}

new_world() { # [NAME]: a fresh HOME with default environment
  detach_images
  chmod -R u+rwx "$T/worlds" > /dev/null 2>&1 || true
  rm -rf "$T/worlds"
  mkdir -p "$T/worlds"
  WORLD_N=$((WORLD_N + 1))
  HOME="$T/worlds/${1:-home}.$WORLD_N"
  mkdir -p "$HOME"
  export HOME
  CLAUDE_DIR=$HOME/.claude
  KIT=$HOME/.local/share/craft-claude-kit
  PREFIX=$HOME/.local/bin
  WS=$HOME/craft-workspace
  GUI_DIR=$HOME/Applications
  CLAUDE_JSON=$CLAUDE_DIR/.claude.json
  SETTINGS=$CLAUDE_DIR/settings.json
  SKILLS=$CLAUDE_DIR/skills
  export CLAUDE_CONFIG_DIR=$CLAUDE_DIR CRAFT_KIT_HOME=$KIT
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
  export CRAFT_KIT_LOCK=$DEF_LOCK CRAFT_KIT_OFFLINE_DIR=$DEF_OFF CLAUDE_BIN=$DEF_CLAUDE_BIN PATH=$DEF_PATH
  unset FAKE_CLAUDE_FAIL_ADD FAKE_CLAUDE_FAIL_ADD_ARG FAKE_CLAUDE_VERSION CRAFT_SANDBOX_PROFILE
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  chmod 700 "$TMPDIR"
  : > "$FAKE_CLAUDE_LOG"
}

# ---- running things --------------------------------------------------------------------------------------------------
RUN_STDIN=/dev/null
run() { # COMMAND ARGS... : sets RC and OUTF (stdout+stderr), cwd = HOME, stdin = $RUN_STDIN, killed after RUN_TIMEOUT
  RUN_N=$((RUN_N + 1))
  OUTF=$STATE/out.$RUN_N
  local pid wd
  (
    cd "$HOME" 2> /dev/null || cd /
    exec "$@"
  ) > "$OUTF" 2>&1 < "$RUN_STDIN" &
  pid=$!
  (
    i=0
    while [ "$i" -lt "$RUN_TIMEOUT" ]; do
      sleep 1
      kill -0 "$pid" 2> /dev/null || exit 0
      i=$((i + 1))
    done
    kill -TERM "$pid" 2> /dev/null
    sleep 2
    kill -KILL "$pid" 2> /dev/null
  ) > /dev/null 2>&1 &
  wd=$!
  wait "$pid" 2> /dev/null
  RC=$?
  kill "$wd" 2> /dev/null
  wait "$wd" 2> /dev/null
  RUN_STDIN=/dev/null
  return 0
}
inst() { run "$BASH_UT" "$INSTALL" "$@"; }
inst_y() { # install.sh with --yes, --no-gui and a GUI dir inside HOME unless the caller says otherwise
  local a have_yes=0 have_gui=0 have_dir=0
  for a in "$@"; do
    case $a in
      -y | --yes) have_yes=1 ;;
      --gui | --no-gui) have_gui=1 ;;
      --gui-dir | --gui-dir=*) have_dir=1 ;;
    esac
  done
  [ "$have_dir" = 1 ] || set -- --gui-dir "$GUI_DIR" "$@"
  [ "$have_gui" = 1 ] || set -- --no-gui "$@"
  [ "$have_yes" = 1 ] || set -- --yes "$@"
  inst "$@"
}
uninst() { run "$BASH_UT" "$UNINSTALL" "$@"; }
uninst_kit() { run "$BASH_UT" "$KIT/uninstall.sh" "$@"; } # the runtime copy, as a user would run it
uninst_y() {
  local a have_yes=0
  for a in "$@"; do
    case $a in -y | --yes) have_yes=1 ;; esac
  done
  [ "$have_yes" = 1 ] || set -- --yes "$@"
  uninst_kit "$@"
}

# ---- checks ----------------------------------------------------------------------------------------------------------
begin_case() {
  CASE=$1
  CHECKS=0
  FAILS=0
  echo "$CASE" > "$STATE/current-case"
  if [ "$VERBOSE" = 1 ]; then printf '\n=== %s\n' "$CASE"; fi
}
end_case() {
  if [ "$FAILS" -eq 0 ]; then
    printf 'PASS %s (%d checks)\n' "$CASE" "$CHECKS"
    echo "PASS $CASE" >> "$RESULTS"
  else
    printf 'FAIL %s (%d of %d checks failed)\n' "$CASE" "$FAILS" "$CHECKS"
    echo "FAIL $CASE" >> "$RESULTS"
  fi
  : > "$STATE/current-case"
  CASE=''
}
pass() {
  CHECKS=$((CHECKS + 1))
  if [ "$VERBOSE" = 1 ]; then printf '    ok    %s\n' "$1"; fi
  return 0
}
fail() { # DESC [DETAIL-LINES]
  CHECKS=$((CHECKS + 1))
  FAILS=$((FAILS + 1))
  printf '    FAIL  [%s] %s\n' "$CASE" "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed -e '/^$/d' -e 's/^/          /' | head -n 14; fi
  return 0
}
out_tail() { tail -n 12 "$OUTF" 2> /dev/null | sed 's/^/| /'; }

a_true() { # DESC CMD... : passes when CMD succeeds
  local desc=$1
  shift
  if "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
a_false() { # DESC CMD... : passes when CMD fails
  local desc=$1
  shift
  if "$@" > /dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}
a_eq() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2${NL}actual:   $3"; fi
}
a_rc() { # DESC WANT : the last run's exit status
  if [ "$RC" = "$2" ]; then pass "$1"; else fail "$1" "exit status $RC, wanted $2${NL}$(out_tail)"; fi
}
a_out() { # DESC REGEX : extended regex (case-insensitive) found in the last run's output
  if grep -Eqi -- "$2" "$OUTF"; then pass "$1"; else fail "$1" "no match for /$2/ in the output${NL}$(out_tail)"; fi
}
a_noout() { # DESC REGEX
  if grep -Eqi -- "$2" "$OUTF"; then fail "$1" "unexpected match for /$2/${NL}$(grep -Ei -- "$2" "$OUTF" | head -n 3)"; else pass "$1"; fi
}
a_outf() { # DESC STRING : fixed string found in the output
  if grep -Fq -- "$2" "$OUTF"; then pass "$1"; else fail "$1" "string not in the output: $2${NL}$(out_tail)"; fi
}
a_jq() { # DESC FILE FILTER [JQ-ARGS...] : jq -e passes
  local desc=$1 file=$2 filter=$3
  shift 3
  if jq -e "$@" "$filter" "$file" > /dev/null 2>&1; then pass "$desc"; else fail "$desc" "jq filter false or file invalid: $filter  ($file)"; fi
}
a_out_path() { # DESC PATH : the path appears in the output, in full or with the home folder written as ~
  local tilde=''
  case $2 in "$HOME"/*) tilde="~${2#"$HOME"}" ;; esac
  if grep -Fq -- "$2" "$OUTF" || { [ -n "$tilde" ] && grep -Fq -- "$tilde" "$OUTF"; }; then pass "$1"; else fail "$1" "path not in the output: $2${NL}$(out_tail)"; fi
}
agg() { # DESC BAD-LINES : passes when there are no bad lines
  if [ -z "$2" ]; then pass "$1"; else fail "$1" "$2"; fi
}

# ---- state helpers ---------------------------------------------------------------------------------------------------
file_hash() { if [ -e "$1" ]; then shasum -a 256 < "$1" | cut -c1-64; else echo absent; fi; }
tree_hash() { # DIR : one digest over every path, type, mode, symlink target and file content below DIR
  (
    cd "$1" 2> /dev/null || exit 0
    find . -print 2> /dev/null | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then
        printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then
        printf 'D %s %s\n' "$p" "$(stat -f '%Lp' "$p")"
      else
        printf 'F %s %s %s\n' "$p" "$(stat -f '%Lp' "$p")" "$(shasum -a 256 < "$p" | cut -c1-64)"
      fi
    done
  ) | shasum -a 256 | cut -c1-64
}
tmp_empty() { [ -z "$(ls -A "$TMPDIR" 2> /dev/null)" ]; }
no_images_mounted() { ! hdiutil info 2> /dev/null | grep -qF "$T/"; }
log_lines() { wc -l < "$FAKE_CLAUDE_LOG" | tr -d ' '; }
calls_from() { tail -n +"$(($1 + 1))" "$FAKE_CLAUDE_LOG"; }
count_calls() { # FROM SUBCOMMAND [APP] : `claude mcp SUBCOMMAND ... APP ...` calls after line FROM
  calls_from "$1" | jq -c --arg s "$2" --arg a "${3:-}" 'select(.[0] == "mcp" and .[1] == $s and ($a == "" or any(.[2:6][]; . == $a)))' | wc -l | tr -d ' '
}
version_str() { tr -d '[:space:]' < "$REPO/VERSION"; }
lock_val() { # APP FIELD
  jq -r --arg a "$1" ".apps[\$a].$2" "$CRAFT_KIT_LOCK"
}
all_apps_but() { # APP... : APPS without these
  local a b skip out=''
  for a in $APPS; do
    skip=0
    for b in "$@"; do [ "$a" = "$b" ] && skip=1; done
    [ "$skip" = 1 ] || out="$out $a"
  done
  echo "${out# }"
}
expected_reg() { # APP : what the registration must be, computed from the contract (SPEC 4) and the lock
  jq -cS --arg a "$1" --arg ws "$WS" --arg pfx "$PREFIX" '
    .apps[$a] as $e
    | ($ws + "/" + $a) as $root
    | ($pfx + "/" + $a + "-cli") as $cli
    | ($e.extraArgs // []) as $x
    | if $e.fence == "roots" then
        {command: $cli, args: (["mcp", "--automation-read-root", $root, "--automation-write-root", $root] + $x)}
      elif $e.fence == "root" then
        {command: $cli, args: (["mcp", "--root", $root] + $x)}
      else
        {command: ($pfx + "/craft-sandbox"), args: ([$root, $cli, "mcp"] + $x)}
      end' "$CRAFT_KIT_LOCK"
}
actual_reg() { # APP : the user-scope registration as written to .claude.json (empty if none)
  jq -cS --arg a "$1" '.mcpServers[$a] // empty | {command: .command, args: .args}' "$CLAUDE_JSON" 2> /dev/null
}
render_skill() { # SRC : the skill as it must be installed
  python3 -I -c 'import sys
t = open(sys.argv[1], encoding="utf-8", newline="").read()
sys.stdout.buffer.write(t.replace("{{WORKSPACE}}", sys.argv[2]).replace("{{KIT_HOME}}", sys.argv[3]).encode("utf-8"))' "$1" "$WS" "$KIT"
}
list_hooks() { jq -r '.hooks.PreToolUse[]? | .matcher as $m | .hooks[]? | [($m // ""), .command] | @tsv' "$SETTINGS" 2> /dev/null; }
settings_backups() { ls "$CLAUDE_DIR"/settings.json.bak-craft-kit-* 2> /dev/null | wc -l | tr -d ' '; }
mtimes() { # DIR : name and mtime of every file directly in DIR
  (cd "$1" 2> /dev/null && for f in *; do [ -f "$f" ] && stat -f '%N %m' "$f"; done) || true
}
backdate() { touch -t 200001010000 "$@"; }
plist_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2> /dev/null; }
make_fake_app() { # DIR BUNDLE VERSION : a bundle that is not the kit's
  mkdir -p "$1/$2/Contents"
  cat > "$1/$2/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$3</string></dict></plist>
PLIST
}
make_stub_cli() { # APP VERSION : an already installed CLI of some other build
  mkdir -p "$PREFIX"
  printf '#!/bin/sh\ncase "$1" in --version) echo "%s-cli %s" ;; *) echo "stub %s-cli" ;; esac\n' "$1" "$2" "$1" > "$PREFIX/$1-cli"
  chmod 755 "$PREFIX/$1-cli"
}
seed_json() { # FILE JSON : write a JSON file (checked)
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" | jq . > "$1.seed.tmp" || {
    echo "test bug: invalid seed JSON for $1" >&2
    return 1
  }
  mv "$1.seed.tmp" "$1"
}
seed_reg() { # APP JSON({command,args}) : add a user-scope registration in the real format
  mkdir -p "$CLAUDE_DIR"
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  jq --arg a "$1" --argjson r "$2" '.mcpServers[$a] = ($r + {type: "stdio", env: {}})' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
}

# ---- fixture variants ------------------------------------------------------------------------------------------------
derive_fixtures() { # NAME : private copies of the offline dir and the lock; sets CRAFT_KIT_OFFLINE_DIR / CRAFT_KIT_LOCK
  local d=$STATE/variant-$1
  rm -rf "$d"
  mkdir -p "$d"
  cp -R "$DEF_OFF/." "$d/"
  cp "$DEF_LOCK" "$d.lock.json"
  VARIANT_DIR=$d
  VARIANT_LOCK=$d.lock.json
  export CRAFT_KIT_OFFLINE_DIR=$d CRAFT_KIT_LOCK=$d.lock.json
}
variant_cli() { # APP [make_cli_zip.py options...] : replace the app's CLI zip by a variant and update the lock to match
  local app=$1 info zip
  shift
  zip=$VARIANT_DIR/$(jq -r --arg a "$app" '.apps[$a].cli.asset' "$VARIANT_LOCK")
  info=$(python3 -I "$FIX/make_cli_zip.py" --app "$app" --version "$(jq -r --arg a "$app" '.apps[$a].version' "$VARIANT_LOCK")" \
    --fence "$(jq -r --arg a "$app" '.apps[$a].fence' "$VARIANT_LOCK")" --out "$zip" "$@") || return 1
  jq --arg a "$app" --arg s "$(echo "$info" | jq -r .sha256)" --argjson z "$(echo "$info" | jq .size)" \
    '.apps[$a].cli.sha256 = $s | .apps[$a].cli.size = $z' "$VARIANT_LOCK" > "$VARIANT_LOCK.tmp" && mv "$VARIANT_LOCK.tmp" "$VARIANT_LOCK"
}
make_nojq_path() { # a PATH with every system tool and python3 but no jq
  NOJQ=$STATE/nojq-bin
  if [ ! -d "$NOJQ" ]; then
    mkdir -p "$NOJQ"
    local d f b
    for d in /usr/bin /bin /usr/sbin /sbin; do
      for f in "$d"/*; do
        b=${f##*/}
        [ "$b" = jq ] && continue
        [ -e "$NOJQ/$b" ] || ln -s "$f" "$NOJQ/$b"
      done
    done
    ln -sf "$(PATH=$DEF_PATH command -v python3)" "$NOJQ/python3"
  fi
}

# ---- compound checks -------------------------------------------------------------------------------------------------
check_clis() { # APPS
  local app ver out mode bad=''
  for app in $1; do
    ver=$(lock_val "$app" version)
    if [ ! -x "$PREFIX/$app-cli" ]; then
      bad="${bad}$app: $PREFIX/$app-cli is missing or not executable$NL"
      continue
    fi
    out=$("$PREFIX/$app-cli" --version 2>&1)
    [ "$out" = "$app-cli $ver" ] || bad="${bad}$app: --version printed '$out', the lock says $ver$NL"
    mode=$(stat -f %Lp "$PREFIX/$app-cli")
    [ "$mode" = 755 ] || bad="${bad}$app: mode is $mode, expected 755$NL"
  done
  agg "CLIs are installed at the locked version, mode 755" "$bad"
}
check_registrations() { # APPS
  local app exp act bad=''
  for app in $1; do
    exp=$(expected_reg "$app")
    act=$(actual_reg "$app")
    if [ "$exp" != "$act" ]; then
      bad="${bad}$app: expected $exp$NL    got      ${act:-<not registered>}$NL"
    elif ! jq -e --arg a "$app" '.mcpServers[$a].type == "stdio"' "$CLAUDE_JSON" > /dev/null 2>&1; then
      bad="${bad}$app: registered, but not as a stdio server$NL"
    fi
  done
  agg "user-scope registrations equal the expected command and argv for each fence mode" "$bad"
}
check_unregistered() { # APPS
  local app bad=''
  for app in $1; do
    [ -z "$(actual_reg "$app")" ] || bad="${bad}$app is still registered$NL"
  done
  agg "these apps are not registered: $1" "$bad"
}
check_register_calls() { # FROM APPS : each app was added exactly once with the contract's argv
  local from=$1 app exp lines bad=''
  for app in $2; do
    exp=$(expected_reg "$app")
    lines=$(calls_from "$from" | jq -c --arg a "$app" --argjson e "$exp" \
      'select(.[0] == "mcp" and .[1] == "add" and .[4] == $a) | (.[0:6] == ["mcp", "add", "-s", "user", $a, "--"]) and (.[6:] == ([$e.command] + $e.args))')
    if [ "$lines" != true ]; then
      bad="${bad}$app: want exactly one 'claude mcp add -s user $app -- <command> <args>' with the expected argv; saw: ${lines:-no add call}$NL"
    fi
  done
  agg "claude mcp add -s user NAME -- COMMAND ARGS... called once per app with the exact expected argv" "$bad"
}
check_workspaces() { # APPS
  local app mode bad=''
  for app in $1; do
    if [ ! -d "$WS/$app" ]; then
      bad="${bad}$app: $WS/$app is missing$NL"
      continue
    fi
    mode=$(stat -f %Lp "$WS/$app")
    [ "$mode" = 700 ] || bad="${bad}$app: workspace folder mode is $mode, expected 700$NL"
  done
  agg "one workspace folder per app, mode 700" "$bad"
}
check_skills_rendered() {
  local src name dst n=0 bad='' count
  for src in "$REPO"/skills/craft-*/SKILL.md; do
    [ -f "$src" ] || continue
    n=$((n + 1))
    name=$(basename "$(dirname "$src")")
    dst=$SKILLS/$name/SKILL.md
    if [ ! -f "$dst" ]; then
      bad="${bad}$name: not installed$NL"
      continue
    fi
    render_skill "$src" > "$STATE/expected-skill"
    cmp -s "$STATE/expected-skill" "$dst" || bad="${bad}$name: differs from the source rendered with WORKSPACE=$WS KIT_HOME=$KIT$NL"
    if grep -Eq '\{\{[^}]*\}\}' "$dst"; then bad="${bad}$name: a {{token}} is left$NL"; fi
  done
  agg "every skill is installed, rendered, and has no {{token}} left" "$bad"
  a_eq "the repo has 14 skills (craft-apps + 13)" 14 "$n"
  count=$(ls -d "$SKILLS"/craft-*/ 2> /dev/null | wc -l | tr -d ' ')
  a_eq "14 craft-* skill folders are installed" 14 "$count"
}
check_skills() {
  check_skills_rendered
  a_eq "a fresh install leaves no SKILL.md backups" 0 "$(ls "$SKILLS"/*/SKILL.md.bak-* 2> /dev/null | wc -l | tr -d ' ')"
  a_true "the master skill mentions the workspace and the kit home it was rendered with" \
    sh -c 'grep -Fq "$1" "$3" && grep -Fq "$2" "$3"' _ "$WS" "$KIT" "$SKILLS/craft-apps/SKILL.md"
}
check_hooks() { # [loose] : both hooks registered once each, with --workspace
  local shell_cmd mcp_cmd n m bad='' app matcher
  shell_cmd="python3 $KIT/hooks/craft-shell-guard.py --workspace $WS || true"
  mcp_cmd="python3 $KIT/hooks/craft-mcp-guard.py --workspace $WS || true"
  if [ "${1:-}" = loose ]; then
    n=$(jq --arg sm "$SHELL_MATCHER" --arg s "$KIT/hooks/craft-shell-guard.py" --arg w "$WS" '[.hooks.PreToolUse[]? | select(.matcher == $sm) | .hooks[]? | select((.command | contains($s)) and (.command | contains("--workspace")) and (.command | contains($w)))] | length' "$SETTINGS" 2> /dev/null)
    m=$(jq --arg s "$KIT/hooks/craft-mcp-guard.py" --arg w "$WS" '[.hooks.PreToolUse[]? | select((.matcher // "") | startswith("mcp__")) | .hooks[]? | select((.command | contains($s)) and (.command | contains("--workspace")) and (.command | contains($w)))] | length' "$SETTINGS" 2> /dev/null)
  else
    n=$(jq --arg sm "$SHELL_MATCHER" --arg c "$shell_cmd" '[.hooks.PreToolUse[]? | select(.matcher == $sm) | .hooks[]? | select(.command == $c and .type == "command")] | length' "$SETTINGS" 2> /dev/null)
    m=$(jq --arg c "$mcp_cmd" '[.hooks.PreToolUse[]? | select((.matcher // "") | startswith("mcp__")) | .hooks[]? | select(.command == $c and .type == "command")] | length' "$SETTINGS" 2> /dev/null)
  fi
  a_eq "settings.json has exactly one PreToolUse hook for the shell matcher ($SHELL_MATCHER) running craft-shell-guard.py --workspace" 1 "${n:-none}"
  a_eq "settings.json has exactly one PreToolUse hook for mcp__ tools running craft-mcp-guard.py --workspace" 1 "${m:-none}"
  matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | contains("craft-mcp-guard.py")) | .matcher' "$SETTINGS" 2> /dev/null | head -n 1)
  for app in $APPS; do
    case $matcher in *"$app"*) ;; *) bad="${bad}$app$NL" ;; esac
  done
  agg "the MCP guard matcher covers all 13 apps (matcher: $matcher)" "$bad"
  a_true "settings.json is still valid JSON" jq -e . "$SETTINGS"
}
check_receipt() { # APPS
  local R=$KIT/receipt.json app bad='' ver repo
  a_true "receipt.json exists and is valid JSON" jq -e . "$R"
  a_jq "receipt: schema 1" "$R" '.schema == 1'
  a_eq "receipt: kitVersion is the VERSION file" "$(version_str)" "$(jq -r '.kitVersion // empty' "$R" 2> /dev/null)"
  a_jq "receipt: workspace, prefix and claudeDir are the ones used" "$R" '.workspace == $w and .prefix == $p and .claudeDir == $c' \
    --arg w "$WS" --arg p "$PREFIX" --arg c "$CLAUDE_DIR"
  a_jq "receipt: installedAt, repoDir and guiDir are present" "$R" '(.installedAt | type == "string" and length > 0) and (.repoDir | type == "string") and has("guiDir")'
  repo=$(jq -r '.repoDir // empty' "$R" 2> /dev/null)
  a_eq "receipt: repoDir is this checkout" "$REPO" "$(cd "$repo" 2> /dev/null && pwd -P)"
  for app in $1; do
    ver=$(lock_val "$app" version)
    jq -e --arg a "$app" --arg v "$ver" '.apps[$a] as $e | $e.version == $v and ($e | has("cli") and has("gui") and has("registered")) and ($e.cli // false) and ($e.registered // false)' "$R" > /dev/null 2>&1 ||
      bad="${bad}$app: want version $ver with cli and registered set, got $(jq -c --arg a "$app" '.apps[$a]' "$R" 2> /dev/null)$NL"
  done
  agg "receipt: apps entries carry version, cli, gui, registered" "$bad"
  a_jq "receipt: skills and hooks arrays" "$R" '(.skills | type == "array") and (.hooks | type == "array")'
}
check_runtime_copy() {
  local f src rel bad='' n1 n2
  for f in doctor.sh uninstall.sh VERSION manifest/apps.lock.json share/craft.sb bin/craft-sandbox lib/craftkit.py lib/mcp_probe.py lib/settings_edit.py hooks/craft-shell-guard.py hooks/craft-mcp-guard.py hooks/risky-tools.json; do
    [ -f "$KIT/$f" ] || bad="${bad}$f is missing from $KIT$NL"
  done
  for src in "$REPO"/doctor.sh "$REPO"/uninstall.sh "$REPO"/VERSION "$REPO"/share/craft.sb "$REPO"/bin/craft-sandbox "$REPO"/lib/* "$REPO"/hooks/*.py "$REPO"/hooks/*.json; do
    [ -f "$src" ] || continue
    rel=${src#"$REPO"/}
    cmp -s "$src" "$KIT/$rel" 2> /dev/null || bad="${bad}$rel differs from the repo's copy$NL"
  done
  for rel in data tests/smoke; do
    n1=$(find "$REPO/$rel" -type f 2> /dev/null | wc -l | tr -d ' ')
    n2=$(find "$KIT/$rel" -type f 2> /dev/null | wc -l | tr -d ' ')
    [ "$n1" = "$n2" ] || bad="${bad}$rel: the repo has $n1 files, the runtime copy $n2$NL"
  done
  for f in doctor.sh uninstall.sh bin/craft-sandbox; do
    [ ! -f "$KIT/$f" ] || [ -x "$KIT/$f" ] || bad="${bad}$f is not executable$NL"
  done
  agg "KIT_HOME holds the runtime copy of the kit (scripts, lib, manifest, hooks, share, bin, data, smoke tests)" "$bad"
  a_jq "runtime copy: manifest/apps.lock.json is a schema-1 lock" "$KIT/manifest/apps.lock.json" '.schema == 1 and (.apps | length) >= 1'
  a_true "install.log exists and is not empty" test -s "$KIT/install.log"
}
check_sandbox_wrapper() {
  a_true "PREFIX/craft-sandbox is an executable copy of bin/craft-sandbox" sh -c '[ -x "$1" ] && cmp -s "$1" "$2"' _ "$PREFIX/craft-sandbox" "$REPO/bin/craft-sandbox"
  a_true "KIT_HOME/share/craft.sb is a copy of share/craft.sb" cmp -s "$REPO/share/craft.sb" "$KIT/share/craft.sb"
}
check_prefix_listing() { # APPS : PREFIX holds exactly these CLIs and the wrapper
  local want got
  want=$( (for a in $1; do echo "$a-cli"; done; echo craft-sandbox) | LC_ALL=C sort | tr '\n' ' ')
  # <app>-cli.bak-craft-kit-<timestamp> files are the user's earlier programs, kept on purpose (B1-SUPPLY-2).
  # shellcheck disable=SC2010
  got=$(ls -A "$PREFIX" 2> /dev/null | grep -v '\.bak-craft-kit-[0-9-]*$' | LC_ALL=C sort | tr '\n' ' ')
  a_eq "PREFIX holds exactly the CLIs and craft-sandbox (no temp or partial files)" "$want" "$got"
}
fixture_zip_for() { jq -r --arg a "$1" '.apps[$a].cli.asset' "$CRAFT_KIT_LOCK"; }

# ====================================================================================================================
# cases
# ====================================================================================================================
t_help() {
  begin_case help
  new_world
  local h0 f missing
  h0=$(tree_hash "$HOME")
  inst --help
  a_rc "install.sh --help exits 0" 0
  missing=''
  for f in -y --yes --dry-run --only --gui --no-gui --workspace --prefix --gui-dir --offline-dir --no-skills --no-hook --no-mcp --version -h --help; do
    grep -Fq -- "$f" "$OUTF" || missing="$missing $f"
  done
  agg "install.sh --help documents every flag of the contract" "${missing:+missing:$missing}"
  inst --version
  a_rc "install.sh --version exits 0" 0
  a_outf "install.sh --version prints the VERSION file" "$(version_str)"
  uninst --help
  a_rc "uninstall.sh --help exits 0" 0
  missing=''
  for f in -y --yes --dry-run --keep-cli --remove-gui --keep-skills --keep-hooks; do
    grep -Fq -- "$f" "$OUTF" || missing="$missing $f"
  done
  agg "uninstall.sh --help documents every flag of the contract" "${missing:+missing:$missing}"
  inst --no-such-flag
  a_rc "install.sh: unknown flag exits 2" 2
  inst --only
  a_rc "install.sh: --only without a value exits 2" 2
  inst --workspace
  a_rc "install.sh: --workspace without a value exits 2" 2
  inst --only wordcraft,nosuchapp --yes --no-gui
  a_rc "install.sh: --only with an unknown app exits 2 (inferred)" 2
  uninst --no-such-flag
  a_rc "uninstall.sh: unknown flag exits 2" 2
  a_true "install.sh and uninstall.sh are executable" sh -c '[ -x "$1" ] && [ -x "$2" ]' _ "$INSTALL" "$UNINSTALL"
  run "$INSTALL" --help
  a_rc "install.sh --help works through its #!/usr/bin/env bash shebang" 0
  a_eq "--help, --version and usage errors changed nothing in HOME" "$h0" "$(tree_hash "$HOME")"
  a_true "no temp files left behind" tmp_empty
  end_case
}

t_preflight() {
  begin_case preflight
  new_world
  local h0 c0
  h0=$(tree_hash "$HOME")
  export CLAUDE_BIN=$HOME/no-such-dir/claude
  inst_y --only wordcraft
  a_rc "a missing claude CLI exits 3 (preflight failed)" 3
  a_out "the message names claude" 'claude'
  a_eq "nothing was created before the preflight stopped the run" "$h0" "$(tree_hash "$HOME")"
  inst_y --dry-run --only wordcraft
  a_rc "--dry-run with a missing claude CLI still shows the plan (exit 0)" 0
  a_out "...and warns that a real install would stop" 'would stop'
  a_out "...and prints the plan" 'install plan'
  a_eq "...and changes nothing" "$h0" "$(tree_hash "$HOME")"
  export CLAUDE_BIN=$DEF_CLAUDE_BIN
  make_nojq_path
  local old_path=$PATH
  PATH=$NOJQ
  export PATH
  inst_y --only wordcraft
  PATH=$old_path
  export PATH
  a_rc "a missing jq exits 3 (preflight failed)" 3
  a_out "the message names jq and says how to get it" 'jq'
  a_out "the message carries the fix hint 'brew install jq'" 'brew install jq'
  a_eq "nothing was created when jq was missing" "$h0" "$(tree_hash "$HOME")"
  c0=$(log_lines)
  inst --only wordcraft --no-gui --gui-dir "$GUI_DIR"
  a_rc "no --yes and no terminal exits 4" 4
  a_out "...and tells the user to re-run with --yes" '--yes'
  a_eq "...without changing anything" "$h0" "$(tree_hash "$HOME")"
  a_eq "...and without registering anything" 0 "$(count_calls "$c0" add)"
  printf 'y\n' > "$STATE/yes.txt"
  RUN_STDIN=$STATE/yes.txt
  inst --only wordcraft --no-gui --gui-dir "$GUI_DIR"
  a_rc "an answer piped into stdin does not count as a terminal: still exit 4" 4
  a_eq "...and nothing was installed" "$h0" "$(tree_hash "$HOME")"
  a_true "no temp files left behind" tmp_empty
  end_case
}

t_dry_run() {
  begin_case dry-run
  new_world
  seed_json "$SETTINGS" '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}'
  seed_json "$CLAUDE_JSON" '{"numStartups":3,"mcpServers":{"myserver":{"type":"stdio","command":"/usr/bin/true","args":[],"env":{}}}}'
  mkdir -p "$SKILLS/my-own" "$WS/wordcraft"
  echo "mine" > "$SKILLS/my-own/SKILL.md"
  echo "precious" > "$WS/wordcraft/keep.txt"
  local h0 c0 app ver missing=''
  h0=$(tree_hash "$HOME")
  c0=$(log_lines)
  inst_y --dry-run
  a_rc "--dry-run exits 0" 0
  a_eq "--dry-run changes nothing in HOME (hash before == after)" "$h0" "$(tree_hash "$HOME")"
  a_true "--dry-run leaves no temp files" tmp_empty
  a_eq "--dry-run never calls claude mcp add" 0 "$(count_calls "$c0" add)"
  a_eq "--dry-run never calls claude mcp remove" 0 "$(count_calls "$c0" remove)"
  for app in $APPS; do
    ver=$(lock_val "$app" version)
    grep -F -- "$app" "$OUTF" | grep -Fq -- "$ver" || missing="$missing $app($ver)"
  done
  agg "the plan names every app next to its version (a line holding both)" "${missing:+not found:$missing}"
  a_out "the plan says it is a dry run" 'dry'
  a_out "the plan shows a size in MB" 'MB'
  a_out "the plan lists an install action" 'install'
  a_out "the plan mentions the three fence modes (roots, root, sandbox)" 'sandbox'
  a_out_path "the plan lists the workspace path" "$WS"
  a_out_path "the plan lists the prefix path" "$PREFIX"
  a_out_path "the plan lists the kit home path" "$KIT"
  inst --dry-run --no-gui --gui-dir "$GUI_DIR"
  a_rc "--dry-run needs no --yes and no terminal (inferred)" 0
  a_eq "...and still changes nothing" "$h0" "$(tree_hash "$HOME")"
  inst_y --dry-run --gui
  a_rc "--dry-run --gui exits 0" 0
  a_eq "...and still changes nothing (no disk image mounted, no app copied)" "$h0" "$(tree_hash "$HOME")"
  a_true "...and no disk image is left mounted" no_images_mounted
  inst_y --dry-run --only wordcraft,pdfcraft --no-hook --no-skills --no-mcp
  a_rc "--dry-run with --only and the --no-* flags exits 0" 0
  a_eq "...and changes nothing" "$h0" "$(tree_hash "$HOME")"
  end_case
}

t_lifecycle() {
  new_world
  local user_settings user_json c0 app sh0 cj0 bak0 m0 s0 f
  user_settings='{"model":"opus","env":{"FOO":"bar"},"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}'
  user_json='{"numStartups":3,"mcpServers":{"myserver":{"type":"stdio","command":"/usr/bin/true","args":["serve"],"env":{}}}}'
  seed_json "$SETTINGS" "$user_settings"
  cp "$SETTINGS" "$STATE/user-settings.orig"
  seed_json "$CLAUDE_JSON" "$user_json"
  mkdir -p "$SKILLS/my-own"
  echo "mine" > "$SKILLS/my-own/SKILL.md"

  # ---------------------------------------------------------------- fresh install
  begin_case fresh-install
  c0=$(log_lines)
  inst_y
  a_rc "install.sh --yes --no-gui exits 0" 0
  check_clis "$APPS"
  check_prefix_listing "$APPS"
  check_sandbox_wrapper
  check_registrations "$APPS"
  check_register_calls "$c0" "$APPS"
  a_eq "all 13 apps plus the user's own server are registered (14 user-scope servers)" 14 "$(jq '.mcpServers | length' "$CLAUDE_JSON")"
  a_eq "nothing was registered in local or project scope" 0 "$(jq '[.projects[]?.mcpServers[]?] | length' "$CLAUDE_JSON")"
  a_eq "wordcraft is fenced with --automation-read-root and --automation-write-root on its own folder" \
    "$WS/wordcraft $WS/wordcraft" "$(jq -r '.mcpServers.wordcraft.args | .[index("--automation-read-root") + 1] + " " + .[index("--automation-write-root") + 1]' "$CLAUDE_JSON")"
  a_eq "wordcraft ends with --author Claude" '["--author","Claude"]' "$(jq -c '.mcpServers.wordcraft.args[-2:]' "$CLAUDE_JSON")"
  a_eq "pdfcraft is the only app fenced with a single --root" "mcp --root $WS/pdfcraft" "$(jq -r '.mcpServers.pdfcraft.args | join(" ")' "$CLAUDE_JSON")"
  a_eq "filmcraft runs through craft-sandbox with its own folder as ROOT" "$PREFIX/craft-sandbox $WS/filmcraft $PREFIX/filmcraft-cli mcp" \
    "$(jq -r '.mcpServers.filmcraft | .command + " " + (.args | join(" "))' "$CLAUDE_JSON")"
  check_workspaces "$APPS"
  check_skills
  check_hooks
  check_receipt "$APPS"
  check_runtime_copy
  a_jq "receipt: 14 skills and 2 hooks recorded" "$KIT/receipt.json" '(.skills | length) == 14 and (.hooks | length) == 2'
  a_jq "receipt: 13 apps recorded" "$KIT/receipt.json" '.apps | length == 13'
  a_true "no GUI app was installed (the GUI is optional)" test -z "$(ls -A "$GUI_DIR" 2> /dev/null)"
  a_out "the summary points to the doctor" 'doctor'
  a_out "the summary says to open a new Claude Code session" 'new (claude code )?session'
  a_true "no temp files left behind" tmp_empty
  end_case

  begin_case user-config-preserved
  a_jq "settings.json keeps the user's own keys and values" "$SETTINGS" '.model == "opus" and .env.FOO == "bar" and .permissions.allow == ["Bash(ls:*)"]'
  a_jq "settings.json keeps the user's own hook next to the kit's" "$SETTINGS" '[.hooks.PreToolUse[] | select(.matcher == "Edit")] | length == 1'
  a_eq "settings.json keeps its key order (model, env, permissions, hooks)" '["model","env","permissions","hooks"]' "$(jq -c 'keys_unsorted' "$SETTINGS")"
  a_true "a backup of the original settings.json was made before the first change" \
    sh -c 'ls "$1"/settings.json.bak-craft-kit-* > /dev/null 2>&1 && cmp -s "$(ls "$1"/settings.json.bak-craft-kit-* | head -n 1)" "$2"' _ "$CLAUDE_DIR" "$STATE/user-settings.orig"
  a_jq ".claude.json keeps the user's own keys and server" "$CLAUDE_JSON" '.numStartups == 3 and .mcpServers.myserver.command == "/usr/bin/true" and .mcpServers.myserver.args == ["serve"]'
  a_eq "the user's own skill is untouched" "mine" "$(cat "$SKILLS/my-own/SKILL.md")"
  end_case

  # ---------------------------------------------------------------- second run
  begin_case idempotent-rerun
  backdate "$PREFIX"/* "$SKILLS"/craft-*/SKILL.md
  m0=$(mtimes "$PREFIX")
  s0=$(for f in "$SKILLS"/craft-*/SKILL.md; do stat -f '%N %m' "$f"; done)
  sh0=$(file_hash "$SETTINGS")
  cj0=$(file_hash "$CLAUDE_JSON")
  bak0=$(settings_backups)
  c0=$(log_lines)
  inst_y
  a_rc "a second install.sh --yes exits 0" 0
  a_eq "settings.json is byte-identical (no duplicate hooks)" "$sh0" "$(file_hash "$SETTINGS")"
  a_eq "no new settings.json backup was made" "$bak0" "$(settings_backups)"
  a_eq ".claude.json is byte-identical" "$cj0" "$(file_hash "$CLAUDE_JSON")"
  a_eq "no claude mcp add on the second run" 0 "$(count_calls "$c0" add)"
  a_eq "no claude mcp remove on the second run" 0 "$(count_calls "$c0" remove)"
  a_eq "up-to-date CLIs and the wrapper were not rewritten (mtimes kept)" "$m0" "$(mtimes "$PREFIX")"
  a_eq "identical skills were not rewritten (mtimes kept)" "$s0" "$(for f in "$SKILLS"/craft-*/SKILL.md; do stat -f '%N %m' "$f"; done)"
  a_eq "no SKILL.md backups were made for identical skills" 0 "$(ls "$SKILLS"/*/SKILL.md.bak-* 2> /dev/null | wc -l | tr -d ' ')"
  check_hooks
  check_registrations "$APPS"
  check_receipt "$APPS"
  a_true "the second run reports every app as skipped / up to date (at least 13 such lines, wording inferred)" test "$(grep -ciE 'skip|up[- ]to[- ]date|already|unchanged' "$OUTF")" -ge 13
  a_true "no temp files left behind" tmp_empty
  end_case

  # ---------------------------------------------------------------- drift
  begin_case registration-drift
  jq '.mcpServers.wordcraft.args[2] = "/somewhere/else" | .mcpServers.filmcraft.command = "/usr/local/bin/other-wrapper" | del(.mcpServers.pdfcraft)' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
  c0=$(log_lines)
  inst_y
  a_rc "install.sh repairs drifted registrations and exits 0" 0
  check_registrations "$APPS"
  for app in wordcraft filmcraft; do
    a_eq "$app (different registration): exactly one claude mcp remove" 1 "$(count_calls "$c0" remove "$app")"
    a_eq "$app: the remove call is exactly 'mcp remove $app -s user'" 1 \
      "$(calls_from "$c0" | jq -c --arg a "$app" 'select(. == ["mcp", "remove", $a, "-s", "user"])' | wc -l | tr -d ' ')"
    a_eq "$app: exactly one claude mcp add afterwards" 1 "$(count_calls "$c0" add "$app")"
    a_true "$app: the remove came before the add" sh -c '
      r=$(tail -n +"$(($1 + 1))" "$2" | grep -n "\"remove\",\"$3\"" | head -n 1 | cut -d: -f1)
      a=$(tail -n +"$(($1 + 1))" "$2" | grep -n "\"add\",\"-s\",\"user\",\"$3\"" | head -n 1 | cut -d: -f1)
      [ -n "$r" ] && [ -n "$a" ] && [ "$r" -lt "$a" ]' _ "$c0" "$FAKE_CLAUDE_LOG" "$app"
  done
  a_eq "pdfcraft (missing registration): no remove, one add" "0 1" "$(count_calls "$c0" remove pdfcraft) $(count_calls "$c0" add pdfcraft)"
  a_eq "the other 10 apps were not touched" 0 "$(calls_from "$c0" | jq -c 'select(.[0] == "mcp" and (.[1] == "add" or .[1] == "remove") and (any(.[2:6][]; . == "wordcraft" or . == "filmcraft" or . == "pdfcraft") | not))' | wc -l | tr -d ' ')"
  a_out "the output says wordcraft's registration differed and was replaced" 'wordcraft.*(differ|replac|updat|repair|re-?regist|drift|mismatch|fix|chang)|(differ|replac|updat|repair|re-?regist|drift|mismatch|fix|chang).*wordcraft'
  a_eq "the user's own server survived the repair" "/usr/bin/true" "$(jq -r '.mcpServers.myserver.command' "$CLAUDE_JSON")"
  end_case

  begin_case dry-run-on-installed
  sh0=$(tree_hash "$HOME")
  c0=$(log_lines)
  inst_y --dry-run
  a_rc "--dry-run on an installed kit exits 0" 0
  a_eq "...and changes nothing" "$sh0" "$(tree_hash "$HOME")"
  a_eq "...and never calls claude mcp add or remove" 0 "$(($(count_calls "$c0" add) + $(count_calls "$c0" remove)))"
  end_case

  # ---------------------------------------------------------------- uninstall
  begin_case uninstall-dry-run
  sh0=$(tree_hash "$HOME")
  c0=$(log_lines)
  uninst_y --dry-run
  a_rc "uninstall.sh --dry-run exits 0" 0
  a_eq "...and changes nothing" "$sh0" "$(tree_hash "$HOME")"
  a_eq "...and never calls claude mcp remove" 0 "$(count_calls "$c0" remove)"
  a_true "...and leaves no temp files" tmp_empty
  end_case

  begin_case uninstall-tampered-receipt
  local pristine=$STATE/receipt.pristine canary_paths
  cp "$KIT/receipt.json" "$pristine"
  mkdir -p "$HOME/victim-skill" "$T/worlds/outside" "$T/worlds/outside-claude/skills/craft-apps"
  echo keep > "$HOME/victim-cli"
  echo keep > "$HOME/victim-skill/SKILL.md"
  echo keep > "$T/worlds/outside/wordcraft-cli"
  echo keep > "$T/worlds/outside/craft-sandbox"
  echo keep > "$T/worlds/outside-claude/skills/craft-apps/SKILL.md"
  echo '{"keep":true}' > "$T/worlds/outside-claude/settings.json"
  canary_paths="$HOME/victim-cli $HOME/victim-skill/SKILL.md $T/worlds/outside/wordcraft-cli $T/worlds/outside/craft-sandbox $T/worlds/outside-claude/skills/craft-apps/SKILL.md $T/worlds/outside-claude/settings.json"
  tamper() { # DESC JQ-FILTER [JQ-ARGS...]
    local desc=$1 filter=$2 c1 p bad=''
    shift 2
    jq "$@" "$filter" "$pristine" > "$KIT/receipt.json"
    c1=$(log_lines)
    uninst_y
    a_true "$desc: uninstall.sh refuses (non-zero exit)" test "$RC" -ne 0
    a_out "$desc: it says the receipt is the problem" 'receipt'
    a_true "$desc: the kit, the CLIs and the skills are all still there" \
      sh -c '[ -d "$1" ] && [ -x "$2/wordcraft-cli" ] && [ -x "$2/craft-sandbox" ] && [ -f "$3/craft-apps/SKILL.md" ]' _ "$KIT" "$PREFIX" "$SKILLS"
    a_eq "$desc: nothing was unregistered" 0 "$(count_calls "$c1" remove)"
    for p in $canary_paths; do [ -e "$p" ] || bad="${bad}deleted: $p$NL"; done
    agg "$desc: files outside the kit locations are untouched" "$bad"
    a_eq "$desc: the hooks are still registered" 2 "$(list_hooks | grep -c 'craft-.*-guard.py')"
    cp "$pristine" "$KIT/receipt.json"
  }
  tamper "receipt prefix is a relative path" '.prefix = "relative/bin"'
  tamper "receipt prefix climbs out with .." '.prefix = ($h + "/../outside")' --arg h "$HOME"
  tamper "receipt prefix is /" '.prefix = "/"'
  tamper "receipt app name climbs out with .." '.apps["../../victim"] = {version: "0", cli: true, gui: false, registered: false}'
  tamper "receipt skill name climbs out with .." '.skills += ["../../victim-skill"]'
  tamper "receipt claudeDir climbs out with .." '.claudeDir = ($h + "/../outside-claude")' --arg h "$HOME"
  end_case

  begin_case uninstall-full
  jq '.mcpServers.figcraft = {"type": "stdio", "command": "/usr/local/bin/my-figcraft", "args": ["serve"], "env": {}}' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
  mkdir -p "$WS/wordcraft/out" "$SKILLS/craft-mine"
  echo "my report" > "$WS/wordcraft/out/report.docx"
  echo "my own craft skill" > "$SKILLS/craft-mine/SKILL.md"
  c0=$(log_lines)
  uninst_y
  a_rc "uninstall.sh --yes (run from the runtime copy) exits 0" 0
  check_unregistered "$(all_apps_but figcraft)"
  a_eq "the user's own figcraft registration (a different command) was kept" '{"args":["serve"],"command":"/usr/local/bin/my-figcraft"}' "$(actual_reg figcraft)"
  a_eq "claude mcp remove was never called for figcraft" 0 "$(count_calls "$c0" remove figcraft)"
  a_eq "claude mcp remove -s user was called once for each of the other 12 apps" 12 \
    "$(calls_from "$c0" | jq -c 'select(.[0] == "mcp" and .[1] == "remove" and .[3] == "-s" and .[4] == "user")' | wc -l | tr -d ' ')"
  a_jq "the user's own server and keys in .claude.json survived" "$CLAUDE_JSON" '.numStartups == 3 and .mcpServers.myserver.command == "/usr/bin/true"'
  # shellcheck disable=SC2010
  a_eq "the CLIs and the sandbox wrapper are gone from PREFIX" 0 "$(ls "$PREFIX" 2> /dev/null | grep -cE -- '-cli$|^craft-sandbox$')"
  a_eq "the 14 kit skills are gone" 0 "$(for a in $APPS apps; do [ -e "$SKILLS/craft-$a" ] && echo x; done | wc -l | tr -d ' ')"
  a_eq "the user's own skills (my-own, craft-mine) are kept" "mine|my own craft skill" "$(cat "$SKILLS/my-own/SKILL.md")|$(cat "$SKILLS/craft-mine/SKILL.md")"
  a_eq "the kit's hooks are gone from settings.json" 0 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  a_jq "the user's own hook and settings are kept" "$SETTINGS" '.model == "opus" and ([.hooks.PreToolUse[]? | select(.matcher == "Edit")] | length == 1)'
  # The registration this case replaced earlier was saved under backup/ (R1-CLEAN-3); that is the user's old
  # configuration, so uninstall keeps it and says so. Nothing else of the kit folder remains.
  a_eq "KIT_HOME is removed apart from backup/ with the replaced registration" "backup" "$(ls -A "$KIT" 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"
  a_out "...and uninstall says it kept the folder because of backup/" 'kept .*backup/'

  a_eq "the workspace is never deleted: all 13 folders remain" 13 "$(ls -d "$WS"/*/ 2> /dev/null | wc -l | tr -d ' ')"
  a_eq "...with the user's files inside" "my report" "$(cat "$WS/wordcraft/out/report.docx" 2> /dev/null)"
  a_out_path "the output prints the workspace path it kept" "$WS"
  a_true "no temp files left behind" tmp_empty
  end_case
}

t_bad_sha() {
  begin_case bad-sha
  new_world
  derive_fixtures badsha
  local zip c0 ok
  zip=$VARIANT_DIR/$(fixture_zip_for figcraft)
  printf 'corruption' >> "$zip"
  ok=$(all_apps_but figcraft)
  c0=$(log_lines)
  inst_y
  a_rc "one corrupted download makes the run exit 1" 1
  a_false "figcraft-cli is not installed" test -e "$PREFIX/figcraft-cli"
  a_eq "figcraft is not registered" "" "$(actual_reg figcraft)"
  a_eq "no claude mcp add figcraft" 0 "$(count_calls "$c0" add figcraft)"
  check_clis "$ok"
  check_registrations "$ok"
  check_workspaces "$ok"
  a_out "the summary names figcraft and the failure" 'figcraft.*(fail|mismatch|checksum|sha|corrupt|verif)|(fail|mismatch|checksum|sha|corrupt|verif).*figcraft'
  a_true "the receipt was still written, and says figcraft is not installed" \
    sh -c 'jq -e ".schema == 1 and ((.apps.figcraft.cli // false) | not) and ((.apps.figcraft.registered // false) | not) and ((.apps.wordcraft.cli // false) and (.apps.wordcraft.registered // false))" "$1" > /dev/null' _ "$KIT/receipt.json"
  a_eq "the other steps still ran: 14 skills installed" 14 "$(ls -d "$SKILLS"/craft-*/ 2> /dev/null | wc -l | tr -d ' ')"
  check_hooks
  a_true "no temp files left behind (the bad download was deleted)" tmp_empty
  a_eq "PREFIX holds the 12 good CLIs and the wrapper only" "$(( $(echo "$ok" | wc -w) + 1 ))" "$(ls -A "$PREFIX" | wc -l | tr -d ' ')"
  export CRAFT_KIT_OFFLINE_DIR=$DEF_OFF CRAFT_KIT_LOCK=$DEF_LOCK
  inst_y
  a_rc "re-running with a good download repairs it and exits 0" 0
  check_clis "$APPS"
  check_registrations "$APPS"
  end_case
}

t_zip_slip() {
  begin_case zip-slip
  new_world
  derive_fixtures zipslip
  local bad_apps="cadcraft photocraft deckcraft" ok app bad=''
  ok=$(all_apps_but cadcraft photocraft deckcraft)
  variant_cli cadcraft --evil dotdot
  variant_cli photocraft --evil abs
  variant_cli deckcraft --evil nested-dotdot
  rm -f /tmp/craftkit-zipslip-sentinel.txt
  inst_y
  a_rc "archives with ../ or absolute entries are rejected: exit 1" 1
  for app in $bad_apps; do
    [ ! -e "$PREFIX/$app-cli" ] || bad="${bad}$app-cli was installed from a hostile archive$NL"
    [ -z "$(actual_reg "$app")" ] || bad="${bad}$app was registered$NL"
    grep -Ei "$app" "$OUTF" | grep -Eqi 'unsafe|reject|invalid|path|\.\.|travers|archive|zip|refus|fail|illegal|absolute' || bad="${bad}the output does not report $app as rejected$NL"
  done
  agg "the three hostile archives (../x, <top>/../../x, /tmp/x) are rejected and reported, nothing installed or registered" "$bad"
  check_clis "$ok"
  check_registrations "$ok"
  a_eq "nothing was written outside the extraction folder inside the sandbox" 0 "$(find "$T" -name 'craftkit-zipslip-sentinel*' 2> /dev/null | wc -l | tr -d ' ')"
  a_false "nothing was written to /tmp" test -e /tmp/craftkit-zipslip-sentinel.txt
  rm -f /tmp/craftkit-zipslip-sentinel.txt
  a_true "no temp files left behind" tmp_empty
  end_case
}

t_fence_fail() {
  begin_case fence-fail
  new_world
  derive_fixtures nofence
  local ok c0
  ok=$(all_apps_but wordcraft pdfcraft)
  variant_cli wordcraft --no-fence-help
  variant_cli pdfcraft --no-fence-help
  c0=$(log_lines)
  inst_y
  a_rc "a roots/root CLI whose --help lacks its fence flags fails the run: exit 1" 1
  a_eq "wordcraft is NOT registered unfenced (fail closed)" "" "$(actual_reg wordcraft)"
  a_eq "pdfcraft is NOT registered unfenced (fail closed)" "" "$(actual_reg pdfcraft)"
  a_eq "no claude mcp add for them" 0 "$(($(count_calls "$c0" add wordcraft) + $(count_calls "$c0" add pdfcraft)))"
  a_out "wordcraft is reported as failed" 'wordcraft.*(fail|fence|flag|confine|refus)|(fail|fence|flag|confine|refus).*wordcraft'
  a_out "pdfcraft is reported as failed" 'pdfcraft.*(fail|fence|flag|confine|refus)|(fail|fence|flag|confine|refus).*pdfcraft'
  check_clis "$ok"
  check_registrations "$ok"
  a_true "...and the other 11 apps were registered" test "$(jq '.mcpServers | length' "$CLAUDE_JSON")" -eq 11
  end_case
}

t_only() {
  begin_case only
  new_world
  local want c0
  c0=$(log_lines)
  inst --yes --only wordcraft,filmcraft --gui-dir "$GUI_DIR"
  a_rc "--only wordcraft,filmcraft (no --gui/--no-gui, no terminal) exits 0" 0
  check_clis "wordcraft filmcraft"
  check_prefix_listing "wordcraft filmcraft"
  check_registrations "wordcraft filmcraft"
  check_register_calls "$c0" "wordcraft filmcraft"
  a_eq "only the selected apps are registered" '["filmcraft","wordcraft"]' "$(jq -c '.mcpServers | keys' "$CLAUDE_JSON")"
  check_workspaces "wordcraft filmcraft"
  a_eq "workspace folders exist only for the selected apps" "filmcraft wordcraft" "$(ls "$WS" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  a_true "the sandbox apps get craft-sandbox and its profile" sh -c '[ -x "$1/craft-sandbox" ] && [ -f "$2/share/craft.sb" ]' _ "$PREFIX" "$KIT"
  a_jq "the receipt lists the selected apps as installed and the others not" "$KIT/receipt.json" \
    '((.apps.wordcraft.cli // false) and (.apps.filmcraft.cli // false)) and ([.apps | to_entries[] | select(.key != "wordcraft" and .key != "filmcraft") | select(.value.cli // false)] | length == 0)'
  a_true "without --gui the default is no desktop app (inferred)" test -z "$(ls -A "$GUI_DIR" 2> /dev/null)"
  new_world
  inst_y --only pdfcraft
  a_rc "--only with a single app exits 0" 0
  check_clis "pdfcraft"
  a_eq "only pdfcraft is registered" '["pdfcraft"]' "$(jq -c '.mcpServers | keys' "$CLAUDE_JSON")"
  end_case
}

t_no_flags() {
  local sh0 c0
  begin_case no-hook
  new_world
  seed_json "$SETTINGS" '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}'
  sh0=$(file_hash "$SETTINGS")
  inst_y --no-hook --only wordcraft,pdfcraft
  a_rc "--no-hook exits 0" 0
  a_eq "settings.json is byte-identical" "$sh0" "$(file_hash "$SETTINGS")"
  a_eq "no settings.json backup was made" 0 "$(settings_backups)"
  check_clis "wordcraft pdfcraft"
  check_registrations "wordcraft pdfcraft"
  a_jq "receipt: no hooks recorded" "$KIT/receipt.json" '.hooks | length == 0'
  end_case

  begin_case no-skills
  new_world
  inst_y --no-skills --only wordcraft,pdfcraft
  a_rc "--no-skills exits 0" 0
  a_eq "no craft-* skill was installed" 0 "$(ls -d "$SKILLS"/craft-*/ 2> /dev/null | wc -l | tr -d ' ')"
  check_clis "wordcraft pdfcraft"
  check_registrations "wordcraft pdfcraft"
  check_hooks
  a_jq "receipt: no skills recorded" "$KIT/receipt.json" '.skills | length == 0'
  end_case

  begin_case no-mcp
  new_world
  c0=$(log_lines)
  inst_y --no-mcp --only wordcraft,pdfcraft
  a_rc "--no-mcp exits 0" 0
  a_eq "claude mcp was never called" 0 "$(calls_from "$c0" | jq -c 'select(.[0] == "mcp")' | wc -l | tr -d ' ')"
  a_eq "nothing is registered" "" "$(jq -c '.mcpServers // empty' "$CLAUDE_JSON" 2> /dev/null | tr -d '{}')"
  check_clis "wordcraft pdfcraft"
  check_hooks
  a_jq "receipt: the apps are installed but not registered" "$KIT/receipt.json" '(.apps.wordcraft.cli // false) and ((.apps.wordcraft.registered // false) | not)'
  end_case
}

t_legacy() {
  begin_case legacy-migration
  new_world
  local legacy_hook=$HOME/.local/share/craft-skills/craft-shell-guard.py
  local legacy_profile=$HOME/.local/share/craft-sandbox/craft.sb
  local c0 app src
  mkdir -p "$HOME/.local/share/craft-skills" "$HOME/.local/share/craft-sandbox" "$PREFIX" "$SKILLS/my-own" "$SKILLS/craft-apps" "$SKILLS/craft-pdfcraft"
  printf '#!/usr/bin/env python3\n# craft-shell-guard (hand-made): ask before a Craft app runs from Bash\nimport json\nprint(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}))\n' > "$legacy_hook"
  printf ';; craft.sb: sandbox profile for the Craft apps (hand-made setup)\n(version 1)\n(allow default)\n(deny file-write* (require-not (subpath (param "ROOT"))))\n' > "$legacy_profile"
  cp "$legacy_hook" "$STATE/legacy-hook.orig"
  cp "$legacy_profile" "$STATE/legacy-profile.orig"
  cat > "$PREFIX/craft-sandbox" << 'WRAPPER'
#!/bin/bash
# craft-sandbox ROOT PROGRAM [ARGS...]: run PROGRAM in a macOS sandbox limited to ROOT (hand-made setup)
set -euo pipefail
ROOT=$1
shift
exec /usr/bin/sandbox-exec -f "$HOME/.local/share/craft-sandbox/craft.sb" -D "ROOT=$ROOT" -D "HOME=$HOME" "$@"
WRAPPER
  chmod 755 "$PREFIX/craft-sandbox"
  seed_json "$SETTINGS" "$(jq -n --arg h "python3 $legacy_hook" '{model: "opus", hooks: {PreToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $h}]},
      {matcher: "Bash", hooks: [{type: "command", command: "/usr/bin/true"}]}]}}')"
  cp "$SETTINGS" "$STATE/legacy-settings.orig"
  seed_reg wordcraft "$(expected_reg wordcraft)"
  seed_reg filmcraft "$(expected_reg filmcraft)"
  seed_reg gridcraft "{\"command\":\"$PREFIX/craft-sandbox\",\"args\":[\"$HOME/old-ws/gridcraft\",\"$PREFIX/gridcraft-cli\",\"mcp\"]}"
  make_stub_cli wordcraft 0.6.0
  make_stub_cli gridcraft "$(lock_val gridcraft version)"
  make_stub_cli filmcraft "$(lock_val filmcraft version)"
  echo "LEGACY CONTENT" > "$SKILLS/craft-apps/SKILL.md"
  render_skill "$REPO/skills/craft-pdfcraft/SKILL.md" > "$SKILLS/craft-pdfcraft/SKILL.md"
  echo mine > "$SKILLS/my-own/SKILL.md"
  backdate "$SKILLS/craft-pdfcraft/SKILL.md" "$PREFIX/gridcraft-cli" "$PREFIX/filmcraft-cli"
  local pdf_m0 grid_m0 film_m0 own0
  pdf_m0=$(stat -f %m "$SKILLS/craft-pdfcraft/SKILL.md")
  grid_m0=$(stat -f %m "$PREFIX/gridcraft-cli")
  film_m0=$(stat -f %m "$PREFIX/filmcraft-cli")
  own0=$(tree_hash "$SKILLS/my-own")
  c0=$(log_lines)
  inst_y
  a_rc "migrating from the legacy hand-made setup exits 0" 0
  a_out "the output says it found an older hand-made setup and replaced it (wording inferred)" 'legacy|migrat|older|hand-made|previous'
  a_out "the plan says CLIs the kit did not install are replaced by the verified download" 'replace\*'
  a_eq "wordcraft-cli was replaced by the locked version" "wordcraft-cli $(lock_val wordcraft version)" "$("$PREFIX/wordcraft-cli" --version)"
  a_false "gridcraft-cli and filmcraft-cli (same version, not verified by the kit) were replaced too (R1-SUPPLY-4)" \
    sh -c 'grep -q "stub" "$1" || grep -q "stub" "$2"' _ "$PREFIX/gridcraft-cli" "$PREFIX/filmcraft-cli"
  check_registrations "$APPS"
  a_eq "identical legacy registrations were kept: no add or remove for wordcraft and filmcraft" 0 \
    "$(($(count_calls "$c0" add wordcraft) + $(count_calls "$c0" remove wordcraft) + $(count_calls "$c0" add filmcraft) + $(count_calls "$c0" remove filmcraft)))"
  a_eq "the differing legacy registration of gridcraft was replaced: one remove, one add" "1 1" "$(count_calls "$c0" remove gridcraft) $(count_calls "$c0" add gridcraft)"
  a_eq "no duplicate registrations: exactly the 13 apps, nothing in local scope" "13 0" \
    "$(jq '.mcpServers | length' "$CLAUDE_JSON") $(jq '[.projects[]?.mcpServers[]?] | length' "$CLAUDE_JSON")"
  a_eq "the legacy hook entry was removed from settings.json" 0 "$(jq -r '[.. | strings | select(contains("craft-skills"))] | length' "$SETTINGS")"
  a_jq "the user's own Bash hook and the model setting are kept" "$SETTINGS" '.model == "opus" and ([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == "/usr/bin/true")] | length == 1)'
  check_hooks
  a_true "settings.json was backed up before the migration" \
    sh -c 'ls "$1"/settings.json.bak-craft-kit-* > /dev/null 2>&1 && cmp -s "$(ls "$1"/settings.json.bak-craft-kit-* | head -n 1)" "$2"' _ "$CLAUDE_DIR" "$STATE/legacy-settings.orig"
  a_false "the recognised legacy hook script is gone from its path" test -e "$legacy_hook"
  a_true "...and was moved aside with its content (.bak-craft-kit-<timestamp>)" \
    sh -c 'cmp -s "$(ls "$1".bak-craft-kit-* | head -n 1)" "$2"' _ "$legacy_hook" "$STATE/legacy-hook.orig"
  a_false "the legacy sandbox profile is gone once its wrapper was replaced" test -e "$legacy_profile"
  a_true "...and was moved aside with its content" \
    sh -c 'cmp -s "$(ls "$1".bak-craft-kit-* | head -n 1)" "$2"' _ "$legacy_profile" "$STATE/legacy-profile.orig"
  check_sandbox_wrapper
  src=$SKILLS/craft-apps
  render_skill "$REPO/skills/craft-apps/SKILL.md" > "$STATE/expected-skill"
  a_true "the legacy craft-apps skill was replaced by the rendered one" cmp -s "$STATE/expected-skill" "$src/SKILL.md"
  a_eq "...after the old one was backed up to SKILL.md.bak-<timestamp>" "LEGACY CONTENT" "$(cat "$(ls "$src"/SKILL.md.bak-* 2> /dev/null | head -n 1)" 2> /dev/null)"
  a_eq "an identical legacy skill is left alone: mtime kept, no backup" "$pdf_m0 0" "$(stat -f %m "$SKILLS/craft-pdfcraft/SKILL.md") $(ls "$SKILLS/craft-pdfcraft"/SKILL.md.bak-* 2> /dev/null | wc -l | tr -d ' ')"
  a_eq "the user's own skill is untouched" "$own0" "$(tree_hash "$SKILLS/my-own")"
  check_skills_rendered
  check_receipt "$APPS"
  inst_y
  a_rc "a second run after the migration exits 0" 0
  a_eq "...and leaves exactly one hook of each kind" "1 1" \
    "$(list_hooks | grep -c 'craft-shell-guard.py') $(list_hooks | grep -c 'craft-mcp-guard.py')"
  end_case

  begin_case legacy-unrelated-files-kept
  new_world
  legacy_hook=$HOME/.local/share/craft-skills/craft-shell-guard.py
  legacy_profile=$HOME/.local/share/craft-sandbox/craft.sb
  mkdir -p "$HOME/.local/share/craft-skills" "$HOME/.local/share/craft-sandbox"
  printf 'my own notes about craft beer recipes\n' > "$legacy_hook"
  printf '(version 1)\n;; something else entirely\n' > "$legacy_profile"
  local h1 h2
  h1=$(file_hash "$legacy_hook"); h2=$(file_hash "$legacy_profile")
  inst_y --only wordcraft
  a_rc "install with unrelated files at the legacy paths exits 0" 0
  a_eq "an unrelated file at the legacy hook path is kept as it was (R1-SUPPLY-3)" "$h1" "$(file_hash "$legacy_hook")"
  a_eq "an unrelated file at the legacy profile path is kept as it was" "$h2" "$(file_hash "$legacy_profile")"
  a_out "...and the installer says it kept them" 'kept .*craft-shell-guard\.py|kept .*craft\.sb'
  end_case

  begin_case legacy-hook-lookalike-kept
  new_world
  legacy_hook=$HOME/.local/share/craft-skills/craft-shell-guard.py
  mkdir -p "$HOME/.local/share/craft-skills"
  printf '#!/usr/bin/env python3\n# my own PreToolUse hook: log every Craft command\nimport json, sys\nprint(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}))\n' > "$legacy_hook"
  h1=$(file_hash "$legacy_hook")
  inst_y --only wordcraft
  a_rc "install with the user's own hook at the legacy path exits 0" 0
  a_eq "a hook that mentions Craft and PreToolUse but is not the older guard is kept (B1-SUPPLY-1)" "$h1" "$(file_hash "$legacy_hook")"
  end_case
}

t_bad_settings() {
  begin_case bad-settings-json
  new_world
  mkdir -p "$CLAUDE_DIR"
  printf '{"permissions": {"allow": ["Bash(ls)"],},}\n' > "$SETTINGS"
  local sh0 c0
  sh0=$(file_hash "$SETTINGS")
  c0=$(log_lines)
  inst_y
  a_rc "an unparseable settings.json makes the run exit 1 (the hook step failed)" 1
  a_eq "settings.json is left exactly as it was" "$sh0" "$(file_hash "$SETTINGS")"
  # shellcheck disable=SC2010
  a_eq "no backup or temp file was left next to it" 0 "$(ls "$CLAUDE_DIR" | grep -c 'settings.json.')"
  a_out "the output explains the settings.json problem" 'settings\.json'
  a_out "...and that it is not valid JSON" 'json|pars|invalid|syntax'
  check_clis "$APPS"
  check_registrations "$APPS"
  check_register_calls "$c0" "$APPS"
  check_workspaces "$APPS"
  check_skills
  a_jq "the receipt was written and records no hooks" "$KIT/receipt.json" '.schema == 1 and (.hooks | length == 0)'
  printf '{"permissions": {"allow": ["Bash(ls)"]}}\n' > "$SETTINGS"
  inst_y
  a_rc "after fixing settings.json, a re-run exits 0" 0
  check_hooks
  end_case

  begin_case bad-settings-json-no-hook
  new_world
  mkdir -p "$CLAUDE_DIR"
  printf '{"permissions": {"allow": ["Bash(ls)"],},}\n' > "$SETTINGS"
  sh0=$(file_hash "$SETTINGS")
  inst_y --no-hook
  a_rc "with --no-hook an unparseable settings.json is not in the way: exit 0" 0
  a_eq "settings.json is left exactly as it was" "$sh0" "$(file_hash "$SETTINGS")"
  check_clis "$APPS"
  check_registrations "$APPS"
  check_skills
  end_case
}

t_spaces() {
  begin_case home-with-spaces
  new_world "my home dir"
  local c0
  c0=$(log_lines)
  inst_y
  a_rc "a HOME containing spaces: install exits 0" 0
  a_true "HOME really contains spaces" sh -c 'case "$1" in *" "*) exit 0 ;; *) exit 1 ;; esac' _ "$HOME"
  check_clis "$APPS"
  check_registrations "$APPS"
  check_register_calls "$c0" "$APPS"
  check_workspaces "$APPS"
  check_skills
  check_hooks loose
  check_receipt "$APPS"
  check_runtime_copy
  a_true "no temp files left behind" tmp_empty
  uninst_y
  a_rc "uninstall exits 0" 0
  check_unregistered "$APPS"
  a_false "KIT_HOME is removed" test -e "$KIT"
  a_eq "no kit hooks remain" 0 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  a_eq "the workspace folders remain" 13 "$(ls -d "$WS"/*/ 2> /dev/null | wc -l | tr -d ' ')"
  end_case
}

t_custom_paths() {
  begin_case custom-paths
  new_world
  unset CRAFT_KIT_OFFLINE_DIR
  PREFIX=$HOME/bin2
  WS=$HOME/ws2
  GUI_DIR=$HOME/Apps2
  local c0
  c0=$(log_lines)
  inst --yes --no-gui --only wordcraft,filmcraft --workspace "$WS" --prefix "$PREFIX" --gui-dir "$GUI_DIR" --offline-dir "$DEF_OFF"
  a_rc "--workspace, --prefix and --offline-dir (no env var) work: exit 0" 0
  check_clis "wordcraft filmcraft"
  check_prefix_listing "wordcraft filmcraft"
  check_registrations "wordcraft filmcraft"
  check_register_calls "$c0" "wordcraft filmcraft"
  check_workspaces "wordcraft filmcraft"
  check_hooks
  a_false "the default prefix was not used" test -e "$HOME/.local/bin"
  a_false "the default workspace was not used" test -e "$HOME/craft-workspace"
  a_jq "receipt records the custom workspace, prefix and gui dir" "$KIT/receipt.json" '.workspace == $w and .prefix == $p and .guiDir == $g' --arg w "$WS" --arg p "$PREFIX" --arg g "$GUI_DIR"
  uninst_y
  a_rc "uninstall reads the custom locations from the receipt and exits 0" 0
  # shellcheck disable=SC2010
  a_eq "the custom prefix holds no CLI any more" 0 "$(ls "$PREFIX" 2> /dev/null | grep -cE -- '-cli$|^craft-sandbox$')"
  a_eq "the custom workspace is kept" 2 "$(ls -d "$WS"/*/ 2> /dev/null | wc -l | tr -d ' ')"
  end_case
}

t_settings_symlink() {
  begin_case settings-symlink
  new_world
  mkdir -p "$HOME/dotfiles" "$CLAUDE_DIR"
  seed_json "$HOME/dotfiles/settings.json" '{"model":"opus"}'
  ln -s "$HOME/dotfiles/settings.json" "$SETTINGS"
  inst_y --only wordcraft
  a_rc "install with a symlinked settings.json exits 0" 0
  a_true "settings.json is still a symlink to the same file" sh -c '[ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]' _ "$SETTINGS" "$HOME/dotfiles/settings.json"
  a_jq "the hooks were written through the symlink into the real file; other keys kept" "$HOME/dotfiles/settings.json" \
    '.model == "opus" and ([.hooks.PreToolUse[]? | .hooks[]? | select(.command | contains("craft-shell-guard.py"))] | length == 1)'
  check_hooks
  end_case
}

t_upgrade() {
  begin_case upgrade
  new_world
  make_stub_cli figcraft 0.5.0
  inst_y --only figcraft
  a_rc "replacing an older CLI the kit did not install exits 0" 0
  a_out "the plan says it replaces it (not run, not trusted)" 'replace\*'
  a_noout "...without running it at plan time (B1-SUPPLY-3: no version read from it)" '0\.5\.0 ->'
  check_clis "figcraft"
  check_prefix_listing "figcraft"
  a_true "...and the older program is kept beside it as figcraft-cli.bak-craft-kit-<timestamp>" \
    sh -c 'grep -q "figcraft-cli 0.5.0" "$(ls "$1".bak-craft-kit-* | head -n 1)"' _ "$PREFIX/figcraft-cli"
  check_registrations "figcraft"
  end_case

  begin_case upgrade-kit-installed
  new_world
  derive_fixtures oldfig
  jq '.apps.figcraft.version = "0.5.0"' "$VARIANT_LOCK" > "$VARIANT_LOCK.tmp" && mv "$VARIANT_LOCK.tmp" "$VARIANT_LOCK"
  variant_cli figcraft
  inst_y --only figcraft
  a_rc "setup: the kit installs figcraft 0.5.0 from a variant lock" 0
  export CRAFT_KIT_OFFLINE_DIR=$DEF_OFF CRAFT_KIT_LOCK=$DEF_LOCK
  inst_y --only figcraft
  a_rc "upgrading a CLI the kit installed exits 0" 0
  a_out "the plan says 0.5.0 -> locked version (it read the version of the file it had verified)" "0\.5\.0 -> $(lock_val figcraft version)"
  check_clis "figcraft"
  end_case
}

t_gui() {
  begin_case gui-install
  new_world
  local app bundle bad='' m0
  inst_y --gui --only wordcraft,gridcraft
  a_rc "--gui --only wordcraft,gridcraft exits 0" 0
  for app in wordcraft gridcraft; do
    bundle=$(lock_val "$app" gui.bundle)
    [ -d "$GUI_DIR/$bundle" ] || { bad="${bad}$bundle was not installed into $GUI_DIR$NL"; continue; }
    [ "$(plist_version "$GUI_DIR/$bundle")" = "$(lock_val "$app" version)" ] || bad="${bad}$bundle: CFBundleShortVersionString is '$(plist_version "$GUI_DIR/$bundle")'$NL"
    codesign --verify --deep --strict "$GUI_DIR/$bundle" > /dev/null 2>&1 || bad="${bad}$bundle: codesign --verify --deep --strict fails (the fixture is ad-hoc signed)$NL"
  done
  agg "both .app bundles are installed from the fixture dmgs at the locked version and still verify" "$bad"
  a_eq "only the selected apps' bundles are in the GUI dir (which the installer created if missing, inferred)" "GridCraft.app WordCraft.app" "$(ls "$GUI_DIR" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  a_true "no disk image is left mounted" no_images_mounted
  a_true "no temp files left behind (mount points and copies are cleaned up)" tmp_empty
  a_jq "receipt records the GUI dir and the GUI installs" "$KIT/receipt.json" '.guiDir == $g and (.apps.wordcraft.gui // false) and (.apps.gridcraft.gui // false)' --arg g "$GUI_DIR"
  check_registrations "wordcraft gridcraft"
  end_case

  begin_case gui-skip-if-present
  backdate "$GUI_DIR/WordCraft.app/Contents/Info.plist" "$GUI_DIR/GridCraft.app/Contents/Info.plist"
  m0=$(stat -f '%m' "$GUI_DIR/WordCraft.app/Contents/Info.plist" "$GUI_DIR/GridCraft.app/Contents/Info.plist" | tr '\n' ' ')
  inst_y --gui --only wordcraft,gridcraft
  a_rc "a second --gui run exits 0" 0
  a_eq "bundles already at the locked version are skipped (not copied again)" "$m0" "$(stat -f '%m' "$GUI_DIR/WordCraft.app/Contents/Info.plist" "$GUI_DIR/GridCraft.app/Contents/Info.plist" | tr '\n' ' ')"
  a_out "the second run says the bundles are skipped / up to date (wording inferred)" 'skip|up[- ]to[- ]date|already|unchanged'
  a_true "no disk image is left mounted" no_images_mounted
  end_case

  begin_case gui-other-version
  new_world
  make_fake_app "$GUI_DIR" WordCraft.app 0.1.0
  local h0
  h0=$(tree_hash "$GUI_DIR/WordCraft.app")
  inst_y --gui --only wordcraft
  a_rc "a bundle at another version is left alone with a warning: exit 0 (inferred)" 0
  a_eq "the existing WordCraft.app 0.1.0 is untouched" "$h0" "$(tree_hash "$GUI_DIR/WordCraft.app")"
  a_out "the output warns about WordCraft.app being at another version" 'wordcraft.*(warn|differ|other|older|leav|0\.1\.0|version)|(warn|differ|other|older|leav|0\.1\.0|version).*wordcraft'
  check_clis "wordcraft"
  a_jq "receipt: the kit did not install that GUI app" "$KIT/receipt.json" '((.apps.wordcraft.gui // false) | not)'
  a_true "no disk image is left mounted" no_images_mounted
  end_case
}

t_uninstall_options() {
  begin_case uninstall-keep-cli
  new_world
  inst_y --only wordcraft,pdfcraft,filmcraft
  uninst_y --keep-cli
  a_rc "uninstall.sh --keep-cli exits 0" 0
  check_clis "wordcraft pdfcraft filmcraft"
  check_unregistered "wordcraft pdfcraft filmcraft"
  a_eq "skills are removed" 0 "$(ls -d "$SKILLS"/craft-*/ 2> /dev/null | wc -l | tr -d ' ')"
  a_eq "hooks are removed" 0 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  a_false "KIT_HOME is removed" test -e "$KIT"
  a_eq "the workspace is kept" 3 "$(ls -d "$WS"/*/ 2> /dev/null | wc -l | tr -d ' ')"
  end_case

  begin_case uninstall-keep-skills-and-hooks
  new_world
  inst_y --only wordcraft,pdfcraft,filmcraft
  local sh0 sk0 c dangling
  sh0=$(file_hash "$SETTINGS")
  sk0=$(tree_hash "$SKILLS")
  uninst_y --keep-skills --keep-hooks
  a_rc "uninstall.sh --keep-skills --keep-hooks exits 0" 0
  a_eq "settings.json is untouched" "$sh0" "$(file_hash "$SETTINGS")"
  a_eq "the skills are untouched" "$sk0" "$(tree_hash "$SKILLS")"
  check_unregistered "wordcraft pdfcraft filmcraft"
  # shellcheck disable=SC2010
  a_eq "the CLIs and the wrapper are gone" 0 "$(ls "$PREFIX" 2> /dev/null | grep -cE -- '-cli$|^craft-sandbox$')"
  dangling=''
  for c in $(list_hooks | cut -f2 | tr ' ' '\n' | grep 'craft-.*-guard.py$'); do
    [ -f "$c" ] || dangling="${dangling}$c$NL"
  done
  agg "hooks that were kept still point at hook scripts that exist (KIT_HOME may be kept for that)" "$dangling"
  a_eq "both kept hooks are still registered" 2 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  end_case

  begin_case uninstall-gui-default-keeps-apps
  new_world
  make_fake_app "$GUI_DIR" PdfCraft.app 0.1.0
  inst_y --gui --only wordcraft,pdfcraft
  a_true "setup: WordCraft.app was installed by the kit" test -d "$GUI_DIR/WordCraft.app"
  uninst_y
  a_rc "uninstall.sh without --remove-gui exits 0" 0
  a_true "WordCraft.app is kept without --remove-gui" test -d "$GUI_DIR/WordCraft.app"
  a_true "the user's own PdfCraft.app is kept" test -d "$GUI_DIR/PdfCraft.app"
  end_case

  begin_case uninstall-remove-gui
  new_world
  make_fake_app "$GUI_DIR" PdfCraft.app 0.1.0
  inst_y --gui --only wordcraft,pdfcraft
  uninst_y --remove-gui
  a_rc "uninstall.sh --remove-gui exits 0" 0
  a_false "WordCraft.app (installed by the kit) is removed" test -e "$GUI_DIR/WordCraft.app"
  a_true "PdfCraft.app (not installed by the kit: another version was already there) is kept" test -d "$GUI_DIR/PdfCraft.app"
  a_true "the GUI dir itself is kept" test -d "$GUI_DIR"
  end_case
}

t_tty() {
  begin_case tty-decline
  new_world
  local h0
  h0=$(tree_hash "$HOME")
  run python3 -I "$FIX/pty_drive.py" --answer n -- "$BASH_UT" "$INSTALL" --only wordcraft --no-gui --gui-dir "$GUI_DIR"
  a_rc "on a terminal, answering no at the prompt exits 4" 4
  a_eq "...and changes nothing" "$h0" "$(tree_hash "$HOME")"
  end_case

  begin_case tty-accept
  new_world
  run python3 -I "$FIX/pty_drive.py" --answer y -- "$BASH_UT" "$INSTALL" --only wordcraft --no-gui --gui-dir "$GUI_DIR"
  a_rc "on a terminal, answering yes at the prompt installs and exits 0" 0
  check_clis "wordcraft"
  check_registrations "wordcraft"
  end_case

  begin_case tty-gui-question
  new_world
  run python3 -I "$FIX/pty_drive.py" --answer y -- "$BASH_UT" "$INSTALL" --only wordcraft --gui-dir "$GUI_DIR"
  a_rc "on a terminal without --gui/--no-gui, answering yes exits 0" 0
  a_out "...and the plan or prompt offers the desktop apps (mentions desktop/GUI)" 'desktop|gui'
  check_clis "wordcraft"
  a_true "no disk image is left mounted" no_images_mounted
  new_world
  run python3 -I "$FIX/pty_drive.py" --answer n -- "$BASH_UT" "$INSTALL" --only wordcraft --gui-dir "$GUI_DIR"
  a_rc "on a terminal, answering no to the prompt exits 4" 4
  a_false "...and installs nothing" test -e "$PREFIX/wordcraft-cli"
  end_case
}

REAL_HOME_SNAP=''
real_home_snapshot() {
  local rh d
  rh=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{print $2}')
  [ -n "$rh" ] || return 0
  for d in "$rh/.local/share/craft-claude-kit" "$rh/craft-workspace" "$rh/.local/bin/craft-sandbox" "$rh/Applications"; do
    if [ -e "$d" ]; then printf '%s %s\n' "$d" "$(stat -f '%m' "$d")"; else printf '%s absent\n' "$d"; fi
  done
}
t_rerun() {
  begin_case rerun-keeps-settings
  new_world
  seed_json "$SETTINGS" '{"model":"opus"}'
  WS=$HOME/ws1
  inst_y --only wordcraft,pdfcraft --workspace "$WS"
  a_rc "setup: --only wordcraft,pdfcraft --workspace ~/ws1 exits 0" 0
  a_eq "one settings.json backup for the whole run" 1 "$(settings_backups)"
  inst_y
  a_rc "a plain re-run (the README update command) exits 0" 0
  a_out "the plan says it reuses the previous settings" 'same settings as your previous install'
  a_jq "the re-run kept the workspace and the two apps" "$KIT/receipt.json" '.workspace == $w and (.apps | keys) == ["pdfcraft", "wordcraft"]' --arg w "$WS"
  a_eq "still only the two apps are registered" '["pdfcraft","wordcraft"]' "$(jq -c '.mcpServers | keys' "$CLAUDE_JSON")"
  a_false "the default workspace was not created" test -e "$HOME/craft-workspace"
  check_hooks
  inst_y --only all
  a_rc "--only all exits 0" 0
  a_eq "--only all registers all 13 apps" 13 "$(jq '.mcpServers | length' "$CLAUDE_JSON")"
  a_jq "--only all still uses the previous workspace" "$KIT/receipt.json" '.workspace == $w' --arg w "$WS"
  end_case
}

t_kit_deleted() {
  begin_case kit-deleted-by-hand
  new_world
  inst_y --only wordcraft,gridcraft
  a_rc "setup: install exits 0" 0
  rm -rf "$KIT"
  local cmd rc=0
  cmd=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command | select(contains("craft-shell-guard"))][0]' "$SETTINGS")
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /bin/sh -c "$cmd" > /dev/null 2>&1 || rc=$?
  a_eq "a hook whose script is gone exits 0 (never 2, which would block every call)" 0 "$rc"
  uninst --dry-run
  a_rc "uninstall.sh from the clone, kit folder gone, --dry-run exits 0" 0
  a_out "it lists what the deleted kit left behind" 'cleanup without a receipt'
  uninst --yes
  a_rc "uninstall.sh from the clone exits 1 while a Craft registration it may not own is left (R1-CLEAN-1)" 1
  a_eq "no kit hooks remain" 0 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  a_eq "the registration through the kit's wrapper (gridcraft) is removed" "" "$(actual_reg gridcraft)"
  a_true "the wordcraft-cli registration (maybe the user's) is kept (R1-CONFIG-4)" test -n "$(actual_reg wordcraft)"
  a_outf "...and listed with the command that removes it" "mcp remove wordcraft -s user"
  a_noout "no success line while a Craft registration remains" 'stops loading the removed servers'
  a_false "craft-sandbox is removed" test -e "$PREFIX/craft-sandbox"
  a_true "the skills are kept (no receipt to prove they are the kit's)" test -f "$SKILLS/craft-apps/SKILL.md"
  run "$CLAUDE_BIN" mcp remove wordcraft -s user
  uninst --dry-run
  a_out "once the user removed it, a second run finds nothing" 'nothing to uninstall'
  end_case

  begin_case kit-deleted-custom-prefix
  new_world
  inst_y --no-hook --only wordcraft,cadcraft --prefix "$HOME/bin tools"
  a_rc "setup: install --no-hook --prefix with a space exits 0" 0
  rm -rf "$KIT"
  uninst --yes
  a_noout "the prefix is taken from the registrations, not assumed (R1-CLEAN-1, B1-CLEAN-1)" 'nothing to uninstall'
  a_eq "the registration through the kit's wrapper in the custom prefix is removed" "" "$(actual_reg cadcraft)"
  a_false "the kit's craft-sandbox in the custom prefix is removed" test -e "$HOME/bin tools/craft-sandbox"
  a_outf "the wordcraft registration is listed with its remove command" "mcp remove wordcraft -s user"
  a_rc "...and the run exits 1 because it is still registered" 1
  a_noout "no success line" 'stops loading the removed servers'
  end_case
}

t_bad_lock() {
  begin_case bad-lock-fields
  new_world
  derive_fixtures badlock
  local marker=$HOME/MARKER label filter base=$VARIANT_LOCK.base
  cp "$VARIANT_LOCK" "$base"
  for label in gui-size-substitution cli-size-float gui-bundle-dotdot gui-url-off-github extra-args-unknown; do
    case $label in
      gui-size-substitution) filter='.apps.wordcraft.gui.size = "dl_gui[$(touch '"$marker"')]"' ;;
      cli-size-float) filter='.apps.wordcraft.cli.size = 1.5' ;;
      gui-bundle-dotdot) filter='.apps.wordcraft.gui.bundle = "../x.app"' ;;
      gui-url-off-github) filter='.apps.wordcraft.gui.url = "https://example.com/x.dmg"' ;;
      extra-args-unknown) filter='.apps.gridcraft.extraArgs = ["--debug"]' ;;
    esac
    jq "$filter" "$base" > "$VARIANT_LOCK"
    inst --dry-run --no-gui --only wordcraft
    a_rc "$label: --dry-run stops at preflight with exit 3 (R1-SUPPLY-1)" 3
    a_out "$label: it names the lock error" 'lock file .* has errors'
    a_noout "$label: no plan is printed" 'install plan'
    a_false "$label: no command from the lock ran (no marker file)" test -e "$marker"
  done
  end_case
}

t_fence_override() {
  begin_case fence-override
  new_world
  derive_fixtures fenceoverride
  local c0 extra
  for extra in '["--automation-write-root","/"]' '["--automation-write-root=/"]' '["--root=/x"]'; do
    jq --argjson x "$extra" '.apps.photocraft.extraArgs = $x' "$DEF_LOCK" > "$VARIANT_LOCK"
    c0=$(log_lines)
    inst_y --only photocraft
    a_false "extraArgs $extra: the install does not succeed (R1-SUPPLY-2)" test "$RC" = 0
    a_eq "extraArgs $extra: no claude mcp add for photocraft" 0 "$(count_calls "$c0" add photocraft)"
  done
  end_case
}

t_planted_cli() {
  begin_case planted-cli
  new_world
  make_stub_cli wordcraft "$(lock_val wordcraft version)"
  inst_y --only wordcraft
  a_rc "a planted wordcraft-cli at the locked version: install exits 0" 0
  a_out "the plan marks it for replacement (R1-SUPPLY-4)" 'wordcraft +replace\*'
  a_false "the planted file was replaced by the verified program" grep -q stub "$PREFIX/wordcraft-cli"
  a_true "...and its bytes were kept as wordcraft-cli.bak-craft-kit-<timestamp> (B1-SUPPLY-2, R1-CONFIG-1)" \
    sh -c 'grep -q stub "$(ls "$1".bak-craft-kit-* | head -n 1)"' _ "$PREFIX/wordcraft-cli"
  a_out "...and the output names the backup" 'kept as .*wordcraft-cli\.bak-craft-kit-'
  a_jq "receipt: cli=true and the SHA-256 of the installed file" "$KIT/receipt.json" \
    '.apps.wordcraft.cli == true and .apps.wordcraft.cliSha256 == $s' --arg s "$(file_hash "$PREFIX/wordcraft-cli")"
  inst_y --only wordcraft
  a_out "a re-run keeps the verified file (up to date)" 'wordcraft +up to date'
  a_jq "receipt still says the kit installed it (R1-CONFIG-1)" "$KIT/receipt.json" '.apps.wordcraft.cli == true'
  make_stub_cli wordcraft "$(lock_val wordcraft version)"
  uninst_y --dry-run
  a_out "uninstall keeps a CLI replaced since install (B1-CONFIG-2)" 'replaced since install.*wordcraft-cli'
  uninst_y
  a_true "...and does not delete it" grep -q stub "$PREFIX/wordcraft-cli"
  a_true "...and the backup made at install survives uninstall" sh -c 'ls "$1".bak-craft-kit-* > /dev/null 2>&1' _ "$PREFIX/wordcraft-cli"
  end_case

  begin_case planted-cli-other-version
  new_world
  make_stub_cli gridcraft 0.0.1
  cp "$PREFIX/gridcraft-cli" "$STATE/grid-orig"
  inst_y --only gridcraft
  a_rc "a hand-made gridcraft-cli of another version: install exits 0" 0
  a_true "it was backed up before the replacement (R1-CONFIG-1)" \
    sh -c 'cmp -s "$(ls "$1".bak-craft-kit-* | head -n 1)" "$2"' _ "$PREFIX/gridcraft-cli" "$STATE/grid-orig"
  uninst_y
  a_true "uninstall removes the kit's program but keeps the backup of the user's file" \
    sh -c '[ ! -e "$1" ] && cmp -s "$(ls "$1".bak-craft-kit-* | head -n 1)" "$2"' _ "$PREFIX/gridcraft-cli" "$STATE/grid-orig"
  end_case
}

t_restore_registration() {
  begin_case restore-registration
  new_world
  local old c0
  old="{\"command\":\"$PREFIX/wordcraft-cli\",\"args\":[\"mcp\",\"--root\",\"$HOME/elsewhere\"]}"
  seed_reg wordcraft "$old"
  export FAKE_CLAUDE_FAIL_ADD_ARG="$WS/"
  inst_y --only wordcraft
  unset FAKE_CLAUDE_FAIL_ADD_ARG
  a_rc "a failing claude mcp add makes the run exit 1" 1
  a_eq "the user's previous registration is put back (R1-CLEAN-3)" "$(printf '%s' "$old" | jq -cS .)" "$(actual_reg wordcraft)"
  a_out "...and the output says so" 'restored your previous registration'
  a_jq "the previous registration was saved under the kit folder before it was replaced (R1-CLEAN-3)" \
    "$(ls "$KIT"/backup/wordcraft-mcp-*.json 2> /dev/null | head -n 1)" '.args == ["mcp", "--root", $h]' --arg h "$HOME/elsewhere"
  end_case

  begin_case restore-registration-double-failure
  new_world
  old="{\"command\":\"$PREFIX/wordcraft-cli\",\"args\":[\"mcp\",\"--root\",\"$HOME/elsewhere\"]}"
  seed_reg wordcraft "$old"
  export FAKE_CLAUDE_FAIL_ADD=wordcraft
  inst_y --only wordcraft
  unset FAKE_CLAUDE_FAIL_ADD
  a_rc "the new add and the restore both fail: exit 1" 1
  local bak
  bak=$(ls "$KIT"/backup/wordcraft-mcp-*.json 2> /dev/null | head -n 1)
  a_jq "the old registration, env included, is in KIT_HOME/backup (R1-CLEAN-3)" "$bak" \
    '.command == $c and .args == ["mcp", "--root", $h] and (.env | type) == "object"' --arg c "$PREFIX/wordcraft-cli" --arg h "$HOME/elsewhere"
  a_true "...readable only by the user (mode 600)" sh -c '[ "$(stat -f %Lp "$1")" = 600 ]' _ "$bak"
  a_outf "...and the failure names that file" "$bak"
  end_case
}

t_python_stub() {
  begin_case python-stub
  new_world
  local d=$STATE/py-stub
  mkdir -p "$d"
  printf '#!/bin/sh\necho "xcode-select: note: No developer tools were found, requesting install." >&2\nexit 1\n' > "$d/python3"
  chmod 755 "$d/python3"
  PATH="$d:$DEF_PATH" inst --dry-run
  a_rc "a python3 that does not run stops preflight with exit 3" 3
  a_out "it says python3 does not run, not that it is old (R1-CLEAN-6)" 'python3 does not run'
  a_out "...and gives the Command Line Tools fix" 'xcode-select --install'
  a_noout "...not the 'older than 3.9' message" 'older than 3\.9'
  end_case
}

t_kit_home_guard() {
  begin_case kit-home-guard
  new_world
  mkdir -p "$HOME/tools/lib" "$HOME/tools/data"
  echo mine > "$HOME/tools/lib/my_helper.py"
  echo 1,2 > "$HOME/tools/data/report.csv"
  local h0
  h0=$(tree_hash "$HOME/tools")
  CRAFT_KIT_HOME=$HOME/tools inst_y --only wordcraft
  a_rc "a non-empty CRAFT_KIT_HOME the kit did not make is refused at preflight (R1-CONFIG-2)" 3
  a_out "...with the reason" 'not empty and was not made by craft-claude-kit'
  a_eq "...and the user's files are untouched" "$h0" "$(tree_hash "$HOME/tools")"
  CRAFT_KIT_HOME=$HOME/.local inst_y --only wordcraft --prefix "$HOME/.local/bin"
  a_rc "CRAFT_KIT_HOME=~/.local with the prefix inside it is a usage error (B1-CONFIG-1)" 2
  CRAFT_KIT_HOME=$CLAUDE_DIR inst_y --only wordcraft
  a_rc "CRAFT_KIT_HOME equal to the Claude Code folder is a usage error (B1-CONFIG-3)" 2
  a_false "nothing was installed" test -e "$PREFIX/wordcraft-cli"
  end_case
}

t_symlinked_local() {
  begin_case symlinked-local
  new_world
  mkdir -p "$HOME/dotfiles-local"
  ln -s "$HOME/dotfiles-local" "$HOME/.local"
  inst_y --only wordcraft,gridcraft
  a_rc "install with ~/.local a symlink exits 0" 0
  uninst_kit --dry-run
  a_rc "the runtime copy's uninstall accepts the receipt through the symlink (R1-CLEAN-2)" 0
  a_out "...and lists the hook entries" 'hook entries in'
  uninst_y
  a_rc "...and removes everything" 0
  a_eq "no kit hooks remain" 0 "$(list_hooks | grep -c 'craft-.*-guard.py')"
  end_case
}

t_env_override() {
  begin_case env-override
  new_world
  inst_y --only filmcraft
  a_rc "setup: install filmcraft" 0
  jq '.mcpServers.filmcraft.env = {"CRAFT_SANDBOX_PROFILE": "/private/tmp/permissive.sb"}' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
  local c0
  c0=$(log_lines)
  inst_y --only filmcraft
  a_rc "a re-run exits 0" 0
  a_eq "the registration with an env override is replaced: one remove, one add (R1-CONFIG-3)" "1 1" \
    "$(count_calls "$c0" remove filmcraft) $(count_calls "$c0" add filmcraft)"
  a_jq "...and has no env afterwards" "$CLAUDE_JSON" '(.mcpServers.filmcraft.env // {}) == {}'
  end_case
}

t_gui_replaced() {
  begin_case gui-replaced
  new_world
  inst_y --gui --only wordcraft
  a_rc "setup: --gui --only wordcraft" 0
  a_jq "receipt records the installed desktop-app version" "$KIT/receipt.json" '.apps.wordcraft.gui == true and .apps.wordcraft.guiVersion == $v' --arg v "$(lock_val wordcraft version)"
  rm -rf "$GUI_DIR/WordCraft.app"
  make_fake_app "$GUI_DIR" WordCraft.app 9.9.9
  inst_y --gui --only wordcraft
  a_jq "after the user replaced it, the receipt no longer claims it (R1-CONFIG-6)" "$KIT/receipt.json" '(.apps.wordcraft.gui // false) | not'
  uninst_y --remove-gui
  a_true "uninstall --remove-gui leaves the user's 9.9.9 bundle in place" test -d "$GUI_DIR/WordCraft.app"
  end_case
}

t_legacy_profile_notice() {
  begin_case legacy-profile-notice
  new_world
  mkdir -p "$HOME/.local/share/craft-sandbox" "$HOME/elsewhere" "$WS/gridcraft"
  printf '(version 1)\n(allow default)\n' > "$HOME/.local/share/craft-sandbox/craft.sb"
  cp "$REPO/bin/craft-sandbox" "$HOME/elsewhere/craft-sandbox"
  CRAFT_KIT_HOME=$HOME/no-kit-here run /bin/bash "$HOME/elsewhere/craft-sandbox" "$WS/gridcraft" /usr/bin/true
  a_rc "the wrapper still runs with only the older profile" 0
  a_out "...and says on stderr that it uses the older profile (R1-FENCE-5)" 'kit profile not found, using the older profile'
  end_case
}

t_plan_width() {
  begin_case plan-width
  new_world
  COLUMNS=80 inst --dry-run
  local wide
  wide=$(grep -E '^  (APP|[a-z]+craft) ' "$OUTF" | awk 'length($0) > 80')
  agg "the plan table fits 80 columns (R1-UX-5)" "$wide"
  inst_y --only wordcraft,pdfcraft
  a_out "a first --only run says later plain re-runs keep that set (B1-UX-3)" 'later plain re-runs keep every app installed so far'
  derive_fixtures widthfail
  printf 'corruption' >> "$VARIANT_DIR/$(fixture_zip_for gridcraft)"
  inst_y --only gridcraft
  a_out "a failed non-interactive run suggests the re-run with --yes (R1-UX-4)" 'install\.sh --yes again'
  end_case
}

t_kit_extra_file() {
  begin_case kit-extra-file
  new_world
  inst_y --only wordcraft
  a_rc "install for the kit-folder case exits 0" 0
  a_jq "the receipt lists the files copied into the kit folder (B1-CONFIG-1)" "$KIT/receipt.json" \
    '(.kitFiles | index("lib/craftkit.py")) != null and (.kitFiles | index("share/craft.sb")) != null'
  echo "my notes" > "$KIT/lib/my_notes.txt"
  uninst_y
  a_rc "uninstall with a user file inside the kit folder exits 0" 0
  a_eq "the user's file inside KIT_HOME/lib survives uninstall" "my notes" "$(cat "$KIT/lib/my_notes.txt" 2> /dev/null)"
  a_false "the kit's own files there are removed" test -e "$KIT/lib/craftkit.py"
  a_out "...and the output lists the kept file" 'did not install:.*|lib/my_notes\.txt'
  a_outf "...naming it" "lib/my_notes.txt"
  end_case
}

t_real_home() {
  begin_case real-home-untouched
  a_eq "the kit's paths in the real home (kit home, workspace, craft-sandbox, ~/Applications) did not change during these tests" "$REAL_HOME_SNAP" "$(real_home_snapshot)"
  end_case
}

# ------------------------------------------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------------------------------------------
run_test() { # NAME
  local name=$1 fn rc cur before after
  fn=t_$(printf '%s' "$name" | tr '-' '_')
  if ! type "$fn" > /dev/null 2>&1; then
    echo "FAIL $name (no such test)"
    echo "FAIL $name" >> "$RESULTS"
    return
  fi
  : > "$STATE/current-case"
  rm -f "$STATE/test-done"
  before=$(wc -l < "$RESULTS" | tr -d ' ')
  (
    "$fn"
    touch "$STATE/test-done"
  )
  rc=$?
  after=$(wc -l < "$RESULTS" | tr -d ' ')
  if [ ! -f "$STATE/test-done" ] || [ "$rc" -ne 0 ]; then
    cur=$(cat "$STATE/current-case" 2> /dev/null)
    [ -n "$cur" ] || cur=$name
    echo "FAIL $cur (the test aborted with exit status $rc before it finished)"
    echo "FAIL $cur" >> "$RESULTS"
  elif [ "$after" = "$before" ]; then
    echo "FAIL $name (the test reported no result)"
    echo "FAIL $name" >> "$RESULTS"
  fi
}

REAL_HOME_SNAP=$(real_home_snapshot)
echo "install.sh/uninstall.sh tests: repo $REPO"
echo "bash for the tests and the installer: $BASH_UT ($("$BASH_UT" -c 'echo $BASH_VERSION'))"
start=$(date +%s)
for name in $TESTS; do
  if [ -n "$ONLY_CASES" ]; then
    case " $ONLY_CASES " in *" $name "*) ;; *) continue ;; esac
  fi
  run_test "$name"
done
passed=$(grep -c '^PASS ' "$RESULTS")
failed=$(grep -c '^FAIL ' "$RESULTS")
printf '\n%d passed, %d failed (%ds)\n' "$passed" "$failed" "$(($(date +%s) - start))"
if [ "$failed" -gt 0 ]; then exit 1; fi
exit 0
