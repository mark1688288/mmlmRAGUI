import AppKit
import Observation
import SwiftUI

#if os(macOS)

/// Open mmlmRAG windows, so one compare window can show two of them.
/// Each conversation owns its `RagSession`; this catalog only keeps the text.
@MainActor
@Observable
final class OpenTabCatalog {
    struct Tab: Identifiable, Equatable {
        let id: UUID
        var title: String
        var question: String
        var answer: String
        var isAsking: Bool
    }

    struct SidePair: Equatable {
        var left: UUID
        var right: UUID
    }

    static let shared = OpenTabCatalog()

    private(set) var tabs: [Tab] = []
    /// Content tab that was key most recently. Stays put while the compare window is key.
    private(set) var lastFrontID: UUID?

    private struct WindowAnchor {
        weak var window: NSWindow?
    }

    private var windowAnchors: [UUID: WindowAnchor] = [:]

    func upsert(
        id: UUID,
        window: NSWindow?,
        title: String,
        question: String,
        answer: String,
        isAsking: Bool
    ) {
        if let window {
            if isOpen(window) {
                windowAnchors[id] = WindowAnchor(window: window)
            } else {
                remove(id: id)
                return
            }
        } else if windowAnchors[id]?.window == nil {
            remove(id: id)
            return
        }
        windowAnchors = windowAnchors.filter { isOpen($0.value.window) }

        var next = tabs.filter { windowAnchors[$0.id] != nil }
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index].title = title
            next[index].question = question
            next[index].answer = answer
            next[index].isAsking = isAsking
        } else {
            next.append(Tab(
                id: id,
                title: title,
                question: question,
                answer: answer,
                isAsking: isAsking
            ))
        }
        let orderedTabs = ordered(next)
        guard orderedTabs != tabs else { return }
        tabs = orderedTabs
    }

    func remove(id: UUID) {
        windowAnchors[id] = nil
        let next = tabs.filter { $0.id != id }
        if next != tabs {
            tabs = next
        }
        if lastFrontID == id {
            lastFrontID = nil
        }
    }

    func noteFront(id: UUID) {
        lastFrontID = id
    }

    func window(for id: UUID) -> NSWindow? {
        windowAnchors[id]?.window
    }

    /// Tab-bar order, leading to trailing. Separate windows follow front-to-back.
    func refreshOrder() {
        windowAnchors = windowAnchors.filter { isOpen($0.value.window) }
        if let lastFrontID, !isOpen(windowAnchors[lastFrontID]?.window) {
            self.lastFrontID = nil
        }
        let next = ordered(tabs.filter { windowAnchors[$0.id] != nil })
        guard next != tabs else { return }
        tabs = next
    }

    func label(for id: UUID) -> String {
        Self.label(for: id, tabs: tabs)
    }

    func resolvedPair(left: UUID?, right: UUID?) -> SidePair? {
        Self.resolvedPair(ids: tabs.map(\.id), lastFrontID: lastFrontID, left: left, right: right)
    }

    static func label(for id: UUID, tabs: [Tab]) -> String {
        guard let tab = tabs.first(where: { $0.id == id }) else { return "mmlmRAG" }
        let sameTitle = tabs.filter { $0.title == tab.title }
        guard sameTitle.count > 1, let index = sameTitle.firstIndex(where: { $0.id == id }) else {
            return tab.title
        }
        return "\(tab.title) · \(index + 1)"
    }

    /// Keeps a choice that still exists. The first choice puts the front tab on the left
    /// and the next tab-bar neighbour on the right.
    static func resolvedPair(
        ids: [UUID],
        lastFrontID: UUID?,
        left: UUID?,
        right: UUID?
    ) -> SidePair? {
        guard ids.count >= 2 else { return nil }
        let leftID: UUID
        if let left, ids.contains(left) {
            leftID = left
        } else if let lastFrontID, ids.contains(lastFrontID) {
            leftID = lastFrontID
        } else {
            leftID = ids[0]
        }
        let rightID: UUID
        if let right, ids.contains(right), right != leftID {
            rightID = right
        } else if let next = next(after: leftID, in: ids) {
            rightID = next
        } else {
            return nil
        }
        return SidePair(left: leftID, right: rightID)
    }

    static func next(after id: UUID, in ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: id) else {
            return ids.first { $0 != id }
        }
        let after = index + 1
        if after < ids.count {
            return ids[after]
        }
        return ids.first { $0 != id }
    }

    /// A background tab is not visible itself. It stays listed while another tab in its group is on screen.
    private func isOpen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.isVisible || window.isMiniaturized { return true }
        guard let group = window.tabGroup else { return false }
        return group.windows.contains { $0 !== window && ($0.isVisible || $0.isMiniaturized) }
    }

    private func ordered(_ current: [Tab]) -> [Tab] {
        // Show All Tabs (Shift-Command-\) asserts if the group is walked mid-transition.
        if NSApp.orderedWindows.contains(where: { $0.tabGroup?.isOverviewVisible == true }) {
            return current.filter { windowAnchors[$0.id]?.window != nil }
        }
        var idByWindow: [ObjectIdentifier: UUID] = [:]
        for (id, anchor) in windowAnchors {
            guard current.contains(where: { $0.id == id }), let window = anchor.window, isOpen(window) else { continue }
            idByWindow[ObjectIdentifier(window)] = id
        }

        var ranked: [UUID] = []
        var seenWindows = Set<ObjectIdentifier>()
        var seenGroups = Set<ObjectIdentifier>()

        for window in NSApp.orderedWindows {
            if let group = window.tabGroup {
                let groupID = ObjectIdentifier(group)
                let members = group.windows.filter { idByWindow[ObjectIdentifier($0)] != nil }
                guard !members.isEmpty, seenGroups.insert(groupID).inserted else { continue }
                for member in members {
                    let memberID = ObjectIdentifier(member)
                    guard seenWindows.insert(memberID).inserted, let id = idByWindow[memberID] else { continue }
                    ranked.append(id)
                }
            } else if let id = idByWindow[ObjectIdentifier(window)],
                      seenWindows.insert(ObjectIdentifier(window)).inserted {
                ranked.append(id)
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return ranked.compactMap { byID[$0] }
    }
}

struct TabComparePage: View {
    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @State private var catalog = OpenTabCatalog.shared

    var body: some View {
        Group {
            if catalog.tabs.count < 2 {
                ContentUnavailableView(
                    "未夠兩個分頁",
                    systemImage: "rectangle.split.2x1",
                    description: Text("開住至少兩個 mmlmRAG 分頁，就可以左右並排比較提問同回答。")
                )
            } else {
                comparison
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            CompareWindowChrome()
        }
        .navigationTitle("比較分頁")
        .onAppear {
            catalog.refreshOrder()
            commitPair()
        }
        .onChange(of: catalog.tabs.map(\.id)) { _, _ in
            commitPair()
        }
    }

    private var comparison: some View {
        HStack(spacing: 0) {
            column(sideTitle: "左邊", selection: leftSelection)
            Divider()
            column(sideTitle: "右邊", selection: rightSelection)
        }
    }

    private func column(sideTitle: String, selection: Binding<UUID>) -> some View {
        let tab = catalog.tabs.first { $0.id == selection.wrappedValue }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(sideTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                Picker(sideTitle, selection: selection) {
                    ForEach(catalog.tabs) { item in
                        Text(catalog.label(for: item.id)).tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .help("次序同視窗上面嘅分頁一樣，由左至右。")
            }

            textBlock(
                title: "提問",
                text: tab?.question ?? "",
                placeholder: "未有提問。",
                isLoading: false,
                itemName: "提問",
                fills: false
            )
            textBlock(
                title: "回答",
                text: tab?.answer ?? "",
                placeholder: "未有回答。",
                isLoading: tab?.isAsking ?? false,
                itemName: "回答",
                fills: true
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sideTitle)
    }

    private func textBlock(
        title: String,
        text: String,
        placeholder: String,
        isLoading: Bool,
        itemName: String,
        fills: Bool
    ) -> some View {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if isLoading && hasText {
                    ProgressView()
                        .controlSize(.small)
                    Text("回覆緊…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                if isLoading && text.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("等緊 rag 回覆…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding(8)
                    .accessibilityElement(children: .combine)
                } else {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.body)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .padding(.trailing, hasText ? 28 : 0)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: fills ? 180 : 140,
                maxHeight: fills ? .infinity : 140
            )
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if hasText {
                    CopyTextButton(text: text, itemName: itemName)
                        .padding(6)
                }
            }
        }
    }

    private var leftSelection: Binding<UUID> {
        Binding(
            get: { shownID(leftID, other: rightID, side: \.left) },
            set: { newValue in
                choose(newValue, as: \.left)
            }
        )
    }

    private var rightSelection: Binding<UUID> {
        Binding(
            get: { shownID(rightID, other: leftID, side: \.right) },
            set: { newValue in
                choose(newValue, as: \.right)
            }
        )
    }

    private func shownID(
        _ current: UUID?,
        other: UUID?,
        side: KeyPath<OpenTabCatalog.SidePair, UUID>
    ) -> UUID {
        if let current, current != other, catalog.tabs.contains(where: { $0.id == current }) {
            return current
        }
        let pair = catalog.resolvedPair(left: side == \.left ? current : other, right: side == \.right ? current : other)
        return pair?[keyPath: side] ?? catalog.tabs.first?.id ?? UUID()
    }

    private func choose(_ newValue: UUID, as side: KeyPath<OpenTabCatalog.SidePair, UUID>) {
        if side == \.left {
            if newValue == rightID {
                rightID = leftID
            }
            leftID = newValue
        } else {
            if newValue == leftID {
                leftID = rightID
            }
            rightID = newValue
        }
        guard let pair = catalog.resolvedPair(left: leftID, right: rightID) else { return }
        leftID = pair.left
        rightID = pair.right
    }

    private func commitPair() {
        guard let pair = catalog.resolvedPair(left: leftID, right: rightID) else { return }
        if leftID != pair.left {
            leftID = pair.left
        }
        if rightID != pair.right {
            rightID = pair.right
        }
    }
}

/// Publishes this window's question and answer while the window exists.
struct OpenTabRegistrar: NSViewRepresentable {
    var tabID: UUID
    var title: String
    var question: String
    var answer: String
    var isAsking: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> OpenTabRegistrarView {
        let view = OpenTabRegistrarView()
        context.coordinator.snapshot = snapshot
        view.onPublish = { [weak coordinator = context.coordinator] window in
            coordinator?.enqueue(window: window)
        }
        view.onClose = { [weak coordinator = context.coordinator] in
            coordinator?.retire()
        }
        return view
    }

    func updateNSView(_ nsView: OpenTabRegistrarView, context: Context) {
        context.coordinator.snapshot = snapshot
        context.coordinator.enqueue(window: nsView.window)
        nsView.rebind()
    }

    static func dismantleNSView(_ nsView: OpenTabRegistrarView, coordinator: Coordinator) {
        nsView.detach()
        coordinator.retire()
    }

    private var snapshot: Coordinator.Snapshot {
        Coordinator.Snapshot(
            id: tabID,
            title: title,
            question: question,
            answer: answer,
            isAsking: isAsking
        )
    }

    final class Coordinator {
        struct Snapshot {
            var id = UUID()
            var title = ""
            var question = ""
            var answer = ""
            var isAsking = false
        }

        var snapshot = Snapshot()
        private var pendingWindow: NSWindow?
        private var queued = false
        private var didClose = false

        /// Waits until the current tab or view update finishes. Publishing here
        /// traps with EXC_BREAKPOINT while AppKit is building the new tab.
        func enqueue(window: NSWindow?) {
            guard !didClose else { return }
            pendingWindow = window
            guard !queued else { return }
            queued = true
            Task { @MainActor in
                queued = false
                publish(window: pendingWindow)
            }
        }

        /// Closing a tab does not dismantle this view, so the row has to leave on willClose.
        func retire() {
            guard !didClose else { return }
            didClose = true
            let id = snapshot.id
            Task { @MainActor in
                OpenTabCatalog.shared.remove(id: id)
            }
        }

        func publish(window: NSWindow?) {
            guard !didClose else { return }
            let snapshot = snapshot
            OpenTabCatalog.shared.upsert(
                id: snapshot.id,
                window: window,
                title: snapshot.title,
                question: snapshot.question,
                answer: snapshot.answer,
                isAsking: snapshot.isAsking
            )
            if window?.isKeyWindow == true {
                OpenTabCatalog.shared.noteFront(id: snapshot.id)
            }
        }
    }
}

final class OpenTabRegistrarView: NSView {
    var onPublish: (NSWindow?) -> Void = { _ in }
    var onClose: () -> Void = {}

    private weak var boundWindow: NSWindow?
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebind()
        onPublish(window)
    }

    func rebind() {
        guard let window else {
            detach()
            return
        }
        if boundWindow !== window {
            clearObservers()
            boundWindow = window
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                let publish = self?.onPublish
                let window = self?.window
                Task { @MainActor in
                    publish?(window)
                }
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                let close = self?.onClose
                Task { @MainActor in
                    close?()
                }
            }
        }
    }

    func detach() {
        clearObservers()
        boundWindow = nil
    }

    private func clearObservers() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

/// Keeps the compare window out of the mmlmRAG tab bar.
private struct CompareWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> CompareWindowChromeView {
        CompareWindowChromeView()
    }

    func updateNSView(_ nsView: CompareWindowChromeView, context: Context) {
        nsView.keepSeparate()
    }
}

private final class CompareWindowChromeView: NSView {
    /// True while a detach is already waiting on the next turn.
    private var isDetaching = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keepSeparate()
    }

    func keepSeparate() {
        guard let window else { return }
        let sharesGroup = window.tabGroup?.windows.contains { $0 !== window } ?? false
        if sharesGroup {
            // Disallowing tabbing while this window is still in the content group
            // makes the next addTabbedWindow raise NSInternalInconsistencyException.
            guard !isDetaching else { return }
            isDetaching = true
            Task { @MainActor [weak self, weak window] in
                self?.isDetaching = false
                guard let window else { return }
                if window.tabGroup?.isOverviewVisible == true {
                    return
                }
                if window.tabGroup?.windows.contains(where: { $0 !== window }) == true {
                    window.tabbingMode = .automatic
                    window.moveTabToNewWindow(nil)
                }
                guard window.tabGroup?.windows.contains(where: { $0 !== window }) != true else { return }
                window.tabbingIdentifier = RagWindowID.compare
                window.tabbingMode = .disallowed
            }
            return
        }
        window.tabbingIdentifier = RagWindowID.compare
        window.tabbingMode = .disallowed
    }
}

#endif
