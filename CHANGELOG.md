# Changelog

All notable changes to Poof are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.3.0] - 2026-10-08

Explains why an app is on your Mac, and lists browser extensions.

### Added

- Poof.app redesign: colour-coded sidebar icons, section headers with summary tiles, an app
  header with a coloured verdict badge and a findings card, grouped file cards, tinted banners
  and empty states, and dark mode.
- `poof apps` and `poof why <app>`, an Apps section and an "About this app" panel in
  Poof.app: each app's developer, origin (App Store, Homebrew, installer receipt, Setapp or
  download quarantine), last use, size, background parts, related apps and a verdict.
  `--unused <days>` lists apps not opened for that long; `--json` prints JSON.
- `poof extensions` and an Extensions section in Poof.app: extensions in Chromium-based
  browsers, Firefox and Safari, with version, state, source and size. Flags extensions that
  are off, not from the store, installed by policy, unsigned or not updated for two years.
  `--flagged` and `--json` are available. Firefox add-ons in the shared Mozilla folders and
  inside Firefox.app are included. Read-only.

### Changed

- Launch-item matching is one shared rule used by `LeftoverScanner` and app insights.
- Apps with a `com.apple.*` bundle ID are hidden from app lists only when Apple or the App
  Store signed them; other claimants are listed with a warning.

## [0.2.0] - 2026-10-07

Removal, a Mac app, and scanning for files from removed apps, developer tools and login items.

### Added

- Poof.app: a SwiftUI app with the installed apps, leftovers of removed apps and the
  quarantine. Items can be checked and unchecked before removal; personal data needs an
  explicit acknowledgement; files in system folders are moved by the bundled CLI after the
  administrator password prompt. Shows a banner while Full Disk Access is missing.
- Releases include `Poof-<version>.zip`. With Developer ID secrets set in the repository,
  the release workflow signs and notarizes the app and the CLI.
- App icon (`scripts/make-icns.sh` draws it).
- `CONTRIBUTING.md`, `SECURITY.md`, and issue templates for wrong matches and bugs.
- `poof scan` finds files of helper apps, extensions and XPC services inside the bundle,
  crash reports, and logs nested in vendor folders. Helpers that other installed apps also
  embed are marked shared.
- README: comparison with AppCleaner on FortiClient, DaVinci Resolve, Word and Antigravity.
- `sudo poof login-items` and a Login Items section in the app: apps and helpers that start
  at login or run in the background, read from `sfltool dumpbtm`, with records whose file is
  missing listed first. `sudo poof scan <app>` includes the app's records. Read-only.
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
