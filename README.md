# Poof

Remove macOS apps and the files they leave behind.

> Status: early development. `poof scan` lists files; nothing is removed yet.

## How Poof finds an app's files

Poof looks in the standard `~/Library` and `/Library` locations and matches entries by:

- **Bundle ID**, including children (`com.google.Chrome.helper`) but not siblings from the
  same vendor (`com.google.antigravity` is a different app).
- **App name** folders such as `~/Library/Application Support/OneDrive`.
- **Team ID** in Group Containers, only when the rest of the name also points at the app.
  Developers like Microsoft share one team ID across Office, Teams and OneDrive.
- **Vendor folders**: `Application Support/Google/Chrome`, `Application Support/Blackmagic Design/DaVinci Resolve`.
- **Launch agents and daemons** whose program is inside the app bundle or inside a folder
  already found (updaters often run from a support folder), or that list the app in
  `AssociatedBundleIdentifiers`.
- **Privileged helpers** the app declares in `SMPrivilegedExecutables`.
- **System extensions** (network filters, drivers) activated from inside the app, read from
  macOS's extension database. These are deactivated rather than deleted.
- **Installer receipts** (`pkgutil`). Packages are matched by ID and by the `.app` they
  contain, because installers often unpack apps in a temporary folder and move them, which
  makes the recorded location wrong for the app (but still right for the package's other files).
  Each package's files are reduced to the top-most folders it owns outside standard system
  folders, such as `/Library/Application Support/Fortinet`.

## Files from apps that are already gone

`poof orphans` lists files whose app is no longer installed, in two groups:

- **Left by removed apps**: sandbox containers, app extension scripts and saved window
  state (only apps create these), system extensions whose app is gone, and launch agents
  or daemons whose program no longer exists.
- **Probably left by removed apps**: preferences and caches named after a bundle ID. Command-line
  tools and libraries write these too, so check them first.

A file counts as orphaned only when no installed app comes from the same vendor
(`com.microsoft.office.plist` stays while any Microsoft app is installed). Installers left
in Downloads do not count as installed apps. Libraries and tools that use bundle-ID-style
names (SwiftPM, CUPS, Electron, analytics SDKs) are listed in
`Sources/PoofCore/KnownNonApps.swift`; contributions to that list are welcome.

Login items are not covered yet: macOS keeps them in a database only administrators can read.

## Shared files

Removing a file another app still uses breaks that app. Poof flags these instead of
treating them as leftovers:

- Siblings under the same vendor prefix are not matched (`com.google.antigravity` is not Chrome).
- Team ID matches in Group Containers must also name the app (`UBF8T346G9.Office` is shared by all Microsoft apps).
- When another package also installs files into a folder, Poof walks down to the
  subfolders only this app's package uses, and marks the rest `also used by`.
- A receipt for a package that also installed other apps is marked with those apps.

## Install

Download `poof-<version>-macos-universal.tar.gz` from
[Releases](https://github.com/csyio/poof/releases), then:

```sh
tar -xzf poof-*-macos-universal.tar.gz
sudo mv poof-*/poof /usr/local/bin/
```

The binary is not notarized yet. If you downloaded it with a browser, macOS may block it;
remove the quarantine flag with `xattr -d com.apple.quarantine /usr/local/bin/poof`.

To build from source (Swift 6, macOS 14 or later):

```sh
swift build -c release
.build/release/poof scan chrome
```

## Usage

```sh
poof scan chrome      # an installed app and its files
poof orphans          # files left by apps that are already gone
poof --version
```

Items marked `[admin]` need administrator rights to remove.

## Roadmap

1. Scanner: login items (needs a privileged helper), browser extensions.
2. Benchmark: install apps in a clean VM, uninstall with Poof and other tools, publish what each leaves behind.
3. Safe removal: move items to a quarantine folder that can be restored for 7 days; warn before deleting saved passwords or bookmarks.
4. SwiftUI app with Full Disk Access.
5. Developer leftovers: Chrome for Testing, Playwright browsers, Xcode simulators.

## Releases

Releases are built by GitHub Actions when a `v*` tag is pushed:

1. Move the `Unreleased` notes in `CHANGELOG.md` under a new version heading.
2. Set the same version in `Sources/poof/Version.swift`.
3. Commit, then `git tag v0.2.0 && git push origin main v0.2.0`.

Versions below 1.0 are published as pre-releases.

## License

MIT
