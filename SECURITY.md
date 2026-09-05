# Security policy

MY MACHINE records sensitive context about one person's Mac even though it deliberately avoids content. Treat privacy failures, unintended data exposure, and misleading security boundaries as security issues.

## Supported version

Security fixes are made on the latest public 1.2.x release and `main`. Older releases may not receive backports.

## Report a vulnerability privately

Please use [GitHub private vulnerability reporting](https://github.com/Nexus-Global-Partners/MyMachine/security/advisories/new). Do not open a public issue for a suspected vulnerability and do not attach a real database, diagnosis brief, process dump, environment dump, or screenshot containing private work.

Include only what is needed to reproduce the problem:

- MY MACHINE version and macOS version
- Apple-silicon model or Intel architecture
- Clear reproduction steps using synthetic data when possible
- What data or boundary is at risk
- Whether the issue requires user interaction

You should receive an acknowledgement through GitHub. A fix and disclosure timeline depends on severity and reproducibility; no guaranteed response window is promised for this volunteer project.

## Security and privacy boundaries

The app is local-first and has no analytics SDK, server, updater, AI client, or telemetry upload path. **Diagnose My Machine** copies a minimized brief only after an explicit click; an external provider sees it only if the user chooses to paste and send it.

Public binaries are ad-hoc signed with Hardened Runtime but are not Developer ID signed or Apple-notarized. The signature protects bundle integrity after packaging; it is not an Apple identity or trust guarantee. Verify the release SHA-256 file and inspect or build the public source when stronger provenance is required.

The full collection contract is in [PRIVACY.md](PRIVACY.md).

## Release engineering

Developer ID signing and notarization require Apple Developer Program membership. Until that is available, `scripts/package.sh` produces an ad-hoc **development-only** build. CI verifies development artifacts; this is not Gatekeeper approval or notarization. The draft-assets workflow never publishes a release and separates unprivileged builds from the write-token upload job. Configure required reviewers for the `release` environment and protect release tags before using it. Do not publish its unsigned draft assets as a notarized release.

On a trusted signing Mac, provision the Developer ID Application certificate in Keychain and store notary credentials with Apple's `notarytool store-credentials`. Never commit or paste passwords, private keys, certificates with private material, or notary tokens into source or workflow text. Set:

- `MY_MACHINE_SIGNING_IDENTITY`: the Developer ID Application identity name.
- `MY_MACHINE_NOTARY_PROFILE`: the existing Keychain notary profile name.
- `MY_MACHINE_REQUIRE_NOTARIZATION=1`: fails closed if signing configuration is absent.

The packaging script signs with hardened runtime and a secure timestamp, submits for notarization, staples and validates the ticket, assesses Gatekeeper acceptance, then recreates the ZIP before hashing it. This path needs a real certificate and clean-Mac validation before it can be declared working in production. Keep signing credentials out of pull-request jobs. Ad-hoc builds remain useful for local development without weakening production signing requirements.

## Remaining hardening work

1. **Authenticated distribution:** obtain membership, provision keys, test the signed path and publish a new release only after Gatekeeper checks pass.
2. **Encrypted storage:** choose a maintained encrypted-store implementation; keep the random database key in Keychain; cover journals, migration and recovery archives; test locked-keychain and key-loss recovery. Do not deploy custom database cryptography or silently fall back to plaintext.
3. **Sandbox compatibility:** measure libproc, IOKit, input counters and app attribution under App Sandbox on supported Macs. Start without networking entitlements, add user-selected export access only, and document unavailable metrics. Do not replace missing metrics with invented values or a broad privileged helper.
4. **Collection controls:** separate aggregate performance, application history and input intensity; add app exclusions and targeted deletion through every derived representation.
5. **Privacy regression coverage:** real clipboard/network observation, macOS permission testing, backup/snapshot behavior, hostile file paths and release-binary/source verification.

Storage minimization intentionally preserves personal aggregate trends, not anonymous population analytics. No outbound telemetry service or automatic updater has been added. Hardened runtime is enabled; App Sandbox and application-level encryption are not yet enabled. These remaining changes need compatibility and migration validation before installation is presented as a hardened production release.
