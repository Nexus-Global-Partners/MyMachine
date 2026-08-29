# Contributing to MY MACHINE

Thanks for helping make Macs easier to understand without turning monitoring into surveillance. A useful contribution keeps the app native, light, local, and honest about what its evidence can prove.

## Start safely

Requirements: macOS 15 or later and Apple Command Line Tools with Swift 6.

```sh
xcode-select --install
git clone https://github.com/Nexus-Global-Partners/MyMachine.git
cd MyMachine
swift build
swift run DailyMacValidation
```

Run development builds with an isolated temporary database so your personal history never becomes a fixture or screenshot:

```sh
export DAILYMAC_DATA_DIR="$(mktemp -d)"
export DAILYMAC_DISABLE_NOTIFICATIONS=1
export DAILYMAC_DISABLE_LOGIN_REGISTRATION=1
swift run DailyMac
```

MY MACHINE has no third-party packages. `Package.swift` defines the app, the core library, and the project validation executable.

## Make a focused change

- Keep telemetry collection permission-free and local. Read [PRIVACY.md](PRIVACY.md) before changing any collected field.
- Interpret metrics in practical language. Explain what happened, whether it was unusual, why it matters, the likely cause, the likely effect, and whether any action is useful.
- Do not infer focus, productivity, intent, or causation from input counts or app correlation.
- Keep raw readings secondary. The default experience should be understandable in seconds.
- Preserve recording gaps. A neutral visual bridge may keep the timeline readable, but it must remain visibly distinct from measured CPU/GPU data and must never invent values for sleep.
- Avoid new background work when existing sampled data can answer the question.

## Verify the change

Run the project checks locally:

```sh
swift build
swift run DailyMacValidation
swift run -c release DailyMacValidation
./scripts/package.sh
codesign --verify --deep --strict --verbose=2 "outputs/MY MACHINE.app"
unzip -t "outputs/MY-MACHINE-1.2.0.zip"
unzip -t "outputs/MY-MACHINE-Source-1.2.0.zip"
(cd outputs && shasum -a 256 -c "SHA256SUMS-1.2.0.txt")
```

The final validation check samples real hardware. It is intentionally a local release check rather than a guaranteed cloud-runner test. GitHub CI runs the deterministic validation suite in both debug and release configurations, then packages the app, verifies the signature and archives, checks the generated hashes, and audits the source archive boundary.

For UI changes, test the menu panel at normal menu-bar scale and the expanded view on the smallest Mac size you support. Confirm selection can be cleared, missing data stays visibly missing, and scrolling or resize remains smooth.

## Protect private data in issues and pull requests

Never attach a real MY MACHINE database, WAL/SHM file, full process dump, environment dump, shell history, diagnosis brief, or unredacted Activity Monitor export. Before uploading a screenshot, crop or blur app names, menu-bar items, filenames, project names, notifications, messages, and anything visible behind MY MACHINE. Synthetic fixtures are preferred.

If a bug needs private evidence, first reduce it to a synthetic sample or explain the shape of the data without posting the data itself. Security issues follow [SECURITY.md](SECURITY.md), not a public issue.

## Pull request checklist

- Describe the user-visible outcome and the evidence boundary.
- Keep the change scoped; do not mix unrelated cleanup.
- Add deterministic coverage where practical and report local hardware checks separately.
- Confirm no private recordings, screenshots, generated apps, archives, or build directories are included.
- Update README, privacy, handoff, or changelog text when public behavior changes.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
