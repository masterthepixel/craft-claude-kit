# shellcheck shell=bash
# shellcheck disable=SC2034  # constants below are used by the scripts that source this file
# Shared helpers for install.sh and uninstall.sh. Sourced, never executed.
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile, no ${var,,}.

# The 13 apps, in the order the kit presents them.
CK_APPS_ALL="wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft filmcraft effectcraft lightcraft soundcraft"
CK_SHELL_HOOK=craft-shell-guard.py
CK_MCP_HOOK=craft-mcp-guard.py
# Every tool that runs a shell command or starts an app, not only Bash (regex alternation; Claude
# Code matches it against the whole tool name). computer_batch and other tools are not covered.
CK_SHELL_MATCHER='Bash|mcp__terminal__run_in_terminal|Monitor|mcp__computer-use__open_application'
CK_MCP_MATCHER="mcp__($(printf '%s' "$CK_APPS_ALL" | tr ' ' '|'))__.*"
CK_HOOK_TIMEOUT=10
# Older hand-made setups this kit migrates from (relative to $HOME).
CK_LEGACY_HOOK_REL=.local/share/craft-skills/craft-shell-guard.py
CK_LEGACY_PROFILE_REL=.local/share/craft-sandbox/craft.sb
CK_LEGACY_WRAPPER_REL=.local/bin/craft-sandbox
# A line only the kit's craft-sandbox carries; used to recognise our own wrapper before replacing
# or removing a file of that name.
CK_WRAPPER_MARKER="craft-sandbox (craft-claude-kit)"

# ---------------------------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------------------------
CK_LOG_FILE=""
CK_RED="" CK_GREEN="" CK_YELLOW="" CK_CYAN="" CK_BOLD="" CK_DIM="" CK_RESET=""

# Color only on a real terminal, or when FORCE_COLOR / CLICOLOR_FORCE is set (so a run saved with tee keeps it).
# NO_COLOR always wins. Color is applied to words only, never to padding, so the plain text is unchanged.
ck_color_init() {
  local want=0
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then want=1; fi
  if [ -n "${FORCE_COLOR:-}" ] && [ "${FORCE_COLOR:-}" != 0 ]; then want=1; fi
  if [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE:-}" != 0 ]; then want=1; fi
  if [ -z "${NO_COLOR:-}" ] && [ "$want" = 1 ]; then
    CK_RED=$'\033[31m' CK_GREEN=$'\033[32m' CK_YELLOW=$'\033[33m' CK_CYAN=$'\033[36m'
    CK_BOLD=$'\033[1m' CK_DIM=$'\033[2m' CK_RESET=$'\033[0m'
  fi
}

ck_log() {
  [ -n "$CK_LOG_FILE" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$CK_LOG_FILE" 2>/dev/null || true
}

ck_say()  { printf '%s\n' "$*"; ck_log "$*"; }
ck_head() { printf '\n%s%s==> %s%s\n' "$CK_BOLD" "$CK_CYAN" "$*" "$CK_RESET"; ck_log "==> $*"; }
ck_dim()  { printf '%s%s%s\n' "$CK_DIM" "$*" "$CK_RESET"; ck_log "$*"; }
# ck_paint TEXT: color the leading word of a (possibly padded) table cell by what it says; the width is unchanged.
ck_paint() {
  local t=$1 w=${1%% *} c=""
  case $w in
    install | installed | upgrade | upgraded | add | added) c=$CK_GREEN ;;
    replace* | re-register* | missing) c=$CK_YELLOW ;;
    FAILED) c=$CK_RED$CK_BOLD ;;
    skip | skipped | keep | kept | registered | up | off) c=$CK_DIM ;;
  esac
  if [ -z "$c" ] || [ -z "$CK_RESET" ]; then printf '%s' "$t"; return 0; fi
  printf '%s%s%s%s' "$c" "$w" "$CK_RESET" "${t#"$w"}"
}
ck_ok()   { printf '  %sOK%s    %s\n' "$CK_GREEN" "$CK_RESET" "$*"; ck_log "OK    $*"; }
ck_skip() { printf '  %s--%s    %s\n' "$CK_DIM" "$CK_RESET" "$*"; ck_log "--    $*"; }
ck_hint() { [ -z "${1:-}" ] || { printf '        fix: %s\n' "$1"; ck_log "      fix: $1"; }; }
ck_warn() { printf '  %sWARN%s  %s\n' "$CK_YELLOW" "$CK_RESET" "$1"; ck_log "WARN  $1"; ck_hint "${2:-}"; }
CK_LAST_FAIL=""
ck_fail() { CK_LAST_FAIL=$1; printf '  %sFAIL%s  %s\n' "$CK_RED" "$CK_RESET" "$1"; ck_log "FAIL  $1"; ck_hint "${2:-}"; }

# ck_die CODE MESSAGE [HINT]: print to stderr and exit.
ck_die() {
  local code=$1
  printf '%s%s%s\n' "$CK_RED" "$2" "$CK_RESET" >&2
  [ -z "${3:-}" ] || printf 'fix: %s\n' "$3" >&2
  ck_log "FATAL $2"
  exit "$code"
}

# ---------------------------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------------------------

# Dynamic per-app variables (bash 3.2 has no associative arrays). Names are [a-z0-9_] only.
ck_set() { printf -v "$1" '%s' "$2"; }
ck_get() { local __n=$1; printf '%s' "${!__n:-}"; }

ck_in_list() { # WORD LIST(space separated)
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# Absolute, normalised path with ~ expanded and no trailing slash; symlinks are NOT resolved.
# Same rule as lib/craftkit.py so registrations compare equal.
ck_abspath() {
  python3 -I -c 'import os, sys
p = os.path.abspath(os.path.expanduser(sys.argv[1]))
print(p if p == os.sep else p.rstrip(os.sep))' "$1"
}

ck_bad_path_chars() { # PATH -> 0 if it contains a newline, tab or other control character
  case "$1" in *[[:cntrl:]]*) return 0 ;; esac
  return 1
}

# Quote a word for a shell command line; plain paths stay unquoted so commands stay readable.
ck_shquote() {
  case "$1" in
    "" | *[!A-Za-z0-9_./:@%+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Display form of a path: $HOME/x -> ~/x (for reading only; commands keep full paths).
# shellcheck disable=SC2088  # a literal ~ is the point: this is display text
ck_tilde() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

ck_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

ck_filesize() { wc -c <"$1" | tr -d ' '; }

ck_mb() { # BYTES -> "819 MB" / "1.0 GB" / "6.3 MB" (decimal units, as GitHub shows them)
  awk -v b="${1:-0}" 'BEGIN { m = b / 1000000
    if (m >= 1000) printf "%.1f GB", m / 1000
    else if (m >= 10) printf "%d MB", m + 0.5
    else printf "%.1f MB", m }'
}

# Does TEXT contain VERSION as a whole version token ("wordcraft-cli 0.7.0", "v0.7.0")?
# (Here-strings, not pipes: with pipefail an early-exiting grep could turn a match into a failure.)
ck_version_in() {
  local re=${2//./\\.}
  grep -Eq "(^|[^0-9.])${re}([^0-9.]|\$)" <<<"$1"
}

ck_first_version() { awk 'match($0, /[0-9]+\.[0-9]+(\.[0-9]+)?/) { print substr($0, RSTART, RLENGTH); exit }' <<<"$1"; }

ck_first_line() { printf '%s' "${1%%$'\n'*}"; }

# Does help TEXT advertise FLAG as a whole option (so --root does not match --automation-read-root)?
ck_has_flag() { grep -Eq -- "(^|[^-[:alnum:]])${2}([^-[:alnum:]]|\$)" <<<"$1"; }

# ck_capture SECONDS CMD [ARGS...]: run CMD with stdin closed, print its stdout+stderr, return its
# exit status (124 on timeout, 126 if it cannot be started). Used only for --version / --help.
ck_capture() {
  python3 -I -c 'import os, signal, subprocess, sys
t = float(sys.argv[1])
try:
    p = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True)
except OSError as exc:
    print(exc)
    sys.exit(126)
def stop(sig):
    try:
        os.killpg(p.pid, sig)
    except OSError:
        pass
    p.wait()
def interrupted(signum, frame):
    stop(signal.SIGTERM)
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    out, _ = p.communicate(timeout=t)
except subprocess.TimeoutExpired:
    stop(signal.SIGKILL)
    print("timed out after %ds" % t)
    sys.exit(124)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(p.returncode if p.returncode >= 0 else 128 - p.returncode)' "$@"
}

ck_bundle_version() { # APP_BUNDLE -> CFBundleShortVersionString (empty if unreadable)
  python3 -I -c 'import plistlib, sys
try:
    with open(sys.argv[1] + "/Contents/Info.plist", "rb") as fh:
        print(plistlib.load(fh).get("CFBundleShortVersionString", ""))
except Exception:
    print("")' "$1"
}

# Nearest existing ancestor of PATH is writable (so PATH can be created or written).
ck_writable_or_creatable() {
  local p=$1
  while [ ! -e "$p" ]; do
    p=$(dirname "$p")
  done
  [ -d "$p" ] && [ -w "$p" ]
}

ck_free_kb() { # PATH -> free KiB on the volume holding PATH (or its nearest existing ancestor)
  local p=$1
  while [ ! -e "$p" ]; do p=$(dirname "$p"); done
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# ---------------------------------------------------------------------------------------------
# temp files, mounts and cleanup (trap-driven, safe on Ctrl-C)
# ---------------------------------------------------------------------------------------------
CK_TMP_DIRS=()
CK_TMP_FILES=()
CK_MOUNTS=()
CK_REPLY=""

# Create a private temp dir; its path is returned in CK_REPLY (no subshell, so it stays registered).
ck_mktemp_dir() {
  local base=${TMPDIR:-/tmp}
  CK_REPLY=$(mktemp -d "${base%/}/craft-kit.XXXXXX") || return 1
  CK_TMP_DIRS+=("$CK_REPLY")
}

# Create a temp file next to TARGET (same folder, so mv is atomic); path in CK_REPLY.
ck_mktemp_beside() {
  local dir
  dir=$(dirname "$1")
  CK_REPLY=$(mktemp "$dir/.craft-kit.XXXXXX") || return 1
  CK_TMP_FILES+=("$CK_REPLY")
}

# rm -rf PATH, but only if PATH is absolute, strictly inside BASE, and neither is / or $HOME.
ck_safe_rm_rf() {
  local p=$1 b=${2%/}
  case "$p" in "" | / | */.. | */../* | ../* | ..) return 1 ;; esac
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$b" in "" | /) return 1 ;; esac
  case "$p" in "$b"/?*) ;; *) return 1 ;; esac
  [ "$p" != "${HOME%/}" ] || return 1
  rm -rf -- "$p"
}

ck_cleanup() {
  local m f d
  for m in ${CK_MOUNTS[@]+"${CK_MOUNTS[@]}"}; do
    [ -d "$m" ] || continue
    hdiutil detach "$m" -quiet >/dev/null 2>&1 || hdiutil detach "$m" -force -quiet >/dev/null 2>&1 || true
    rmdir "$m" 2>/dev/null || true
  done
  CK_MOUNTS=()
  for f in ${CK_TMP_FILES[@]+"${CK_TMP_FILES[@]}"}; do
    [ -n "$f" ] && [ -e "$f" ] && rm -f -- "$f"
  done
  CK_TMP_FILES=()
  for d in ${CK_TMP_DIRS[@]+"${CK_TMP_DIRS[@]}"}; do
    case "$(basename "$d")" in craft-kit.* | .craft-kit.*) ck_safe_rm_rf "$d" "$(dirname "$d")" || true ;; esac
  done
  CK_TMP_DIRS=()
}

# ---------------------------------------------------------------------------------------------
# kit locations
# ---------------------------------------------------------------------------------------------
ck_default_kit_home() { printf '%s\n' "$HOME/.local/share/craft-claude-kit"; }

# File that holds user-scope MCP servers (what `claude mcp add -s user` edits).
ck_claude_json_for() { # CLAUDE_CONFIG_DIR value (may be empty)
  if [ -n "$1" ]; then printf '%s/.claude.json\n' "${1%/}"; else printf '%s/.claude.json\n' "$HOME"; fi
}

# The hook command line the kit registers for SCRIPT (basename) given KIT_HOME and WORKSPACE.
# "|| true": Claude Code treats a hook's exit code 2 as "block this tool call", and python3 exits 2
# when the script is missing (kit folder deleted by hand). The hooks only ever answer through JSON on
# exit 0, so forcing exit 0 keeps them fail-open instead of blocking every Bash or Craft call.
ck_hook_command() {
  printf 'python3 %s --workspace %s || true' "$(ck_shquote "$2/hooks/$1")" "$(ck_shquote "$3")"
}

# Refuse to run as root: with sudo, HOME usually stays the user's, so root-owned files would land
# in the user's ~/.claude, ~/.local and workspace.
ck_refuse_root() { # PROG
  [ "$(id -u)" != 0 ] || ck_die 3 "$1: do not run this with sudo or as root; run it as your normal user." \
    "The kit installs into your own home folder and never needs administrator rights."
}

# Does settings FILE contain a PreToolUse hook whose command contains STRING? (read-only)
ck_settings_has_hook() {
  [ -f "$1" ] || return 1
  jq -e --arg s "$2" \
    '[.hooks.PreToolUse[]?.hooks[]?.command? // empty | strings | select(contains($s))] | length > 0' \
    "$1" >/dev/null 2>&1
}

# Is settings FILE missing or valid JSON?
ck_settings_parses() { [ ! -e "$1" ] || jq empty "$1" >/dev/null 2>&1; }
