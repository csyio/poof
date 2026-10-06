# Poof

Remove macOS apps and the files they leave behind.

> Status: early development. Removal moves files to a quarantine you can restore from;
> nothing is deleted until you run `poof purge`.

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
poof scan chrome            # an installed app and its files
poof orphans                # files left by apps that are already gone
poof remove chrome          # move the app and its files to quarantine
sudo poof remove chrome     # same, including files in system folders
poof restore                # list what is in quarantine
poof restore --last         # put the last removal back
poof purge --older-than 7   # permanently delete removals older than 7 days
```

## Safe removal

`poof remove` never deletes. It moves each item into
`~/Library/Application Support/Poof/Quarantine/<session>/` and records its original path,
so `poof restore` puts back the same files with the same permissions. Only `poof purge`
deletes, and it asks first.

Before moving anything, Poof:

- refuses if the app is running;
- keeps files another app or package also uses, and says which;
- keeps system extensions, which macOS protects (remove them in System Settings);
- skips files in system folders unless run with `sudo`, and prints the command;
- warns about saved passwords, bookmarks, cookies, keychains and wallets inside the items,
  and asks you to type `yes` instead of `y` (with `--yes`, it also needs `--allow-sensitive`);
- unloads launch agents and daemons so they stop running.

If macOS blocks access to an app's data (`~/Library/Containers` is protected), give your
terminal Full Disk Access in System Settings > Privacy & Security.

Items marked `[admin]` need administrator rights to remove.

## Roadmap

1. Scanner: login items (needs a privileged helper), browser extensions.
2. `poof orphans --remove`.
3. Benchmark: install apps in a clean VM, uninstall with Poof and other tools, publish what each leaves behind.
4. SwiftUI app with Full Disk Access and a privileged helper.
5. Developer leftovers: Chrome for Testing, Playwright browsers, Xcode simulators.

## Releases

Releases are built by GitHub Actions when a `v*` tag is pushed:

1. Move the `Unreleased` notes in `CHANGELOG.md` under a new version heading.
2. Set the same version in `Sources/poof/Version.swift`.
3. Commit, then `git tag v0.2.0 && git push origin main v0.2.0`.

Versions below 1.0 are published as pre-releases.

## License

MIT
