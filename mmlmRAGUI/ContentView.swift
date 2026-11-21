import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import ObjectiveC
#endif

struct ContentView: View {
    #if os(macOS)
    @State private var session: RagSession
    @State private var isTargeted = false
    @State private var showImporter = false
    @State private var sidebarTab = SidebarTab.ingest
    /// Wide windows show both columns. Narrow windows show the sidebar, or only the main page when this is detailOnly.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// Width of the 文件 sidebar. Every mmlmRAG tab reads and writes this same value.
    @AppStorage(DocumentsSidebarWidthPolicy.defaultsKey) private var documentsSidebarWidth = DocumentsSidebarWidthPolicy.fallback
    @State private var documentPreview = DocumentPreviewModel()
    /// Stable identity for this window's preview cache. A new tab gets a new one.
    @State private var tabID = UUID()
    @State private var history: QuestionHistoryStore
    /// Row this tab last saved or loaded. A later save appends a new row.
    @State private var linkedRecordID: Int64?
    @State private var savedQuestion = ""
    @State private var savedAnswer = ""
    /// A row opened from 歷史. The question stays as saved, and 提問 does not run again.
    @State private var loadedFromHistory = false
    /// This tab's log text area. Collapsing it hides the text and leaves the answer the room. The log still records.
    @State private var isLogExpanded = true
    /// Below the one-column width the two trailing icons share one glass circle, which does not draw them.
    @State private var compactTrailingMenu = false

    /// Portrait width of the iPhone 18 Pro, in points (1206 px at 3x).
    static let iPhone18ProScreenWidth: CGFloat = 402
    /// Narrowest main window, in points. Stays under the one-column cutoff.
    static let minimumWindowWidth: CGFloat = 380
    @FocusState private var isQuestionFocused: Bool
    @Environment(\.appearsActive) private var windowIsActive
    @Environment(\.openWindow) private var openWindow

    init(settings: RagSettings, history: QuestionHistoryStore) {
        _session = State(initialValue: RagSession(settings: settings))
        _history = State(initialValue: history)
    }
    #endif

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        ContentUnavailableView(
            "mmlmRAG",
            systemImage: "macwindow",
            description: Text(ui("This prototype only runs the local rag command on macOS."))
        )
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width <= Self.iPhone18ProScreenWidth
            Group {
                if isCompact {
                    compactContent
                } else {
                    splitContent(availableWidth: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear {
                compactTrailingMenu = isCompact
            }
            .onChange(of: isCompact) { _, compact in
                compactTrailingMenu = compact
            }
            .background {
                SidebarToggleBridge(isExpanded: sidebarIsExpanded, toggle: toggleSidebar)
            }
            .background {
                NewTabButtonKeeper()
            }
        }
        .frame(minWidth: Self.minimumWindowWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MainWindowMinimumWidth()
        }
        .navigationTitle(windowTitle)
        .task {
            history.prepare()
            await session.prepare()
        }
        .onChange(of: isRecordDirty) { _, dirty in
            if dirty, uiSame(session.notice, "Saved this question.") {
                session.notice = nil
            }
        }
        .onChange(of: history.records) { old, new in
            let removed = Set(old.map(\.id)).subtracting(new.map(\.id))
            guard !removed.isEmpty else { return }
            releaseDeletedLink(removed)
        }
        .onChange(of: session.isAsking) { _, asking in
            guard asking else { return }
            PreviewShelf.shared.update(
                id: tabID,
                model: documentPreview,
                answer: session.answerText,
                workingDirectory: session.workingDirectory,
                isAsking: true
            )
            PreviewShelf.shared.noteAsking(id: tabID)
        }
        .onChange(of: windowIsActive) { _, isActive in
            guard isActive else { return }
            PreviewShelf.shared.update(
                id: tabID,
                model: documentPreview,
                answer: session.answerText,
                workingDirectory: session.workingDirectory,
                isAsking: session.isAsking
            )
            PreviewShelf.shared.activate(id: tabID)
        }
        .background {
            PreviewTabMonitor(
                tabID: tabID,
                model: documentPreview,
                answer: session.answerText,
                workingDirectory: session.workingDirectory,
                isAsking: session.isAsking
            )
        }
        .background {
            QuestionCloseMonitor(
                isDirty: isRecordDirty,
                isAsking: session.isAsking,
                question: session.question,
                answer: session.answerText,
                workingDirectory: session.workingDirectory,
                history: history,
                save: { saveRecord() }
            )
        }
        .background {
            HistoryTabLoader(records: history.records, onLoad: apply)
        }
        .background {
            OpenTabRegistrar(
                tabID: tabID,
                title: windowTitle,
                question: session.question,
                answer: session.answerText,
                isAsking: session.isAsking
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: RagSession.importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                session.enqueueIngest(urls)
            case .failure(let error):
                session.errorMessage = error.localizedDescription
            }
        }
        .alert(
            ui("Couldn't do that"),
            isPresented: errorPresented
        ) {
            Button(ui("OK")) {
                session.errorMessage = nil
            }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .toolbar {
            if compactTrailingMenu {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        compareMenuButton
                        settingsToolbarLink
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .help(ui("Compare") + ", " + ui("Settings"))
                    .accessibilityLabel(ui("Compare") + ", " + ui("Settings"))
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    compareToolbarButton
                    settingsToolbarLink
                }
            }
        }
    }

    private var compareToolbarButton: some View {
        Button {
            openWindow(id: RagWindowID.compare)
        } label: {
            Label(ui("Compare"), systemImage: "rectangle.split.2x1")
        }
        .help(ui("Compare two tabs' questions and answers side by side"))
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }

    /// The shared toolbar button is icon-only, so a menu built from it drops the symbol.
    private var compareMenuButton: some View {
        Button(ui("Compare"), systemImage: "rectangle.split.2x1") {
            openWindow(id: RagWindowID.compare)
        }
        .labelStyle(.titleAndIcon)
        .help(ui("Compare two tabs' questions and answers side by side"))
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }

    private var settingsToolbarLink: some View {
        SettingsLink {
            Label(ui("Settings"), systemImage: "gearshape")
        }
        .help(ui("Settings"))
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )
    }

    /// Window and tab title. Empty questions stay "mmlmRAG". A question shows its first 8 characters plus "...".
    private var windowTitle: String {
        let question = session.question
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "mmlmRAG" }
        return String(question.prefix(8)) + "..."
    }

    /// Cited pages in the answer. Zero stays "Documents".
    private var documentsTabTitle: String {
        let count = CitationPages.orderedPages(in: session.answerText).count
        return count == 0 ? ui("Documents") : ui("Documents ({count})", ["count": String(count)])
    }

    private var sidebarIsExpanded: Bool {
        columnVisibility != .detailOnly
    }

    /// Narrow windows show one column. The sidebar button switches which one.
    private var compactContent: some View {
        Group {
            if sidebarIsExpanded {
                sidebar
            } else {
                detail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help(sidebarIsExpanded ? ui("Hide Sidebar") : ui("Show Sidebar"))
                .accessibilityLabel(sidebarIsExpanded ? ui("Hide Sidebar") : ui("Show Sidebar"))
            }
        }
    }

    private func splitContent(availableWidth: CGFloat) -> some View {
        let width = sidebarColumnWidth(fitting: availableWidth)
        let columnVisible = columnVisibility != .detailOnly
        let sharedWidth = columnVisible
            ? DocumentsSidebarWidthPolicy.enforced(
                stored: documentsSidebarWidth,
                columnMin: width.min,
                columnMax: width.max,
                availableWidth: availableWidth
            )
            : nil
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: width.min,
                    ideal: width.ideal,
                    max: width.max
                )
                .background {
                    DocumentsSidebarWidthSync(
                        enforcedWidth: sharedWidth,
                        remembersDrag: columnVisible,
                        sidebarTab: sidebarTab,
                        availableWidth: availableWidth
                    ) { measured in
                        guard abs(documentsSidebarWidth - measured) >= 1 else { return }
                        documentsSidebarWidth = measured
                    }
                }
        } detail: {
            detail
        }
    }

    private var sidebarExpandedBinding: Binding<Bool> {
        Binding(
            get: { sidebarIsExpanded },
            set: { isExpanded in
                columnVisibility = isExpanded ? .all : .detailOnly
            }
        )
    }

    private func toggleSidebar() {
        sidebarExpandedBinding.wrappedValue.toggle()
    }

    /// Preferred sidebar widths. The minimum shrinks only when the window is too narrow for both columns.
    /// 入庫, 文件, and 歷史 share one saved width.
    private func sidebarColumnWidth(fitting availableWidth: CGFloat) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let preferredMin = DocumentsSidebarWidthPolicy.preferredMin
        let preferredIdeal = DocumentsSidebarWidthPolicy.preferredIdeal(stored: documentsSidebarWidth)
        let preferredMax = DocumentsSidebarWidthPolicy.preferredMax
        let mainPageReserve = DocumentsSidebarWidthPolicy.mainPageReserve
        let minWidth = min(preferredMin, max(DocumentsSidebarWidthPolicy.collapsedFloor, availableWidth - mainPageReserve))
        let idealWidth = min(max(preferredIdeal, minWidth), preferredMax)
        return (minWidth, idealWidth, preferredMax)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(ui("Sidebar"), selection: $sidebarTab) {
                Text(ui("Ingest")).tag(SidebarTab.ingest)
                Text(documentsTabTitle).tag(SidebarTab.documents)
                Text(ui("History")).tag(SidebarTab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(ui("Sidebar"))

            switch sidebarTab {
            case .ingest:
                dropZone
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .documents:
                DocumentPreview(
                    answer: session.answerText,
                    workingDirectory: session.workingDirectory,
                    model: documentPreview
                )
            case .history:
                QuestionHistoryList(
                    records: history.records,
                    problem: history.lastError,
                    currentID: isRecordDirty ? nil : linkedRecordID,
                    onSelect: loadRecord,
                    onOpenInNewTab: openInNewTab,
                    onDelete: deleteHistoryRecords
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            questionRow
            outputPane(
                title: ui("Answer"),
                text: session.answerText,
                placeholder: ui("The answer shows up here."),
                isLoading: session.isAsking,
                canCopy: true
            )
            outputPane(
                title: ui("Log"),
                text: session.logText,
                placeholder: ui("Ingest and question logs show up here."),
                monospaced: true,
                isExpanded: $isLogExpanded
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if session.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(session.busyLabel)
                    .font(.headline)
                if session.queuedCount > 0 {
                    Text(ui("{count} more queued", ["count": String(session.queuedCount)]))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ui("Cancel"), role: .cancel) {
                    session.cancel()
                }
            } else {
                Text(ui("Local corpus"))
                    .font(.headline)
                Spacer()
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
            Text(isTargeted ? ui("Drop to ingest") : ui("Drop a file here, or choose one"))
            Text(ui("pdf, docx, pptx, text, and images. Each file is handed to rag ingest one at a time."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(ui("Choose Files…")) {
                showImporter = true
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            session.enqueueIngest(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var questionRow: some View {
        @Bindable var session = session
        return HStack(alignment: .bottom, spacing: 8) {
            if loadedFromHistory {
                historyQuestion(session.question)
            } else {
                TextField(ui("Ask the corpus a question"), text: $session.question, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($isQuestionFocused)
                    .help(ui("Ask the corpus a question"))
            }
            Button(ui("Ask")) {
                guard canAsk else { return }
                session.ask()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAsk)
            .help(askHelp)
            Button(saveTitle) {
                _ = saveRecord()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave)
            .help(saveHelp)
        }
        .background {
            // A vertical-axis field treats Return as a newline, so onSubmit never fires.
            QuestionReturnMonitor(
                isFocused: isQuestionFocused && !loadedFromHistory,
                consumesReturn: {
                    canAsk
                },
                submit: {
                    guard canAsk else { return }
                    session.ask()
                }
            )
        }
    }

    private func outputPane(
        title: String,
        text: String,
        placeholder: String,
        monospaced: Bool = false,
        isLoading: Bool = false,
        canCopy: Bool = false,
        isExpanded: Binding<Bool>? = nil
    ) -> some View {
        let showsBody = isExpanded?.wrappedValue ?? true
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if isLoading && !text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text(ui("Answering…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isExpanded != nil {
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded?.wrappedValue.toggle()
                        }
                    } label: {
                        Label(
                            showsBody ? ui("Collapse Log") : ui("Expand Log"),
                            systemImage: showsBody ? "chevron.down" : "chevron.right"
                        )
                    }
                    .controlSize(.small)
                    .help(showsBody ? ui("Collapse Log") : ui("Expand Log"))
                }
            }
            if showsBody {
                ScrollView {
                    if isLoading && text.isEmpty {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(ui("Waiting for rag…"))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(8)
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(text.isEmpty ? placeholder : text)
                            .font(monospaced ? .system(.body, design: .monospaced) : .body)
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .padding(.trailing, canCopy && !text.isEmpty ? 28 : 0)
                    }
                }
                .frame(minHeight: monospaced ? 90 : 140, maxHeight: .infinity)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if canCopy, !text.isEmpty {
                        CopyTextButton(text: text)
                            .padding(6)
                    }
                }
            }
        }
    }

    /// A typed question or an answer that does not match the last save.
    private var isRecordDirty: Bool {
        let question = session.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = session.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty && answer.isEmpty {
            return false
        }
        return question != savedQuestion || answer != savedAnswer
    }

    /// 提問 is for a question typed in this tab. A record opened from 歷史 stays as it was saved.
    private var canAsk: Bool {
        !loadedFromHistory
            && !session.isBusy
            && !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saved question text. Selectable, with the same one-click copy button as the answer.
    private func historyQuestion(_ question: String) -> some View {
        let canCopy = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ScrollView {
            Text(question)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(6)
                .padding(.trailing, canCopy ? 28 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 108)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if canCopy {
                CopyTextButton(text: question, itemName: "Question")
                    .padding(6)
            }
        }
    }

    private var askHelp: String {
        if loadedFromHistory {
            return ui("This question was opened from history and can't be asked again")
        }
        return ui("Ask")
    }

    private var canSave: Bool {
        isRecordDirty
            && !session.isAsking
            && !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveTitle: String {
        if linkedRecordID != nil && !isRecordDirty {
            return ui("Saved")
        }
        return ui("Save")
    }

    private var saveHelp: String {
        if canSave {
            return ui("Save this question and answer")
        }
        if linkedRecordID != nil && !isRecordDirty {
            return ui("This question is saved")
        }
        if !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ui("Save this question after it has an answer")
        }
        return ui("Nothing to save")
    }

    private func deleteHistoryRecords(_ ids: Set<Int64>) {
        guard history.delete(ids: ids) else {
            session.errorMessage = history.lastError ?? ui("Couldn't delete the question.")
            return
        }
        releaseDeletedLink(ids)
        session.notice = ids.count == 1
            ? ui("Deleted 1 question.")
            : ui("Deleted {count} questions.", ["count": String(ids.count)])
    }

    /// Drops the link when another window deleted the row this tab is showing.
    /// A clean copy of that row leaves the page. Edits stay, so they can be saved again.
    private func releaseDeletedLink(_ ids: Set<Int64>) {
        guard let linkedRecordID, ids.contains(linkedRecordID) else { return }
        let showingSavedCopy = !isRecordDirty
        self.linkedRecordID = nil
        savedQuestion = ""
        savedAnswer = ""
        guard showingSavedCopy else { return }
        session.question = ""
        session.answerText = ""
        session.logText = ""
        loadedFromHistory = false
        if uiSame(session.notice, "Saved this question.") {
            session.notice = nil
        }
    }

    @discardableResult
    private func saveRecord() -> Bool {
        guard !session.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.errorMessage = ui("Save this question after it has an answer")
            return false
        }
        guard let record = history.save(
            question: session.question,
            answer: session.answerText,
            workingDirectory: session.workingDirectory
        ) else {
            session.errorMessage = history.lastError ?? ui("Couldn't save the question.")
            return false
        }
        linkedRecordID = record.id
        savedQuestion = record.question
        savedAnswer = record.answer
        session.logText = ""
        session.notice = ui("Saved this question.")
        loadedFromHistory = true
        isQuestionFocused = false
        return true
    }

    /// Opens a new mmlmRAG tab beside this one and loads `record` there.
    private func openInNewTab(_ record: QuestionRecord) {
        let source = OpenTabCatalog.shared.window(for: tabID) ?? NSApp.keyWindow
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let selector = #selector(NSResponder.newWindowForTab(_:))
        if !NSApp.sendAction(selector, to: nil, from: nil) {
            openWindow(id: RagWindowID.main)
        }
        if let window = newContentWindow(excluding: existing) {
            finishOpening(window, beside: source, recordID: record.id)
            return
        }
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(30))
                if let window = newContentWindow(excluding: existing) {
                    finishOpening(window, beside: source, recordID: record.id)
                    return
                }
            }
            session.notice = ui("Couldn't open a new tab.")
        }
    }

    private func newContentWindow(excluding existing: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.first { window in
            !existing.contains(ObjectIdentifier(window))
                && !(window is NSPanel)
                && window.canBecomeKey
                && window.tabbingIdentifier != RagWindowID.compare
                && window.tabbingMode != .disallowed
        }
    }

    private func finishOpening(_ window: NSWindow, beside source: NSWindow?, recordID: Int64) {
        // newWindowForTab focuses the empty question field immediately.
        // Joining the tab bar after that strands the text cursor.
        HistoryTabLaunch.releaseTextCursor(on: window)
        window.makeKeyAndOrderFront(nil)
        HistoryTabLaunch.mark(window, recordID: recordID)
        // newWindowForTab is still inside AppKit here. Tabbing on this turn
        // raises EXC_BREAKPOINT. Join on the next turn if it is not already a tab.
        Task { @MainActor in
            if let source, window !== source {
                joinTab(window, beside: source)
            }
            HistoryTabLaunch.releaseTextCursor(on: window)
            OpenTabCatalog.shared.refreshOrder()
        }
    }

    /// Puts `window` into `source`'s tab group.
    /// addTabbedWindow raises when the new window is already in another group,
    /// or when that group still contains a window with tabbing disallowed.
    private func joinTab(_ window: NSWindow, beside source: NSWindow) {
        if source.tabGroup?.isOverviewVisible == true || window.tabGroup?.isOverviewVisible == true {
            return
        }
        ejectDisallowedTabs(from: source)
        if source.tabGroup != nil && source.tabGroup === window.tabGroup {
            return
        }
        if window.tabGroup?.windows.contains(where: { $0 !== window }) == true {
            window.moveTabToNewWindow(nil)
        }
        window.tabbingIdentifier = source.tabbingIdentifier
        window.tabbingMode = .preferred
        if source.tabbingMode == .disallowed {
            source.tabbingMode = .automatic
        }
        source.addTabbedWindow(window, ordered: .above)
    }

    private func ejectDisallowedTabs(from source: NSWindow) {
        let stuck = source.tabGroup?.windows.filter { member in
            member !== source && member.tabbingMode == .disallowed
        } ?? []
        for member in stuck {
            member.tabbingMode = .automatic
            member.moveTabToNewWindow(nil)
            member.tabbingIdentifier = RagWindowID.compare
            member.tabbingMode = .disallowed
        }
    }

    private func loadRecord(_ record: QuestionRecord) {
        guard !session.isBusy else {
            session.notice = ui("Wait for the current job to finish before loading.")
            return
        }
        if linkedRecordID == record.id && !isRecordDirty {
            return
        }
        if isRecordDirty && !confirmReplaceRecord() {
            return
        }
        apply(record)
    }

    /// Same choices as closing the tab: save, discard, or stay.
    private func confirmReplaceRecord() -> Bool {
        let alert = NSAlert()
        alert.messageText = ui("Unsaved question")
        alert.informativeText = ui("Load another question without saving this one?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: ui("Save"))
        alert.addButton(withTitle: ui("Don't Save"))
        alert.addButton(withTitle: ui("Cancel"))
        if alert.buttons.indices.contains(1) {
            alert.buttons[1].keyEquivalent = "d"
            alert.buttons[1].keyEquivalentModifierMask = .command
        }
        if alert.buttons.indices.contains(2) {
            alert.buttons[2].keyEquivalent = "\u{1b}"
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveRecord()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func apply(_ record: QuestionRecord) {
        session.question = record.question
        session.answerText = record.answer
        session.logText = ""
        session.notice = nil
        linkedRecordID = record.id
        savedQuestion = record.question
        savedAnswer = record.answer
        loadedFromHistory = true
        isLogExpanded = false
        // Leave the field unfocused. Focusing it while the new tab settles
        // keeps the text cursor on its loading icon.
        isQuestionFocused = false
    }
    #endif
}

#if os(macOS)
/// Settings window. Same fields the sidebar tab used to show.
struct SettingsPage: View {
    @Bindable var settings: RagSettings
    @State private var session: RagSession

    init(settings: RagSettings) {
        self.settings = settings
        _session = State(initialValue: RagSession(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ui("rag path"))
                    .font(.headline)
                TextField("/opt/homebrew/bin/rag", text: $settings.ragPath)
                    .textFieldStyle(.roundedBorder)
                Text(ui("Executable. A folder that contains rag.toml is used as the working directory instead."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(ui("Use This Path")) {
                    Task { await session.usePathAndRefresh() }
                }
                .disabled(session.isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(ui("Working Directory"))
                    .font(.headline)
                TextField("~", text: $settings.workingDirectory)
                    .textFieldStyle(.roundedBorder)
                Text(ui("A parent folder with rag.toml is used. Otherwise ~/.mmlmrag/rag.toml."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(ui("Status"))
                        .font(.headline)
                    Spacer()
                    Button(ui("Check Again")) {
                        Task { await session.refreshStatus() }
                    }
                    .disabled(session.isBusy)
                }
                ScrollView {
                    Text(statusDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(
            minWidth: 380,
            idealWidth: 440,
            maxWidth: 640,
            minHeight: 480,
            idealHeight: 560,
            maxHeight: 800
        )
    }

    /// The untouched status line follows the interface language. Command output stays as rag printed it.
    private var statusDisplay: String {
        let text = settings.statusText
        if text.isEmpty { return " " }
        if text == "Not checked yet." || text == UICopy.chinese["Not checked yet."] {
            return ui("Not checked yet.")
        }
        return text
    }
}

/// Settings window. System keeps the rag path. Display chooses the interface language.
struct SettingsTabs: View {
    @Bindable var settings: RagSettings

    var body: some View {
        TabView {
            Tab(ui("System"), systemImage: "gear") {
                SettingsPage(settings: settings)
            }
            Tab(ui("Display"), systemImage: "textformat") {
                DisplaySettingsPage()
            }
        }
        .frame(minWidth: 380, minHeight: 560)
    }
}

/// One option: the language used for interface text.
struct DisplaySettingsPage: View {
    @Bindable private var interfaceLanguage = InterfaceLanguage.shared

    var body: some View {
        Form {
            Picker(ui("Interface Language"), selection: $interfaceLanguage.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Copies a text block in one click. The icon swaps to a checkmark, same as a code snippet.
struct CopyTextButton: View {
    let text: String
    var itemName = "Answer"

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    private var canCopy: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button(action: copy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!canCopy)
        .foregroundStyle(didCopy ? Color.green : Color.secondary)
        .help(didCopy ? ui("Copied") : ui("Copy {item}", ["item": ui(itemName)]))
        .accessibilityLabel(didCopy ? ui("Copied") : ui("Copy {item}", ["item": ui(itemName)]))
        .onChange(of: text) {
            resetTask?.cancel()
            didCopy = false
        }
        .onDisappear {
            resetTask?.cancel()
        }
    }

    private func copy() {
        guard canCopy else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        resetTask?.cancel()
        withAnimation {
            didCopy = true
        }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation {
                didCopy = false
            }
        }
    }
}

/// While the question field is focused, plain Return activates 提問.
/// Shift-Return still inserts a newline. Marked text (an IME composition) is left alone.
private struct QuestionReturnMonitor: NSViewRepresentable {
    var isFocused: Bool
    /// True when plain Return should press 提問 instead of inserting a newline.
    var consumesReturn: () -> Bool
    var submit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isFocused = isFocused
        context.coordinator.consumesReturn = consumesReturn
        context.coordinator.submit = submit
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: @unchecked Sendable {
        var isFocused = false
        var consumesReturn: () -> Bool = { false }
        var submit: () -> Void = {}
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isFocused, Self.isPlainReturn(event) else { return event }
            guard let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient else { return event }
            if client.hasMarkedText() { return event }
            guard consumesReturn() else { return event }
            // A held key repeats; only the first press should ask.
            if !event.isARepeat {
                submit()
            }
            return nil
        }

        private static func isPlainReturn(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            guard flags.isEmpty else { return false }
            return event.charactersIgnoringModifiers == "\r"
        }
    }
}

/// Keeps the View menu's toggleSidebar: on the same expand and collapse state as the toolbar button.
/// The split view consumes that command while it is on screen. The window's own method does not
/// switch the narrow layout, so the narrow layout handles the command itself.
private struct SidebarToggleBridge: NSViewRepresentable {
    var isExpanded: Bool
    var toggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.isExpanded = isExpanded
        context.coordinator.toggle = toggle
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.windowChanged(window)
        }
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        context.coordinator.isExpanded = isExpanded
        context.coordinator.toggle = toggle
        context.coordinator.windowChanged(nsView.window)
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: Coordinator) {
        coordinator.windowChanged(nil)
    }

    final class Coordinator {
        var isExpanded = true
        var toggle: () -> Void = {}
        private weak var window: NSWindow?

        func windowChanged(_ window: NSWindow?) {
            if self.window != nil, window == nil {
                SidebarToggleInstaller.shared.uninstall()
            }
            self.window = window
            guard let window else { return }
            SidebarToggleInstaller.shared.install(on: window, isExpanded: { [weak self] in
                self?.isExpanded ?? true
            }, toggle: { [weak self] in
                self?.toggle()
            })
        }
    }
}

/// Invisible. It only keeps the window hook alive, so it must not take clicks.
private final class BridgeView: NSView {
    var onWindowChange: (NSWindow?) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }
}

private final class SidebarToggleInstaller: NSObject {
    static let shared = SidebarToggleInstaller()

    private let selector = #selector(NSSplitViewController.toggleSidebar(_:))
    private var swizzledClasses = Set<ObjectIdentifier>()
    private var toggle: () -> Void = {}
    private var isExpanded: () -> Bool = { true }
    private weak var window: NSWindow?
    /// The window implementation from before this installer replaced it.
    private var original: (@convention(c) (AnyObject, Selector, Any?) -> Void)?
    private var isForwarding = false
    private var menuObserver: NSObjectProtocol?

    func install(on window: NSWindow, isExpanded: @escaping () -> Bool, toggle: @escaping () -> Void) {
        self.window = window
        self.isExpanded = isExpanded
        self.toggle = toggle
        swizzleIfNeeded(object_getClass(window))
        observeMenu()
        claimSidebarMenuItem()
    }

    func uninstall() {
        toggle = {}
        isExpanded = { true }
        window = nil
    }

    /// The scene's own validation leaves this command disabled, so the shortcut never arrives.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == selector else { return true }
        menuItem.title = isExpanded() ? UICopy.resolve("Hide Sidebar") : UICopy.resolve("Show Sidebar")
        return true
    }

    @objc func toggleSidebar(_ sender: Any?) {
        handleToggle()
    }

    private func observeMenu() {
        guard menuObserver == nil else { return }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.claimSidebarMenuItem()
            }
        }
    }

    private func claimSidebarMenuItem() {
        guard let menu = NSApp.mainMenu else { return }
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == selector {
                    item.target = self
                }
                if let submenu = item.submenu {
                    walk(submenu)
                }
            }
        }
        walk(menu)
    }

    private func swizzleIfNeeded(_ cls: AnyClass?) {
        guard let cls else { return }
        let id = ObjectIdentifier(cls)
        guard !swizzledClasses.contains(id) else { return }
        guard let method = class_getInstanceMethod(NSWindow.self, selector),
              let encoding = method_getTypeEncoding(method),
              let previous = class_getMethodImplementation(NSWindow.self, selector) else { return }
        typealias ToggleFunction = @convention(c) (AnyObject, Selector, Any?) -> Void
        original = unsafeBitCast(previous, to: ToggleFunction.self)
        let block: @convention(block) (AnyObject, Any?) -> Void = { _, _ in
            MainActor.assumeIsolated {
                SidebarToggleInstaller.shared.handleToggle()
            }
        }
        let imp = imp_implementationWithBlock(block)
        _ = class_replaceMethod(cls, selector, imp, encoding)
        swizzledClasses.insert(id)
    }

    private func handleToggle() {
        guard let window else { return }
        let isNarrow = window.frame.width <= ContentView.iPhone18ProScreenWidth
        if isNarrow {
            toggle()
            return
        }
        guard !isForwarding, let original else { return }
        isForwarding = true
        original(window, selector, nil)
        isForwarding = false
    }
}

/// Reloads this tab's preview when its window becomes the selected tab.
private struct PreviewTabMonitor: NSViewRepresentable {
    var tabID: UUID
    var model: DocumentPreviewModel
    var answer: String
    var workingDirectory: String
    var isAsking: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewTabMonitorView {
        context.coordinator.store(
            tabID: tabID,
            model: model,
            answer: answer,
            workingDirectory: workingDirectory,
            isAsking: isAsking
        )
        let view = PreviewTabMonitorView()
        view.onBecomeKey = { [weak coordinator = context.coordinator] in
            coordinator?.becomeKey()
        }
        return view
    }

    func updateNSView(_ nsView: PreviewTabMonitorView, context: Context) {
        context.coordinator.store(
            tabID: tabID,
            model: model,
            answer: answer,
            workingDirectory: workingDirectory,
            isAsking: isAsking
        )
    }

    static func dismantleNSView(_ nsView: PreviewTabMonitorView, coordinator: Coordinator) {
        nsView.detach()
        PreviewShelf.shared.unregister(id: coordinator.tabID)
    }

    final class Coordinator {
        var tabID = UUID()
        var model: DocumentPreviewModel?
        var answer = ""
        var workingDirectory = ""
        var isAsking = false

        func store(
            tabID: UUID,
            model: DocumentPreviewModel,
            answer: String,
            workingDirectory: String,
            isAsking: Bool
        ) {
            self.tabID = tabID
            self.model = model
            self.answer = answer
            self.workingDirectory = workingDirectory
            self.isAsking = isAsking
            PreviewShelf.shared.update(
                id: tabID,
                model: model,
                answer: answer,
                workingDirectory: workingDirectory,
                isAsking: isAsking
            )
        }

        func becomeKey() {
            guard let model else { return }
            PreviewShelf.shared.update(
                id: tabID,
                model: model,
                answer: answer,
                workingDirectory: workingDirectory,
                isAsking: isAsking
            )
            PreviewShelf.shared.activate(id: tabID)
        }
    }
}

private final class PreviewTabMonitorView: NSView {
    var onBecomeKey: () -> Void = {}
    private var observer: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            let becomeKey = self?.onBecomeKey
            Task { @MainActor in
                becomeKey?()
            }
        }
        if window.isKeyWindow {
            onBecomeKey()
        }
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

/// Shared sidebar width for 入庫, 文件, and 歷史. Every mmlmRAG tab reads the same UserDefaults value.
private enum DocumentsSidebarWidthPolicy {
    static let defaultsKey = "documentsSidebarWidth"
    static let fallback: Double = 560
    static let preferredMin: CGFloat = 420
    static let preferredMax: CGFloat = 900
    static let mainPageReserve: CGFloat = 240
    static let collapsedFloor: CGFloat = 160

    static func preferredIdeal(stored: Double) -> CGFloat {
        let width = CGFloat(stored)
        guard width >= preferredMin, width <= preferredMax else { return CGFloat(fallback) }
        return width
    }

    /// Nil when this window is too narrow to give the sidebar its saved width.
    static func enforced(
        stored: Double,
        columnMin: CGFloat,
        columnMax: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat? {
        let preferred = preferredIdeal(stored: stored)
        guard preferred + mainPageReserve <= availableWidth + 0.5 else { return nil }
        return min(columnMax, max(columnMin, preferred))
    }

    /// Finished divider drag. Nil while the window is squeezing the column below its preferred minimum.
    static func preferenceToRemember(measured: CGFloat, availableWidth: CGFloat) -> Double? {
        let windowLimitedMin = min(preferredMin, max(collapsedFloor, availableWidth - mainPageReserve))
        if windowLimitedMin < preferredMin - 0.5 { return nil }
        let rounded = measured.rounded()
        guard rounded >= preferredMin - 1, rounded <= preferredMax + 1 else { return nil }
        return Double(min(preferredMax, max(preferredMin, rounded)))
    }
}

/// Writes a sidebar divider drag into the shared width, and applies that width on every sidebar tab.
private struct DocumentsSidebarWidthSync: NSViewRepresentable {
    var enforcedWidth: CGFloat?
    var remembersDrag: Bool
    var sidebarTab: SidebarTab
    var availableWidth: CGFloat
    var onCommit: (Double) -> Void

    func makeNSView(context: Context) -> DocumentsSidebarWidthSyncView {
        let view = DocumentsSidebarWidthSyncView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: DocumentsSidebarWidthSyncView, context: Context) {
        let widthChanged = !Self.sameWidth(nsView.enforcedWidth, enforcedWidth)
        let tabChanged = nsView.sidebarTab != sidebarTab
        nsView.remembersDrag = remembersDrag
        nsView.sidebarTab = sidebarTab
        nsView.availableWidth = availableWidth
        nsView.onCommit = onCommit
        nsView.enforcedWidth = enforcedWidth
        nsView.ensureObserving()
        if widthChanged || tabChanged {
            nsView.correctionCount = 0
            nsView.scheduleApply()
        }
    }

    static func dismantleNSView(_ nsView: DocumentsSidebarWidthSyncView, coordinator: Coordinator) {
        nsView.teardown()
    }

    private static func sameWidth(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= 0.5
        default:
            return false
        }
    }
}

private final class DocumentsSidebarWidthSyncView: NSView {
    var enforcedWidth: CGFloat?
    var remembersDrag = false
    var sidebarTab = SidebarTab.ingest
    var availableWidth: CGFloat = 0
    var onCommit: (Double) -> Void = { _ in }
    var correctionCount = 0

    private var splitView: NSSplitView?
    private var keyObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var trackingDivider = false
    private var applyTicket = 0

    deinit {
        teardown()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            detachObservers()
            splitView = nil
            trackingDivider = false
            return
        }
        observeKeyWindow()
        ensureObserving()
        scheduleApply()
    }

    func teardown() {
        detachObservers()
        splitView = nil
        trackingDivider = false
        applyTicket += 1
    }

    func ensureObserving() {
        let split = nearestSplitView
        if split !== splitView {
            splitView = split
        }
        guard mouseMonitor == nil, window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.trackDivider(event)
            }
            return event
        }
    }

    private func observeKeyWindow() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Split constraints are still the previous tab's until this notification returns.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.correctionCount = 0
                self.scheduleApply()
            }
        }
    }

    func scheduleApply() {
        applyTicket += 1
        let ticket = applyTicket
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.applyTicket else { return }
            self.ensureObserving()
            guard let target = self.enforcedWidth else { return }
            self.apply(target)
        }
    }

    private func detachObservers() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
    }

    private func trackDivider(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            trackingDivider = remembersDrag && eventHitsDivider(event)
        case .leftMouseUp:
            guard trackingDivider else { return }
            trackingDivider = false
            guard remembersDrag, let measured = currentSidebarWidth else { return }
            if let enforcedWidth, abs(measured - enforcedWidth) < 1 { return }
            guard let remembered = DocumentsSidebarWidthPolicy.preferenceToRemember(
                measured: measured,
                availableWidth: availableWidth
            ) else { return }
            let commit = onCommit
            Task { @MainActor in
                commit(remembered)
            }
        default:
            break
        }
    }

    private func eventHitsDivider(_ event: NSEvent) -> Bool {
        guard let split = splitView, split.isVertical, event.window === split.window else { return false }
        guard let sidebar = sidebarPane(in: split), !split.isSubviewCollapsed(sidebar) else { return false }
        let point = split.convert(event.locationInWindow, from: nil)
        return abs(point.x - sidebar.frame.maxX) <= max(30, split.dividerThickness + 8)
    }

    private func apply(_ target: CGFloat) {
        guard let split = splitView, split.isVertical, let sidebar = sidebarPane(in: split) else { return }
        guard split.arrangedSubviews.first === sidebar, !split.isSubviewCollapsed(sidebar) else { return }
        let current = sidebar.frame.width
        guard abs(current - target) > 1 else {
            correctionCount = 0
            return
        }
        let lower = split.minPossiblePositionOfDivider(at: 0)
        let upper = split.maxPossiblePositionOfDivider(at: 0)
        guard upper + 0.5 >= lower else { return }
        let position = min(max(target, lower), upper)
        guard abs(current - position) > 1 else {
            // Constraints can still be the previous column's max for a moment. Try again next turn.
            guard abs(current - target) > 1, correctionCount < 5 else { return }
            correctionCount += 1
            scheduleApply()
            return
        }
        let previous = current
        split.setPosition(position, ofDividerAt: 0)
        if split.isSubviewCollapsed(sidebar) || sidebar.frame.width < 1 {
            split.setPosition(previous, ofDividerAt: 0)
            return
        }
        guard abs(sidebar.frame.width - target) > 1, correctionCount < 5 else {
            if abs(sidebar.frame.width - target) <= 1 {
                correctionCount = 0
            }
            return
        }
        correctionCount += 1
        scheduleApply()
    }

    private var currentSidebarWidth: CGFloat? {
        guard let split = splitView, let sidebar = sidebarPane(in: split) else { return nil }
        let width = sidebar.frame.width
        guard width > 1 else { return nil }
        return width
    }

    /// The pane that contains this view, or the leading pane when SwiftUI places the anchor beside the column.
    private func sidebarPane(in split: NSSplitView) -> NSView? {
        var view: NSView? = self
        while let current = view, current !== split {
            if current.superview === split {
                return current
            }
            view = current.superview
        }
        return split.arrangedSubviews.first
    }

    private var nearestSplitView: NSSplitView? {
        if let ancestor = sequence(first: superview, next: { $0?.superview }).compactMap({ $0 as? NSSplitView }).first {
            return ancestor
        }
        guard let content = window?.contentView else { return nil }
        return firstVerticalSplit(in: content)
    }

    private func firstVerticalSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical {
            return split
        }
        for child in view.subviews {
            if let found = firstVerticalSplit(in: child) {
                return found
            }
        }
        return nil
    }
}
#endif

#if os(macOS)
/// The split view does not pass its own minimum up to the window, so the floor is applied here.
private struct MainWindowMinimumWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowMinimumWidthView {
        let view = MainWindowMinimumWidthView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: MainWindowMinimumWidthView, context: Context) {
        nsView.apply()
    }
}

private final class MainWindowMinimumWidthView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    func apply() {
        guard let window else { return }
        let width = ContentView.minimumWindowWidth
        guard window.contentMinSize.width != width else { return }
        window.contentMinSize = NSSize(width: width, height: window.contentMinSize.height)
    }
}

/// Keeps the window-tab "+" button in the toolbar when a wide sidebar would leave it on the sidebar's trailing edge.
private struct NewTabButtonKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> NewTabButtonKeeperView {
        let view = NewTabButtonKeeperView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NewTabButtonKeeperView, context: Context) {
        nsView.schedule()
    }

    static func dismantleNSView(_ nsView: NewTabButtonKeeperView, coordinator: Coordinator) {
        nsView.restoreIfNeeded()
    }
}

/// The system button is `NSTabBarNewTabButton`, pinned to the trailing edge of the tab bar.
/// A sidebar that reaches that edge puts the button on the sidebar. It then sits in the title bar,
/// just before the trailing toolbar controls.
private final class NewTabButtonKeeperView: NSView {
    private weak var parkedBar: NSView?
    private var parkedConstraints: [NSLayoutConstraint] = []
    private var liftConstraints: [NSLayoutConstraint] = []
    private var softened: [(NSLayoutConstraint, NSLayoutConstraint.Priority)] = []
    private var resizeObserver: NSObjectProtocol?
    private var splitObserver: NSObjectProtocol?
    private var watchTimer: Timer?
    private var applyTicket = 0

    private static let trailingID = "mmlm.newTabLift"
    private static let buttonSide: CGFloat = 28
    private static let edgeSlop: CGFloat = 8
    private static let clusterGap: CGFloat = 6
    private static let minimumLeading: CGFloat = 78

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        if let splitObserver {
            NotificationCenter.default.removeObserver(splitObserver)
        }
        watchTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        schedule()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let splitObserver {
            NotificationCenter.default.removeObserver(splitObserver)
            self.splitObserver = nil
        }
        watchTimer?.invalidate()
        watchTimer = nil
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.schedule()
            }
        }
        splitObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let split = note.object as? NSSplitView, split.window === self.window else { return }
            DispatchQueue.main.async { [weak self] in
                self?.schedule()
            }
        }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
        schedule()
    }

    func schedule() {
        applyTicket += 1
        let ticket = applyTicket
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.applyTicket else { return }
            self.apply()
        }
    }

    func restoreIfNeeded() {
        guard let window, let button = Self.newTabButton(in: window) else { return }
        restore(button)
    }

    private func apply() {
        guard let window, let button = Self.newTabButton(in: window) else { return }
        guard let sidebarMaxX = Self.sidebarMaxX(in: window),
              let tabBar = Self.find("NSTabBar", in: window) else {
            restore(button)
            return
        }
        let restingMinX = tabBar.convert(
            NSPoint(x: tabBar.bounds.width - 8 - Self.buttonSide, y: 0),
            to: nil
        ).x
        if restingMinX < sidebarMaxX + Self.edgeSlop {
            lift(button, in: window)
        } else {
            restore(button)
        }
    }

    private func lift(_ button: NSView, in window: NSWindow) {
        guard let titlebar = Self.find("NSTitlebarView", in: window),
              let toolbar = Self.find("NSToolbarView", in: window) else { return }
        if button.superview !== titlebar {
            guard let bar = button.superview else { return }
            NSLayoutConstraint.deactivate(liftConstraints)
            liftConstraints = []
            parkedBar = bar
            parkedConstraints = bar.constraints.filter { Self.involves($0, button) }
            NSLayoutConstraint.deactivate(parkedConstraints)
            softenSizing(of: button)
            button.removeFromSuperview()
            titlebar.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            let trailing = button.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor)
            trailing.identifier = Self.trailingID
            liftConstraints = [
                trailing,
                button.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: Self.buttonSide),
                button.heightAnchor.constraint(equalToConstant: Self.buttonSide),
            ]
            NSLayoutConstraint.activate(liftConstraints)
        }
        guard let trailing = liftConstraints.first(where: { $0.identifier == Self.trailingID }) else { return }
        let desired = trailingConstant(titlebar: titlebar, ignoring: button)
        guard abs(trailing.constant - desired) > 0.5 else { return }
        trailing.constant = desired
    }

    private func restore(_ button: NSView) {
        guard let bar = parkedBar, button.superview !== bar else { return }
        NSLayoutConstraint.deactivate(liftConstraints)
        liftConstraints = []
        button.removeFromSuperview()
        bar.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(parkedConstraints)
        parkedConstraints = []
        parkedBar = nil
        restoreSizing()
    }

    private func trailingConstant(titlebar: NSView, ignoring button: NSView) -> CGFloat {
        let width = titlebar.bounds.width
        let cluster = Self.toolbarClusterMinX(in: titlebar, ignoring: button)
        let targetMaxX = max(Self.minimumLeading + Self.buttonSide, (cluster ?? width - 8) - Self.clusterGap)
        return targetMaxX - width
    }

    private func softenSizing(of button: NSView) {
        softened.removeAll()
        for constraint in button.constraints {
            guard constraint.secondItem == nil,
                  constraint.firstAttribute == .width || constraint.firstAttribute == .height,
                  constraint.priority == .required else { continue }
            softened.append((constraint, constraint.priority))
            constraint.priority = .defaultHigh
        }
    }

    private func restoreSizing() {
        for (constraint, priority) in softened {
            constraint.priority = priority
        }
        softened.removeAll()
    }

    private static func involves(_ constraint: NSLayoutConstraint, _ view: NSView) -> Bool {
        (constraint.firstItem as? NSView) === view || (constraint.secondItem as? NSView) === view
    }

    private static func newTabButton(in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        return find("NSTabBarNewTabButton", in: root)
    }

    private static func find(_ name: String, in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        return find(name, in: root)
    }

    private static func find(_ name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == name { return view }
        for subview in view.subviews {
            if let found = find(name, in: subview) { return found }
        }
        return nil
    }

    /// Trailing edge of the narrower split pane, which is the sidebar.
    private static func sidebarMaxX(in window: NSWindow) -> CGFloat? {
        guard let content = window.contentView, let split = verticalSplit(in: content) else { return nil }
        let panes = split.arrangedSubviews.map { view in
            (view, view.convert(view.bounds, to: nil))
        }
        guard panes.count >= 2, let sidebar = panes.min(by: { $0.1.width < $1.1.width }) else { return nil }
        guard !split.isSubviewCollapsed(sidebar.0), sidebar.1.width > 40 else { return nil }
        return sidebar.1.maxX
    }

    private static func verticalSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical { return split }
        for subview in view.subviews {
            if let found = verticalSplit(in: subview) { return found }
        }
        return nil
    }

    /// Leading edge of the trailing toolbar controls, in title-bar coordinates.
    private static func toolbarClusterMinX(in titlebar: NSView, ignoring button: NSView) -> CGFloat? {
        var minX: CGFloat?
        func walk(_ view: NSView) {
            if view !== button {
                let name = String(describing: type(of: view))
                if name.contains("ToolbarItemViewer") || name == "NSToolbarClippedItemsIndicator" {
                    let frame = titlebar.convert(view.bounds, from: view)
                    if frame.width > 16, frame.height > 16, frame.minX > titlebar.bounds.width * 0.35 {
                        minX = min(minX ?? frame.minX, frame.minX)
                    }
                }
            }
            for subview in view.subviews where subview !== button {
                walk(subview)
            }
        }
        if let toolbar = find("NSToolbarView", in: titlebar) {
            walk(toolbar)
        }
        return minX
    }
}
#endif

#Preview {
    #if os(macOS)
    ContentView(settings: RagSettings(), history: QuestionHistoryStore())
    #else
    ContentView()
    #endif
}
