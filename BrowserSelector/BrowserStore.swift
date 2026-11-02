import AppKit
import Foundation

nonisolated enum BrowserStore {
    private static let folderName = "BrowserSelector"
    private static let cacheFileName = "browsers.json"

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static var iconsDirectory: URL {
        supportDirectory.appendingPathComponent("icons", isDirectory: true)
    }

    private static var cacheFile: URL {
        supportDirectory.appendingPathComponent(cacheFileName)
    }

    static func loadCached() -> [BrowserEntry] {
        guard let data = try? Data(contentsOf: cacheFile),
              let entries = try? JSONDecoder().decode([BrowserEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Scans and saves the result. An incomplete scan only replaces a missing or empty cache:
    /// a transient `Local State` read failure must not shrink a good list to Safari only.
    @discardableResult
    static func refresh() -> BrowserDiscovery.ScanResult {
        createDirectoriesIfNeeded()
        let result = BrowserDiscovery.scan(iconsDirectory: iconsDirectory)
        if result.isComplete || loadCached().isEmpty,
           let data = try? JSONEncoder().encode(result.entries) {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return result
    }

    @MainActor private static var iconCache: [String: NSImage?] = [:]

    @MainActor
    static func iconImage(named fileName: String?) -> NSImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let cached = iconCache[fileName] { return cached }
        let image = NSImage(contentsOf: iconsDirectory.appendingPathComponent(fileName))
        iconCache[fileName] = image
        return image
    }

    /// Icon files are rewritten under the same names, so a refresh must drop the decoded images.
    @MainActor
    static func invalidateIconCache() {
        iconCache.removeAll()
    }

    private static func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
    }
}
