import Foundation
import Observation
import UniformTypeIdentifiers

#if os(macOS)

/// One running `rag` process. Opted out of the default main-actor isolation
/// so the stream can terminate it from a sendable completion handler.
nonisolated private final class RunningCommand: @unchecked Sendable {
    let process = Process()

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}

enum RagCommandError: LocalizedError {
    case launch(String)
    case exit(Int32)

    var errorDescription: String? {
        switch self {
        case .launch(let message):
            return message
        case .exit(let code):
            return "rag 結束，代碼 \(code)。"
        }
    }
}

enum RagCommand {
    /// Streams merged stdout and stderr, one line at a time.
    /// `PYTHONUNBUFFERED` is set because Python block-buffers pipes.
    static func stream(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let running = RunningCommand()
            let process = running.process
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.currentDirectoryURL = workingDirectory
            process.environment = environment

            let reader = Task.detached {
                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: RagCommandError.launch(error.localizedDescription))
                    return
                }

                do {
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                    process.waitUntilExit()
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let code = process.terminationStatus
                    if code == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: RagCommandError.exit(code))
                    }
                } catch is CancellationError {
                    running.terminateIfRunning()
                    continuation.finish()
                } catch {
                    running.terminateIfRunning()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                reader.cancel()
                running.terminateIfRunning()
            }
        }
    }
}

@MainActor
@Observable
final class RagSession {
    static let acceptedExtensions: Set<String> = [
        "pdf", "docx", "pptx", "txt", "md",
        "png", "jpg", "jpeg", "webp", "tif", "tiff",
        "gif", "bmp", "heic", "heif",
    ]

    static var importTypes: [UTType] {
        acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    var ragPath: String {
        didSet { defaults.set(ragPath, forKey: Keys.path) }
    }

    var workingDirectory: String {
        didSet { defaults.set(workingDirectory, forKey: Keys.directory) }
    }

    var statusText = "未檢查。"
    var logText = ""
    var answerText = ""
    var question = ""
    var isBusy = false
    var busyLabel = ""
    var errorMessage: String?
    var notice: String?
    private(set) var queuedCount = 0

    private let defaults = UserDefaults.standard
    private var ingestQueue: [URL] = []
    private var job: Task<Void, Never>?
    private var jobGeneration = 0
    private var didPrepare = false

    private enum Keys {
        static let path = "ragExecutablePath"
        static let directory = "ragWorkingDirectory"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ragPath = defaults.string(forKey: Keys.path) ?? ""
        workingDirectory = defaults.string(forKey: Keys.directory) ?? home
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        await refreshStatus()
    }

    func usePathAndRefresh() async {
        notice = nil
        guard FileManager.default.isExecutableFile(atPath: ragPath) else {
            errorMessage = "呢個路徑唔係可執行的 rag。"
            return
        }
        await refreshStatus()
    }

    func refreshStatus() async {
        guard let generation = beginJob(label: "檢查狀態") else { return }
        let task = Task { await performStatus(generation: generation) }
        job = task
        await task.value
    }

    private func performStatus(generation: Int) async {
        guard await locateIfNeeded() else {
            statusText = "搵唔到 rag。可以用 Homebrew 裝：brew install mark1688288/mmlmrag/mmlmrag，或者自己填上可執行檔路徑。"
            finish(generation: generation)
            return
        }
        statusText = ""
        await consume(arguments: ["status"]) { [weak self] line, _ in
            self?.statusText += line + "\n"
        }
        finish(generation: generation)
    }

    func enqueueIngest(_ urls: [URL]) {
        let files = urls.filter { Self.isAcceptedFile($0) }
        let skipped = urls.count - files.count
        guard !files.isEmpty else {
            errorMessage = "唔支援呢個項目。入庫接受 pdf、docx、pptx、文字同圖像，每次一個檔案。"
            return
        }
        ingestQueue.append(contentsOf: files)
        queuedCount = ingestQueue.count
        if skipped > 0 {
            notice = "跳過 \(skipped) 個唔支援的項目。"
        }
        kickQueue()
    }

    func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let generation = beginJob(label: "提問") else {
            notice = "等而家呢個工作完先再提問。"
            return
        }
        answerText = ""
        logText = ""
        job = Task {
            await performAsk(trimmed, generation: generation)
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        jobGeneration += 1
        ingestQueue.removeAll()
        queuedCount = 0
        isBusy = false
        busyLabel = ""
        notice = "已取消。"
    }

    private func performAsk(_ trimmed: String, generation: Int) async {
        guard await locateIfNeeded() else {
            errorMessage = "搵唔到 rag，未能提問。"
            finish(generation: generation)
            return
        }
        await consume(arguments: ["ask", trimmed]) { [weak self] line, isLog in
            guard let self else { return }
            if isLog {
                self.logText += line + "\n"
            } else if !line.isEmpty || !self.answerText.isEmpty {
                self.answerText += line + "\n"
            }
        }
        finish(generation: generation)
        kickQueue()
    }

    private func kickQueue() {
        guard !isBusy, !ingestQueue.isEmpty else {
            queuedCount = ingestQueue.count
            return
        }
        let url = ingestQueue.removeFirst()
        queuedCount = ingestQueue.count
        guard let generation = beginJob(label: "入庫 \(url.lastPathComponent)") else {
            ingestQueue.insert(url, at: 0)
            queuedCount = ingestQueue.count
            return
        }
        logText = ""
        job = Task {
            await performIngest(url, generation: generation)
        }
    }

    private func performIngest(_ url: URL, generation: Int) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard await locateIfNeeded() else {
            errorMessage = "搵唔到 rag，未能入庫。"
            ingestQueue.removeAll()
            queuedCount = 0
            finish(generation: generation)
            return
        }
        await consume(arguments: ["ingest", url.path]) { [weak self] line, _ in
            self?.logText += line + "\n"
        }
        finish(generation: generation)
        kickQueue()
    }

    private func beginJob(label: String) -> Int? {
        guard !isBusy else { return nil }
        isBusy = true
        busyLabel = label
        jobGeneration += 1
        return jobGeneration
    }

    /// Ignore a finish from a job that cancel, or a newer job, already replaced.
    private func finish(generation: Int) {
        guard generation == jobGeneration else { return }
        isBusy = false
        busyLabel = ""
    }

    private func consume(
        arguments: [String],
        onLine: @escaping @MainActor (String, Bool) -> Void
    ) async {
        guard let executable = executableURL else {
            errorMessage = "搵唔到 rag。"
            return
        }
        guard let directory = workingDirectoryURL else {
            errorMessage = "工作目錄唔存在：\(workingDirectory)"
            return
        }

        let stream = RagCommand.stream(
            executable: executable.path,
            arguments: arguments,
            workingDirectory: directory,
            environment: environmentForRag()
        )

        do {
            for try await line in stream {
                try Task.checkCancellation()
                onLine(line, Self.isLogLine(line))
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateIfNeeded() async -> Bool {
        if FileManager.default.isExecutableFile(atPath: ragPath) {
            return true
        }
        if let found = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            ragPath = found
            return true
        }
        if let found = await Self.whichViaLoginShell(), FileManager.default.isExecutableFile(atPath: found) {
            ragPath = found
            return true
        }
        return false
    }

    private var executableURL: URL? {
        guard FileManager.default.isExecutableFile(atPath: ragPath) else { return nil }
        return URL(fileURLWithPath: ragPath)
    }

    private var workingDirectoryURL: URL? {
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// GUI apps do not inherit a Homebrew PATH. The child still needs it
    /// when `rag` locates Python or Ollama.
    private func environmentForRag() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin"
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(prefix):\(current)"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/rag",
            "/usr/local/bin/rag",
            home + "/.local/bin/rag",
        ]
    }

    private static func whichViaLoginShell() async -> String? {
        let running = RunningCommand()
        let process = running.process
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v rag"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return await Task.detached { () -> String? in
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty, !text.contains("\n") else { return nil }
            return text
        }.value
    }

    private static func isAcceptedFile(_ url: URL) -> Bool {
        url.isFileURL && acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// `rag` writes human log lines before the answer. There is no JSON mode yet.
    private static func isLogLine(_ line: String) -> Bool {
        let prefixes = ["INFO ", "WARNING ", "ERROR ", "DEBUG ", "CRITICAL "]
        return prefixes.contains { line.hasPrefix($0) }
    }
}

#endif
