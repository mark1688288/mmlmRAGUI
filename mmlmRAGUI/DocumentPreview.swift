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
                    group.problem = ui("Couldn't open this PDF.")
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
                problem: ui("This file isn't a PDF, so its pages can't be previewed.")
            )
        }
        if let path = paths.first {
            return CitedDocument(
                filename: filename,
                sourcePath: path,
                problem: ui("File does not exist: {path}", ["path": path])
            )
        }
        return CitedDocument(filename: filename, problem: ui("The corpus has no \u{201C}{name}\u{201D}.", ["name": filename]))
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
            return RenderedPage(page: pageNumber, problem: ui("There is no page {page}.", ["page": String(pageNumber)]))
        }
        if let image = images[cacheKey] {
            return RenderedPage(page: pageNumber, image: image, pdfPage: page)
        }
        let display = PDFPageGeometry.displayedSize(of: page)
        guard display.width > 1, display.height > 1 else {
            return RenderedPage(page: pageNumber, problem: ui("Page {page} has no size.", ["page": String(pageNumber)]))
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

    /// `selection(for:)` raises if the range is empty or falls outside the page.
    static func selection(on page: PDFPage, for range: NSRange) -> PDFSelection? {
        guard range.location >= 0, range.length > 0 else { return nil }
        guard NSMaxRange(range) <= page.numberOfCharacters else { return nil }
        return page.selection(for: range)
    }

    /// 0 is the top of the upright page image, 1 is the bottom.
    static func centerFromTop(of selection: PDFSelection, on page: PDFPage) -> CGFloat? {
        let display = displayedSize(of: page)
        guard display.height > 1 else { return nil }
        let upright = selection.bounds(for: page).applying(page.transform(for: box))
        guard upright.isNull == false, upright.isInfinite == false else { return nil }
        guard upright.width > 0.2 || upright.height > 0.2 else { return nil }
        let fraction = 1 - (upright.midY / display.height)
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }
}

/// One keyword hit in the selectable text of a previewed page.
struct PreviewTextMatch: Equatable, Identifiable {
    enum Source: Equatable {
        case pdf
        case ocr
    }

    var filename: String
    var pageNumber: Int
    var range: NSRange
    var source: Source
    /// Glyph indexes when `source` is `.ocr`. Empty for a PDF text-layer hit.
    var ocrGlyphs: IndexSet

    var id: String {
        let kind = source == .pdf ? "pdf" : "ocr"
        return "\(filename)\u{1e}\(pageNumber)\u{1e}\(kind)\u{1e}\(range.location)\u{1e}\(range.length)"
    }

    var pageAnchor: String {
        Self.pageAnchor(filename: filename, page: pageNumber)
    }

    static func pageAnchor(filename: String, page: Int) -> String {
        "preview-page:\(filename)\u{1e}\(page)"
    }
}

/// Finds a literal keyword in the selectable text of the pages currently shown.
/// A PDF text layer is searched directly. A page PDFKit cannot read, such as a scan,
/// is searched once Vision has recognized the same text the page can select.
/// Hits follow the sidebar's file order, then the active page order inside each file.
enum PreviewTextSearch {
    nonisolated static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    nonisolated static func ranges(in text: NSString, query: String, limit: Int) -> [NSRange] {
        let needle = query as NSString
        guard needle.length > 0, limit > 0, text.length > 0 else { return [] }
        let capped = min(limit, text.length)
        guard capped >= needle.length else { return [] }
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: capped)
        while search.length >= needle.length {
            let hit = text.range(of: query, options: options, range: search)
            guard hit.location != NSNotFound, hit.length > 0, NSMaxRange(hit) <= capped else { break }
            found.append(hit)
            let next = NSMaxRange(hit)
            guard next < capped else { break }
            search = NSRange(location: next, length: capped - next)
        }
        return found
    }

    /// Nil when the page has no PDF text layer. Those pages are selected through OCR.
    static func pdfText(of page: PDFPage) -> NSString? {
        guard page.numberOfCharacters > 0, let raw = page.string else { return nil }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw as NSString
    }

    static func matches(in groups: [CitedDocument], query: String, order: CitationPageOrder) -> [PreviewTextMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var matches: [PreviewTextMatch] = []
        for group in groups {
            for page in orderedPages(in: group, order: order) {
                guard let pdfPage = page.pdfPage else { continue }
                if let text = pdfText(of: pdfPage) {
                    let limit = min(text.length, pdfPage.numberOfCharacters)
                    for range in ranges(in: text, query: trimmed, limit: limit) {
                        matches.append(
                            PreviewTextMatch(
                                filename: group.filename,
                                pageNumber: page.page,
                                range: range,
                                source: .pdf,
                                ocrGlyphs: []
                            )
                        )
                    }
                } else {
                    let key = PreviewOCRCache.key(filename: group.filename, page: page.page)
                    guard let recognized = PreviewOCRCache.shared.stored(for: key) else { continue }
                    for hit in recognized.searchHits(query: trimmed) where !hit.glyphs.isEmpty {
                        matches.append(
                            PreviewTextMatch(
                                filename: group.filename,
                                pageNumber: page.page,
                                range: hit.range,
                                source: .ocr,
                                ocrGlyphs: hit.glyphs
                            )
                        )
                    }
                }
            }
        }
        return matches
    }

    static func centerFromTop(of match: PreviewTextMatch, in groups: [CitedDocument]) -> CGFloat? {
        if match.source == .ocr {
            let key = PreviewOCRCache.key(filename: match.filename, page: match.pageNumber)
            return PreviewOCRCache.shared.stored(for: key)?.centerFromTop(of: match.ocrGlyphs)
        }
        for group in groups where group.filename == match.filename {
            guard let pdfPage = group.pages.first(where: { $0.page == match.pageNumber })?.pdfPage else { continue }
            guard let selection = PDFPageGeometry.selection(on: pdfPage, for: match.range) else { return nil }
            return PDFPageGeometry.centerFromTop(of: selection, on: pdfPage)
        }
        return nil
    }

    private static func orderedPages(in group: CitedDocument, order: CitationPageOrder) -> [RenderedPage] {
        switch order {
        case .source:
            group.pages
        case .pageNumber:
            group.pages.sorted { $0.page < $1.page }
        }
    }
}

/// Vision OCR of one rendered page. Boxes are normalized to that image, origin at the lower-left.
nonisolated struct RecognizedPageText: Sendable {
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

    struct SearchHit {
        var range: NSRange
        var glyphs: IndexSet
    }

    init(glyphs: [Glyph]) {
        self.glyphs = glyphs
    }

    func searchHits(query: String) -> [SearchHit] {
        let mapped = searchMap()
        return PreviewTextSearch.ranges(in: mapped.string, query: query, limit: mapped.string.length).compactMap { range in
            var indexes = IndexSet()
            let end = min(NSMaxRange(range), mapped.owners.count)
            guard range.location >= 0, range.location < end else { return nil }
            for offset in range.location..<end {
                let owner = mapped.owners[offset]
                guard owner >= 0 else { continue }
                indexes.insert(owner)
            }
            guard !indexes.isEmpty else { return nil }
            return SearchHit(range: range, glyphs: indexes)
        }
    }

    /// 0 is the top of the upright page image.
    func centerFromTop(of indexes: IndexSet) -> CGFloat? {
        var union: CGRect?
        for index in indexes where glyphs.indices.contains(index) {
            let box = glyphs[index].bounds
            union = union.map { $0.union(box) } ?? box
        }
        guard let union, union.isNull == false, union.isInfinite == false else { return nil }
        guard union.width > 0.000_5 || union.height > 0.000_5 else { return nil }
        let fraction = 1 - union.midY
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// UTF-16 owners are glyph indexes. A line break is `-1` so a hit cannot land on it.
    private func searchMap() -> (string: NSString, owners: [Int]) {
        var raw = ""
        var owners: [Int] = []
        var previousLine: Int?
        for (index, glyph) in glyphs.enumerated() {
            if let previousLine, glyph.lineID != previousLine {
                raw.append("\n")
                owners.append(-1)
            }
            previousLine = glyph.lineID
            let piece = glyph.text as NSString
            raw.append(glyph.text)
            for _ in 0..<piece.length {
                owners.append(index)
            }
        }
        return (raw as NSString, owners)
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
nonisolated final class PageOCRJob: @unchecked Sendable {
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

/// One OCR result per previewed page, shared by selection and keyword search.
@MainActor
private final class PreviewOCRCache {
    static let shared = PreviewOCRCache()
    static let readyNotification = Notification.Name("mmlmRAGUI.previewOCRReady")

    private var texts: [String: RecognizedPageText] = [:]
    private var running: [String: Task<RecognizedPageText, Never>] = [:]

    static func key(filename: String, page: Int) -> String {
        "\(filename)\u{1e}\(page)"
    }

    func stored(for key: String) -> RecognizedPageText? {
        texts[key]
    }

    func isLoading(_ key: String) -> Bool {
        running[key] != nil
    }

    func load(key: String, image: NSImage) async -> RecognizedPageText {
        if let stored = texts[key] { return stored }
        if let existing = running[key] {
            return await existing.value
        }
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let task = Task<RecognizedPageText, Never> { @MainActor in
            let recognized: RecognizedPageText
            if let cgImage {
                let job = PageOCRJob(cgImage: cgImage)
                recognized = await Task.detached(priority: .userInitiated) {
                    job.recognize()
                }.value ?? RecognizedPageText(observations: [])
            } else {
                recognized = RecognizedPageText(observations: [])
            }
            self.texts[key] = recognized
            self.running[key] = nil
            NotificationCenter.default.post(name: Self.readyNotification, object: key)
            return recognized
        }
        running[key] = task
        return await task.value
    }
}

/// One cited page, drawn from its bitmap, with text selection on top.
struct SelectablePDFPage: NSViewRepresentable {
    var image: NSImage
    var pdfPage: PDFPage
    var textKey = ""
    var findRanges: [NSRange] = []
    var activeFindRange: NSRange?
    var ocrFindGlyphs = IndexSet()
    var activeOCRFindGlyphs = IndexSet()
    var findReveal: Int = 0
    var caption = ""

    func makeNSView(context: Context) -> SelectablePDFPageView {
        let view = SelectablePDFPageView()
        view.pageImage = image
        view.pdfPage = pdfPage
        view.textKey = textKey
        view.caption = caption
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SelectablePDFPageView, context: Context) {
        nsView.caption = caption
        nsView.textKey = textKey
        nsView.show(image: image, pdfPage: pdfPage)
        nsView.applyFind(
            ranges: findRanges,
            active: activeFindRange,
            ocrGlyphs: ocrFindGlyphs,
            activeOCR: activeOCRFindGlyphs,
            reveal: findReveal
        )
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
    var textKey = ""
    var caption = ""

    private let statusLabel = PassThroughLabel(frame: .zero)
    private var selection: PDFSelection?
    private var anchorPoint: CGPoint?
    private var ocrAnchor: CGPoint?
    private var granularity: SelectionGranularity = .character
    private var dragMode: DragMode = .none
    private var selectionObserver: NSObjectProtocol?
    private var recognitionTask: Task<Void, Never>?
    private var recognizedImage: NSImage?
    private var recognized: RecognizedPageText?
    private var ocrSelection: IndexSet?

    private struct FindHit {
        var range: NSRange
        var selection: PDFSelection
    }

    private var findHits: [FindHit] = []
    private var appliedFindRanges: [NSRange] = []
    private var findHitsPage: PDFPage?
    private var activeFindRange: NSRange?
    private var ocrFindGlyphs = IndexSet()
    private var activeOCRFindGlyphs = IndexSet()
    private var consumedFindReveal = 0
    private var pendingFindReveal = false
    private var cachedPictures: [PagePicture]?
    private var cachedPicturesPage: PDFPage?

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
        statusLabel.stringValue = UICopy.resolve("Recognizing text…")
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
            cachedPictures = nil
            cachedPicturesPage = nil
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
        guard pendingFindReveal, bounds.width > 1, bounds.height > 1 else { return }
        pendingFindReveal = false
        scrollActiveFindIntoView()
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
        drawOCRFindHighlights()
        drawFindHighlights()
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
        let copyItem = NSMenuItem(title: UICopy.resolve("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let selectAllItem = NSMenuItem(title: UICopy.resolve("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        appendPictureItems(to: menu)
        return menu
    }

    private func appendPictureItems(to menu: NSMenu) {
        let pictures = picturesOnPage()
        guard !pictures.isEmpty else { return }
        menu.addItem(.separator())
        if pictures.count == 1 {
            menu.addItem(pictureItem(title: UICopy.resolve("Open Image"), index: 0))
            return
        }
        let parent = NSMenuItem(title: UICopy.resolve("Open Image"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for index in pictures.indices {
            let title = UICopy.fill("Image {number}", ["number": String(index + 1)])
            submenu.addItem(pictureItem(title: title, index: index))
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func pictureItem(title: String, index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openPicture(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: index)
        return item
    }

    @objc func openPicture(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let index = number.intValue
        let pictures = picturesOnPage()
        guard pictures.indices.contains(index), let pdfPage else { return }
        guard let image = PDFPagePictures.render(pictures[index], on: pdfPage) else { return }
        PagePictureWindow.show(image: image, title: pictureWindowTitle(index: index, count: pictures.count))
    }

    private func picturesOnPage() -> [PagePicture] {
        guard let pdfPage else { return [] }
        if cachedPicturesPage === pdfPage, let cachedPictures {
            return cachedPictures
        }
        let found = PDFPagePictures.detect(on: pdfPage)
        cachedPictures = found
        cachedPicturesPage = pdfPage
        return found
    }

    private func pictureWindowTitle(index: Int, count: Int) -> String {
        guard count > 1 else { return caption.isEmpty ? UICopy.resolve("Open Image") : caption }
        let name = UICopy.fill("Image {number}", ["number": String(index + 1)])
        return caption.isEmpty ? name : "\(caption) \u{2014} \(name)"
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

    func applyFind(
        ranges: [NSRange],
        active: NSRange?,
        ocrGlyphs: IndexSet,
        activeOCR: IndexSet,
        reveal: Int
    ) {
        if appliedFindRanges != ranges || findHitsPage !== pdfPage {
            appliedFindRanges = ranges
            findHitsPage = pdfPage
            findHits = ranges.compactMap { range in
                guard let pdfPage, let selection = PDFPageGeometry.selection(on: pdfPage, for: range) else {
                    return nil
                }
                return FindHit(range: range, selection: selection)
            }
            needsDisplay = true
        }
        if activeFindRange != active {
            activeFindRange = active
            needsDisplay = true
        }
        if ocrFindGlyphs != ocrGlyphs || activeOCRFindGlyphs != activeOCR {
            ocrFindGlyphs = ocrGlyphs
            activeOCRFindGlyphs = activeOCR
            needsDisplay = true
        }
        guard reveal != consumedFindReveal else { return }
        consumedFindReveal = reveal
        guard active != nil || !activeOCR.isEmpty else { return }
        scheduleFindReveal()
    }

    private func drawOCRFindHighlights() {
        guard recognized != nil, !ocrFindGlyphs.isEmpty else { return }
        let active = activeOCRFindGlyphs
        let rest = ocrFindGlyphs.subtracting(active)
        NSColor.systemYellow.withAlphaComponent(0.42).setFill()
        for rect in ocrHighlightRects(for: rest) where rect.width > 0 && rect.height > 0 {
            rect.fill()
        }
        NSColor.systemOrange.withAlphaComponent(0.62).setFill()
        for rect in ocrHighlightRects(for: active) where rect.width > 0 && rect.height > 0 {
            rect.fill()
        }
    }

    private func drawFindHighlights() {
        guard let pdfPage, !findHits.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let display = PDFPageGeometry.displayedSize(of: pdfPage)
        guard display.width > 1, display.height > 1, bounds.width > 1, bounds.height > 1 else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / display.width, y: bounds.height / display.height)
        context.concatenate(pdfPage.transform(for: PDFPageGeometry.box))
        for hit in findHits where hit.range != activeFindRange {
            fill(hit.selection, on: pdfPage, color: NSColor.systemYellow.withAlphaComponent(0.42), context: context)
        }
        if let activeFindRange, let active = findHits.first(where: { $0.range == activeFindRange }) {
            fill(active.selection, on: pdfPage, color: NSColor.systemOrange.withAlphaComponent(0.62), context: context)
        }
        context.restoreGState()
    }

    private func fill(_ selection: PDFSelection, on page: PDFPage, color: NSColor, context: CGContext) {
        color.setFill()
        let lines = selection.selectionsByLine()
        let rects = lines.isEmpty ? [selection.bounds(for: page)] : lines.map { $0.bounds(for: page) }
        for rect in rects where rect.width > 0 && rect.height > 0 {
            context.fill(rect)
        }
    }

    private func scheduleFindReveal() {
        if bounds.width > 1, bounds.height > 1 {
            DispatchQueue.main.async { [weak self] in
                self?.scrollActiveFindIntoView()
            }
        } else {
            pendingFindReveal = true
            needsLayout = true
        }
    }

    private func scrollActiveFindIntoView() {
        if !activeOCRFindGlyphs.isEmpty {
            guard bounds.width > 1, bounds.height > 1 else {
                pendingFindReveal = true
                needsLayout = true
                return
            }
            let rects = ocrHighlightRects(for: activeOCRFindGlyphs)
            guard !rects.isEmpty else {
                pendingFindReveal = true
                return
            }
            var union = rects[0]
            for rect in rects.dropFirst() {
                union = union.union(rect)
            }
            scrollToVisible(union.insetBy(dx: -32, dy: -64))
            return
        }
        guard let activeFindRange,
              let hit = findHits.first(where: { $0.range == activeFindRange }) else { return }
        guard bounds.width > 1, bounds.height > 1 else {
            pendingFindReveal = true
            needsLayout = true
            return
        }
        let rects = viewRects(for: hit.selection)
        guard !rects.isEmpty else { return }
        var union = rects[0]
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        scrollToVisible(union.insetBy(dx: -32, dy: -64))
    }

    private func pageToViewTransform() -> CGAffineTransform? {
        guard let pdfPage else { return nil }
        let display = PDFPageGeometry.displayedSize(of: pdfPage)
        guard display.width > 1, display.height > 1, bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = CGAffineTransform(scaleX: bounds.width / display.width, y: bounds.height / display.height)
        let move = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
        return pdfPage.transform(for: PDFPageGeometry.box).concatenating(scale).concatenating(move)
    }

    private func viewRects(for selection: PDFSelection) -> [CGRect] {
        guard let pdfPage, let transform = pageToViewTransform() else { return [] }
        let lines = selection.selectionsByLine()
        let pieces = lines.isEmpty ? [selection] : lines
        return pieces.compactMap { piece in
            let rect = piece.bounds(for: pdfPage).applying(transform)
            guard rect.width > 0.5, rect.height > 0.5, rect.isNull == false, rect.isInfinite == false else { return nil }
            return rect
        }
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
        if usesOCRSelection, let ocrSelection {
            let color = selectionColor
            color.setFill()
            for rect in ocrHighlightRects(for: ocrSelection) where rect.width > 0 && rect.height > 0 {
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
        let key = textKey
        if recognizedImage === image, recognized != nil || recognitionTask != nil {
            return
        }
        if !key.isEmpty, let cached = PreviewOCRCache.shared.stored(for: key) {
            recognitionTask?.cancel()
            recognitionTask = nil
            recognizedImage = image
            applyOCR(cached)
            return
        }
        recognitionTask?.cancel()
        recognized = nil
        ocrSelection = nil
        recognizedImage = image
        statusLabel.stringValue = UICopy.resolve("Recognizing text…")
        statusLabel.isHidden = false
        needsLayout = true
        needsDisplay = true
        guard !key.isEmpty else {
            statusLabel.stringValue = UICopy.resolve("No text recognized on this page.")
            return
        }
        let token = image
        recognitionTask = Task { @MainActor [weak self] in
            let text = await PreviewOCRCache.shared.load(key: key, image: image)
            guard let self, !Task.isCancelled, self.recognizedImage === token, self.textKey == key else { return }
            self.applyOCR(text)
        }
    }

    private func stopOCR() {
        recognitionTask?.cancel()
        recognitionTask = nil
        let showingStatus = !statusLabel.isHidden
        statusLabel.isHidden = true
        guard recognized != nil || ocrSelection != nil || recognizedImage != nil || showingStatus else { return }
        recognized = nil
        recognizedImage = nil
        ocrSelection = nil
        needsDisplay = true
    }

    private func applyOCR(_ text: RecognizedPageText?) {
        let transcript = text?.text(in: IndexSet(integersIn: text?.glyphs.indices ?? 0..<0))
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if transcript.isEmpty {
            recognized = text
            statusLabel.stringValue = UICopy.resolve("No text recognized on this page.")
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

    private func ocrHighlightRects(for indexes: IndexSet) -> [CGRect] {
        guard let recognized else { return [] }
        var rects: [CGRect] = []
        var current: CGRect?
        var currentLine: Int?
        var previousIndex: Int?
        for index in indexes where recognized.glyphs.indices.contains(index) {
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

    @State private var findQuery = ""
    @State private var findMatches: [PreviewTextMatch] = []
    @State private var findIndex = 0
    @State private var findReveal = 0
    @State private var activeFindCenter: CGFloat?
    @State private var findOCRPending = false
    @State private var findOCRWaiters: Set<String> = []
    /// Pages whose views exist. `scrollTo` a hit inside a page only after that page has been built.
    @State private var materializedPages = MaterializedPageAnchors()

    private final class MaterializedPageAnchors {
        var anchors: Set<String> = []
    }

    private var loadKey: String {
        let pages = CitationPages.orderedPages(in: answer, order: .source)
        return pages.map(\.id).joined(separator: "\u{1e}") + "\u{1f}" + workingDirectory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.groups.isEmpty {
                findBar
            }
            HStack {
                Spacer(minLength: 0)
                Picker(ui("Sort"), selection: $model.pageOrder) {
                    ForEach(CitationPageOrder.allCases) { order in
                        Text(ui(order.title)).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(ui("Choose how document pages are sorted"))
            }

            Group {
                if model.isLoading, model.groups.isEmpty, model.notice == nil {
                    ProgressView(ui("Loading document pages…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let notice = model.notice, model.groups.isEmpty {
                    ContentUnavailableView(
                        ui("Can't preview"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(notice)
                    )
                } else if model.groups.isEmpty {
                    ContentUnavailableView(
                        ui("No document pages yet"),
                        systemImage: "doc.richtext",
                        description: Text(emptyPageDescription)
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(previewRows) { row in
                                    previewRow(row)
                                        .id(row.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: findReveal, initial: true) { _, _ in
                            guard findReveal > 0 else { return }
                            scrollFind(with: proxy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: loadKey) {
            await model.load(answer: answer, workingDirectory: workingDirectory)
        }
        .onChange(of: findSourceKey, initial: true) { _, _ in
            refreshFind(resetToFirst: false, revealCurrent: false)
        }
        .onChange(of: model.pageOrder) { _, _ in
            refreshFind(resetToFirst: false, revealCurrent: true)
        }
        .onChange(of: findQuery) { _, _ in
            refreshFind(resetToFirst: true, revealCurrent: true)
        }
    }

    private var emptyPageDescription: String {
        switch model.pageOrder {
        case .source:
            ui("Document pages cited in the answer are listed here from top to bottom in answer order.")
        case .pageNumber:
            ui("Document pages cited in the answer are listed here by page number.")
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
                SelectablePDFPage(
                    image: image,
                    pdfPage: pdfPage,
                    textKey: PreviewOCRCache.key(filename: filename, page: pageNumber),
                    findRanges: findRanges(filename: filename, pageNumber: pageNumber),
                    activeFindRange: activeFindRange(filename: filename, pageNumber: pageNumber),
                    ocrFindGlyphs: ocrFindGlyphs(filename: filename, pageNumber: pageNumber),
                    activeOCRFindGlyphs: activeOCRFindGlyphs(filename: filename, pageNumber: pageNumber),
                    findReveal: findReveal,
                    caption: ui("{filename} page {page}", ["filename": filename, "page": String(pageNumber)])
                )
                .help(ui("Drag to select text, then press ⌘C to copy. Scanned pages are recognized first."))
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
        .background {
            findAnchor(filename: filename, pageNumber: pageNumber)
        }
        .accessibilityLabel(ui("{filename} page {page}", ["filename": filename, "page": String(pageNumber)]))
    }

    /// One lazy row. A page id has to sit on the row itself: an id nested inside a
    /// file section does not exist until that section has been built, so next/previous
    /// cannot reach a later file while an earlier file is on screen.
    private enum PreviewRow: Identifiable {
        case loading
        case header(CitedDocument)
        case page(filename: String, page: RenderedPage)

        var id: String {
            switch self {
            case .loading:
                "preview-loading"
            case .header(let group):
                "preview-file:\(group.filename)"
            case .page(let filename, let page):
                PreviewTextMatch.pageAnchor(filename: filename, page: page.page)
            }
        }
    }

    private var previewRows: [PreviewRow] {
        var rows: [PreviewRow] = []
        if model.isLoading {
            rows.append(.loading)
        }
        for group in model.groups {
            rows.append(.header(group))
            for page in displayedPages(in: group) {
                rows.append(.page(filename: group.filename, page: page))
            }
        }
        return rows
    }

    @ViewBuilder
    private func previewRow(_ row: PreviewRow) -> some View {
        switch row {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(ui("Loading document pages…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .header(let group):
            fileHeader(group, addsTopGap: group.filename != model.groups.first?.filename)
        case .page(let filename, let page):
            pageRow(filename: filename, page: page)
        }
    }

    private func fileHeader(_ group: CitedDocument, addsTopGap: Bool) -> some View {
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
        }
        .padding(.top, addsTopGap ? 12 : 0)
    }

    private func pageRow(filename: String, page: RenderedPage) -> some View {
        let anchor = PreviewTextMatch.pageAnchor(filename: filename, page: page.page)
        return VStack(alignment: .leading, spacing: 6) {
            Text("p.\(page.page)")
                .font(.subheadline.weight(.semibold))
            if let image = page.image {
                pagePreview(image: image, pdfPage: page.pdfPage, filename: filename, pageNumber: page.page)
            } else if let problem = page.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            materializedPages.anchors.insert(anchor)
        }
        .onDisappear {
            materializedPages.anchors.remove(anchor)
        }
    }

    private var trimmedFindQuery: String {
        findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var findSourceKey: String {
        model.groups.map { group in
            let pages = group.pages.map { "\($0.page):\($0.pdfPage == nil ? 0 : 1)" }.joined(separator: ",")
            return "\(group.filename)|\(pages)"
        }.joined(separator: "\u{1e}")
    }

    private var currentFindMatch: PreviewTextMatch? {
        guard findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex]
    }

    private var findStatusAccessibility: String {
        if findMatches.isEmpty {
            return findOCRPending ? ui("Recognizing") : ui("No matches")
        }
        let values = [
            "index": String(findIndex + 1),
            "total": String(findMatches.count),
        ]
        if findOCRPending {
            return ui("Match {index} of {total}, recognizing", values)
        }
        return ui("Match {index} of {total}", values)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            findField
            findStatusLabel
            findStepButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.16))
        }
        .help(ui("Search selectable text on the preview pages. Return or ⌘G for the next match, ⇧⌘G for the previous. Scanned pages are recognized first."))
    }

    private var findField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(ui("Search the text layer"), text: $findQuery)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(ui("Search the text layer"))
                .onSubmit { stepFind(1) }
                .onKeyPress(.escape) {
                    guard !findQuery.isEmpty else { return .ignored }
                    findQuery = ""
                    return .handled
                }
            if !findQuery.isEmpty {
                Button {
                    findQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ui("Clear search"))
            }
        }
    }

    @ViewBuilder
    private var findStatusLabel: some View {
        if !trimmedFindQuery.isEmpty {
            HStack(spacing: 4) {
                if findOCRPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(findMatches.isEmpty ? (findOCRPending ? ui("Recognizing") : ui("No matches")) : "\(findIndex + 1) / \(findMatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(findStatusAccessibility)
            }
        }
    }

    private var findStepButtons: some View {
        HStack(spacing: 2) {
            findStepButton(
                systemName: "chevron.up",
                label: ui("Previous"),
                delta: -1,
                shortcut: "g",
                modifiers: [.command, .shift]
            )
            findStepButton(
                systemName: "chevron.down",
                label: ui("Next"),
                delta: 1,
                shortcut: "g",
                modifiers: [.command]
            )
        }
    }

    private func findStepButton(
        systemName: String,
        label: String,
        delta: Int,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers
    ) -> some View {
        Button {
            stepFind(delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(findMatches.isEmpty)
        .accessibilityLabel(label)
        .keyboardShortcut(shortcut, modifiers: modifiers)
        .help(label)
    }

    private func findRanges(filename: String, pageNumber: Int) -> [NSRange] {
        findMatches.compactMap { match in
            guard match.source == .pdf, match.filename == filename, match.pageNumber == pageNumber else { return nil }
            return match.range
        }
    }

    private func activeFindRange(filename: String, pageNumber: Int) -> NSRange? {
        guard let match = currentFindMatch,
              match.source == .pdf,
              match.filename == filename,
              match.pageNumber == pageNumber else { return nil }
        return match.range
    }

    private func ocrFindGlyphs(filename: String, pageNumber: Int) -> IndexSet {
        var glyphs = IndexSet()
        for match in findMatches where match.source == .ocr && match.filename == filename && match.pageNumber == pageNumber {
            glyphs.formUnion(match.ocrGlyphs)
        }
        return glyphs
    }

    private func activeOCRFindGlyphs(filename: String, pageNumber: Int) -> IndexSet {
        guard let match = currentFindMatch,
              match.source == .ocr,
              match.filename == filename,
              match.pageNumber == pageNumber else { return IndexSet() }
        return match.ocrGlyphs
    }

    @ViewBuilder
    private func findAnchor(filename: String, pageNumber: Int) -> some View {
        if let match = currentFindMatch,
           match.filename == filename,
           match.pageNumber == pageNumber,
           let fraction = activeFindCenter {
            GeometryReader { geo in
                let offset = min(max(fraction, 0), 1) * geo.size.height
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: max(0, offset - 4))
                    Color.clear
                        .frame(height: 8)
                        .id(match.id)
                    Spacer(minLength: 0)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func refreshFind(resetToFirst: Bool, revealCurrent: Bool) {
        findOCRPending = trimmedFindQuery.isEmpty ? false : noteMissingOCR()
        let previousID = currentFindMatch?.id
        let next = PreviewTextSearch.matches(in: model.groups, query: findQuery, order: model.pageOrder)
        findMatches = next
        guard !next.isEmpty else {
            findIndex = 0
            activeFindCenter = nil
            return
        }
        let newIndex: Int
        if !resetToFirst, let previousID, let index = next.firstIndex(where: { $0.id == previousID }) {
            newIndex = index
        } else {
            newIndex = 0
        }
        let changed = previousID != next[newIndex].id
        findIndex = newIndex
        syncActiveFindCenter()
        if revealCurrent || changed {
            findReveal += 1
        }
    }

    /// Starts recognition for cited pages PDFKit cannot read, and reports whether any are still outstanding.
    private func noteMissingOCR() -> Bool {
        var missing = false
        for group in model.groups {
            for page in group.pages {
                guard let pdfPage = page.pdfPage, let image = page.image else { continue }
                guard PreviewTextSearch.pdfText(of: pdfPage) == nil else { continue }
                let key = PreviewOCRCache.key(filename: group.filename, page: page.page)
                if PreviewOCRCache.shared.stored(for: key) != nil { continue }
                missing = true
                guard !findOCRWaiters.contains(key) else { continue }
                findOCRWaiters.insert(key)
                Task { @MainActor in
                    _ = await PreviewOCRCache.shared.load(key: key, image: image)
                    findOCRWaiters.remove(key)
                    refreshFind(resetToFirst: false, revealCurrent: false)
                }
            }
        }
        return missing
    }

    private func stepFind(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findIndex = (findIndex + delta + count) % count
        syncActiveFindCenter()
        findReveal += 1
    }

    private func syncActiveFindCenter() {
        guard let match = currentFindMatch else {
            activeFindCenter = nil
            return
        }
        activeFindCenter = PreviewTextSearch.centerFromTop(of: match, in: model.groups)
    }

    private func scrollFind(with proxy: ScrollViewProxy) {
        guard let match = currentFindMatch else { return }
        let ticket = findReveal
        let pageID = match.pageAnchor
        let matchID = match.id
        let pages = materializedPages
        if pages.anchors.contains(pageID) {
            proxy.scrollTo(matchID, anchor: .center)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard ticket == findReveal else { return }
                proxy.scrollTo(matchID, anchor: .center)
            }
            return
        }
        proxy.scrollTo(pageID, anchor: .center)
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard ticket == findReveal else { return }
                if pages.anchors.contains(pageID) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard ticket == findReveal else { return }
                    proxy.scrollTo(matchID, anchor: .center)
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard ticket == findReveal else { return }
                    proxy.scrollTo(matchID, anchor: .center)
                    return
                }
                proxy.scrollTo(pageID, anchor: .center)
            }
        }
    }
}

#endif
