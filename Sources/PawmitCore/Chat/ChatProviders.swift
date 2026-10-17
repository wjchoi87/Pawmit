import Foundation

/// API 대화 방식
public enum ChatAPIStyle: String, Codable, CaseIterable, Sendable {
    /// Anthropic Messages API (`POST /messages`)
    case anthropic
    /// OpenAI 호환 Chat Completions (`POST /chat/completions`) — 대부분의 provider·Ollama·LM Studio
    case openai
    /// OpenAI Responses API (`POST /responses`)
    case responses

    public var label: String {
        switch self {
        case .anthropic: return "Anthropic (Messages)"
        case .openai: return L10n.t("OpenAI 호환 (Chat Completions)")
        case .responses: return "OpenAI Responses"
        }
    }
}

/// 사용자가 붙인 provider. API 키는 config가 아니라 키체인(`ChatKeychain`)에 둔다.
public struct CustomChatProvider: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var style: ChatAPIStyle
    public var baseURL: String
    /// false면 키 없이 부른다 (로컬 서버 등)
    public var needsKey: Bool

    public init(id: String = UUID().uuidString.prefix(8).lowercased(), name: String, style: ChatAPIStyle, baseURL: String, needsKey: Bool = true) {
        self.id = id
        self.name = name
        self.style = style
        self.baseURL = baseURL
        self.needsKey = needsKey
    }

    public var providerID: String { "custom:\(id)" }
}

public struct ChatProviderInfo: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 이미 로그인한 CLI (명령 이름)
        case cli(String)
        case api(ChatAPIStyle)
    }

    public enum Group: String, Sendable, CaseIterable {
        case cli
        case cloud = "API"
        case local
        case custom

        /// 설정 창에 보여줄 이름 (rawValue는 식별자라 번역하지 않는다)
        public var displayName: String {
            switch self {
            case .cli: return L10n.t("로그인한 CLI")
            case .cloud: return "API"
            case .local: return L10n.t("내 컴퓨터")
            case .custom: return L10n.t("커스텀")
            }
        }
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let group: Group
    public let baseURL: String?
    public let needsKey: Bool
    /// API 키 받는 곳
    public let keyPage: String?
    /// 비우면 모델 목록에서 빠른 모델을 자동으로 고른다
    public let defaultModel: String?
}

/// 대화 provider 목록. 모델 목록은 각 provider의 `/models`에서 불러온다 (이름을 코드에 박지 않음).
public enum ChatProviders {
    static func api(_ id: String, _ name: String, _ style: ChatAPIStyle, _ base: String, key: String?, group: ChatProviderInfo.Group = .cloud,
                    needsKey: Bool = true) -> ChatProviderInfo {
        ChatProviderInfo(id: id, name: name, kind: .api(style), group: group, baseURL: base, needsKey: needsKey, keyPage: key, defaultModel: nil)
    }

    public static let builtins: [ChatProviderInfo] = [
        ChatProviderInfo(id: "claude-cli", name: "Claude Code CLI", kind: .cli("claude"), group: .cli, baseURL: nil, needsKey: false, keyPage: nil, defaultModel: "haiku"),
        ChatProviderInfo(id: "codex-cli", name: "Codex CLI", kind: .cli("codex"), group: .cli, baseURL: nil, needsKey: false, keyPage: nil, defaultModel: nil),
        ChatProviderInfo(id: "gemini-cli", name: "Gemini CLI", kind: .cli("gemini"), group: .cli, baseURL: nil, needsKey: false, keyPage: nil, defaultModel: nil),
        api("anthropic", "Anthropic (Claude)", .anthropic, "https://api.anthropic.com/v1", key: "https://console.anthropic.com/settings/keys"),
        api("openai", "OpenAI", .responses, "https://api.openai.com/v1", key: "https://platform.openai.com/api-keys"),
        api("google", "Google Gemini", .openai, "https://generativelanguage.googleapis.com/v1beta/openai", key: "https://aistudio.google.com/apikey"),
        api("xai", "xAI (Grok)", .openai, "https://api.x.ai/v1", key: "https://console.x.ai"),
        api("deepseek", "DeepSeek", .openai, "https://api.deepseek.com", key: "https://platform.deepseek.com/api_keys"),
        api("mistral", "Mistral", .openai, "https://api.mistral.ai/v1", key: "https://console.mistral.ai/api-keys"),
        api("zai", "Z.ai (GLM)", .openai, "https://api.z.ai/api/paas/v4", key: "https://z.ai/manage-apikey/apikey-list"),
        api("moonshot", "Moonshot (Kimi)", .openai, "https://api.moonshot.ai/v1", key: "https://platform.moonshot.ai/console/api-keys"),
        api("qwen", "Alibaba Qwen (DashScope)", .openai, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", key: "https://modelstudio.console.alibabacloud.com"),
        api("groq", "Groq", .openai, "https://api.groq.com/openai/v1", key: "https://console.groq.com/keys"),
        api("openrouter", "OpenRouter", .openai, "https://openrouter.ai/api/v1", key: "https://openrouter.ai/keys"),
        api("ollama", "Ollama", .openai, "http://localhost:11434/v1", key: nil, group: .local, needsKey: false),
        api("lmstudio", "LM Studio", .openai, "http://localhost:1234/v1", key: nil, group: .local, needsKey: false),
    ]

    public static func all(custom: [CustomChatProvider]) -> [ChatProviderInfo] {
        builtins + custom.map { c in
            ChatProviderInfo(id: c.providerID, name: c.name, kind: .api(c.style), group: .custom, baseURL: c.baseURL,
                             needsKey: c.needsKey, keyPage: nil, defaultModel: nil)
        }
    }

    public static func provider(_ id: String, custom: [CustomChatProvider]) -> ChatProviderInfo? {
        let key = id == "claude" ? "claude-cli" : id == "codex" ? "codex-cli" : id
        return all(custom: custom).first { $0.id == key }
    }

    /// 키 없이 http로 보내도 되는 주소인지 (로컬)
    public static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}
