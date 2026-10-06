# Changelog

All notable changes to Poof are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- `poof orphans` lists files left by apps that are no longer installed, split into items
  only apps create and items a tool or library may also have created.
- `poof scan` finds system extensions an app activated.
- `Sources/PoofCore/KnownNonApps.swift`: libraries and tools whose files look like app data.

## [0.1.0] - 2026-10-06

First preview. Poof can find an app's files but does not remove anything yet.

### Added

- `poof scan <app>` lists an app's bundle and the files it left elsewhere, with sizes and
  the reason each one was matched. Items that need administrator rights are marked `[admin]`.
- Matching by bundle ID, app and file name, vendor folders, team ID in Group Containers,
  launch agents and daemons, privileged helpers, and installer receipts.
- Shared-file detection: files another app or package also uses are marked `also used by`
  instead of being treated as leftovers.
