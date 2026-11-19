import AppKit
import PDFKit
import SwiftUI
import Vision

#if os(macOS)

enum SidebarTab: Hashable {
    case ingest
    case documents
    case history
}

struct CitedDocument: Identifiable {
    var filename: String
    var sourcePath: String?
    var problem: String?
    var pages: [RenderedPage] = []

    var id: String { filename }
}

struct RenderedPage: Identifiable {
    var page: Int
    var image: NSImage?
    var pdfPage: PDFPage?
    var problem: String?

    var id: Int { page }
}

@MainActor
@Observable
final class DocumentPreviewModel {
    private(set) var groups: [CitedDocument] = []
    private(set) var isLoading = false
    private(set) var notice: String?
    /// Pages inside each file. Loading keeps source order; this only changes display.
    var pageOrder: CitationPageOrder = .source

    private var loadedKey = ""
    private var loadedDirectory = ""
    private var generation = 0
    private var documents: [String: PDFDocument] = [:]
    private var images: [String: NSImage] = [:]
    /// False after another tab takes the preview cache. Loads wait until this tab is selected again.
    private(set) var acceptsLoads = true

    func load(answer: String, workingDirectory: String) async {
        guard acceptsLoads else { return }
        let cited = CitationPages.orderedPages(in: answer, order: .source)
        let key = cited.map(\.id).joined(separator: "\u{1e}") + "\u{1f}" + workingDirectory
        guard key != loadedKey else { return }

        generation += 1
        let ticket = generation
        isLoading = true
        notice = nil
        if workingDirectory != loadedDirectory {
            documents = [:]
            images = [:]
            groups = []
            loadedDirectory = workingDirectory
        }
        await Task.yield()
        guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }

        guard !cited.isEmpty else {
            documents = [:]
            images = [:]
            groups = []
            isLoading = false
            loadedKey = key
            loadedDirectory = workingDirectory
            return
        }

        let filenames = cited.reduce(into: [String]()) { list, page in
            if !list.contains(page.filename) {
                list.append(page.filename)
            }
        }
        let located = CorpusLookup.sourcePaths(for: filenames, workingDirectory: workingDirectory)
        guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }

        switch located {
        case .failure(let failure):
            notice = failure.message
            groups = []
            isLoading = false
            loadedKey = key
        case .success(let pathsByName):
            var built: [CitedDocument] = []
            for filename in filenames {
                guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }
                var group = groupShell(filename: filename, paths: pathsByName[filename] ?? [])
                built.append(group)
                groups = built
                await Task.yield()
                guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }
                guard group.problem == nil, let path = group.sourcePath else { continue }
                guard let document = openDocument(at: path) else {
                    group.problem = "打唔開呢個 PDF。"
                    replace(group, in: &built)
                    groups = built
                    continue
                }
                let pages = cited.filter { $0.filename == filename }.map(\.page)
                for page in pages {
                    guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }
                    group.pages.append(render(document: document, path: path, pageNumber: page))
                    replace(group, in: &built)
                    groups = built
                    await Task.yield()
                }
            }
            guard ticket == generation, !Task.isCancelled, acceptsLoads else { return }
            isLoading = false
            loadedKey = key
        }
    }

    /// Drops rendered pages but still accepts the next answer's load.
    func discardRenderedPages() {
        generation += 1
        documents = [:]
        images = [:]
        groups = []
        loadedKey = ""
        loadedDirectory = ""
        isLoading = false
        notice = nil
    }

    /// Drops rendered pages and ignores loads until `resumeLoads()`.
    func releaseResources() {
        let alreadyReleased = !acceptsLoads && documents.isEmpty && images.isEmpty && groups.isEmpty && !isLoading
        acceptsLoads = false
        guard !alreadyReleased else { return }
        generation += 1
        documents = [:]
        images = [:]
        groups = []
        loadedKey = ""
        loadedDirectory = ""
        isLoading = false
        notice = nil
    }

    func resumeLoads() {
        acceptsLoads = true
    }

    private func groupShell(filename: String, paths: [String]) -> CitedDocument {
        if let existing = paths.first(where: { FileManager.default.isReadableFile(atPath: $0) }) {
            if URL(fileURLWithPath: existing).pathExtension.lowercased() == "pdf" {
                return CitedDocument(filename: filename, sourcePath: existing)
            }
            return CitedDocument(
                filename: filename,
                sourcePath: existing,
                problem: "呢個檔唔係 PDF，預覽唔到頁面。"
            )
        }
        if let path = paths.first {
            return CitedDocument(
                filename: filename,
                sourcePath: path,
                problem: "檔案唔存在：\(path)"
            )
        }
        return CitedDocument(filename: filename, problem: "語料冇「\(filename)」。")
    }

    private func replace(_ group: CitedDocument, in built: inout [CitedDocument]) {
        guard let index = built.firstIndex(where: { $0.filename == group.filename }) else { return }
        built[index] = group
    }

    private func openDocument(at path: String) -> PDFDocument? {
        if let document = documents[path] { return document }
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        documents[path] = document
        return document
    }

    /// Citation pages are 1-based. PDFKit page indexes are 0-based.
    private func render(document: PDFDocument, path: String, pageNumber: Int) -> RenderedPage {
        let cacheKey = "\(path)#\(pageNumber)"
        guard pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1)
        else {
            return RenderedPage(page: pageNumber, problem: "冇第 \(pageNumber) 頁。")
        }
        if let image = images[cacheKey] {
            return RenderedPage(page: pageNumber, image: image, pdfPage: page)
        }
        let display = PDFPageGeometry.displayedSize(of: page)
        guard display.width > 1, display.height > 1 else {
            return RenderedPage(page: pageNumber, problem: "第 \(pageNumber) 頁冇尺寸。")
        }
        let targetWidth: CGFloat = 1600
        let targetHeight = targetWidth * display.height / display.width
        let image = page.thumbnail(of: NSSize(width: targetWidth, height: targetHeight), for: PDFPageGeometry.box)
        images[cacheKey] = image
        return RenderedPage(page: pageNumber, image: image, pdfPage: page)
    }
}

/// Keeps PDF page bitmaps for the selected mmlmRAG tab only.
@MainActor
final class PreviewShelf {
    static let shared = PreviewShelf()

    private struct Slot {
        weak var model: DocumentPreviewModel?
        var answer: String
        var workingDirectory: String
        var isAsking: Bool
    }

    private var slots: [UUID: Slot] = [:]

    func update(
        id: UUID,
        model: DocumentPreviewModel,
        answer: String,
        workingDirectory: String,
        isAsking: Bool
    ) {
        slots[id] = Slot(
            model: model,
            answer: answer,
            workingDirectory: workingDirectory,
            isAsking: isAsking
        )
    }

    func unregister(id: UUID) {
        slots[id]?.model?.releaseResources()
        slots.removeValue(forKey: id)
    }

    /// A newly asked tab drops every other tab's rendered pages.
    func noteAsking(id: UUID) {
        releaseOthers(keeping: id)
        guard let model = slots[id]?.model else { return }
        model.resumeLoads()
        model.discardRenderedPages()
    }

    /// Switching to a tab that already has an answer reloads that answer and frees the others.
    /// A new empty tab leaves the previous tab's pages in memory until it asks.
    func activate(id: UUID) {
        guard let slot = slots[id], let model = slot.model else { return }
        let trimmed = slot.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || slot.isAsking else { return }
        releaseOthers(keeping: id)
        model.resumeLoads()
        guard !trimmed.isEmpty else { return }
        let answer = slot.answer
        let directory = slot.workingDirectory
        Task { await model.load(answer: answer, workingDirectory: directory) }
    }

    private func releaseOthers(keeping id: UUID) {
        for (slotID, slot) in slots where slotID != id {
            slot.model?.releaseResources()
        }
    }
}

/// Maps a fitted, upright page image back to PDF page space, including rotation.
enum PDFPageGeometry {
    static let box: PDFDisplayBox = .cropBox

    static func displayedSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: box)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        if quarterTurns % 2 == 1 {
            return CGSize(width: bounds.height, height: bounds.width)
        }
        return bounds.size
    }

    /// `viewPoint` is in an unflipped view whose bounds show the upright page image.
    static func pagePoint(from viewPoint: CGPoint, viewBounds: CGRect, page: PDFPage) -> CGPoint? {
        guard viewBounds.width > 1, viewBounds.height > 1 else { return nil }
        let display = displayedSize(of: page)
        guard display.width > 1, display.height > 1 else { return nil }
        let transform = page.transform(for: box)
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 0.000_001 else { return nil }
        let upright = CGPoint(
            x: (viewPoint.x - viewBounds.minX) / viewBounds.width * display.width,
            y: (viewPoint.y - viewBounds.minY) / viewBounds.height * display.height
        )
        return upright.applying(transform.inverted())
    }

    /// Character range between two page-space points. Falls back to the rectangle between them
    /// when a point is in the margin and has no character index.
    static func textSelection(on page: PDFPage, from start: CGPoint, to end: CGPoint) -> PDFSelection? {
        let startIndex = page.characterIndex(at: start)
        let endIndex = page.characterIndex(at: end)
        if startIndex != NSNotFound, endIndex != NSNotFound {
            let lower = min(startIndex, endIndex)
            let upper = max(startIndex, endIndex)
            return page.selection(for: NSRange(location: lower, length: upper - lower + 1))
        }
        return page.selection(from: start, to: end)
    }
}

/// Vision OCR of one rendered page. Boxes are normalized to that image, origin at the lower-left.
private nonisolated struct RecognizedPageText: Sendable {
    struct Glyph: Sendable {
        var text: String
        var bounds: CGRect
        var lineID: Int
    }

    var glyphs: [Glyph]

    var isEmpty: Bool { glyphs.isEmpty }

    init(observations: [VNRecognizedTextObservation]) {
        var glyphs: [Glyph] = []
        var lineID = 0
        for observation in Self.readingOrder(observations) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = Self.glyphs(in: candidate, lineID: lineID, fallback: observation.boundingBox)
            guard !line.isEmpty else { continue }
            glyphs.append(contentsOf: line)
            lineID += 1
        }
        self.glyphs = glyphs
    }

    func text(in indexes: IndexSet) -> String {
        var result = ""
        var previousLine: Int?
        for index in indexes where glyphs.indices.contains(index) {
            let glyph = glyphs[index]
            if let previousLine, glyph.lineID != previousLine {
                result += "\n"
            }
            result += glyph.text
            previousLine = glyph.lineID
        }
        return result
    }

    func indexes(intersecting normalizedRect: CGRect) -> IndexSet {
        var indexes = IndexSet()
        for (index, glyph) in glyphs.enumerated() {
            let hit = glyph.bounds.intersection(normalizedRect)
            guard hit.width > 0.000_5, hit.height > 0.000_5 else { continue }
            indexes.insert(index)
        }
        return indexes
    }

    func glyphIndex(at normalizedPoint: CGPoint) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, glyph) in glyphs.enumerated() {
            let rect = glyph.bounds.insetBy(dx: -0.004, dy: -0.001)
            guard rect.contains(normalizedPoint) else { continue }
            let area = max(glyph.bounds.width, 0) * max(glyph.bounds.height, 0)
            if let current = best {
                if area < current.area {
                    best = (index, area)
                }
            } else {
                best = (index, area)
            }
        }
        return best?.index
    }

    func wordRange(containing index: Int) -> Range<Int> {
        guard glyphs.indices.contains(index) else { return 0..<0 }
        let lineID = glyphs[index].lineID
        guard Self.isWordCharacter(glyphs[index].text) else {
            return index..<(index + 1)
        }
        var lower = index
        while lower > 0 {
            let previous = glyphs[lower - 1]
            guard previous.lineID == lineID, Self.isWordCharacter(previous.text) else { break }
            lower -= 1
        }
        var upper = index + 1
        while upper < glyphs.count {
            let next = glyphs[upper]
            guard next.lineID == lineID, Self.isWordCharacter(next.text) else { break }
            upper += 1
        }
        return lower..<upper
    }

    func lineRange(containing index: Int) -> Range<Int> {
        guard glyphs.indices.contains(index) else { return 0..<0 }
        let lineID = glyphs[index].lineID
        var lower = index
        while lower > 0, glyphs[lower - 1].lineID == lineID {
            lower -= 1
        }
        var upper = index + 1
        while upper < glyphs.count, glyphs[upper].lineID == lineID {
            upper += 1
        }
        return lower..<upper
    }

    private static func isWordCharacter(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first, scalars.count == 1 else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.punctuationCharacters.contains(scalar)
            && !CharacterSet.symbols.contains(scalar)
    }

    /// Rows share a band so a table is copied left to right, then downward.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        let sorted = observations.sorted { lhs, rhs in
            let delta = lhs.boundingBox.maxY - rhs.boundingBox.maxY
            if abs(delta) > 0.002 {
                return delta > 0
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in sorted {
            let box = observation.boundingBox
            if let rowIndex = rows.firstIndex(where: { row in
                row.contains { verticalOverlap($0.boundingBox, box) >= 0.45 }
            }) {
                rows[rowIndex].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.flatMap { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let height = min(lhs.height, rhs.height)
        guard height > 0.000_1 else { return 0 }
        return overlap / height
    }

    private static func glyphs(in candidate: VNRecognizedText, lineID: Int, fallback: CGRect) -> [Glyph] {
        let string = candidate.string
        guard !string.isEmpty else { return [] }
        var pieces: [(text: String, bounds: CGRect?)] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            let box = try? candidate.boundingBox(for: index..<next)
            let bounds = box?.boundingBox
            if let bounds, bounds.width > 0, bounds.height > 0 {
                pieces.append((String(string[index..<next]), bounds))
            } else {
                pieces.append((String(string[index..<next]), nil))
            }
            index = next
        }
        let count = CGFloat(pieces.count)
        let splitEvenly = pieces.allSatisfy { $0.bounds == nil } && fallback.width > 0 && count > 0
        return pieces.enumerated().map { offset, piece in
            let bounds: CGRect
            if let known = piece.bounds {
                bounds = known
            } else if splitEvenly {
                bounds = CGRect(
                    x: fallback.minX + fallback.width * CGFloat(offset) / count,
                    y: fallback.minY,
                    width: fallback.width / count,
                    height: fallback.height
                )
            } else {
                bounds = fallback
            }
            return Glyph(text: piece.text, bounds: bounds, lineID: lineID)
        }
    }
}

/// `VNRecognizeTextRequest` is the recognizer ocrmac wraps. Cancel can run while `recognize()` is in progress.
private nonisolated final class PageOCRJob: @unchecked Sendable {
    private let image: CGImage
    private let request: VNRecognizeTextRequest

    init(cgImage: CGImage) {
        image = cgImage
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "yue-Hant", "en-US"]
        self.request = request
    }

    func cancel() {
        request.cancel()
    }

    func recognize() -> RecognizedPageText? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return RecognizedPageText(observations: request.results ?? [])
    }
}

/// One cited page, drawn from its bitmap, with text selection on top.
struct SelectablePDFPage: NSViewRepresentable {
    var image: NSImage
    var pdfPage: PDFPage

    func makeNSView(context: Context) -> SelectablePDFPageView {
        let view = SelectablePDFPageView()
        view.pageImage = image
        view.pdfPage = pdfPage
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SelectablePDFPageView, context: Context) {
        nsView.show(image: image, pdfPage: pdfPage)
    }

    static func dismantleNSView(_ nsView: SelectablePDFPageView, coordinator: Coordinator) {
        nsView.cancelRecognition()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelectablePDFPageView,
        context: Context
    ) -> CGSize? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        if let width = proposal.width, width.isFinite, width > 1 {
            return CGSize(width: width, height: width * size.height / size.width)
        }
        if let height = proposal.height, height.isFinite, height > 1 {
            return CGSize(width: height * size.width / size.height, height: height)
        }
        return size
    }
}

final class SelectablePDFPageView: NSView, NSMenuItemValidation {
    var pageImage: NSImage?
    var pdfPage: PDFPage?

    private let statusLabel = PassThroughLabel(frame: .zero)
    private var selection: PDFSelection?
    private var anchorPoint: CGPoint?
    private var ocrAnchor: CGPoint?
    private var granularity: SelectionGranularity = .character
    private var dragMode: DragMode = .none
    private var selectionObserver: NSObjectProtocol?
    private var recognitionTask: Task<Void, Never>?
    private var ocrJob: PageOCRJob?
    private var recognizedImage: NSImage?
    private var recognized: RecognizedPageText?
    private var ocrSelection: IndexSet?

    private static let selectionNotification = Notification.Name("mmlmRAGUI.previewPageTextSelection")

    private enum SelectionGranularity {
        case character
        case word
        case line
    }

    private enum DragMode {
        case none
        case pdf
        case ocr
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        statusLabel.stringValue = "識別緊文字…"
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.isHidden = true
        statusLabel.setAccessibilityElement(false)
        addSubview(statusLabel)
        selectionObserver = NotificationCenter.default.addObserver(
            forName: Self.selectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object as AnyObject !== self else { return }
            DispatchQueue.main.async { [weak self] in
                self?.clearSelection()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        recognitionTask?.cancel()
        ocrJob?.cancel()
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    /// Image-only pages, such as a scanned table, have no PDF text layer. OCR supplies the selectable text.
    func show(image: NSImage, pdfPage: PDFPage) {
        let pageChanged = self.pdfPage !== pdfPage
        let imageChanged = pageImage !== image
        if pageChanged {
            clearSelection()
            dragMode = .none
        }
        self.pdfPage = pdfPage
        if imageChanged {
            pageImage = image
            needsDisplay = true
        }
        recognizeIfNeeded(image)
    }

    func cancelRecognition() {
        stopOCR()
    }

    override func layout() {
        super.layout()
        let size = statusLabel.fittingSize
        statusLabel.frame = NSRect(
            x: 8,
            y: bounds.height - size.height - 8,
            width: size.width + 12,
            height: size.height + 4
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    func clearSelection() {
        let hadSelection = selection != nil || ocrSelection != nil
        selection = nil
        ocrSelection = nil
        guard hadSelection else { return }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        pageImage?.draw(in: bounds)
        drawSelectionHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if usesOCRSelection {
            dragMode = .ocr
            NotificationCenter.default.post(name: Self.selectionNotification, object: self)
            ocrAnchor = viewPoint
            switch event.clickCount {
            case 2:
                granularity = .word
                storeOCR(ocrIndexes(at: viewPoint, granularity: .word))
            case 3...:
                granularity = .line
                storeOCR(ocrIndexes(at: viewPoint, granularity: .line))
            default:
                granularity = .character
                storeOCR(nil)
            }
            return
        }
        dragMode = .pdf
        guard let pdfPage, let pagePoint = pagePoint(for: event) else { return }
        NotificationCenter.default.post(name: Self.selectionNotification, object: self)
        anchorPoint = pagePoint
        switch event.clickCount {
        case 2:
            granularity = .word
            store(pdfPage.selectionForWord(at: pagePoint))
        case 3...:
            granularity = .line
            store(pdfPage.selectionForLine(at: pagePoint))
        default:
            granularity = .character
            store(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        switch dragMode {
        case .ocr:
            guard granularity == .character, let recognized, let ocrAnchor else { return }
            let viewPoint = convert(event.locationInWindow, from: nil)
            guard let rect = normalizedRect(from: ocrAnchor, to: viewPoint) else { return }
            storeOCR(recognized.indexes(intersecting: rect))
        case .pdf:
            guard granularity == .character, let pdfPage, let anchorPoint, let pagePoint = pagePoint(for: event) else {
                return
            }
            store(PDFPageGeometry.textSelection(on: pdfPage, from: anchorPoint, to: pagePoint))
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        anchorPoint = nil
        ocrAnchor = nil
        dragMode = .none
    }

    @objc func copy(_ sender: Any?) {
        guard let text = textForClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        if usesOCRSelection, let recognized {
            NotificationCenter.default.post(name: Self.selectionNotification, object: self)
            storeOCR(IndexSet(integersIn: recognized.glyphs.indices))
            return
        }
        guard let pdfPage, pdfPage.numberOfCharacters > 0 else { return }
        NotificationCenter.default.post(name: Self.selectionNotification, object: self)
        let range = NSRange(location: 0, length: pdfPage.numberOfCharacters)
        store(pdfPage.selection(for: range))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "複製", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let selectAllItem = NSMenuItem(title: "全選", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return textForClipboard != nil
        case #selector(selectAll(_:)):
            if usesOCRSelection { return true }
            return (pdfPage?.numberOfCharacters ?? 0) > 0
        default:
            return true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copy(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    private var selectedText: String? {
        guard let text = selection?.string, !text.isEmpty else { return nil }
        return text
    }

    private func pagePoint(for event: NSEvent) -> CGPoint? {
        guard let pdfPage else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        return PDFPageGeometry.pagePoint(from: viewPoint, viewBounds: bounds, page: pdfPage)
    }

    private func store(_ next: PDFSelection?) {
        if let text = next?.string, !text.isEmpty {
            selection = next
        } else {
            selection = nil
        }
        needsDisplay = true
    }

    private func drawSelectionHighlight() {
        if usesOCRSelection, ocrSelection != nil {
            let color = selectionColor
            color.setFill()
            for rect in ocrHighlightRects() where rect.width > 0 && rect.height > 0 {
                rect.fill()
            }
            return
        }
        guard let pdfPage, let selection, selectedText != nil else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let display = PDFPageGeometry.displayedSize(of: pdfPage)
        guard display.width > 1, display.height > 1, bounds.width > 1, bounds.height > 1 else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / display.width, y: bounds.height / display.height)
        context.concatenate(pdfPage.transform(for: PDFPageGeometry.box))
        selectionColor.setFill()
        let lines = selection.selectionsByLine()
        let rects = lines.isEmpty ? [selection.bounds(for: pdfPage)] : lines.map { $0.bounds(for: pdfPage) }
        for rect in rects where rect.width > 0 && rect.height > 0 {
            context.fill(rect)
        }
        context.restoreGState()
    }

    private var selectionColor: NSColor {
        let focused = window?.firstResponder === self
        return focused
            ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
            : NSColor.unemphasizedSelectedTextBackgroundColor.withAlphaComponent(0.45)
    }

    private var needsOCR: Bool {
        guard let pdfPage else { return false }
        let text = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
    }

    private var usesOCRSelection: Bool {
        guard needsOCR, let recognized, !recognized.isEmpty else { return false }
        return true
    }

    private var textForClipboard: String? {
        if let recognized, let ocrSelection, !ocrSelection.isEmpty {
            let text = recognized.text(in: ocrSelection)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return selectedText
    }

    private func recognizeIfNeeded(_ image: NSImage) {
        guard needsOCR else {
            stopOCR()
            return
        }
        guard recognizedImage !== image else { return }
        recognitionTask?.cancel()
        ocrJob?.cancel()
        recognized = nil
        ocrSelection = nil
        recognizedImage = image
        statusLabel.stringValue = "識別緊文字…"
        statusLabel.isHidden = false
        needsLayout = true
        needsDisplay = true
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusLabel.stringValue = "呢頁識別唔到文字。"
            return
        }
        let job = PageOCRJob(cgImage: cgImage)
        ocrJob = job
        let token = image
        recognitionTask = Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                job.recognize()
            }.value
            guard let self, !Task.isCancelled, self.recognizedImage === token else { return }
            self.applyOCR(text)
        }
    }

    private func stopOCR() {
        recognitionTask?.cancel()
        recognitionTask = nil
        ocrJob?.cancel()
        ocrJob = nil
        let showingStatus = !statusLabel.isHidden
        statusLabel.isHidden = true
        guard recognized != nil || ocrSelection != nil || recognizedImage != nil || showingStatus else { return }
        recognized = nil
        recognizedImage = nil
        ocrSelection = nil
        needsDisplay = true
    }

    private func applyOCR(_ text: RecognizedPageText?) {
        ocrJob = nil
        let transcript = text?.text(in: IndexSet(integersIn: text?.glyphs.indices ?? 0..<0))
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if transcript.isEmpty {
            recognized = text
            statusLabel.stringValue = "呢頁識別唔到文字。"
            statusLabel.isHidden = false
        } else {
            recognized = text
            statusLabel.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    private func storeOCR(_ indexes: IndexSet?) {
        guard let recognized, let indexes, !indexes.isEmpty else {
            if ocrSelection != nil {
                ocrSelection = nil
                needsDisplay = true
            }
            return
        }
        let text = recognized.text(in: indexes)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ocrSelection = nil
            needsDisplay = true
            return
        }
        ocrSelection = indexes
        needsDisplay = true
    }

    private func ocrIndexes(at viewPoint: CGPoint, granularity: SelectionGranularity) -> IndexSet? {
        guard let recognized, let normalized = normalizedPoint(viewPoint),
              let index = recognized.glyphIndex(at: normalized) else {
            return nil
        }
        switch granularity {
        case .character:
            return IndexSet(integer: index)
        case .word:
            return IndexSet(integersIn: recognized.wordRange(containing: index))
        case .line:
            return IndexSet(integersIn: recognized.lineRange(containing: index))
        }
    }

    private func normalizedPoint(_ viewPoint: CGPoint) -> CGPoint? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        return CGPoint(
            x: (viewPoint.x - bounds.minX) / bounds.width,
            y: (viewPoint.y - bounds.minY) / bounds.height
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rect = CGRect(
            x: min(start.x, end.x) - 1,
            y: min(start.y, end.y) - 1,
            width: abs(end.x - start.x) + 2,
            height: abs(end.y - start.y) + 2
        )
        return CGRect(
            x: (rect.minX - bounds.minX) / bounds.width,
            y: (rect.minY - bounds.minY) / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        )
    }

    private func viewRect(forNormalized box: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + box.minX * bounds.width,
            y: bounds.minY + box.minY * bounds.height,
            width: box.width * bounds.width,
            height: box.height * bounds.height
        )
    }

    private func ocrHighlightRects() -> [CGRect] {
        guard let recognized, let ocrSelection else { return [] }
        var rects: [CGRect] = []
        var current: CGRect?
        var currentLine: Int?
        var previousIndex: Int?
        for index in ocrSelection where recognized.glyphs.indices.contains(index) {
            let glyph = recognized.glyphs[index]
            let rect = viewRect(forNormalized: glyph.bounds)
            guard rect.width > 0, rect.height > 0 else { continue }
            let continues = currentLine == glyph.lineID && previousIndex == index - 1
            if continues, let existing = current {
                current = existing.union(rect)
            } else {
                if let existing = current {
                    rects.append(existing)
                }
                current = rect
                currentLine = glyph.lineID
            }
            previousIndex = index
        }
        if let current {
            rects.append(current)
        }
        return rects
    }
}

private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct DocumentPreview: View {
    let answer: String
    let workingDirectory: String
    @Bindable var model: DocumentPreviewModel

    private var loadKey: String {
        let pages = CitationPages.orderedPages(in: answer, order: .source)
        return pages.map(\.id).joined(separator: "\u{1e}") + "\u{1f}" + workingDirectory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Picker("排序", selection: $model.pageOrder) {
                    ForEach(CitationPageOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("揀文件頁嘅排序")
            }

            Group {
                if model.isLoading, model.groups.isEmpty, model.notice == nil {
                    ProgressView("讀緊文件頁…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let notice = model.notice, model.groups.isEmpty {
                    ContentUnavailableView(
                        "預覽唔到",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(notice)
                    )
                } else if model.groups.isEmpty {
                    ContentUnavailableView(
                        "未有文件頁",
                        systemImage: "doc.richtext",
                        description: Text(emptyPageDescription)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if model.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("讀緊文件頁…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(model.groups) { group in
                                documentSection(group)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: loadKey) {
            await model.load(answer: answer, workingDirectory: workingDirectory)
        }
    }

    private var emptyPageDescription: String {
        switch model.pageOrder {
        case .source:
            "回答提到的文件頁會按答覆來源次序由上至下排喺呢度。"
        case .pageNumber:
            "回答提到的文件頁會按頁碼由小至大排喺呢度。"
        }
    }

    /// Loaded pages stay in source order. Page-number order is display only.
    private func displayedPages(in group: CitedDocument) -> [RenderedPage] {
        switch model.pageOrder {
        case .source:
            group.pages
        case .pageNumber:
            group.pages.sorted { $0.page < $1.page }
        }
    }

    private func pagePreview(image: NSImage, pdfPage: PDFPage?, filename: String, pageNumber: Int) -> some View {
        Group {
            if let pdfPage {
                SelectablePDFPage(image: image, pdfPage: pdfPage)
                    .help("拖選文字，然後按 ⌘C 複製。掃描頁會先識別文字。")
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.separator)
        }
        .accessibilityLabel("\(filename) 第 \(pageNumber) 頁")
    }

    private func documentSection(_ group: CitedDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.filename)
                .font(.headline)
            if let path = group.sourcePath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let problem = group.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(displayedPages(in: group)) { page in
                VStack(alignment: .leading, spacing: 6) {
                    Text("p.\(page.page)")
                        .font(.subheadline.weight(.semibold))
                    if let image = page.image {
                        pagePreview(image: image, pdfPage: page.pdfPage, filename: group.filename, pageNumber: page.page)
                    } else if let problem = page.problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#endif
