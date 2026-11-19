import Foundation

#if os(macOS)

/// One cited PDF page parsed from an answer.
///
/// `rag` tells the model to end a sentence with
/// `[來源: filename p.N #chunk=id]`. Page numbers are 1-based.
struct CitedPage: Hashable, Identifiable {
    var filename: String
    var page: Int

    var id: String { "\(filename)\n\(page)" }
}

/// Order of cited pages inside one file. Files stay in first-appearance order.
enum CitationPageOrder: String, CaseIterable, Identifiable {
    /// Pages follow the order they first appear among the answer's sources.
    case source
    /// Pages go from the smallest page number to the largest.
    case pageNumber

    var id: Self { self }

    var title: String {
        switch self {
        case .source:
            "答覆來源次序"
        case .pageNumber:
            "頁碼由小至大"
        }
    }
}

enum CitationPages {
    /// Pages mentioned in `answer`, one entry per file and page.
    ///
    /// Files stay in the order they first appear. Inside a file, pages are
    /// unique. `.source` keeps first-appearance order. `.pageNumber` sorts
    /// them from smallest to largest.
    static func orderedPages(
        in answer: String,
        order: CitationPageOrder = .source
    ) -> [CitedPage] {
        // Stay on one line and require the closing bracket, so a citation that
        // is still streaming cannot borrow the next line's `]`.
        guard let regex = try? NSRegularExpression(
            pattern: #"\[來源\s*[:：]\s*([^\n\]]+?)\s+p\.\s*(\d+)[^\n\]]*\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(answer.startIndex..., in: answer)
        var fileOrder: [String] = []
        var pagesByFile: [String: [Int]] = [:]
        regex.enumerateMatches(in: answer, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: answer),
                  let pageRange = Range(match.range(at: 2), in: answer),
                  let page = Int(answer[pageRange]),
                  page >= 1
            else { return }

            let filename = String(answer[nameRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty, !filename.contains("["), !filename.contains("\n") else {
                return
            }
            var pages = pagesByFile[filename] ?? []
            if pagesByFile[filename] == nil {
                fileOrder.append(filename)
            }
            if !pages.contains(page) {
                pages.append(page)
            }
            pagesByFile[filename] = pages
        }

        return fileOrder.flatMap { filename in
            let seen = pagesByFile[filename] ?? []
            let pages = order == .pageNumber ? seen.sorted() : seen
            return pages.map { CitedPage(filename: filename, page: $0) }
        }
    }
}

#endif
