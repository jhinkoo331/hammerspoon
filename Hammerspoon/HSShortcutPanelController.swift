import AppKit
import Combine
import SwiftUI

private struct HSShortcut: Identifiable, Equatable {
    let id: String
    let keys: String
    let title: String
}

private struct HSLuaHotkey: Decodable {
    let idx: String
    let msg: String?
}

private enum HSShortcutPanelError: LocalizedError {
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Hammerspoon 返回了无法识别的快捷键数据。"
        }
    }
}

@MainActor
private final class HSConfigurationWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pendingRefresh: DispatchWorkItem?

    func start(onChange: @escaping () -> Void) {
        stop()

        descriptor = open(MJConfigDirAbsolute(), O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pendingRefresh?.cancel()
            let work = DispatchWorkItem(block: onChange)
            pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
private final class HSShortcutStore: ObservableObject {
    @Published private(set) var shortcuts: [HSShortcut] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let watcher = HSConfigurationWatcher()
    private var refreshTimer: Timer?
    private var isActive = false

    private let query = """
    local result = {}
    for _, hotkey in ipairs(hs.hotkey.getHotkeys()) do
        table.insert(result, { idx = hotkey.idx, msg = hotkey.msg })
    end
    return hs.json.encode(result)
    """

    func activate() {
        guard !isActive else { return }
        isActive = true
        watcher.start { [weak self] in self?.refresh(silently: true) }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(silently: true)
            }
        }
    }

    func refresh(silently: Bool = false) {
        if !silently { isLoading = true }

        do {
            let output = MJLuaRunString(query) ?? ""
            guard let data = output.data(using: .utf8) else {
                throw HSShortcutPanelError.invalidOutput
            }
            let hotkeys = try JSONDecoder().decode([HSLuaHotkey].self, from: data)
            shortcuts = hotkeys.map { hotkey in
                let title = Self.cleanedTitle(message: hotkey.msg, keys: hotkey.idx)
                return HSShortcut(id: "\(hotkey.idx)|\(title)", keys: hotkey.idx, title: title)
            }.sorted(by: Self.shortcutOrder)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private static func cleanedTitle(message: String?, keys: String) -> String {
        guard var title = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "未命名快捷键"
        }

        if title.hasPrefix(keys) {
            title.removeFirst(keys.count)
            title = title.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：-–—"))
            )
        }
        return title.isEmpty ? "未命名快捷键" : title
    }

    private static func shortcutOrder(_ lhs: HSShortcut, _ rhs: HSShortcut) -> Bool {
        let left = sortableParts(for: lhs.keys)
        let right = sortableParts(for: rhs.keys)

        if left.modifiers != right.modifiers {
            return left.modifiers < right.modifiers
        }
        let keyComparison = left.key.localizedStandardCompare(right.key)
        if keyComparison != .orderedSame {
            return keyComparison == .orderedAscending
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func sortableParts(for shortcut: String) -> (modifiers: String, key: String) {
        let modifierSymbols: [(symbol: Character, rank: Character)] = [
            ("⌃", "1"), ("⌥", "2"), ("⇧", "3"), ("⌘", "4")
        ]
        let modifiers = String(modifierSymbols.compactMap { shortcut.contains($0.symbol) ? $0.rank : nil })
        let key = shortcut
            .filter { character in !modifierSymbols.contains(where: { $0.symbol == character }) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedUppercase
        return (modifiers, key)
    }
}

@MainActor
private final class HSPopoverSizing: ObservableObject {
    @Published var height: Double

    private let minimumHeight = 320.0
    private var dragStartHeight: Double?
    private let userDefaultsKey = "HSShortcutPopoverHeight"

    private var maximumHeight: Double {
        max(minimumHeight, (NSScreen.main?.visibleFrame.height ?? 900) * 0.8)
    }

    init() {
        let savedHeight = UserDefaults.standard.double(forKey: userDefaultsKey)
        let screenMaximumHeight = max(minimumHeight, (NSScreen.main?.visibleFrame.height ?? 900) * 0.8)
        height = min(max(savedHeight > 0 ? savedHeight : 630, minimumHeight), screenMaximumHeight)
    }

    func clampForCurrentScreen() {
        height = min(max(height, minimumHeight), maximumHeight)
    }

    func resize(translation: CGFloat) {
        if dragStartHeight == nil { dragStartHeight = height }
        height = min(max((dragStartHeight ?? height) + Double(translation), minimumHeight), maximumHeight)
    }

    func finishResizing() {
        dragStartHeight = nil
        UserDefaults.standard.set(height, forKey: userDefaultsKey)
    }
}

@MainActor
private struct HSShortcutPanelView: View {
    @ObservedObject var store: HSShortcutStore
    @ObservedObject var sizing: HSPopoverSizing

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            resizeHandle
        }
        .frame(width: 380, height: sizing.height)
        .onAppear {
            sizing.clampForCurrentScreen()
            store.refresh()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hammerspoon 快捷键").font(.headline)
                Text("当前生效的全局快捷键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage, store.shortcuts.isEmpty {
            emptyState(title: "无法读取快捷键", systemImage: "exclamationmark.triangle", detail: error) {
                Button("重试") { store.refresh() }
            }
        } else if store.shortcuts.isEmpty, !store.isLoading {
            emptyState(
                title: "没有快捷键",
                systemImage: "keyboard",
                detail: "请在 hs.hotkey.bind 中加入 message 参数。"
            ) { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.shortcuts) { shortcut in
                        shortcutRow(shortcut)
                        if shortcut.id != store.shortcuts.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func emptyState<Actions: View>(
        title: String,
        systemImage: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutRow(_ shortcut: HSShortcut) -> some View {
        HStack(spacing: 12) {
            Text(shortcut.keys)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 72, alignment: .leading)
            Text(shortcut.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { hovering in
                hovering ? NSCursor.resizeUpDown.push() : NSCursor.pop()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { sizing.resize(translation: $0.translation.height) }
                    .onEnded { _ in sizing.finishResizing() }
            )
            .help("上下拖动调整弹窗高度")
    }

}

@MainActor
@objcMembers
final class HSShortcutPanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let store = HSShortcutStore()
    private let sizing = HSPopoverSizing()
    private var sizeObservation: AnyCancellable?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: HSShortcutPanelView(store: store, sizing: sizing)
        )
        popover.contentSize = NSSize(width: 380, height: sizing.height)
        sizeObservation = sizing.$height.sink { [weak popover] height in
            popover?.contentSize = NSSize(width: 380, height: height)
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
