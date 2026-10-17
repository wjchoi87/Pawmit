import Foundation

/// 지원하는 코딩 에이전트. 새 에이전트는 여기와 `AgentAdapters`에 추가한다.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursor, gemini, copilot, opencode, kiro, droid, qwen, zcode, generic

    public init(loose raw: String) {
        let key = raw.lowercased()
        switch key {
        case "claude", "claude-code", "claudecode", "cc": self = .claude
        case "codex", "codex-cli": self = .codex
        case "cursor", "cursor-agent": self = .cursor
        case "gemini", "gemini-cli": self = .gemini
        case "copilot", "github-copilot", "copilot-cli": self = .copilot
        case "opencode": self = .opencode
        case "kiro", "kiro-cli": self = .kiro
        case "droid", "factory": self = .droid
        case "qwen", "qwen-code": self = .qwen
        case "zcode", "z-code", "zai", "z.ai": self = .zcode
        default: self = AgentKind(rawValue: key) ?? .generic
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot CLI"
        case .opencode: return "OpenCode"
        case .kiro: return "Kiro"
        case .droid: return "Droid"
        case .qwen: return "Qwen Code"
        case .zcode: return "ZCode"
        case .generic: return "Agent"
        }
    }
}

/// 에이전트 hook 이벤트를 펫이 이해하는 형태로 정규화한 것.
public struct AgentEvent: Sendable {
    public enum Kind: String, Sendable {
        /// 도구 실행 승인 요청 (Allow / Deny)
        case permission
        /// 사용자에게 객관식 질문 (AskUserQuestion)
        case question
        /// 계획 승인 요청 (ExitPlanMode)
        case plan
        /// 단순 알림 (입력 대기 등)
        case notification
        /// 에이전트 응답 종료 → 답장 가능
        case stop
        case sessionStart
        case sessionEnd
        case promptSubmit
        case toolStart
        case toolEnd
        case toolFailed
        case subagentStop
        case compact
        case error
        /// 외부에서 보낸 일반 알림 (`pawmit notify`)
        case custom
        case other
    }

    public var kind: Kind
    public var agent: AgentKind
    public var rawEvent: String
    public var sessionID: String?
    public var cwd: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var title: String?
    public var message: String?
    public var notificationType: String?
    public var questions: [Question]
    public var plan: String?
    /// "항상 허용"에 쓸 수 있는 에이전트 제안 (Claude Code permission_suggestions)
    public var permissionSuggestions: JSONValue?
    /// 이 이벤트에 대해 앱이 보낼 수 있는 응답 종류
    public var capabilities: Set<HookReply.Decision>

    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public init(kind: Kind, agent: AgentKind, rawEvent: String, sessionID: String? = nil, cwd: String? = nil,
                toolName: String? = nil, toolInput: JSONValue? = nil, title: String? = nil, message: String? = nil,
                notificationType: String? = nil, questions: [Question] = [], plan: String? = nil,
                permissionSuggestions: JSONValue? = nil, capabilities: Set<HookReply.Decision> = []) {
        self.kind = kind
        self.agent = agent
        self.rawEvent = rawEvent
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.title = title
        self.message = message
        self.notificationType = notificationType
        self.questions = questions
        self.plan = plan
        self.permissionSuggestions = permissionSuggestions
        self.capabilities = capabilities
    }

    public struct Question: Sendable, Equatable {
        public struct Option: Sendable, Equatable {
            public var label: String
            public var description: String?
        }
        public var question: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool
    }
}

extension AgentEvent.Question {
    /// Claude Code AskUserQuestion `tool_input.questions` 파싱
    public static func parseList(_ value: JSONValue?) -> [AgentEvent.Question] {
        guard let items = value?.array else { return [] }
        return items.compactMap { item in
            guard let q = item["question"]?.string else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { opt -> Option? in
                if let label = opt["label"]?.string { return Option(label: label, description: opt["description"]?.string) }
                if let label = opt.string { return Option(label: label, description: nil) }
                return nil
            }
            return AgentEvent.Question(question: q, header: item["header"]?.string, options: options,
                                       multiSelect: item["multiSelect"]?.bool ?? false)
        }
    }
}
