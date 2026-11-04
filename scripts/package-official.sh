#!/bin/zsh -f
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

: "${MYMACHINE_DEVELOPER_TEAM:?Expected Apple Developer Team ID}"
: "${MYMACHINE_APPLICATION_IDENTITY:?Developer ID Application signing identity}"
: "${MYMACHINE_NOTARY_PROFILE:?notarytool Keychain profile}"
[[ "$MYMACHINE_DEVELOPER_TEAM" =~ '^[A-Z0-9]{10}$' ]] || exit 64

cd "${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { print -u2 'Release source must be clean.'; exit 1; }
[[ "$(git rev-list -n 1 "refs/tags/v$version")" == "$(git rev-parse HEAD)" ]] ||
  { print -u2 'Release source must match its version tag.'; exit 1; }
./scripts/package.sh
stage="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$stage"' EXIT
app="$stage/MY MACHINE.app"
/usr/bin/ditto --noacl --noqtn 'outputs/MY MACHINE.app' "$app"
# Build both supported CPU architectures for the official release.
swift build -c release --product DailyMac --arch arm64 --arch x86_64
bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
/usr/bin/lipo -verify_arch arm64 x86_64 "$bin_dir/DailyMac"
/bin/cp "$bin_dir/DailyMac" "$app/Contents/MacOS/DailyMac"
/usr/bin/strip -S -x "$app/Contents/MacOS/DailyMac"
/usr/bin/codesign --force --options runtime --timestamp --sign "$MYMACHINE_APPLICATION_IDENTITY" "$app"
requirement="anchor apple generic and identifier \"local.mymachine.app\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$MYMACHINE_DEVELOPER_TEAM\""
/usr/bin/codesign --verify --strict --deep --all-architectures -R "$requirement" "$app"
# Staple the application so Gatekeeper can assess it offline.
/usr/bin/ditto -c -k --keepParent "$app" "$stage/app.zip"
/usr/bin/xcrun notarytool submit "$stage/app.zip" --keychain-profile "$MYMACHINE_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

/usr/sbin/spctl --assess --type execute "$app"
./scripts/verify-monitoring-bundle.sh "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
output="outputs/MY-MACHINE-$version-$build-notarized.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/release.zip"
/usr/bin/unzip -t "$stage/release.zip"
mkdir "$stage/reopened"
/usr/bin/ditto -x -k "$stage/release.zip" "$stage/reopened"
reopened="$stage/reopened/MY MACHINE.app"
./scripts/verify-monitoring-bundle.sh "$reopened"
/usr/bin/codesign --verify --strict --deep --all-architectures -R "$requirement" "$reopened"
/usr/bin/xcrun stapler validate "$reopened"
/usr/sbin/spctl --assess --type execute "$reopened"
/bin/mv "$stage/release.zip" "$output"
(cd outputs && /usr/bin/shasum -a 256 "${output:t}" > "${output:t}.sha256")
print "Notarized monitoring archive ready for release validation: $output"
