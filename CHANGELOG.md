# Changelog

All notable changes to Poof are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- Poof.app: a SwiftUI app with the installed apps, leftovers of removed apps and the
  quarantine. Items can be checked and unchecked before removal; personal data needs an
  explicit acknowledgement; files in system folders are moved by the bundled CLI after the
  administrator password prompt. Shows a banner while Full Disk Access is missing.
- Releases include `Poof-<version>.zip`.
- `poof scan` finds files of helper apps, extensions and XPC services inside the bundle,
  crash reports, and logs nested in vendor folders. Helpers that other installed apps also
  embed are marked shared.
- README: comparison with AppCleaner on FortiClient, DaVinci Resolve, Word and Antigravity.
- `poof dev` and a Developer section in the app: developer caches, DerivedData of deleted
  projects, build folders of idle projects (`--projects`), and the cleanup command for data
  a tool manages itself (simulators, Homebrew, Go, Rust toolchains).

- `poof orphans` lists files left by apps that are no longer installed, split into items
  only apps create and items a tool or library may also have created.
- `poof scan` finds system extensions an app activated.
- `Sources/PoofCore/KnownNonApps.swift`: libraries and tools whose files look like app data.
- `poof remove <app>` moves an app and its files into a quarantine folder. It keeps shared
  files and system extensions, refuses while the app is running, unloads launch items, and
  asks for a typed `yes` when items contain saved passwords, bookmarks or keys.
- `poof restore` lists quarantine sessions and puts a removal back; `poof purge` deletes them.
- `poof orphans --remove` quarantines orphaned files Poof is sure about; `--include-unsure`
  adds the rest.

### Changed

- A launch item whose program is missing is no longer reported as certain when its vendor
  still has apps installed (FortiClient keeps daemons for features that are not enabled).

### Fixed

- Removing an installer receipt now moves its `.bom` file along with the `.plist`.

- Under `sudo`, Poof scanned root's home folder instead of the user's.

## [0.1.0] - 2026-10-06

First preview. Poof can find an app's files but does not remove anything yet.

### Added

- `poof scan <app>` lists an app's bundle and the files it left elsewhere, with sizes and
  the reason each one was matched. Items that need administrator rights are marked `[admin]`.
- Matching by bundle ID, app and file name, vendor folders, team ID in Group Containers,
  launch agents and daemons, privileged helpers, and installer receipts.
- Shared-file detection: files another app or package also uses are marked `also used by`
  instead of being treated as leftovers.
