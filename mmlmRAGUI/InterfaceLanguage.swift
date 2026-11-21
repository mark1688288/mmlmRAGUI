import Foundation
import Observation

/// Interface language. English is the source and the default.
/// Chinese keeps the app's written Cantonese copy.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh-Hant"

    var id: String { rawValue }

    /// Name of this language, written in that language, for the language menu.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static func stored() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: InterfaceLanguage.defaultsKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .english
    }
}

/// English source strings and their Chinese translations.
///
/// Placeholders use `{name}` so a value can contain any characters.
enum UICopy {
    static func resolve(_ english: String) -> String {
        guard AppLanguage.stored() == .chinese else { return english }
        return chinese[english] ?? english
    }

    static func fill(_ english: String, _ values: [String: String]) -> String {
        var text = resolve(english)
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }

    static let chinese: [String: String] = [
        "This prototype only runs the local rag command on macOS.": "呢個雛型淨係係 macOS 呼叫本機的 rag 命令。",
        "Saved this question.": "已儲存提問記錄。",
        "Couldn't do that": "做唔到",
        "OK": "好",
        "Compare": "比較",
        "Compare two tabs' questions and answers side by side": "左右並排比較兩個分頁的提問同回答",
        "Settings": "設定",
        "Documents": "文件",
        "Documents ({count})": "文件({count})",
        "Hide Sidebar": "隱藏側欄",
        "Show Sidebar": "顯示側欄",
        "Sidebar": "側欄",
        "Ingest": "入庫",
        "History": "歷史",
        "Answer": "回答",
        "The answer shows up here.": "回答會顯示在呢度。",
        "Log": "記錄",
        "Collapse Log": "收起記錄",
        "Expand Log": "展開記錄",
        "Ingest and question logs show up here.": "入庫同提問的記錄會顯示在呢度。",
        "{count} more queued": "仲有 {count} 個排隊",
        "Cancel": "取消",
        "Local corpus": "本機語料",
        "Drop to ingest": "放低就入庫",
        "Drop a file here, or choose one": "拖一個檔入呢度，或者揀一個檔",
        "pdf, docx, pptx, text, and images. Each file is handed to rag ingest one at a time.": "pdf、docx、pptx、文字、圖像。每次交一個檔界 rag ingest。",
        "Choose Files…": "揀檔案…",
        "Ask the corpus a question": "問語料一條問題",
        "Ask": "提問",
        "This question was opened from history and can't be asked again": "由歷史打開嘅提問唔可以再提問",
        "Answering…": "回覆緊…",
        "Waiting for rag…": "等緊 rag 回覆…",
        "Saved": "已儲存",
        "Save": "儲存",
        "Save this question and answer": "儲存呢條提問同回答",
        "This question is saved": "呢條提問記錄已儲存",
        "Nothing to save": "未有可儲存的提問",
        "Save this question after it has an answer": "有回答先可以儲存",
        "Couldn't delete the question.": "刪除唔到提問記錄。",
        "Deleted 1 question.": "已刪除 1 條提問記錄。",
        "Deleted {count} questions.": "已刪除 {count} 條提問記錄。",
        "Couldn't save the question.": "儲存唔到提問記錄。",
        "Couldn't open a new tab.": "開唔到新分頁。",
        "Wait for the current job to finish before loading.": "等而家呢個工作完先再載入。",
        "Unsaved question": "未儲存提問記錄",
        "Load another question without saving this one?": "是否不儲存提問記錄便載入另一條？",
        "Don't Save": "不儲存",
        "rag path": "rag 路徑",
        "Executable. A folder that contains rag.toml is used as the working directory instead.": "可執行檔。填有 rag.toml 的資料夾會改做工作目錄。",
        "Use This Path": "使用此路徑",
        "Working Directory": "工作目錄",
        "A parent folder with rag.toml is used. Otherwise ~/.mmlmrag/rag.toml.": "上層有 rag.toml 就用佢。否則用 ~/.mmlmrag/rag.toml。",
        "Status": "狀態",
        "Check Again": "重新檢查",
        "Not checked yet.": "未檢查。",
        "Copied": "已複製",
        "Copy {item}": "複製{item}",
        "System": "系統",
        "Display": "顯示",
        "Interface Language": "界面語言",
        "Compare Tabs": "比較分頁",
        "rag exited with code {code}.": "rag 結束，代碼 {code}。",
        "This path is a folder, not an executable rag. A corpus folder must contain rag.toml. Put that folder in the working directory.": "呢個路徑係資料夾，唔係可執行的 rag。語料目錄要包含 rag.toml，請填喺工作目錄。",
        "This path is not an executable rag.": "呢個路徑唔係可執行的 rag。",
        "Working directory set to {path}, using the program inside it.": "工作目錄已設為 {path}，並用裡面的程式。",
        "Working directory set to {path}.": "工作目錄已設為 {path}。",
        "Checking status": "檢查狀態",
        "This item isn't supported. Ingest accepts pdf, docx, pptx, text, and images, one file at a time.": "唔支援呢個項目。入庫接受 pdf、docx、pptx、文字同圖像，每次一個檔案。",
        "Skipped {count} unsupported items.": "跳過 {count} 個唔支援的項目。",
        "Wait for the current job to finish before asking.": "等而家呢個工作完先再提問。",
        "Cancelled.": "已取消。",
        "Ingest {name}": "入庫 {name}",
        "Working directory does not exist: {path}": "工作目錄唔存在：{path}",
        "Python wasn't found, so the rag in that folder can't run.": "搵唔到 Python，未能執行資料夾入面的 rag。",
        "rag wasn't found. Install it with Homebrew: brew install mark1688288/mmlmrag/mmlmrag, or set the executable path yourself.": "搵唔到 rag。可以用 Homebrew 裝：brew install mark1688288/mmlmrag/mmlmrag，或者自己填上可執行檔路徑。",
        "corpus.sqlite wasn't found in the working directory.": "搵唔到工作目錄入面的 corpus.sqlite。",
        "Couldn't open corpus.sqlite: {detail}": "打唔開 corpus.sqlite：{detail}",
        "Answer order": "答覆來源次序",
        "Page number": "頁碼由小至大",
        "Couldn't open this PDF.": "打唔開呢個 PDF。",
        "This file isn't a PDF, so its pages can't be previewed.": "呢個檔唔係 PDF，預覽唔到頁面。",
        "File does not exist: {path}": "檔案唔存在：{path}",
        "The corpus has no “{name}”.": "語料冇「{name}」。",
        "There is no page {page}.": "冇第 {page} 頁。",
        "Page {page} has no size.": "第 {page} 頁冇尺寸。",
        "Recognizing text…": "識別緊文字…",
        "Copy": "複製",
        "Select All": "全選",
        "Open Image": "打開圖片",
        "Hand": "手掌",
        "Drag to move the picture": "拖住嚟移動張相",
        "Select Text": "選取文字",
        "Select text on the picture": "選取圖片上嘅文字",
        "Pin": "釘住",
        "Keep the picture in front of other windows": "令張相保持喺其他視窗前面",
        "Keep this window in front of other windows": "令呢個視窗保持喺其他視窗前面",
        "No text recognized on this picture.": "呢張圖識別唔到文字。",
        "Zoom In": "放大",
        "Zoom Out": "縮小",
        "Zoom": "縮放",
        "Fit": "適合",
        "Image {number}": "圖片 {number}",
        "No text recognized on this page.": "呢頁識別唔到文字。",
        "Sort": "排序",
        "Choose how document pages are sorted": "揀文件頁嘅排序",
        "Loading document pages…": "讀緊文件頁…",
        "Can't preview": "預覽唔到",
        "No document pages yet": "未有文件頁",
        "Document pages cited in the answer are listed here from top to bottom in answer order.": "回答提到的文件頁會按答覆來源次序由上至下排喺呢度。",
        "Document pages cited in the answer are listed here by page number.": "回答提到的文件頁會按頁碼由小至大排喺呢度。",
        "Drag to select text, then press ⌘C to copy. Scanned pages are recognized first.": "拖選文字，然後按 ⌘C 複製。掃描頁會先識別文字。",
        "{filename} page {page}": "{filename} 第 {page} 頁",
        "Recognizing": "識別緊",
        "No matches": "冇符合",
        "Match {index} of {total}, recognizing": "第 {index} 個，共 {total} 個，識別緊",
        "Match {index} of {total}": "第 {index} 個，共 {total} 個",
        "Search selectable text on the preview pages. Return or ⌘G for the next match, ⇧⌘G for the previous. Scanned pages are recognized first.": "搜尋預覽頁可選嘅文字。Return 或 ⌘G 下一個，⇧⌘G 上一個。掃描頁會先識別文字。",
        "Search the text layer": "搜尋文字層",
        "Previous": "上一個",
        "Next": "下一個",
        "Need two answered tabs": "未夠兩個有回答嘅分頁",
        "Open at least two mmlmRAG tabs that already have answers.": "開住至少兩個已經有回答嘅 mmlmRAG 分頁，就可以左右並排比較提問同回答。",
        "Left": "左邊",
        "Right": "右邊",
        "Show right": "轉去右邊",
        "Show left": "轉去左邊",
        "Same order as the window tabs, left to right.": "次序同視窗上面嘅分頁一樣，由左至右。",
        "Question": "提問",
        "No question yet.": "未有提問。",
        "No answer yet.": "未有回答。",
        "There's no question to save.": "未有提問，儲存唔到。",
        "Couldn't delete the question: {detail}": "刪除唔到提問記錄：{detail}",
        "Couldn't read questions: {detail}": "讀唔到提問記錄：{detail}",
        "Couldn't open questions: {detail}": "開唔到提問記錄：{detail}",
        "Couldn't write the question: {detail}": "寫唔到提問記錄：{detail}",
        "No saved questions": "未有提問記錄",
        "Saved questions and answers will be listed here.": "儲存之後，提問同回答會列喺呢度。",
        "Assistant is checking": "AI 幫手核對緊",
        "Searching": "搜尋緊",
        "No matching questions": "搵唔到相符記錄",
        "Checking whether this sentence really matches, including negation.": "對緊呢句說話係咪真係符合，包括否定。",
        "Comparing this sentence with saved questions and answers.": "對緊呢句說話同已儲存的提問、回答。",
        "Try another sentence, or clear the search.": "試下另一句說話，或者清空搜尋。",
        "Assistant excluded the negated wording": "AI 幫手已排除否定嘅字眼",
        "Assistant isn't ready. Negation rules were used instead.": "AI 幫手未就緒，已用否定規則排除",
        "Assistant didn't respond. Negation rules were used instead.": "AI 幫手暫時回應唔到，已用否定規則排除",
        "Search questions and answers in plain language": "用自然語言搜尋提問同回答",
        "Search history": "搜尋歷史",
        "Clear search": "清空搜尋",
        "Search with one sentence. The assistant understands negation, for example「冇提過黃碧嬌」.": "用一句說話搜尋。AI 幫手會理解否定，例如「冇提過黃碧嬌」。",
        "Deselect All": "取消全選",
        "{count} selected": "已揀 {count} 條",
        "Delete": "刪除",
        "Select questions to delete first": "先揀要刪除的提問記錄",
        "Delete {count} selected questions": "刪除已揀的 {count} 條提問記錄",
        "Select this question": "揀呢條記錄",
        "Load this question and answer": "載入呢條提問同回答",
        "Open in New Tab": "開啟於新分頁",
        "Delete question": "刪除提問記錄",
        "Delete this question? This can't be undone.": "刪除呢條提問記錄？刪除之後搵唔返。",
        "Delete {count} questions? This can't be undone.": "刪除 {count} 條提問記錄？刪除之後搵唔返。",
        "No answer yet": "未有回答",
        "Load this question": "載入呢條提問記錄",
        "{stamp}, {question}": "{stamp}，{question}",
        "The answer isn't finished. Leave without saving this question?": "回覆未完。是否不儲存提問記錄便離開？",
        "Leave without saving this question?": "是否不儲存提問記錄便離開？",
    ]
}

/// The language chosen in Settings → Display. Default is English.
@MainActor
@Observable
final class InterfaceLanguage {
    static let shared = InterfaceLanguage()
    static let defaultsKey = "interfaceLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        language = AppLanguage.stored()
    }

    func text(_ english: String) -> String {
        _ = language
        return UICopy.resolve(english)
    }
}

/// Localized interface copy for the current language.
/// Reading this from a view body refreshes that view when the language changes.
@MainActor
func ui(_ english: String) -> String {
    _ = InterfaceLanguage.shared.language
    return UICopy.resolve(english)
}

@MainActor
func ui(_ english: String, _ values: [String: String]) -> String {
    _ = InterfaceLanguage.shared.language
    return UICopy.fill(english, values)
}

/// True when `value` is this message in either interface language.
func uiSame(_ value: String?, _ english: String) -> Bool {
    guard let value else { return false }
    return value == english || value == UICopy.chinese[english]
}
