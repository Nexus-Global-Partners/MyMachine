# MyMachine Mac App Store target

The `MyMachineStore` scheme builds the sandboxed edition for macOS 15 and later. It is a clean install with a separate bundle identity and its own private history. The direct-distribution Swift package remains the entry point for the source preview and Developer ID build.

The Store target compiles the public CPU, memory, battery and thermal readers, SQLite history, and a separate SwiftUI menu-bar UI. It records after Start Monitoring, shows recording status, and supports pausing, opt-in Launch at Login, a recent timeline, local deletion, and CSV export via Save Panel. Sleep intervals require both observed notifications. The target source list excludes the direct edition's full sampler. Fan RPM, private driver readings, per-app attribution, input counters and network-connected features are outside the Store scope.

## Validate a local preview

Use Xcode 16.4 or newer for local preparation and an Apple-accepted stable Xcode for distribution. The following builds an ad-hoc sandboxed preview with both architectures.

```sh
archive="$PWD/outputs/MyMachine-Store-Preview.xcarchive"
xcodebuild -project MyMachineStore.xcodeproj -scheme MyMachineStore \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$PWD/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= archive
staged="$PWD/outputs/StorePreview/MyMachine.app"
ditto --norsrc --noextattr "$archive/Products/Applications/MyMachine.app" "$staged"
scripts/verify-store-bundle.sh "$staged"
scripts/validate-store.sh
```

The staged copy omits Finder metadata that Xcode can attach when archiving. Signature verification still checks the sealed application content.

To exercise the same history and sensor code from a sandboxed process, run `scripts/validate-store.sh --sandbox /absolute/path/to/a-new-disposable-test-file` in a signed-in Mac desktop session. Pick a new, writable scratch path outside the app container. The harness expects the sandbox to deny writing there. It uses a distinct validation app ID and removes its test history on exit. Its sleep and wake notifications are simulated. For a real hardware test, open the preview app, start monitoring, and verify that its timeline shows a sleep band only after observed sleep and wake. The first CPU reading after wake must establish a fresh baseline.

## Prepare a Store archive

1. Confirm the publisher's team, permanent explicit App ID, app record, and version/build. The project default `local.mymachine.storepreview` is for local tests. Use the approved bundle ID for distribution.
2. Set `MYMACHINE_PRIVACY_URL` and `MYMACHINE_SUPPORT_URL` to the publisher's verified HTTPS pages for the submitted build. These values are build settings substituted into the app's Info.plist. The bundled privacy text is the technical policy draft and should agree with the public policy and label. Inspect the final plist for resolved values.
3. Archive with the authorized Apple team and export through Xcode's App Store Connect distribution method. Audit the exact exported app, signing identity, profile, entitlements, minimum OS, icon, and any required privacy manifest. Validate it with Apple's upload tools. Review the final export compliance answer before recording it.
4. Test the processed build with internal testers on the supported hardware and OS matrix. Verify clean installation, usable launch and menu-bar controls, no auto-start on a fresh install, pause across quit/relaunch, explicit Launch at Login, measured CPU and memory, laptop battery and charging, desktop unavailable states, sleep/wake and overnight sampling, CSV, and erase including a pending cleanup. Document measured overhead during the overnight test.
5. Use the exact tested build to capture Store screenshots and write reviewer instructions. Keep names of other apps, open documents, and other personal desktop information outside screenshots and diagnostic evidence.

The Store build has no automatic migration from the direct edition. A Mac that ran an experimental build with the old privileged helper requires separate maintainer-led retirement and verification of automatic fan behavior before any supported upgrade path is offered.
