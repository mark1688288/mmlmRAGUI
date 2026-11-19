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

/// Path and corpus directory shared by every window. Each window still has its own conversation.
@MainActor
@Observable
final class RagSettings {
    var ragPath: String {
        didSet { defaults.set(ragPath, forKey: Keys.path) }
    }

    var workingDirectory: String {
        didSet { defaults.set(workingDirectory, forKey: Keys.directory) }
    }

    var statusText = "未檢查。"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let path = "ragExecutablePath"
        static let directory = "ragWorkingDirectory"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ragPath = defaults.string(forKey: Keys.path) ?? ""
        workingDirectory = defaults.string(forKey: Keys.directory) ?? home
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

    private let settings: RagSettings

    var ragPath: String {
        get { settings.ragPath }
        set { settings.ragPath = newValue }
    }

    var workingDirectory: String {
        get { settings.workingDirectory }
        set { settings.workingDirectory = newValue }
    }

    var statusText: String {
        get { settings.statusText }
        set { settings.statusText = newValue }
    }

    var logText = ""
    var answerText = ""
    var question = ""
    var isBusy = false
    var busyLabel = ""
    /// True while an `ask` is in flight, including the wait before the first line.
    private(set) var isAsking = false
    var errorMessage: String?
    var notice: String?
    private(set) var queuedCount = 0

    private var ingestQueue: [URL] = []
    private var job: Task<Void, Never>?
    private var jobGeneration = 0
    private var didPrepare = false
    /// Launch status hits the shared settings text once. Later windows skip it so they can ask immediately.
    private static var didCheckStatus = false

    init(settings: RagSettings) {
        self.settings = settings
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        guard !Self.didCheckStatus else { return }
        Self.didCheckStatus = true
        await refreshStatus()
    }

    func usePathAndRefresh() async {
        notice = nil
        let expanded = (ragPath as NSString).expandingTildeInPath
        if Self.isDirectory(expanded) {
            guard Self.projectRoot(at: expanded) != nil else {
                errorMessage = "呢個路徑係資料夾，唔係可執行的 rag。語料目錄要包含 rag.toml，請填喺工作目錄。"
                return
            }
        } else if Self.isRunnableFile(expanded) {
            ragPath = expanded
        } else {
            errorMessage = "呢個路徑唔係可執行的 rag。"
            return
        }
        guard await locateIfNeeded() else {
            errorMessage = missingToolMessage
            return
        }
        if Self.isDirectory(expanded) {
            if Self.sourceRoot(near: workingDirectory) != nil {
                notice = "工作目錄已設為 \(workingDirectory)，並用裡面的程式。"
            } else {
                notice = "工作目錄已設為 \(workingDirectory)。"
            }
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
            statusText = missingToolMessage
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
        guard let generation = beginJob(label: "等緊 rag 回覆…") else {
            notice = "等而家呢個工作完先再提問。"
            return
        }
        isAsking = true
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
        isAsking = false
        busyLabel = ""
        notice = "已取消。"
    }

    private func performAsk(_ trimmed: String, generation: Int) async {
        guard await locateIfNeeded() else {
            errorMessage = missingToolMessage
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
            errorMessage = missingToolMessage
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
        isAsking = false
        busyLabel = ""
    }

    private func consume(
        arguments: [String],
        onLine: @escaping @MainActor (String, Bool) -> Void
    ) async {
        guard let launch = await resolveLaunch() else {
            errorMessage = missingToolMessage
            return
        }
        guard let directory = workingDirectoryURL else {
            errorMessage = "工作目錄唔存在：\(workingDirectory)"
            return
        }

        let stream = RagCommand.stream(
            executable: launch.executable,
            arguments: launch.prefix + arguments,
            workingDirectory: directory,
            environment: environmentForRag(extra: launch.extraEnvironment)
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
        await resolveLaunch() != nil
    }

    private struct RagLaunch {
        var executable: String
        var prefix: [String]
        var extraEnvironment: [String: String]
    }

    /// `main()` reads `sys.argv`, so the child is `python -c <this> <rag args>`.
    private static let sourceBootstrap = "from ragcli.cli import main; raise SystemExit(main())"

    /// A checkout wins over an installed `rag`. The installed copy can be older
    /// than the SQLite schema in that folder, and then `status` refuses to run.
    private func resolveLaunch() async -> RagLaunch? {
        adoptProjectDirectoryIfNeeded()
        if Self.isRunnableFile(ragPath) {
            return RagLaunch(
                executable: (ragPath as NSString).expandingTildeInPath,
                prefix: [],
                extraEnvironment: [:]
            )
        }
        if let source = Self.sourceRoot(near: workingDirectory) ?? Self.sourceRoot(near: ragPath) {
            guard let python = Self.pythonExecutable(for: source) else { return nil }
            let src = (source as NSString).appendingPathComponent("src")
            return RagLaunch(
                executable: python,
                prefix: ["-c", Self.sourceBootstrap],
                extraEnvironment: ["PYTHONPATH": src]
            )
        }
        guard let found = await resolveExecutable() else { return nil }
        if ragPath != found {
            ragPath = found
        }
        return RagLaunch(executable: found, prefix: [], extraEnvironment: [:])
    }

    private var missingToolMessage: String {
        if Self.sourceRoot(near: workingDirectory) != nil || Self.sourceRoot(near: ragPath) != nil {
            return "搵唔到 Python，未能執行資料夾入面的 rag。"
        }
        return "搵唔到 rag。可以用 Homebrew 裝：brew install mark1688288/mmlmrag/mmlmrag，或者自己填上可執行檔路徑。"
    }

    private static func sourceRoot(near path: String) -> String? {
        guard let root = projectRoot(at: path) else { return nil }
        let cli = (root as NSString).appendingPathComponent("src/ragcli/cli.py")
        guard FileManager.default.isReadableFile(atPath: cli) else { return nil }
        return root
    }

    private static func pythonExecutable(for sourceRoot: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            sourceRoot + "/.venv/bin/python",
            sourceRoot + "/venv/bin/python",
            home + "/.mmlmrag/venv/bin/python",
            "/opt/homebrew/bin/python3.13",
            "/usr/local/bin/python3.13",
        ]
        return candidates.first(where: isRunnableFile)
    }

    /// A searchable directory also passes `isExecutableFile`. Launching it
    /// returns EACCES, shown as "Permission denied". A folder that contains
    /// `rag.toml` is the corpus, so keep it as the working directory.
    private func adoptProjectDirectoryIfNeeded() {
        let expanded = (ragPath as NSString).expandingTildeInPath
        guard Self.isDirectory(expanded), let project = Self.projectRoot(at: expanded) else {
            return
        }
        if workingDirectory != project {
            workingDirectory = project
        }
    }

    private func resolveExecutable() async -> String? {
        if Self.isRunnableFile(ragPath) {
            return (ragPath as NSString).expandingTildeInPath
        }
        let nearby = Self.localExecutableCandidates(near: workingDirectory)
        if let found = (nearby + Self.candidatePaths).first(where: Self.isRunnableFile) {
            return found
        }
        if let found = await Self.whichViaLoginShell(), Self.isRunnableFile(found) {
            return found
        }
        return nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isRunnableFile(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !isDirectory(expanded) else { return false }
        return FileManager.default.isExecutableFile(atPath: expanded)
    }

    /// The checkout that owns `rag.toml`, walking up from `path`.
    /// Corpus lookup uses the same root to find `data/corpus.sqlite`.
    static func projectRoot(at path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        if !isDirectory(url.path) {
            url.deleteLastPathComponent()
        }
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("rag.toml").path) {
                return url.path
            }
            if url.path == "/" {
                return nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func localExecutableCandidates(near directory: String) -> [String] {
        let expanded = (directory as NSString).expandingTildeInPath
        let root = projectRoot(at: expanded) ?? (isDirectory(expanded) ? expanded : nil)
        guard let root else { return [] }
        return [
            root + "/.venv/bin/rag",
            root + "/venv/bin/rag",
        ]
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
    private func environmentForRag(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin"
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(prefix):\(current)"
        env["PYTHONUNBUFFERED"] = "1"
        // Xcode injects DYLD_INSERT_LIBRARIES. A child Python aborts if it stays set.
        for key in Array(env.keys) where key.hasPrefix("DYLD_") {
            env.removeValue(forKey: key)
        }
        for (key, value) in extra {
            if key == "PYTHONPATH", let existing = env["PYTHONPATH"], !existing.isEmpty {
                env[key] = "\(value):\(existing)"
            } else {
                env[key] = value
            }
        }
        return env
    }

    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/rag",
            "/usr/local/bin/rag",
            home + "/.local/bin/rag",
            home + "/.mmlmrag/venv/bin/rag",
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
