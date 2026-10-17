import Foundation
import PawmitCore

/// 에이전트 hook 수신소. Unix socket으로 들어온 요청을 정규화하고, 응답이 필요한 요청은 대기열에 둔다.
///
/// 터미널에서 먼저 답한 경우 정리 규칙 (coucou·agentNotch·vibe-notch 동작 참고):
/// 1) hook 프로세스가 죽어 socket이 닫히면 즉시 정리 (가장 확실)
/// 2) 같은 세션에서 같은 도구의 PostToolUse, 또는 Stop·UserPromptSubmit·SessionEnd가 오면 정리
/// 3) 대기 시간이 지나면 pass로 돌려 터미널 프롬프트에 맡김
@MainActor
final class AgentHub {
    struct Pending: Identifiable {
        let id: String
        let envelope: HookEnvelope
        let event: AgentEvent
        let summary: ToolSummary?
        let connection: UnixSocketConnection
        let created: Date
        var deadline: Date
        /// 답장을 쓰는 중이라 카운트다운을 멈춤
        var typing = false
    }

    enum RemovalReason { case answered, closedByAgent, answeredElsewhere, timeout }

    struct SessionInfo {
        var agent: AgentKind
        var project: String
        var cwd: String?
        var working: Bool
        var lastEvent: Date
        var envelope: HookEnvelope
    }

    var config: PawmitConfig
    private(set) var pending: [Pending] = []
    private(set) var sessions: [String: SessionInfo] = [:]
    private let server = UnixSocketServer(path: PawmitPaths.socket.path)
    private var timer: Timer?

    /// 대기열 변화 (메뉴바 배지 등)
    var onChange: () -> Void = {}
    /// 새 대기 요청
    var onPendingAdded: (Pending) -> Void = { _ in }
    var onPendingRemoved: (Pending, RemovalReason) -> Void = { _, _ in }
    /// 응답이 필요 없는 이벤트 (펫 반응용)
    var onEvent: (AgentEvent, HookEnvelope) -> Void = { _, _ in }
    /// `pawmit debug …` (개발·검증용): 결과 문자열을 돌려준다
    var onDebug: (String, String?) -> String = { _, _ in "{}" }

    init(config: PawmitConfig) {
        self.config = config
    }

    func start() throws {
        server.onConnection = { [weak self] conn in
            conn.onMessage = { data in
                DispatchQueue.main.async { self?.handle(data, conn) }
            }
            conn.onClose = {
                DispatchQueue.main.async { self?.connectionClosed(conn) }
            }
        }
        try server.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        Log.info("hook socket listening at \(server.path)")
    }

    func stop() {
        for p in pending { p.connection.reply(encode(HookReply(id: p.id, decision: .pass))) }
        pending.removeAll()
        server.stop()
        timer?.invalidate()
    }

    // MARK: - 수신

    private func handle(_ data: Data, _ conn: UnixSocketConnection) {
        guard let env = try? WireCodec.decode(HookEnvelope.self, line: data) else {
            conn.close()
            return
        }
        if env.agent == "debug" {
            let result = onDebug(env.event, env.payload["arg"]?.string)
            conn.reply(encode(HookReply(id: env.id, decision: .pass, message: result)))
            return
        }
        let event = AgentAdapters.normalize(env)
        trackSession(event, env)
        clearStale(after: event)

        guard env.expectsReply, needsUser(event) else {
            if env.expectsReply { conn.reply(encode(HookReply(id: env.id, decision: .pass))) } else { conn.close() }
            onEvent(event, env)
            return
        }
        if config.quietMode || autoPass(event) {
            conn.reply(encode(HookReply(id: env.id, decision: .pass)))
            onEvent(event, env)
            return
        }

        let wait = event.kind == .stop ? config.stopReplySeconds : config.permissionTimeoutSeconds
        let cap = (env.waitSeconds ?? wait) - 5
        let summary = event.kind == .permission ? ToolSummary.make(toolName: event.toolName, input: event.toolInput, agent: event.agent) : nil
        let p = Pending(id: env.id, envelope: env, event: event, summary: summary, connection: conn, created: Date(),
                        deadline: Date().addingTimeInterval(max(3, min(wait, cap))))
        pending.append(p)
        Log.info("pending \(event.agent.rawValue) \(event.kind.rawValue) tool=\(event.toolName ?? "-") project=\(event.projectName ?? "-")")
        onPendingAdded(p)
        onChange()
    }

    private func needsUser(_ e: AgentEvent) -> Bool {
        switch e.kind {
        case .permission, .question, .plan: return !e.capabilities.isEmpty
        case .stop: return e.capabilities.contains(.reply) && config.stopReplySeconds > 0
        default: return false
        }
    }

    /// 펫이 끼어들 필요 없는 요청
    private func autoPass(_ e: AgentEvent) -> Bool {
        if e.kind == .permission, config.readonlyPassthrough, [.copilot, .droid].contains(e.agent),
           ToolSummary.isReadOnly(toolName: e.toolName) {
            return true
        }
        if e.kind == .question, e.questions.isEmpty { return true }
        return false
    }

    private func connectionClosed(_ conn: UnixSocketConnection) {
        guard let i = pending.firstIndex(where: { $0.connection === conn }) else { return }
        let p = pending.remove(at: i)
        Log.info("pending closed by agent (\(p.event.kind.rawValue))")
        onPendingRemoved(p, .closedByAgent)
        onChange()
    }

    private func trackSession(_ e: AgentEvent, _ env: HookEnvelope) {
        let key = "\(e.agent.rawValue):\(e.sessionID ?? e.cwd ?? "default")"
        var info = sessions[key] ?? SessionInfo(agent: e.agent, project: e.projectName ?? e.agent.displayName, cwd: e.cwd,
                                                working: false, lastEvent: Date(), envelope: env)
        info.lastEvent = Date()
        info.envelope = env
        if let name = e.projectName { info.project = name }
        switch e.kind {
        case .promptSubmit, .toolStart, .toolEnd, .permission, .question, .plan, .subagentStop, .compact: info.working = true
        case .stop, .error, .notification: info.working = false
        case .sessionEnd:
            sessions.removeValue(forKey: key)
            onChange()
            return
        default: break
        }
        sessions[key] = info
        // 오래된 세션 정리
        sessions = sessions.filter { Date().timeIntervalSince($0.value.lastEvent) < 6 * 3600 }
        onChange()
    }

    private func clearStale(after e: AgentEvent) {
        guard [.toolEnd, .toolFailed, .stop, .promptSubmit, .sessionEnd].contains(e.kind) else { return }
        let stale = pending.filter { p in
            guard p.event.agent == e.agent, p.event.sessionID != nil, p.event.sessionID == e.sessionID,
                  Date().timeIntervalSince(p.created) > 0.5 else { return false }
            if p.event.kind == .stop { return e.kind == .promptSubmit || e.kind == .sessionEnd }
            if e.kind == .toolEnd || e.kind == .toolFailed {
                return p.event.toolName == e.toolName && (e.toolInput == nil || p.event.toolInput == e.toolInput)
            }
            return true
        }
        for p in stale { remove(p.id, reply: HookReply(id: p.id, decision: .pass), reason: .answeredElsewhere) }
    }

    private func expire() {
        let now = Date()
        for p in pending where p.deadline < now {
            remove(p.id, reply: HookReply(id: p.id, decision: .pass), reason: .timeout)
        }
    }

    // MARK: - 응답

    /// 답장을 쓰기 시작하면 마감을 hook이 기다릴 수 있는 끝(에이전트 대기 시간 − 5초)까지 미뤄, 쓰는 도중 답장이 날아가지 않게 한다.
    func holdForTyping(_ id: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }), !pending[i].typing else { return }
        let cap = (pending[i].envelope.waitSeconds ?? 600) - 5
        pending[i].typing = true
        pending[i].deadline = max(pending[i].deadline, pending[i].created.addingTimeInterval(cap))
        onChange()
    }

    func respond(_ id: String, _ reply: HookReply) {
        remove(id, reply: reply, reason: .answered)
    }

    private func remove(_ id: String, reply: HookReply, reason: RemovalReason) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        // 대기열에서 먼저 빼므로 reply 후 닫힘 콜백(connectionClosed)은 아무것도 하지 않는다
        let p = pending.remove(at: i)
        p.connection.reply(encode(reply))
        Log.info("pending \(reason) → \(reply.decision.rawValue)")
        onPendingRemoved(p, reason)
        onChange()
    }

    private func encode(_ reply: HookReply) -> Data {
        (try? WireCodec.encodeLine(reply)) ?? Data("{}\n".utf8)
    }

    var workingSessions: [SessionInfo] {
        sessions.values.filter { $0.working && Date().timeIntervalSince($0.lastEvent) < 1800 }.sorted { $0.lastEvent > $1.lastEvent }
    }
}
