#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2015,SC2016,SC2034,SC2046,SC2086,SC2155,SC2317
# Build the offline test fixtures: fake release assets for all 13 apps and a fixture lockfile.
#
#   tests/fixtures/build.sh [--force] [--quiet]
#
# Output (all git-ignored):
#   tests/fixtures/out/<cli asset>.zip   one tiny zip per app: a fake <app>-cli (fake-cli.py), layout like the real
#                                        releases (<app>-cli-<ver>-macos-universal/<app>-cli); soundcraft uses a flat layout
#   tests/fixtures/out/<gui asset>.dmg   one small real disk image per app holding <Bundle>.app (ad-hoc signed, with an
#                                        Info.plist whose CFBundleShortVersionString is the app version)
#   tests/fixtures/apps.lock.json        lock schema 1 for these files: same apps, versions, fences and extraArgs as
#                                        manifest/apps.lock.json, but asset sizes and sha256 of the fixtures
#                                        and URLs on a github.com owner that does not exist, so an accidental network
#                                        fetch fails fast instead of downloading the real (large) releases.
#
# Use them with tests/isolated.sh (CRAFT_KIT_LOCK=tests/fixtures/apps.lock.json, CRAFT_KIT_OFFLINE_DIR=tests/fixtures/out).
# Re-running is a no-op while the inputs are unchanged and the files verify (--force rebuilds).
# Needs macOS (hdiutil, codesign), jq, python3. Bash 3.2 compatible.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
REAL_LOCK=${CRAFT_KIT_REAL_LOCK:-$REPO/manifest/apps.lock.json}
OUT=$HERE/out
LOCK_OUT=$HERE/apps.lock.json
OWNER=craft-kit-fixtures
FORCE=0
QUIET=0

die() {
  echo "fixtures/build.sh: $*" >&2
  exit 1
}
say() { if [ "$QUIET" = 0 ]; then echo "$*"; fi; }

while [ $# -gt 0 ]; do
  case $1 in
    --force) FORCE=1 ;;
    -q | --quiet) QUIET=1 ;;
    -h | --help)
      sed -n '3,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || die "the fixtures need macOS (hdiutil, codesign)"
for tool in jq python3 hdiutil codesign shasum; do
  command -v "$tool" > /dev/null 2>&1 || die "missing required tool: $tool"
done
[ -f "$REAL_LOCK" ] || die "lock not found: $REAL_LOCK"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
size_of() { stat -f %z "$1"; }

stamp() { cat "$REAL_LOCK" "$HERE/fake-cli.py" "$HERE/make_cli_zip.py" "$HERE/build.sh" | shasum -a 256 | cut -d' ' -f1; }

fixtures_ok() { # 0 when out/ and the fixture lock match the current inputs and verify
  [ -f "$LOCK_OUT" ] && [ -f "$OUT/.stamp" ] || return 1
  [ "$(cat "$OUT/.stamp")" = "$(stamp)" ] || return 1
  jq -e '.schema == 1' "$LOCK_OUT" > /dev/null 2>&1 || return 1
  local rows asset sha
  rows=$(jq -r '.apps[] | .cli.asset + "\t" + .cli.sha256, .gui.asset + "\t" + .gui.sha256' "$LOCK_OUT") || return 1
  [ -n "$rows" ] || return 1
  while IFS="$(printf '\t')" read -r asset sha; do
    [ -f "$OUT/$asset" ] || return 1
    [ "$(sha256_of "$OUT/$asset")" = "$sha" ] || return 1
  done <<EOF
$rows
EOF
  return 0
}

LOCKDIR=$HERE/.build.lock
have_lock=0
acquire_lock() {
  local i=0
  until mkdir "$LOCKDIR" 2> /dev/null; do
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +10 2> /dev/null)" ]; then
      rmdir "$LOCKDIR" 2> /dev/null || true
      continue
    fi
    i=$((i + 1))
    [ "$i" -le 300 ] || die "another build holds $LOCKDIR (remove it if no build is running)"
    sleep 1
  done
  have_lock=1
}

NEW=$HERE/out.new
cleanup() {
  rm -rf "$NEW"
  if [ "$have_lock" = 1 ]; then rmdir "$LOCKDIR" 2> /dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

acquire_lock
if [ "$FORCE" = 0 ] && fixtures_ok; then
  say "fixtures up to date ($OUT)"
  exit 0
fi

rm -rf "$NEW"
mkdir -p "$NEW"
say "building fixtures in $OUT ..."

make_dmg() { # APP VERSION BUNDLE DMGFILE
  local app=$1 version=$2 bundle=$3 dmg=$4 stage name
  name=${bundle%.app}
  stage=$NEW/stage-$app
  mkdir -p "$stage/$bundle/Contents/MacOS"
  cat > "$stage/$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>invalid.craft-kit-fixtures.$app</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
</dict>
</plist>
PLIST
  cp /usr/bin/true "$stage/$bundle/Contents/MacOS/$name"
  codesign --force --deep --sign - "$stage/$bundle" > /dev/null 2>&1
  # Real release images carry Finder info on their files; a plain copy then fails codesign --strict.
  xattr -wx com.apple.FinderInfo "$(printf '0%.0s' $(seq 1 19))2$(printf '0%.0s' $(seq 1 44))" \
    "$stage/$bundle" "$stage/$bundle/Contents" "$stage/$bundle/Contents/MacOS" "$stage/$bundle/Contents/MacOS/$name"
  hdiutil create -srcfolder "$stage" -volname "$name" -format UDZO -ov -quiet "$dmg"
  rm -rf "$stage"
}

apps=$(jq -r '.apps | keys_unsorted[]' "$REAL_LOCK")
: > "$NEW/overrides.ndjson"
pids=""
dmg_apps=""
for app in $apps; do
  field() { jq -r --arg a "$app" ".apps[\$a].$1" "$REAL_LOCK"; }
  version=$(field version)
  fence=$(field fence)
  cli_asset=$(field cli.asset)
  gui_asset=$(field gui.asset)
  bundle=$(field gui.bundle)
  layout=nested
  [ "$app" != soundcraft ] || layout=flat
  python3 -I "$HERE/make_cli_zip.py" --app "$app" --version "$version" --fence "$fence" --layout "$layout" \
    --out "$NEW/$cli_asset" > /dev/null || die "could not build $cli_asset"
  # up to 4 disk images at a time: hdiutil create takes a few seconds each
  make_dmg "$app" "$version" "$bundle" "$NEW/$gui_asset" &
  pids="$pids $!"
  dmg_apps="$dmg_apps $app"
  if [ "$(echo "$pids" | wc -w | tr -d ' ')" -ge 4 ]; then
    for p in $pids; do wait "$p" || die "hdiutil failed building a disk image (run it by hand: hdiutil create -srcfolder DIR -format UDZO x.dmg)"; done
    pids=""
  fi
done
for p in $pids; do wait "$p" || die "hdiutil failed building a disk image"; done

for app in $apps; do
  cli_asset=$(jq -r --arg a "$app" '.apps[$a].cli.asset' "$REAL_LOCK")
  gui_asset=$(jq -r --arg a "$app" '.apps[$a].gui.asset' "$REAL_LOCK")
  [ -f "$NEW/$cli_asset" ] && [ -f "$NEW/$gui_asset" ] || die "missing built asset for $app"
  jq -n --arg app "$app" \
    --arg ca "$cli_asset" --arg cs "$(sha256_of "$NEW/$cli_asset")" --argjson cz "$(size_of "$NEW/$cli_asset")" \
    --arg ga "$gui_asset" --arg gs "$(sha256_of "$NEW/$gui_asset")" --argjson gz "$(size_of "$NEW/$gui_asset")" \
    '{($app): {cli: {asset: $ca, sha256: $cs, size: $cz}, gui: {asset: $ga, sha256: $gs, size: $gz}}}' >> "$NEW/overrides.ndjson"
done

jq --slurpfile ov "$NEW/overrides.ndjson" --arg owner "$OWNER" '
  ($ov | add) as $o
  | {schema: 1, owner: $owner,
     apps: (.apps | to_entries | map(
       .key as $k | .value as $v
       | {key: $k, value: {
           version: $v.version, tag: $v.tag, kind: $v.kind, license: $v.license,
           repo: ("https://github.com/" + $owner + "/" + $k),
           fence: $v.fence, extraArgs: $v.extraArgs,
           cli: {asset: $o[$k].cli.asset,
                 url: ("https://github.com/" + $owner + "/" + $k + "/releases/download/" + $v.tag + "/" + $o[$k].cli.asset),
                 size: $o[$k].cli.size, sha256: $o[$k].cli.sha256},
           gui: {asset: $o[$k].gui.asset,
                 url: ("https://github.com/" + $owner + "/" + $k + "/releases/download/" + $v.tag + "/" + $o[$k].gui.asset),
                 size: $o[$k].gui.size, sha256: $o[$k].gui.sha256, bundle: $v.gui.bundle}}}
     ) | from_entries)}' "$REAL_LOCK" > "$NEW/apps.lock.json"
jq -e '.schema == 1 and (.apps | length) >= 1' "$NEW/apps.lock.json" > /dev/null || die "generated an invalid fixture lock"

rm -f "$NEW/overrides.ndjson"
stamp > "$NEW/.stamp"
rm -rf "$OUT"
mv "$NEW" "$OUT"
mv "$OUT/apps.lock.json" "$LOCK_OUT.tmp-$$"
mv "$LOCK_OUT.tmp-$$" "$LOCK_OUT"
n=$(jq '.apps | length' "$LOCK_OUT")
say "built $n fake CLI zips and $n fake dmgs; lock: $LOCK_OUT"
