#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2015,SC2016,SC2034,SC2046,SC2086,SC2155,SC2317
# isolated.sh - run a command inside a throw-away fake user environment.
#
#   tests/isolated.sh COMMAND [ARGS...]
#
# Every run of install.sh / uninstall.sh / doctor.sh that is not --help or --dry-run should go through here
# while developing, so nothing can touch your real ~/.claude, ~/.claude.json, ~/.local or /Applications.
#
# It creates <tmp>/craft-kit-test.XXXXXX/ containing
#   <name>.XXXXXX/   HOME for the command (fresh, unique name; <name> is "home" unless ISOLATED_HOME_NAME says otherwise,
#                    e.g. ISOLATED_HOME_NAME="my home" to test paths with spaces)
#   tmp/             TMPDIR, so tests can see whether a tool leaves temp files behind
#   bin/             a fake `claude` (tests/fixtures/fake-claude) first on PATH, plus symlinks for tools your PATH only
#                    offered from a directory that was dropped (see below)
#   state/           files that must NOT live in HOME (the fake claude's call log)
# and runs COMMAND with this environment (always forced, never inherited):
#   HOME, CLAUDE_CONFIG_DIR=$HOME/.claude, CRAFT_KIT_HOME=$HOME/.local/share/craft-claude-kit,
#   CLAUDE_BIN=<fake claude>, TMPDIR, PATH, NO_COLOR=1, XDG_* inside HOME,
#   CRAFT_KIT_GUI_DIR=$HOME/Applications (the installer's and doctor's default desktop-app folder; without
#   it --gui with no --gui-dir would target the real /Applications, which a fake HOME cannot isolate)
# and, unless you already set them (so a test can point them at a variant):
#   CRAFT_KIT_LOCK=tests/fixtures/apps.lock.json   CRAFT_KIT_OFFLINE_DIR=tests/fixtures/out
#   CRAFT_KIT_SMOKE_DIR=tests/fixtures/smoke (smoke steps the fixture CLIs can answer)
# Also set: FAKE_CLAUDE_SANDBOX=1, FAKE_CLAUDE_LOG=<state>/claude-calls.log (one JSON array of arguments per line),
#   FAKE_CLAUDE_JQ, CRAFT_TEST_ROOT=<the temp root>, and proxy variables pointing at a closed local port, so an
#   accidental download fails at once instead of fetching the real 800+ MB of releases.
# PATH: your PATH minus directories that contain a Craft CLI or craft-sandbox (such as your real ~/.local/bin), so a
#   real installation can never be picked up by accident.
#
# The temp root is removed on exit (also after Ctrl-C) and any disk image still mounted under it is detached.
# KEEP_TEMP=1 keeps it and prints its path (and HOME) on stderr when the command ends.
# The exit status is the command's. Fixtures are built on first use (tests/fixtures/build.sh).
# Bash 3.2 compatible.
set -euo pipefail

usage() {
  sed -n '3,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --) shift ;;
esac
if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P)
FIX=$SELF_DIR/fixtures
REAL_HOME=${HOME:-}
APP_NAMES="wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft filmcraft effectcraft lightcraft soundcraft"

if [ -z "${CRAFT_KIT_LOCK:-}" ] || [ -z "${CRAFT_KIT_OFFLINE_DIR:-}" ]; then
  if [ ! -f "$FIX/apps.lock.json" ] || [ ! -d "$FIX/out" ]; then
    echo "isolated.sh: building the fixtures (first use) ..." >&2
    /bin/bash "$FIX/build.sh" --quiet >&2
  fi
fi
[ -f "$FIX/fake-claude" ] || { echo "isolated.sh: missing $FIX/fake-claude" >&2; exit 1; }

# ---- sandbox root ------------------------------------------------------------------------------------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/craft-kit-test.XXXXXX")
T=$(cd "$T" && pwd -P)
case "$T" in /*/craft-kit-test.??????) ;; *) echo "isolated.sh: unexpected temp root: $T" >&2; exit 1 ;; esac

detach_images() {
  command -v hdiutil > /dev/null 2>&1 || return 0
  local mp
  hdiutil info 2> /dev/null | awk -F'\t' -v root="$T/" '$1 ~ /^\/dev\/disk/ && index($0, root) { print $NF }' |
    while IFS= read -r mp; do
      [ -n "$mp" ] && hdiutil detach -force -quiet "$mp" > /dev/null 2>&1 || true
    done
}

cleanup() {
  local rc=$?
  trap - EXIT
  detach_images
  if [ "${KEEP_TEMP:-0}" = 1 ]; then
    echo "isolated.sh: kept the sandbox (KEEP_TEMP=1): $T" >&2
    echo "isolated.sh: HOME was ${HOME_DIR:-?}" >&2
  else
    chmod -R u+rwx "$T" > /dev/null 2>&1 || true
    rm -rf "$T"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

HOME_NAME=${ISOLATED_HOME_NAME:-home}
case "$HOME_NAME" in */* | '') echo "isolated.sh: ISOLATED_HOME_NAME must be a plain name" >&2; exit 2 ;; esac
HOME_DIR=$(mktemp -d "$T/$HOME_NAME.XXXXXX")
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
mkdir "$T/tmp" "$T/bin" "$T/state"
chmod 700 "$T/tmp"

# ---- PATH: drop directories holding a real Craft installation ------------------------------------------------------
dir_has_craft() { # DIR
  local d=$1 n
  [ -e "$d/craft-sandbox" ] && return 0
  for n in $APP_NAMES; do
    [ -e "$d/$n-cli" ] && return 0
  done
  return 1
}
new_path=''
old_ifs=$IFS
IFS=:
set -f
for d in $PATH; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  if dir_has_craft "$d" || { [ -n "$REAL_HOME" ] && [ "$d" = "$REAL_HOME/.local/bin" ]; }; then
    continue
  fi
  case ":$new_path:" in *":$d:"*) continue ;; esac
  new_path=${new_path:+$new_path:}$d
done
set +f
IFS=$old_ifs

for tool in jq python3 curl unzip shasum; do
  if ! PATH=$new_path command -v "$tool" > /dev/null 2>&1; then
    src=$(command -v "$tool" 2> /dev/null || true)
    [ -z "$src" ] || ln -s "$src" "$T/bin/$tool"
  fi
done
JQ_ABS=$(command -v jq 2> /dev/null || true)

cp "$FIX/fake-claude" "$T/bin/claude"
chmod 755 "$T/bin/claude"

# ---- environment ----------------------------------------------------------------------------------------------------
export HOME="$HOME_DIR"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CRAFT_KIT_HOME="$HOME/.local/share/craft-claude-kit"
export CLAUDE_BIN="$T/bin/claude"
export TMPDIR="$T/tmp"
export PATH="$T/bin${new_path:+:$new_path}"
export NO_COLOR=1
export CRAFT_KIT_GUI_DIR="$HOME/Applications"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
export CRAFT_KIT_LOCK="${CRAFT_KIT_LOCK:-$FIX/apps.lock.json}"
export CRAFT_KIT_OFFLINE_DIR="${CRAFT_KIT_OFFLINE_DIR:-$FIX/out}"
export CRAFT_KIT_SMOKE_DIR="${CRAFT_KIT_SMOKE_DIR:-$FIX/smoke}"
export FAKE_CLAUDE_SANDBOX=1
export FAKE_CLAUDE_LOG="$T/state/claude-calls.log"
export FAKE_CLAUDE_JQ="$JQ_ABS"
export CRAFT_TEST_ROOT="$T"
export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
unset no_proxy NO_PROXY CRAFT_SANDBOX_PROFILE FAKE_CLAUDE_FAIL_ADD FAKE_CLAUDE_FAIL_ADD_ARG FAKE_CLAUDE_VERSION

# last guard: never run against the real home
if [ -n "$REAL_HOME" ] && [ "$HOME" = "$REAL_HOME" ]; then
  echo "isolated.sh: refusing to run with the real HOME" >&2
  exit 1
fi
: > "$FAKE_CLAUDE_LOG"

rc=0
"$@" || rc=$?
exit "$rc"
