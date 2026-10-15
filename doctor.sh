#!/usr/bin/env bash
# doctor.sh: check that craft-claude-kit is installed and working: the Craft CLIs, their fenced MCP
# registrations (and that the servers start and the sandbox fence holds), the skills and the hooks.
# Changes nothing, except --smoke, which writes only inside <workspace>/<app>/_doctor/ and always
# removes it (see --help for what the live probes do). Heavy lifting: lib/doctor_checks.py.
# Works from the repo checkout and from the runtime copy in $CRAFT_KIT_HOME. bash 3.2 compatible.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: doctor.sh [options]

Checks the Craft apps, their fenced Claude Code MCP registrations, the skills and the hooks.
Every check prints PASS, WARN or FAIL with a one-line fix hint.

Read-only: it changes no settings, registrations or files. It does start each MCP server for a
moment (inside its fence) to list its tools and make one real in-memory call (the first step of
its smoke test, for example a new blank document; nothing is saved), and it runs a few harmless commands through
craft-sandbox that the sandbox must refuse: a write outside the app folder, a read under your
home folder, a network connect, and starting a program through macOS (`open` of a tiny bundle
doctor writes to a temp folder; it only writes a marker file). Probe files are removed afterwards.

By default it checks what the install receipt says the kit installed (the apps from --only, and
not the skills, hooks or registrations left out with --no-skills, --no-hook or --no-mcp).

Options:
  --workspace DIR  workspace to check (default: the install receipt's, else $HOME/craft-workspace)
  --prefix DIR     folder with the <app>-cli binaries and craft-sandbox
                   (default: the install receipt's, else $HOME/.local/bin)
  --app a,b        check only these apps (default: the receipt's apps, else all 13)
  --smoke          also drive each server through tests/smoke/<app>.json; writes only inside
                   <workspace>/<app>/_doctor/, which doctor creates and removes afterwards (also on
                   failure/Ctrl-C); an existing _doctor folder doctor did not create is left alone
  --gui            check the desktop apps even if the install receipt does not list them
  --gui-dir DIR    where the desktop apps are (default: the receipt's, else /Applications
                   and ~/Applications)
  --brief          print only WARN and FAIL lines, and a count of passed checks per section
  --json           print JSON: {"summary":{...},"checks":[{scope,id,status,detail,hint}]}
  -h, --help       show this help
  --version        print the kit version

Exit status: 0 no FAIL (WARN does not fail), 1 at least one FAIL, 2 usage error.
Environment: CRAFT_KIT_HOME, CLAUDE_CONFIG_DIR, CLAUDE_BIN, NO_COLOR;
             test hooks: CRAFT_KIT_LOCK (another lock file), CRAFT_KIT_GUI_DIR (default desktop-app folder),
                         CRAFT_KIT_SMOKE_DIR (another folder of <app>.json smoke steps).
EOF
}

# ---- locate the kit: this script's own folder (repo checkout or the KIT_HOME runtime copy) ----
src=${BASH_SOURCE[0]}
while [ -h "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
KIT_DIR=$(cd -P "$(dirname "$src")" && pwd)
CHECKS=$KIT_DIR/lib/doctor_checks.py
CRAFTKIT=$KIT_DIR/lib/craftkit.py
PROBE=$KIT_DIR/lib/mcp_probe.py
KIT_VERSION=$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)
US=$'\037'

# ---- options ----
OPT_WS='' OPT_PREFIX='' OPT_APPS='' OPT_GUI_DIR='' SMOKE=0 JSON=0 GUI=0 BRIEF=0
die_usage() { printf 'doctor.sh: %s\n' "$1" >&2; printf "Try 'doctor.sh --help'.\n" >&2; exit 2; }
need() { if [ $# -lt 2 ] || [ -z "$2" ]; then die_usage "$1 needs a value"; fi; }
while [ $# -gt 0 ]; do
  case $1 in
    --workspace) need "$@"; OPT_WS=$2; shift 2 ;;
    --workspace=*) OPT_WS=${1#*=}; shift ;;
    --prefix) need "$@"; OPT_PREFIX=$2; shift 2 ;;
    --prefix=*) OPT_PREFIX=${1#*=}; shift ;;
    --app|--apps) need "$@"; OPT_APPS=$2; shift 2 ;;
    --app=*|--apps=*) OPT_APPS=${1#*=}; shift ;;
    --gui-dir) need "$@"; OPT_GUI_DIR=$2; shift 2 ;;
    --gui-dir=*) OPT_GUI_DIR=${1#*=}; shift ;;
    --gui) GUI=1; shift ;;
    --smoke) SMOKE=1; shift ;;
    --json) JSON=1; shift ;;
    --brief) BRIEF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) printf 'craft-claude-kit doctor %s\n' "$KIT_VERSION"; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

if [ "$(id -u)" = 0 ]; then
  printf 'doctor.sh: do not run this with sudo or as root; run it as your normal user.\n' >&2
  exit 2
fi

# ---- python3 is needed for everything below ----
PY=$(command -v python3 2>/dev/null || true)
if [ -z "$PY" ] || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null \
   || [ ! -f "$CHECKS" ]; then
  if [ -z "$PY" ]; then why="python3 not found"; hint="xcode-select --install (installs python3)"
  elif [ ! -f "$CHECKS" ]; then why="kit incomplete: $CHECKS is missing"; hint="re-clone the repo or re-run install.sh"
  else why="python3 3.9 or newer is needed"; hint="xcode-select --install"; fi
  if [ "$JSON" = 1 ]; then
    printf '{"summary":{"pass":0,"warn":0,"fail":1},"checks":[{"scope":"env","id":"python3","status":"FAIL","detail":"%s","hint":"%s"}]}\n' \
      "$(printf '%s' "$why" | sed 's/[\\"]/\\&/g')" "$hint"
  else
    printf 'FAIL  env  python3  %s\n      fix: %s\n' "$why" "$hint"
  fi
  exit 1
fi

# -I: ignore PYTHONPATH and user site-packages; the kit's helpers use the standard library only.
py() { "$PY" -I "$@"; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/craft-doctor.XXXXXX")
chmod 700 "$TMPD"
RESULTS=$TMPD/results
: > "$RESULTS"
SMOKE_DIRS=()
cleanup() {
  local d
  for d in ${SMOKE_DIRS[@]+"${SMOKE_DIRS[@]}"}; do
    [ -L "$d" ] || rm -rf -- "$d"
  done
  rm -rf -- "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

abspath() { py "$CHECKS" abspath "$1"; }

# ---- paths (contract section 3) ----
KIT_HOME=$(abspath "${CRAFT_KIT_HOME:-$HOME/.local/share/craft-claude-kit}")
RECEIPT=$KIT_HOME/receipt.json
LOCK=$(abspath "${CRAFT_KIT_LOCK:-$KIT_DIR/manifest/apps.lock.json}")
SMOKE_DIR=${CRAFT_KIT_SMOKE_DIR:-$KIT_DIR/tests/smoke}
CLAUDE_DIR=$(abspath "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
CLAUDE_BIN=${CLAUDE_BIN:-claude}
CONFIG_ARGS=()
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || CONFIG_ARGS=(--config-dir "$CLAUDE_CONFIG_DIR")

RECEIPT_OK=0
if [ -f "$RECEIPT" ] && py "$CHECKS" json-get "$RECEIPT" schema >/dev/null 2>&1; then RECEIPT_OK=1; fi
receipt_get() {
  [ "$RECEIPT_OK" = 1 ] || return 0
  py "$CHECKS" json-get "$RECEIPT" "$1" 2>/dev/null || true
}
WORKSPACE=${OPT_WS:-$(receipt_get workspace)}
WORKSPACE=$(abspath "${WORKSPACE:-$HOME/craft-workspace}")
PREFIX=${OPT_PREFIX:-$(receipt_get prefix)}
PREFIX=$(abspath "${PREFIX:-$HOME/.local/bin}")
REPO_DIR=$(receipt_get repoDir)
if [ -z "$OPT_GUI_DIR" ] && [ -z "$(receipt_get guiDir)" ] && [ -n "${CRAFT_KIT_GUI_DIR:-}" ]; then OPT_GUI_DIR=$CRAFT_KIT_GUI_DIR; fi
[ -z "$OPT_GUI_DIR" ] || OPT_GUI_DIR=$(abspath "$OPT_GUI_DIR")
# What the install left out on purpose (--no-mcp, --no-skills, --no-hook); older receipts: nothing.
SKIP_MCP=0 SKIP_SKILLS=0 SKIP_HOOKS=0
[ "$(receipt_get components.mcp)" != false ] || SKIP_MCP=1
[ "$(receipt_get components.skills)" != false ] || SKIP_SKILLS=1
[ "$(receipt_get components.hooks)" != false ] || SKIP_HOOKS=1
# The installer is also the repair and migration tool; the runtime copy has none, the receipt knows the clone.
INSTALLER="install.sh (from your clone of craft-claude-kit)"
if [ -f "$KIT_DIR/install.sh" ]; then INSTALLER=$KIT_DIR/install.sh
elif [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/install.sh" ]; then INSTALLER=$REPO_DIR/install.sh; fi
export CRAFT_DOCTOR_INSTALLER="$INSTALLER"
# Without a terminal (Claude Code's Bash tool) the installer needs --yes, or it stops with exit 4 (R1-UX-4).
RERUN_HINT=$INSTALLER
if [ ! -t 0 ]; then
  case "$INSTALLER" in /*) RERUN_HINT="$INSTALLER --yes" ;; *) RERUN_HINT="install.sh --yes (from your clone of craft-claude-kit)" ;; esac
fi
export CRAFT_DOCTOR_RECEIPT_OK="$RECEIPT_OK"

# ---- apps (from the lock) ----
ALL_APPS=''
LOCK_ERR=''
if [ -f "$CRAFTKIT" ]; then
  ALL_APPS=$(py "$CRAFTKIT" apps --lock "$LOCK" 2>"$TMPD/lock.err" | tr '\n' ' ') || ALL_APPS=''
  [ -n "$ALL_APPS" ] || LOCK_ERR=$(tr '\n' ' ' < "$TMPD/lock.err")
else
  LOCK_ERR="$CRAFTKIT is missing"
fi
APPS=$ALL_APPS
NOT_INSTALLED=''
if [ -z "$OPT_APPS" ] && [ -n "$ALL_APPS" ] && [ "$RECEIPT_OK" = 1 ]; then
  # Only the apps the receipt lists (install.sh --only installs a subset on purpose).
  rapps=$(receipt_get apps)
  if [ -n "$rapps" ] && [ "$rapps" != '{}' ]; then
    APPS=''
    for a in $ALL_APPS; do
      case $rapps in *"\"$a\": "*) APPS="$APPS $a" ;; *) NOT_INSTALLED="$NOT_INSTALLED $a" ;; esac
    done
    [ -n "$APPS" ] || { APPS=$ALL_APPS; NOT_INSTALLED=''; }
  fi
fi
if [ -n "$OPT_APPS" ]; then
  APPS=''
  for a in $(printf '%s' "$OPT_APPS" | tr ',' ' '); do
    if [ -n "$ALL_APPS" ]; then
      case " $ALL_APPS " in *" $a "*) ;; *) die_usage "unknown app: $a (known: $(printf '%s' "$ALL_APPS" | xargs))" ;; esac
    fi
    case " $APPS " in *" $a "*) ;; *) APPS="$APPS $a" ;; esac
  done
fi
APPS_CSV=$(printf '%s' "$APPS" | xargs | tr ' ' ',')
ALL_APPS_CSV=$(printf '%s' "$ALL_APPS" | xargs | tr ' ' ',')

# ---- output ----
if [ "$JSON" = 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_B=$'\033[1m' C_D=$'\033[2m' C_0=$'\033[0m'
else
  C_G='' C_Y='' C_R='' C_B='' C_D='' C_0=''
fi
LAST_SCOPE='' SCOPE_PASS=0 SCOPE_BUF=''
TILDE='~'
tilde() { # shorten $HOME to ~ for reading (JSON keeps full paths; hints keep them too, so they paste)
  if [ "${#HOME}" -gt 1 ]; then printf '%s' "${1//"$HOME"/$TILDE}"; else printf '%s' "$1"; fi
}
flush_scope() { # --brief: one line per section with its pass count, then its WARN/FAIL lines
  [ "$BRIEF" = 1 ] && [ -n "$LAST_SCOPE" ] || return 0
  printf '\n%s%s%s  %s%d passed%s\n' "$C_B" "$LAST_SCOPE" "$C_0" "$C_D" "$SCOPE_PASS" "$C_0"
  printf '%s' "$SCOPE_BUF"
}
emit() { # scope id status detail [hint]
  local scope=$1 id=$2 st=$3 detail=$4 hint=${5:-} c line
  detail=${detail//$'\n'/ }; detail=${detail//$'\t'/ }; detail=${detail//$US/ }
  hint=${hint//$'\n'/ }; hint=${hint//$'\t'/ }; hint=${hint//$US/ }
  [ "$st" != PASS ] || hint=''
  printf '%s\037%s\037%s\037%s\037%s\n' "$scope" "$id" "$st" "$detail" "$hint" >> "$RESULTS"
  [ "$JSON" = 0 ] || return 0
  if [ "$scope" != "$LAST_SCOPE" ]; then
    flush_scope
    [ "$BRIEF" = 1 ] || printf '\n%s%s%s\n' "$C_B" "$scope" "$C_0"
    LAST_SCOPE=$scope SCOPE_PASS=0 SCOPE_BUF=''
  fi
  case $st in PASS) c=$C_G ;; WARN) c=$C_Y ;; *) c=$C_R ;; esac
  detail=$(tilde "$detail")
  line=$(printf '  %s%-4s%s  %-16s %s' "$c" "$st" "$C_0" "$id" "$detail")
  [ -z "$hint" ] || line=$(printf '%s\n  %-4s  %-16s %sfix: %s%s' "$line" '' '' "$C_D" "$hint" "$C_0")
  if [ "$BRIEF" = 0 ]; then printf '%s\n' "$line"
  elif [ "$st" = PASS ]; then SCOPE_PASS=$((SCOPE_PASS + 1))
  else SCOPE_BUF="$SCOPE_BUF$line"$'\n'; fi
}
progress() { if [ "$JSON" = 1 ] && [ -t 2 ]; then printf 'doctor: %s\n' "$1" >&2; fi; }

M_FENCE='' M_CLI=0 M_WS=0 M_FENCE_OK=0 M_WRAPPER='' M_FENCE_WHY='' M_REG_OK=0
set_meta() {
  case $1 in
    reg_ok) M_REG_OK=$2 ;;
    fence) M_FENCE=$2 ;;
    cli_runs) M_CLI=$2 ;;
    ws_ok) M_WS=$2 ;;
    fence_ok) M_FENCE_OK=$2 ;;
    wrapper) M_WRAPPER=$2 ;;
    fence_why) M_FENCE_WHY=$2 ;;
  esac
}
ingest() { # records written by doctor_checks.py
  local s i st d h
  while IFS=$US read -r s i st d h || [ -n "$s" ]; do
    case $s in
      '') ;;
      META) set_meta "$i" "$st" ;;
      *) emit "$s" "$i" "$st" "$d" "$h" ;;
    esac
  done < "$1"
}
helper() { # scope id-on-crash doctor_checks-subcommand [args...]
  local scope=$1 id=$2 rc=0
  shift 2
  py "$CHECKS" "$@" > "$TMPD/rec" 2> "$TMPD/rec.err" < /dev/null || rc=$?
  ingest "$TMPD/rec"
  if [ "$rc" -ne 0 ]; then
    emit "$scope" "$id" FAIL "doctor_checks.py $1 crashed (exit $rc): $(tail -n 2 "$TMPD/rec.err" | tr '\n' ' ')" \
      "this is a bug in the kit; please report it with this output"
  fi
}

# ---- env ----
check_env() {
  local os ver major arch t p hint cpath cver kv rv f profile missing=''
  os=$(uname -s)
  if [ "$os" != Darwin ]; then
    emit env macos FAIL "$os is not supported: the kit needs macOS 13 or newer" "use a Mac (Linux and Windows are not supported)"
  else
    ver=$(sw_vers -productVersion 2>/dev/null || echo 0)
    major=${ver%%.*}
    if [ "$major" -ge 13 ] 2>/dev/null; then emit env macos PASS "macOS $ver"
    else emit env macos FAIL "macOS $ver is older than 13" "update macOS"; fi
  fi
  arch=$(uname -m)
  case $arch in
    arm64|x86_64) emit env arch PASS "$arch" ;;
    *) emit env arch WARN "$arch: the Craft builds are macos-universal (arm64 and x86_64)" "use an arm64 or x86_64 Mac" ;;
  esac
  if [ -x /usr/bin/sandbox-exec ]; then
    emit env sandbox-exec PASS "/usr/bin/sandbox-exec (deprecated by Apple, still works)"
  else
    emit env sandbox-exec FAIL "/usr/bin/sandbox-exec not found: the sandbox fence cannot work" "use macOS 13 or newer"
  fi
  for t in curl unzip shasum jq python3; do
    if p=$(command -v "$t" 2>/dev/null); then
      emit env "tool-$t" PASS "$p"
    else
      case $t in
        jq) hint="brew install jq (macOS 15 and newer ship /usr/bin/jq)" ;;
        python3) hint="xcode-select --install" ;;
        *) hint="$t is part of macOS: make sure /usr/bin is on PATH" ;;
      esac
      emit env "tool-$t" FAIL "$t not found (install.sh needs it)" "$hint"
    fi
  done
  if cpath=$(command -v "$CLAUDE_BIN" 2>/dev/null); then
    cver=$(py "$CHECKS" run-timeout 30 "$cpath" --version < /dev/null 2>/dev/null | head -n 1) || cver=''
    if [ -n "$cver" ]; then emit env claude PASS "$cver ($cpath)"
    else emit env claude WARN "$cpath does not report a version" "reinstall Claude Code"; fi
  else
    emit env claude FAIL "Claude Code CLI not found ($CLAUDE_BIN)" "install Claude Code, or set CLAUDE_BIN to its path"
  fi
  for f in lib/craftkit.py lib/mcp_probe.py bin/craft-sandbox share/craft.sb manifest/apps.lock.json; do
    [ -e "$KIT_DIR/$f" ] || missing="$missing $f"
  done
  if [ -z "$missing" ]; then emit env kit PASS "craft-claude-kit $KIT_VERSION at $KIT_DIR"
  else emit env kit FAIL "kit incomplete at $KIT_DIR, missing:$missing" "re-clone the repo, or re-run install.sh to refresh $KIT_HOME"; fi
  if [ -n "$ALL_APPS" ]; then
    emit env lock PASS "$(printf '%s' "$ALL_APPS" | wc -w | tr -d ' ') apps pinned in $LOCK"
  else
    emit env lock FAIL "cannot read the lock: $LOCK_ERR" "re-clone the repo (manifest/apps.lock.json)"
  fi
  if [ -n "$NOT_INSTALLED" ]; then
    emit env apps PASS "checking the $(printf '%s' "$APPS" | wc -w | tr -d ' ') app(s) the install receipt lists; not installed by the kit:$NOT_INSTALLED (add one with: install.sh --only NAME)"
  fi
  if [ "$RECEIPT_OK" = 1 ]; then
    kv=$(receipt_get kitVersion)
    rv="kit ${kv:-?} installed $(receipt_get installedAt)"
    if [ -n "$kv" ] && [ "$kv" != "$KIT_VERSION" ]; then
      emit env receipt WARN "$rv, but this copy of the kit is $KIT_VERSION" "re-run $RERUN_HINT to update the installation"
    else
      emit env receipt PASS "$rv ($RECEIPT)"
    fi
  elif [ -f "$RECEIPT" ]; then
    emit env receipt WARN "$RECEIPT is not valid JSON" "re-run $RERUN_HINT (it rewrites the receipt)"
  elif [ "$NOT_INSTALLED_YET" = 0 ]; then
    # When nothing is installed, the "nothing installed" FAIL below already says this (B1-UX-2).
    emit env receipt WARN "no install receipt at $RECEIPT (not installed yet, or installed with another CRAFT_KIT_HOME)" "run $RERUN_HINT"
  fi
  # Claude Code reads skills, hooks and MCP servers from one config dir; it must be the installed one.
  f=$(receipt_get claudeDir)
  if [ -n "$f" ] && [ "$f" != "$CLAUDE_DIR" ]; then
    emit env claude-config WARN "the kit was installed into the Claude config $f, but this shell uses $CLAUDE_DIR" \
      "start Claude Code (and doctor) with CLAUDE_CONFIG_DIR=$f, or re-run $RERUN_HINT in the environment Claude Code uses"
  else
    emit env claude-config PASS "$CLAUDE_DIR${CLAUDE_CONFIG_DIR:+ (from CLAUDE_CONFIG_DIR)}"
  fi
  [ "$NOT_INSTALLED_YET" = 0 ] || return 0
  if [ -d "$WORKSPACE" ]; then
    p=$(stat -f '%Lp' "$WORKSPACE" 2>/dev/null || echo '?')
    case $p in
      700|500) emit env workspace PASS "$WORKSPACE (mode $p)" ;;
      *) emit env workspace WARN "$WORKSPACE is mode $p (other users can look inside)" "chmod 700 $(printf '%q' "$WORKSPACE") (or re-run $RERUN_HINT)" ;;
    esac
  else
    emit env workspace FAIL "workspace folder missing: $WORKSPACE" "run $RERUN_HINT (or pass --workspace DIR if you installed elsewhere)"
  fi
  NEED_SANDBOX=0
  for t in $APPS; do
    if [ "$(py "$CRAFTKIT" lock-get --app "$t" --field fence --lock "$LOCK" 2>/dev/null || true)" = sandbox ]; then
      NEED_SANDBOX=1
      break
    fi
  done
  [ "$NEED_SANDBOX" = 1 ] || return 0
  f=$PREFIX/craft-sandbox
  if [ ! -x "$f" ]; then
    emit env craft-sandbox FAIL "sandbox wrapper missing: $f" "run $RERUN_HINT"
  elif cmp -s <(grep -v 'craft-kit:kit-home' "$f") <(grep -v 'craft-kit:kit-home' "$KIT_DIR/bin/craft-sandbox"); then
    # install.sh may pin the marked kit-home line in its copy; everything else must be identical.
    emit env craft-sandbox PASS "$f (same as the kit's bin/craft-sandbox)"
  else
    emit env craft-sandbox WARN "$f differs from the kit's bin/craft-sandbox (older or edited); Claude Code starts the sandboxed servers through it, and an older wrapper can make GPU work crash (seen with LightCraft; --smoke shows it)" "re-run $RERUN_HINT to replace it"
  fi
  if [ -n "${CRAFT_SANDBOX_PROFILE:-}" ]; then
    emit env sandbox-profile WARN "CRAFT_SANDBOX_PROFILE=$CRAFT_SANDBOX_PROFILE overrides the kit's profile in this shell" \
      "unset CRAFT_SANDBOX_PROFILE unless you mean it; Claude Code started elsewhere will not see it"
  elif [ -f "$KIT_HOME/share/craft.sb" ]; then
    profile=$KIT_HOME/share/craft.sb
    if cmp -s "$profile" "$KIT_DIR/share/craft.sb"; then emit env sandbox-profile PASS "$profile"
    else emit env sandbox-profile WARN "$profile differs from the kit's share/craft.sb (older or edited)" "re-run $RERUN_HINT to replace it"; fi
  elif [ -f "$HOME/.local/share/craft-sandbox/craft.sb" ]; then
    emit env sandbox-profile WARN "only the legacy profile $HOME/.local/share/craft-sandbox/craft.sb exists" "re-run $RERUN_HINT (it installs $KIT_HOME/share/craft.sb)"
  else
    emit env sandbox-profile FAIL "no sandbox profile: $KIT_HOME/share/craft.sb is missing" "run $RERUN_HINT"
  fi
}

check_app() {
  local app=$1 why='' rc via
  local -a wrap=() skip=() first=()
  M_FENCE='' M_CLI=0 M_WS=0 M_FENCE_OK=0 M_WRAPPER='' M_FENCE_WHY='' M_REG_OK=0
  [ "$SKIP_MCP" = 0 ] || skip=(--mcp-skipped)
  helper "$app" cli-installed app-static --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" \
    --kit-dir "$KIT_DIR" --kit-home "$KIT_HOME" --lock "$LOCK" --receipt "$RECEIPT" \
    ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} ${skip[@]+"${skip[@]}"}
  [ "$M_CLI" = 1 ] || why="the CLI is not usable"
  [ "$M_WS" = 1 ] || why="${why:+$why; }the workspace folder is missing"
  [ "$M_FENCE_OK" = 1 ] || why="${why:+$why; }the fence is not confirmed${M_FENCE_WHY:+ ($M_FENCE_WHY)}"
  # Start the server the way Claude Code does when the registration is the expected one: for
  # sandboxed apps that means through the installed wrapper and the profile it finds itself.
  if [ "$M_REG_OK" = 1 ]; then
    via="started as registered"
    if [ "$M_FENCE" = sandbox ] && [ -x "$PREFIX/craft-sandbox" ]; then wrap=(--wrapper "$PREFIX/craft-sandbox"); fi
  else
    via="started as the installer would register it, not as currently registered"
  fi

  if [ -z "$why" ]; then
    rc=0
    # One real call (the first, in-memory step of the smoke test) in the same session: a server can
    # start and list tools but die on its first real call (seen: LightCraft's GPU setup in a sandbox).
    if [ -f "$SMOKE_DIR/$app.json" ]; then first=(--first-call "$SMOKE_DIR/$app.json"); fi
    py "$PROBE" --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" --timeout 60 \
      ${wrap[@]+"${wrap[@]}"} list-tools ${first[@]+"${first[@]}"} > "$TMPD/probe-$app.json" 2> "$TMPD/probe-$app.err" < /dev/null || rc=$?
    helper "$app" server-starts probe-result --app "$app" --rc "$rc" --out "$TMPD/probe-$app.json" \
      --err "$TMPD/probe-$app.err" --snapshot "$KIT_DIR/data/tools/$app.json" --lock "$LOCK" \
      --workspace "$WORKSPACE" --prefix "$PREFIX" ${wrap[@]+"${wrap[@]}"} --via "$via"
  else
    emit "$app" server-starts WARN "not started: $why" "fix the FAIL lines above first"
  fi

  if [ "$M_FENCE" = sandbox ]; then
    if [ "$M_WS" = 1 ]; then
      helper "$app" fence-live fence-live --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" \
        --kit-dir "$KIT_DIR" --kit-home "$KIT_HOME" --wrapper "$M_WRAPPER" \
        --read-candidate "$KIT_HOME/VERSION" --read-candidate "$KIT_HOME/receipt.json" \
        --read-candidate "$KIT_DIR/VERSION" --read-candidate "$PREFIX/craft-sandbox"
    else
      emit "$app" fence-live WARN "not probed: the workspace folder is missing" "fix the workspace FAIL above first"
    fi
  fi

  [ "$SMOKE" = 1 ] || return 0
  # _doctor is created by doctor and marked, so an interrupted run's folder can be recognised;
  # a _doctor folder without the marker belongs to someone else and is never deleted.
  local steps=$SMOKE_DIR/$app.json sd=$WORKSPACE/$app/_doctor marker=.craft-kit-doctor
  if [ ! -f "$steps" ]; then
    emit "$app" smoke WARN "no smoke test (tests/smoke/$app.json) in this kit" "update the kit"
  elif [ -n "$why" ]; then
    emit "$app" smoke WARN "not run: $why" "fix the FAIL lines above first"
  elif [ -L "$sd" ] || { [ -e "$sd" ] && [ ! -d "$sd" ]; }; then
    emit "$app" smoke FAIL "$sd exists and is not a folder; doctor does not touch it" "remove it, then run doctor --smoke again"
  elif [ -d "$sd" ] && [ ! -f "$sd/$marker" ]; then
    emit "$app" smoke WARN "not run: $sd already exists and doctor did not create it, so it is left alone" \
      "rename or remove that folder, then run doctor --smoke again"
  else
    [ ! -d "$sd" ] || rm -rf -- "$sd"
    mkdir -m 700 "$sd"
    SMOKE_DIRS+=("$sd")
    : > "$sd/$marker"
    rc=0
    py "$PROBE" --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" --timeout 60 \
      ${wrap[@]+"${wrap[@]}"} run "$steps" > "$TMPD/smoke-$app.json" 2> "$TMPD/smoke-$app.err" < /dev/null || rc=$?
    rm -rf -- "$sd"
    helper "$app" smoke smoke-result --app "$app" --rc "$rc" --out "$TMPD/smoke-$app.json" --err "$TMPD/smoke-$app.err" \
      --workspace "$WORKSPACE" --prefix "$PREFIX" --steps "$steps" ${wrap[@]+"${wrap[@]}"}
  fi
}

# ---- run ----
if [ "$JSON" = 0 ]; then
  printf '%scraft-claude-kit doctor %s%s\n' "$C_B" "$KIT_VERSION" "$C_0"
  printf '  kit        %s\n  workspace  %s\n  prefix     %s\n  claude     %s\n' \
    "$(tilde "$KIT_DIR")" "$(tilde "$WORKSPACE")" "$(tilde "$PREFIX")" "$(tilde "$CLAUDE_DIR")"
fi
# Nothing installed here at all (no receipt, no <app>-cli and no craft-sandbox in PREFIX): in text
# mode say that once instead of ~50 per-app FAIL lines. JSON keeps every record for scripts.
NOT_INSTALLED_YET=0
if [ "$JSON" = 0 ] && [ "$RECEIPT_OK" = 0 ] && [ -n "$ALL_APPS" ] && [ ! -e "$PREFIX/craft-sandbox" ]; then
  NOT_INSTALLED_YET=1
  for app in $ALL_APPS; do
    if [ -e "$PREFIX/$app-cli" ]; then NOT_INSTALLED_YET=0; fi
  done
fi

progress "environment"
check_env

if [ "$NOT_INSTALLED_YET" = 1 ]; then
  emit install installed FAIL "nothing installed here: no install receipt in $KIT_HOME and no <app>-cli in $PREFIX" \
    "run $RERUN_HINT (or pass --prefix DIR / set CRAFT_KIT_HOME if you installed elsewhere)"
elif [ -n "$ALL_APPS" ]; then
  for app in $APPS; do
    progress "$app"
    check_app "$app"
  done
  progress "skills, hooks, desktop apps, legacy"
  SRC=''
  if [ -d "$KIT_DIR/skills" ]; then SRC=$KIT_DIR/skills
  elif [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/skills" ]; then SRC=$REPO_DIR/skills; fi
  if [ "$SKIP_SKILLS" = 1 ]; then
    emit skills installed PASS "not checked: installed with --no-skills (re-run install.sh without it to add the skills)"
  else
    helper skills skills skills --claude-dir "$CLAUDE_DIR" --workspace "$WORKSPACE" --kit-home "$KIT_HOME" \
      --apps "$APPS_CSV" --source "$SRC" --tools-dir "$TMPD"
  fi
  if [ "$SKIP_HOOKS" = 1 ]; then
    emit hooks hooks PASS "not checked: installed with --no-hook (re-run install.sh without it to add the hooks)"
  else
    helper hooks hooks hooks --settings "$CLAUDE_DIR/settings.json" --kit-home "$KIT_HOME" --workspace "$WORKSPACE" \
      --apps "$ALL_APPS_CSV" --receipt "$RECEIPT"
  fi
  GUI_ARGS=(--apps "$APPS_CSV" --lock "$LOCK" --receipt "$RECEIPT")
  [ -z "$OPT_GUI_DIR" ] || GUI_ARGS+=(--gui-dir "$OPT_GUI_DIR")
  [ "$GUI" = 0 ] || GUI_ARGS+=(--force)
  helper gui gui gui "${GUI_ARGS[@]}"
fi
[ "$NOT_INSTALLED_YET" = 1 ] || helper legacy legacy legacy --settings "$CLAUDE_DIR/settings.json" --home "$HOME"

if [ "$JSON" = 1 ]; then
  py "$CHECKS" report --in "$RESULTS" --format json
else
  flush_scope
  printf '\n%s%s%s\n' "$C_B" "$(py "$CHECKS" report --in "$RESULTS" --format summary)" "$C_0"
  n_apps=$(printf '%s' "$APPS" | wc -w | tr -d ' ')
  if grep -q "${US}FAIL${US}" "$RESULTS"; then
    printf 'Fix the FAIL lines (each has a "fix:" hint), then run doctor.sh again.\n'
  elif grep -q "${US}WARN${US}" "$RESULTS"; then
    printf 'No failures (%s app(s) checked); the WARN lines are worth a look but do not block anything.\n' "$n_apps"
  else
    printf 'All good: %s app(s)%s%s checked.\n' "$n_apps" "$([ "$SKIP_SKILLS" = 1 ] || printf ', the skills')" "$([ "$SKIP_HOOKS" = 1 ] || printf ', the hooks')"
  fi
fi
if grep -q "${US}FAIL${US}" "$RESULTS"; then exit 1; fi
exit 0
