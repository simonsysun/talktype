#!/bin/bash
# Build TalkType, and sign it so the Accessibility permission survives the update.
#
# The Xcode project stays on ad-hoc signing so that `git clone && xcodebuild` works for
# anyone. Signing with the certificate happens here instead, and is skipped with a warning
# when the certificate is absent — see scripts/make-signing-cert.sh for what it buys.
#
#   scripts/build.sh            build and sign
#   scripts/build.sh install    ... and replace /Applications/TalkType.app
#   scripts/build.sh release    ... and also produce dist/TalkType-<version>.zip

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="TalkType Signing"
DERIVED="${TMPDIR:-/tmp}/talktype-build"
ACTION="${1:-}"

echo "Building..."
xcodebuild -scheme TalkType -configuration Release \
    -derivedDataPath "$DERIVED" build > "$DERIVED.log" 2>&1 || {
        echo "Build failed:"; grep -E "error:" "$DERIVED.log" | head -20; exit 1; }

APP="$DERIVED/Build/Products/Release/TalkType.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "Signing as \"$IDENTITY\"..."
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "WARNING: \"$IDENTITY\" not found — leaving the ad-hoc signature."
    echo "         Anyone updating from an earlier build will have to grant"
    echo "         Accessibility again. Run scripts/make-signing-cert.sh first."
fi

echo
echo "TalkType $VERSION"
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/  /'
echo "  $APP"

if [ "$ACTION" = "install" ] || [ "$ACTION" = "release" ]; then
    echo
    echo "Installing to /Applications..."
    osascript -e 'tell application "TalkType" to quit' 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -f "TalkType.app/Contents/MacOS/TalkType" >/dev/null || break
        sleep 0.3
    done
    rm -rf /Applications/TalkType.app
    ditto "$APP" /Applications/TalkType.app
    xattr -dr com.apple.quarantine /Applications/TalkType.app 2>/dev/null || true
    echo "  /Applications/TalkType.app"
fi

if [ "$ACTION" = "release" ]; then
    echo
    mkdir -p dist && rm -f "dist/TalkType-$VERSION.zip"
    # ditto, not zip: preserves the signature and resource forks inside the bundle.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/TalkType-$VERSION.zip"
    echo "  dist/TalkType-$VERSION.zip  ($(du -h "dist/TalkType-$VERSION.zip" | cut -f1))"
fi
