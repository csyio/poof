import PoofCore
import SwiftUI

/// Poof's colours, taken from the app icon's purple-to-blue gradient.
enum Brand {
    static let purple = Color(red: 0.47, green: 0.27, blue: 0.96)
    static let blue = Color(red: 0.16, green: 0.55, blue: 0.98)
    /// A single colour between the two, for controls that take one tint.
    static let accent = Color(red: 0.36, green: 0.36, blue: 0.97)
    static let gradient = LinearGradient(colors: [purple, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// One spacing scale for every screen.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
}

/// Semantic colours for badges, tiles and banners.
enum Tone: Equatable {
    case positive, caution, danger, info, neutral, brand, homebrew
    case custom(Color)

    var color: Color {
        switch self {
        case .positive: .green
        case .caution: .orange
        case .danger: .red
        case .info: .blue
        case .neutral: .secondary
        case .brand: Brand.accent
        case .homebrew: .brown
        case .custom(let color): color
        }
    }

    /// Fill behind text in this tone. Neutral uses a grey that reads in both appearances.
    var fill: Color {
        self == .neutral ? Color.primary.opacity(0.07) : color.opacity(0.14)
    }
}

/// Title, symbol, tint and one-line description of each sidebar section.
struct SectionStyle {
    let title: String
    let symbol: String
    let tint: Color
    let summary: String

    static let apps = SectionStyle(
        title: "Apps", symbol: "square.grid.2x2.fill", tint: .blue,
        summary: "Where each app came from and when you last opened it. Select an app to see why it is here.")
    static let leftovers = SectionStyle(
        title: "Leftovers", symbol: "sparkles", tint: .purple,
        summary: "Files from apps that are no longer installed.")
    static let developer = SectionStyle(
        title: "Developer", symbol: "hammer.fill", tint: .orange,
        summary: "Caches and build output of developer tools. Quarantined items use space until you delete them.")
    static let loginItems = SectionStyle(
        title: "Login Items", symbol: "power", tint: .green,
        summary: "What starts at login or runs in the background. macOS removes these records when their app is gone.")
    static let extensions = SectionStyle(
        title: "Browser Extensions", symbol: "puzzlepiece.extension.fill", tint: .teal,
        summary: "Extensions in every browser profile. A flag is a reason to look, not a sign that an extension is harmful.")
    static let quarantine = SectionStyle(
        title: "Quarantine", symbol: "archivebox.fill", tint: .gray,
        summary: "Removed items wait here until you put them back or delete them.")
}

extension Verdict {
    var tone: Tone {
        switch self {
        case .unused: .positive
        case .runsInBackground: .caution
        case .recentlyUsed: .info
        case .managedByHomebrew: .homebrew
        case .fromAppStore: .custom(.teal)
        case .partOfMacOS, .componentOf, .unknownOrigin, .noUsageRecord: .neutral
        }
    }

    var symbol: String {
        switch self {
        case .unused: "moon.zzz.fill"
        case .runsInBackground: "gearshape.2.fill"
        case .recentlyUsed: "clock.fill"
        case .managedByHomebrew: "mug.fill"
        case .fromAppStore: "bag.fill"
        case .partOfMacOS: "apple.logo"
        case .componentOf: "shippingbox.fill"
        case .unknownOrigin: "questionmark.circle.fill"
        case .noUsageRecord: "eye.fill"
        }
    }

    /// The verdict word with a capital letter, for badges.
    var title: String {
        word == "macOS" ? word : word.prefix(1).uppercased() + word.dropFirst()
    }
}

extension Tone {
    /// An opaque colour for filled shapes such as icon tiles.
    var solid: Color {
        self == .neutral ? .gray : color
    }
}

extension AppOrigin {
    var symbol: String {
        switch self {
        case .macOS: "apple.logo"
        case .appStore: "bag.fill"
        case .homebrew: "mug.fill"
        case .setapp: "square.stack.3d.up.fill"
        case .installer: "shippingbox.fill"
        case .downloaded: "arrow.down.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}
