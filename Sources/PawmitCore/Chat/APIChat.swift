import Foundation

/// HTTP API로 대화하기: Anthropic Messages · OpenAI 호환 Chat Completions · OpenAI Responses.
/// 모두 SSE 스트리밍으로 받아 조각마다 onDelta를 부르고, 끝나면 전체 텍스트를 돌려준다.
public enum APIChat {
    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct Endpoint: Sendable {
        public var style: ChatAPIStyle
        public var baseURL: String
        public var apiKey: String?
        public var model: String

        public init(style: ChatAPIStyle, baseURL: String, apiKey: String?, model: String) {
            self.style = style
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
        }
    }

    public enum APIError: LocalizedError, Equatable {
        case badURL(String)
        case http(Int, String)
        case server(String)
        case empty
        case noModels

        public var errorDescription: String? {
            switch self {
            case .badURL(let u): return L10n.format("주소가 이상해요: %@", u)
            case .http(let code, let msg): return code == 401 || code == 403 ? L10n.format("API 키를 확인해 주세요 (%lld): %@", code, msg) : "HTTP \(code): \(msg)"
            case .server(let msg): return msg
            case .empty: return L10n.t("대답이 비어 있어요")
            case .noModels: return L10n.t("쓸 수 있는 모델을 찾지 못했어요")
            }
        }
    }

    static func url(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let u = URL(string: b + path), let scheme = u.scheme, scheme == "https" || scheme == "http" else { throw APIError.badURL(base) }
        return u
    }

    static func authorize(_ r: inout URLRequest, style: ChatAPIStyle, key: String?) {
        guard let key, !key.isEmpty else { return }
        if style == .anthropic {
            r.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - 요청

    public static func request(_ e: Endpoint, system: String, messages: [Message], maxTokens: Int = 1024) throws -> URLRequest {
        var body: [String: JSONValue]
        let msgs: [JSONValue] = messages.map { .object(["role": .string($0.role), "content": .string($0.content)]) }
        let path: String
        switch e.style {
        case .anthropic:
            path = "/messages"
            body = ["model": .string(e.model), "max_tokens": .number(Double(maxTokens)), "stream": true, "messages": .array(msgs)]
            if !system.isEmpty { body["system"] = .string(system) }
        case .openai:
            path = "/chat/completions"
            let all = (system.isEmpty ? [] : [JSONValue.object(["role": "system", "content": .string(system)])]) + msgs
            body = ["model": .string(e.model), "stream": true, "messages": .array(all)]
        case .responses:
            path = "/responses"
            body = ["model": .string(e.model), "stream": true, "input": .array(msgs), "store": false]
            if !system.isEmpty { body["instructions"] = .string(system) }
        }
        var r = URLRequest(url: try url(e.baseURL, path))
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if e.style == .anthropic { r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        authorize(&r, style: e.style, key: e.apiKey)
        r.httpBody = Data(JSONValue.object(body).encoded().utf8)
        return r
    }

    /// SSE `data:` 한 줄 → 글자 조각 / 오류 / 끝
    public static func parse(sseData data: String, style: ChatAPIStyle) -> (text: String?, error: String?, done: Bool) {
        let d = data.trimmingCharacters(in: .whitespaces)
        if d == "[DONE]" { return (nil, nil, true) }
        guard let v = JSONValue.parse(d) else { return (nil, nil, false) }
        if let err = v["error"], err != .null {
            return (nil, err["message"]?.string ?? err.string ?? err.encoded(), true)
        }
        switch style {
        case .anthropic:
            switch v["type"]?.string {
            case "content_block_delta": return (v["delta"]?["text"]?.string, nil, false)
            case "message_stop": return (nil, nil, true)
            default: return (nil, nil, false)
            }
        case .openai:
            // 끝은 "[DONE]"으로 온다
            return (v["choices"]?[0]?["delta"]?["content"]?.string, nil, false)
        case .responses:
            switch v["type"]?.string {
            case "response.output_text.delta": return (v["delta"]?.string, nil, false)
            case "response.completed": return (nil, nil, true)
            case "response.failed", "response.incomplete":
                return (nil, v["response"]?["error"]?["message"]?.string ?? L10n.t("응답 실패"), true)
            case "error": return (nil, v["message"]?.string ?? L10n.t("오류"), true)
            default: return (nil, nil, false)
            }
        }
    }

    /// 스트리밍 대화 한 번
    public static func stream(_ e: Endpoint, system: String, messages: [Message], session: URLSession = .shared,
                              onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let req = try request(e, system: system, messages: messages)
        let (bytes, response) = try await session.bytes(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > 8000 { break }
            }
            throw APIError.http(code, errorMessage(body))
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let (text, err, done) = parse(sseData: String(line.dropFirst(5)), style: e.style)
            if let err { throw APIError.server(err) }
            if let text, !text.isEmpty {
                full += text
                onDelta(full)
            }
            if done { break }
        }
        guard !full.isEmpty else { throw APIError.empty }
        return full
    }

    static func errorMessage(_ body: Data) -> String {
        if let v = JSONValue.parse(body) {
            if let m = v["error"]?["message"]?.string ?? v["error"]?.string ?? v["message"]?.string { return String(m.prefix(300)) }
        }
        return String(String(decoding: body, as: UTF8.self).prefix(300))
    }

    // MARK: - 모델 목록

    public static func listModels(style: ChatAPIStyle, baseURL: String, apiKey: String?, session: URLSession = .shared) async throws -> [String] {
        var r = URLRequest(url: try url(baseURL, "/models"))
        r.timeoutInterval = 20
        if style == .anthropic { r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        authorize(&r, style: style, key: apiKey)
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, errorMessage(data)) }
        let v = JSONValue.parse(data)
        let items = v?["data"]?.array ?? v?["models"]?.array ?? []
        let ids = items.compactMap { $0["id"]?.string ?? $0["name"]?.string }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        let chat = chatModels(ids)
        guard !chat.isEmpty else { throw APIError.noModels }
        return chat
    }

    /// 대화에 못 쓰는 모델(임베딩·음성·이미지 등)을 뺀다
    public static func chatModels(_ ids: [String]) -> [String] {
        let skip = ["embed", "whisper", "tts", "dall-e", "image", "audio", "realtime", "moderation", "transcribe", "rerank", "sora", "speech", "computer-use"]
        var seen = Set<String>()
        return ids.filter { id in
            let l = id.lowercased()
            return !skip.contains { l.contains($0) } && seen.insert(id).inserted
        }.sorted()
    }

    /// 펫 대화는 짧으니 빠른·가벼운 모델을 고른다
    public static func pickFastModel(_ ids: [String]) -> String? {
        let prefer = ["haiku", "flash-lite", "flash", "mini", "nano", "small", "lite", "fast", "turbo", "air"]
        for word in prefer {
            if let m = ids.filter({ $0.lowercased().contains(word) && !$0.lowercased().contains("preview") }).sorted(by: >).first { return m }
        }
        return ids.first
    }
}
