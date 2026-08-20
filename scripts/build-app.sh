#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
app_dir="${HOME}/Applications/Codex Provider Switcher.app"

cd "$project_dir"
bin_dir=$(swift build -c release --show-bin-path)

if [[ -e "$app_dir" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$existing_id" != "local.codex.provider-switcher" ]]; then
    print -u2 "Refusing to replace an unrelated path: $app_dir"
    exit 1
  fi
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$bin_dir/CodexProviderSwitcher" "$app_dir/Contents/MacOS/CodexProviderSwitcher"
install -m 644 "Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
