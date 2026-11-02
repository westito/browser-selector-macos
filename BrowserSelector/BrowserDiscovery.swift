import AppKit
import Foundation

nonisolated enum BrowserDiscovery {
    nonisolated struct ScanResult: Sendable {
        let entries: [BrowserEntry]
        /// False when Chrome is installed but its `Local State` could not be read. Chrome rewrites
        /// that file while running, so the failure may be transient and the result must not
        /// replace a previously complete list.
        let isComplete: Bool
    }

    private static let safariBundleID = "com.apple.Safari"
    private static let chromeBundleID = "com.google.Chrome"
    private static let iconSide: CGFloat = 64
    private static let badgeSide: CGFloat = 32

    static func scan(iconsDirectory: URL) -> ScanResult {
        var entries: [BrowserEntry] = []
        if let safari = scanSafari(iconsDirectory: iconsDirectory) {
            entries.append(safari)
        }
        let chromeProfiles = scanChromeProfiles(iconsDirectory: iconsDirectory)
        entries.append(contentsOf: chromeProfiles ?? [])
        return ScanResult(entries: entries, isComplete: chromeProfiles != nil)
    }

    // MARK: - Safari

    private static func scanSafari(iconsDirectory: URL) -> BrowserEntry? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let iconFileName = writePNG(icon, side: iconSide, to: iconsDirectory, named: "safari.png")
        return BrowserEntry(
            id: "safari",
            kind: .safari,
            name: "Safari",
            subtitle: nil,
            bundleIdentifier: safariBundleID,
            profileDirectory: nil,
            colorARGB: nil,
            iconFileName: iconFileName,
            badgeIconFileName: nil
        )
    }

    // MARK: - Chrome

    /// Nil when Chrome is installed but its profile list could not be read.
    private static func scanChromeProfiles(iconsDirectory: URL) -> [BrowserEntry]? {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) else {
            return []
        }
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard let infoCache = readInfoCache(chromeRoot: root) else { return nil }

        let badgeIcon = writePNG(
            NSWorkspace.shared.icon(forFile: chromeURL.path),
            side: badgeSide,
            to: iconsDirectory,
            named: "chrome-app.png"
        )

        return sortedProfileKeys(infoCache.keys).compactMap { key in
            guard let info = infoCache[key] as? [String: Any] else { return nil }
            return makeChromeEntry(
                directoryKey: key,
                info: info,
                chromeRoot: root,
                iconsDirectory: iconsDirectory,
                badgeIconFileName: badgeIcon
            )
        }
    }

    private static func readInfoCache(chromeRoot: URL) -> [String: Any]? {
        let localState = chromeRoot.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else { return nil }
        return infoCache
    }

    private static func makeChromeEntry(
        directoryKey: String,
        info: [String: Any],
        chromeRoot: URL,
        iconsDirectory: URL,
        badgeIconFileName: String?
    ) -> BrowserEntry? {
        let profileDirectory = chromeRoot.appendingPathComponent(directoryKey, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profileDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        if let ephemeral = info["is_ephemeral"] as? Bool, ephemeral { return nil }

        let name = nonEmptyString(info["name"])
            ?? nonEmptyString(info["gaia_name"])
            ?? directoryKey
        let subtitle = nonEmptyString(info["user_name"])
        let color = (info["profile_highlight_color"] as? NSNumber)
            ?? (info["default_avatar_fill_color"] as? NSNumber)

        let id = "chrome:\(directoryKey)"
        var iconFileName: String?
        let picture = profileDirectory.appendingPathComponent("Google Profile Picture.png")
        if FileManager.default.fileExists(atPath: picture.path),
           let image = NSImage(contentsOf: picture) {
            iconFileName = writePNG(
                image,
                side: iconSide,
                to: iconsDirectory,
                named: "\(sanitize(id)).png"
            )
        }

        return BrowserEntry(
            id: id,
            kind: .chromeProfile,
            name: name,
            subtitle: subtitle,
            bundleIdentifier: chromeBundleID,
            profileDirectory: directoryKey,
            colorARGB: color.map { Int32(truncatingIfNeeded: $0.intValue) },
            iconFileName: iconFileName,
            badgeIconFileName: badgeIconFileName
        )
    }

    // MARK: - Helpers

    /// "Default" first, then "Profile N" in numeric order, then anything else alphabetically.
    private static func sortedProfileKeys(_ keys: some Collection<String>) -> [String] {
        func rank(_ key: String) -> (Int, Int, String) {
            if key == "Default" { return (0, 0, key) }
            if key.hasPrefix("Profile "), let number = Int(key.dropFirst("Profile ".count)) {
                return (1, number, key)
            }
            return (2, 0, key)
        }
        return keys.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l.0 != r.0 { return l.0 < r.0 }
            if l.1 != r.1 { return l.1 < r.1 }
            return l.2.localizedStandardCompare(r.2) == .orderedAscending
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    @discardableResult
    private static func writePNG(_ image: NSImage, side: CGFloat, to directory: URL, named fileName: String) -> String? {
        let pixels = Int(side)
        // Scans run off the main thread, where `NSImage.lockFocus()` is not safe; an explicit bitmap
        // context is.
        guard let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixels,
                  pixelsHigh: pixels,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.set()
        rect.fill(using: .copy)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let url = directory.appendingPathComponent(fileName)
        do {
            try png.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }
}
