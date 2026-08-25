#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/MY MACHINE.app"
CONTENTS_DIR="$APP_DIR/Contents"
SOURCE_STAGE="$(mktemp -d)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
APP_ARCHIVE="$OUTPUT_DIR/MY-MACHINE-$VERSION.zip"
SOURCE_ARCHIVE="$OUTPUT_DIR/MY-MACHINE-Source-$VERSION.zip"
CHECKSUM_FILE="$OUTPUT_DIR/SHA256SUMS-$VERSION.txt"

cleanup() {
  /bin/rm -rf "$SOURCE_STAGE"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
swift build -c release --product DailyMac

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/bin/cp ".build/release/DailyMac" "$CONTENTS_DIR/MacOS/DailyMac"
/bin/cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "Resources/MyMachine.icns" "$CONTENTS_DIR/Resources/MyMachine.icns"
/bin/cp "Resources/MyMachineMenuIcon.png" "$CONTENTS_DIR/Resources/MyMachineMenuIcon.png"
/bin/chmod 755 "$CONTENTS_DIR/MacOS/DailyMac"
/usr/bin/strip -S -x "$CONTENTS_DIR/MacOS/DailyMac"

/usr/bin/codesign --force --deep --options runtime --timestamp=none --entitlements "Resources/DailyMac.entitlements" --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

/bin/rm -f "$APP_ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ARCHIVE"

/bin/mkdir -p "$SOURCE_STAGE/MY-MACHINE-Source"
/usr/bin/rsync -a \
  --exclude '.build' \
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
