import Foundation

/// `pawmit hook` CLI ↔ Pawmit.app 사이 Unix socket 메시지.
/// 한 연결 = 한 hook 호출. 요청 1줄(JSON + "\n")을 보내고, 응답이 필요한 이벤트면 응답 1줄을 기다린다.
/// 앱이 응답 없이 연결을 닫으면 CLI는 무출력으로 종료해 에이전트 기본 동작(터미널 프롬프트)으로 넘긴다.
public enum Wire {
    public static let version = 1
    /// 한 줄 메시지 최대 크기. tool_input에 큰 파일 내용이 들어올 수 있어 넉넉히 잡는다.
    public static let maxMessageBytes = 8 * 1024 * 1024
}

public struct HookEnvelope: Codable, Sendable {
    public var v: Int
    public var id: String
    /// 에이전트 식별자 (`AgentKind.rawValue`). 모르는 값도 받아서 generic으로 처리한다.
    public var agent: String
    /// 에이전트가 쓰는 원래 이벤트 이름 (예: PermissionRequest, beforeShellExecution)
    public var event: String
    /// 앱의 결정을 기다리는 호출인지 (권한 요청, 질문, Stop 답장 등)
    public var expectsReply: Bool
    /// hook CLI 자신의 pid와 부모(에이전트 프로세스) pid. 터미널 포커스·세션 매칭에 사용.
    public var pid: Int32
    public var ppid: Int32
    public var tty: String?
    /// 터미널 식별용 환경 변수 일부 (TERM_PROGRAM, ITERM_SESSION_ID, TMUX_PANE 등)
    public var env: [String: String]
    /// hook 실행 시 작업 디렉토리 (payload에 cwd가 없는 에이전트용)
    public var cwd: String?
    /// 에이전트가 stdin(또는 argv)으로 준 원본 JSON
    public var payload: JSONValue
    /// CLI가 앱 응답을 기다리는 최대 시간(초). 앱은 이 시간이 지나기 전에 말풍선을 정리한다.
    public var waitSeconds: Double?

    public init(id: String = UUID().uuidString, agent: String, event: String, expectsReply: Bool,
                pid: Int32, ppid: Int32, tty: String?, env: [String: String], cwd: String?,
                payload: JSONValue, waitSeconds: Double?) {
        self.v = Wire.version
        self.id = id
        self.agent = agent
        self.event = event
        self.expectsReply = expectsReply
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.env = env
        self.cwd = cwd
        self.payload = payload
        self.waitSeconds = waitSeconds
    }

    /// 터미널 식별에 쓰는 환경 변수 목록. 그 외 환경 변수(토큰 등)는 절대 보내지 않는다.
    public static let forwardedEnvKeys = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID",
        "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR",
        "__CFBundleIdentifier", "VSCODE_PID", "CURSOR_TRACE_ID", "ZED_TERM", "WARP_IS_LOCAL_SHELL_SESSION",
        "CLAUDE_PROJECT_DIR", "CODEX_HOME", "GEMINI_PROJECT_DIR", "ZCODE_PROJECT_DIR",
    ]
}

/// 앱 → CLI 응답. 에이전트별 출력 형식으로의 변환은 `AgentAdapter.render`가 담당한다.
public struct HookReply: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable {
        /// 허용
        case allow
        /// 거절 (`message`가 에이전트에게 전달되는 이유)
        case deny
        /// AskUserQuestion 같은 질문에 답함 (`answers`)
        case answer
        /// Stop 이후 사용자 답장으로 작업을 이어감 (`message`가 다음 지시)
        case reply
        /// 결정하지 않음 → 에이전트 기본 동작(터미널 프롬프트)
        case pass
    }

    public var id: String
    public var decision: Decision
    public var message: String?
    /// 질문 텍스트 → 선택한 답(여러 개면 ", "로 합침)
    public var answers: [String: String]?
    /// "항상 허용" 시 에이전트에 넘길 권한 규칙 (Claude Code permission_suggestions 원본)
    public var updatedPermissions: JSONValue?
    /// 거절과 함께 에이전트를 멈출지
    public var interrupt: Bool?

    public init(id: String, decision: Decision, message: String? = nil, answers: [String: String]? = nil,
                updatedPermissions: JSONValue? = nil, interrupt: Bool? = nil) {
        self.id = id
        self.decision = decision
        self.message = message
        self.answers = answers
        self.updatedPermissions = updatedPermissions
        self.interrupt = interrupt
    }
}

public enum WireCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
