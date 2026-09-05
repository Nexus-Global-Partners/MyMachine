#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/MY MACHINE.app"
CONTENTS_DIR="$APP_DIR/Contents"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
APP_ARCHIVE="$OUTPUT_DIR/MY-MACHINE-$VERSION.zip"
SOURCE_ARCHIVE="$OUTPUT_DIR/MY-MACHINE-Source-$VERSION.zip"
CHECKSUM_FILE="$OUTPUT_DIR/SHA256SUMS-$VERSION.txt"
SIGNING_IDENTITY="${MY_MACHINE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${MY_MACHINE_NOTARY_PROFILE:-}"

if [[ "${MY_MACHINE_REQUIRE_NOTARIZATION:-0}" == "1" && ( -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ) ]]; then
  echo "A distribution build requires Developer ID signing and a Keychain notary profile." >&2
  exit 1
fi
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Use a Developer ID Application identity for distribution." >&2
  exit 1
fi
if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
  echo "Notarization requires a Developer ID Application identity." >&2
  exit 1
fi

SOURCE_STAGE="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "$SOURCE_STAGE"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
swift build -c release --product DailyMac

# `outputs/` is entirely generated. Replacing it on every package prevents stale
# app bundles and old release archives from quietly consuming disk space.
/bin/rm -rf "$OUTPUT_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/bin/cp ".build/release/DailyMac" "$CONTENTS_DIR/MacOS/DailyMac"
/bin/cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "Resources/MyMachine.icns" "$CONTENTS_DIR/Resources/MyMachine.icns"
/bin/cp "Resources/MyMachineMenuIcon.png" "$CONTENTS_DIR/Resources/MyMachineMenuIcon.png"
/bin/chmod 755 "$CONTENTS_DIR/MacOS/DailyMac"
/usr/bin/strip -S -x "$CONTENTS_DIR/MacOS/DailyMac"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "Resources/DailyMac.entitlements" --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  echo "Development build only: ad-hoc signed, not notarized." >&2
  /usr/bin/codesign --force --options runtime --timestamp=none --entitlements "Resources/DailyMac.entitlements" --sign - "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

/bin/rm -f "$APP_ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ARCHIVE"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$APP_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  /usr/sbin/spctl --assess --type execute "$APP_DIR"
  /bin/rm -f "$APP_ARCHIVE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ARCHIVE"
fi

/bin/mkdir -p "$SOURCE_STAGE/MY-MACHINE-Source"
/usr/bin/rsync -a \
  --exclude '.build' \
  --exclude '.DS_Store' \
  --exclude 'outputs' \
  --exclude 'work' \
  --exclude '.git' \
  "$PROJECT_DIR/Package.swift" \
  "$PROJECT_DIR/.gitignore" \
  "$PROJECT_DIR/LICENSE" \
  "$PROJECT_DIR/README.md" \
  "$PROJECT_DIR/HANDOFF.md" \
  "$PROJECT_DIR/CONTRIBUTING.md" \
  "$PROJECT_DIR/SECURITY.md" \
  "$PROJECT_DIR/CHANGELOG.md" \
  "$PROJECT_DIR/PRIVACY.md" \
  "$PROJECT_DIR/.github" \
  "$PROJECT_DIR/Sources" \
  "$PROJECT_DIR/Resources" \
  "$PROJECT_DIR/scripts" \
  "$SOURCE_STAGE/MY-MACHINE-Source/"
/bin/rm -f "$SOURCE_ARCHIVE"
/usr/bin/ditto --norsrc -c -k --keepParent "$SOURCE_STAGE/MY-MACHINE-Source" "$SOURCE_ARCHIVE"

/bin/rm -f "$CHECKSUM_FILE"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "${APP_ARCHIVE:t}" "${SOURCE_ARCHIVE:t}" > "${CHECKSUM_FILE:t}"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_FILE:t}"
)

echo "Packaged: $APP_DIR"
echo "Archive: $APP_ARCHIVE"
echo "Source archive: $SOURCE_ARCHIVE"
echo "Checksums: $CHECKSUM_FILE"
