import AppKit
import Observation
import SwiftUI

@Observable
final class PickerModel {
    private(set) var entries: [BrowserEntry]
    /// Bumped on every update: icon files can change on disk while the entries compare equal.
    private(set) var iconRevision = 0
    let url: URL?

    init(entries: [BrowserEntry], url: URL?) {
        self.entries = entries
        self.url = url
    }

    func update(entries: [BrowserEntry]) {
        self.entries = entries
        iconRevision += 1
    }
}

struct PickerView: View {
    let model: PickerModel
    let onPick: (BrowserEntry) -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onSizeChange: () -> Void

    private enum Metrics {
        static let width: CGFloat = 260
        static let rowHeight: CGFloat = 38
        static let maxListHeight: CGFloat = 420
        static let listPadding: CGFloat = 6
        static let cornerRadius: CGFloat = 12
    }

    @State private var selection: Int = 0
    @State private var keyMonitor: Any?

    /// The copy row follows the browsers in the selection order.
    private var copyIndex: Int { model.entries.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            list(entries: model.entries, iconRevision: model.iconRevision)
            Divider().opacity(0.5)
            copyRow
        }
        .frame(width: Metrics.width)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in onSizeChange() }
        .onChange(of: model.entries) { oldEntries, newEntries in
            selection = preservedSelection(from: oldEntries, to: newEntries)
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private var header: some View {
        Text(headerText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        guard let url = model.url else { return "Open link" }
        return url.host ?? url.absoluteString
    }

    private func list(entries: [BrowserEntry], iconRevision: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        PickerRow(
                            entry: entry,
                            shortcut: index < 9 ? String(index + 1) : nil,
                            isSelected: index == selection,
                            iconRevision: iconRevision
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { selection = index }
                        }
                        .onTapGesture { onPick(entry) }
                    }
                }
                .padding(Metrics.listPadding)
            }
            .frame(height: listHeight(rowCount: entries.count))
            .onChange(of: selection) { _, newValue in
                guard newValue < entries.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func listHeight(rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(rowCount, 1))
        let content = rows * Metrics.rowHeight + max(rows - 1, 0) * 2 + Metrics.listPadding * 2
        return min(content, Metrics.maxListHeight)
    }

    /// Kept outside the scroll view so it stays visible however long the browser list is.
    private var copyRow: some View {
        CopyLinkRow(isSelected: selection == copyIndex)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { selection = copyIndex }
            }
            .onTapGesture { onCopy() }
            .padding(Metrics.listPadding)
    }

    private func preservedSelection(from oldEntries: [BrowserEntry], to newEntries: [BrowserEntry]) -> Int {
        guard selection < oldEntries.count else { return newEntries.count }
        let selectedID = oldEntries[selection].id
        if let index = newEntries.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return min(selection, max(newEntries.count - 1, 0))
    }

    private func activate(_ index: Int) {
        if model.entries.indices.contains(index) {
            onPick(model.entries[index])
        } else {
            onCopy()
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let itemCount = model.entries.count + 1
        switch event.keyCode {
        case 126: // Up
            selection = selection > 0 ? selection - 1 : itemCount - 1
            return true
        case 125: // Down
            selection = selection < itemCount - 1 ? selection + 1 : 0
            return true
        case 36, 76: // Return, keypad Enter
            activate(selection)
            return true
        case 53: // Escape
            onCancel()
            return true
        default:
            break
        }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.charactersIgnoringModifiers?.lowercased() == "c", modifiers == [] || modifiers == .command {
            onCopy()
            return true
        }

        if let characters = event.charactersIgnoringModifiers,
           let digit = characters.first.flatMap({ $0.wholeNumberValue }),
           (1...9).contains(digit),
           digit <= model.entries.count {
            onPick(model.entries[digit - 1])
            return true
        }
        return false
    }
}

private struct PickerRow: View {
    let entry: BrowserEntry
    let shortcut: String?
    let isSelected: Bool
    /// Not displayed; a new value makes the row re-read its icons from the store.
    let iconRevision: Int

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(entry.color ?? .clear)
                .frame(width: 3, height: 22)
                .opacity(entry.color == nil ? 0 : 1)

            icon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .pickerRowChrome(isSelected: isSelected)
    }

    @ViewBuilder
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = BrowserStore.iconImage(named: entry.iconFileName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Circle()
                    .fill(entry.color ?? Color.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Text(entry.initial)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }

            if let badge = BrowserStore.iconImage(named: entry.badgeIconFileName) {
                Image(nsImage: badge)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 11, height: 11)
                    .clipShape(Circle())
                    .offset(x: 2, y: 2)
            }
        }
    }
}

private struct CopyLinkRow: View {
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 3, height: 22)

            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            Text("Copy Link")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("⌘C")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .pickerRowChrome(isSelected: isSelected)
    }
}

private extension View {
    func pickerRowChrome(isSelected: Bool) -> some View {
        padding(.horizontal, 6)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0))
            )
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
