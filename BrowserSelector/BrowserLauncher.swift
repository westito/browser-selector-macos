import AppKit
import Foundation
import os

enum BrowserLauncher {
    private static let log = Logger(subsystem: "it.marcell.BrowserSelector", category: "launch")

    /// Hands the URLs to the chosen browser. The completion runs on the main queue once the launch
    /// has actually been accepted — quitting before that cancels the pending open request, which
    /// silently drops document-style URLs such as `file://`.
    static func open(_ urls: [URL], in entry: BrowserEntry, completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty else {
            completion(false)
            return
        }
        log.info("opening \(urls.count) URL(s) in \(entry.name, privacy: .public)")

        if let profileDirectory = entry.profileDirectory, entry.kind == .chromeProfile {
            openInChromeProfile(urls, profileDirectory: profileDirectory, bundleIdentifier: entry.bundleIdentifier, completion: completion)
        } else {
            openInApplication(urls, bundleIdentifier: entry.bundleIdentifier, completion: completion)
        }
    }

    private static func openInApplication(_ urls: [URL], bundleIdentifier: String, completion: @escaping (Bool) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            log.error("no application found for \(bundleIdentifier, privacy: .public)")
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                log.error("\(bundleIdentifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    /// `open -n -b <bundle> --args --profile-directory=…` is the only reliable way to target a specific
    /// Chrome profile: the flag is honoured even when Chrome is already running, which the
    /// NSWorkspace launch APIs cannot express.
    private static func openInChromeProfile(
        _ urls: [URL],
        profileDirectory: String,
        bundleIdentifier: String,
        completion: @escaping (Bool) -> Void
    ) {
        let arguments = [
            "-n", "-b", bundleIdentifier,
            "--args", "--profile-directory=\(profileDirectory)"
        ] + urls.map(\.absoluteString)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments

            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
                if !succeeded {
                    log.error("open exited with status \(process.terminationStatus)")
                }
            } catch {
                log.error("failed to launch \(bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { completion(succeeded) }
        }
    }
}
