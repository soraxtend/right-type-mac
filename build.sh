#!/bin/zsh
# Build RightType.app: the Rust core as a static library, the Swift app on top.
#   ./build.sh            build into build/RightType.app
#   ./build.sh install    also copy it to /Applications
#   ./build.sh dist       also pack it as a disk image (.dmg) to share
#   ./build.sh test       run the core's tests instead
#
# Signing: ad-hoc by default. With an Apple Developer ID, set
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
# and, for `dist`, NOTARY_PROFILE (made once with
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id …)
# to sign and notarize, so the app opens with no Gatekeeper warning.
set -euo pipefail
cd "${0:a:h}"

export MACOSX_DEPLOYMENT_TARGET=13.0
# Rust keeps source paths in the binary (for panic messages); without this they
# would name the builder's home folder, and with it their user name.
export RUSTFLAGS="--remap-path-prefix=$HOME=/build"
# rustup's standard library is built for macOS 11; Homebrew's `rust` formula
# ships one built for the macOS it was bottled on (26), which older Macs
# cannot run. Use rustup's when it is there (Homebrew's `rustup` is keg-only).
RUSTUP=$(command -v rustup || true)
[[ -z "$RUSTUP" && -x /opt/homebrew/opt/rustup/bin/rustup ]] && RUSTUP=/opt/homebrew/opt/rustup/bin/rustup
core_cargo() {
    if [[ -n "$RUSTUP" ]]; then
        # The toolchain's own cargo and rustc, whatever else is on PATH.
        local toolchain=$("$RUSTUP" run stable rustc --print sysroot)
        PATH="$toolchain/bin:$PATH" RUSTC="$toolchain/bin/rustc" "$toolchain/bin/cargo" "$@" --manifest-path core/Cargo.toml
    else
        cargo "$@" --manifest-path core/Cargo.toml
    fi
}
if [[ "${1:-}" == test ]]; then
    # The debug profile: release strips the test binary, which rustup's
    # minimal toolchain has no objcopy for.
    shift
    core_cargo test "$@"
    exit
fi
core_cargo build --release

APP=build/RightType.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
# The icon is drawn by tools/make_icon.swift; redraw it if missing.
[[ -f app/AppIcon.icns ]] || swift tools/make_icon.swift
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

LINK_LOG=$(mktemp)
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -import-objc-header core/include/righttype.h \
    -L core/target/release -lrighttype_mac_core \
    -framework AppKit -framework Carbon -framework ServiceManagement \
    app/Sources/*.swift \
    -o "$APP/Contents/MacOS/RightType" 2> >(tee "$LINK_LOG" >&2)
# An object built for a newer macOS than the app's minimum would stop the app
# from opening there: refuse it rather than ship it.
if grep -q "was built for newer 'macOS' version" "$LINK_LOG"; then
    rm -f "$LINK_LOG"
    echo "error: part of the Rust core is built for a newer macOS than 13.0." >&2
    echo "       Install rustup (brew install rustup) and build again." >&2
    exit 1
fi
rm -f "$LINK_LOG"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    # Hardened runtime and a secure timestamp: what notarization asks for.
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
    # Ad-hoc signature: macOS ties the Accessibility permission to it, so after
    # a rebuild you need to remove RightType from that list and add it again.
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == install ]]; then
    pkill -x RightType 2>/dev/null || true
    rm -rf /Applications/RightType.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/RightType.app"
fi

if [[ "${1:-}" == dist ]]; then
    # A disk image with the app next to a shortcut to Applications: open it,
    # drag one onto the other (see INSTALL.md).
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" app/Info.plist)
    DMG="build/RightType-mac-$VERSION-$(uname -m).dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname RightType -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
    rm -rf "$STAGE"
    if [[ -n "${DEVELOPER_ID:-}" ]]; then
        codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
        if [[ -n "${NOTARY_PROFILE:-}" ]]; then
            xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$DMG"
        fi
    fi
    # Just the file name, so whoever receives both can check from any folder.
    (cd build && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")
    echo "Packed $DMG"
fi
