# Contributing to Poof

## Build and test

Swift 6 and macOS 14 or later.

```sh
swift build
swift test
.build/debug/poof scan <app>
scripts/build-app.sh            # dist/Poof.app
```

Debug builds of the app can render their window to a PNG without Screen Recording
permission, which helps when checking layout changes:

```sh
POOF_SNAPSHOT=/tmp/poof POOF_SELECT=developer .build/debug/PoofApp   # writes /tmp/poof.png
```

## Where things live

- `Sources/PoofCore`: scanning, matching and removal. Everything here is testable without
  touching real files; scanners take a home folder and a system root.
- `Sources/poof`: the command-line tool.
- `Sources/PoofApp`: the SwiftUI app. It runs the CLI as root for files in system folders.
- `Tests/PoofCoreTests`: one file per scanner.

## Ground rules

Poof's job is to remove files, so a wrong match costs someone data. Changes to matching
should:

- come with a test for the case that motivated them, and one for the nearest case that must
  not match (see `ignoresSiblingsUnderSameVendor` and `helpersOtherAppsEmbedAreShared`);
- prefer missing a leftover over taking a file another app uses;
- explain in a comment why a rule exists, with the real app that needed it.

Removal must stay reversible: anything Poof takes goes through `Quarantine`.

## Easy first contributions

- **Known non-app IDs.** If `poof orphans` lists files a library or command-line tool wrote,
  add its prefix to `Sources/PoofCore/KnownNonApps.swift` with a comment naming the project.
- **Developer caches.** New cache locations go in `DeveloperScanner.locations`. Use a
  `command` for anything the tool tracks itself.
- **Wrong matches.** A failing test reproducing a false positive is a great pull request on
  its own.

## Pull requests

Keep commits focused and messages in plain English: what changed and why. Update
`CHANGELOG.md` under `Unreleased`.
