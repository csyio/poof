/// Bundle-ID-style names written by libraries, command-line tools and macOS itself
/// rather than by an app, so their files are never reported as orphaned.
///
/// An entry matches the ID itself and anything below it ("org.swift" covers
/// "org.swift.swiftpm"). Add new entries in lowercase, sorted.
let knownNonAppIDs: [String] = [
    "com.amplitude",              // analytics SDK
    "com.bugsnag",                // crash reporting SDK
    "com.crashlytics",            // crash reporting SDK
    "com.github.electron",        // Electron's default ID before an app renames itself
    "com.google.firebase",        // Firebase SDK
    "com.hackemist",              // SDWebImage cache
    "com.launchdarkly",           // feature flag SDK
    "com.microsoft.appcenter",    // App Center SDK
    "com.mixpanel",               // analytics SDK
    "com.plausiblelabs",          // PLCrashReporter
    "com.qtproject",              // Qt framework settings
    "com.segment",                // analytics SDK
    "io.sentry",                  // crash reporting SDK
    "org.cups",                   // macOS printing system
    "org.nodejs",                 // Node.js
    "org.python",                 // Python
    "org.sparkle-project",        // Sparkle updater framework
    "org.swift",                  // Swift toolchain and SwiftPM caches
]

func isKnownNonApp(_ id: String) -> Bool {
    let id = id.lowercased()
    return knownNonAppIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
}
