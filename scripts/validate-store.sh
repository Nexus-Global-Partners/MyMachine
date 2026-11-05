#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:---fixtures}"
case "$mode" in
    --fixtures|--sandbox) ;;
    *) echo 'Usage: scripts/validate-store.sh [--sandbox OUTSIDE_TEST_FILE]' >&2; exit 64 ;;
esac
if [[ "$mode" == --sandbox ]]; then
    outside="${2:?Expected an absolute, disposable test file path outside the app container}"
    [[ "$outside" == /* && ! -e "$outside" && ! -L "$outside" ]] || exit 64
    (set -C; printf 'parent can write\n' > "$outside")
    rm "$outside"
fi

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
core=(
    ApplicationCategorizer.swift BatteryTelemetry.swift CoverageEvaluator.swift LocalEraseReceipt.swift
    Models.swift RetentionCoordinator.swift SQLiteStore.swift SystemMetrics.swift
)
sources=()
for source in "${core[@]}"; do
    sources+=("Sources/DailyMacCore/$source")
done
sources+=(
    Sources/MyMachineStore/StoreHistory.swift Sources/MyMachineStore/StoreMonitor.swift
    Tests/MyMachineStoreTests/StoreValidation.swift
)

export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx15.0" \
    -lsqlite3 "${sources[@]}" -o "$scratch/StoreValidation"

if [[ "$mode" == --fixtures ]]; then
    "$scratch/StoreValidation" --fixtures "$scratch"
    exit
fi

app="$scratch/MyMachine Store Validation.app"
mkdir -p "$app/Contents/MacOS"
mv "$scratch/StoreValidation" "$app/Contents/MacOS/StoreValidation"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.mymachine.storevalidation</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>StoreValidation</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --options runtime --timestamp=none --entitlements Store/Store.entitlements --sign - "$app"
codesign --verify --strict --deep "$app"
/usr/bin/open -W -n -g --stdout "$scratch/stdout" --stderr "$scratch/stderr" "$app" --args --sandbox "$outside"
cat "$scratch/stdout" "$scratch/stderr"
if [[ -f "$outside" && ! -L "$outside" ]]; then
    rm "$outside"
    echo 'Validation app wrote the forbidden test file.' >&2
    exit 1
fi
/usr/bin/grep -qx 'Store validation passed.' "$scratch/stdout"
