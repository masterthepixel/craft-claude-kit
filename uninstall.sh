#!/usr/bin/env bash
# uninstall.sh: remove what craft-claude-kit installed, using the receipt the installer wrote.
#
#   ~/.local/share/craft-claude-kit/uninstall.sh            show what will be removed, ask once
#   ~/.local/share/craft-claude-kit/uninstall.sh --dry-run  show it only
#
# It removes only what the kit owns: MCP registrations whose command points into the kit's folders,
# the kit's skills (unless you edited them), its hook entries, craft-sandbox, the CLIs, desktop apps
# only with --remove-gui (moved to the Trash), and finally the kit folder. It NEVER deletes your
# workspace. Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

src=${BASH_SOURCE[0]}
while [ -h "$src" ]; do
  dir=$(cd -P "$(dirname "$src")" && pwd -P)
  src=$(readlink "$src")
  case $src in /*) ;; *) src=$dir/$src ;; esac
done
KIT_DIR=$(cd -P "$(dirname "$src")" && pwd -P)
# shellcheck source=lib/common.sh
. "$KIT_DIR/lib/common.sh"

PROG=uninstall.sh
TS=$(date +%Y%m%d-%H%M%S)
YES=0 DRY_RUN=0 KEEP_CLI=0 REMOVE_GUI=0 KEEP_SKILLS=0 KEEP_HOOKS=0 OPT_PREFIX=""

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

Removes what craft-claude-kit installed, as recorded in its receipt. Shows the list first and asks
once. Your workspace folder is never deleted.

If the kit folder is gone (deleted by hand), run it from your clone of the kit: it then looks for
what the kit left behind and removes its hook entries, its craft-sandbox wrapper and the MCP
registrations that run through that wrapper. It lists, with the commands to remove them, the
other Craft MCP registrations, skills and programs it cannot attribute to the kit without the
receipt. The <app>-cli folder is taken from the registrations; pass --prefix DIR if it is not.

Options:
  -y, --yes        do not ask
      --dry-run    show what would be removed; change nothing
      --keep-cli   keep the <app>-cli programs
      --remove-gui also move the desktop apps the kit installed to the Trash
      --keep-skills  keep the craft-* skills
      --keep-hooks   keep the two hooks (and the scripts they run)
      --prefix DIR only when the kit folder is gone: where the <app>-cli programs and
                   craft-sandbox are (default: taken from the MCP registrations, else ~/.local/bin)
  -h, --help       show this help

Environment: CRAFT_KIT_HOME (kit folder, default ~/.local/share/craft-claude-kit),
CLAUDE_BIN (Claude Code command, default: claude), NO_COLOR.

Exit codes: 0 ok, 1 something could not be removed, 2 usage error, 3 no usable receipt,
            4 declined (or not interactive and no --yes).
EOF
}

usage_error() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Run uninstall.sh --help to see the options.\n' >&2
  exit 2
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --keep-cli) KEEP_CLI=1 ;;
      --remove-gui) REMOVE_GUI=1 ;;
      --keep-skills) KEEP_SKILLS=1 ;;
      --keep-hooks | --keep-hook) KEEP_HOOKS=1 ;;
      --prefix)
        [ $# -ge 2 ] && [ -n "$2" ] || usage_error "--prefix needs a value"
        OPT_PREFIX=$2
        shift
        ;;
      --prefix=*) OPT_PREFIX=${1#*=}; [ -n "$OPT_PREFIX" ] || usage_error "--prefix needs a value" ;;
      -h | --help) usage; exit 0 ;;
      --version) printf 'craft-claude-kit %s\n' "$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)"; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------------------------
# receipt: trusted only after every path in it is checked
# ---------------------------------------------------------------------------------------------
RECEIPT=""
rget() { jq -r "$@" "$RECEIPT"; }

# A directory the receipt names must be absolute, normalised, free of control characters and not a
# system or top-level folder. Deletions then only ever target fixed names inside these folders.
check_dir() { # LABEL PATH
  local p=$2 bad=""
  if [ -z "$p" ] || [ "$p" = null ]; then bad="is missing"
  elif ck_bad_path_chars "$p"; then bad="contains control characters"
  else
    case "$p" in /*) ;; *) bad="is not an absolute path" ;; esac
    if [ -z "$bad" ] && [ "$(ck_abspath "$p")" != "$p" ]; then bad="is not a normalised path"; fi
    case "$p" in
      / | /System | /System/* | /Library | /bin | /sbin | /usr | /usr/bin | /usr/sbin | /etc | /private | /private/etc | /var | /tmp | /Users | /Volumes | /opt)
        bad="is a system folder" ;;
    esac
    [ "$p" != "$HOME_REAL" ] || bad="is your home folder itself"
  fi
  [ -z "$bad" ] && return 0
  RECEIPT_ERRORS="${RECEIPT_ERRORS}  - $1 ($p) $bad"$'\n'
  return 1
}

load_receipt() {
  RECEIPT_ERRORS=""
  if ! jq -e '.schema == 1 and (.apps | type) == "object"' "$RECEIPT" >/dev/null 2>&1; then
    RECEIPT_ERRORS="  - not a schema-1 receipt (or not valid JSON)"$'\n'
    return 1
  fi
  R_KIT_HOME=$(rget '.kitHome // empty')
  R_WORKSPACE=$(rget '.workspace // empty')
  PREFIX=$(rget '.prefix // empty')
  CLAUDE_DIR=$(rget '.claudeDir // empty')
  GUI_DIR=$(rget '.guiDir // empty')
  CLAUDE_CONFIG_ENV=$(rget '.claudeConfigDirEnv // empty')
  check_dir prefix "$PREFIX" || true
  check_dir claudeDir "$CLAUDE_DIR" || true
  [ -z "$R_WORKSPACE" ] || check_dir workspace "$R_WORKSPACE" || true
  [ -z "$CLAUDE_CONFIG_ENV" ] || check_dir claudeConfigDirEnv "$CLAUDE_CONFIG_ENV" || true
  if [ "$REMOVE_GUI" = 1 ]; then check_dir guiDir "$GUI_DIR" || true; fi
  if [ -n "$R_KIT_HOME" ] && [ "$R_KIT_HOME" != "$KIT_HOME" ]; then
    # This script finds its folder with cd -P (symlinks resolved); the receipt keeps the path the
    # installer used (for example through a symlinked ~/.local). The same folder is fine, and the
    # receipt's spelling is the one the hook entries in settings.json use.
    if ! ck_bad_path_chars "$R_KIT_HOME" && [ -d "$R_KIT_HOME" ] && [ "$R_KIT_HOME" -ef "$KIT_HOME" ]; then
      KIT_HOME=$R_KIT_HOME
    else
      RECEIPT_ERRORS="${RECEIPT_ERRORS}  - it was written for the kit folder $R_KIT_HOME, not $KIT_HOME"$'\n'
    fi
  fi
  # The kit folder's fixed names (bin, share, hooks, ...) are removed at the end; a receipt whose
  # kit folder is or contains another folder the kit used would make that delete user data.
  local label p
  for label in prefix claudeDir workspace; do
    case $label in prefix) p=$PREFIX ;; claudeDir) p=$CLAUDE_DIR ;; *) p=$R_WORKSPACE ;; esac
    [ -n "$p" ] || continue
    case "$p/" in "$KIT_HOME"/*) RECEIPT_ERRORS="${RECEIPT_ERRORS}  - its $label ($p) is the kit folder or inside it; removing the kit folder would delete it"$'\n' ;; esac
  done
  local bad
  bad=$(jq -r '
    (.apps | to_entries[] | select((.key | test("^[a-z][a-z0-9]*$") | not)
       or ((.value | type) != "object")) | "app entry \(.key)"),
    ((.skills // []) | if type != "array" then "skills" else .[] | select((type != "string")
       or (test("^craft-[a-z0-9]+$") | not)) | "skill \(.)" end),
    ((.skillsSha256 // {}) | if type != "object" then "skillsSha256" else empty end),
    ((.kitFiles // []) | if type != "array" then "kitFiles" else .[] | select((type != "string")
       or (test("^((lib|manifest|data|tests|hooks|share|bin)(/[A-Za-z0-9_.+-]+)+|doctor\\.sh|uninstall\\.sh|VERSION)$") | not)
       or (split("/") | any(. == ".." or . == "."))) | "kit file \(.)" end)' "$RECEIPT" 2>&1) || bad="unreadable"
  [ -z "$bad" ] || RECEIPT_ERRORS="${RECEIPT_ERRORS}  - unexpected entries: $(printf '%s' "$bad" | tr '\n' ' ')"$'\n'
  [ -z "$RECEIPT_ERRORS" ]
}

# shellcheck disable=SC2016  # $a, $f, $n are jq variables
receipt_flag() { # APP FIELD -> true|false
  [ "$(rget --arg a "$1" --arg f "$2" '.apps[$a][$f] // false')" = true ] && echo true || echo false
}

# ---------------------------------------------------------------------------------------------
# what the kit owns
# ---------------------------------------------------------------------------------------------
LOCK_FILE=""
lock_bundle() { # APP -> bundle name from the kit's lock, validated against the app name
  local b
  [ -n "$LOCK_FILE" ] || return 1
  b=$(jq -r --arg a "$1" '.apps[$a].gui.bundle // empty' "$LOCK_FILE" 2>/dev/null) || return 1
  case "$b" in */* | .* | "") return 1 ;; esac
  [ "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" = "$1.app" ] || return 1
  printf '%s\n' "$b"
}

craftkit() { python3 -I "$KIT_DIR/lib/craftkit.py" "$@"; }
settings_edit() { python3 -I "$KIT_DIR/lib/settings_edit.py" "$@"; }

registration_of() { # APP -> JSON in CK_REPLY ; 0 found, 1 none, other unreadable
  local rc=0
  if [ -n "$CLAUDE_CONFIG_ENV" ]; then
    CK_REPLY=$(craftkit registered --app "$1" --config-dir "$CLAUDE_CONFIG_ENV" 2>/dev/null) || rc=$?
  else
    CK_REPLY=$(craftkit registered --app "$1" 2>/dev/null) || rc=$?
  fi
  return "$rc"
}

reg_is_kits() { # APP JSON -> 0 if the command points into PREFIX/KIT_HOME
  local cmd
  cmd=$(printf '%s' "$2" | jq -r '.command // empty')
  case "$cmd" in
    "$PREFIX/$1-cli" | "$PREFIX/craft-sandbox" | "$KIT_HOME"/*) return 0 ;;
  esac
  return 1
}

hooks_referenced() { # 0 if settings.json still runs a script from KIT_HOME/hooks (or cannot be read)
  local s="$CLAUDE_DIR/settings.json"
  [ -e "$s" ] || return 1
  ck_settings_parses "$s" || return 0
  ck_settings_has_hook "$s" "$KIT_HOME/hooks/"
}

skill_path() { printf '%s/skills/%s/SKILL.md\n' "$CLAUDE_DIR" "$1"; }

skill_state() { # NAME -> remove|modified|absent|link
  local dst want
  dst=$(skill_path "$1")
  if [ -L "$CLAUDE_DIR/skills/$1" ] || [ -L "$dst" ]; then echo link; return 0; fi
  [ -f "$dst" ] || { echo absent; return 0; }
  # shellcheck disable=SC2016
  want=$(rget --arg n "$1" '.skillsSha256[$n] // empty')
  if [ -z "$want" ] || [ "$(ck_sha256 "$dst")" = "$want" ]; then echo remove; else echo modified; fi
}

# ---------------------------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------------------------
MCP_REMOVE="" MCP_KEEP="" MCP_UNREADABLE=0 SKILLS_REMOVE="" SKILLS_KEEP="" CLI_REMOVE="" GUI_REMOVE="" GUI_RUNNING=""
CLI_CHANGED="" GUI_CHANGED="" MCP_LEFT=""
HOOKS_REMOVE="" WRAPPER_REMOVE=0

# Is the bundle no longer the version the kit installed (receipt guiVersion)? Receipts written
# before guiVersion existed cannot tell, so those bundles count as replaced and are kept.
gui_replaced() { # APP BUNDLE_PATH
  local want
  want=$(rget --arg a "$1" '.apps[$a].guiVersion // empty')
  [ -z "$want" ] || [ "$(ck_bundle_version "$2")" != "$want" ]
}

plan() {
  local app rc name f b all want
  all=$({ tr ' ' '\n' <<<"$CK_APPS_ALL"; rget '.apps | keys[]'; } | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  for app in $all; do
    rc=0
    registration_of "$app" || rc=$?
    case "$rc" in
      0) if reg_is_kits "$app" "$CK_REPLY"; then MCP_REMOVE="${MCP_REMOVE:+$MCP_REMOVE }$app"; else MCP_KEEP="${MCP_KEEP:+$MCP_KEEP }$app"; fi ;;
      1) ;;
      *) MCP_UNREADABLE=1 ;;
    esac
    if [ "$KEEP_CLI" = 0 ] && [ "$(receipt_flag "$app" cli)" = true ] && [ -f "$PREFIX/$app-cli" ]; then
      # Only the exact file the kit installed (receipt cliSha256); a program replaced since is kept.
      want=$(rget --arg a "$app" '.apps[$a].cliSha256 // empty')
      if [ -n "$want" ] && [ "$(ck_sha256 "$PREFIX/$app-cli" 2>/dev/null)" = "$want" ]; then
        CLI_REMOVE="${CLI_REMOVE:+$CLI_REMOVE }$app"
      else
        CLI_CHANGED="${CLI_CHANGED:+$CLI_CHANGED }$app"
      fi
    fi
    if [ "$REMOVE_GUI" = 1 ] && [ "$(receipt_flag "$app" gui)" = true ] && b=$(lock_bundle "$app") && [ -d "$GUI_DIR/$b" ] \
      && ! gui_replaced "$app" "$GUI_DIR/$b"; then
      if pgrep -f "$GUI_DIR/$b/Contents/MacOS/" >/dev/null 2>&1; then
        GUI_RUNNING="${GUI_RUNNING:+$GUI_RUNNING }$b"
      else
        GUI_REMOVE="${GUI_REMOVE:+$GUI_REMOVE }$app"
      fi
    elif [ "$REMOVE_GUI" = 1 ] && [ "$(receipt_flag "$app" gui)" = true ] && b=$(lock_bundle "$app") && [ -d "$GUI_DIR/$b" ]; then
      GUI_CHANGED="${GUI_CHANGED:+$GUI_CHANGED }$b"
    fi
  done
  if [ "$KEEP_SKILLS" = 0 ]; then
    for name in $(rget '(.skills // [])[]'); do
      case "$(skill_state "$name")" in
        remove) SKILLS_REMOVE="${SKILLS_REMOVE:+$SKILLS_REMOVE }$name" ;;
        modified | link) SKILLS_KEEP="${SKILLS_KEEP:+$SKILLS_KEEP }$name" ;;
      esac
    done
  fi
  if [ "$KEEP_HOOKS" = 0 ]; then
    for f in "$CK_SHELL_HOOK" "$CK_MCP_HOOK"; do
      ! ck_settings_has_hook "$CLAUDE_DIR/settings.json" "$KIT_HOME/hooks/$f" || HOOKS_REMOVE="${HOOKS_REMOVE:+$HOOKS_REMOVE }$f"
    done
  fi
  if grep -qF "$CK_WRAPPER_MARKER" "$PREFIX/craft-sandbox" 2>/dev/null; then WRAPPER_REMOVE=1; fi
}

count_words() { local n=0 w; for w in $1; do [ -z "$w" ] || n=$((n + 1)); done; echo "$n"; }

print_plan() {
  local ws_size=""
  printf '%scraft-claude-kit: uninstall plan%s  (receipt %s, installed %s)\n\n' "$CK_BOLD" "$CK_RESET" \
    "$(ck_tilde "$RECEIPT")" "$(rget '.installedAt // "?"')"
  printf '  Will remove:\n'
  [ -z "$MCP_REMOVE" ] || printf '    MCP servers (user scope, via "%s mcp remove"): %s\n' "$(ck_tilde "$CLAUDE_BIN")" "$MCP_REMOVE"
  [ -z "$HOOKS_REMOVE" ] || printf '    hook entries in %s (backup first): %s\n' "$(ck_tilde "$CLAUDE_DIR/settings.json")" "$HOOKS_REMOVE"
  [ -z "$SKILLS_REMOVE" ] || printf '    %s skill(s) in %s: %s\n' "$(count_words "$SKILLS_REMOVE")" "$(ck_tilde "$CLAUDE_DIR/skills")" "$SKILLS_REMOVE"
  [ -z "$CLI_REMOVE" ] || printf '    %s program(s) in %s: %s\n' "$(count_words "$CLI_REMOVE")" "$(ck_tilde "$PREFIX")" "$(for a in $CLI_REMOVE; do printf '%s-cli ' "$a"; done)"
  [ "$WRAPPER_REMOVE" = 0 ] || printf '    %s\n' "$(ck_tilde "$PREFIX/craft-sandbox")"
  [ -z "$GUI_REMOVE" ] || printf '    desktop apps in %s (moved to the Trash): %s\n' "$(ck_tilde "$GUI_DIR")" "$(for a in $GUI_REMOVE; do printf '%s ' "$(lock_bundle "$a")"; done)"
  printf '    the kit folder %s and what the kit put in it:%s\n' "$(ck_tilde "$KIT_HOME")" \
    "$(for e in doctor.sh uninstall.sh VERSION install.log receipt.json lib manifest data tests hooks share bin; do
         if [ -e "$KIT_HOME/$e" ] || [ -L "$KIT_HOME/$e" ]; then printf ' %s' "$e"; fi
       done)"
  printf '\n  Will keep:\n'
  if [ -n "$R_WORKSPACE" ]; then
    [ ! -d "$R_WORKSPACE" ] || ws_size=$(du -sh "$R_WORKSPACE" 2>/dev/null | awk '{print $1}')
    printf '    your workspace %s%s: never deleted\n' "$(ck_tilde "$R_WORKSPACE")" "${ws_size:+ ($ws_size)}"
  fi
  [ -z "$MCP_KEEP" ] || printf '    MCP servers that do not point into the kit (not created by it): %s\n' "$MCP_KEEP"
  [ -z "$SKILLS_KEEP" ] || printf '    skills you changed after install, or symlinked: %s\n' "$SKILLS_KEEP"
  [ -z "$CLI_CHANGED" ] || printf '    programs you replaced since install (or older receipts without a SHA-256): %s\n' "$(for a in $CLI_CHANGED; do printf '%s-cli ' "$a"; done)"
  [ -z "$GUI_CHANGED" ] || printf '    desktop apps replaced since the kit installed them (or not recorded): %s\n' "$GUI_CHANGED"
  [ "$KEEP_CLI" = 0 ] || printf '    the <app>-cli programs (--keep-cli)\n'
  [ "$KEEP_SKILLS" = 0 ] || printf '    the skills (--keep-skills)\n'
  [ "$KEEP_HOOKS" = 0 ] || printf '    the hooks and %s (--keep-hooks)\n' "$(ck_tilde "$KIT_HOME/hooks")"
  if [ "$REMOVE_GUI" = 0 ]; then
    printf '    desktop apps (pass --remove-gui to move the ones the kit installed to the Trash)\n'
  fi
  [ -z "$GUI_RUNNING" ] || printf '    desktop apps that are running now (quit them first): %s\n' "$GUI_RUNNING"
  [ "$MCP_UNREADABLE" = 0 ] || printf '\n  %sWARN%s  could not read the Claude Code MCP config; registrations will be left alone.\n' "$CK_YELLOW" "$CK_RESET"
  if [ -n "$MCP_REMOVE" ] && ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    printf '\n  %sWARN%s  %s not found: the MCP registrations cannot be removed automatically.\n' "$CK_YELLOW" "$CK_RESET" "$CLAUDE_BIN"
  fi
}

# ---------------------------------------------------------------------------------------------
# removal steps
# ---------------------------------------------------------------------------------------------
ANY_FAIL=0
fail() { ANY_FAIL=1; ck_fail "$@"; }

step_mcp() {
  [ -n "$MCP_REMOVE" ] || return 0
  ck_head "MCP servers"
  local app out
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    fail "Claude Code CLI not found ($CLAUDE_BIN); registrations left in place" \
      "Remove them yourself: $(for app in $MCP_REMOVE; do printf 'claude mcp remove %s -s user; ' "$app"; done | sed 's/; $//')"
    return 0
  fi
  for app in $MCP_REMOVE; do
    if out=$(ck_capture 120 "$CLAUDE_BIN" mcp remove "$app" -s user 2>&1); then
      ck_log "$CLAUDE_BIN mcp remove $app: $out"
      ck_ok "$app: MCP server removed"
    else
      fail "$app: '$CLAUDE_BIN mcp remove $app -s user' failed: $(ck_first_line "$out")" "Run that command yourself."
    fi
  done
}

step_hooks() {
  [ -n "$HOOKS_REMOVE" ] || return 0
  ck_head "Hooks"
  local f out
  for f in $HOOKS_REMOVE; do
    if out=$(settings_edit remove-hook --settings "$CLAUDE_DIR/settings.json" --event PreToolUse --command-contains "$KIT_HOME/hooks/$f" --backup-tag "$TS" 2>&1); then
      ck_log "settings_edit: $out"
      ck_ok "$f hook entry removed"
    else
      fail "$f: could not edit $CLAUDE_DIR/settings.json: $(ck_first_line "$out")" "Remove the PreToolUse entry that runs $KIT_HOME/hooks/$f by hand."
    fi
  done
}

step_skills() {
  [ -n "$SKILLS_REMOVE$SKILLS_KEEP" ] || return 0
  ck_head "Skills"
  local name dst
  for name in $SKILLS_REMOVE; do
    dst=$(skill_path "$name")
    if rm -f "$dst"; then
      rmdir "$CLAUDE_DIR/skills/$name" 2>/dev/null || true
      ck_ok "$name removed"
    else
      fail "$name: could not remove $dst"
    fi
  done
  for name in $SKILLS_KEEP; do
    ck_warn "$name kept: it was changed after install (or is a symlink)" "Delete $CLAUDE_DIR/skills/$name yourself if you no longer want it."
  done
}

step_gui() {
  [ -n "$GUI_REMOVE$GUI_RUNNING" ] || return 0
  ck_head "Desktop apps"
  local app b dest trash="$HOME/.Trash"
  for app in $GUI_REMOVE; do
    b=$(lock_bundle "$app") || continue
    dest="$trash/$b"
    [ ! -e "$dest" ] || dest="$trash/${b%.app} $TS.app"
    if mkdir -p "$trash" && mv "$GUI_DIR/$b" "$dest"; then
      ck_ok "$b moved to the Trash"
    else
      fail "$b: could not move it to the Trash" "Quit it and drag $GUI_DIR/$b to the Trash yourself."
    fi
  done
  for b in $GUI_RUNNING; do
    ck_warn "$b is running; left in place" "Quit it, then drag $GUI_DIR/$b to the Trash."
  done
}

step_programs() {
  [ -n "$CLI_REMOVE" ] || [ "$WRAPPER_REMOVE" = 1 ] || return 0
  ck_head "Programs in $PREFIX"
  local app f
  for app in $CLI_REMOVE; do
    if rm -f "$PREFIX/$app-cli"; then ck_ok "$app-cli removed"; else fail "could not remove $PREFIX/$app-cli"; fi
  done
  if [ "$WRAPPER_REMOVE" = 1 ]; then
    if rm -f "$PREFIX/craft-sandbox"; then ck_ok "craft-sandbox removed"; else fail "could not remove $PREFIX/craft-sandbox"; fi
  fi
  # Leftovers of an interrupted install (atomic-install temp files carry this exact prefix).
  for f in "$PREFIX"/.craft-kit.??????; do
    if [ -f "$f" ]; then rm -f "$f"; fi
  done
  return 0
}

step_kit_home() {
  ck_head "Kit folder $KIT_HOME"
  local keep="" e
  if [ "$KEEP_HOOKS" = 1 ] || hooks_referenced; then keep="hooks"; fi
  # Keep what is needed to run this uninstaller again if something is left to do.
  if [ -n "$keep" ] || [ "$ANY_FAIL" = 1 ]; then keep="$keep receipt.json uninstall.sh lib manifest VERSION"; fi
  # The receipt lists every file the installer copied (kitFiles); only those are removed from the kit's
  # folders, so a file you added there is kept (B1-CONFIG-1). Older receipts without the list fall back
  # to removing the fixed folders whole.
  local listed f extra=""
  listed=$(rget '(.kitFiles // [])[]' 2>/dev/null) || listed=""
  for e in doctor.sh uninstall.sh VERSION install.log receipt.json lib manifest data tests hooks share bin; do
    if ck_in_list "$e" "$keep"; then continue; fi
    [ -e "$KIT_HOME/$e" ] || [ -L "$KIT_HOME/$e" ] || continue
    if [ -z "$listed" ] || [ ! -d "$KIT_HOME/$e" ] || [ -L "$KIT_HOME/$e" ]; then
      ck_safe_rm_rf "$KIT_HOME/$e" "$KIT_HOME" || fail "could not remove $KIT_HOME/$e"
      continue
    fi
    while IFS= read -r f; do
      case "$f" in "$e"/?*) ;; *) continue ;; esac
      if [ -f "$KIT_HOME/$f" ] || [ -L "$KIT_HOME/$f" ]; then rm -f "$KIT_HOME/$f" || fail "could not remove $KIT_HOME/$f"; fi
    done <<EOF
$listed
EOF
    # Python's byte-code caches are made by running the kit's own scripts.
    find "$KIT_HOME/$e" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
    find "$KIT_HOME/$e" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
    if [ -e "$KIT_HOME/$e" ]; then
      extra="$extra$(cd "$KIT_HOME" && find "$e" ! -type d | head -n 20)"$'\n'
    fi
  done
  for e in "$KIT_HOME"/.craft-kit.??????; do
    if [ -e "$e" ]; then ck_safe_rm_rf "$e" "$KIT_HOME" || true; fi
  done
  if rmdir "$KIT_HOME" 2>/dev/null; then
    ck_ok "kit folder removed"
  elif [ -n "$keep" ]; then
    ck_warn "kept $KIT_HOME (${keep# }) so the uninstaller can be run again" \
      "When you are ready, run $KIT_HOME/uninstall.sh again$([ "$KEEP_HOOKS" = 1 ] && printf ' without --keep-hooks')."
  elif [ -n "$(printf '%s' "$extra" | tr -d '[:space:]')" ]; then
    ck_warn "kept $KIT_HOME: it contains files the kit did not install:$(printf '%s' "$extra" | awk 'NF { printf "\n      %s", $0 }')" \
      "Look at them and delete the folder yourself when done."
  else
    ck_warn "kept $KIT_HOME: it contains files the kit did not create (for example backup/, the MCP registrations it replaced)" \
      "Look inside and delete it yourself when done."
  fi
}

# ---------------------------------------------------------------------------------------------
# no kit folder: find and remove what a deleted kit left behind
# ---------------------------------------------------------------------------------------------
# The folder of the <app>-cli programs, taken from the registrations when they agree.
derive_prefix() {
  local app cmd d first="" many=0
  for app in $CK_APPS_ALL; do
    registration_of "$app" || continue
    cmd=$(printf '%s' "$CK_REPLY" | jq -r '.command // empty')
    case "$(basename "$cmd")" in "$app-cli" | craft-sandbox) ;; *) continue ;; esac
    d=$(dirname "$cmd")
    if [ -z "$first" ]; then first=$d; elif [ "$d" != "$first" ]; then many=1; fi
  done
  if [ -z "$first" ] || [ "$many" = 1 ]; then ck_abspath "$HOME/.local/bin"; else printf '%s\n' "$first"; fi
}

leftovers() {
  local app name s cmd skills="" clis="" left=""
  CLAUDE_CONFIG_ENV=""
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || CLAUDE_CONFIG_ENV=$(ck_abspath "$CLAUDE_CONFIG_DIR")
  CLAUDE_DIR=${CLAUDE_CONFIG_ENV:-$(ck_abspath "$HOME/.claude")}
  if [ -n "$OPT_PREFIX" ]; then PREFIX=$(ck_abspath "$OPT_PREFIX"); else PREFIX=$(derive_prefix); fi
  s="$CLAUDE_DIR/settings.json"
  for name in "$CK_SHELL_HOOK" "$CK_MCP_HOOK"; do
    ! ck_settings_has_hook "$s" "$KIT_HOME/hooks/$name" || HOOKS_REMOVE="${HOOKS_REMOVE:+$HOOKS_REMOVE }$name"
  done
  if grep -qF "$CK_WRAPPER_MARKER" "$PREFIX/craft-sandbox" 2>/dev/null; then WRAPPER_REMOVE=1; fi
  # Registrations: the ones that run through the kit's wrapper (or a wrapper file that is gone) are
  # the kit's and are removed; one that runs <app>-cli directly may be yours, so it is only listed.
  for app in $CK_APPS_ALL; do
    registration_of "$app" || continue
    cmd=$(printf '%s' "$CK_REPLY" | jq -r '.command // empty')
    if [ "$cmd" = "$PREFIX/craft-sandbox" ] && { [ "$WRAPPER_REMOVE" = 1 ] || [ ! -e "$cmd" ]; }; then
      MCP_REMOVE="${MCP_REMOVE:+$MCP_REMOVE }$app"
    elif reg_is_kits "$app" "$CK_REPLY"; then
      MCP_LEFT="${MCP_LEFT:+$MCP_LEFT }$app"
    fi
  done
  for app in $CK_APPS_ALL; do
    [ ! -f "$PREFIX/$app-cli" ] || clis="$clis $(ck_shquote "$PREFIX/$app-cli")"
  done
  for name in craft-apps $(for app in $CK_APPS_ALL; do printf 'craft-%s ' "$app"; done); do
    [ ! -f "$CLAUDE_DIR/skills/$name/SKILL.md" ] || skills="$skills $(ck_shquote "$CLAUDE_DIR/skills/$name")"
  done
  if [ -z "$HOOKS_REMOVE$MCP_REMOVE$MCP_LEFT" ] && [ "$WRAPPER_REMOVE" = 0 ]; then
    printf 'Nothing to uninstall: %s does not exist, %s has no hook entry of the kit, %s/craft-sandbox is not the kit'"'"'s, and no Craft MCP server points into %s.\n' \
      "$KIT_HOME" "$(ck_tilde "$s")" "$(ck_tilde "$PREFIX")" "$(ck_tilde "$PREFIX")"
    if [ -n "$skills$clis" ]; then
      printf 'Not removed (without the receipt the kit cannot tell whether it installed them):\n'
      [ -z "$skills" ] || printf '  rm -r%s\n' "$skills"
      [ -z "$clis" ] || printf '  rm%s\n' "$clis"
    fi
    return 0
  fi
  [ "$KEEP_HOOKS" = 0 ] || HOOKS_REMOVE=""
  for app in $MCP_LEFT; do
    left="$left"$'\n'"    $(ck_tilde "$CLAUDE_BIN") mcp remove $app -s user"
  done

  printf '%scraft-claude-kit: cleanup without a receipt%s\n\n' "$CK_BOLD" "$CK_RESET"
  printf '  The kit folder %s is gone, but the kit left these behind.\n\n  Will remove:\n' "$(ck_tilde "$KIT_HOME")"
  [ -z "$HOOKS_REMOVE" ] || printf '    hook entries in %s that run scripts from the missing folder (backup first): %s\n' "$(ck_tilde "$s")" "$HOOKS_REMOVE"
  [ -z "$MCP_REMOVE" ] || printf '    MCP servers (user scope) that run through the kit'"'"'s %s: %s\n' "$(ck_tilde "$PREFIX/craft-sandbox")" "$MCP_REMOVE"
  [ "$WRAPPER_REMOVE" = 0 ] || printf '    %s (the kit'"'"'s sandbox wrapper)\n' "$(ck_tilde "$PREFIX/craft-sandbox")"
  if [ -n "$skills$clis$left" ]; then
    printf '\n  Not removed: without the receipt the kit cannot tell whether it installed these or you did.\n'
    printf '  Remove them yourself if they are the kit'"'"'s:\n'
    [ -z "$left" ] || printf '    MCP servers that run a program in %s:%s\n' "$(ck_tilde "$PREFIX")" "$left"
    [ -z "$skills" ] || printf '    rm -r%s\n' "$skills"
    [ -z "$clis" ] || printf '    rm%s\n' "$clis"
    printf '  Or restore the receipt first (run ./install.sh from your clone), then run uninstall.sh again.\n'
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '\nDry run: nothing was changed.\n'
    return 0
  fi
  confirm
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  step_mcp
  step_hooks
  step_programs
  ck_head "Done"
  [ ! -e "$s.bak-craft-kit-$TS" ] || printf '  settings.json as it was before: %s\n' "$(ck_tilde "$s.bak-craft-kit-$TS")"
  # Never report success while a Craft MCP server that points into PREFIX is still registered.
  MCP_LEFT=""
  for app in $CK_APPS_ALL; do
    if registration_of "$app" && reg_is_kits "$app" "$CK_REPLY"; then MCP_LEFT="${MCP_LEFT:+$MCP_LEFT }$app"; fi
  done
  if [ -n "$MCP_LEFT" ]; then
    printf '  %sStill registered (not removed, see above):%s %s\n' "$CK_YELLOW" "$CK_RESET" "$MCP_LEFT"
    for app in $MCP_LEFT; do printf '    %s mcp remove %s -s user\n' "$CLAUDE_BIN" "$app"; done
    printf '  Remove the ones you do not want, then open a new Claude Code session.\n'
    return 1
  fi
  printf '  Open a new Claude Code session so it stops loading the removed servers.\n'
  [ "$ANY_FAIL" = 0 ] || { printf '  %sSome items could not be removed; see the FAIL lines above.%s\n' "$CK_RED" "$CK_RESET"; return 1; }
  return 0
}

on_exit() {
  local rc=$?
  set +e
  ck_cleanup
  exit "$rc"
}

confirm() {
  local answer
  [ "$YES" = 0 ] || return 0
  if [ ! -t 0 ]; then
    printf '\nNot running in an interactive terminal, so nothing was changed.\n' >&2
    printf 'To remove as listed, run: %s --yes\n' "$KIT_DIR/uninstall.sh" >&2
    exit 4
  fi
  printf '\nRemove these? [y/N] : '
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
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || ck_die 3 "HOME is not set to an existing folder." "Run it from a normal login shell."
  local t
  for t in jq python3 shasum; do
    command -v "$t" >/dev/null 2>&1 || ck_die 3 "$t is missing." "Install it (jq: brew install jq; python3: xcode-select --install), then re-run."
  done
  [ -f "$KIT_DIR/lib/craftkit.py" ] || ck_die 3 "kit file missing: $KIT_DIR/lib/craftkit.py" "Run the uninstaller from the kit folder or a full checkout."
  CLAUDE_BIN=${CLAUDE_BIN:-claude}
  HOME_REAL=$(ck_abspath "$HOME")

  if [ -f "$KIT_DIR/receipt.json" ]; then
    KIT_HOME=$KIT_DIR
  else
    ! ck_bad_path_chars "${CRAFT_KIT_HOME:-}" || ck_die 2 "CRAFT_KIT_HOME contains control characters."
    KIT_HOME=$(ck_abspath "${CRAFT_KIT_HOME:-$(ck_default_kit_home)}")
  fi
  RECEIPT="$KIT_HOME/receipt.json"
  if [ ! -e "$KIT_HOME" ]; then
    leftovers
    return $?
  fi
  if [ ! -f "$RECEIPT" ]; then
    ck_die 3 "No receipt at $RECEIPT, so it is not known what the kit installed." \
      "Run ./install.sh from the kit checkout once (it rewrites the receipt), then run this again."
  fi
  case "$KIT_HOME" in / | "$HOME_REAL") ck_die 3 "Refusing to work on the kit folder $KIT_HOME." "Set CRAFT_KIT_HOME to the kit's own folder." ;; esac
  if ! load_receipt; then
    printf 'The receipt %s cannot be trusted:\n%s' "$RECEIPT" "$RECEIPT_ERRORS" >&2
    printf 'fix: run uninstall.sh from your clone of the kit (it works without the kit folder), or re-run ./install.sh from that clone (it rewrites the receipt), then run this again.\n' >&2
    exit 3
  fi
  # Talk to the same Claude Code config the installer used.
  if [ -n "$CLAUDE_CONFIG_ENV" ]; then export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_ENV"; else unset CLAUDE_CONFIG_DIR; fi
  LOCK_FILE="$KIT_HOME/manifest/apps.lock.json"
  [ -f "$LOCK_FILE" ] || LOCK_FILE="$KIT_DIR/manifest/apps.lock.json"
  [ -f "$LOCK_FILE" ] || LOCK_FILE=""

  plan
  print_plan
  if [ "$DRY_RUN" = 1 ]; then
    printf '\nDry run: nothing was changed.\n'
    return 0
  fi
  confirm
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  if [ -d "$KIT_HOME" ] && [ -w "$KIT_HOME" ]; then
    CK_LOG_FILE="$KIT_HOME/install.log"
    ck_log "=== uninstall.sh ($*)"
  fi

  step_mcp
  step_hooks
  step_skills
  step_gui
  step_programs
  # shellcheck disable=SC2034  # read by the ck_* helpers; the log file is about to be removed
  CK_LOG_FILE=""
  step_kit_home

  ck_head "Done"
  [ -z "$R_WORKSPACE" ] || printf '  Your workspace was not touched: %s\n' "$R_WORKSPACE"
  [ ! -e "$CLAUDE_DIR/settings.json.bak-craft-kit-$TS" ] || printf '  settings.json as it was before: %s\n' "$CLAUDE_DIR/settings.json.bak-craft-kit-$TS"
  printf '  Open a new Claude Code session so it stops loading the removed servers and skills.\n'
  if [ "$ANY_FAIL" = 1 ]; then
    printf '  %sSome items could not be removed; see the FAIL lines above.%s\n' "$CK_RED" "$CK_RESET"
    return 1
  fi
  return 0
}

main "$@"
