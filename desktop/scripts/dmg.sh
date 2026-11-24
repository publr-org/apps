#!/bin/sh
# Publr Desktop's installer: builds the app, signs it with the Developer ID, lays it out in
# a disk image (the app, an arrow, Applications) and has Apple notarise it.
#
#   scripts/dmg.sh                 signed, notarised: dist/Publr-Desktop-<version>-macos-<cpu>.dmg,
#                                  with SHA256SUMS and SHA256SUMS.sig, a release as Desktop's
#                                  updates take it (src/update.zig)
#   scripts/dmg.sh --local         ad-hoc signed, not notarised, to check the window
#
# Needs a "Developer ID Application" certificate in the keychain and the notary login saved
# once as "publr-notary" (xcrun notarytool store-credentials publr-notary ...).
# PUBLR_SIGN_IDENTITY and PUBLR_NOTARY_PROFILE pick others. The checksums are signed with
# Publr's release key (~/.publr/release-signing-key.pem, or PUBLR_SIGNING_KEY_FILE) by
# OpenSSL 3 (Homebrew's; the system's LibreSSL cannot).
set -eu

cd "$(dirname "$0")/.."

LOCAL=0
[ "${1:-}" = "--local" ] && LOCAL=1

NAME="Publr Desktop"
PROFILE="${PUBLR_NOTARY_PROFILE:-publr-notary}"
VERSION=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon | head -1)
case "$(uname -m)" in
    arm64) CPU=aarch64 ;;
    *) CPU="$(uname -m)" ;;
esac
DMG="dist/Publr-Desktop-$VERSION-macos-$CPU.dmg"
KEY="${PUBLR_SIGNING_KEY_FILE:-$HOME/.publr/release-signing-key.pem}"

if [ "$LOCAL" = 1 ]; then
    IDENTITY="-"
else
    IDENTITY="${PUBLR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
    if [ -z "$IDENTITY" ]; then
        echo "No \"Developer ID Application\" certificate in the keychain." >&2
        echo "Make one in Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application." >&2
        exit 1
    fi
    if [ ! -f "$KEY" ]; then
        echo "No release signing key at $KEY." >&2
        exit 1
    fi
    if ! openssl version | grep -q "^OpenSSL 3"; then
        echo "The checksums need OpenSSL 3 (brew install openssl), not $(openssl version)." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "No notary login saved as \"$PROFILE\". Save it once with:" >&2
        echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id <team id> --password <app-specific password>" >&2
        exit 1
    fi
fi

echo "==> Building $NAME $VERSION"
zig build app -Doptimize=safe

echo "==> Signing with: $IDENTITY"
rm -rf dist
mkdir -p dist/stage/.background
APP="dist/stage/$NAME.app"
ditto "zig-out/$NAME.app" "$APP"
# The inside first, then the app around it.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/publr"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Making the disk image"
if [ -e "/Volumes/$NAME" ]; then
    echo "A disk named \"$NAME\" is open already: eject it first (Finder would lay out that one)." >&2
    exit 1
fi
ln -s /Applications dist/stage/Applications
tiffutil -cathidpicheck assets/dmg/background.png assets/dmg/background@2x.png \
    -out dist/stage/.background/background.tiff 2>/dev/null

hdiutil create -quiet -volname "$NAME" -srcfolder dist/stage -fs HFS+ -format UDRW \
    -size 400m dist/rw.dmg
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen dist/rw.dmg |
    sed -n 's|^\(/dev/disk[0-9]*\).*Apple_HFS.*|\1|p')
MOUNT="/Volumes/$NAME"
trap 'hdiutil detach -quiet -force "$DEVICE" 2>/dev/null || true' EXIT
# Finder writes the window's look into the volume's .DS_Store. The first run asks to let
# the terminal control Finder.
osascript <<EOF
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {180, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
# The disk's own icon, after Finder: it removes the file while it lays the window out.
cp assets/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
chflags hidden "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
sync
hdiutil detach -quiet "$DEVICE"
trap - EXIT
hdiutil convert -quiet dist/rw.dmg -format ULFO -o "$DMG"
rm dist/rw.dmg
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$LOCAL" = 1 ]; then
    echo "==> $DMG (ad-hoc signed, not notarised: only for checking the window)"
    exit 0
fi

echo "==> Notarising (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "==> Signing the checksums"
(cd dist && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS &&
    openssl pkeyutl -sign -inkey "$KEY" -rawin -in SHA256SUMS -out SHA256SUMS.sig)
echo "==> $DMG, SHA256SUMS and SHA256SUMS.sig are ready to hand out as release v$VERSION"
