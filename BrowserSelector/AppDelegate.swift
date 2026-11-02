import AppKit
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate, PickerPanelControllerDelegate {
    private static let log = Logger(subsystem: "it.marcell.BrowserSelector", category: "app")

    private enum Constants {
        /// Grace period to tell "opened by a link" apart from "launched from Finder".
        static let launchGracePeriod: TimeInterval = 0.3
        static let inactivityTimeout: TimeInterval = 120
        static let launchTimeout: TimeInterval = 15
    }

    private var pendingURLs: [URL] = []
    private var seenURLs: Set<String> = []
    private var isFinishedLaunching = false
    private var panelController: PickerPanelController?
    private var safetyTimer: Timer?
    private var isRefreshing = false
    private var isLaunching = false
    private var wantsTermination = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        isFinishedLaunching = true
        if !pendingURLs.isEmpty {
            startLinkFlow()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.launchGracePeriod) { [weak self] in
            guard let self, self.panelController == nil else { return }
            if self.pendingURLs.isEmpty {
                self.startDirectLaunchFlow()
            } else {
                self.startLinkFlow()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Incoming URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        accept(urls)
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        accept([url])
    }

    private func accept(_ urls: [URL]) {
        let fresh = urls.filter { seenURLs.insert($0.absoluteString).inserted }
        for url in fresh {
            Self.log.info("received \(url.scheme ?? "?", privacy: .public) URL: \(url.absoluteString, privacy: .private)")
        }
        guard !fresh.isEmpty else { return }
        pendingURLs.append(contentsOf: fresh)

        guard isFinishedLaunching, panelController == nil else { return }
        startLinkFlow()
    }

    // MARK: - Link flow

    private func startLinkFlow() {
        var entries = BrowserStore.loadCached()
        let isFromCache = !entries.isEmpty
        if entries.isEmpty {
            entries = BrowserStore.refresh().entries
        }
        guard !entries.isEmpty else {
            Self.log.error("no browsers found, cannot open \(self.pendingURLs.count) URL(s)")
            NSApp.terminate(nil)
            return
        }

        let controller = PickerPanelController()
        controller.delegate = self
        panelController = controller
        controller.show(entries: entries, url: pendingURLs.first)

        safetyTimer = Timer.scheduledTimer(withTimeInterval: Constants.inactivityTimeout, repeats: false) { _ in
            NSApp.terminate(nil)
        }

        if isFromCache {
            startBackgroundRefresh()
        }
    }

    private func startBackgroundRefresh() {
        isRefreshing = true
        Task.detached(priority: .userInitiated) {
            let result = BrowserStore.refresh()
            await self.backgroundRefreshDidFinish(result)
        }
    }

    private func backgroundRefreshDidFinish(_ result: BrowserDiscovery.ScanResult) {
        isRefreshing = false
        Self.log.info("background refresh found \(result.entries.count) browser(s), complete: \(result.isComplete)")
        BrowserStore.invalidateIconCache()
        if result.isComplete, !result.entries.isEmpty {
            panelController?.update(entries: result.entries)
        }
        terminateIfIdle()
    }

    func pickerPanel(_ controller: PickerPanelController, didPick entry: BrowserEntry) {
        // Quitting while the open request is still in flight cancels it, so the process stays alive
        // until the browser has taken the URLs.
        isLaunching = true
        requestTermination()
        BrowserLauncher.open(pendingURLs, in: entry) { [weak self] _ in
            self?.isLaunching = false
            self?.terminateIfIdle()
        }
    }

    func pickerPanelDidCopy(_ controller: PickerPanelController) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pendingURLs.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        Self.log.info("copied \(self.pendingURLs.count) URL(s) to the pasteboard")
        requestTermination()
    }

    func pickerPanelDidCancel(_ controller: PickerPanelController) {
        requestTermination()
    }

    // MARK: - Termination

    /// Quits once the pending launch and the background refresh have both finished, bounded by
    /// `launchTimeout` in case either never completes.
    private func requestTermination() {
        if !wantsTermination {
            wantsTermination = true
            safetyTimer?.invalidate()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: Constants.launchTimeout, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
        terminateIfIdle()
    }

    private func terminateIfIdle() {
        guard wantsTermination, !isLaunching, !isRefreshing else { return }
        NSApp.terminate(nil)
    }

    // MARK: - Direct launch flow

    private func startDirectLaunchFlow() {
        let entries = BrowserStore.refresh().entries
        Task { @MainActor in
            var failure: String?
            let bundleURL = Bundle.main.bundleURL

            // macOS treats http and https as one "default browser" setting, so the second request is
            // redundant once the first one succeeded and answers with a spurious error. Each scheme is
            // therefore requested only while it still points elsewhere, and the outcome is judged by
            // the resulting handler rather than by the thrown errors.
            for scheme in ["http", "https"] where !self.isDefaultHandler(forScheme: scheme) {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: scheme)
                } catch {
                    failure = failure ?? error.localizedDescription
                }
            }

            let isDefault = ["http", "https"].allSatisfy(self.isDefaultHandler(forScheme:))
            self.showSummary(entryCount: entries.count, isDefault: isDefault, failure: isDefault ? nil : failure)
            NSApp.terminate(nil)
        }
    }

    private func isDefaultHandler(forScheme scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func showSummary(entryCount: Int, isDefault: Bool, failure: String?) {
        let alert = NSAlert()
        alert.messageText = "Found \(entryCount) browser\(entryCount == 1 ? "" : "s")"
        if let failure {
            alert.informativeText = "BrowserSelector could not be set as the default browser: \(failure)"
        } else if isDefault {
            alert.informativeText = "BrowserSelector is the default browser."
        } else {
            alert.informativeText = "BrowserSelector is not the default browser yet."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
