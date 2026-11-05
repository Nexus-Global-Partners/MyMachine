#!/bin/bash
set -euo pipefail
[[ $# == 1 && -d "$1/Contents" ]] || { echo 'Usage: scripts/verify-store-bundle.sh MyMachine.app' >&2; exit 64; }
app="$1"
contents="$app/Contents"
binary="$contents/MacOS/MyMachine"

codesign --verify --strict --deep --all-architectures "$app"
plutil -lint "$contents/Info.plist"
test -s "$contents/Resources/LICENSE"
test -s "$contents/Resources/StorePrivacy.txt"
test -s "$contents/Resources/Assets.car"
test -s "$contents/Resources/AppIcon.icns"
test -f "$binary"
architectures=" $(lipo -archs "$binary") "
if [[ "$architectures" != *" arm64 "* || "$architectures" != *" x86_64 "* ]]; then
    echo "Expected Apple Silicon and Intel slices. Found:$architectures" >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
codesign --display --xml --entitlements - "$app" > "$scratch/entitlements.plist"
python3 - "$scratch/entitlements.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    actual = plistlib.load(file)
required = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
}
signing_identifiers = {
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
}
if not all(actual.get(key) is value for key, value in required.items()):
    sys.exit("Required Store entitlements are missing.")
unexpected = actual.keys() - required.keys() - signing_identifiers
if unexpected:
    sys.exit("Unexpected Store entitlements: " + ", ".join(sorted(unexpected)))
PY

find "$contents" ! -type d -print > "$scratch/files"
while IFS= read -r path; do
    [[ -f "$path" && ! -L "$path" ]] || exit 1
    case "${path#"$contents/"}" in
        Info.plist|PkgInfo|MacOS/MyMachine|Resources/AppIcon.icns|Resources/Assets.car|\
        Resources/LICENSE|Resources/StorePrivacy.txt|Resources/PrivacyInfo.xcprivacy|\
        embedded.provisionprofile|_CodeSignature/CodeResources) ;;
        *) echo "Unexpected Store bundle payload: $path" >&2; exit 1 ;;
    esac
done < "$scratch/files"

nm -u "$binary" > "$scratch/symbols"
strings -a "$binary" > "$scratch/strings"
if grep -Eiq 'AppleSMC|FanControlHelper|local\.mymachine\.fancontrol|IOServiceOpen|IOConnectCallStructMethod|proc_listallpids|proc_pid_rusage|proc_pidinfo|CGEventSourceCounterForEventType|CGEventTapCreate|CLGeocoder|SMJobBless|Sparkle' "$scratch/symbols" "$scratch/strings"; then
    echo 'Store executable includes an excluded collector, updater, or privileged component.' >&2
    exit 1
fi

echo 'PASS  Store bundle signature, entitlements, architectures, resources, and executable boundary'
