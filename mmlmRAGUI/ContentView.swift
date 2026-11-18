import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    #if os(macOS)
    @State private var session = RagSession()
    @State private var isTargeted = false
    @State private var showImporter = false
    #endif

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        ContentUnavailableView(
            "mmlmRAG",
            systemImage: "macwindow",
            description: Text("呢個雛型淨係係 macOS 呼叫本機的 rag 命令。")
        )
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("mmlmRAG")
        .task {
            await session.prepare()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: RagSession.importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                session.enqueueIngest(urls)
            case .failure(let error):
                session.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "做唔到",
            isPresented: errorPresented
        ) {
            Button("好") {
                session.errorMessage = nil
            }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("rag 路徑")
                    .font(.headline)
                TextField("/opt/homebrew/bin/rag", text: $session.ragPath)
                    .textFieldStyle(.roundedBorder)
                Button("使用此路徑") {
                    Task { await session.usePathAndRefresh() }
                }
                .disabled(session.isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("工作目錄")
                    .font(.headline)
                TextField("~", text: $session.workingDirectory)
                    .textFieldStyle(.roundedBorder)
                Text("上層有 rag.toml 就用佢。否則用 ~/.mmlmrag/rag.toml。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("狀態")
                        .font(.headline)
                    Spacer()
                    Button("重新檢查") {
                        Task { await session.refreshStatus() }
                    }
                    .disabled(session.isBusy)
                }
                ScrollView {
                    Text(session.statusText.isEmpty ? " " : session.statusText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            dropZone
            questionRow
            outputPane(title: "回答", text: session.answerText, placeholder: "回答會顯示在呢度。")
            outputPane(title: "記錄", text: session.logText, placeholder: "入庫同提問的記錄會顯示在呢度。", monospaced: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if session.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(session.busyLabel)
                    .font(.headline)
                if session.queuedCount > 0 {
                    Text("仲有 \(session.queuedCount) 個排隊")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) {
                    session.cancel()
                }
            } else {
                Text("本機語料")
                    .font(.headline)
                Spacer()
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
            Text(isTargeted ? "放低就入庫" : "拖一個檔入呢度，或者揀一個檔")
            Text("pdf、docx、pptx、文字、圖像。每次交一個檔界 rag ingest。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("揀檔案…") {
                showImporter = true
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            session.enqueueIngest(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var questionRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("問語料一條問題", text: $session.question, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            Button("提問") {
                session.ask()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.isBusy || session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func outputPane(title: String, text: String, placeholder: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: monospaced ? 90 : 140, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    #endif
}

#Preview {
    ContentView()
}
