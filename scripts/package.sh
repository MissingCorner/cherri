#!/bin/bash
#
# Builds the production installer: Cherri-<version>.pkg containing
#   - Cherri.app            → /Applications
#   - MIAgentAudio.driver   → /Library/Audio/Plug-Ins/HAL (+ coreaudiod restart)
#
# Signing: uses "Developer ID Application" / "Developer ID Installer"
# identities when present (real distribution); otherwise falls back to the
# best available identity (e.g. self-signed "Cherri Dev") and prints a
# warning — such a pkg installs fine locally but Gatekeeper will block it on
# other Macs until it is Developer ID-signed and notarized (make notarize).

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD=build
STAGE="$BUILD/pkg"
APP="$BUILD/Cherri.app"
DRIVER="$BUILD/MIAgentAudio.driver"
ENTITLEMENTS="App/Resources/Cherri.entitlements"
OUT="$BUILD/Cherri-$VERSION.pkg"

[ -d "$APP" ] && [ -d "$DRIVER" ] || { echo "Run 'make' first."; exit 1; }

# ---------------------------------------------------------------- identities
DEV_ID_APP=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)
DEV_ID_INST=$(security find-identity -v 2>/dev/null \
    | grep -m1 -o '"Developer ID Installer[^"]*"' | tr -d '"' || true)
FALLBACK_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -o '"[^"]*"' | tr -d '"' || true)

SIGN_ID="${DEV_ID_APP:-${FALLBACK_ID:--}}"

if [ -n "$DEV_ID_APP" ]; then
    echo "Signing with: $DEV_ID_APP (production)"
    TIMESTAMP="--timestamp"
else
    echo "WARNING: no Developer ID certificate — signing with '$SIGN_ID'."
    echo "         The pkg works on this Mac; other Macs need Developer ID + notarization."
    TIMESTAMP="--timestamp=none"
fi

# ------------------------------------------------------------------- signing
# Hardened runtime everywhere; the app carries the audio-input entitlement.
codesign --force $TIMESTAMP --options runtime --sign "$SIGN_ID" "$DRIVER"
codesign --force $TIMESTAMP --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$DRIVER"

# ------------------------------------------------------------------- staging
rm -rf "$STAGE"
mkdir -p "$STAGE/approot" "$STAGE/driverroot" "$STAGE/scripts"
cp -R "$APP" "$STAGE/approot/"
cp -R "$DRIVER" "$STAGE/driverroot/"

cat > "$STAGE/scripts/postinstall" <<'EOS'
#!/bin/bash
# Restart Core Audio so the freshly installed driver loads.
killall -9 coreaudiod 2>/dev/null || true
exit 0
EOS
chmod +x "$STAGE/scripts/postinstall"

# ---------------------------------------------------------------- components
# BundleIsRelocatable=false: otherwise the installer "updates" any existing
# copy of the app it can find (e.g. a dev build) instead of /Applications.
pkgbuild --analyze --root "$STAGE/approot" "$STAGE/app-components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/app-components.plist"

pkgbuild --root "$STAGE/approot" \
    --component-plist "$STAGE/app-components.plist" \
    --identifier com.missingcorner.miagent \
    --version "$VERSION" \
    --install-location /Applications \
    "$STAGE/CherriApp.pkg" >/dev/null

pkgbuild --root "$STAGE/driverroot" \
    --identifier com.missingcorner.miagent.audiodriver \
    --version "$VERSION" \
    --install-location "/Library/Audio/Plug-Ins/HAL" \
    --scripts "$STAGE/scripts" \
    "$STAGE/CherriDriver.pkg" >/dev/null

# -------------------------------------------------------------- distribution
cat > "$STAGE/distribution.xml" <<EOS
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Cherri</title>
    <welcome mime-type="text/plain"><![CDATA[Cherri installs the app and its virtual audio driver. Core Audio restarts at the end of installation — any audio playing will glitch for a moment.]]></welcome>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"><line choice="app"/><line choice="driver"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="com.missingcorner.miagent"/></choice>
    <choice id="driver" visible="false"><pkg-ref id="com.missingcorner.miagent.audiodriver"/></choice>
    <pkg-ref id="com.missingcorner.miagent" version="$VERSION">CherriApp.pkg</pkg-ref>
    <pkg-ref id="com.missingcorner.miagent.audiodriver" version="$VERSION">CherriDriver.pkg</pkg-ref>
</installer-gui-script>
EOS

if [ -n "$DEV_ID_INST" ]; then
    productbuild --distribution "$STAGE/distribution.xml" \
        --package-path "$STAGE" --sign "$DEV_ID_INST" "$OUT"
else
    productbuild --distribution "$STAGE/distribution.xml" \
        --package-path "$STAGE" "$OUT"
    [ -z "$DEV_ID_APP" ] || echo "NOTE: no 'Developer ID Installer' identity — pkg itself is unsigned."
fi

echo ""
echo "Package ready: $OUT"
if [ -n "$DEV_ID_APP" ]; then
    echo "Next: make notarize  (requires APPLE_ID, TEAM_ID, APP_PASSWORD env vars)"
fi
