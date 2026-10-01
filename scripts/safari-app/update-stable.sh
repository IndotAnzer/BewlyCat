#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
state_dir="$HOME/Library/Application Support/BewlyCat-Updater"
app="${BEWLYCAT_APP_PATH:-/Applications/BewlyCat.app}"
[[ "$app" == '/Applications/BewlyCat.app' ]]
signing_entitlements="${BEWLYCAT_ENTITLEMENTS:-$app/Contents/Resources/extension.entitlements}"
repo='IndotAnzer/BewlyCat'
mkdir -p "$state_dir"
if ! mkdir "$state_dir/lock" 2>/dev/null; then
  lock_pid=$(cat "$state_dir/lock/pid" 2>/dev/null || true)
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    unlink "$state_dir/lock/pid"
    rmdir "$state_dir/lock"
    mkdir "$state_dir/lock"
  else
    echo 'Another update is running.'
    exit 0
  fi
fi
echo "$$" > "$state_dir/lock/pid"
trap 'unlink "$state_dir/lock/pid"; rmdir "$state_dir/lock"' EXIT
release=$(curl --fail --silent --show-error --connect-timeout 15 --retry 2 --max-time 60 "https://api.github.com/repos/$repo/releases/latest")
tag=$(printf '%s' "$release" | jq -er 'select(.draft == false and .prerelease == false) | .tag_name')
[[ "$tag" =~ ^safari-v([0-9]+\.[0-9]+\.[0-9]+)-app2$ ]]
version="${BASH_REMATCH[1]}"
current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
revision=$(/usr/libexec/PlistBuddy -c 'Print :BewlyCatUpdaterRevision' "$app/Contents/Info.plist" 2>/dev/null || echo 0)
if [[ "$current" == "$version" && "$revision" == 2 ]]; then
  echo "Already installed: $version"
  exit 0
fi
if [[ "$current" != '1.0' ]] && ! /usr/bin/ruby -e 'exit(Gem::Version.new(ARGV[0]) >= Gem::Version.new(ARGV[1]) ? 0 : 1)' "$version" "$current"; then
  echo "No newer stable build: installed $current, available $version"
  exit 0
fi
archive_url=$(printf '%s' "$release" | jq -er '.assets[] | select(.name == "BewlyCat-Safari-macOS.zip") | .browser_download_url')
digest=$(printf '%s' "$release" | jq -er '.assets[] | select(.name == "BewlyCat-Safari-macOS.zip") | .digest')
[[ "$archive_url" == "https://github.com/$repo/releases/download/$tag/"* ]]
[[ "$digest" == sha256:* ]]
stage=$(mktemp -d "$state_dir/stage.XXXXXX")
mv "$stage" "$stage.noindex"
stage="$stage.noindex"
archive_cache="$state_dir/$tag.zip"
if [[ -f "$archive_cache" ]]; then
  ditto "$archive_cache" "$stage/BewlyCat-Safari-macOS.zip"
else
  curl --fail --location --silent --show-error --connect-timeout 15 --retry 2 --max-time 180 "$archive_url" -o "$stage/BewlyCat-Safari-macOS.zip"
fi
expected="${digest#sha256:}"
actual=$(shasum -a 256 "$stage/BewlyCat-Safari-macOS.zip" | awk '{print $1}')
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$expected" == "$actual" ]]
ditto "$stage/BewlyCat-Safari-macOS.zip" "$archive_cache"
ditto -x -k "$stage/BewlyCat-Safari-macOS.zip" "$stage/unpacked"
new_app="$stage/unpacked/BewlyCat.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist")" == 'com.keleus.BewlyCat' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new_app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BewlyCatUpdaterRevision' "$new_app/Contents/Info.plist")" == 2 ]]
codesign --verify --deep --strict "$new_app"
entitlements=$(codesign -d --entitlements :- "$new_app/Contents/PlugIns/BewlyCat Extension.appex" 2>/dev/null)
printf '%s' "$entitlements" | plutil -convert json -o - -- - | jq -e '.["com.apple.security.app-sandbox"] == true' >/dev/null
codesign --force --sign - --entitlements "$signing_entitlements" "$new_app/Contents/PlugIns/BewlyCat Extension.appex"
# The containing app must be able to replace its own app bundle; only the Safari extension is sandboxed.
codesign --force --sign - "$new_app"
codesign --verify --deep --strict "$new_app"
if [[ "${1:-}" == '--check-only' ]]; then
  echo "Verified stable update: $current -> $version ($stage)"
  exit 0
fi
mkdir -p "$state_dir/backups.noindex"
backup="$state_dir/backups.noindex/BewlyCat-$current-$(date +%Y%m%d%H%M%S).app"
mv "$app" "$backup"
rollback() {
  if [[ -e "$app" ]]; then mv "$app" "$stage/failed.app"; fi
  mv "$backup" "$app"
  pluginkit -a "$app/Contents/PlugIns/BewlyCat Extension.appex" || true
  echo 'Update failed; restored previous app.' >&2
}
if ! ditto "$new_app" "$app" || ! codesign --verify --deep --strict "$app" || ! pluginkit -a "$app/Contents/PlugIns/BewlyCat Extension.appex"; then
  rollback
  exit 1
fi
if ! '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -f "$app" || ! open -g -n "$app"; then
  rollback
  exit 1
fi
registered=false
for attempt in 1 2 3 4 5; do
  registration=$(pluginkit -mAv -p com.apple.Safari.web-extension || true)
  if printf '%s' "$registration" | /usr/bin/grep -Fq 'com.keleus.BewlyCat.Extension('; then
    registered=true
    break
  fi
  sleep 2
done
if [[ "$registered" != true ]]; then
  rollback
  exit 1
fi
echo "Installed stable version $version; previous app retained at $backup. Reload Bilibili pages."
