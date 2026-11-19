import Foundation
import SQLite3

#if os(macOS)

/// Reads `source_path` from the working directory's `data/corpus.sqlite`.
///
/// `data_dir` comes from the `rag.toml` next to that database. A relative
/// `data_dir` is resolved from the directory that contains `rag.toml`.
enum CorpusLookup {
    enum DatabaseFailure: Error, Equatable {
        case missing
        case unreadable(String)

        var message: String {
            switch self {
            case .missing:
                return "搵唔到工作目錄入面的 corpus.sqlite。"
            case .unreadable(let detail):
                return "打唔開 corpus.sqlite：\(detail)"
            }
        }
    }

    /// Candidate absolute paths for each filename, newest ingest first.
    static func sourcePaths(
        for filenames: [String],
        workingDirectory: String
    ) -> Result<[String: [String]], DatabaseFailure> {
        let unique = filenames.reduce(into: [String]()) { list, name in
            if !list.contains(name) {
                list.append(name)
            }
        }
        guard !unique.isEmpty else { return .success([:]) }
        guard let databasePath = databasePath(workingDirectory: workingDirectory) else {
            return .failure(.missing)
        }
        let database: OpaquePointer
        switch openReadOnly(at: databasePath) {
        case .ready(let handle):
            database = handle
        case .failed(let detail):
            return .failure(.unreadable(detail))
        }
        defer { sqlite3_close(database) }

        var found: [String: [String]] = [:]
        for filename in unique {
            switch paths(for: filename, in: database) {
            case .failed(let detail):
                return .failure(.unreadable(detail))
            case .paths(let paths):
                found[filename] = paths
            }
        }
        return .success(found)
    }

    /// `rag.toml`'s data directory plus `corpus.sqlite`, if that file exists.
    static func databasePath(workingDirectory: String) -> String? {
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        for root in configRoots(expanded) {
            let database = (dataDirectory(projectRoot: root) as NSString)
                .appendingPathComponent("corpus.sqlite")
            if FileManager.default.fileExists(atPath: database) {
                return database
            }
        }
        return nil
    }

    private static func configRoots(_ expandedWorkingDirectory: String) -> [String] {
        var roots: [String] = []
        if let project = RagSession.projectRoot(at: expandedWorkingDirectory) {
            roots.append(project)
        }
        let homeConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mmlmrag")
            .path
        let homeToml = (homeConfig as NSString).appendingPathComponent("rag.toml")
        if FileManager.default.fileExists(atPath: homeToml), !roots.contains(homeConfig) {
            roots.append(homeConfig)
        }
        return roots
    }

    private static func dataDirectory(projectRoot: String) -> String {
        let relative = dataDirSetting(projectRoot: projectRoot) ?? "data"
        let expanded = (relative as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    /// The `data_dir` string in `rag.toml`, without resolving it.
    private static func dataDirSetting(projectRoot: String) -> String? {
        let toml = URL(fileURLWithPath: projectRoot).appendingPathComponent("rag.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"^[ \t]*data_dir[ \t]*=[ \t]*["']([^"']+)["']"#,
            options: [.anchorsMatchLines]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    private enum OpenedDatabase {
        case ready(OpaquePointer)
        case failed(String)
    }

    /// Read-write plus `query_only`. A read-only open can succeed and then fail
    /// every statement with "unable to open database file" while `rag` still has
    /// the WAL open. That used to look like the filename was missing.
    private static func openReadOnly(at path: String) -> OpenedDatabase {
        var database: OpaquePointer?
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database {
            sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)
            return .ready(database)
        }
        let readwriteError = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(database)
        database = nil
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database {
            return .ready(database)
        }
        let readonlyError = database.map { String(cString: sqlite3_errmsg($0)) } ?? readwriteError
        sqlite3_close(database)
        return .failed(readonlyError)
    }

    private enum PathQuery {
        case paths([String])
        case failed(String)
    }

    private static func paths(for filename: String, in database: OpaquePointer) -> PathQuery {
        let sql = "SELECT source_path FROM documents WHERE filename = ? ORDER BY ingested_at DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return .failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_STATIC: the bytes must stay alive until sqlite3_step finishes.
        let bytes = Array(filename.utf8CString)
        return bytes.withUnsafeBufferPointer { buffer in
            guard sqlite3_bind_text(statement, 1, buffer.baseAddress, -1, nil) == SQLITE_OK else {
                return .failed(String(cString: sqlite3_errmsg(database)))
            }
            var paths: [String] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(statement, 0) else { continue }
                    paths.append(String(cString: raw))
                    continue
                }
                if step == SQLITE_DONE {
                    return .paths(paths)
                }
                return .failed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}

#endif
