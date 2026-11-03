#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

: "${MYMACHINE_DEVELOPER_TEAM:?Expected Apple Developer Team ID}"
: "${MYMACHINE_APPLICATION_IDENTITY:?Developer ID Application signing identity}"
: "${MYMACHINE_INSTALLER_IDENTITY:?Developer ID Installer signing identity}"
: "${MYMACHINE_NOTARY_PROFILE:?notarytool Keychain profile}"
[[ "$MYMACHINE_DEVELOPER_TEAM" =~ '^[A-Z0-9]{10}$' ]] || exit 64

cd "${0:A:h:h}"
./scripts/package.sh
stage="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$stage"' EXIT
/bin/mkdir "$stage/scripts"
app="$stage/scripts/MY MACHINE.app"
/usr/bin/ditto --noacl --noqtn 'outputs/MY MACHINE.app' "$app"
# Build both supported CPU architectures for the official release.
swift build -c release --product DailyMac --arch arm64 --arch x86_64
bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
/usr/bin/lipo -verify_arch arm64 x86_64 "$bin_dir/DailyMac"
/bin/cp "$bin_dir/DailyMac" "$app/Contents/MacOS/DailyMac"
/usr/bin/strip -S -x "$app/Contents/MacOS/DailyMac"
/bin/mkdir -p "$app/Contents/Library/LaunchDaemons"
/bin/cp Resources/local.mymachine.fancontrol.service.plist "$app/Contents/Library/LaunchDaemons/"
/usr/libexec/PlistBuddy -c "Add :MyMachineDeveloperTeam string $MYMACHINE_DEVELOPER_TEAM" "$app/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --timestamp --sign "$MYMACHINE_APPLICATION_IDENTITY" "$app"
requirement="anchor apple generic and identifier \"local.mymachine.app\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$MYMACHINE_DEVELOPER_TEAM\""
/usr/bin/codesign --verify --strict --deep --all-architectures -R "$requirement" "$app"
# Staple the app separately so Service Management can assess it offline.
/usr/bin/ditto -c -k --keepParent "$app" "$stage/app.zip"
/usr/bin/xcrun notarytool submit "$stage/app.zip" --keychain-profile "$MYMACHINE_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

/usr/bin/sed "s/@DEVELOPER_TEAM@/$MYMACHINE_DEVELOPER_TEAM/g" scripts/official-install-postinstall > "$stage/scripts/postinstall"
/bin/chmod 755 "$stage/scripts/postinstall"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
# Use a scripts-only component so Installer does not write through a
# pre-existing destination or relocate the app to a user-writable folder.
/usr/bin/pkgbuild --nopayload --scripts "$stage/scripts" --identifier local.mymachine.app.install \
    --version "$version.$build" "$stage/component.pkg"
cat > "$stage/distribution.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MY MACHINE</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="15.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="local.mymachine.app.install"/></choice>
  <pkg-ref id="local.mymachine.app.install">component.pkg</pkg-ref>
</installer-gui-script>
XML
/usr/bin/productbuild --distribution "$stage/distribution.xml" --package-path "$stage" \
    --sign "$MYMACHINE_INSTALLER_IDENTITY" "$stage/official.pkg"
/usr/bin/xcrun notarytool submit "$stage/official.pkg" --keychain-profile "$MYMACHINE_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$stage/official.pkg"
/usr/bin/xcrun stapler validate "$stage/official.pkg"
/usr/sbin/pkgutil --check-signature "$stage/official.pkg"
/usr/sbin/spctl --assess --type install "$stage/official.pkg"
output="outputs/MY-MACHINE-$version-$build-official.pkg"
/bin/mv "$stage/official.pkg" "$output"
(cd outputs && /usr/bin/shasum -a 256 "${output:t}" > "${output:t}.sha256")
print "Official installer ready for hardware validation: $output"
