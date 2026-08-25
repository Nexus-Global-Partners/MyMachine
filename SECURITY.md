# Security policy

MY MACHINE records sensitive context about one person's Mac even though it deliberately avoids content. Treat privacy failures, unintended data exposure, and misleading security boundaries as security issues.

## Supported version

Security fixes are made on the latest public 1.1.x release and `main`. Older releases may not receive backports.

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
