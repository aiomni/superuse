#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
signing_identity="${SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f .signing-identity.local ]]; then
    signing_identity="$(< .signing-identity.local)"
fi
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    print -u2 -- '请设置 SIGNING_IDENTITY，或在 .signing-identity.local 中填写代码签名证书的 SHA-1 / 名称。'
    print -u2 -- '为保持录屏授权身份稳定，打包不会自动退回临时签名。'
    exit 1
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Suse.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Suse" "$app_dir/Contents/MacOS/Suse"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift .build/Suse.iconset
iconutil --convert icns .build/Suse.iconset --output "$app_dir/Contents/Resources/Suse.icns"
# Let codesign derive a certificate-bound requirement; never use an identifier-only requirement.
/usr/bin/codesign --force --sign "$signing_identity" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"
