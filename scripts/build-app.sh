#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Suse.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Suse" "$app_dir/Contents/MacOS/Suse"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift .build/Suse.iconset
iconutil --convert icns .build/Suse.iconset --output "$app_dir/Contents/Resources/Suse.icns"
# Set SIGNING_IDENTITY to a local Apple Development identity for stable TCC grants.
codesign --force --deep --sign "${SIGNING_IDENTITY:--}" "$app_dir"
print -r -- "$app_dir"
