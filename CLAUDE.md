# Working in this repository

algobuddy is a macOS menu bar app that watches an Algorand participation account from public chain data alone. It holds no credentials, contacts only the configured algod and indexer endpoints, and its value rests on being simple enough to read and trust. Keep changes small, verified, and in that spirit.

## Layout

- `Sources/AlgobuddyCore` is a pure library, Foundation only, no Apple UI frameworks. All 108 tests live in `Tests/AlgobuddyCoreTests` and exercise it. This is where logic changes belong, and where they can be fully verified.
- `Sources/AlgobuddyApp` is the SwiftUI and AppKit layer. It compiles but has no automated tests, so treat changes here as unverified beyond a clean build.

## The gate

`make check` runs the linter and the full test suite, and is the single bar every change must clear. Run it, and iterate until it passes, before proposing anything.

- Never delete, skip, or weaken a test to make the suite pass. A failing test is a finding, not an obstacle.
- `make install` builds and installs the app bundle; `make bundle` assembles it. Neither is needed to validate a logic change.

## Commit messages

Conventional Commits, `<type>(<scope>)!: <description>`, subject at most 72 characters. A commit-msg hook and CI both enforce this, so a malformed subject fails. Types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. See CONTRIBUTING.md.

## Comments

- Explain why, never what the next line already says.
- Full sentences, sentence case, terminal punctuation. No first-person pronouns.
- No em dashes, en dashes, or " - " asides. Rephrase to remove them.
- Timeless: never reference a previous state of this codebase. A reader who has not seen an earlier version must not be able to tell one existed. Comments about runtime or the Algorand protocol are fine.
- Section markers are `// MARK: -`. British spelling appears in places and is fine.

## Scope, for an agent working here

Prefer changes to `Sources/AlgobuddyCore`, its tests, and documentation, where the outcome is fully testable. Do not, without an explicit request in the summoning comment, touch:

- the release pipeline (`.github/workflows/`, `release-please-config.json`, the manifest),
- the version stamping in the `Makefile` or `Resources/Info.plist`,
- the security posture: the "no credentials, two configured hosts, nothing stored" claims in `SECURITY.md` and `README.md` must stay true of the code.

When a change would affect any of those, say so and stop rather than guessing.
