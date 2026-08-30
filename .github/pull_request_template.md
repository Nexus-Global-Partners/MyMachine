## What changes for the person using MY MACHINE?

Describe the visible outcome and why it matters.

## Evidence and privacy boundary

- What local evidence does this use?
- What can it honestly conclude?
- Does it add a collected or retained field? If yes, update `PRIVACY.md` and explain why existing data was insufficient.

## Verification

- [ ] `swift build`
- [ ] `swift run DailyMacValidation`
- [ ] `swift run -c release DailyMacValidation`
- [ ] Menu panel checked at normal scale
- [ ] Menu positioning and Calm/Precise switching checked when relevant
- [ ] No private database, process dump, environment dump, diagnosis brief, or generated release artifact is included
- [ ] Screenshots use synthetic data or are cropped/redacted for app names, filenames, projects, notifications, messages, and background windows

## Practical interpretation

Explain how the UI answers: what happened, whether it is normal, why it matters, what likely caused it, what it affects, and whether anything useful should be done.
