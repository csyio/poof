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
- **Helper apps, extensions and XPC services inside the bundle** from the same vendor, which
  have their own bundle IDs. A helper that other installed apps also embed (Office's error
  reporter) is marked shared.
- **Crash reports** in `CrashReporter` and `DiagnosticReports`, by executable name.
- **Logs in vendor folders**, a few levels into `Logs`, by bundle ID.
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
  tools and libraries write these too, so check them first. Launch items with a missing
  program also land here when the vendor still has apps installed, since the app may
  install the program later.

`poof orphans --remove` moves the first group to quarantine, with the same checks as
`poof remove`. Add `--include-unsure` to move the second group too.

A file counts as orphaned only when no installed app comes from the same vendor
(`com.microsoft.office.plist` stays while any Microsoft app is installed). Installers left
in Downloads do not count as installed apps. Libraries and tools that use bundle-ID-style
names (SwiftPM, CUPS, Electron, analytics SDKs) are listed in
`Sources/PoofCore/KnownNonApps.swift`; contributions to that list are welcome.

Login items are not covered yet: macOS keeps them in a database only administrators can read.

## Login and background items

`sudo poof login-items` lists what macOS's background task database holds: apps that open at
login, login items inside apps, launch agents and daemons, and apps' background tasks, with
whether each is on and whether the file it points at still exists. The app shows the same list
after asking for your password. `sudo poof scan <app>` includes the app's own records.

These records are not files. macOS removes them when their app or plist is gone, and only
System Settings > General > Login Items & Extensions turns them off, so Poof never changes
them. Records whose file is missing usually come from a launch agent or daemon left behind;
`poof orphans` finds and removes those plists.

## Developer leftovers

`poof dev` measures what developer tools leave behind and sorts it into four groups:

- **Caches** that the tool downloads or rebuilds when needed: npm, Bun, Yarn, pnpm, pip,
  uv, Cargo, Gradle, SwiftPM, CocoaPods, Playwright and Puppeteer browsers, Electron,
  node-gyp, Xcode device symbols and shared Xcode caches.
- **Build output of deleted projects.** Xcode writes each DerivedData folder's project path
  into its `info.plist`; when that project is gone, the folder is certainly unused.
- **Review first**: build output of projects that still exist (their next build starts from
  scratch), Xcode archives, Maven, Android emulators, and with `--projects`, dependency and
  build folders of projects untouched for `--idle-days` (default 30). A folder only counts
  when the file that proves its tool is there (`node_modules` next to `package.json`,
  `target` next to `Cargo.toml`).
- **Managed by the tool**: simulators, Homebrew downloads, the Go module cache and Rust
  toolchains. Moving these by hand leaves the tool's records pointing at files that are
  gone, so Poof prints the tool's own command and never moves them.

`--remove` takes the first two groups; `--include-review` adds the third. Quarantined items
still use disk space until `poof purge`. Caches are not checked for personal data: package
caches contain packages named `cookies` and test keychains.

## Comparison with AppCleaner

Run on 2026-10-07 on macOS 27 against AppCleaner 3.6.8, using apps that were already
installed. Nothing was removed; both tools' lists were compared item by item.

| App | AppCleaner | Poof | Difference |
|---|---|---|---|
| FortiClient 7.4 | 31 files, 294 MB | 34 items, 407 MB | AppCleaner misses `/Library/Application Support/Fortinet` (102.5 MB), `~/Library/Application Support/Fortinet/FortiClient` (5.4 MB) and the VPN system extension. |
| DaVinci Resolve 21 | 7 files, 6.28 GB | 14 items, 5.98 GB | AppCleaner misses Resolve's data in `~/Library/Application Support/Blackmagic Design/DaVinci Resolve` (46 MB) and `/Library/Application Support/Blackmagic Design/DaVinci Resolve` (832 MB). It checks the whole `/Applications/DaVinci Resolve` folder, which also holds DaVinci Control Panels Setup and Fairlight Studio Utility from separate packages; Poof keeps those. |
| Microsoft Word 16 | 15 files, 8 checked | 10 items | AppCleaner checks `com.microsoft.errorreporting` by default, which Excel, Outlook, PowerPoint, OneNote, OneDrive and Copilot also embed. Poof marks it shared and keeps it. Both leave Office's shared group containers alone. |
| Antigravity 2.19 | 5 files, 504 MB | 5 items, 504 MB | Same result. |

AppCleaner refuses to inspect running apps, so OneDrive was not compared.

The comparison also found gaps in Poof, now fixed: installer receipts' `.bom` files, files
from helper apps inside the bundle (DaVinci Resolve Welcome), crash reports, and logs nested
in vendor folders (`/Library/Logs/Microsoft/InstallLogs`).

## Shared files

Removing a file another app still uses breaks that app. Poof flags these instead of
treating them as leftovers:

- Siblings under the same vendor prefix are not matched (`com.google.antigravity` is not Chrome).
- Team ID matches in Group Containers must also name the app (`UBF8T346G9.Office` is shared by all Microsoft apps).
- When another package also installs files into a folder, Poof walks down to the
  subfolders only this app's package uses, and marks the rest `also used by`.
- A receipt for a package that also installed other apps is marked with those apps.

## Install

### App

Download `Poof-<version>.zip` from [Releases](https://github.com/csyio/poof/releases),
unzip it and move `Poof.app` to Applications. The app is not notarized yet, so the first
time macOS blocks it: open System Settings > Privacy & Security and click "Open Anyway".

Then give Poof Full Disk Access (System Settings > Privacy & Security > Full Disk Access).
Without it macOS hides other apps' sandboxed data. Poof shows a banner until it has access.

The app lists your apps, the leftovers of removed apps, and the quarantine. Drop an app
onto the window to inspect one outside the Applications folder. Files in system folders
are moved by the bundled `poof` tool after macOS asks for your password.

### Command line

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
scripts/build-app.sh          # builds dist/Poof.app
```

## Usage

```sh
poof scan chrome            # an installed app and its files
poof orphans                # files left by apps that are already gone
poof orphans --remove       # quarantine the ones Poof is sure about
poof dev                    # caches and build output of developer tools
poof dev --projects ~/Code  # plus node_modules, .build, target... of idle projects
poof dev --remove           # quarantine caches and build output of deleted projects
sudo poof login-items       # what starts at login or runs in the background
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

1. Scanner: browser extensions.
2. Developer ID signing and notarization.

## Releases

Releases are built by GitHub Actions when a `v*` tag is pushed:

1. Move the `Unreleased` notes in `CHANGELOG.md` under a new version heading.
2. Set the same version in `Sources/PoofCore/Version.swift`.
3. Commit, then `git tag v0.2.0 && git push origin main v0.2.0`.

Versions below 1.0 are published as pre-releases.

## License

MIT
