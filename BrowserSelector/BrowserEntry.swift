import AppKit
import SwiftUI

nonisolated struct BrowserEntry: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case safari
        case chromeProfile
    }

    let id: String
    let kind: Kind
    let name: String
    let subtitle: String?
    let bundleIdentifier: String
    let profileDirectory: String?
    let colorARGB: Int32?
    let iconFileName: String?
    let badgeIconFileName: String?

    /// Chrome stores the highlight color as a signed 32-bit ARGB value.
    var nsColor: NSColor? {
        guard let colorARGB else { return nil }
        let raw = UInt32(bitPattern: colorARGB)
        let alpha = CGFloat((raw >> 24) & 0xFF) / 255
        let red = CGFloat((raw >> 16) & 0xFF) / 255
        let green = CGFloat((raw >> 8) & 0xFF) / 255
        let blue = CGFloat(raw & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha == 0 ? 1 : alpha)
    }

    var color: Color? {
        guard let nsColor else { return nil }
        return Color(nsColor)
    }

    var initial: String {
        String(name.first.map(String.init)?.uppercased() ?? "?")
    }
}
