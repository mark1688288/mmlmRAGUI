import Foundation
import SQLite3
#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI
#endif

#if os(macOS)

/// One saved question and answer. `workingDirectory` is the corpus used when it was saved.
struct QuestionRecord: Identifiable, Equatable, Sendable {
    var id: Int64
    var savedAt: Date
    var question: String
    var answer: String
    var workingDirectory: String
}

/// App-wide question log in Application Support. Every window shares one store.
@MainActor
@Observable
final class QuestionHistoryStore {
    private(set) var records: [QuestionRecord] = []
    private(set) var lastError: String?

    private var database: OpaquePointer?
    private static let savedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Opens the database and loads every saved row. Safe to call more than once.
    func prepare() {
        guard database == nil else { return }
        guard let handle = openDatabase() else { return }
        database = handle
        if let message = createTable(in: handle) {
            lastError = message
            return
        }
        reload()
    }

    /// Inserts a new row. Editing a saved question keeps the older row.
    func save(question: String, answer: String, workingDirectory: String) -> QuestionRecord? {
        prepare()
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            lastError = "未有提問，儲存唔到。"
            return nil
        }
        guard let database else { return nil }

        let savedAt = Date()
        let stamp = Self.savedAtFormatter.string(from: savedAt)
        let sql = """
        INSERT INTO question_records (saved_at, question, answer, working_directory)
        VALUES (?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            lastError = writeFailure(database)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, 1, stamp),
              bindText(statement, 2, question),
              bindText(statement, 3, answer),
              bindText(statement, 4, workingDirectory)
        else {
            lastError = writeFailure(database)
            return nil
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            lastError = writeFailure(database)
            return nil
        }

        let record = QuestionRecord(
            id: sqlite3_last_insert_rowid(database),
            savedAt: savedAt,
            question: question,
            answer: answer,
            workingDirectory: workingDirectory
        )
        records.insert(record, at: 0)
        lastError = nil
        return record
    }

    private func reload() {
        guard let database else { return }
        let sql = """
        SELECT id, saved_at, question, answer, working_directory
        FROM question_records
        ORDER BY saved_at DESC, id DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            lastError = "讀唔到提問記錄：\(Self.errorText(database))"
            return
        }
        defer { sqlite3_finalize(statement) }

        var loaded: [QuestionRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                let stamp = columnText(statement, 1)
                loaded.append(
                    QuestionRecord(
                        id: sqlite3_column_int64(statement, 0),
                        savedAt: Self.savedAtFormatter.date(from: stamp) ?? .distantPast,
                        question: columnText(statement, 2),
                        answer: columnText(statement, 3),
                        workingDirectory: columnText(statement, 4)
                    )
                )
                continue
            }
            if step == SQLITE_DONE {
                records = loaded
                lastError = nil
                return
            }
            lastError = "讀唔到提問記錄：\(Self.errorText(database))"
            return
        }
    }

    private func openDatabase() -> OpaquePointer? {
        let folder: URL
        do {
            folder = try Self.storageFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "開唔到提問記錄：\(error.localizedDescription)"
            return nil
        }

        let path = folder.appendingPathComponent("questions.sqlite").path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { Self.errorText($0) } ?? "unknown"
            sqlite3_close(handle)
            lastError = "開唔到提問記錄：\(message)"
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        return handle
    }

    private func createTable(in database: OpaquePointer) -> String? {
        let sql = """
        CREATE TABLE IF NOT EXISTS question_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            saved_at TEXT NOT NULL,
            question TEXT NOT NULL,
            answer TEXT NOT NULL,
            working_directory TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS question_records_saved_at
        ON question_records (saved_at DESC, id DESC);
        """
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        if result == SQLITE_OK {
            return nil
        }
        let message = error.map { String(cString: $0) } ?? Self.errorText(database)
        sqlite3_free(error)
        return "開唔到提問記錄：\(message)"
    }

    private static func storageFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("mmlmRAGUI", isDirectory: true)
    }

    /// `SQLITE_TRANSIENT` copies the bytes before the C string goes away.
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) -> Bool {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transientDestructor) == SQLITE_OK
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }

    private func writeFailure(_ database: OpaquePointer) -> String {
        "寫唔到提問記錄：\(Self.errorText(database))"
    }

    private static func errorText(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

/// Sidebar list of saved questions. The selected row is the one loaded in this tab.
struct QuestionHistoryList: View {
    let records: [QuestionRecord]
    let problem: String?
    let currentID: Int64?
    let onSelect: (QuestionRecord) -> Void
    let onOpenInNewTab: (QuestionRecord) -> Void

    @State private var hoveredID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if records.isEmpty {
                ContentUnavailableView(
                    "未有提問記錄",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("儲存之後，提問同回答會列喺呢度。")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(records) { record in
                                historyButton(record)
                                    .id(record.id)
                            }
                        }
                    }
                    .onChange(of: currentID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyButton(_ record: QuestionRecord) -> some View {
        Button {
            onSelect(record)
        } label: {
            historyLabel(record)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("開啟於新分頁") {
                onOpenInNewTab(record)
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredID = record.id
            } else if hoveredID == record.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel(accessibilityLabel(for: record))
        .accessibilityHint("載入呢條提問同回答")
    }

    private func historyLabel(_ record: QuestionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.savedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.question)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.answer.isEmpty ? "未有回答" : record.answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rowFill(for: record))
        }
        .help(helpText(for: record))
    }

    private func rowFill(for record: QuestionRecord) -> Color {
        if record.id == currentID {
            return Color.accentColor.opacity(0.18)
        }
        if record.id == hoveredID {
            return Color.primary.opacity(0.08)
        }
        return Color.primary.opacity(0.04)
    }

    private func accessibilityLabel(for record: QuestionRecord) -> String {
        let stamp = record.savedAt.formatted(.dateTime.year().month().day().hour().minute().second())
        return "\(stamp)，\(record.question)"
    }

    private func helpText(for record: QuestionRecord) -> String {
        if record.workingDirectory.isEmpty {
            return "載入呢條提問記錄"
        }
        return record.workingDirectory
    }
}

/// Pins a saved question to the window opened by 開啟於新分頁.
enum HistoryTabLaunch {
    static let didMark = Notification.Name("mmlmRAGUI.historyTabDidMark")

    static func mark(_ window: NSWindow, recordID: Int64) {
        objc_setAssociatedObject(
            window,
            &historyTabRecordKey,
            NSNumber(value: recordID),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        NotificationCenter.default.post(name: didMark, object: window)
    }

    /// Drops the text cursor. Tabbing a window while it is attached leaves
    /// CursorUIViewService spinning on a task port that no longer exists.
    static func releaseTextCursor(on window: NSWindow?) {
        if let context = NSTextInputContext.current {
            context.discardMarkedText()
            context.deactivate()
        }
        window?.makeFirstResponder(nil)
        NSCursor.arrow.set()
    }

    static func peek(_ window: NSWindow) -> Int64? {
        (objc_getAssociatedObject(window, &historyTabRecordKey) as? NSNumber)?.int64Value
    }

    static func take(_ window: NSWindow) -> Int64? {
        let recordID = peek(window)
        if recordID != nil {
            objc_setAssociatedObject(window, &historyTabRecordKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return recordID
    }
}

private var historyTabRecordKey: UInt8 = 0

/// Loads the question pinned to this window once the new tab exists.
struct HistoryTabLoader: NSViewRepresentable {
    var records: [QuestionRecord]
    var onLoad: (QuestionRecord) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HistoryTabHookView {
        let view = HistoryTabHookView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.records = records
        context.coordinator.onLoad = onLoad
        view.onCheck = { [weak coordinator = context.coordinator] window in
            coordinator?.claim(window)
        }
        return view
    }

    func updateNSView(_ nsView: HistoryTabHookView, context: Context) {
        context.coordinator.records = records
        context.coordinator.onLoad = onLoad
        context.coordinator.claim(nsView.window)
    }

    static func dismantleNSView(_ nsView: HistoryTabHookView, coordinator: Coordinator) {
        nsView.detach()
    }

    final class Coordinator {
        var records: [QuestionRecord] = []
        var onLoad: (QuestionRecord) -> Void = { _ in }
        private var didLoad = false

        func claim(_ window: NSWindow?) {
            guard !didLoad, let window, let recordID = HistoryTabLaunch.peek(window) else { return }
            guard let record = records.first(where: { $0.id == recordID }) else { return }
            didLoad = true
            _ = HistoryTabLaunch.take(window)
            let load = onLoad
            // Avoid publishing state from inside a SwiftUI update.
            // Fill the field first, then drop the cursor on the next turn so
            // SwiftUI cannot focus it during that same update.
            DispatchQueue.main.async {
                load(record)
                DispatchQueue.main.async {
                    HistoryTabLaunch.releaseTextCursor(on: window)
                }
            }
        }
    }
}

final class HistoryTabHookView: NSView {
    var onCheck: (NSWindow?) -> Void = { _ in }
    private var observer: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else {
            onCheck(nil)
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: HistoryTabLaunch.didMark,
            object: window,
            queue: .main
        ) { [weak self] _ in
            let check = self?.onCheck
            let window = self?.window
            Task { @MainActor in
                check?(window)
            }
        }
        onCheck(window)
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

/// Asks before an mmlmRAG tab closes when this question has not been saved.
///
/// The tab close button calls `close()` and does not call `performClose`.
/// SwiftUI also removes this view before that call returns, so the dirty bit is
/// copied onto the window and kept there. Detaching here used to let the tab
/// close with no prompt.
struct QuestionCloseMonitor: NSViewRepresentable {
    var isDirty: Bool
    var isAsking: Bool
    var question: String
    var answer: String
    var workingDirectory: String
    var history: QuestionHistoryStore
    var save: () -> Bool

    func makeCoordinator() -> QuestionCloseGate {
        QuestionCloseGate()
    }

    func makeNSView(context: Context) -> QuestionCloseHookView {
        let view = QuestionCloseHookView(frame: .zero)
        view.setAccessibilityElement(false)
        bind(context.coordinator)
        view.onWindow = { [weak coordinator = context.coordinator] window in
            guard let coordinator, let window else { return }
            QuestionCloseInstaller.shared.attach(coordinator, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: QuestionCloseHookView, context: Context) {
        bind(context.coordinator)
        if let window = nsView.window {
            QuestionCloseInstaller.shared.attach(context.coordinator, to: window)
        }
    }

    static func dismantleNSView(_ nsView: QuestionCloseHookView, coordinator: QuestionCloseGate) {
        coordinator.viewAttached = false
    }

    private func bind(_ gate: QuestionCloseGate) {
        gate.viewAttached = true
        gate.note(
            dirty: isDirty,
            asking: isAsking,
            question: question,
            answer: answer,
            workingDirectory: workingDirectory,
            history: history,
            save: save
        )
    }
}

@MainActor
final class QuestionCloseGate: NSObject {
    weak var window: NSWindow?
    fileprivate var viewAttached = true
    fileprivate var isClosing = false

    private var dirty = false
    private var asking = false
    private var question = ""
    private var answer = ""
    private var workingDirectory = ""
    private var history: QuestionHistoryStore?
    private var save: () -> Bool = { false }
    private var isPrompting = false

    func note(
        dirty: Bool,
        asking: Bool,
        question: String,
        answer: String,
        workingDirectory: String,
        history: QuestionHistoryStore,
        save: @escaping () -> Bool
    ) {
        self.dirty = dirty
        self.asking = asking
        self.question = question
        self.answer = answer
        self.workingDirectory = workingDirectory
        self.history = history
        self.save = save
    }

    func allowClose() -> Bool {
        if isPrompting || isClosing { return false }
        guard dirty else { return true }
        isPrompting = true
        defer { isPrompting = false }

        let alert = NSAlert()
        alert.messageText = "未儲存提問記錄"
        alert.informativeText = asking
            ? "回覆未完。是否不儲存提問記錄便離開？"
            : "是否不儲存提問記錄便離開？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "不儲存")
        alert.addButton(withTitle: "取消")
        if alert.buttons.indices.contains(1) {
            alert.buttons[1].keyEquivalent = "d"
            alert.buttons[1].keyEquivalentModifierMask = .command
        }
        if alert.buttons.indices.contains(2) {
            alert.buttons[2].keyEquivalent = "\u{1b}"
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return performSave()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// The view's save updates the tab. After SwiftUI has removed the view, write the copy kept on the gate.
    private func performSave() -> Bool {
        if viewAttached {
            return save()
        }
        return history?.save(
            question: question,
            answer: answer,
            workingDirectory: workingDirectory
        ) != nil
    }
}

final class QuestionCloseHookView: NSView {
    var onWindow: (NSWindow?) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}

enum QuestionCloseTermination {
    /// Quit sends `close()` to every window. Asking there leaves the window open and stalls termination.
    @MainActor static func begin() {
        QuestionCloseInstaller.shared.isTerminating = true
    }
}

/// Hooks `close` and `performClose` on each window class. Windows without a gate close as usual.
@MainActor
private final class QuestionCloseInstaller: NSObject {
    static let shared = QuestionCloseInstaller()

    fileprivate var isTerminating = false

    private struct Hook: Hashable {
        let classID: ObjectIdentifier
        let selector: Selector
    }

    private var swizzled = Set<Hook>()
    /// Implementations this installer installed, so a subclass does not wrap them again.
    private var installedIMPs = Set<UnsafeRawPointer>()

    func attach(_ gate: QuestionCloseGate, to window: NSWindow) {
        if let previous = gate.window, previous !== window {
            detach(gate, from: previous)
        }
        gate.window = window
        objc_setAssociatedObject(window, &questionCloseGateKey, gate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let cls = object_getClass(window) else { return }
        swizzleClose(cls)
        swizzlePerformClose(cls)
    }

    private func detach(_ gate: QuestionCloseGate, from window: NSWindow) {
        let current = objc_getAssociatedObject(window, &questionCloseGateKey) as? QuestionCloseGate
        if current === gate {
            objc_setAssociatedObject(window, &questionCloseGateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if gate.window === window {
            gate.window = nil
        }
    }

    private func swizzleClose(_ cls: AnyClass) {
        let selector = #selector(NSWindow.close)
        guard let current = implementation(toWrap: cls, selector: selector) else { return }
        typealias CloseIMP = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(current, to: CloseIMP.self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            MainActor.assumeIsolated {
                QuestionCloseInstaller.shared.finishClose(object) {
                    original($0, selector)
                }
            }
        }
        guard let method = class_getInstanceMethod(NSWindow.self, selector),
              let encoding = method_getTypeEncoding(method) else { return }
        let imp = imp_implementationWithBlock(block)
        installedIMPs.insert(UnsafeRawPointer(imp))
        _ = class_replaceMethod(cls, selector, imp, encoding)
        swizzled.insert(Hook(classID: ObjectIdentifier(cls), selector: selector))
    }

    private func swizzlePerformClose(_ cls: AnyClass) {
        let selector = #selector(NSWindow.performClose(_:))
        guard let current = implementation(toWrap: cls, selector: selector) else { return }
        typealias PerformCloseIMP = @convention(c) (AnyObject, Selector, Any?) -> Void
        let original = unsafeBitCast(current, to: PerformCloseIMP.self)
        let block: @convention(block) (AnyObject, Any?) -> Void = { object, sender in
            MainActor.assumeIsolated {
                QuestionCloseInstaller.shared.finishClose(object) {
                    original($0, selector, sender)
                }
            }
        }
        guard let method = class_getInstanceMethod(NSWindow.self, selector),
              let encoding = method_getTypeEncoding(method) else { return }
        let imp = imp_implementationWithBlock(block)
        installedIMPs.insert(UnsafeRawPointer(imp))
        _ = class_replaceMethod(cls, selector, imp, encoding)
        swizzled.insert(Hook(classID: ObjectIdentifier(cls), selector: selector))
    }

    /// Nil when this class already has the hook, or its current implementation is one we installed.
    private func implementation(toWrap cls: AnyClass, selector: Selector) -> IMP? {
        let hook = Hook(classID: ObjectIdentifier(cls), selector: selector)
        guard !swizzled.contains(hook) else { return nil }
        guard class_getInstanceMethod(NSWindow.self, selector) != nil,
              let current = class_getMethodImplementation(cls, selector) else { return nil }
        let currentPointer = unsafeBitCast(current, to: UnsafeRawPointer.self)
        if installedIMPs.contains(currentPointer) {
            swizzled.insert(hook)
            return nil
        }
        return current
    }

    private func finishClose(
        _ object: AnyObject,
        call: (AnyObject) -> Void
    ) {
        guard let window = object as? NSWindow else { return }
        if isTerminating {
            call(object)
            return
        }
        guard let gate = objc_getAssociatedObject(window, &questionCloseGateKey) as? QuestionCloseGate else {
            call(object)
            return
        }
        if gate.isClosing {
            call(object)
            return
        }
        guard gate.allowClose() else { return }
        gate.isClosing = true
        call(object)
        gate.isClosing = false
    }
}

private var questionCloseGateKey: UInt8 = 0

#endif
