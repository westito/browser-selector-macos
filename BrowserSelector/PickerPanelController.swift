import AppKit
import SwiftUI

protocol PickerPanelControllerDelegate: AnyObject {
    func pickerPanel(_ controller: PickerPanelController, didPick entry: BrowserEntry)
    func pickerPanelDidCopy(_ controller: PickerPanelController)
    func pickerPanelDidCancel(_ controller: PickerPanelController)
}

final class PickerPanelController: NSObject, NSWindowDelegate {
    private enum Outcome {
        case pick(BrowserEntry)
        case copy
        case cancel
    }

    weak var delegate: PickerPanelControllerDelegate?

    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<PickerView>?
    private var model: PickerModel?
    /// Top-left corner the panel grows and shrinks from.
    private var anchor: NSPoint = .zero
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isDismissed = false

    func show(entries: [BrowserEntry], url: URL?) {
        guard panel == nil else { return }

        let model = PickerModel(entries: entries, url: url)
        let view = PickerView(
            model: model,
            onPick: { [weak self] entry in self?.finish(.pick(entry)) },
            onCopy: { [weak self] in self?.finish(.copy) },
            onCancel: { [weak self] in self?.finish(.cancel) },
            onSizeChange: { [weak self] in
                DispatchQueue.main.async { self?.resizeToFit() }
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hostingView
        panel.delegate = self
        let initialFrame = frame(for: hostingView.fittingSize)
        panel.setFrame(initialFrame, display: false)
        anchor = NSPoint(x: initialFrame.minX, y: initialFrame.maxY)

        self.panel = panel
        self.hostingView = hostingView
        self.model = model
        installMouseMonitors()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Replaces the listed browsers while the panel is open; a no-op once it has been dismissed.
    func update(entries: [BrowserEntry]) {
        guard let model, panel != nil else { return }
        model.update(entries: entries)
        resizeToFit()
    }

    // MARK: - Placement

    private func frame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let gap: CGFloat = 6

        var origin = NSPoint(x: mouse.x + gap, y: mouse.y - gap - size.height)

        // Screen coordinates grow upwards: falling below the visible area means the popup would
        // hang off the bottom, so flip it above the cursor instead.
        if origin.y < visible.minY {
            origin.y = mouse.y + gap
        }
        return clamp(NSRect(origin: origin, size: size), to: visible)
    }

    /// Fits the panel to its content with the top-left corner fixed. SwiftUI may apply a model
    /// change after `update(entries:)` returns, so the view also reports later size changes here.
    private func resizeToFit() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let resized = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? resized
        let target = clamp(resized, to: visible)
        anchor = NSPoint(x: target.minX, y: target.maxY)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    private func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        return NSRect(origin: origin, size: frame.size)
    }

    // MARK: - Dismissal

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.finish(.cancel)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.finish(.cancel)
                return nil
            }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func finish(_ outcome: Outcome) {
        guard !isDismissed else { return }
        isDismissed = true

        removeMouseMonitors()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
        model = nil

        switch outcome {
        case .pick(let entry):
            delegate?.pickerPanel(self, didPick: entry)
        case .copy:
            delegate?.pickerPanelDidCopy(self)
        case .cancel:
            delegate?.pickerPanelDidCancel(self)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        finish(.cancel)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
