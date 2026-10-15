#!/usr/bin/env bash
# Maintainer tool: regenerate manifest/apps.lock.json from upstream GitHub release metadata.
#
#   tools/gen-lock.sh              pin the versions listed in manifest/pins.txt
#   tools/gen-lock.sh --latest     ignore pins.txt and lock each app's latest release (then review the diff)
#
# Needs: gh (authenticated; only reads public release metadata), jq, curl.
# The SHA-256 of every asset comes from the GitHub API and is cross-checked against the SHA256SUMS.txt
# that upstream publishes with each release. A mismatch or missing entry aborts.
# Bash 3.2 compatible (macOS default shell).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OWNER=storytold
PINS="$HERE/manifest/pins.txt"
OUT="$HERE/manifest/apps.lock.json"
LATEST=0
[ "${1:-}" = "--latest" ] && LATEST=1

command -v gh >/dev/null || { echo "gen-lock: gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "gen-lock: jq is required" >&2; exit 1; }

# app -> bundle|fence mode|extra MCP args (JSON)|what it is
meta() {
  case $1 in
    wordcraft)   echo 'WordCraft.app|roots|["--author","Claude"]|Word processor (.docx)' ;;
    gridcraft)   echo 'GridCraft.app|sandbox|[]|Spreadsheet (.xlsx)' ;;
    deckcraft)   echo 'DeckCraft.app|sandbox|[]|Presentations (.pptx)' ;;
    pdfcraft)    echo 'PdfCraft.app|root|[]|PDF editor' ;;
    photocraft)  echo 'PhotoCraft.app|roots|[]|Image editor (layers, PSD)' ;;
    vectorcraft) echo 'VectorCraft.app|roots|[]|Vector illustration (SVG)' ;;
    designcraft) echo 'DesignCraft.app|sandbox|[]|Page layout' ;;
    cadcraft)    echo 'CADCraft.app|sandbox|[]|2D CAD drafting' ;;
    figcraft)    echo 'FigCraft.app|sandbox|[]|Interface design' ;;
    filmcraft)   echo 'FilmCraft.app|sandbox|[]|Video editor' ;;
    effectcraft) echo 'EffectCraft.app|roots|[]|Motion graphics compositor' ;;
    lightcraft)  echo 'LightCraft.app|sandbox|[]|Raw photo library and developer' ;;
    soundcraft)  echo 'SoundCraft.app|sandbox|[]|Audio workstation' ;;
    *) echo "gen-lock: unknown app $1" >&2; return 1 ;;
  esac
}

entries=$(mktemp); trap 'rm -f "$entries"' EXIT
APPS="wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft filmcraft effectcraft lightcraft soundcraft"

for app in $APPS; do
  if [ "$LATEST" = 1 ]; then
    tag=$(gh api "repos/$OWNER/$app/releases/latest" --jq .tag_name)
  else
    ver=$(grep -E "^${app}[[:space:]]" "$PINS" | awk '{print $2}')
    [ -n "$ver" ] || { echo "gen-lock: $app missing from pins.txt" >&2; exit 1; }
    tag="v$ver"
  fi
  ver=${tag#v}
  rel=$(gh api "repos/$OWNER/$app/releases/tags/$tag")
  # GitHub's detector reports only one licence; the upstream repos ship LICENSE-MIT and LICENSE-APACHE.
  files=$(gh api "repos/$OWNER/$app/contents" --jq '.[].name')
  if echo "$files" | grep -qx 'LICENSE-MIT' && echo "$files" | grep -qx 'LICENSE-APACHE'; then
    lic="MIT OR Apache-2.0"
  else
    lic=$(gh api "repos/$OWNER/$app" --jq '.license.spdx_id // "unknown"')
  fi
  sums=$(curl -fsSL "https://github.com/$OWNER/$app/releases/download/$tag/SHA256SUMS.txt" || true)

  pick() { # regex -> "name size sha256"
    echo "$rel" | jq -r --arg re "$1" '[.assets[] | select(.name|test($re))] | if length==1 then .[0] | "\(.name) \(.size) \(.digest|sub("^sha256:";""))" else error("expected exactly one asset matching \($re), got \(length)") end'
  }
  cli=$(pick "^$app-cli-$ver-macos-universal\\.zip\$")
  gui=$(pick "^$app-$ver-macos-universal\\.dmg\$")

  for line in "$cli" "$gui"; do
    name=${line%% *}; sha=${line##* }
    if [ -n "$sums" ]; then
      echo "$sums" | grep -q "$sha  *\*\{0,1\}$name\$" \
        || { echo "gen-lock: $app: $name sha256 not confirmed by SHA256SUMS.txt" >&2; exit 1; }
    else
      echo "gen-lock: warning: $app $tag has no SHA256SUMS.txt; using GitHub API digest only" >&2
    fi
  done

  IFS='|' read -r bundle mode extra kind <<EOF
$(meta "$app")
EOF
  set -- $cli; cname=$1; csize=$2; csha=$3
  set -- $gui; gname=$1; gsize=$2; gsha=$3
  base="https://github.com/$OWNER/$app/releases/download/$tag"
  jq -n --arg app "$app" --arg ver "$ver" --arg tag "$tag" --arg lic "$lic" --arg kind "$kind" \
        --arg mode "$mode" --argjson extra "$extra" --arg bundle "$bundle" \
        --arg cname "$cname" --argjson csize "$csize" --arg csha "$csha" \
        --arg gname "$gname" --argjson gsize "$gsize" --arg gsha "$gsha" --arg base "$base" \
        --arg repo "https://github.com/$OWNER/$app" \
    '{($app): {version:$ver, tag:$tag, kind:$kind, license:$lic, repo:$repo, fence:$mode, extraArgs:$extra,
       cli:{asset:$cname, url:($base+"/"+$cname), size:$csize, sha256:$csha},
       gui:{asset:$gname, url:($base+"/"+$gname), size:$gsize, sha256:$gsha, bundle:$bundle}}}' >> "$entries"
  echo "locked $app $tag" >&2
done

jq -s --arg owner "$OWNER" '{schema:1, owner:$owner, apps:(add)}' "$entries" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT" >&2
