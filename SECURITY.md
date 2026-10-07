# Security

Poof deletes files and can run parts of itself as root, so security reports matter.

Please report vulnerabilities privately through GitHub: open the repository's **Security**
tab and choose **Report a vulnerability**. Do not open a public issue.

Useful details: the Poof version (`poof --version`), macOS version, and steps to reproduce.

Areas worth extra scrutiny:

- `Sources/PoofApp/AppModel.swift` (`PrivilegedRunner`): builds the shell command run as root
  through the administrator prompt.
- `Sources/poof/Poof.swift` (`admin-move`): moves arbitrary paths when run as root.
- `Sources/PoofCore/Quarantine.swift`: moves and restores files, including under `sudo`.
