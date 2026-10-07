import Foundation

/// The person Poof is working for. Under `sudo` the process runs as root, but the files
/// to scan and the quarantine belong to the user who typed the command.
public enum UserContext {
    public static var isRoot: Bool { geteuid() == 0 }

    public static var uid: uid_t {
        // SUDO_UID comes from sudo; POOF_UID from the app, which runs the CLI as root
        // through macOS's administrator prompt, where SUDO_UID is not set.
        let env = ProcessInfo.processInfo.environment
        if isRoot, let id = (env["SUDO_UID"] ?? env["POOF_UID"]).flatMap(UInt32.init) {
            return id
        }
        return getuid()
    }

    public static var home: URL {
        if let entry = getpwuid(uid), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
