#!/bin/zsh
# Build RightType.app: the Rust core as a static library, the Swift app on top.
#   ./build.sh            build into build/RightType.app
#   ./build.sh install    also copy it to /Applications
#   ./build.sh dist       also pack it as a zip to share
set -euo pipefail
cd "${0:a:h}"

export MACOSX_DEPLOYMENT_TARGET=13.0
cargo build --release --manifest-path core/Cargo.toml

APP=build/RightType.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
# The icon is drawn by tools/make_icon.swift; redraw it if missing.
[[ -f app/AppIcon.icns ]] || swift tools/make_icon.swift
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -import-objc-header core/include/righttype.h \
    -L core/target/release -lrighttype_mac_core \
    -framework AppKit -framework Carbon -framework ServiceManagement \
    app/Sources/*.swift \
    -o "$APP/Contents/MacOS/RightType"

# Ad-hoc signature: macOS ties the Accessibility permission to it, so after a
# rebuild you may need to switch RightType off and on again in that list.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == install ]]; then
    pkill -x RightType 2>/dev/null || true
    rm -rf /Applications/RightType.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/RightType.app"
fi

if [[ "${1:-}" == dist ]]; then
    # A zip to hand to other people (see INSTALL.md for what they do with it).
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" app/Info.plist)
    ZIP="build/RightType-mac-$VERSION-$(uname -m).zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    # Just the file name, so whoever receives both can check from any folder.
    (cd build && shasum -a 256 "${ZIP:t}" | tee "${ZIP:t}.sha256")
    echo "Packed $ZIP"
fi
