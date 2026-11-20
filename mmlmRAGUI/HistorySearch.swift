import Foundation
import FoundationModels
import NaturalLanguage

#if os(macOS)

/// What a search sentence excludes. Embeddings treat "冇提過黃碧嬌" as a question about
/// 黃碧嬌. This intent stops that: a negated name is not a topic match.
struct HistoryQueryIntent: Equatable {
    var excludedPhrases: [String]
    var wantsAbsence: Bool
    /// Topic left after the exclusion is removed. Empty when the search is only an absence.
    var affirmativeQuery: String

    static let none = HistoryQueryIntent(excludedPhrases: [], wantsAbsence: false, affirmativeQuery: "")
}

/// Matches saved questions and answers from a sentence the user typed.
///
/// Words that actually appear are matched immediately. A separate pass uses the
/// on-device contextual embedding to pick up a paraphrase that shares no words.
/// Negation is applied first, so a name inside "冇提過" is excluded instead of retrieved.
enum HistorySearch {
    /// Blank queries keep the saved order. Otherwise question matches come first,
    /// then answer matches, then wording matches, then semantic ids.
    /// An absence-only query keeps every record that does not mention the excluded phrase.
    /// A record that names the phrase stays only when that record also denies it.
    static func ordered(
        _ records: [QuestionRecord],
        query: String,
        semanticIDs: [Int64],
        intent: HistoryQueryIntent
    ) -> [QuestionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        if intent.wantsAbsence, intent.affirmativeQuery.isEmpty {
            return records.filter { allows($0, intent: intent) }
        }

        let searchText = intent.wantsAbsence ? intent.affirmativeQuery : query
        let terms = significantTerms(in: searchText)
        var tierByID: [Int64: Int] = [:]
        for record in records {
            if let tier = lexicalTier(for: record, query: searchText, terms: terms) {
                tierByID[record.id] = tier
            }
        }

        var semanticRank: [Int64: Int] = [:]
        for (index, id) in semanticIDs.enumerated() where tierByID[id] == nil {
            tierByID[id] = semanticTier
            semanticRank[id] = index
        }

        return records.enumerated()
            .filter { tierByID[$0.element.id] != nil }
            .sorted { lhs, rhs in
                let leftTier = tierByID[lhs.element.id] ?? semanticTier
                let rightTier = tierByID[rhs.element.id] ?? semanticTier
                if leftTier != rightTier { return leftTier < rightTier }
                if leftTier == semanticTier {
                    return (semanticRank[lhs.element.id] ?? 0) < (semanticRank[rhs.element.id] ?? 0)
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { allows($0, intent: intent) }
    }

    /// Reads exclusion language such as "沒提過黃碧嬌" without calling the model.
    static func intent(for raw: String) -> HistoryQueryIntent {
        resolvedIntent(query: raw, modelExclusions: [], modelWantsAbsence: false)
    }

    /// Combines the literal reading with phrases the on-device model found in the same sentence.
    static func resolvedIntent(
        query raw: String,
        modelExclusions: [String],
        modelWantsAbsence: Bool
    ) -> HistoryQueryIntent {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .none }

        var phrases = excludedPhrases(in: query)
        if modelWantsAbsence {
            // A phrase already kept as the topic, such as 「合約」 in 「合約冇提過黃碧嬌」, stays searchable.
            let topic = phrases.isEmpty ? "" : affirmativeRemainder(of: query, removing: phrases)
            for phrase in modelExclusions {
                let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, query.localizedStandardContains(trimmed) else { continue }
                let pieces = significantTerms(in: trimmed)
                let additions = pieces.isEmpty ? [trimmed] : pieces
                for piece in additions where piece.count >= 2 && query.localizedStandardContains(piece) {
                    if fieldWords.contains(piece) { continue }
                    if !topic.isEmpty, topic.localizedStandardContains(piece) { continue }
                    phrases.append(piece)
                }
            }
        }
        phrases = shortestPhrases(uniquePhrases(phrases))
        guard !phrases.isEmpty else { return HistoryQueryIntent(excludedPhrases: [], wantsAbsence: false, affirmativeQuery: query) }

        let affirmative = affirmativeRemainder(of: query, removing: phrases)
        return HistoryQueryIntent(
            excludedPhrases: phrases,
            wantsAbsence: true,
            affirmativeQuery: affirmative
        )
    }

    /// True when the sentence may be a negation the embeddings would get backwards.
    static func mayNeedAssistant(_ query: String) -> Bool {
        if intent(for: query).wantsAbsence { return true }
        let cues = [
            "冇提", "冇講", "冇出現", "沒提", "沒講", "沒出現", "沒有",
            "没提", "没有", "没讲", "未提", "無提", "不是", "並非", "不包括",
            "never mentioned", "not mentioned", "didn't mention", "did not mention", "without"
        ]
        return cues.contains {
            query.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A record that names an excluded phrase stays only when a denial sits next to that phrase.
    /// Records that never name it stay. A bare 「冇」 elsewhere in a long answer does not count.
    static func allows(_ record: QuestionRecord, intent: HistoryQueryIntent) -> Bool {
        guard intent.wantsAbsence else { return true }
        let text = record.question + "\n" + record.answer
        for phrase in intent.excludedPhrases where text.localizedStandardContains(phrase) {
            if !denies(phrase, in: text) { return false }
        }
        return true
    }

    /// Chinese and Cantonese stay on the CJK embedding. Anything else uses English.
    static func queryUsesLatin(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isCJK = (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value)
            if isCJK { return false }
        }
        return text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    static func shouldEmbed(_ query: String) -> Bool {
        query.contains { $0.isLetter }
    }

    private static let semanticTier = 4

    /// Fillers that should not be required when matching a sentence word by word.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "for", "and", "or",
        "is", "are", "was", "were", "be", "do", "does", "did",
        "how", "what", "when", "where", "why", "who",
        "i", "me", "my", "we", "you", "your", "it", "this", "that",
        "with", "from", "at", "by", "as", "can", "could", "please",
        "的", "了", "呢", "個", "在", "和", "與", "及", "或", "是", "有",
        "沒", "不", "嗎", "啊", "吧", "呀", "嘅", "咗", "喎", "同", "嗰",
        "啲", "咁", "冇", "唔", "係", "喺", "囉", "喇", "嘛", "咩", "裏",
        "裡", "既", "我", "你", "佢", "想", "要", "可以", "幫", "請",
        "一下", "之後", "然後", "如果", "因為", "所以", "但係", "但是",
        "這個", "那個", "呢個", "嗰個"
    ]

    /// Question phrase, answer phrase, every term in the question, then every term in either field.
    private static func lexicalTier(for record: QuestionRecord, query: String, terms: [String]) -> Int? {
        if record.question.localizedStandardContains(query) { return 0 }
        if record.answer.localizedStandardContains(query) { return 1 }
        guard !terms.isEmpty else { return nil }
        let questionHits = terms.allSatisfy { record.question.localizedStandardContains($0) }
        if questionHits { return 2 }
        let combinedHits = terms.allSatisfy { term in
            record.question.localizedStandardContains(term) || record.answer.localizedStandardContains(term)
        }
        return combinedHits ? 3 : nil
    }

    /// Content words, in order, with particles and one-character tokens removed.
    private static func significantTerms(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var terms: [String] = []
        var seen: Set<String> = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 2 else { return true }
            let key = token.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard !stopwords.contains(key) else { return true }
            guard key.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
            if seen.insert(key).inserted {
                terms.append(key)
            }
            return true
        }
        return terms
    }

    /// The longest cue at one index wins, so "沒有提過" is kept instead of "沒有".
    private static let negationPrefixes: [String] = [
        "never mentioned", "did not mention", "didn't mention", "didn’t mention",
        "not mentioned", "no mention of",
        "冇提過", "冇提及", "冇提到", "冇講過", "冇講到", "冇出現過",
        "沒有提過", "沒有提及", "沒有提到", "沒有講過",
        "沒提過", "未提過", "未提到", "未提及",
        "無提過", "無提及", "無提到",
        "從未提過", "從不提過",
        "冇提", "冇講", "冇出現", "沒提", "沒講", "沒出現",
        "沒有", "没有", "不是", "並非", "不包括", "除了", "除外",
        "without"
    ]

    private static let spanPunctuation = CharacterSet(charactersIn: "，。！？；、,.!?;\n：:")

    private static let trailingParticles = ["嘅事", "的事", "嘅", "的", "咗", "了", "呢", "啊", "呀", "吧", "嗎", "嘛", "囉", "喇"]

    private static func excludedPhrases(in query: String) -> [String] {
        var phrases: [String] = []
        var searchStart = query.startIndex
        var loops = 0
        while searchStart < query.endIndex, loops < 8 {
            loops += 1
            guard let hit = earliestNegation(in: query, from: searchStart) else { break }
            let spanEnd = endOfSpan(in: query, from: hit.upperBound)
            phrases.append(contentsOf: spanPhrases(String(query[hit.upperBound..<spanEnd])))
            searchStart = spanEnd
        }
        return phrases
    }

    private static func earliestNegation(in query: String, from start: String.Index) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let region = start..<query.endIndex
        var best: Range<String.Index>?
        for prefix in negationPrefixes {
            guard let range = query.range(of: prefix, options: options, range: region) else { continue }
            guard let current = best else {
                best = range
                continue
            }
            let earlier = range.lowerBound < current.lowerBound
            let sameStartLonger = range.lowerBound == current.lowerBound && range.upperBound > current.upperBound
            if earlier || sameStartLonger {
                best = range
            }
        }
        return best
    }

    private static func endOfSpan(in query: String, from start: String.Index) -> String.Index {
        var index = start
        while index < query.endIndex {
            let character = query[index]
            if character.unicodeScalars.contains(where: { spanPunctuation.contains($0) }) {
                return index
            }
            index = query.index(after: index)
        }
        return query.endIndex
    }

    private static let fieldWords: Set<String> = ["回答", "答案", "提問", "問題", "記錄", "歷史"]

    private static func spanPhrases(_ span: String) -> [String] {
        let withoutField = stripFieldSuffix(span.trimmingCharacters(in: .whitespacesAndNewlines))
        let stripped = stripTrailingParticles(withoutField)
        guard !stripped.isEmpty else { return [] }
        var terms: [String] = []
        for term in significantTerms(in: stripped) {
            let cleaned = stripTrailingParticles(term)
            guard cleaned.count >= 2, !fieldWords.contains(cleaned) else { continue }
            terms.append(cleaned)
        }
        if !terms.isEmpty { return terms }
        return connectorPieces(in: stripped).filter { $0.count >= 2 }
    }

    /// Used when the word tokenizer only returns one-character pieces.
    private static func connectorPieces(in text: String) -> [String] {
        var parts = [text]
        for connector in ["或者", "and", "同", "與", "和", "及", "或"] {
            parts = parts.flatMap { $0.components(separatedBy: connector) }
        }
        return parts.map {
            stripTrailingParticles($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func stripTrailingParticles(_ text: String) -> String {
        var result = text
        var changed = true
        while changed, !result.isEmpty {
            changed = false
            for particle in trailingParticles where result.count > particle.count && result.hasSuffix(particle) {
                result = String(result.dropLast(particle.count))
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return result
    }

    private static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for phrase in phrases {
            let key = phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            if seen.insert(key).inserted {
                unique.append(phrase)
            }
        }
        return unique
    }

    /// Keep "黃碧嬌" when a longer phrase such as "黃碧嬌嘅事" was also found.
    private static func shortestPhrases(_ phrases: [String]) -> [String] {
        phrases.filter { phrase in
            !phrases.contains { other in
                other.count < phrase.count && phrase.localizedStandardContains(other)
            }
        }
    }

    private static func affirmativeRemainder(of query: String, removing phrases: [String]) -> String {
        var ranges: [Range<String.Index>] = []
        var searchStart = query.startIndex
        var loops = 0
        while searchStart < query.endIndex, loops < 8 {
            loops += 1
            guard let hit = earliestNegation(in: query, from: searchStart) else { break }
            ranges.append(hit)
            searchStart = endOfSpan(in: query, from: hit.upperBound)
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for phrase in phrases {
            var start = query.startIndex
            while start < query.endIndex,
                  let range = query.range(of: phrase, options: options, range: start..<query.endIndex) {
                ranges.append(range)
                start = range.upperBound
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var kept = ""
        var index = query.startIndex
        for range in sorted {
            if range.lowerBound > index {
                kept += query[index..<range.lowerBound]
            }
            if range.upperBound > index {
                index = range.upperBound
            }
        }
        if index < query.endIndex {
            kept += query[index...]
        }
        let trimmed = stripFieldSuffix(kept.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !significantTerms(in: trimmed).isEmpty else { return "" }
        return trimmed
    }

    /// 「黃碧嬌嘅回答」 names the answer field. The field word is not something to search for.
    private static func stripFieldSuffix(_ text: String) -> String {
        let particles = ["嘅", "的", "既"]
        let markers = ["回答", "答案", "提問", "問題", "記錄", "歷史"]
        for marker in markers {
            for particle in particles {
                let suffix = particle + marker
                guard text.hasSuffix(suffix) else { continue }
                return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Every time the phrase appears, a denial has to sit just before or just after it.
    private static func denies(_ phrase: String, in text: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var start = text.startIndex
        var found = false
        while start < text.endIndex, let range = text.range(of: phrase, options: options, range: start..<text.endIndex) {
            found = true
            let before = window(in: text, endingAt: range.lowerBound, maxCount: 24)
            let after = window(in: text, startingAt: range.upperBound, maxCount: 20)
            if !hasNegationSuffix(before) && !hasNearbyDenial(after) {
                return false
            }
            start = range.upperBound
        }
        return found
    }

    private static func window(in text: String, endingAt index: String.Index, maxCount: Int) -> String {
        var start = index
        var remaining = maxCount
        while remaining > 0, start > text.startIndex {
            start = text.index(before: start)
            remaining -= 1
        }
        return String(text[start..<index])
    }

    private static func window(in text: String, startingAt index: String.Index, maxCount: Int) -> String {
        var end = index
        var remaining = maxCount
        while remaining > 0, end < text.endIndex {
            end = text.index(after: end)
            remaining -= 1
        }
        return String(text[index..<end])
    }

    private static func hasNegationSuffix(_ window: String) -> Bool {
        let trimmed = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for prefix in negationPrefixes {
            let needle = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if folded.hasSuffix(needle) { return true }
            for extra in ["過", "了", "到", "及"] where folded.hasSuffix(needle + extra) {
                return true
            }
        }
        return false
    }

    private static func hasNearbyDenial(_ window: String) -> Bool {
        let chinese = ["冇", "沒有", "没有", "未有", "並無", "沒提", "無提", "未提", "不是", "並非", "不包括"]
        if chinese.contains(where: { window.localizedStandardContains($0) }) {
            return true
        }
        let folded = window.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let latin = ["never", "not mentioned", "without"]
        return latin.contains { cue in
            let needle = cue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var start = folded.startIndex
            while let range = folded.range(of: needle, range: start..<folded.endIndex) {
                let beforeIsLetter = range.lowerBound > folded.startIndex
                    && folded[folded.index(before: range.lowerBound)].isLetter
                let afterIsLetter = range.upperBound < folded.endIndex && folded[range.upperBound].isLetter
                if !beforeIsLetter && !afterIsLetter { return true }
                start = range.upperBound
            }
            return false
        }
    }
}

/// Reads exclusion from the search sentence only. Saved questions are not sent to the model.
enum HistorySearchAssistant {
    static var isReady: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    static func interpret(_ query: String) async -> (phrases: [String], wantsAbsence: Bool)? {
        let session = LanguageModelSession(instructions: """
        The person's locale is \(Locale.current.identifier).
        You read one search sentence about saved questions and answers. The sentence may be Cantonese.
        If the person says someone or something was not mentioned, did not appear, or should be left out, copy only that name or phrase into excludedPhrases and set wantsAbsence to true.
        Example: 冇提過黃碧嬌 excludes 黃碧嬌 and wantsAbsence is true. A saved question about who 黃碧嬌 is related to does not match.
        If the person is asking about a name, wantsAbsence is false and excludedPhrases is empty.
        An ordinary topic search leaves excludedPhrases empty and wantsAbsence false.
        Copy phrases from the sentence. Do not translate them.
        """)
        do {
            let response = try await session.respond(
                to: "Search sentence: \(query)",
                generating: HistorySearchReading.self
            )
            return (response.content.excludedPhrases, response.content.wantsAbsence)
        } catch {
            return nil
        }
    }
}

@Generable
struct HistorySearchReading {
    @Guide(description: "Names or phrases copied from the sentence that the person said were not mentioned. Empty when nothing is excluded.", .maximumCount(4))
    var excludedPhrases: [String]

    @Guide(description: "True when the person wants to exclude those phrases.")
    var wantsAbsence: Bool
}

/// On-device paraphrase search. One queue owns the embedding models.
///
/// `NLContextualEmbedding` keeps token vectors in storage that the next call
/// overwrites, and one instance must not be used from two threads. Vectors are
/// copied out before the next string is embedded.
final class HistorySemanticSearch: @unchecked Sendable {
    static let shared = HistorySemanticSearch()

    private let queue = DispatchQueue(label: "mmlmRAGUI.historySearch")
    private var chineseModel: NLContextualEmbedding?
    private var englishModel: NLContextualEmbedding?
    private var vectors: [String: [Double]] = [:]

    /// Cosine distance is `1 - similarity`. 0 is the same sentence.
    /// Chinese 0.23 keeps 「點先可以清走已儲存嘅問題同答案」 near the delete record
    /// and leaves an unrelated corpus question outside.
    /// English 0.142 keeps “remove a question from history” and leaves a citation question outside.
    private static let chineseLimit = 0.23
    private static let englishLimit = 0.142
    private static let snippetLength = 180
    private static let matchLimit = 40

    private init() {}

    func matchingIDs(in records: [QuestionRecord], query: String) async -> [Int64] {
        let rows = records.map { (id: $0.id, question: $0.question, answer: $0.answer) }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.rank(rows: rows, query: query))
            }
        }
    }

    private func rank(
        rows: [(id: Int64, question: String, answer: String)],
        query: String
    ) -> [Int64] {
        let query = snippet(query)
        guard query.count >= 2, HistorySearch.shouldEmbed(query) else { return [] }
        let latin = HistorySearch.queryUsesLatin(query)
        guard let embedding = embedding(latin: latin) else { return [] }
        guard let queryVector = vector(for: query, model: embedding.model, language: embedding.language) else {
            return []
        }

        var matches: [(id: Int64, distance: Double)] = []
        for row in rows {
            let distance = bestDistance(
                question: row.question,
                answer: row.answer,
                queryVector: queryVector,
                model: embedding.model,
                language: embedding.language,
                limit: embedding.limit
            )
            if let distance, distance <= embedding.limit {
                matches.append((row.id, distance))
            }
        }
        matches.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.id > rhs.id
        }
        return matches.prefix(Self.matchLimit).map(\.id)
    }

    private func bestDistance(
        question: String,
        answer: String,
        queryVector: [Double],
        model: NLContextualEmbedding,
        language: NLLanguage,
        limit: Double
    ) -> Double? {
        var best: Double?
        if let questionVector = vector(for: question, model: model, language: language),
           let distance = cosineDistance(queryVector, questionVector) {
            best = distance
        }
        let questionIsFar = best.map { $0 > limit } ?? true
        guard questionIsFar else { return best }
        guard let answerVector = vector(for: answer, model: model, language: language),
              let distance = cosineDistance(queryVector, answerVector)
        else {
            return best
        }
        if let best {
            return min(best, distance)
        }
        return distance
    }

    private func embedding(latin: Bool) -> (model: NLContextualEmbedding, language: NLLanguage, limit: Double)? {
        if latin {
            if englishModel == nil {
                englishModel = NLContextualEmbedding(language: .english)
            }
            guard let englishModel, englishModel.hasAvailableAssets else { return nil }
            return (englishModel, .english, Self.englishLimit)
        }
        if chineseModel == nil {
            chineseModel = NLContextualEmbedding(language: .traditionalChinese)
        }
        guard let chineseModel, chineseModel.hasAvailableAssets else { return nil }
        return (chineseModel, .traditionalChinese, Self.chineseLimit)
    }

    /// Mean of the token vectors. The array is copied because the model reuses its buffer.
    private func vector(
        for text: String,
        model: NLContextualEmbedding,
        language: NLLanguage
    ) -> [Double]? {
        let text = snippet(text)
        guard text.count >= 2 else { return nil }
        let key = "\(language.rawValue)\u{1f}\(text)"
        if let cached = vectors[key] { return cached }
        guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }

        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { tokenVector, _ in
            let owned = Array(tokenVector)
            let limit = min(owned.count, sum.count)
            guard limit > 0 else { return true }
            for index in 0..<limit {
                sum[index] += owned[index]
            }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let mean = sum.map { $0 / Double(count) }
        if vectors.count > 800 {
            vectors.removeAll(keepingCapacity: true)
        }
        vectors[key] = mean
        return mean
    }

    private func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.snippetLength else { return trimmed }
        return String(trimmed.prefix(Self.snippetLength))
    }

    private func cosineDistance(_ left: [Double], _ right: [Double]) -> Double? {
        guard left.count == right.count, !left.isEmpty else { return nil }
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in left.indices {
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }
        let denominator = leftNorm.squareRoot() * rightNorm.squareRoot()
        guard denominator > 0 else { return nil }
        return 1 - (dot / denominator)
    }
}

#endif
