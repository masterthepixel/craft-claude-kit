#!/usr/bin/env bash
# install.sh: install the 13 Craft apps for Claude Code on macOS.
#
#   ./install.sh             show the plan, ask once, then install
#   ./install.sh --dry-run   show the plan only (changes nothing)
#   ./install.sh --help      every option
#
# What it does: downloads each app's headless CLI from its official GitHub release (SHA-256 checked
# against manifest/apps.lock.json), optionally the desktop apps, registers every CLI as a user-scope
# Claude Code MCP server confined to its own workspace folder, installs the Craft skills and two
# ask-only hooks, and writes a receipt that doctor.sh and uninstall.sh use. Safe to re-run.
# Bash 3.2 compatible (macOS /bin/bash).
# shellcheck disable=SC2016  # single-quoted $names in jq filters are jq variables
set -euo pipefail

# Resolve symlinks to this script, so a link to install.sh still finds the kit beside the real file.
src=${BASH_SOURCE[0]}
while [ -h "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd -P)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
KIT_DIR=$(cd -P "$(dirname "$src")" && pwd -P)
# shellcheck source=lib/common.sh
. "$KIT_DIR/lib/common.sh"

KIT_VERSION=$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)
PROG=install.sh
case "$0" in */*) SELF=$0 ;; *) SELF=./$0 ;; esac
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_NOTES=""

YES=0 DRY_RUN=0 ONLY="" GUI_MODE=yes DO_SKILLS=1 DO_HOOKS=1 DO_MCP=1
OPT_WORKSPACE="" OPT_PREFIX="" OPT_GUI_DIR="" OPT_OFFLINE="" GUI_FLAG_SEEN=""
ARGS_TEXT="$*"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Installs the 13 Craft apps, as command-line programs (the ones Claude uses) and as desktop apps (to open
the files yourself), from their official GitHub releases (SHA-256 verified), registers each
one as a Claude Code MCP server confined to its own workspace folder, and installs the Craft skills
and two ask-only safety hooks. It shows the full plan, with download sizes, and asks once before
changing anything. Re-running it is safe: it repairs what is missing and skips what is up to date.
A re-run keeps the workspace, --prefix, --gui-dir and app selection of the previous install unless
you pass them again.

Options:
  -y, --yes             do not ask; install as planned (command-line apps and desktop apps)
      --dry-run         show the plan and exit; changes nothing
      --only APP,APP    only these apps (skills and hooks are still installed); --only all for all 13
      --no-gui          skip the desktop apps (command-line apps only)
      --workspace DIR   workspace root, one folder per app (default: ~/craft-workspace)
      --prefix DIR      where the <app>-cli programs and craft-sandbox go (default: ~/.local/bin)
      --gui-dir DIR     where desktop apps go (default: /Applications if writable, else ~/Applications)
      --offline-dir DIR take downloads from DIR/<asset name> instead of the network (still verified)
      --no-skills       do not install the skills
      --no-hook         do not install the hooks
      --no-mcp          do not register the MCP servers
  -h, --help            show this help
      --version         print the kit version

Environment:
  CRAFT_KIT_HOME     kit runtime folder (default: ~/.local/share/craft-claude-kit)
  CLAUDE_CONFIG_DIR  Claude Code config folder (default: ~/.claude)
  CLAUDE_BIN         Claude Code command to use (default: claude)
  NO_COLOR           plain output without colours
  Test hooks:        CRAFT_KIT_LOCK=FILE (another lock file), CRAFT_KIT_OFFLINE_DIR=DIR (like --offline-dir),
                     CRAFT_KIT_GUI_DIR=DIR (default desktop-app folder instead of /Applications)

Exit codes: 0 ok, 1 something failed, 2 usage error, 3 preflight failed,
            4 declined (or not interactive and no --yes).
EOF
}

usage_error() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Run %s --help to see the options.\n' "$SELF" >&2
  exit 2
}

set_opt() {
  case "$1" in
    --only) ONLY=$2 ;;
    --workspace) OPT_WORKSPACE=$2 ;;
    --prefix) OPT_PREFIX=$2 ;;
    --gui-dir) OPT_GUI_DIR=$2 ;;
    --offline-dir) OPT_OFFLINE=$2 ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --gui | --no-gui)
        [ -z "$GUI_FLAG_SEEN" ] || [ "$GUI_FLAG_SEEN" = "$1" ] || usage_error "use either --gui or --no-gui, not both"
        GUI_FLAG_SEEN=$1
        if [ "$1" = --gui ]; then GUI_MODE=yes; else GUI_MODE=no; fi
        ;;
      --no-skills) DO_SKILLS=0 ;;
      --no-hook | --no-hooks) DO_HOOKS=0 ;;
      --no-mcp) DO_MCP=0 ;;
      --only | --workspace | --prefix | --gui-dir | --offline-dir)
        [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
        set_opt "$1" "$2"
        shift
        ;;
      --only=* | --workspace=* | --prefix=* | --gui-dir=* | --offline-dir=*)
        [ -n "${1#*=}" ] || usage_error "${1%%=*} needs a value"
        set_opt "${1%%=*}" "${1#*=}"
        ;;
      -h | --help) usage; exit 0 ;;
      --version) printf 'craft-claude-kit %s\n' "$KIT_VERSION"; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------------------------
# settings and preflight
# ---------------------------------------------------------------------------------------------
PREV_RECEIPT=""
prev_get() { # JQ_FILTER [jq args...] -> value from the previous receipt (empty if none or null)
  [ -n "$PREV_RECEIPT" ] || return 0
  local f=$1
  shift
  jq -r "$@" "($f) // empty" "$PREV_RECEIPT" 2>/dev/null || true
}
prev_path() { # FIELD -> that absolute path from the previous receipt (empty if missing or unusable)
  local v
  v=$(prev_get ".$1 | strings")
  case "$v" in /*) ;; *) return 0 ;; esac
  ! ck_bad_path_chars "$v" || return 0
  printf '%s' "$v"
}

default_gui_dir() {
  if [ -n "${CRAFT_KIT_GUI_DIR:-}" ]; then ck_abspath "$CRAFT_KIT_GUI_DIR"
  elif [ -d /Applications ] && [ -w /Applications ]; then echo /Applications
  else ck_abspath "$HOME/Applications"; fi
}

# A path as an option value people can paste: ~/x when that needs no quoting, else the quoted full path.
display_path() {
  case "$1" in
    "$HOME"/*) case "${1#"$HOME"/}" in *[!A-Za-z0-9_./@%+=,-]*) ck_shquote "$1" ;; *) ck_tilde "$1" ;; esac ;;
    *) ck_shquote "$1" ;;
  esac
}

PROBLEMS=""
problem() { # MESSAGE HINT
  PROBLEMS="${PROBLEMS}  - $1"$'\n'
  [ -z "${2:-}" ] || PROBLEMS="${PROBLEMS}    fix: $2"$'\n'
}

craftkit() { python3 -I "$KIT_DIR/lib/craftkit.py" "$@"; }

check_tools() {
  local t
  [ "$(uname -s)" = Darwin ] || ck_die 3 "This kit supports macOS only (13 or newer, Apple Silicon or Intel)." \
    "Linux and Windows are not supported: the Craft CLIs are macOS builds and the fences use macOS sandbox-exec."
  local os_ver major
  os_ver=$(sw_vers -productVersion 2>/dev/null || echo 0)
  major=${os_ver%%.*}
  case "$major" in '' | *[!0-9]*) major=0 ;; esac
  [ "$major" -ge 13 ] || problem "macOS $os_ver is too old; the Craft apps need macOS 13 or newer" "Update macOS."
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || ck_die 3 "HOME is not set to an existing folder." "Run the installer from a normal login shell."

  for t in curl unzip shasum; do
    command -v "$t" >/dev/null 2>&1 || problem "$t is missing" "It ships with macOS; install the Xcode Command Line Tools: xcode-select --install"
  done
  command -v jq >/dev/null 2>&1 || problem "jq is missing" "macOS 15 and newer include jq; on older macOS install it with Homebrew: brew install jq"
  if ! command -v python3 >/dev/null 2>&1; then
    problem "python3 is missing" "Install the Xcode Command Line Tools (xcode-select --install), which include python3."
  elif ! python3 -c 'pass' >/dev/null 2>&1; then
    # /usr/bin/python3 on a Mac without the Command Line Tools is a stub that only offers to install them.
    problem "python3 does not run (the Command Line Tools are probably missing): $(python3 -c pass 2>&1 | head -n 1)" \
      "xcode-select --install, then re-run."
  elif ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    problem "python3 is older than 3.9 ($(python3 --version 2>&1))" "Install a newer python3 (Xcode Command Line Tools or Homebrew)."
  fi
  if [ "$DO_MCP" = 1 ]; then
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
      local claude_fix="Install Claude Code first (setup guide: https://docs.anthropic.com/en/docs/claude-code/setup), open a new terminal, re-run. Or pass --no-mcp to skip MCP registration."
      if [ "$DRY_RUN" = 1 ]; then
        ck_warn "Claude Code CLI not found (looked for: $CLAUDE_BIN); a real install would stop here" "$claude_fix"
      else
        problem "Claude Code CLI not found (looked for: $CLAUDE_BIN)" "$claude_fix"
      fi
    fi
    [ -x /usr/bin/sandbox-exec ] || problem "/usr/bin/sandbox-exec is missing" "It ships with macOS 13+; without it the sandbox-fenced apps cannot be registered (or pass --no-mcp)."
  fi
  if [ "$GUI_MODE" = yes ]; then
    for t in hdiutil ditto; do
      command -v "$t" >/dev/null 2>&1 || problem "$t is missing (needed for --gui)" "It ships with macOS; or install without --gui."
    done
  fi
  for t in lib/craftkit.py bin/craft-sandbox share/craft.sb; do
    [ -f "$KIT_DIR/$t" ] || problem "kit file missing: $KIT_DIR/$t" "Your checkout is incomplete; clone the repository again."
  done
  if [ "$DO_HOOKS" = 1 ] && [ ! -f "$KIT_DIR/lib/settings_edit.py" ]; then
    problem "kit file missing: $KIT_DIR/lib/settings_edit.py" "Clone the repository again, or pass --no-hook."
  fi
}

resolve_settings() {
  local p
  for p in "$OPT_WORKSPACE" "$OPT_PREFIX" "$OPT_GUI_DIR" "$OPT_OFFLINE" "${CRAFT_KIT_HOME:-}" "${CLAUDE_CONFIG_DIR:-}" "${CRAFT_KIT_LOCK:-}"; do
    ! ck_bad_path_chars "$p" || usage_error "a path contains a newline or control character; choose another folder"
  done
  LOCK=$(ck_abspath "${CRAFT_KIT_LOCK:-$KIT_DIR/manifest/apps.lock.json}")
  OFFLINE_DIR=${OPT_OFFLINE:-${CRAFT_KIT_OFFLINE_DIR:-}}
  [ -z "$OFFLINE_DIR" ] || OFFLINE_DIR=$(ck_abspath "$OFFLINE_DIR")
  KIT_HOME=$(ck_abspath "${CRAFT_KIT_HOME:-$(ck_default_kit_home)}")
  KIT_HOME_IS_DEFAULT=0
  [ "$KIT_HOME" != "$(ck_abspath "$(ck_default_kit_home)")" ] || KIT_HOME_IS_DEFAULT=1
  if [ -f "$KIT_HOME/receipt.json" ] && jq -e '.schema == 1' "$KIT_HOME/receipt.json" >/dev/null 2>&1; then
    PREV_RECEIPT="$KIT_HOME/receipt.json"
  fi
  # A re-run (the README's update command) keeps the previous install's locations; the plan names
  # the ones that differ from the defaults.
  local v
  REUSED=""
  if [ -z "$OPT_WORKSPACE" ] && v=$(prev_path workspace) && [ -n "$v" ]; then
    OPT_WORKSPACE=$v
    [ "$v" = "$(ck_abspath "$HOME/craft-workspace")" ] || REUSED="$REUSED --workspace $(display_path "$v")"
  fi
  if [ -z "$OPT_PREFIX" ] && v=$(prev_path prefix) && [ -n "$v" ]; then
    OPT_PREFIX=$v
    [ "$v" = "$(ck_abspath "$HOME/.local/bin")" ] || REUSED="$REUSED --prefix $(display_path "$v")"
  fi
  if [ -z "$OPT_GUI_DIR" ] && v=$(prev_path guiDir) && [ -n "$v" ]; then
    OPT_GUI_DIR=$v
    [ "$v" = "$(default_gui_dir)" ] || REUSED="$REUSED --gui-dir $(display_path "$v")"
  fi
  PREFIX=$(ck_abspath "${OPT_PREFIX:-$HOME/.local/bin}")
  WORKSPACE=$(ck_abspath "${OPT_WORKSPACE:-$HOME/craft-workspace}")
  CLAUDE_CONFIG_ENV=${CLAUDE_CONFIG_DIR:-}
  [ -z "$CLAUDE_CONFIG_ENV" ] || CLAUDE_CONFIG_ENV=$(ck_abspath "$CLAUDE_CONFIG_ENV")
  CLAUDE_DIR=${CLAUDE_CONFIG_ENV:-$(ck_abspath "$HOME/.claude")}
  CLAUDE_JSON=$(ck_claude_json_for "$CLAUDE_CONFIG_ENV")
  SETTINGS="$CLAUDE_DIR/settings.json"
  if [ -n "$OPT_GUI_DIR" ]; then
    GUI_DIR=$(ck_abspath "$OPT_GUI_DIR")
  else
    GUI_DIR=$(default_gui_dir)
  fi
  HOME_REAL=$(ck_abspath "$HOME")

  case "$WORKSPACE/" in "$KIT_HOME"/*) usage_error "the workspace ($WORKSPACE) must not be inside the kit folder ($KIT_HOME): uninstall removes that folder" ;; esac
  # uninstall.sh removes fixed names inside the kit folder (bin, share, hooks, lib, ...), so no other
  # folder the kit uses may be the kit folder or lie inside it.
  case "$PREFIX/" in "$KIT_HOME"/*) usage_error "--prefix ($PREFIX) must not be the kit folder ($KIT_HOME) or inside it: uninstall removes the kit folder's bin/ and share/ folders" ;; esac
  case "$CLAUDE_DIR/" in "$KIT_HOME"/*) usage_error "the Claude Code folder ($CLAUDE_DIR) must not be the kit folder ($KIT_HOME) or inside it: uninstall removes the kit folder's hooks/ folder and more; choose another CRAFT_KIT_HOME" ;; esac
  case "$GUI_DIR/" in "$KIT_HOME"/*) usage_error "--gui-dir ($GUI_DIR) must not be the kit folder ($KIT_HOME) or inside it: uninstall removes folders there" ;; esac
  case "$WORKSPACE/" in "$PREFIX"/*) usage_error "the workspace ($WORKSPACE) must not be inside --prefix ($PREFIX)" ;; esac
  case "$WORKSPACE/" in "$KIT_DIR"/*) usage_error "the workspace ($WORKSPACE) must not be inside the kit checkout ($KIT_DIR); a relative --workspace is taken from the current folder" ;; esac
  [ "$WORKSPACE" != / ] && [ "$WORKSPACE" != "$HOME_REAL" ] || usage_error "--workspace must be a folder of its own (for example ~/craft-workspace), not $WORKSPACE"
  [ "$KIT_HOME" != / ] && [ "$KIT_HOME" != "$HOME_REAL" ] || usage_error "CRAFT_KIT_HOME must be a folder of its own, not $KIT_HOME"
  [ "$PREFIX" != / ] || usage_error "--prefix must not be /"
}

# Read and validate the lock into L_<field>_<app> variables.
load_lock() {
  [ -f "$LOCK" ] || { problem "lock file not found: $LOCK" "Clone the repository again (or fix CRAFT_KIT_LOCK)."; return 0; }
  local errors
  # Every lock value that later reaches a path, a URL, $(( )) or a registration is checked here,
  # before the plan, so even --dry-run never evaluates an unchecked value. extraArgs may only be
  # the per-app list below: a fence flag there would move the fence (the CLIs honour the last one).
  if ! errors=$(jq -r '
      def str: type == "string";
      def check($ok; $msg): if $ok then empty else $msg end;
      def size_ok: (type == "number") and (. >= 0) and (. == floor) and (. < 100000000000);
      def gh_url: str and test("^https://github\\.com/[A-Za-z0-9._/+%-]+$");
      def allowed_extra($a): {"wordcraft": [["--author", "Claude"]]}[$a] // [];
      if (type != "object") or (.schema != 1) or ((.apps | type) != "object") or ((.apps | length) == 0)
      then "not a schema-1 lock with apps"
      else .apps | to_entries[] | .key as $a | .value as $v |
        check(($a | test("^[a-z][a-z0-9]*$")); "\($a): bad app name"),
        check(($v | type) == "object"; "\($a): entry is not an object"),
        (if ($v | type) == "object" then
          check(($v.version | str) and ($v.version | test("^[0-9A-Za-z][0-9A-Za-z.+-]*$")); "\($a): bad version"),
          check(($v.fence == "roots") or ($v.fence == "root") or ($v.fence == "sandbox"); "\($a): bad fence"),
          check((($v.extraArgs // []) | type) == "array"; "\($a): extraArgs is not a list"),
          check((($v.extraArgs // []) | type) != "array" or (($v.extraArgs // []) | length) == 0
            or any(allowed_extra($a)[]; . == $v.extraArgs); "\($a): extraArgs \($v.extraArgs | tojson) are not allowed for this app"),
          check(($v.cli | type) == "object"; "\($a): no cli entry"),
          (if ($v.cli | type) == "object" then
            check(($v.cli.asset | str) and ($v.cli.asset | test("^[A-Za-z0-9._+-]+$")); "\($a): bad cli.asset"),
            check(($v.cli.sha256 | str) and ($v.cli.sha256 | test("^[0-9a-f]{64}$")); "\($a): bad cli.sha256"),
            check(($v.cli.size | size_ok); "\($a): bad cli.size (must be a whole number of bytes)"),
            check(($v.cli.url | gh_url); "\($a): bad cli.url (must be an https://github.com/ URL)")
           else empty end),
          (if $v.gui == null then empty
           elif ($v.gui | type) != "object" then "\($a): gui entry is not an object"
           else
            check(($v.gui.asset | str) and ($v.gui.asset | test("^[A-Za-z0-9._+-]+$")); "\($a): bad gui.asset"),
            check(($v.gui.sha256 | str) and ($v.gui.sha256 | test("^[0-9a-f]{64}$")); "\($a): bad gui.sha256"),
            check(($v.gui.size | size_ok); "\($a): bad gui.size (must be a whole number of bytes)"),
            check(($v.gui.url | gh_url); "\($a): bad gui.url (must be an https://github.com/ URL)"),
            check(($v.gui.bundle | str) and ($v.gui.bundle | test("^[A-Za-z0-9_+-][A-Za-z0-9._+-]*\\.app$")); "\($a): bad gui.bundle (must be a plain <Name>.app)")
           end)
         else empty end)
      end' "$LOCK" 2>&1); then
    problem "lock file is not valid JSON: $LOCK" "Clone the repository again (or fix CRAFT_KIT_LOCK)."
    return 0
  fi
  if [ -n "$errors" ]; then
    problem "lock file $LOCK has errors: $(printf '%s' "$errors" | tr '\n' ';' | sed 's/;$//')" "Clone the repository again (or fix CRAFT_KIT_LOCK)."
    return 0
  fi
  local US=$'\x1f' rows app ver fence ca cs csha cu ga gs gsha gu gb
  rows=$(jq -r '.apps | to_entries[] | [.key, .value.version, .value.fence,
      .value.cli.asset, (.value.cli.size | tostring), .value.cli.sha256, .value.cli.url,
      (.value.gui.asset // ""), ((.value.gui.size // 0) | tostring), (.value.gui.sha256 // ""),
      (.value.gui.url // ""), (.value.gui.bundle // "")] | join("\u001f")' "$LOCK")
  LOCK_APPS=""
  while IFS="$US" read -r app ver fence ca cs csha cu ga gs gsha gu gb; do
    [ -n "$app" ] || continue
    LOCK_APPS="${LOCK_APPS:+$LOCK_APPS }$app"
    ck_set "L_ver_$app" "$ver"; ck_set "L_fence_$app" "$fence"
    ck_set "L_casset_$app" "$ca"; ck_set "L_csize_$app" "$cs"; ck_set "L_csha_$app" "$csha"; ck_set "L_curl_$app" "$cu"
    ck_set "L_gasset_$app" "$ga"; ck_set "L_gsize_$app" "$gs"; ck_set "L_gsha_$app" "$gsha"; ck_set "L_gurl_$app" "$gu"
    ck_set "L_gbundle_$app" "$gb"
  done <<EOF
$rows
EOF
}

select_apps() {
  APPS="" REUSED_APPS=0
  local want a
  if [ -z "$ONLY" ] && [ -n "$PREV_RECEIPT" ]; then
    want=$(prev_get '.apps | keys[]' | tr '\n' ' ')
    for a in $LOCK_APPS; do
      ! ck_in_list "$a" "$want" || APPS="${APPS:+$APPS }$a"
    done
    if [ -n "$APPS" ] && [ "$APPS" != "$LOCK_APPS" ]; then
      REUSED_APPS=1
      return 0
    fi
    APPS=""
  fi
  if [ -z "$ONLY" ] || [ "$(printf '%s' "$ONLY" | tr '[:upper:]' '[:lower:]')" = all ]; then
    APPS=$LOCK_APPS
    return 0
  fi
  want=$(printf '%s' "$ONLY" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')
  for a in $want; do
    ck_in_list "$a" "$LOCK_APPS" || usage_error "unknown app in --only: $a (known: $(printf '%s' "$LOCK_APPS" | tr ' ' ','))"
  done
  for a in $LOCK_APPS; do
    ! ck_in_list "$a" "$want" || APPS="${APPS:+$APPS }$a"
  done
  [ -n "$APPS" ] || usage_error "--only selected no apps"
}

# The apps the receipt will list after this run: the ones of earlier runs plus this selection.
selected_after_run() {
  local had a out=""
  had=$(prev_get '.apps | keys[]' | tr '\n' ' ')
  for a in $LOCK_APPS; do
    if ck_in_list "$a" "$APPS" || ck_in_list "$a" "$had"; then out="${out:+$out }$a"; fi
  done
  printf '%s' "$out"
}

check_locations() {
  ck_writable_or_creatable "$KIT_HOME" || problem "cannot create or write $KIT_HOME" "Check the folder's permissions, or set CRAFT_KIT_HOME to a folder you own."
  # uninstall.sh deletes what is inside the kit folder, so it must be new, empty or the kit's own
  # (install.log is written before the first file is copied, so an interrupted first run counts).
  # shellcheck disable=SC2010  # filtering names, not parsing ls output for file handling
  if [ -d "$KIT_HOME" ] && [ ! -f "$KIT_HOME/receipt.json" ] && [ ! -f "$KIT_HOME/install.log" ] \
    && [ -n "$(ls -A "$KIT_HOME" 2>/dev/null | grep -v '^\.DS_Store$' || true)" ]; then
    problem "$KIT_HOME is not empty and was not made by craft-claude-kit" "Choose an empty or new folder with CRAFT_KIT_HOME, or move its contents away."
  fi
  ck_writable_or_creatable "$PREFIX" || problem "cannot create or write $PREFIX" "Choose another folder with --prefix DIR."
  ck_writable_or_creatable "$WORKSPACE" || problem "cannot create or write $WORKSPACE" "Choose another folder with --workspace DIR."
  if [ "$DO_SKILLS" = 1 ] || [ "$DO_HOOKS" = 1 ]; then
    ck_writable_or_creatable "$CLAUDE_DIR" || problem "cannot write the Claude Code folder $CLAUDE_DIR" "Check its permissions (or use --no-skills --no-hook)."
  fi
  if [ "$GUI_MODE" = yes ]; then
    ck_writable_or_creatable "$GUI_DIR" || problem "cannot write $GUI_DIR for the desktop apps" "Pass --gui-dir ~/Applications, or install without --gui."
  fi
  if [ -n "$OFFLINE_DIR" ] && [ ! -d "$OFFLINE_DIR" ]; then
    problem "offline folder not found: $OFFLINE_DIR" "Point --offline-dir (or CRAFT_KIT_OFFLINE_DIR) at a folder holding the release files."
  fi
}

# ---------------------------------------------------------------------------------------------
# plan (read-only)
# ---------------------------------------------------------------------------------------------

# An existing <app>-cli is kept only when its SHA-256 equals the one the kit recorded after it
# verified and installed that file (receipt apps.<app>.cliSha256). Any other file there (installed
# by hand, by an older setup, or changed since) is replaced by the verified download, and it is
# not run at plan time: the plan never executes a program the kit has not verified.
cli_state() { # APP -> sets P_cli_<app> (install|upgrade|replace|skip), P_clicur_<app>, P_clisha_<app>
  local app=$1 bin="$PREFIX/$1-cli" ver out want got=""
  ver=$(ck_get "L_ver_$app")
  ck_set "P_clicur_$app" ""
  ck_set "P_clisha_$app" ""
  if [ ! -e "$bin" ] && [ ! -L "$bin" ]; then
    ck_set "P_cli_$app" install
    return 0
  fi
  want=$(prev_get '.apps[$a].cliSha256 | strings' --arg a "$app")
  [ ! -f "$bin" ] || got=$(ck_sha256 "$bin" 2>/dev/null) || got=""
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    ck_set "P_cli_$app" replace
    return 0
  fi
  ck_set "P_clisha_$app" "$got"
  if [ -x "$bin" ] && out=$(ck_capture 30 "$bin" --version 2>&1) && ck_version_in "$out" "$ver"; then
    ck_set "P_cli_$app" skip
    ck_set "P_clicur_$app" "$ver"
    return 0
  fi
  ck_set "P_cli_$app" upgrade
  out=$(ck_first_version "${out:-}")
  ck_set "P_clicur_$app" "${out:-unknown}"
}

fence_help_ok() { # APP -> 0 if the installed CLI advertises its fence flag(s); message in CK_REPLY
  local app=$1 fence help flag
  fence=$(ck_get "L_fence_$app")
  CK_REPLY=""
  case "$fence" in
    roots) set -- --automation-read-root --automation-write-root ;;
    root) set -- --root ;;
    *) return 0 ;;
  esac
  help=$(ck_capture 30 "$PREFIX/$app-cli" --help 2>&1) || true
  for flag in "$@"; do
    if ! ck_has_flag "$help" "$flag"; then
      CK_REPLY="'$app-cli --help' does not list $flag"
      return 1
    fi
  done
}

mcp_state() { # APP -> P_mcp_<app>: add|ok|replace|nofence|error|off ; E_exp_<app>, E_reg_<app>
  local app=$1 exp reg rc=0
  ck_set "E_reg_$app" ""
  ck_set "E_exp_$app" ""
  ck_set "P_regok_$app" false
  if [ "$DO_MCP" = 0 ]; then
    ck_set "P_mcp_$app" off
    if exp=$(craftkit expected --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" 2>/dev/null) \
      && current_registration "$app" && [ "$CK_REPLY" = "$exp" ]; then
      ck_set "P_regok_$app" true
    fi
    return 0
  fi
  if ! exp=$(craftkit expected --app "$app" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" 2>&1); then
    ck_set "P_mcp_$app" error
    ck_set "P_mcpnote_$app" "$exp"
    return 0
  fi
  ck_set "E_exp_$app" "$exp"
  if [ -n "$CLAUDE_CONFIG_ENV" ]; then
    reg=$(craftkit registered --app "$app" --config-dir "$CLAUDE_CONFIG_ENV" 2>/dev/null) || rc=$?
  else
    reg=$(craftkit registered --app "$app" 2>/dev/null) || rc=$?
  fi
  case "$rc" in
    0)
      ck_set "E_reg_$app" "$reg"
      if [ "$reg" = "$exp" ]; then ck_set "P_mcp_$app" ok; else ck_set "P_mcp_$app" replace; fi
      ;;
    1) ck_set "P_mcp_$app" add ;;
    *)
      ck_set "P_mcp_$app" error
      ck_set "P_mcpnote_$app" "cannot read $CLAUDE_JSON"
      ;;
  esac
  if [ "$(ck_get "P_cli_$app")" = skip ] && ! fence_help_ok "$app"; then
    ck_set "P_mcp_$app" nofence
    ck_set "P_mcpnote_$app" "$CK_REPLY"
  fi
}

gui_state() { # APP -> P_gui_<app>: install|skip|keep|bad ; P_guicur_<app>
  local app=$1 bundle cur
  bundle=$(ck_get "L_gbundle_$app")
  ck_set "P_guicur_$app" ""
  case "$bundle" in
    "" | */* | .* | *[!A-Za-z0-9\ ._-]*) ck_set "P_gui_$app" bad; return 0 ;;
    *.app) ;;
    *) ck_set "P_gui_$app" bad; return 0 ;;
  esac
  if [ ! -e "$GUI_DIR/$bundle" ]; then
    ck_set "P_gui_$app" install
    return 0
  fi
  cur=$(ck_bundle_version "$GUI_DIR/$bundle")
  ck_set "P_guicur_$app" "${cur:-unknown}"
  if [ "$cur" = "$(ck_get "L_ver_$app")" ]; then ck_set "P_gui_$app" skip; else ck_set "P_gui_$app" keep; fi
}

wrapper_kind() { # PATH -> none|ours|legacy|other
  if [ ! -e "$1" ]; then echo none
  elif grep -qF "$CK_WRAPPER_MARKER" "$1" 2>/dev/null; then echo ours
  elif grep -qF '.local/share/craft-sandbox/craft.sb' "$1" 2>/dev/null; then echo legacy
  else echo other
  fi
}

# Is DST the unmodified copy the kit wrote last time (sha256 recorded in the previous receipt)?
skill_is_ours() { # NAME DST
  local want
  want=$(prev_get '.skillsSha256[$n]' --arg n "$1")
  [ -n "$want" ] && [ "$(ck_sha256 "$2")" = "$want" ]
}

skills_state() { # -> SK_NAMES, SK_NEW, SK_SAME, SK_UPD, SK_REPL, SK_LINK (space-separated names)
  SK_NAMES="" SK_NEW="" SK_SAME="" SK_UPD="" SK_REPL="" SK_LINK=""
  local src name dst
  for src in "$KIT_DIR"/skills/*/SKILL.md; do
    [ -f "$src" ] || continue
    name=$(basename "$(dirname "$src")")
    case "$name" in craft-[a-z]*) ;; *) continue ;; esac
    SK_NAMES="${SK_NAMES:+$SK_NAMES }$name"
    dst="$CLAUDE_DIR/skills/$name/SKILL.md"
    if [ -L "$CLAUDE_DIR/skills/$name" ] || [ -L "$dst" ]; then
      SK_LINK="${SK_LINK:+$SK_LINK }$name"
    elif [ ! -e "$dst" ]; then
      SK_NEW="${SK_NEW:+$SK_NEW }$name"
    elif craftkit render --workspace "$WORKSPACE" --kit-home "$KIT_HOME" --in "$src" --out - 2>/dev/null | cmp -s - "$dst"; then
      SK_SAME="${SK_SAME:+$SK_SAME }$name"
    elif skill_is_ours "$name" "$dst"; then
      SK_UPD="${SK_UPD:+$SK_UPD }$name"
    else
      SK_REPL="${SK_REPL:+$SK_REPL }$name"
    fi
  done
}

count_words() { local n=0 w; for w in $1; do [ -z "$w" ] || n=$((n + 1)); done; echo "$n"; }

# Folders the kit manages under the workspace that exist but are open to other users.
is_loose() { # DIR -> 0 if it is a real folder of ours that group/others can open
  local m
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  m=$(stat -f '%Lp' "$1" 2>/dev/null) || return 1
  case "$m" in *00) return 1 ;; esac
  return 0
}

loose_dirs() {
  local app d
  ! is_loose "$WORKSPACE" || printf '%s\n' "$WORKSPACE"
  for app in $APPS; do
    for d in "$WORKSPACE/$app" "$WORKSPACE/$app/in" "$WORKSPACE/$app/out"; do
      ! is_loose "$d" || printf '%s\n' "$d"
    done
  done
}

settings_edit() { python3 -I "$KIT_DIR/lib/settings_edit.py" "$@"; }

# Why settings.json cannot be edited (empty when it is missing or strict JSON).
settings_problem() {
  local out
  [ -e "$SETTINGS" ] || return 0
  if out=$(settings_edit list-hooks --settings "$SETTINGS" 2>&1 >/dev/null); then return 0; fi
  out=${out#settings_edit: }
  printf '%s' "${out%%. Nothing was changed*}"
}

plan_all() {
  local app csv
  for app in $APPS; do
    cli_state "$app"
    mcp_state "$app"
    if [ "$GUI_MODE" != no ]; then gui_state "$app"; else ck_set "P_gui_$app" off; fi
  done
  [ "$DO_SKILLS" = 0 ] || skills_state
  PREFIX_WRAPPER_KIND=$(wrapper_kind "$PREFIX/craft-sandbox")
  LEGACY_HOOK_ENTRY=0
  if [ "$DO_HOOKS" = 1 ] && ck_settings_has_hook "$SETTINGS" "/$CK_LEGACY_HOOK_REL"; then LEGACY_HOOK_ENTRY=1; fi
  LOOSE_DIRS=$(loose_dirs)
  SETTINGS_PROBLEM=""
  [ "$DO_HOOKS" = 0 ] || SETTINGS_PROBLEM=$(settings_problem)
  SHADOWED='[]'
  if [ "$DO_MCP" = 1 ]; then
    csv=$(printf '%s' "$APPS" | tr ' ' ',')
    if [ -n "$CLAUDE_CONFIG_ENV" ]; then
      SHADOWED=$(craftkit shadowed --apps "$csv" --config-dir "$CLAUDE_CONFIG_ENV" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" 2>/dev/null) || SHADOWED='[]'
    else
      SHADOWED=$(craftkit shadowed --apps "$csv" --workspace "$WORKSPACE" --prefix "$PREFIX" --lock "$LOCK" 2>/dev/null) || SHADOWED='[]'
    fi
  fi
}

pad() { printf "%-${1}s" "$2"; }

cli_label() {
  local app=$1 size
  size=$(ck_mb "$(ck_get "L_csize_$app")")
  case "$(ck_get "P_cli_$app")" in
    skip) echo "up to date $(ck_get "L_ver_$app")" ;;
    install) echo "install $(ck_get "L_ver_$app"), $size" ;;
    upgrade) echo "$(ck_get "P_clicur_$app") -> $(ck_get "L_ver_$app"), $size" ;;
    replace) echo "replace* -> $(ck_get "L_ver_$app"), $size" ;;
  esac
}

mcp_label() {
  case "$(ck_get "P_mcp_$1")" in
    ok) echo "registered" ;;
    add) echo "add" ;;
    replace) echo "replace" ;;
    nofence) echo "FAIL: no fence" ;;
    error) echo "FAIL (below)" ;;
    off) echo "skip (--no-mcp)" ;;
  esac
}

gui_label() {
  local app=$1
  case "$(ck_get "P_gui_$app")" in
    off) echo "-" ;;
    install) echo "install $(ck_mb "$(ck_get "L_gsize_$app")")" ;;
    skip) echo "have $(ck_get "L_ver_$app")" ;;
    keep) echo "keep $(ck_get "P_guicur_$app")" ;;
    bad) echo "unavailable" ;;
  esac
}

print_plan() {
  local app dl_cli=0 dl_gui=0 n_cli=0 n_gui=0 maxzip=0 sz s
  printf '%scraft-claude-kit %s: install plan%s\n\n' "$CK_BOLD" "$KIT_VERSION" "$CK_RESET"
  if [ -n "$REUSED" ] || [ "$REUSED_APPS" = 1 ]; then
    printf '  Same settings as your previous install (pass the option again to change one):\n   %s%s\n\n' "$REUSED" \
      "$([ "$REUSED_APPS" = 1 ] && printf ' --only %s   (the apps installed so far; --only all for all %s)' "$(printf '%s' "$APPS" | tr ' ' ',')" "$(count_words "$LOCK_APPS")")"
  fi
  # Table lines stay within 80 columns (app names are at most 11 characters).
  printf '%s  %s%s%s%s%s%s\n' "$CK_BOLD" "$(pad 12 APP)" "$(pad 24 'CLI')" "$(pad 8 FENCE)" "$(pad 16 'MCP SERVER')" \
    "$([ "$GUI_MODE" = no ] || printf 'DESKTOP')" "$CK_RESET"
  local any_replace=0
  for app in $APPS; do
    printf '  %s%s%s%s%s%s%s\n' "$CK_BOLD" "$(pad 12 "$app")" "$CK_RESET" "$(ck_paint "$(pad 24 "$(cli_label "$app")")")" "$(pad 8 "$(ck_get "L_fence_$app")")" \
      "$(ck_paint "$(pad 16 "$(mcp_label "$app")")")" "$([ "$GUI_MODE" = no ] || ck_paint "$(gui_label "$app")")"
    case "$(ck_get "P_cli_$app")" in
      replace) any_replace=1 ;;
    esac
    case "$(ck_get "P_cli_$app")" in
      install | upgrade | replace)
        sz=$(ck_get "L_csize_$app")
        dl_cli=$((dl_cli + sz)); n_cli=$((n_cli + 1))
        [ "$sz" -le "$maxzip" ] || maxzip=$sz
        ;;
    esac
    if [ "$(ck_get "P_gui_$app")" = install ]; then
      dl_gui=$((dl_gui + $(ck_get "L_gsize_$app"))); n_gui=$((n_gui + 1))
    fi
  done
  printf '  CLI = the <app>-cli program. FENCE keeps each server in its own folder: roots/root =\n'
  printf '  the app'"'"'s own folder flags, sandbox = the macOS sandbox (craft-sandbox).\n'
  printf '  MCP SERVER = the entry that lets Claude Code use the app (docs/FENCES.md).\n'
  [ "$GUI_MODE" = no ] || printf '  DESKTOP = the windowed app, to open the files yourself.\n'
  if [ "$any_replace" = 1 ]; then
    printf '  * replace: a program of that name is there that the kit did not install or cannot\n'
    printf '    verify; it is replaced by the verified download and is not run before that.\n'
    printf '    The old file is kept beside it as <name>.bak-craft-kit-%s.\n' "$TS"
  fi
  if [ -n "$ONLY" ] && [ "$(printf '%s' "$ONLY" | tr '[:upper:]' '[:lower:]')" != all ] && [ "$APPS" != "$LOCK_APPS" ]; then
    printf '  Later plain re-runs keep every app installed so far (now: %s);\n' "$(printf '%s' "$(selected_after_run)" | tr ' ' ',')"
    printf '  --only adds to that set. Use --only all for all %s apps.\n' "$(count_words "$LOCK_APPS")"
  fi
  printf '\n'
  printf '  Download now: %s for %s command-line app(s)' "$(ck_mb "$dl_cli")" "$n_cli"
  case "$GUI_MODE" in
    yes) printf ' + %s for %s desktop app(s)\n' "$(ck_mb "$dl_gui")" "$n_gui" ;;
    *)
      dl_gui=0
      for app in $APPS; do dl_gui=$((dl_gui + $(ck_get "L_gsize_$app"))); done
      printf '\n  Desktop apps: not included (add --gui to also install them, %s)\n' "$(ck_mb "$dl_gui")"
      ;;
  esac
  [ -z "$OFFLINE_DIR" ] || printf '  Downloads come from %s (offline mode), SHA-256 still verified\n' "$(ck_tilde "$OFFLINE_DIR")"
  # Rough disk check: an installed CLI is about 2.5x its zip; the zip and its contents are temporary.
  local need_kb free_kb
  need_kb=$(((dl_cli * 5 / 2 + maxzip * 4) / 1024))
  free_kb=$(ck_free_kb "$PREFIX")
  if [ -n "$free_kb" ] && [ "$need_kb" -gt 0 ] && [ "$free_kb" -lt "$need_kb" ]; then
    printf '  %sWARN%s  low disk space: about %s needed, %s free\n' "$CK_YELLOW" "$CK_RESET" "$(ck_mb $((need_kb * 1024)))" "$(ck_mb $((free_kb * 1024)))"
  fi

  printf '\n  Folders and files this run may create or change:\n'
  printf '    %s  kit runtime: doctor.sh, uninstall.sh, lib, hooks, sandbox profile, receipt.json, install.log\n' "$(ck_tilde "$KIT_HOME")"
  printf '    %s  <app>-cli programs and craft-sandbox' "$(ck_tilde "$PREFIX")"
  case "$PREFIX_WRAPPER_KIND" in
    legacy) printf ' (replaces the older hand-made craft-sandbox)' ;;
    other) printf ' (an unrelated craft-sandbox there is kept as craft-sandbox.bak-%s)' "$TS" ;;
  esac
  printf '\n'
  printf '    %s/<app>/{in,out}  one private (700) folder per app; existing files are never touched\n' "$(ck_tilde "$WORKSPACE")"
  [ -z "$LOOSE_DIRS" ] || printf '      %s existing folder(s) there that other users can open are made private (chmod go-rwx)\n' "$(printf '%s\n' "$LOOSE_DIRS" | grep -c .)"
  [ "$DO_MCP" = 0 ] || printf '    %s  user-scope MCP servers, changed only through "%s mcp add/remove"\n' "$(ck_tilde "$CLAUDE_JSON")" "$(ck_tilde "$CLAUDE_BIN")"
  if [ "$DO_SKILLS" = 1 ]; then
    printf '    %s/skills/  %s skills: %s new, %s up to date, %s updated, %s replaced\n' \
      "$(ck_tilde "$CLAUDE_DIR")" "$(count_words "$SK_NAMES")" "$(count_words "$SK_NEW")" "$(count_words "$SK_SAME")" \
      "$(count_words "$SK_UPD")" "$(count_words "$SK_REPL")"
    [ -z "$SK_REPL" ] || printf '      replaced (they differ from what the kit last installed; your copy is kept as SKILL.md.bak-%s): %s\n' "$TS" "$SK_REPL"
    [ -z "$SK_LINK" ] || printf '      left alone because they are symlinks: %s\n' "$SK_LINK"
  fi
  if [ "$DO_HOOKS" = 1 ]; then
    printf '    %s  two PreToolUse hooks (Bash shell guard, Craft MCP guard); one backup is made before any change\n' "$(ck_tilde "$SETTINGS")"
    [ "$LEGACY_HOOK_ENTRY" = 0 ] || printf '      and the older hand-made craft-shell-guard hook entry is removed\n'
    if [ -n "$SETTINGS_PROBLEM" ]; then
      printf '      %sWARN%s  the hooks step will leave this file untouched: %s\n' "$CK_YELLOW" "$CK_RESET" "$SETTINGS_PROBLEM"
      printf '            The kit edits it only as strict JSON (no comments, no trailing commas). Fix it first, or pass --no-hook.\n'
    fi
  fi
  if [ "$GUI_MODE" != no ]; then
    printf '    %s  desktop apps%s; existing apps are never replaced\n' "$(ck_tilde "$GUI_DIR")" ""
  fi
  local legacy=""
  [ ! -f "$HOME/$CK_LEGACY_HOOK_REL" ] || [ "$DO_HOOKS" = 0 ] || legacy="$legacy ~/$CK_LEGACY_HOOK_REL"
  [ ! -f "$HOME/$CK_LEGACY_PROFILE_REL" ] || legacy="$legacy ~/$CK_LEGACY_PROFILE_REL"
  [ -z "$legacy" ] || printf '    older hand-made setup files to move aside (.bak-craft-kit-%s) once replaced, if recognised:%s\n' "$TS" "$legacy"

  for app in $APPS; do
    case "$(ck_get "P_mcp_$app")" in
      replace)
        printf '\n  %s: the existing MCP registration will be replaced.\n    now:  %s\n    new:  %s\n' "$app" \
          "$(printf '%s' "$(ck_get "E_reg_$app")" | jq -r '[.command] + .args | join(" ")' 2>/dev/null)" \
          "$(printf '%s' "$(ck_get "E_exp_$app")" | jq -r '[.command] + .args | join(" ")' 2>/dev/null)"
        ;;
      nofence) printf '\n  %s: %s, so it will NOT be registered (fail-closed).\n' "$app" "$(ck_get "P_mcpnote_$app")" ;;
      error) printf '\n  %s: cannot plan the MCP registration: %s\n' "$app" "$(ck_get "P_mcpnote_$app")" ;;
    esac
  done
  if [ "$SHADOWED" != '[]' ] && [ -n "$SHADOWED" ]; then
    printf '\n  %sWARN%s  registered again at local or project scope; in that folder Claude Code uses these instead of the fenced server:\n' "$CK_YELLOW" "$CK_RESET"
    printf '%s' "$SHADOWED" | jq -r '.[] | "        \(.app) (\(.scope) scope, \(.dir)): \(([.command] + .args) | join(" "))\n          fix: " +
      (if .scope == "local" then "cd \(.dir | @sh) && claude mcp remove \(.app) -s local" else "remove \(.app) from \(.file | @sh)" end)' 2>/dev/null || true
  fi
  if [ -n "$PREV_RECEIPT" ]; then
    s=$(prev_get .prefix)
    if [ -n "$s" ] && [ "$s" != "$PREFIX" ]; then
      printf '\n  Note: the previous install used --prefix %s; its programs there are not moved or removed.\n' "$s"
      local old="" a
      for a in $LOCK_APPS; do [ ! -f "$s/$a-cli" ] || old="$old $(ck_shquote "$s/$a-cli")"; done
      [ "$(wrapper_kind "$s/craft-sandbox")" != ours ] || old="$old $(ck_shquote "$s/craft-sandbox")"
      [ -z "$old" ] || printf '  Once nothing uses them, remove them with:\n    rm%s\n' "$old"
    fi
    s=$(prev_get .workspace)
    [ -z "$s" ] || [ "$s" = "$WORKSPACE" ] || printf '\n  Note: the previous install used the workspace %s; registrations and hooks move to %s, files stay where they are.\n' "$s" "$WORKSPACE"
  fi
}

# ---------------------------------------------------------------------------------------------
# install steps (each records results; failures never stop the other apps)
# ---------------------------------------------------------------------------------------------
FAILED_APPS="" FAIL_NOTES="" ANY_FAIL=0

note_fail() { # APP|- MESSAGE
  ANY_FAIL=1
  if [ "$1" != - ] && ! ck_in_list "$1" "$FAILED_APPS"; then FAILED_APPS="${FAILED_APPS:+$FAILED_APPS }$1"; fi
  FAIL_NOTES="${FAIL_NOTES}  - $2"$'\n'
}

# Files written into KIT_HOME, relative to it; recorded in the receipt (kitFiles) so uninstall.sh removes
# only these and keeps anything else found in the kit folder (B1-CONFIG-1).
KIT_FILES=""
install_file() { # SRC DST MODE -> CK_REPLY=same|changed ; atomic (temp file beside DST, then mv)
  local src=$1 dst=$2 mode=$3 t
  case "$dst" in "$KIT_HOME"/?*) KIT_FILES="$KIT_FILES${dst#"$KIT_HOME"/}"$'\n' ;; esac
  if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    CK_REPLY=same
    return 0
  fi
  mkdir -p "$(dirname "$dst")" || return 1
  ck_mktemp_beside "$dst" || return 1
  t=$CK_REPLY
  if cp "$src" "$t" && chmod "$mode" "$t" && mv -f "$t" "$dst"; then
    CK_REPLY=changed
    return 0
  fi
  rm -f "$t"
  return 1
}

kit_copy_tree() { # REL_DIR [maxdepth] -> copies files under KIT_DIR/REL_DIR into KIT_HOME
  local rel=$1 depth=${2:-} list f mode
  [ -d "$KIT_DIR/$rel" ] || return 0
  if [ -n "$depth" ]; then
    list=$(cd "$KIT_DIR" && find "$rel" -maxdepth "$depth" -type f ! -name '*.pyc' ! -name '.DS_Store' ! -name '*.bak*' | sort) || return 1
  else
    list=$(cd "$KIT_DIR" && find "$rel" -type f ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '.DS_Store' ! -name '*.bak*' | sort) || return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mode=644
    [ ! -x "$KIT_DIR/$f" ] || mode=755
    install_file "$KIT_DIR/$f" "$KIT_HOME/$f" "$mode" || return 1
  done <<EOF
$list
EOF
}

# The wrapper to install: the repo copy, or (non-default CRAFT_KIT_HOME) a copy pinned to KIT_HOME
# so the wrapper finds the profile without CRAFT_KIT_HOME in Claude Code's environment.
wrapper_source() {
  if [ "$KIT_HOME_IS_DEFAULT" = 1 ]; then
    CK_REPLY="$KIT_DIR/bin/craft-sandbox"
    return 0
  fi
  ck_mktemp_dir || return 1
  local out="$CK_REPLY/craft-sandbox"
  CK_PIN_LINE="KIT_HOME_DEFAULT=\${CRAFT_KIT_HOME:-$(ck_shquote "$KIT_HOME")} # craft-kit:kit-home" \
    awk '/# craft-kit:kit-home$/ { print ENVIRON["CK_PIN_LINE"]; next } { print }' "$KIT_DIR/bin/craft-sandbox" >"$out" || return 1
  CK_REPLY=$out
}

SANDBOX_OK=0
step_runtime() {
  ck_head "Kit runtime: $KIT_HOME"
  local rel ok=1 wsrc
  for rel in doctor.sh uninstall.sh VERSION; do
    if [ -f "$KIT_DIR/$rel" ]; then
      if [ -x "$KIT_DIR/$rel" ]; then install_file "$KIT_DIR/$rel" "$KIT_HOME/$rel" 755 || ok=0
      else install_file "$KIT_DIR/$rel" "$KIT_HOME/$rel" 644 || ok=0; fi
    else
      ck_warn "$rel is missing from this checkout; not copied" "Update your checkout of the kit (git pull) and re-run."
    fi
  done
  kit_copy_tree lib || ok=0
  kit_copy_tree data || ok=0
  kit_copy_tree tests/smoke || ok=0
  kit_copy_tree hooks 1 || ok=0
  install_file "$KIT_DIR/share/craft.sb" "$KIT_HOME/share/craft.sb" 644 || ok=0
  install_file "$LOCK" "$KIT_HOME/manifest/apps.lock.json" 644 || ok=0
  if [ "$ok" = 1 ]; then
    ck_ok "runtime files are in place"
  else
    ck_fail "could not copy every kit file into $KIT_HOME" "Check free space and permissions of $KIT_HOME, then re-run."
    note_fail - "kit runtime copy in $KIT_HOME is incomplete"
  fi

  ok=1
  if wrapper_source; then
    wsrc=$CK_REPLY
    install_file "$wsrc" "$KIT_HOME/bin/craft-sandbox" 755 || ok=0
    if [ "$ok" = 1 ] && [ "$(wrapper_kind "$PREFIX/craft-sandbox")" = other ]; then
      mv -f "$PREFIX/craft-sandbox" "$PREFIX/craft-sandbox.bak-$TS" || ok=0
      [ "$ok" = 0 ] || ck_warn "an unrelated $PREFIX/craft-sandbox was moved to craft-sandbox.bak-$TS"
    fi
    [ "$ok" = 0 ] || install_file "$wsrc" "$PREFIX/craft-sandbox" 755 || ok=0
  else
    ok=0
  fi
  if [ "$ok" = 1 ] && [ -f "$KIT_HOME/share/craft.sb" ]; then
    SANDBOX_OK=1
    ck_ok "sandbox wrapper $PREFIX/craft-sandbox and profile $KIT_HOME/share/craft.sb"
  else
    ck_fail "could not install the sandbox wrapper or its profile; sandbox-fenced apps will not be registered" \
      "Check that $PREFIX and $KIT_HOME are writable, then re-run."
    note_fail - "sandbox wrapper/profile not installed"
  fi
  legacy_sandbox_cleanup
}

# The older hand-made files are recognised by content, not only by path, and are moved aside
# (<name>.bak-craft-kit-<timestamp>), never deleted: a file of that name may be something else.
legacy_profile_recognised() { grep -qF '(version 1)' "$1" 2>/dev/null && grep -qF '(param "ROOT")' "$1" 2>/dev/null; }
# The older hook names itself (craft-shell-guard) and answers with an ask decision. Mentioning "craft"
# plus a hook keyword is not enough: the user's own hook could do that (B1-SUPPLY-1).
legacy_hook_recognised() {
  grep -qi 'craft-shell-guard' "$1" 2>/dev/null && grep -qF 'permissionDecision' "$1" 2>/dev/null \
    && grep -qF '"ask"' "$1" 2>/dev/null
}
move_aside() { # FILE -> moves it to FILE.bak-craft-kit-TS ; path in CK_REPLY
  CK_REPLY="$1.bak-craft-kit-$TS"
  mv -f "$1" "$CK_REPLY"
}

legacy_sandbox_cleanup() {
  local prof="$HOME/$CK_LEGACY_PROFILE_REL" wrap="$HOME/$CK_LEGACY_WRAPPER_REL"
  [ -f "$prof" ] && [ "$SANDBOX_OK" = 1 ] || return 0
  if ! legacy_profile_recognised "$prof"; then
    ck_warn "kept $prof: it is not the older craft-sandbox profile the kit knows" "Delete it yourself if it is a leftover."
    return 0
  fi
  case "$(wrapper_kind "$wrap")" in
    none | ours)
      if move_aside "$prof"; then
        ck_ok "moved the older sandbox profile aside to $CK_REPLY (the kit's profile replaces it)"
      fi
      ;;
    *) ck_warn "kept the older sandbox profile $prof: $wrap (outside --prefix) still uses it" \
      "Once nothing uses $wrap, delete it and $prof." ;;
  esac
}

fetch_asset() { # APP cli|gui OUTFILE -> downloads (or copies offline) and verifies sha256
  local app=$1 kind=$2 out=$3 asset url sha got
  if [ "$kind" = cli ]; then
    asset=$(ck_get "L_casset_$app"); url=$(ck_get "L_curl_$app"); sha=$(ck_get "L_csha_$app")
  else
    asset=$(ck_get "L_gasset_$app"); url=$(ck_get "L_gurl_$app"); sha=$(ck_get "L_gsha_$app")
  fi
  if [ -n "$OFFLINE_DIR" ]; then
    if [ ! -f "$OFFLINE_DIR/$asset" ]; then
      ck_fail "$app: $asset not found in the offline folder $OFFLINE_DIR" "Put the release file there, or run without --offline-dir."
      return 1
    fi
    cp "$OFFLINE_DIR/$asset" "$out" || { ck_fail "$app: cannot copy $OFFLINE_DIR/$asset"; return 1; }
  else
    case "$url" in
      https://github.com/*) ;;
      *) ck_fail "$app: refusing to download $url (only https://github.com/ release URLs are allowed)" "Restore manifest/apps.lock.json from the repository."; return 1 ;;
    esac
    ck_dim "  ..    downloading $asset ($(ck_mb "$(ck_get "L_${kind:0:1}size_$app")"))"
    local progress=-sS why
    [ ! -t 2 ] || progress=--progress-bar
    # --speed-limit/--speed-time: a stalled transfer (under 1 KB/s for 60 s) fails and is retried
    # instead of hanging forever. %{errormsg} is curl's own reason (disk full, proxy, TLS, ...).
    if ! why=$(curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 30 \
      --speed-limit 1024 --speed-time 60 "$progress" -w '%{errormsg}' -o "$out" "$url"); then
      why=$(printf '%s' "$why" | tail -n 1)
      ck_fail "$app: download failed: $url${why:+ ($why)}" \
        "Check the connection (a stalled or blocked network, a proxy or captive portal) and free disk space (df -h), then re-run; apps that finished are skipped."
      return 1
    fi
  fi
  got=$(ck_sha256 "$out") || got=""
  if [ "$got" != "$sha" ]; then
    rm -f "$out"
    ck_fail "$app: SHA-256 mismatch for $asset (expected $sha, got ${got:-nothing}); the file was deleted" \
      "Re-run once. If it happens again, do not use the file: the release may have changed upstream; please open an issue."
    return 1
  fi
}

zip_is_safe() { # ZIP -> 0 if no absolute paths, no '..' parts, no symlinks
  local listing
  listing=$(unzip -Z1 "$1" 2>/dev/null) || return 1
  if grep -Eq '^/|^\\|(^|/|\\)\.\.(/|\\|$)' <<<"$listing"; then return 1; fi
  listing=$(unzip -Z "$1" 2>/dev/null) || return 1
  if grep -q '^l' <<<"$listing"; then return 1; fi
  return 0
}

do_cli() { # APP -> 0 ok, 1 failed ; sets R_cli_<app>
  local app=$1 ver bin tmp zip member count exe stage out
  ver=$(ck_get "L_ver_$app")
  bin="$PREFIX/$app-cli"
  if [ "$(ck_get "P_cli_$app")" = skip ]; then
    ck_skip "$app-cli $ver already installed (the file the kit verified and installed)"
    ck_set "R_cli_$app" "up to date"
    ck_set "R_clisha_$app" "$(ck_get "P_clisha_$app")"
    return 0
  fi
  ck_set "R_cli_$app" "FAILED"
  ck_mktemp_dir || { ck_fail "$app: cannot create a temp folder" "Check free space in ${TMPDIR:-/tmp}."; return 1; }
  tmp=$CK_REPLY
  zip="$tmp/$(ck_get "L_casset_$app")"
  fetch_asset "$app" cli "$zip" || return 1
  if ! zip_is_safe "$zip"; then
    ck_fail "$app: the zip contains absolute paths, '..' parts or symlinks; refused" "Do not use this file; please open an issue."
    return 1
  fi
  member=$(unzip -Z1 "$zip" | awk -v n="$app-cli" '{ b = $0; sub(/.*\//, "", b) } b == n')
  count=$(printf '%s' "$member" | grep -c . || true)
  if [ "$count" != 1 ]; then
    ck_fail "$app: expected exactly one $app-cli inside $(ck_get "L_casset_$app"), found $count" "The release layout changed; please open an issue."
    return 1
  fi
  case "$member" in *[!A-Za-z0-9._/+-]*) ck_fail "$app: unexpected file name inside the zip: $member"; return 1 ;; esac
  if ! unzip -q -o "$zip" "$member" -d "$tmp/x" || [ ! -f "$tmp/x/$member" ] || [ -L "$tmp/x/$member" ]; then
    ck_fail "$app: could not extract $member" "Check free space in ${TMPDIR:-/tmp} and re-run."
    return 1
  fi
  exe="$tmp/x/$member"
  rm -f "$zip"
  mkdir -p "$PREFIX" || { ck_fail "$app: cannot create $PREFIX"; return 1; }
  ck_mktemp_beside "$bin" || { ck_fail "$app: cannot write in $PREFIX" "Check its permissions or use --prefix DIR."; return 1; }
  stage=$CK_REPLY
  if ! cp "$exe" "$stage" || ! chmod 755 "$stage"; then
    rm -f "$stage"
    ck_fail "$app: cannot copy the program into $PREFIX" "Check free space and permissions."
    return 1
  fi
  out=$(ck_capture 60 "$stage" --version 2>&1) || true
  if ! ck_version_in "$out" "$ver"; then
    rm -f "$stage"
    ck_fail "$app: the downloaded program does not report version $ver (it said: $(ck_first_line "$out"))" "Please open an issue."
    return 1
  fi
  # A file the kit did not install is kept, never overwritten: it may be the user's own build of the
  # same name (B1-SUPPLY-2, R1-CONFIG-1).
  local kept=""
  if [ "$(ck_get "P_cli_$app")" = replace ] && { [ -e "$bin" ] || [ -L "$bin" ]; }; then
    if ! move_aside "$bin"; then
      rm -f "$stage"
      ck_fail "$app: cannot move the existing $bin aside, so it was left in place" "Move or delete it yourself, then re-run."
      return 1
    fi
    kept=$CK_REPLY
    BACKUP_NOTES="${BACKUP_NOTES}    $kept"$'\n'
  fi
  if ! mv -f "$stage" "$bin"; then
    rm -f "$stage"
    [ -z "$kept" ] || mv -f "$kept" "$bin" || true
    ck_fail "$app: cannot move the program into place at $bin"
    return 1
  fi
  ck_safe_rm_rf "$tmp" "$(dirname "$tmp")" || true
  ck_set "R_clisha_$app" "$(ck_sha256 "$bin" 2>/dev/null || true)"
  if [ "$(ck_get "P_cli_$app")" = upgrade ]; then
    ck_ok "$app-cli upgraded $(ck_get "P_clicur_$app") -> $ver ($bin)"
    ck_set "R_cli_$app" "upgraded"
  elif [ "$(ck_get "P_cli_$app")" = replace ]; then
    ck_ok "$app-cli $ver installed ($bin), replacing a copy the kit had not verified (kept as $kept)"
    ck_set "R_cli_$app" "replaced"
  else
    ck_ok "$app-cli $ver installed ($bin)"
    ck_set "R_cli_$app" "installed"
  fi
}

do_workspace() { # APP
  local d="$WORKSPACE/$1" sub
  if [ ! -d "$WORKSPACE" ]; then
    if ! { mkdir -p "$WORKSPACE" && chmod 700 "$WORKSPACE"; }; then
      ck_fail "cannot create $WORKSPACE" "Choose another folder with --workspace DIR."
      return 1
    fi
  fi
  for sub in "" /in /out; do
    if [ ! -d "$d$sub" ] && ! { mkdir -p "$d$sub" && chmod 700 "$d$sub"; }; then
      ck_fail "$1: cannot create $d$sub" "Check the permissions of $WORKSPACE."
      return 1
    fi
  done
  local f
  for f in "$WORKSPACE" "$d" "$d/in" "$d/out"; do
    is_loose "$f" || continue
    if chmod go-rwx "$f" 2>/dev/null; then ck_ok "made $f private (other users could open it)"
    else ck_warn "could not make $f private" "Run: chmod 700 $(ck_shquote "$f")"; fi
  done
}

fence_argv_ok() { # APP EXPECTED_JSON -> 0 if the argv really fences the server to WORKSPACE/APP
  printf '%s' "$2" | jq -e --arg f "$(ck_get "L_fence_$1")" --arg root "$WORKSPACE/$1" \
    --arg cli "$PREFIX/$1-cli" --arg wrap "$PREFIX/craft-sandbox" '
    # The fence flags must appear exactly once, at their fixed place, and never again (also not as
    # --flag=value) in the extra arguments: the CLIs honour the LAST occurrence.
    def fenceflag: . == "--root" or startswith("--root=") or startswith("--automation-");
    def clean($n): ([.args[$n:][] | select(fenceflag)] | length) == 0;
    if $f == "roots" then .command == $cli
      and .args[0:5] == ["mcp", "--automation-read-root", $root, "--automation-write-root", $root] and clean(5)
    elif $f == "root" then .command == $cli and .args[0:3] == ["mcp", "--root", $root] and clean(3)
    else .command == $wrap and .args[0:3] == [$root, $cli, "mcp"] and clean(3) end' >/dev/null 2>&1
}

claude_cmd() { # ARGS... -> runs the Claude Code CLI with a timeout; output in CK_REPLY
  local rc=0
  CK_REPLY=$(ck_capture 120 "$CLAUDE_BIN" "$@" 2>&1) || rc=$?
  ck_log "$CLAUDE_BIN $* -> exit $rc: $CK_REPLY"
  return "$rc"
}

current_registration() { # APP -> JSON in CK_REPLY, return 0 found, 1 none, 3 unreadable
  local rc=0
  if [ -n "$CLAUDE_CONFIG_ENV" ]; then
    CK_REPLY=$(craftkit registered --app "$1" --config-dir "$CLAUDE_CONFIG_ENV" 2>/dev/null) || rc=$?
  else
    CK_REPLY=$(craftkit registered --app "$1" 2>/dev/null) || rc=$?
  fi
  return "$rc"
}

# After a failed add, put the previous registration back (it was removed just before). Only its
# command and args are known (registered() normalises the entry), so env or other settings it
# had are not restored; the message says so.
restore_registration() { # APP CUR_JSON
  local app=$1 old_sh
  local -a old
  old_sh=$(printf '%s' "$2" | jq -r '[.command] + .args | @sh' 2>/dev/null) || old_sh=""
  if [ -n "$old_sh" ] && eval "old=($old_sh)" && claude_cmd mcp add -s user "$app" -- "${old[@]}"; then
    ck_warn "$app: restored your previous registration (command and arguments; any env settings it had are not restored)"
    return 0
  fi
  ck_warn "$app: could not restore the previous registration" \
    "Run: $CLAUDE_BIN mcp add -s user $app -- $(printf '%s' "$2" | jq -r '[.command] + .args | map(@sh) | join(" ")' 2>/dev/null)"
  return 1
}

# The registration as it is in the Claude Code config (all keys, env included), else the normalised
# command and args, saved to KIT_HOME/backup/<app>-mcp-<TS>.json (mode 600) before it is replaced.
save_registration() { # APP CUR_JSON -> path in CK_REPLY
  local app=$1 dir="$KIT_HOME/backup" f raw=""
  f="$dir/$app-mcp-$TS.json"
  [ ! -f "$CLAUDE_JSON" ] || raw=$(jq -e --arg a "$app" '.mcpServers[$a] // empty' "$CLAUDE_JSON" 2>/dev/null) || raw=""
  [ -n "$raw" ] || raw=$2
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  ( umask 077 && printf '%s\n' "$raw" >"$f" ) || return 1
  chmod 600 "$f" 2>/dev/null || true
  CK_REPLY=$f
  BACKUP_NOTES="${BACKUP_NOTES}    $f (the $app MCP registration before this run)"$'\n'
}

do_register() { # APP -> sets R_mcp_<app> and R_reg_<app> (true|false)
  local app=$1 fence exp argv_sh rc=0 cur=""
  local -a argv
  fence=$(ck_get "L_fence_$app")
  ck_set "R_reg_$app" false
  if [ "$DO_MCP" = 0 ]; then
    ck_set "R_mcp_$app" "skipped"
    ck_set "R_reg_$app" "$(ck_get "P_regok_$app")"
    return 0
  fi
  ck_set "R_mcp_$app" "FAILED"
  exp=$(ck_get "E_exp_$app")
  if [ -z "$exp" ]; then
    ck_fail "$app: cannot compute the registration: $(ck_get "P_mcpnote_$app")" "Run: python3 $KIT_DIR/lib/craftkit.py expected --app $app --workspace $WORKSPACE --prefix $PREFIX"
    return 1
  fi
  if ! fence_argv_ok "$app" "$exp"; then
    ck_fail "$app: the computed command line does not confine the server to $WORKSPACE/$app; NOT registered (fail-closed)" "Please open an issue with the output of ./install.sh --dry-run."
    return 1
  fi
  case "$fence" in
    roots | root)
      if ! fence_help_ok "$app"; then
        ck_fail "$app: $CK_REPLY, so the server cannot be confined; NOT registered (fail-closed)" \
          "This $app-cli version may have changed its options. Run $KIT_HOME/doctor.sh --app $app and please open an issue."
        current_registration "$app" && ck_warn "$app: an existing registration was left unchanged: $(printf '%s' "$CK_REPLY" | jq -r '[.command] + .args | join(" ")')"
        return 1
      fi
      ;;
    sandbox)
      if [ "$SANDBOX_OK" != 1 ] || [ ! -x "$PREFIX/craft-sandbox" ] || [ ! -f "$KIT_HOME/share/craft.sb" ]; then
        ck_fail "$app: the sandbox wrapper or its profile is missing; NOT registered (fail-closed)" "Fix the sandbox step above, then re-run."
        return 1
      fi
      ;;
  esac
  current_registration "$app" || rc=$?
  case "$rc" in
    0) cur=$CK_REPLY ;;
    1) ;;
    *) ck_fail "$app: cannot read $CLAUDE_JSON" "Make sure it is valid JSON (Claude Code writes it), then re-run."; return 1 ;;
  esac
  if [ -n "$cur" ] && [ "$cur" = "$exp" ]; then
    ck_skip "$app: MCP server already registered"
    ck_set "R_mcp_$app" "registered"
    ck_set "R_reg_$app" true
    return 0
  fi
  local regbak=""
  if [ -n "$cur" ]; then
    # Keep the full previous entry (env and all) before it is removed, in case it cannot be put back.
    if save_registration "$app" "$cur"; then regbak=$CK_REPLY; else
      ck_fail "$app: could not back up the current registration to $KIT_HOME/backup, so it was left unchanged" "Check that $KIT_HOME is writable, then re-run."
      return 1
    fi
    if ! claude_cmd mcp remove "$app" -s user; then
      ck_fail "$app: could not remove the old registration: $(printf '%s' "$CK_REPLY" | tail -n 1)" "Run: $CLAUDE_BIN mcp remove $app -s user   then re-run the installer."
      return 1
    fi
  fi
  argv_sh=$(printf '%s' "$exp" | jq -r '[.command] + .args | @sh') || { ck_fail "$app: bad registration JSON"; return 1; }
  eval "argv=($argv_sh)"
  if ! claude_cmd mcp add -s user "$app" -- "${argv[@]}"; then
    local why
    why=$(printf '%s' "$CK_REPLY" | tail -n 1)
    if [ -n "$cur" ] && ! restore_registration "$app" "$cur"; then
      ck_fail "$app: '$CLAUDE_BIN mcp add' failed: $why; your previous registration could not be restored" \
        "It is saved in $regbak (the entry as it was in $CLAUDE_JSON); add it back with $CLAUDE_BIN mcp add, then re-run."
      return 1
    fi
    ck_fail "$app: '$CLAUDE_BIN mcp add' failed: $why" "Run $CLAUDE_BIN --version to check Claude Code works, then re-run."
    return 1
  fi
  if ! current_registration "$app" || [ "$CK_REPLY" != "$exp" ]; then
    ck_fail "$app: the registration did not take effect in $CLAUDE_JSON" "If you use CLAUDE_CONFIG_DIR, make sure it is set the same way for Claude Code and this installer."
    return 1
  fi
  if [ -n "$cur" ]; then
    ck_ok "$app: MCP server re-registered (the previous command line differed)"
    ck_set "R_mcp_$app" "replaced"
  else
    ck_ok "$app: MCP server registered, confined to $WORKSPACE/$app ($fence)"
    ck_set "R_mcp_$app" "added"
  fi
  ck_set "R_reg_$app" true
}

step_apps() {
  local app ok
  for app in $APPS; do
    ck_head "$app $(ck_get "L_ver_$app")"
    ok=1
    ck_set "R_mcp_$app" "skipped"
    ck_set "R_reg_$app" false
    if do_cli "$app"; then
      if ! do_workspace "$app"; then
        ok=0
      elif ! do_register "$app"; then
        ok=0
      fi
    else
      ok=0
      ck_set "R_mcp_$app" "not attempted"
      [ "$DO_MCP" = 0 ] || ck_skip "$app: MCP registration skipped because the CLI is not installed"
    fi
    [ "$ok" = 1 ] || note_fail "$app" "$CK_LAST_FAIL"
  done
}

do_gui() { # APP
  local app=$1 bundle ver dest tmp dmg mnt src stage spctl_out
  bundle=$(ck_get "L_gbundle_$app"); ver=$(ck_get "L_ver_$app"); dest="$GUI_DIR/$bundle"
  ck_set "R_gui_$app" "FAILED"
  case "$(ck_get "P_gui_$app")" in
    skip) ck_skip "$bundle $ver already installed"; ck_set "R_gui_$app" "up to date"; return 0 ;;
    keep)
      ck_warn "$bundle is already in $GUI_DIR at version $(ck_get "P_guicur_$app"); left untouched (the kit pins $ver)" \
        "To switch: quit the app, move it to the Trash yourself, and re-run."
      ck_set "R_gui_$app" "kept $(ck_get "P_guicur_$app")"
      return 0
      ;;
    bad) ck_fail "$app: the lock has no usable desktop-app entry" "Restore manifest/apps.lock.json from the repository."; return 1 ;;
  esac
  if ! grep -Eq '^[0-9a-f]{64}$' <<<"$(ck_get "L_gsha_$app")" || ! grep -Eq '^[A-Za-z0-9._+-]+$' <<<"$(ck_get "L_gasset_$app")"; then
    ck_fail "$app: the lock has no usable SHA-256 or file name for the desktop app" "Restore manifest/apps.lock.json from the repository."
    return 1
  fi
  ck_mktemp_dir || { ck_fail "$app: cannot create a temp folder"; return 1; }
  tmp=$CK_REPLY
  dmg="$tmp/$(ck_get "L_gasset_$app")"
  fetch_asset "$app" gui "$dmg" || return 1
  mnt="$tmp/mnt"
  mkdir "$mnt" || return 1
  CK_MOUNTS+=("$mnt")
  if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
    ck_fail "$app: could not open the disk image" "Re-run; if it keeps failing, please open an issue."
    return 1
  fi
  src="$mnt/$bundle"
  if [ ! -d "$src" ] || [ -L "$src" ]; then
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
    ck_fail "$app: $bundle not found inside the disk image" "The release layout changed; please open an issue."
    return 1
  fi
  mkdir -p "$GUI_DIR" || { ck_fail "$app: cannot create $GUI_DIR"; return 1; }
  stage=$(mktemp -d "$GUI_DIR/.craft-kit.XXXXXX") || { ck_fail "$app: cannot write in $GUI_DIR" "Use --gui-dir ~/Applications."; return 1; }
  CK_TMP_DIRS+=("$stage")
  # Extended attributes (Finder info, resource forks) are not part of the seal and make codesign
  # --strict reject the copy ("detritus not allowed"); some release images carry them.
  if ! ditto --noextattr --norsrc "$src" "$stage/$bundle"; then
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
    ck_fail "$app: copying $bundle failed" "Check free space in $GUI_DIR."
    return 1
  fi
  hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1 || true
  local cs_err
  if ! cs_err=$(codesign --verify --deep --strict "$stage/$bundle" 2>&1); then
    ck_fail "$app: code signature check failed for $bundle; not installed (codesign: ${cs_err##*$'\n'})" "Do not use this copy; please open an issue."
    return 1
  fi
  if [ -e "$dest" ]; then
    ck_fail "$app: $dest appeared while installing; left untouched"
    return 1
  fi
  mv "$stage/$bundle" "$dest" || { ck_fail "$app: cannot move $bundle into $GUI_DIR"; return 1; }
  rmdir "$stage" 2>/dev/null || true
  if spctl --assess --type execute "$dest" >/dev/null 2>&1; then
    spctl_out="Gatekeeper accepts it"
  else
    spctl_out="Gatekeeper does not pre-approve it, so macOS may ask you to confirm the first launch"
  fi
  ck_ok "$bundle $ver installed in $GUI_DIR (signature intact per codesign; publisher not checked; $spctl_out)"
  ck_set "R_gui_$app" "installed"
  ck_set "R_guiown_$app" true
  ck_set "R_guiver_$app" "$(ck_bundle_version "$dest")"
  ck_safe_rm_rf "$tmp" "$(dirname "$tmp")" || true
}

step_gui() {
  [ "$GUI_MODE" = yes ] || return 0
  ck_head "Desktop apps in $GUI_DIR"
  local app t
  for t in hdiutil ditto codesign; do
    command -v "$t" >/dev/null 2>&1 || { ck_fail "$t is missing; desktop apps skipped"; note_fail - "desktop apps: $t missing"; return 0; }
  done
  for app in $APPS; do
    if ! do_gui "$app"; then
      note_fail "$app" "$CK_LAST_FAIL"
    fi
  done
  ck_cleanup_mounts
}

ck_cleanup_mounts() {
  local m
  for m in ${CK_MOUNTS[@]+"${CK_MOUNTS[@]}"}; do
    if [ -d "$m" ]; then hdiutil detach "$m" -quiet >/dev/null 2>&1 || true; fi
  done
  return 0
}

SKILLS_DONE="" SKILLS_SHA=""
step_skills() {
  [ "$DO_SKILLS" = 1 ] || return 0
  ck_head "Skills in $CLAUDE_DIR/skills"
  local name src dst out tmp backed_up existed
  ck_mktemp_dir || { ck_fail "cannot create a temp folder for the skills"; note_fail - "skills not installed"; return 0; }
  tmp=$CK_REPLY
  for name in $SK_NAMES; do
    src="$KIT_DIR/skills/$name/SKILL.md"
    dst="$CLAUDE_DIR/skills/$name/SKILL.md"
    if ck_in_list "$name" "$SK_LINK"; then
      ck_warn "$name: $CLAUDE_DIR/skills/$name is a symlink; left alone" "Remove the symlink and re-run to let the kit manage this skill."
      continue
    fi
    if ! out=$(craftkit render --workspace "$WORKSPACE" --kit-home "$KIT_HOME" --in "$src" --out "$tmp/$name.md" 2>&1); then
      ck_fail "$name: could not render: $out" "Update your checkout of the kit and re-run."
      note_fail - "skill $name not installed"
      continue
    fi
    if [ -f "$dst" ] && cmp -s "$tmp/$name.md" "$dst"; then
      ck_skip "$name up to date"
    else
      backed_up=0 existed=0
      [ ! -e "$dst" ] || existed=1
      if [ "$existed" = 1 ] && ! skill_is_ours "$name" "$dst"; then
        if ! cp -p "$dst" "$dst.bak-$TS"; then
          ck_fail "$name: cannot back up $dst; not replaced"
          note_fail - "skill $name not installed"
          continue
        fi
        backed_up=1
      fi
      if ! install_file "$tmp/$name.md" "$dst" 644; then
        ck_fail "$name: cannot write $dst" "Check the permissions of $CLAUDE_DIR/skills."
        note_fail - "skill $name not installed"
        continue
      fi
      if [ "$backed_up" = 1 ]; then ck_ok "$name updated (your previous copy: SKILL.md.bak-$TS)"
      elif [ "$existed" = 1 ]; then ck_ok "$name updated"
      else ck_ok "$name installed"; fi
    fi
    SKILLS_DONE="${SKILLS_DONE:+$SKILLS_DONE }$name"
    SKILLS_SHA="${SKILLS_SHA}${name} $(ck_sha256 "$dst")"$'\n'
  done
}

HOOKS_DONE=""

hook_needs_cleanup() { # SCRIPT CMD MATCHER -> 0 if settings has an entry for SCRIPT that differs
  [ -f "$SETTINGS" ] || return 1
  jq -e --arg s "$KIT_HOME/hooks/$1" --arg c "$2" --arg m "$3" '
    [.hooks.PreToolUse[]? | . as $e | .hooks[]? | (.command? // "") | strings
     | select(contains($s)) | select(. != $c or $e.matcher != $m)] | length > 0' "$SETTINGS" >/dev/null 2>&1
}

step_hooks() {
  [ "$DO_HOOKS" = 1 ] || return 0
  ck_head "Hooks in $SETTINGS"
  local script matcher cmd out
  out=$(settings_problem)
  if [ -n "$out" ]; then
    ck_fail "$SETTINGS cannot be edited safely, hooks not changed: $out" \
      "The kit edits it only as strict JSON (no comments, no trailing commas). Fix the spot named above, then re-run."
    note_fail - "hooks not installed"
    return 0
  fi
  mkdir -p "$CLAUDE_DIR" || { ck_fail "cannot create $CLAUDE_DIR"; note_fail - "hooks not installed"; return 0; }
  for script in "$CK_SHELL_HOOK" "$CK_MCP_HOOK"; do
    if [ "$script" = "$CK_SHELL_HOOK" ]; then matcher=$CK_SHELL_MATCHER; else matcher=$CK_MCP_MATCHER; fi
    cmd=$(ck_hook_command "$script" "$KIT_HOME" "$WORKSPACE")
    if [ ! -f "$KIT_HOME/hooks/$script" ]; then
      ck_fail "$script is missing from the kit; not registered" "Update your checkout of the kit (git pull) and re-run."
      note_fail - "hook $script not installed"
      continue
    fi
    # A hook command that cannot run would make Claude Code show errors on every tool call.
    if ! printf '{}' | python3 "$KIT_HOME/hooks/$script" --workspace "$WORKSPACE" >/dev/null 2>&1; then
      ck_fail "$script does not run with this python3 ($(python3 --version 2>&1)); not registered" "Check python3, then re-run."
      note_fail - "hook $script not installed"
      continue
    fi
    if hook_needs_cleanup "$script" "$cmd" "$matcher"; then
      if out=$(settings_edit remove-hook --settings "$SETTINGS" --event PreToolUse --command-contains "$KIT_HOME/hooks/$script" --backup-tag "$TS" 2>&1); then
        ck_ok "removed an outdated entry for $script"
      else
        ck_warn "could not remove an outdated entry for $script: $out"
      fi
    fi
    if out=$(settings_edit add-hook --settings "$SETTINGS" --event PreToolUse --matcher "$matcher" --command "$cmd" --timeout "$CK_HOOK_TIMEOUT" --backup-tag "$TS" 2>&1); then
      ck_log "settings_edit: $out"
      case "$out" in unchanged:*) ck_skip "$script already registered" ;; *) ck_ok "$script registered (matcher $matcher)" ;; esac
      HOOKS_DONE="${HOOKS_DONE}${matcher}"$'\x1f'"${cmd}"$'\n'
    else
      ck_fail "$script: could not update $SETTINGS: $(printf '%s' "$out" | tail -n 1)" "Fix the problem above, then re-run."
      note_fail - "hook $script not installed"
    fi
  done
  legacy_hook_cleanup
}

legacy_hook_cleanup() {
  local f="$HOME/$CK_LEGACY_HOOK_REL" out
  if ck_settings_has_hook "$SETTINGS" "/$CK_LEGACY_HOOK_REL"; then
    if out=$(settings_edit remove-hook --settings "$SETTINGS" --event PreToolUse --command-contains "/$CK_LEGACY_HOOK_REL" --backup-tag "$TS" 2>&1); then
      ck_ok "removed the older hand-made craft-shell-guard hook entry"
    else
      ck_warn "could not remove the older craft-shell-guard hook entry: $out" "Remove the entry that runs $f from $SETTINGS by hand."
      return 0
    fi
  fi
  if [ -f "$f" ] && ! ck_settings_has_hook "$SETTINGS" "/$CK_LEGACY_HOOK_REL"; then
    if ! legacy_hook_recognised "$f"; then
      ck_warn "kept $f: it does not look like the older craft-shell-guard hook" "Delete it yourself if it is a leftover."
    elif move_aside "$f"; then
      ck_ok "moved the older hook script aside to $CK_REPLY"
    fi
  fi
}

# ---------------------------------------------------------------------------------------------
# receipt and summary
# ---------------------------------------------------------------------------------------------
RECEIPT_PENDING=0

bool() { if [ "$1" = true ]; then echo true; else echo false; fi; }

# Is a part (mcp|skills|hooks) managed by the kit? Yes if this run did it; with --no-<part>, what the
# previous receipt says (older receipts: whether it recorded any). doctor.sh skips the parts left out.
component() { # NAME DO_FLAG
  if [ "$2" = 1 ]; then echo true; return 0; fi
  [ -n "$PREV_RECEIPT" ] || { echo false; return 0; }
  jq -r --arg c "$1" 'if (.components | type) == "object" and (.components[$c] | type) == "boolean" then .components[$c]
    elif $c == "skills" then ((.skills // []) | length > 0)
    elif $c == "hooks" then ((.hooks // []) | length > 0)
    else ([.apps[]?.registered] | any) end' "$PREV_RECEIPT" 2>/dev/null || echo false
}

write_receipt() {
  RECEIPT_PENDING=0
  [ -d "$KIT_HOME" ] || return 0
  local apps_json='{}' app entry cli clisha gui guiver reg prev_gui_dir skills_json sha_json hooks_json t name sum m c
  prev_gui_dir=$(prev_get .guiDir)
  for app in $LOCK_APPS; do
    # Apps this run did not reach (other --only selection, or interrupted) keep their old entry.
    if ck_in_list "$app" "$APPS" && { [ -n "$(ck_get "R_cli_$app")" ] || [ -z "$(prev_get '.apps[$a]' --arg a "$app")" ]; }; then
      # cli=true only for a file this kit wrote (or wrote earlier and that still has the bytes it
      # recorded); a program that was already there is never recorded as the kit's.
      cli=false clisha=""
      case "$(ck_get "R_cli_$app")" in
        installed | upgraded | replaced) cli=true; clisha=$(ck_get "R_clisha_$app") ;;
        *)
          clisha=$(prev_get '.apps[$a].cliSha256 | strings' --arg a "$app")
          if [ "$(prev_get ".apps[\$a].cli" --arg a "$app")" = true ] && [ -f "$PREFIX/$app-cli" ] \
            && [ -n "$clisha" ] && [ "$(ck_sha256 "$PREFIX/$app-cli" 2>/dev/null)" = "$clisha" ]; then cli=true; else clisha=""; fi
          ;;
      esac
      # gui=true only for a bundle the kit copied, still at the version it recorded then.
      gui=false guiver=""
      if [ "$(ck_get "R_guiown_$app")" = true ]; then gui=true; guiver=$(ck_get "R_guiver_$app")
      elif [ "$(prev_get ".apps[\$a].gui" --arg a "$app")" = true ] && [ "$prev_gui_dir" = "$GUI_DIR" ] \
        && [ -d "$GUI_DIR/$(ck_get "L_gbundle_$app")" ]; then
        guiver=$(prev_get '.apps[$a].guiVersion | strings' --arg a "$app")
        if [ -n "$guiver" ] && [ "$(ck_bundle_version "$GUI_DIR/$(ck_get "L_gbundle_$app")")" = "$guiver" ]; then gui=true; else guiver=""; fi
      fi
      reg=$(bool "$(ck_get "R_reg_$app")")
      entry=$(jq -cn --arg v "$(ck_get "L_ver_$app")" --arg f "$(ck_get "L_fence_$app")" \
        --argjson cli "$cli" --argjson gui "$gui" --argjson reg "$reg" --arg cs "$clisha" --arg gv "$guiver" \
        '{version: $v, fence: $f, cli: $cli, gui: $gui, registered: $reg}
         + (if $cs == "" then {} else {cliSha256: $cs} end) + (if $gv == "" then {} else {guiVersion: $gv} end)')
    else
      entry=$(prev_get "(.apps[\$a] // empty) | tojson" --arg a "$app")
      [ -n "$entry" ] || continue
    fi
    apps_json=$(printf '%s' "$apps_json" | jq -c --arg a "$app" --argjson e "$entry" '. + {($a): $e}')
  done
  if [ "$DO_SKILLS" = 1 ]; then
    skills_json=$(jq -cn --arg s "$SKILLS_DONE" '$s | split(" ") | map(select(length > 0))')
    sha_json='{}'
    while IFS=' ' read -r name sum; do
      [ -n "$name" ] || continue
      sha_json=$(printf '%s' "$sha_json" | jq -c --arg n "$name" --arg s "$sum" '. + {($n): $s}')
    done <<EOF
$SKILLS_SHA
EOF
  else
    skills_json=$(prev_get '(.skills // empty) | tojson'); [ -n "$skills_json" ] || skills_json='[]'
    sha_json=$(prev_get '(.skillsSha256 // empty) | tojson'); [ -n "$sha_json" ] || sha_json='{}'
  fi
  if [ "$DO_HOOKS" = 1 ]; then
    hooks_json='[]'
    while IFS=$'\x1f' read -r m c; do
      [ -n "$m" ] || continue
      hooks_json=$(printf '%s' "$hooks_json" | jq -c --arg m "$m" --arg c "$c" '. + [{matcher: $m, command: $c}]')
    done <<EOF
$HOOKS_DONE
EOF
  else
    hooks_json=$(prev_get '(.hooks // empty) | tojson'); [ -n "$hooks_json" ] || hooks_json='[]'
  fi
  # SHA-256 of the installed hook files, so doctor.sh can notice a later change (HOOK drift).
  local hsha='{}' hf
  if [ "$DO_HOOKS" = 1 ]; then
    for hf in "$CK_SHELL_HOOK" "$CK_MCP_HOOK" risky-tools.json; do
      [ -f "$KIT_HOME/hooks/$hf" ] || continue
      hsha=$(printf '%s' "$hsha" | jq -c --arg n "$hf" --arg s "$(ck_sha256 "$KIT_HOME/hooks/$hf")" '. + {($n): $s}')
    done
  else
    hsha=$(prev_get '(.hooksSha256 // empty) | tojson'); [ -n "$hsha" ] || hsha='{}'
  fi
  local cm cs ch kf
  cm=$(component mcp "$DO_MCP"); cs=$(component skills "$DO_SKILLS"); ch=$(component hooks "$DO_HOOKS")
  # Files of earlier versions stay on disk until uninstall, so the list is the union with the old one.
  kf=$({ printf '%s' "$KIT_FILES"; prev_get '(.kitFiles // [])[] | strings'; } | awk 'NF && !seen[$0]++' | sort \
    | jq -R . | jq -cs .) || kf='[]'
  ck_mktemp_beside "$KIT_HOME/receipt.json" || return 1
  t=$CK_REPLY
  if jq -n --arg kv "$KIT_VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$KIT_DIR" \
    --arg kh "$KIT_HOME" --arg ws "$WORKSPACE" --arg px "$PREFIX" --arg cd "$CLAUDE_DIR" \
    --arg cenv "$CLAUDE_CONFIG_ENV" --arg cj "$CLAUDE_JSON" --arg gd "$GUI_DIR" --arg lock "$LOCK" \
    --argjson apps "$apps_json" --argjson skills "$skills_json" --argjson sha "$sha_json" --argjson hooks "$hooks_json" \
    --argjson cm "$cm" --argjson cs "$cs" --argjson ch "$ch" --argjson hsha "$hsha" --argjson kf "$kf" \
    '{schema: 1, kitVersion: $kv, installedAt: $at, repoDir: $repo, kitHome: $kh, workspace: $ws,
      prefix: $px, claudeDir: $cd, claudeConfigDirEnv: (if $cenv == "" then null else $cenv end),
      claudeJson: $cj, guiDir: $gd, lock: $lock, apps: $apps, skills: $skills, skillsSha256: $sha,
      hooks: $hooks, hooksSha256: $hsha, components: {mcp: $cm, skills: $cs, hooks: $ch}, kitFiles: $kf}' >"$t" && chmod 644 "$t" && mv -f "$t" "$KIT_HOME/receipt.json"; then
    ck_log "receipt written: $KIT_HOME/receipt.json"
    return 0
  fi
  rm -f "$t"
  ck_fail "could not write $KIT_HOME/receipt.json" "uninstall.sh and doctor.sh need it; re-run the installer."
  return 1
}

print_summary() {
  local app ready=0 total=0
  ck_head "Summary"
  printf '%s  %s%s%s%s%s\n' "$CK_BOLD" "$(pad 13 APP)" "$(pad 18 'COMMAND-LINE APP')" "$(pad 18 'MCP SERVER')" "$([ "$GUI_MODE" = yes ] && printf 'DESKTOP APP')" "$CK_RESET"
  for app in $APPS; do
    total=$((total + 1))
    ck_in_list "$app" "$FAILED_APPS" || ready=$((ready + 1))
    printf '  %s%s%s%s%s%s\n' "$CK_BOLD" "$(pad 13 "$app")" "$CK_RESET" "$(ck_paint "$(pad 18 "$(ck_get "R_cli_$app")")")" "$(ck_paint "$(pad 18 "$(ck_get "R_mcp_$app")")")" \
      "$([ "$GUI_MODE" = yes ] && ck_paint "$(ck_get "R_gui_$app")")"
  done
  ck_log "summary: $ready of $total apps ready; failed: ${FAILED_APPS:-none}"
  local rc_col=$CK_GREEN
  [ "$ready" = "$total" ] || rc_col=$CK_RED
  printf '\n  %s%s of %s app(s) ready.%s' "$CK_BOLD$rc_col" "$ready" "$total" "$CK_RESET"
  [ "$DO_SKILLS" = 0 ] || printf ' Skills: %s of %s.' "$(count_words "$SKILLS_DONE")" "$(count_words "$SK_NAMES")"
  [ "$DO_HOOKS" = 0 ] || printf ' Hooks: %s of 2.' "$(printf '%s' "$HOOKS_DONE" | grep -c . || true)"
  printf '\n'
  local kh ws backup="$SETTINGS.bak-craft-kit-$TS"
  kh=$(ck_tilde "$KIT_HOME"); ws=$(ck_tilde "$WORKSPACE")
  [ ! -e "$backup" ] || printf '  settings.json as it was before this run: %s\n' "$(ck_tilde "$backup")"
  [ -z "$BACKUP_NOTES" ] || printf '  Kept as backups (yours; delete them when you no longer need them):\n%s' "$BACKUP_NOTES"
  if [ "$ANY_FAIL" = 1 ]; then
    printf '\n  %sSomething failed:%s\n%s' "$CK_RED" "$CK_RESET" "$FAIL_NOTES"
    printf '  Fix the problems above and run %s again: finished parts are skipped. Log: %s/install.log\n' "$(rerun_cmd)" "$(ck_tilde "$KIT_HOME")"
    printf '  Then check everything with: %s/doctor.sh\n' "$kh"
    return 0
  fi
  printf '\n  %sNext steps:%s\n' "$CK_BOLD" "$CK_RESET"
  cat <<EOF
    1. Open a NEW Claude Code session (servers and skills are loaded at start-up).
    2. Check everything: $kh/doctor.sh   (add --smoke to drive each server once)
    3. Put files for an app in $ws/<app>/in/ ; results go to $ws/<app>/out/
    4. To remove the kit later: $kh/uninstall.sh
EOF
}

# The command to run again; without a terminal (Claude Code's Bash tool) it needs --yes.
rerun_cmd() { if [ -t 0 ]; then printf '%s' "$SELF"; else printf '%s --yes' "$SELF"; fi; }

on_exit() {
  local rc=$?
  set +e
  ck_cleanup_mounts
  if [ "$RECEIPT_PENDING" = 1 ]; then write_receipt >/dev/null 2>&1; fi
  ck_cleanup
  exit "$rc"
}

on_signal() {
  trap - INT TERM
  printf '\n'
  ck_warn "Interrupted: cleaning up temporary files. Re-run $(rerun_cmd) to finish; completed steps are skipped."
  exit 130
}

confirm() {
  local answer
  if [ "$YES" = 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    printf '\nNot running in an interactive terminal, so nothing was changed.\n' >&2
    printf 'To install as planned, run: %s --yes\n' "$SELF" >&2
    exit 4
  fi
  printf '\nInstall now? [y/N] : '
  IFS= read -r answer || answer=""
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    "" | n | N | no | NO | No) printf 'Nothing was changed.\n'; exit 4 ;;
    *) printf 'Did not understand "%s", so this is taken as No. Nothing was changed.\n' "$answer"; exit 4 ;;
  esac
}

main() {
  ck_color_init
  parse_args "$@"
  ck_refuse_root "$PROG"
  CLAUDE_BIN=${CLAUDE_BIN:-claude}
  check_tools
  if [ -n "$PROBLEMS" ]; then
    printf 'Cannot install yet:\n%s' "$PROBLEMS" >&2
    exit 3
  fi
  resolve_settings
  load_lock
  [ -n "$PROBLEMS" ] || select_apps
  check_locations
  if [ -n "$PROBLEMS" ]; then
    printf 'Cannot install yet:\n%s' "$PROBLEMS" >&2
    exit 3
  fi

  trap on_exit EXIT
  trap on_signal INT TERM

  plan_all
  local plan_text
  plan_text=$(print_plan)
  printf '%s\n' "$plan_text"
  if [ "$DRY_RUN" = 1 ]; then
    printf '\nDry run: nothing was changed.\n'
    return 0
  fi
  confirm
  if [ "$GUI_MODE" = yes ]; then
    local app
    for app in $APPS; do [ -n "$(ck_get "P_gui_$app")" ] && [ "$(ck_get "P_gui_$app")" != off ] || gui_state "$app"; done
    ck_writable_or_creatable "$GUI_DIR" || { ck_fail "cannot write $GUI_DIR" "Use --gui-dir ~/Applications."; GUI_MODE=no; note_fail - "desktop apps: $GUI_DIR not writable"; }
  fi

  mkdir -p "$KIT_HOME" || ck_die 1 "Cannot create $KIT_HOME." "Check its permissions or set CRAFT_KIT_HOME."
  CK_LOG_FILE="$KIT_HOME/install.log"
  ck_log "=== install.sh $KIT_VERSION ($ARGS_TEXT) from $KIT_DIR; desktop apps: $GUI_MODE"
  printf '%s\n' "$plan_text" | sed $'s/\033\\[[0-9;]*m//g' >>"$CK_LOG_FILE" 2>/dev/null || true
  RECEIPT_PENDING=1
  if [ "$DO_MCP" = 1 ] || [ "$DO_SKILLS" = 1 ] || [ "$DO_HOOKS" = 1 ]; then
    mkdir -p "$CLAUDE_DIR" || ck_warn "cannot create $CLAUDE_DIR" "Check its permissions."
  fi

  step_runtime
  step_apps
  step_gui
  step_skills
  step_hooks
  write_receipt || ANY_FAIL=1
  print_summary
  [ "$ANY_FAIL" = 0 ] || return 1
  return 0
}

main "$@"
