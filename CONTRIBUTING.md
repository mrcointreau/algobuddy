# Contributing

## Building and testing

Requires macOS 14+ and a Swift 6 toolchain (`xcode-select --install`).

```bash
make check    # lint + tests, what CI runs
make install  # build and install to /Applications
```

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org): `<type>(<scope>)!: <description>`, subject at most 72 characters. The scope is optional; `!` marks a breaking change.

| Type | Use for | Version bump at release |
|---|---|---|
| `feat` | new user-visible behaviour | minor |
| `fix` | bug fixes | patch |
| `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert` | everything else | none |

Examples:

```
feat: hide values from the menu bar
fix(poller): retry the challenge seed when a header omits it
feat!: drop macOS 14 support
```

Enable the local gate once per checkout:

```bash
make hooks
```

CI validates pushed commits with the same script, so `--no-verify` only defers the failure.

## Releases

release-please maintains a release pull request on `main`: it accumulates the `CHANGELOG.md` additions and computes the next version from the commit types above (`feat!` major, `feat` minor, otherwise patch). Merging that PR is the whole release: release-please creates the tag and the GitHub Release, with the PR's description as the release notes.

To polish the notes, edit the PR description right before merging; the PR is regenerated whenever `main` moves, so earlier edits do not survive new pushes. To reword a single entry durably, edit the merged pull request it came from and add a `BEGIN_COMMIT_OVERRIDE` block with the replacement subject.
