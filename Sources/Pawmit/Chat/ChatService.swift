import Foundation
import PawmitCore

/// 펫과의 일반 대화. API 키를 따로 받지 않고 사용자가 이미 로그인해 둔 `claude`(없으면 `codex`) CLI를 쓴다.
///
/// - `claude -p --safe-mode`: CLAUDE.md·hook·MCP·플러그인을 끄고 로그인은 유지 (펫 자신의 hook이 다시 펫을 부르지 않게)
/// - `--tools ""`: 대화만, 파일·명령 도구는 쓰지 않음
/// - `--resume <id>`: 대화 이어가기
@MainActor
final class ChatService {
    var config: PawmitConfig
    var sessionID: String?
    private var process: Process?
    private var apiTask: Task<Void, Never>?
    private var resolvedClaude: String??
    private var resolvedCodex: String??
    private var resolvedGemini: String??
    let keys: ChatKeyStore
    /// API 대화 기록 (CLI는 --resume으로 이어가고, API는 여기 쌓아 보낸다)
    private var history: [APIChat.Message] = []
    /// 모델을 고르지 않은 API provider에서 자동으로 고른 모델 (이번 실행 동안)
    private var autoModels: [String: String] = [:]

    init(config: PawmitConfig, sessionID: String?, keys: ChatKeyStore = ChatKeychain()) {
        self.config = config
        self.sessionID = sessionID
        self.keys = keys
        loadHistory()
    }

    var isBusy: Bool { process?.isRunning == true || apiTask != nil }

    func cancel() {
        process?.terminate()
        process = nil
        apiTask?.cancel()
        apiTask = nil
    }

    /// API 방식 대화 기록을 ~/.pawmit/chat-history.json에서 되살려 재시작 후에도 이어 간다 (CLI 대화는 세션 resume).
    private func loadHistory() {
        guard let data = try? Data(contentsOf: PawmitPaths.chatHistory),
              let list = try? JSONDecoder.pawmit.decode([APIChat.Message].self, from: data) else { return }
        history = list
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder.pawmit.encode(history) else { return }
        try? data.write(to: PawmitPaths.chatHistory, options: .atomic)
    }

    func resetConversation() {
        sessionID = nil
        history = []
        try? FileManager.default.removeItem(at: PawmitPaths.chatHistory)
    }

    var providerName: String {
        switch provider() {
        case .claude: return "Claude CLI"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .api(let info, _): return info.name
        case .none: return "없음"
        }
    }

    private enum Provider { case claude(String), codex(String), gemini(String), api(ChatProviderInfo, ChatAPIStyle), none(String) }

    /// 이번 실행 중 Claude 인증 실패를 본 적 있으면 자동 모드에서 바로 Codex를 쓴다
    private var claudeAuthFailed = false

    /// 설정된 대화 provider (CLI·HTTP API·커스텀). 예전 설정값 claude·codex는 claude-cli·codex-cli로 읽는다.
    private func provider() -> Provider {
        let id = config.chat.providerID
        switch id {
        case "off": return .none(L10n.t("대화가 꺼져 있어요. 설정 → 대화에서 켜 주세요."))
        case "auto":
            if claudeAuthFailed, let codex = codexPath() { return .codex(codex) }
            if let claude = claudePath() { return .claude(claude) }
            if let codex = codexPath() { return .codex(codex) }
            return .none(L10n.t("대화할 AI CLI(claude 또는 codex)를 찾지 못했어요. 설정 → 대화에서 다른 provider를 골라 주세요."))
        case "claude-cli":
            return claudePath().map(Provider.claude) ?? .none(L10n.t("claude CLI를 찾지 못했어요. 설정에서 경로를 지정해 주세요."))
        case "codex-cli":
            return codexPath().map(Provider.codex) ?? .none(L10n.t("codex CLI를 찾지 못했어요. 설정에서 경로를 지정해 주세요."))
        case "gemini-cli":
            return geminiPath().map(Provider.gemini) ?? .none(L10n.t("gemini CLI를 찾지 못했어요. 설정에서 경로를 지정해 주세요."))
        default:
            if let info = ChatProviders.provider(id, custom: config.chat.customProviders), case .api(let style) = info.kind {
                return .api(info, style)
            }
            return .none(L10n.format("대화 provider '%@'를 찾지 못했어요.", id))
        }
    }

    /// 대화 한 번. onDelta는 스트리밍 조각, onDone은 최종 텍스트(실패 시 nil, 이유).
    func ask(_ message: String, persona: String, onDelta: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        cancel()
        switch provider() {
        case .claude(let path): runClaude(path: path, message: message, persona: persona, safeMode: true, onDelta: onDelta, onDone: onDone)
        case .codex(let path): runCodex(path: path, message: message, persona: persona, onDone: onDone)
        case .gemini(let path): runGemini(path: path, message: message, persona: persona, onDone: onDone)
        case .api(let info, let style): runAPI(info, style: style, message: message, persona: persona, onDelta: onDelta, onDone: onDone)
        case .none(let why): onDone(nil, why)
        }
    }

    // MARK: - HTTP API

    private func runAPI(_ info: ChatProviderInfo, style: ChatAPIStyle, message: String, persona: String,
                        onDelta: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        let key = keys.key(for: info.id)
        if info.needsKey, key == nil {
            onDone(nil, L10n.format("%@ API 키가 없어요. 설정 → 대화에서 키를 넣어 주세요.", info.name))
            return
        }
        guard let base = info.baseURL else { onDone(nil, L10n.t("주소가 없어요")); return }
        let chosen = config.chat.model(for: info.id) ?? autoModels[info.id]
        let msgs = Array((history + [APIChat.Message(role: "user", content: message)]).suffix(24))
        let deliver: @Sendable (String) -> Void = { partial in DispatchQueue.main.async { onDelta(partial) } }
        apiTask = Task { @MainActor [weak self] in
            do {
                var model = chosen
                if model == nil {
                    // 모델을 안 골랐으면 목록에서 빠른 모델을 골라 쓴다
                    let ids = try await APIChat.listModels(style: style, baseURL: base, apiKey: key)
                    model = APIChat.pickFastModel(ids)
                    if let model { self?.autoModels[info.id] = model }
                }
                guard let model else { throw APIChat.APIError.noModels }
                let text = try await APIChat.stream(.init(style: style, baseURL: base, apiKey: key, model: model),
                                                    system: persona, messages: msgs, onDelta: deliver)
                guard !Task.isCancelled else { return }
                self?.history = Array((msgs + [APIChat.Message(role: "assistant", content: text)]).suffix(24))
                self?.saveHistory()
                self?.apiTask = nil
                onDone(text, nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.apiTask = nil
                Log.info("chat api failed provider=\(info.id)")
                onDone(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Gemini CLI

    private func runGemini(path: String, message: String, persona: String, onDone: @escaping (String?, String?) -> Void) {
        var args = ["-p", "\(persona)\n\n\(L10n.t("사용자:")) \(message)"]
        if let m = config.chat.model(for: "gemini-cli"), !m.isEmpty { args += ["-m", m] }
        let proc = makeProcess(path, args)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.process = nil
                if !text.isEmpty, p.terminationStatus == 0 { onDone(text, nil) }
                else { onDone(nil, L10n.format("Gemini CLI가 대답하지 않았어요 (종료 코드 %@)", "\(p.terminationStatus)")) }
            }
        }
        launch(proc, onDone: onDone)
    }

    private func runClaude(path: String, message: String, persona: String, safeMode: Bool,
                           onDelta: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        var args = ["-p", message, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--model", config.chat.model(for: "claude-cli") ?? "haiku", "--tools", "", "--append-system-prompt", persona]
        if safeMode {
            args.append("--safe-mode")
        } else {
            args += ["--settings", #"{"disableAllHooks": true}"#, "--disallowedTools", "mcp__*"]
        }
        if let sessionID {
            args += ["--resume", sessionID]
        }
        let proc = makeProcess(path, args)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        var buffer = Data()
        var streamed = ""
        var final: String?
        var newSession: String?
        var isError = false
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let piece = ChatActions.parseStreamLine(line) else { continue }
                    if let sid = piece.sessionID { newSession = sid }
                    if let d = piece.delta {
                        streamed += d
                        onDelta(streamed)
                    }
                    if let r = piece.result { final = r; isError = piece.isError }
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.process = nil
                if safeMode, p.terminationStatus != 0, errText.contains("safe-mode") || errText.lowercased().contains("unknown option") {
                    // 오래된 Claude Code: --safe-mode 없이 hook만 끄고 다시
                    self.runClaude(path: path, message: message, persona: persona, safeMode: false, onDelta: onDelta, onDone: onDone)
                    return
                }
                if self.sessionID == nil || newSession != nil { self.sessionID = newSession ?? self.sessionID }
                let text = final ?? (streamed.isEmpty ? nil : streamed)
                // Claude CLI 로그인이 안 됐거나 만료됐으면 자동 모드에서는 Codex로 넘긴다
                let authFailed = (text ?? errText).localizedCaseInsensitiveContains("authenticate")
                    || (text ?? errText).localizedCaseInsensitiveContains("login")
                if isError || final == nil, authFailed {
                    self.claudeAuthFailed = true
                    if self.config.chat.providerID == "auto", let codex = self.codexPath() {
                        Log.info("chat: claude 인증 실패 → codex로 대신")
                        self.runCodex(path: codex, message: message, persona: persona, onDone: onDone)
                        return
                    }
                    onDone(nil, L10n.t("Claude CLI 로그인이 필요해요. 터미널에서 `claude` 실행 후 /login 해 주세요."))
                    return
                }
                if let text, !isError {
                    onDone(text, nil)
                } else if self.sessionID != nil, errText.contains("No conversation found") {
                    self.sessionID = nil
                    self.runClaude(path: path, message: message, persona: persona, safeMode: safeMode, onDelta: onDelta, onDone: onDone)
                } else {
                    Log.info("chat failed status=\(p.terminationStatus)")
                    onDone(nil, text ?? L10n.format("대답을 못 들었어요 (claude 종료 코드 %@)", "\(p.terminationStatus)"))
                }
            }
        }
        launch(proc, onDone: onDone)
    }

    private func runCodex(path: String, message: String, persona: String, onDone: @escaping (String?, String?) -> Void) {
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-codex-\(UUID().uuidString).txt")
        let prompt = "\(persona)\n\n\(L10n.t("사용자:")) \(message)"
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "features.hooks=false",
                    "-c", "model_reasoning_effort=\"low\"", "--output-last-message", outFile.path]
        if let m = config.chat.model(for: "codex-cli") ?? Self.fastCodexModel(), !m.isEmpty { args += ["-m", m] }
        args.append(prompt)
        let proc = makeProcess(path, args)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            let text = try? String(contentsOf: outFile, encoding: .utf8)
            try? FileManager.default.removeItem(at: outFile)
            DispatchQueue.main.async {
                self?.process = nil
                if let text, !text.isEmpty { onDone(text.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
                else { onDone(nil, L10n.format("Codex가 대답하지 않았어요 (종료 코드 %@)", "\(p.terminationStatus)")) }
            }
        }
        launch(proc, onDone: onDone)
    }

    private func makeProcess(_ path: String, _ args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let dir = PawmitPaths.home.appendingPathComponent("chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        // 펫 채팅 프로세스가 Pawmit hook을 다시 부르지 않도록 표시 (CLI가 이 값을 보면 무시)
        env["PAWMIT_CHAT"] = "1"
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        return proc
    }

    private func launch(_ proc: Process, onDone: @escaping (String?, String?) -> Void) {
        do {
            try proc.run()
            process = proc
            // 90초 넘으면 포기
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak proc] in
                if proc?.isRunning == true { proc?.terminate() }
            }
        } catch {
            onDone(nil, L10n.format("실행 실패: %@", error.localizedDescription))
        }
    }

    /// Codex 모델 캐시(~/.codex/models_cache.json)에서 목록에 보이는 모델 중 "빠른·가벼운" 것을 고른다.
    /// 모델 이름을 코드에 박지 않아 Codex가 모델을 바꿔도 따라간다.
    static func fastCodexModel() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex"
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json"),
              let root = JSONValue.parse(data) else { return nil }
        let models = (root["models"] ?? root).array ?? []
        let listed = models.filter { $0["visibility"]?.string == "list" }
        func score(_ m: JSONValue) -> Int {
            let d = (m["description"]?.string ?? "").lowercased() + " " + (m["slug"]?.string ?? "").lowercased()
            return ["fast", "efficient", "mini", "nano", "lite", "luna"].reduce(0) { $0 + (d.contains($1) ? 1 : 0) }
        }
        return listed.max { score($0) < score($1) }?["slug"]?.string
    }

    /// Codex 모델 캐시에서 목록에 보이는 모델들
    static func codexModels() -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex"
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json"), let root = JSONValue.parse(data) else { return [] }
        return ((root["models"] ?? root).array ?? []).filter { $0["visibility"]?.string == "list" }.compactMap { $0["slug"]?.string }
    }

    /// 설정 창 모델 고르기: provider가 지금 쓸 수 있는 모델 목록
    static func models(for info: ChatProviderInfo, keys: ChatKeyStore = ChatKeychain()) async throws -> [String] {
        switch info.kind {
        case .cli("claude"): return ["haiku", "sonnet", "opus"]
        case .cli("codex"): return codexModels()
        case .cli: return []
        case .api(let style):
            guard let base = info.baseURL else { return [] }
            let key = keys.key(for: info.id)
            if info.needsKey, key == nil { throw APIChat.APIError.http(401, L10n.t("API 키를 먼저 넣어 주세요")) }
            return try await APIChat.listModels(style: style, baseURL: base, apiKey: key)
        }
    }

    // MARK: - 실행 파일 찾기 (GUI 앱은 PATH가 짧다)

    private func geminiPath() -> String? {
        if let p = config.chat.geminiPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        if let cached = resolvedGemini { return cached }
        let found = locate("gemini", extra: [])
        resolvedGemini = .some(found)
        return found
    }

    private func claudePath() -> String? {
        if let p = config.chat.claudePath, FileManager.default.isExecutableFile(atPath: p) { return p }
        if let cached = resolvedClaude { return cached }
        let found = locate("claude", extra: ["\(NSHomeDirectory())/.claude/local/claude"])
        resolvedClaude = .some(found)
        return found
    }

    private func codexPath() -> String? {
        if let p = config.chat.codexPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        if let cached = resolvedCodex { return cached }
        let found = locate("codex", extra: [])
        resolvedCodex = .some(found)
        return found
    }

    private func locate(_ name: String, extra: [String]) -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"] + extra
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // 로그인 셸에게 물어보기
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
