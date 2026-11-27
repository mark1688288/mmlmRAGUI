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
            "This prototype only runs the local rag command on macOS.": "此原型僅在 macOS 上執行本機的 rag 命令。",
            "Saved this question.": "已儲存此提問。",
            "Couldn't do that": "無法執行此操作",
            "OK": "好",
            "Compare": "比較",
            "Compare two tabs' questions and answers side by side": "並排比較兩個分頁的提問與回答",
            "Settings": "設定",
            "Documents": "文件",
            "Documents ({count})": "文件 ({count})",
            "Hide Sidebar": "隱藏側邊欄",
            "Show Sidebar": "顯示側邊欄",
            "Sidebar": "側邊欄",
            "Ingest": "入庫",
            "History": "歷史記錄",
            "Answer": "回答",
            "The answer shows up here.": "答案會顯示在這裡。",
            "Log": "日誌",
            "Collapse Log": "收合日誌",
            "Expand Log": "展開日誌",
            "Ingest and question logs show up here.": "入庫與提問日誌會顯示在這裡。",
            "{count} more queued": "尚有 {count} 個項目排隊中",
            "Cancel": "取消",
            "Local corpus": "本機語料庫",
            "Drop to ingest": "放開即可入庫",
            "Drop a file here, or choose one": "將檔案拖放至此，或選擇檔案",
            "pdf, docx, pptx, text, and images. Each file is handed to rag ingest one at a time.": "支援 pdf、docx、pptx、純文字與圖片。每次會逐一將檔案交給 rag ingest 處理。",
            "Choose Files…": "選擇檔案…",
            "Ask the corpus a question": "向語料庫提問",
            "Ask": "提問",
            "This question was opened from history and can't be asked again": "此提問是從歷史記錄開啟，無法重新提問",
            "Answering…": "正在回答…",
            "Waiting for rag…": "正在等待 rag 回應…",
            "Saved": "已儲存",
            "Save": "儲存",
            "Save this question and answer": "儲存此提問與回答",
            "This question is saved": "此提問已儲存",
            "Nothing to save": "沒有可儲存的內容",
            "Save this question after it has an answer": "待有回答後即可儲存此提問",
            "Couldn't delete the question.": "無法刪除此提問。",
            "Deleted 1 question.": "已刪除 1 則提問。",
            "Deleted {count} questions.": "已刪除 {count} 則提問。",
            "Couldn't save the question.": "無法儲存此提問。",
            "Couldn't open a new tab.": "無法開啟新分頁。",
            "Wait for the current job to finish before loading.": "請等待目前的工作完成後再載入。",
            "Unsaved question": "未儲存的提問",
            "Load another question without saving this one?": "不儲存此提問並載入另一則提問嗎？",
            "Don't Save": "不儲存",
            "rag path": "rag 路徑",
            "Executable. A folder that contains rag.toml is used as the working directory instead.": "可執行檔。若指定包含 rag.toml 的資料夾，則會改作工作目錄。",
            "Use This Path": "使用此路徑",
            "Working Directory": "工作目錄",
            "A parent folder with rag.toml is used. Otherwise ~/.mmlmrag/rag.toml.": "會使用包含 rag.toml 的上層資料夾，否則使用 ~/.mmlmrag/rag.toml。",
            "Status": "狀態",
            "Check Again": "重新檢查",
            "Not checked yet.": "尚未檢查。",
            "Copied": "已複製",
            "Copy {item}": "複製{item}",
            "System": "系統",
            "Display": "顯示",
            "Privacy Policy": "私隱政策",
            "Open Privacy Policy": "開啟私隱政策",
            "This app keeps questions, answers, and settings on your Mac.": "此應用程式將問題、回答和設定留在你的 Mac 上。",
            "Interface Language": "介面語言",
            "Compare Tabs": "比較分頁",
            "rag exited with code {code}.": "rag 已結束，結束代碼為 {code}。",
            "This path is a folder, not an executable rag. A corpus folder must contain rag.toml. Put that folder in the working directory.": "此路徑是資料夾，而非可執行的 rag。語料庫資料夾必須包含 rag.toml，請將該資料夾設為工作目錄。",
            "This path is not an executable rag.": "此路徑不是可執行的 rag。",
            "Working directory set to {path}, using the program inside it.": "已將工作目錄設為 {path}，並使用其中的程式。",
            "Working directory set to {path}.": "已將工作目錄設為 {path}。",
            "Checking status": "正在檢查狀態",
            "This item isn't supported. Ingest accepts pdf, docx, pptx, text, and images, one file at a time.": "不支援此項目。入庫僅接受 pdf、docx、pptx、純文字與圖片，每次處理一個檔案。",
            "Skipped {count} unsupported items.": "已略過 {count} 個不支援的項目。",
            "Wait for the current job to finish before asking.": "請等待目前的工作完成後再提問。",
            "Cancelled.": "已取消。",
            "Ingest {name}": "入庫 {name}",
            "Working directory does not exist: {path}": "工作目錄不存在：{path}",
            "Python wasn't found, so the rag in that folder can't run.": "找不到 Python，因此無法執行該資料夾中的 rag。",
            "rag wasn't found. Install it with Homebrew: brew install mark1688288/mmlmrag/mmlmrag, or set the executable path yourself.": "找不到 rag。請使用 Homebrew 安裝：brew install mark1688288/mmlmrag/mmlmrag，或手動設定可執行檔路徑。",
            "corpus.sqlite wasn't found in the working directory.": "在工作目錄中找不到 corpus.sqlite。",
            "Couldn't open corpus.sqlite: {detail}": "無法開啟 corpus.sqlite：{detail}",
            "Answer order": "回答順序",
            "Page number": "頁碼",
            "Couldn't open this PDF.": "無法開啟此 PDF。",
            "This file isn't a PDF, so its pages can't be previewed.": "此檔案不是 PDF，因此無法預覽頁面。",
            "File does not exist: {path}": "檔案不存在：{path}",
            "The corpus has no “{name}”.": "語料庫中沒有「{name}」。",
            "There is no page {page}.": "沒有第 {page} 頁。",
            "Page {page} has no size.": "第 {page} 頁沒有尺寸資訊。",
            "Recognizing text…": "正在識別文字…",
            "Copy": "複製",
            "Select All": "全選",
            "Open Image": "開啟圖片",
            "Hand": "手形工具",
            "Drag to move the picture": "拖曳以移動圖片",
            "Select Text": "選取文字",
            "Select text on the picture": "選取圖片上的文字",
            "Pin": "釘選",
            "Keep the picture in front of other windows": "讓圖片保持在其他視窗最前方",
            "Keep this window in front of other windows": "讓此視窗保持在其他視窗最前方",
            "No text recognized on this picture.": "此圖片上未識別出文字。",
            "Zoom In": "放大",
            "Zoom Out": "縮小",
            "Zoom": "縮放",
            "Fit": "適合大小",
            "Image {number}": "圖片 {number}",
            "No text recognized on this page.": "此頁面上未識別出文字。",
            "Sort": "排序",
            "Choose how document pages are sorted": "選擇文件頁面的排序方式",
            "Loading document pages…": "正在載入文件頁面…",
            "Can't preview": "無法預覽",
            "No document pages yet": "尚無文件頁面",
            "Document pages cited in the answer are listed here from top to bottom in answer order.": "回答中引用的文件頁面會依回答順序由上至下顯示於此。",
            "Document pages cited in the answer are listed here by page number.": "回答中引用的文件頁面會依頁碼順序顯示於此。",
            "Drag to select text, then press ⌘C to copy. Scanned pages are recognized first.": "拖曳以選取文字，然後按 ⌘C 複製。掃描頁面會先進行文字識別。",
            "{filename} page {page}": "{filename} 第 {page} 頁",
            "Recognizing": "正在識別",
            "No matches": "沒有符合項目",
            "Match {index} of {total}, recognizing": "第 {index} 項，共 {total} 項，正在識別",
            "Match {index} of {total}": "第 {index} 項，共 {total} 項",
            "Search selectable text on the preview pages. Return or ⌘G for the next match, ⇧⌘G for the previous. Scanned pages are recognized first.": "搜尋預覽頁面中可選取的文字。按 Return 或 ⌘G 跳至下一個符合項目，按 ⇧⌘G 跳至上一個。掃描頁面會先進行文字識別。",
            "Search the text layer": "搜尋文字層",
            "Previous": "上一個",
            "Next": "下一個",
            "Need two answered tabs": "需要兩個已有回答的分頁",
            "Open at least two mmlmRAG tabs that already have answers.": "請開啟至少兩個已有回答的 mmlmRAG 分頁。",
            "Left": "左側",
            "Right": "右側",
            "Show right": "顯示右側",
            "Show left": "顯示左側",
            "Same order as the window tabs, left to right.": "順序與視窗分頁相同，由左至右。",
            "Question": "提問",
            "No question yet.": "尚無提問。",
            "No answer yet.": "尚無回答。",
            "There's no question to save.": "沒有可儲存的提問。",
            "Couldn't delete the question: {detail}": "無法刪除提問：{detail}",
            "Couldn't read questions: {detail}": "無法讀取提問：{detail}",
            "Couldn't open questions: {detail}": "無法開啟提問：{detail}",
            "Couldn't write the question: {detail}": "無法寫入提問：{detail}",
            "No saved questions": "尚無已儲存的提問",
            "Saved questions and answers will be listed here.": "已儲存的提問與回答會顯示於此。",
            "Assistant is checking": "助理正在核對",
            "Searching": "正在搜尋",
            "No matching questions": "找不到相符的提問",
            "Checking whether this sentence really matches, including negation.": "正在檢查此句子是否真正符合，包含否定語意。",
            "Comparing this sentence with saved questions and answers.": "正在將此句子與已儲存的提問和回答進行比對。",
            "Try another sentence, or clear the search.": "請嘗試其他句子，或清除搜尋。",
            "Assistant excluded the negated wording": "助理已排除否定用語",
            "Assistant isn't ready. Negation rules were used instead.": "助理尚未就緒，已改用否定規則處理。",
            "Assistant didn't respond. Negation rules were used instead.": "助理未回應，已改用否定規則處理。",
            "Search questions and answers in plain language": "以自然語言搜尋提問與回答",
            "Search history": "搜尋歷史記錄",
            "Clear search": "清除搜尋",
            "Search with one sentence. The assistant understands negation, for example「冇提過黃碧嬌」.": "用一句話進行搜尋。助理能理解否定語意，例如「冇提過黃碧嬌」。",
            "Deselect All": "取消全選",
            "{count} selected": "已選取 {count} 則",
            "Delete": "刪除",
            "Select questions to delete first": "請先選取要刪除的提問",
            "Delete {count} selected questions": "刪除已選取的 {count} 則提問",
            "Select this question": "選取此提問",
            "Load this question and answer": "載入此提問與回答",
            "Open in New Tab": "在新分頁中開啟",
            "Delete question": "刪除提問",
            "Delete this question? This can't be undone.": "確定要刪除此提問嗎？此操作無法還原。",
            "Delete {count} questions? This can't be undone.": "確定要刪除這 {count} 則提問嗎？此操作無法還原。",
            "No answer yet": "尚無回答",
            "Load this question": "載入此提問",
            "{stamp}, {question}": "{stamp}，{question}",
            "The answer isn't finished. Leave without saving this question?": "回答尚未完成。確定不儲存此提問並離開嗎？",
            "Leave without saving this question?": "確定不儲存此提問並離開嗎？",
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
