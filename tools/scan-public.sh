#!/usr/bin/env bash
# scan-public.sh - generic public-hygiene scan for a repository that is about to be (or already is) public.
#
#   tools/scan-public.sh [--root DIR] [--allow FILE] [--tree-only | --history-only] [--no-commit-meta] [-q]
#
# Scans every text file of the working tree (tracked files plus untracked files that are not ignored) and, in a
# git repository, the whole history ("git log -p": every added and removed line, commit messages, author and
# committer names/emails). It reports:
#   personal-path      /Users/<name> (except /Users/you, /Users/example, /Users/Shared) and /Volumes/<name>
#   email              e-mail addresses other than example.com/.org/.net, *noreply*, git@github.com
#   ipv4               IPv4 addresses (except loopback, 0.0.0.0, netmasks and documentation ranges)
#   hex-secret         hexadecimal runs of 32+ characters
#   base64-secret      base64/url-safe-looking runs of 40+ characters mixing upper case, lower case and digits
#   known-token        well-known credential prefixes (AWS, GitHub, Slack, sk-... keys)
#   secret-assignment  password / passwd / secret / token / api key assigned a literal value
#   private-key        private key block headers
#   hostname           host names ending in .local, .home.arpa or .ts.net
#   denylist           any line containing an entry of the optional extra denylist (see below)
#   binary-file        a file (or a binary change in history) the scan cannot read as text: review it by hand
#   long-line          a line over 20000 characters; only its first 20000 are scanned
# Matched secret values are masked in the output. Nothing is modified and nothing leaves the machine.
#
# Extra denylist: set CRAFT_KIT_EXTRA_DENYLIST=/path/to/file (one fixed string per line, case-insensitive, blank
# lines and lines starting with # ignored). Use it for things only you know are private (your name, employer,
# host names). The file must live OUTSIDE the repository; the scan refuses to run otherwise.
# SCAN_DENY_TERMS=term1,term2 adds terms the same way without a file (for example the owner's handle, which the
# public text must not contain); both can be used together. Neither is ever written into the repository.
#
# --no-commit-meta skips author/committer names and e-mails (CI uses it: contributors' commit e-mails are theirs to
# choose); commit messages and diffs are still scanned.
#
# Allowlist: tools/scan-public.allow (or --allow FILE). One entry per line:
# <path-glob><TAB><fixed-string>[<TAB><category>]. A hit is ignored when its file path matches the glob ('*'
# matches any characters, including '/'), its line contains the fixed string (an empty string allows every hit
# in those files) and, when the third column is given, the hit is of that category (so a sha256 line cannot
# also hide a personal path). Commit metadata uses the path "(commit)" and commit messages "(commit message)".
# The allowlist file itself is not scanned.
#
# Exit status: 0 clean, 1 findings, 2 usage or environment error. Bash 3.2 compatible.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SELF_DIR/.." && pwd -P)
ALLOW=""
ALLOW_GIVEN=0
DO_TREE=1
DO_HISTORY=1
QUIET=0
NOMETA=0

usage() {
  cat <<'EOF'
Usage: tools/scan-public.sh [--root DIR] [--allow FILE] [--tree-only | --history-only] [--no-commit-meta] [-q] [-h]

  --root DIR         repository to scan (default: the repository containing this script)
  --allow FILE       allowlist (default: <root>/tools/scan-public.allow when it exists)
  --tree-only        scan only the working tree
  --history-only     scan only git history
  --no-commit-meta   do not check commit author/committer names and e-mails
  -q, --quiet        print findings and the final line only

Environment: CRAFT_KIT_EXTRA_DENYLIST=FILE (fixed strings, one per line; must be outside the repository)
             SCAN_DENY_TERMS=a,b (comma-separated fixed strings, added to the denylist)
Exit status: 0 clean, 1 findings, 2 usage or environment error.
EOF
}

die() {
  echo "scan-public: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --root)
      [ $# -ge 2 ] || die "--root needs a directory"
      ROOT=$(cd "$2" 2>/dev/null && pwd -P) || die "no such directory: $2"
      shift 2
      ;;
    --allow)
      [ $# -ge 2 ] || die "--allow needs a file"
      ALLOW=$2
      ALLOW_GIVEN=1
      shift 2
      ;;
    --tree-only) DO_HISTORY=0; shift ;;
    --history-only) DO_TREE=0; shift ;;
    --no-commit-meta) NOMETA=1; shift ;;
    -q | --quiet) QUIET=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [ "$DO_TREE" = 0 ] && [ "$DO_HISTORY" = 0 ]; then
  die "--tree-only and --history-only exclude each other"
fi

if [ "$ALLOW_GIVEN" = 0 ] && [ -f "$ROOT/tools/scan-public.allow" ]; then
  ALLOW=$ROOT/tools/scan-public.allow
fi
if [ -n "$ALLOW" ]; then
  [ -f "$ALLOW" ] || die "allowlist not found: $ALLOW"
  ALLOW=$(cd "$(dirname "$ALLOW")" && pwd -P)/$(basename "$ALLOW")
fi
ALLOW_REL=""
case "$ALLOW" in
  "$ROOT"/*) ALLOW_REL=${ALLOW#"$ROOT"/} ;;
esac

DENY=${CRAFT_KIT_EXTRA_DENYLIST:-}
if [ -n "$DENY" ]; then
  [ -f "$DENY" ] || die "CRAFT_KIT_EXTRA_DENYLIST is set but is not a file"
  deny_dir=$(cd "$(dirname "$DENY")" && pwd -P)
  case "$deny_dir/" in
    "$ROOT"/*) die "the extra denylist is inside the repository; keep it outside so it can never be committed" ;;
  esac
  DENY=$deny_dir/$(basename "$DENY")
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/scan-public.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "${SCAN_DENY_TERMS:-}" ]; then
  { [ -z "$DENY" ] || cat "$DENY"; printf '\n%s\n' "$SCAN_DENY_TERMS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; } > "$TMP/deny-terms.txt"
  DENY=$TMP/deny-terms.txt
fi

cat > "$TMP/scan.awk" <<'AWK'
# Variables: MODE (tree|history), LIST (file with paths, tree mode), ALLOW, DENY, SKIP (path never scanned),
# NOMETA (history mode: 1 = do not check commit author/committer lines)

function glob_to_re(g,   i, c, r) {
  r = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == "?") r = r "."
    else if (index("\\^$.[]|()+{}", c) > 0) r = r "\\" c
    else r = r c
  }
  return r "$"
}

function allowed(path, text, cat,   i) {
  for (i = 1; i <= na; i++)
    if (path ~ aglob[i] && (afix[i] == "" || index(text, afix[i]) > 0) && (acat[i] == "" || acat[i] == cat)) return 1
  return 0
}

function mask(v) {
  return substr(v, 1, 4) "... (" length(v) " chars)"
}

function report(cat, val, shown,   key) {
  if (allowed(cur_path, cur_text, cat)) return
  if (MODE == "history") {
    key = cat SUBSEP val SUBSEP cur_path
    if (key in seen) return
    seen[key] = 1
  }
  print cur_path ":" cur_loc ": [" cat "] " shown
}

function has_any(s, chars,   i) {
  for (i = 1; i <= length(chars); i++)
    if (index(s, substr(chars, i, 1)) > 0) return 1
  return 0
}

function distinct(s,   i, c, n, d) {
  n = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (!(c in d)) { d[c] = 1; n++ }
  }
  return n
}

function runs(text, re, minlen, cat,   rest, m) {
  rest = text
  while (match(rest, re)) {
    m = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    if (length(m) >= minlen) report(cat, m, mask(m))
  }
}

function placeholder(v,   lv) {
  lv = tolower(v)
  if (lv ~ /^(secret|password|passwd|token|none|null|true|false|yes|no|todo|tbd|empty|unset|required|optional)$/) return 1
  if (index(lv, "example") || index(lv, "your") || index(lv, "xxx") || index(lv, "changeme") || \
      index(lv, "change-me") || index(lv, "placeholder") || index(lv, "redact") || index(lv, "dummy") || \
      index(lv, "sample") || index(lv, "<") || index(lv, "***")) return 1
  if (has_any(v, "$<>{}()[]@*%") || index(lv, "http") == 1 || index(lv, "://") > 0) return 1
  return 0
}

function check(text, path, loc,   rest, m, rs, rl, off, pre, nxt, nxt2, parts, name, base, at, lcl, dom, n, o, i, ok, low, v, q, idx, op, aft) {
  cur_text = text; cur_path = path; cur_loc = loc
  if (length(text) > 20000) {
    report("long-line", "x", "line of " length(text) " characters: only the first 20000 are scanned")
    text = substr(text, 1, 20000)
  }

  # personal paths
  rest = text
  while (match(rest, "/Users/[A-Za-z0-9._-]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    name = substr(m, 8); sub(/[._-]+$/, "", name)
    if (name == "" || name == "you" || name == "example" || name == "Shared") continue
    report("personal-path", m, m)
  }
  rest = text
  while (match(rest, "/Volumes/[A-Za-z0-9._-]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    name = substr(m, 10); sub(/[._-]+$/, "", name)
    if (name == "" || name == "you" || name == "example" || name == "Macintosh") continue
    report("personal-path", m, m)
  }

  # e-mail addresses
  rest = text
  while (match(rest, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z][A-Za-z]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    at = index(m, "@"); lcl = tolower(substr(m, 1, at - 1)); dom = tolower(substr(m, at + 1))
    if (dom ~ /(^|\.)example\.(com|org|net)$/ || dom ~ /\.(test|example|invalid|localhost)$/) continue
    if (index(lcl, "noreply") || index(lcl, "no-reply") || index(dom, "noreply")) continue
    if (lcl == "git" && dom == "github.com") continue
    if (dom ~ /^[0-9]x\./) continue
    report("email", m, m)
  }

  # IPv4 addresses
  rest = text; off = 0
  while (match(rest, "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+")) {
    rs = RSTART; rl = RLENGTH
    m = substr(rest, rs, rl)
    pre = (off + rs > 1) ? substr(text, off + rs - 1, 1) : ""
    nxt = substr(rest, rs + rl, 1); nxt2 = substr(rest, rs + rl + 1, 1)
    off += rs + rl - 1
    rest = substr(rest, rs + rl)
    if (pre ~ /[A-Za-z0-9_.]/) continue
    if (nxt == "." && nxt2 ~ /[0-9]/) continue
    n = split(m, o, ".")
    ok = 1
    for (i = 1; i <= 4; i++) if (length(o[i]) > 3 || o[i] + 0 > 255) ok = 0
    if (!ok) continue
    if (m == "0.0.0.0" || m ~ /^127\./ || m ~ /^255\./ || m ~ /^192\.0\.2\./ || m ~ /^198\.51\.100\./ || m ~ /^203\.0\.113\./) continue
    report("ipv4", m, m)
  }

  # long hex and base64-looking runs
  rest = text
  while (match(rest, "[0-9A-Fa-f]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    if (length(m) >= 32) report("hex-secret", m, mask(m))
  }
  rest = text
  while (match(rest, "[A-Za-z0-9+/=_-]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    if (length(m) >= 40 && m ~ /[A-Z]/ && m ~ /[a-z]/ && m ~ /[0-9]/ && m !~ /^[0-9A-Fa-f]+$/ && distinct(m) >= 20)
      report("base64-secret", m, mask(m))
  }

  # well-known credential prefixes
  rest = text
  while (match(rest, "(AKIA|ASIA)[0-9A-Z]+")) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    if (length(m) == 20) report("known-token", m, mask(m))
  }
  runs(text, "gh[pousr]_[A-Za-z0-9]+", 30, "known-token")
  runs(text, "github_pat_[A-Za-z0-9_]+", 30, "known-token")
  runs(text, "xox[abprs]-[A-Za-z0-9-]+", 15, "known-token")
  runs(text, "sk-[A-Za-z0-9_-]+", 24, "known-token")
  runs(text, "AIza[0-9A-Za-z_-]+", 39, "known-token")

  # password / secret / token assignments with a literal value
  low = tolower(text); rest = low; off = 0
  while (match(rest, "(password|passwd|secret|token|api[_-]?key)[a-z0-9_-]*[\"']?[ \t]*[:=]")) {
    rs = RSTART; rl = RLENGTH
    op = substr(rest, rs + rl - 1, 1)
    aft = substr(rest, rs + rl, 1)
    v = substr(text, off + rs + rl)
    off += rs + rl - 1
    rest = substr(rest, rs + rl)
    if ((op == "=" && (aft == "=" || aft == "~")) || (op == ":" && aft == ":")) continue
    sub(/^[ \t]+/, "", v)
    q = substr(v, 1, 1)
    if (q == "\"" || q == "'") {
      idx = index(substr(v, 2), q)
      v = (idx > 0) ? substr(v, 2, idx - 1) : substr(v, 2)
      if (length(v) < 8 || index(v, " ") > 0) continue
    } else {
      if (!match(v, "^[^ \t;&|),<>}]+")) continue
      v = substr(v, 1, RLENGTH)
      if (length(v) < 8 || v !~ /[0-9]/) continue
      if (op == ":" && v !~ /[A-Za-z]/) continue
    }
    if (placeholder(v)) continue
    report("secret-assignment", v, "literal value assigned to a password/secret/token/key name: " mask(v))
  }

  # private key blocks
  if (match(text, "-----BEGIN [A-Z ]*PRIVATE KEY")) report("private-key", "k", "private key header")

  # private-network host names
  rest = text; off = 0
  while (match(rest, "[A-Za-z0-9][A-Za-z0-9-]*\\.(local|home\\.arpa|ts\\.net)")) {
    rs = RSTART; rl = RLENGTH
    m = substr(rest, rs, rl); nxt = substr(rest, rs + rl, 1)
    rest = substr(rest, rs + rl)
    if (nxt ~ /[A-Za-z0-9_.(-]/) continue
    report("hostname", m, m)
  }

  # extra denylist (entries are never echoed)
  if (nd > 0) {
    low = tolower(text)
    for (i = 1; i <= nd; i++)
      if (index(low, deny[i]) > 0) report("denylist", deny[i], "line contains denylist entry #" i)
  }
}

BEGIN {
  na = 0; nd = 0
  if (ALLOW != "") {
    while ((getline line < ALLOW) > 0) {
      sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#|$)/) continue
      nf = split(line, col, "\t")
      na++
      aglob[na] = glob_to_re(col[1]); afix[na] = (nf >= 2) ? col[2] : ""; acat[na] = (nf >= 3) ? col[3] : ""
    }
    close(ALLOW)
  }
  if (DENY != "") {
    while ((getline line < DENY) > 0) {
      sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#|$)/) continue
      nd++; deny[nd] = tolower(line)
    }
    close(DENY)
  }
  if (MODE == "tree") {
    while ((getline fpath < LIST) > 0) {
      if (fpath == SKIP) continue
      check(fpath, fpath, "name")
      n = 0
      while ((getline line < fpath) > 0) { n++; check(line, fpath, n) }
      close(fpath)
    }
    while (BINLIST != "" && (getline fpath < BINLIST) > 0) {
      cur_text = ""; cur_path = fpath; cur_loc = "file"
      report("binary-file", fpath, "binary file, not text-scanned: review it by hand (or allowlist it by path)")
    }
    exit 0
  }
}

# History mode: input is "git log -p" with the markers produced by the --format below.
MODE == "history" {
  if (substr($0, 1, 1) == "\001") {
    tag = substr($0, 2, 1); body = substr($0, 4)
    if (tag == "C") { loc = "commit " body; state = ""; inhunk = 0; path = "(unknown)" }
    else if (tag == "A" || tag == "M") { if (!NOMETA) check(body, "(commit)", loc) }
    else if (tag == "B") state = "msg"
    else if (tag == "E") state = ""
    next
  }
  if (state == "msg") { check($0, "(commit message)", loc); next }
  if (index($0, "diff --git ") == 1) { inhunk = 0; path = "(unknown)"; next }
  if (!inhunk && index($0, "Binary files ") == 1) {
    p = $0; sub(/ differ$/, "", p); sub(/^.* and /, "", p); sub(/^"?[ab]\//, "", p); sub(/"$/, "", p)
    if (p == "/dev/null") { p = $0; sub(/^Binary files /, "", p); sub(/ and .*$/, "", p); sub(/^"?[ab]\//, "", p); sub(/"$/, "", p) }
    cur_text = ""; cur_path = p; cur_loc = loc
    if (p != SKIP) report("binary-file", p, "binary change, not text-scanned: review it by hand (or allowlist it by path)")
    next
  }
  if (!inhunk) {
    if (index($0, "--- ") == 1 || index($0, "+++ ") == 1) {
      p = substr($0, 5); sub(/\t.*$/, "", p)
      if (p != "/dev/null") { sub(/^"?[ab]\//, "", p); sub(/"$/, "", p); path = p }
    } else if (index($0, "@@") == 1) inhunk = 1
    next
  }
  if (index($0, "@@") == 1) next
  c = substr($0, 1, 1)
  if ((c == "+" || c == "-") && path != SKIP) check(substr($0, 2), path, loc)
}
AWK

export LC_ALL=C
cd "$ROOT"

is_git=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  is_git=1
fi

say() { [ "$QUIET" = 1 ] || echo "$@"; }

tree_n=0
hist_n=0
files_n=0
commits_n=0

if [ "$DO_TREE" = 1 ]; then
  if [ "$is_git" = 1 ]; then
    git -c core.quotepath=off ls-files -co --exclude-standard > "$TMP/all"
  else
    find . -type f -not -path './.git/*' | sed 's|^\./||' > "$TMP/all"
  fi
  : > "$TMP/files"
  if [ -s "$TMP/all" ]; then
    tr '\n' '\0' < "$TMP/all" | xargs -0 -n 200 grep -lI -e '' -- > "$TMP/files" 2>/dev/null || true
  fi
  # Files grep did not list as text: binary (reported), or empty / missing (nothing to scan).
  : > "$TMP/binary"
  sort "$TMP/files" > "$TMP/files.sorted"
  sort "$TMP/all" | comm -23 - "$TMP/files.sorted" | while IFS= read -r f; do
    if [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] && [ "$f" != "$ALLOW_REL" ]; then printf '%s\n' "$f"; fi
  done > "$TMP/binary"
  files_n=$(wc -l < "$TMP/files" | tr -d ' ')
  say "== working tree: $files_n text file(s), $(wc -l < "$TMP/binary" | tr -d ' ') binary =="
  awk -f "$TMP/scan.awk" -v MODE=tree -v LIST="$TMP/files" -v BINLIST="$TMP/binary" -v ALLOW="$ALLOW" -v DENY="$DENY" -v SKIP="$ALLOW_REL" \
    > "$TMP/tree.out" || die "awk failed while scanning the working tree"
  tree_n=$(wc -l < "$TMP/tree.out" | tr -d ' ')
  cat "$TMP/tree.out"
fi

if [ "$DO_HISTORY" = 1 ]; then
  if [ "$is_git" = 0 ]; then
    say "== git history: not a git repository, skipped =="
  else
    commits_n=$(git rev-list --all --count 2>/dev/null || echo 0)
    if [ "$commits_n" = 0 ]; then
      say "== git history: no commits yet =="
    else
      if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = true ]; then
        echo "scan-public: warning: shallow clone, only the fetched history is scanned (use fetch-depth: 0)" >&2
      fi
      say "== git history: $commits_n commit(s) =="
      fmt='%x01C %h%n%x01A %an <%ae>%n%x01M %cn <%ce>%n%x01B%n%B%n%x01E'
      git -c core.quotepath=off --no-pager log --all -p --no-color --no-ext-diff --no-textconv \
        --format="$fmt" -- . 2> "$TMP/git.err" \
        | awk -f "$TMP/scan.awk" -v MODE=history -v ALLOW="$ALLOW" -v DENY="$DENY" -v SKIP="$ALLOW_REL" -v NOMETA="$NOMETA" \
          > "$TMP/hist.out" || die "scanning git history failed: $(head -n 3 "$TMP/git.err" | tr '\n' ' ')"
      hist_n=$(wc -l < "$TMP/hist.out" | tr -d ' ')
      cat "$TMP/hist.out"
    fi
  fi
fi

total=$((tree_n + hist_n))
if [ "$total" -gt 0 ]; then
  echo "scan-public: FAILED, $total finding(s) (working tree: $tree_n, history: $hist_n)." >&2
  echo "scan-public: fix them, or allowlist legitimate hits in tools/scan-public.allow (path-glob<TAB>fixed-string<TAB>category)." >&2
  exit 1
fi
echo "scan-public: clean ($files_n file(s), $commits_n commit(s))"
