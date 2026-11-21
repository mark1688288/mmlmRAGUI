import AppKit
import PDFKit
import Vision

#if os(macOS)

/// One picture a person can see on a PDF page.
///
/// Publishers often slice a figure into horizontal strips. Those strips are joined
/// here, so the page menu offers the figure once.
struct PagePicture: Equatable {
    /// Bounds in PDF page space, the same space as `PDFPage.bounds(for: .cropBox)`.
    var bounds: CGRect
    /// Sharpest source image in the group, in pixels per drawn point.
    var pixelsPerPoint: CGFloat
}

enum PDFPagePictures {
    /// Pictures large enough to open, top to bottom then left to right.
    /// A figure painted as its own image is returned directly. A scanned page is one
    /// image of the whole page, so the figure inside it is found from that bitmap.
    static func detect(on page: PDFPage) -> [PagePicture] {
        guard let cgPage = page.pageRef, let scanner = PictureScanner() else { return [] }
        let placed = scanner.placedImages(on: cgPage)
        let pictures = cluster(placed, on: page)
        if !pictures.isEmpty { return pictures }
        guard let density = placed.lazy.filter({ isFullPage($0, on: page) }).map(\.pixelsPerPoint).max() else {
            return []
        }
        return figuresInScan(on: page, pixelsPerPoint: density)
    }

    /// Renders `picture` from the page, capped so the long side stays near 4096 pixels.
    static func render(_ picture: PagePicture, on page: PDFPage) -> NSImage? {
        let crop = page.bounds(for: .cropBox)
        let visible = picture.bounds.insetBy(dx: -0.5, dy: -0.5).intersection(crop)
        guard visible.width > 1, visible.height > 1 else { return nil }
        let longest = max(visible.width, visible.height)
        let wanted = max(picture.pixelsPerPoint, 2)
        let scale = min(wanted, 4096 / longest)
        guard scale > 0 else { return nil }

        let displayRect = visible.applying(page.transform(for: .cropBox))
        let pixelWidth = max(1, Int((displayRect.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((displayRect.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -displayRect.minX, y: -displayRect.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cluster(_ placed: [PlacedImage], on page: PDFPage) -> [PagePicture] {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 1, crop.height > 1 else { return [] }
        let gap = PictureLimits.gap
        var remaining = placed
        var pictures: [PagePicture] = []
        while !remaining.isEmpty {
            var group = [remaining.removeFirst()]
            var grew = true
            while grew {
                grew = false
                var index = 0
                while index < remaining.count {
                    let candidate = remaining[index].bounds.insetBy(dx: -gap, dy: -gap)
                    let touches = group.contains { item in
                        item.bounds.insetBy(dx: -gap, dy: -gap).intersects(candidate)
                    }
                    if touches {
                        group.append(remaining.remove(at: index))
                        grew = true
                    } else {
                        index += 1
                    }
                }
            }
            guard let first = group.first else { continue }
            let union = group.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
            let visible = union.intersection(crop)
            guard visible.width >= PictureLimits.minimumSide,
                  visible.height >= PictureLimits.minimumSide else { continue }
            if visible.width >= crop.width * PictureLimits.fullPageFraction,
               visible.height >= crop.height * PictureLimits.fullPageFraction {
                continue
            }
            let density = group.map(\.pixelsPerPoint).max() ?? 2
            pictures.append(PagePicture(bounds: visible, pixelsPerPoint: density))
        }
        pictures.sort(by: readingOrder)
        if pictures.count > PictureLimits.menuCap {
            pictures = pictures
                .sorted { area($0) > area($1) }
                .prefix(PictureLimits.menuCap)
                .sorted(by: readingOrder)
        }
        return pictures
    }

    nonisolated private static func readingOrder(_ lhs: PagePicture, _ rhs: PagePicture) -> Bool {
        if abs(lhs.bounds.maxY - rhs.bounds.maxY) > 8 {
            return lhs.bounds.maxY > rhs.bounds.maxY
        }
        return lhs.bounds.minX < rhs.bounds.minX
    }

    nonisolated private static func area(_ picture: PagePicture) -> CGFloat {
        picture.bounds.width * picture.bounds.height
    }

    private static func isFullPage(_ image: PlacedImage, on page: PDFPage) -> Bool {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 1, crop.height > 1 else { return false }
        let visible = image.bounds.intersection(crop)
        return visible.width >= crop.width * PictureLimits.fullPageFraction
            && visible.height >= crop.height * PictureLimits.fullPageFraction
    }

    /// Rectangle edges in the scan, widened across the ink of that same band.
    private static func figuresInScan(on page: PDFPage, pixelsPerPoint: CGFloat) -> [PagePicture] {
        let displayed = PDFPageGeometry.displayedSize(of: page)
        guard displayed.width > 1, displayed.height > 1 else { return [] }
        let scale = ScanFigure.pixelWidth / displayed.width
        let pixelWidth = Int((displayed.width * scale).rounded())
        let pixelHeight = Int((displayed.height * scale).rounded())
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), context.data != nil else { return [] }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        guard let cgImage = context.makeImage(), let bytes = context.data else { return [] }

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.1
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.08
        rectangles.maximumObservations = 10
        rectangles.quadratureTolerance = 30
        rectangles.minimumConfidence = 0.45
        let text = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([rectangles, text])
        let lines = (text.results ?? []).map(\.boundingBox)
        let seeds = (rectangles.results ?? []).filter { $0.confidence >= 0.9 }.map(\.boundingBox).filter { seed in
            seed.height >= ScanFigure.minimumHeight
                && seed.height <= ScanFigure.maximumHeight
                && seed.width >= 0.06
                && seed.width <= 0.9
        }
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: pixelWidth * pixelHeight * 4)
        var grown: [CGRect] = []
        for seed in seeds {
            guard let widened = widen(seed, pixels: pixels, width: pixelWidth, height: pixelHeight) else { continue }
            guard widened.width >= ScanFigure.minimumWidth,
                  widened.height >= ScanFigure.minimumHeight,
                  widened.height <= ScanFigure.maximumHeight else { continue }
            let area = widened.width * widened.height
            guard area > 0 else { continue }
            let covered = lines.reduce(CGFloat.zero) { partial, line in
                let hit = line.intersection(widened)
                guard !hit.isNull, hit.width > 0, hit.height > 0 else { return partial }
                return partial + hit.width * hit.height
            }
            guard covered / area <= ScanFigure.maximumTextCoverage else { continue }
            grown.append(widened.insetBy(dx: -0.012, dy: -0.008))
        }
        let merged = merge(grown).filter { rect in
            rect.width >= ScanFigure.minimumWidth
                && rect.height >= ScanFigure.minimumHeight
                && rect.height <= ScanFigure.maximumHeight
                && rect.width <= 0.94
        }
        return merged.map { normalized in
            PagePicture(
                bounds: pageBounds(of: normalized, on: page),
                pixelsPerPoint: pixelsPerPoint
            )
        }.sorted(by: readingOrder)
    }

    /// Extends a rectangle sideways through ink in its vertical band, bridging short gaps.
    private static func widen(
        _ seed: CGRect,
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int
    ) -> CGRect? {
        let columns = ScanFigure.columns
        let y0 = max(0, Int(seed.minY * CGFloat(height)))
        let y1 = min(height, max(y0 + 1, Int(seed.maxY * CGFloat(height))))
        var hot = Array(repeating: false, count: columns)
        for column in 0..<columns {
            let x0 = column * width / columns
            let x1 = max(x0 + 1, (column + 1) * width / columns)
            var hits = 0
            var samples = 0
            var y = y0
            while y < y1 {
                var x = x0
                while x < min(width, x1) {
                    let offset = (y * width + x) * 4
                    let sum = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                    if sum < ScanFigure.inkSum { hits += 1 }
                    samples += 1
                    x += 3
                }
                y += 3
            }
            hot[column] = samples > 0 && Double(hits) / Double(samples) > ScanFigure.columnInk
        }
        let seedStart = max(0, min(columns - 1, Int(seed.minX * CGFloat(columns))))
        let seedEnd = max(seedStart, min(columns - 1, Int(seed.maxX * CGFloat(columns))))
        guard let anchor = (seedStart...seedEnd).first(where: { hot[$0] }) else { return nil }
        var left = anchor
        var right = anchor
        var gap = 0
        var column = anchor
        while column >= 0 {
            if hot[column] {
                left = column
                gap = 0
            } else {
                gap += 1
                if gap > ScanFigure.bridge { break }
            }
            column -= 1
        }
        gap = 0
        column = anchor
        while column < columns {
            if hot[column] {
                right = column
                gap = 0
            } else {
                gap += 1
                if gap > ScanFigure.bridge { break }
            }
            column += 1
        }
        return CGRect(
            x: CGFloat(left) / CGFloat(columns),
            y: seed.minY,
            width: CGFloat(right - left + 1) / CGFloat(columns),
            height: seed.height
        )
    }

    private static func merge(_ rects: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for rect in rects.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let padded = rect.insetBy(dx: -0.02, dy: -0.02)
            if let index = merged.firstIndex(where: { $0.intersects(padded) }) {
                merged[index] = merged[index].union(rect)
            } else {
                merged.append(rect)
            }
        }
        return merged
    }

    /// `normalized` uses the upright page image, origin at the bottom left.
    private static func pageBounds(of normalized: CGRect, on page: PDFPage) -> CGRect {
        let displayed = PDFPageGeometry.displayedSize(of: page)
        let displayRect = CGRect(
            x: normalized.minX * displayed.width,
            y: normalized.minY * displayed.height,
            width: normalized.width * displayed.width,
            height: normalized.height * displayed.height
        )
        let transform = page.transform(for: .cropBox)
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 0.000_001 else { return displayRect }
        return displayRect.applying(transform.inverted())
    }
}

/// Scale menu for a picture window. Percentages are of the image's point size.
private enum PictureScale: Equatable {
    case fit
    case percent(Int)

    static let percents = [25, 50, 75, 100, 200]
    static let fitTag = -1
    static let customTag = -2

    /// How close a live magnification has to be before it counts as that menu item.
    private static let matchSlack: CGFloat = 0.008
    /// Ignore float noise when stepping off the current magnification.
    private static let stepSlack: CGFloat = 0.004

    static func step(from magnification: CGFloat, zoomIn: Bool) -> PictureScale? {
        if zoomIn {
            guard let percent = percents.first(where: { CGFloat($0) / 100 > magnification + stepSlack }) else {
                return nil
            }
            return .percent(percent)
        }
        guard let percent = percents.last(where: { CGFloat($0) / 100 < magnification - stepSlack }) else {
            return nil
        }
        return .percent(percent)
    }

    static func matching(magnification: CGFloat) -> PictureScale? {
        for percent in percents where abs(CGFloat(percent) / 100 - magnification) < matchSlack {
            return .percent(percent)
        }
        return nil
    }
}

/// Keeps a picture centered when a zoom level makes it smaller than the scroll view.
private final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// The picture bitmap, with OCR text selection on top.
///
/// Recognition waits until the text tool is used, then the same Vision request as a scanned page.
private final class PictureCanvasView: NSView, NSMenuItemValidation {
    private enum Granularity {
        case character
        case word
        case line
    }

    let image: NSImage
    var onStatus: (String?) -> Void = { _ in }
    private(set) var textTool = false

    private var recognized: RecognizedPageText?
    private var selection: IndexSet?
    private var anchor: CGPoint?
    private var granularity: Granularity = .character
    private var recognitionTask: Task<Void, Never>?
    private var job: PageOCRJob?
    private var didRequestOCR = false
    private var statusEnglish: String?

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        job?.cancel()
        recognitionTask?.cancel()
    }

    func activateTextTool() {
        textTool = true
        window?.makeFirstResponder(self)
        recognizeIfNeeded()
    }

    func deactivateTextTool() {
        textTool = false
    }

    func cancelRecognition() {
        job?.cancel()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    func refreshCopy() {
        guard let statusEnglish else {
            onStatus(nil)
            return
        }
        onStatus(UICopy.resolve(statusEnglish))
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard textTool else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.intersection(bounds).fill()
        image.draw(in: bounds)
        drawSelection()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard textTool, let recognized, !recognized.isEmpty else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        anchor = viewPoint
        switch event.clickCount {
        case 2:
            granularity = .word
            store(indexes(at: viewPoint, granularity: .word))
        case 3...:
            granularity = .line
            store(indexes(at: viewPoint, granularity: .line))
        default:
            granularity = .character
            store(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard textTool, granularity == .character, recognized != nil, let anchor else { return }
        autoscroll(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let rect = normalizedRect(from: anchor, to: viewPoint) else { return }
        store(recognized?.indexes(intersecting: rect))
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: UICopy.resolve("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let selectAllItem = NSMenuItem(title: UICopy.resolve("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return clipboardText != nil
        case #selector(selectAll(_:)):
            return recognized?.isEmpty == false
        default:
            return true
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = clipboardText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let recognized, !recognized.isEmpty else { return }
        store(IndexSet(integersIn: recognized.glyphs.indices))
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

    private func recognizeIfNeeded() {
        guard !didRequestOCR else { return }
        didRequestOCR = true
        showStatus("Recognizing text…")
        let source = image
        recognitionTask = Task { @MainActor [weak self] in
            let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let recognized: RecognizedPageText
            if let cgImage {
                let job = PageOCRJob(cgImage: cgImage)
                self?.job = job
                recognized = await Task.detached(priority: .userInitiated) {
                    job.recognize() ?? RecognizedPageText(observations: [])
                }.value
            } else {
                recognized = RecognizedPageText(observations: [])
            }
            guard let self, !Task.isCancelled else { return }
            self.job = nil
            self.recognized = recognized
            let transcript = recognized.text(in: IndexSet(integersIn: recognized.glyphs.indices))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.showStatus(transcript.isEmpty ? "No text recognized on this picture." : nil)
            self.needsDisplay = true
        }
    }

    private func showStatus(_ english: String?) {
        statusEnglish = english
        guard let english else {
            onStatus(nil)
            return
        }
        onStatus(UICopy.resolve(english))
    }

    private var clipboardText: String? {
        guard let recognized, let selection, !selection.isEmpty else { return nil }
        let text = recognized.text(in: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func store(_ indexes: IndexSet?) {
        guard let recognized, let indexes, !indexes.isEmpty else {
            if selection != nil {
                selection = nil
                needsDisplay = true
            }
            return
        }
        let text = recognized.text(in: indexes)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selection = nil
            needsDisplay = true
            return
        }
        selection = indexes
        needsDisplay = true
    }

    private func indexes(at viewPoint: CGPoint, granularity: Granularity) -> IndexSet? {
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

    private func highlightRects(for indexes: IndexSet) -> [CGRect] {
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

    private func drawSelection() {
        guard let selection else { return }
        let focused = window?.firstResponder === self
        let color = focused
            ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
            : NSColor.unemphasizedSelectedTextBackgroundColor.withAlphaComponent(0.45)
        color.setFill()
        for rect in highlightRects(for: selection) where rect.width > 0 && rect.height > 0 {
            rect.fill()
        }
    }
}

/// A status line that stays visible over the picture and does not take clicks.
private final class PictureStatusLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A picture opened from a cited page. It stays its own window, outside the question tabs.
final class PagePictureWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private enum Item {
        static let hand = NSToolbarItem.Identifier("picture.hand")
        static let text = NSToolbarItem.Identifier("picture.text")
        static let zoomOut = NSToolbarItem.Identifier("picture.zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("picture.zoomIn")
        static let scale = NSToolbarItem.Identifier("picture.scale")
        static let pin = NSToolbarItem.Identifier("picture.pin")
    }

    private enum PictureTool {
        case hand
        case text
    }

    private static var openWindows: [PagePictureWindow] = []
    private static let scaleWidth: CGFloat = 104

    private let scrollView: NSScrollView
    private let canvas: PictureCanvasView
    private let statusLabel: PictureStatusLabel
    private let scalePopup: NSPopUpButton
    private let panGesture: NSPanGestureRecognizer
    private var handItem: NSToolbarItem?
    private var textItem: NSToolbarItem?
    private var pinItem: NSToolbarItem?
    private var pinned = false
    private var tool: PictureTool? = .hand
    private var panStart: (origin: NSPoint, window: NSPoint)?
    private var isGrabbing = false
    private var zoomOutItem: NSToolbarItem?
    private var zoomInItem: NSToolbarItem?
    private var scaleItem: NSToolbarItem?
    private weak var customScaleItem: NSMenuItem?
    private var scale: PictureScale = .fit
    private var fittedMagnification: CGFloat = 1
    private var suppressPopup = false
    private var appliedLanguage = AppLanguage.stored()

    static func show(image: NSImage, title: String) {
        let controller = PagePictureWindow(image: image, title: title)
        openWindows.append(controller)
        controller.showWindow(nil)
        controller.apply(.fit)
    }

    private init(image: NSImage, title: String) {
        let canvas = PictureCanvasView(image: image)
        canvas.setAccessibilityLabel(title)

        let status = PictureStatusLabel(frame: .zero)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.drawsBackground = true
        status.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
        status.isBezeled = false
        status.isEditable = false
        status.isSelectable = false
        status.isHidden = true
        status.setAccessibilityElement(false)

        let scroll = NSScrollView()
        scroll.contentView = CenteredClipView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .white
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.documentView = canvas
        scroll.addSubview(status)

        let pan = NSPanGestureRecognizer()
        scroll.contentView.addGestureRecognizer(pan)

        let popup = NSPopUpButton()
        popup.controlSize = .regular
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: Self.scaleWidth).isActive = true

        self.scrollView = scroll
        self.canvas = canvas
        self.statusLabel = status
        self.scalePopup = popup
        self.panGesture = pan

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxSide = NSSize(
            width: min(1100, visible.width * 0.72),
            height: min(860, visible.height * 0.72)
        )
        let fit = min(maxSide.width / max(image.size.width, 1), maxSide.height / max(image.size.height, 1), 1)
        let content = NSSize(
            width: max(280, image.size.width * fit),
            height: max(200, image.size.height * fit)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentMinSize = NSSize(width: 280, height: 200)
        window.contentView = scroll
        super.init(window: window)
        window.delegate = self
        popup.target = self
        popup.action = #selector(scaleChosen(_:))
        pan.target = self
        pan.action = #selector(panPicture(_:))
        canvas.onStatus = { [weak self] text in
            self?.showPictureStatus(text)
        }
        installScaleMenu()
        installToolbar()
        applyCopy()
        showHandCursor()
        observeChanges()
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        if isGrabbing {
            window?.enableCursorRects()
            isGrabbing = false
        }
        canvas.cancelRecognition()
        NotificationCenter.default.removeObserver(self)
        Self.openWindows.removeAll { $0 === self }
    }

    func windowDidResize(_ notification: Notification) {
        if scale == .fit {
            fitToWindow()
            window?.toolbar?.validateVisibleItems()
        }
        placeStatus()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Item.hand:
            let item = zoomItem(
                identifier: itemIdentifier,
                symbol: "hand.raised",
                label: "Hand",
                action: #selector(toggleHand(_:))
            )
            item.style = tool == .hand ? .prominent : .plain
            item.toolTip = UICopy.resolve("Drag to move the picture")
            handItem = item
            return item
        case Item.text:
            let item = zoomItem(
                identifier: itemIdentifier,
                symbol: "character.cursor.ibeam",
                label: "Select Text",
                action: #selector(toggleText(_:))
            )
            item.style = tool == .text ? .prominent : .plain
            item.toolTip = UICopy.resolve("Select text on the picture")
            textItem = item
            return item
        case Item.zoomOut:
            let item = zoomItem(
                identifier: itemIdentifier,
                symbol: "minus.magnifyingglass",
                label: "Zoom Out",
                action: #selector(zoomOut(_:))
            )
            zoomOutItem = item
            return item
        case Item.zoomIn:
            let item = zoomItem(
                identifier: itemIdentifier,
                symbol: "plus.magnifyingglass",
                label: "Zoom In",
                action: #selector(zoomIn(_:))
            )
            zoomInItem = item
            return item
        case Item.pin:
            let item = zoomItem(
                identifier: itemIdentifier,
                symbol: "pin",
                label: "Pin",
                action: #selector(togglePin(_:))
            )
            item.toolTip = UICopy.resolve("Keep the picture in front of other windows")
            pinItem = item
            return item
        case Item.scale:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = scalePopup
            scaleItem = item
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.hand, Item.text, Item.zoomOut, Item.zoomIn, Item.scale, Item.pin]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.hand, Item.text, Item.zoomOut, Item.zoomIn, Item.scale, Item.pin]
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.zoomOut:
            return PictureScale.step(from: displayedMagnification(), zoomIn: false) != nil
        case Item.zoomIn:
            return PictureScale.step(from: displayedMagnification(), zoomIn: true) != nil
        default:
            return true
        }
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "PagePicture-\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Item.hand, Item.text, Item.zoomOut, Item.zoomIn, Item.scale, Item.pin]
        window?.toolbar = toolbar
        window?.toolbarStyle = .expanded
    }

    private func zoomItem(
        identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let title = UICopy.resolve(label)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    private func installScaleMenu() {
        scalePopup.removeAllItems()
        scalePopup.addItem(withTitle: UICopy.resolve("Fit"))
        scalePopup.lastItem?.tag = PictureScale.fitTag
        for percent in PictureScale.percents {
            scalePopup.addItem(withTitle: "\(percent)%")
            scalePopup.lastItem?.tag = percent
        }
        // addItem(withTitle:) removes an existing item with the same title, so a
        // second "100%" would delete the real 100% choice and then hide it.
        let custom = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        custom.tag = PictureScale.customTag
        custom.isHidden = true
        scalePopup.menu?.addItem(custom)
        customScaleItem = custom
        selectPopup(.fit)
    }

    private func applyCopy() {
        let hand = UICopy.resolve("Hand")
        let zoomOut = UICopy.resolve("Zoom Out")
        let zoomIn = UICopy.resolve("Zoom In")
        let zoom = UICopy.resolve("Zoom")
        handItem?.label = hand
        handItem?.paletteLabel = hand
        handItem?.toolTip = UICopy.resolve("Drag to move the picture")
        handItem?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: hand)
        let text = UICopy.resolve("Select Text")
        textItem?.label = text
        textItem?.paletteLabel = text
        textItem?.toolTip = UICopy.resolve("Select text on the picture")
        textItem?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: text)
        canvas.refreshCopy()
        placeStatus()
        zoomOutItem?.label = zoomOut
        zoomOutItem?.paletteLabel = zoomOut
        zoomOutItem?.toolTip = zoomOut
        zoomOutItem?.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: zoomOut)
        zoomInItem?.label = zoomIn
        zoomInItem?.paletteLabel = zoomIn
        zoomInItem?.toolTip = zoomIn
        zoomInItem?.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: zoomIn)
        scaleItem?.label = zoom
        scaleItem?.paletteLabel = zoom
        scaleItem?.toolTip = zoom
        scalePopup.setAccessibilityLabel(zoom)
        scalePopup.menu?.item(withTag: PictureScale.fitTag)?.title = UICopy.resolve("Fit")
        applyPin()
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(magnificationEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    private func apply(_ scale: PictureScale) {
        self.scale = scale
        switch scale {
        case .fit:
            window?.layoutIfNeeded()
            fitToWindow()
        case .percent(let value):
            let fraction = CGFloat(value) / 100
            let bounds = scrollView.contentView.bounds
            if bounds.width > 1, bounds.height > 1 {
                scrollView.setMagnification(
                    fraction,
                    centeredAt: NSPoint(x: bounds.midX, y: bounds.midY)
                )
            } else {
                scrollView.magnification = fraction
            }
        }
        selectPopup(scale)
        window?.toolbar?.validateVisibleItems()
    }

    private func fitToWindow() {
        guard scrollView.bounds.width > 1, scrollView.bounds.height > 1,
              let document = scrollView.documentView else { return }
        scrollView.magnify(toFit: document.bounds)
        fittedMagnification = scrollView.magnification
    }

    private func selectPopup(_ scale: PictureScale) {
        suppressPopup = true
        defer { suppressPopup = false }
        switch scale {
        case .fit:
            customScaleItem?.isHidden = true
            scalePopup.selectItem(withTag: PictureScale.fitTag)
        case .percent(let value) where PictureScale.percents.contains(value):
            customScaleItem?.isHidden = true
            scalePopup.selectItem(withTag: value)
        case .percent(let value):
            customScaleItem?.title = "\(value)%"
            customScaleItem?.isHidden = false
            if let customScaleItem {
                scalePopup.select(customScaleItem)
            }
        }
    }

    private func displayedMagnification() -> CGFloat {
        switch scale {
        case .fit:
            return fittedMagnification
        case .percent(let value):
            return CGFloat(value) / 100
        }
    }

    @objc private func togglePin(_ sender: Any?) {
        pinned.toggle()
        applyPin()
    }

    /// A pinned picture stays above ordinary windows, including after this app is no longer active.
    private func applyPin() {
        window?.level = pinned ? .floating : .normal
        window?.hidesOnDeactivate = false
        let title = UICopy.resolve("Pin")
        pinItem?.label = title
        pinItem?.paletteLabel = title
        pinItem?.toolTip = UICopy.resolve("Keep the picture in front of other windows")
        pinItem?.style = pinned ? .prominent : .plain
        pinItem?.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: title
        )
    }

    @objc private func toggleHand(_ sender: Any?) {
        setTool(tool == .hand ? nil : .hand)
    }

    @objc private func toggleText(_ sender: Any?) {
        setTool(tool == .text ? nil : .text)
    }

    private func setTool(_ tool: PictureTool?) {
        if isGrabbing {
            setGrabbing(false)
            panStart = nil
        }
        self.tool = tool
        panGesture.isEnabled = tool == .hand
        handItem?.style = tool == .hand ? .prominent : .plain
        textItem?.style = tool == .text ? .prominent : .plain
        showHandCursor()
        if tool == .text {
            canvas.activateTextTool()
        } else {
            canvas.deactivateTextTool()
        }
    }

    private func showPictureStatus(_ text: String?) {
        if let text {
            statusLabel.stringValue = text
            statusLabel.isHidden = false
            placeStatus()
        } else {
            statusLabel.isHidden = true
        }
    }

    private func placeStatus() {
        guard !statusLabel.isHidden else { return }
        let fitted = statusLabel.fittingSize
        let size = NSSize(width: fitted.width + 12, height: fitted.height + 4)
        let originY = scrollView.isFlipped
            ? 10
            : scrollView.bounds.height - size.height - 10
        statusLabel.frame = NSRect(x: 10, y: originY, width: size.width, height: size.height)
    }

    /// Grabs the picture: the hand pulls the image with the pointer.
    @objc private func panPicture(_ pan: NSPanGestureRecognizer) {
        guard tool == .hand else { return }
        let clip = scrollView.contentView
        switch pan.state {
        case .began:
            panStart = (clip.bounds.origin, pan.location(in: nil))
            setGrabbing(true)
        case .changed:
            guard let panStart else { return }
            let current = pan.location(in: nil)
            let magnification = max(scrollView.magnification, 0.01)
            let moved = NSPoint(
                x: (current.x - panStart.window.x) / magnification,
                y: (current.y - panStart.window.y) / magnification
            )
            scrollView.scroll(
                clip,
                to: NSPoint(x: panStart.origin.x - moved.x, y: panStart.origin.y - moved.y)
            )
            scrollView.reflectScrolledClipView(clip)
        case .ended, .cancelled, .failed:
            panStart = nil
            setGrabbing(false)
        default:
            break
        }
    }

    private func showHandCursor() {
        let cursor: NSCursor? = switch tool {
        case .hand: .openHand
        case .text: .iBeam
        case nil: nil
        }
        scrollView.contentView.documentCursor = cursor
        window?.invalidateCursorRects(for: scrollView.contentView)
    }

    private func setGrabbing(_ grabbing: Bool) {
        guard grabbing != isGrabbing, let window else {
            isGrabbing = grabbing
            return
        }
        isGrabbing = grabbing
        if grabbing {
            window.disableCursorRects()
            NSCursor.closedHand.set()
        } else {
            window.enableCursorRects()
            window.invalidateCursorRects(for: scrollView.contentView)
        }
    }

    @objc private func zoomOut(_ sender: Any?) {
        guard let next = PictureScale.step(from: displayedMagnification(), zoomIn: false) else { return }
        apply(next)
    }

    @objc private func zoomIn(_ sender: Any?) {
        guard let next = PictureScale.step(from: displayedMagnification(), zoomIn: true) else { return }
        apply(next)
    }

    @objc private func scaleChosen(_ sender: NSPopUpButton) {
        guard !suppressPopup, let item = sender.selectedItem else { return }
        if item.tag == PictureScale.fitTag {
            apply(.fit)
        } else if PictureScale.percents.contains(item.tag) {
            apply(.percent(item.tag))
        }
    }

    @objc private func magnificationEnded(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView, scroll === scrollView else { return }
        if let match = PictureScale.matching(magnification: scroll.magnification) {
            scale = match
        } else {
            scale = .percent(Int((scroll.magnification * 100).rounded()))
        }
        selectPopup(scale)
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func defaultsChanged(_ notification: Notification) {
        let language = AppLanguage.stored()
        guard language != appliedLanguage else { return }
        appliedLanguage = language
        applyCopy()
    }
}

private enum PictureLimits {
    static let gap: CGFloat = 1.5
    static let minimumSide: CGFloat = 48
    static let fullPageFraction: CGFloat = 0.92
    static let menuCap = 16
}

/// Tuned on IC-Report-Volume1_tc.pdf p.308, a scan whose map is not its own image.
private enum ScanFigure {
    static let pixelWidth: CGFloat = 1000
    static let columns = 100
    static let minimumHeight: CGFloat = 0.12
    static let maximumHeight: CGFloat = 0.45
    static let minimumWidth: CGFloat = 0.20
    static let maximumTextCoverage: CGFloat = 0.18
    static let columnInk = 0.035
    static let inkSum = 680
    static let bridge = 4
}

private struct PlacedImage {
    var bounds: CGRect
    var pixelsPerPoint: CGFloat
}

/// Walks a page content stream. `Do` paints an image in the unit square under the current matrix.
private final class PictureScanner {
    private var stack: [CGAffineTransform] = [.identity]
    private var streams: [CGPDFContentStreamRef] = []
    private var owned: [CGPDFContentStreamRef] = []
    private var placed: [PlacedImage] = []
    private var depth = 0
    private var pageResources: CGPDFDictionaryRef?
    private let table: CGPDFOperatorTableRef

    private var ctm: CGAffineTransform { stack.last ?? .identity }

    init?() {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        self.table = table
        CGPDFOperatorTableSetCallback(table, "q") { _, raw in
            guard let raw else { return }
            Unmanaged<PictureScanner>.fromOpaque(raw).takeUnretainedValue().save()
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, raw in
            guard let raw else { return }
            Unmanaged<PictureScanner>.fromOpaque(raw).takeUnretainedValue().restore()
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, raw in
            guard let raw else { return }
            Unmanaged<PictureScanner>.fromOpaque(raw).takeUnretainedValue().concat(scanner)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, raw in
            guard let raw else { return }
            Unmanaged<PictureScanner>.fromOpaque(raw).takeUnretainedValue().paint(scanner)
        }
    }

    deinit {
        for stream in owned {
            CGPDFContentStreamRelease(stream)
        }
        CGPDFOperatorTableRelease(table)
    }

    func placedImages(on page: CGPDFPage) -> [PlacedImage] {
        if let dictionary = page.dictionary {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources) {
                pageResources = resources
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        owned.append(stream)
        scan(stream)
        return placed
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 8 else { return }
        depth += 1
        streams.append(stream)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        streams.removeLast()
        depth -= 1
    }

    private func save() {
        stack.append(ctm)
    }

    private func restore() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    private func concat(_ scanner: CGPDFScannerRef) {
        guard !stack.isEmpty else { return }
        var values = [CGPDFReal](repeating: 0, count: 6)
        for index in stride(from: 5, through: 0, by: -1) {
            guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
        }
        let matrix = CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]
        )
        stack[stack.count - 1] = matrix.concatenating(ctm)
    }

    private func paint(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name, let content = streams.last else { return }
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        switch subtype(of: dictionary) {
        case "Image":
            recordImage(dictionary)
        case "Form":
            paintForm(stream, dictionary: dictionary)
        default:
            break
        }
    }

    private func recordImage(_ dictionary: CGPDFDictionaryRef) {
        var mask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask), mask != 0 { return }
        guard let pixelWidth = number(dictionary, "Width"),
              let pixelHeight = number(dictionary, "Height"),
              pixelWidth >= 2, pixelHeight >= 2 else { return }
        let bounds = unitSquareBounds()
        guard bounds.width > 0.5, bounds.height > 0.5 else { return }
        let density = max(pixelWidth / bounds.width, pixelHeight / bounds.height)
        placed.append(PlacedImage(bounds: bounds, pixelsPerPoint: density))
    }

    private func paintForm(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) {
        let resources = formResources(dictionary)
        guard let resources, let parent = streams.last else { return }
        let saved = stack.count
        stack.append(matrix(in: dictionary).concatenating(ctm))
        let child = CGPDFContentStreamCreateWithStream(stream, resources, parent)
        owned.append(child)
        scan(child)
        while stack.count > saved {
            stack.removeLast()
        }
    }

    private func formResources(_ dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
            return resources
        }
        return pageResources
    }

    private func matrix(in dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array,
              CGPDFArrayGetCount(array) == 6 else { return .identity }
        var values = [CGPDFReal](repeating: 0, count: 6)
        for index in 0..<6 {
            guard CGPDFArrayGetNumber(array, index, &values[index]) else { return .identity }
        }
        return CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]
        )
    }

    private func unitSquareBounds() -> CGRect {
        let corners = [
            CGPoint.zero,
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
        ].map { $0.applying(ctm) }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func subtype(of dictionary: CGPDFDictionaryRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &name), let name else { return nil }
        return String(cString: name)
    }

    private func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
        var integer: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, key, &integer) {
            return CGFloat(integer)
        }
        var real: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(dictionary, key, &real) {
            return CGFloat(real)
        }
        return nil
    }
}

#endif
