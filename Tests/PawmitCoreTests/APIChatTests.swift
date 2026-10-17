import XCTest
@testable import PawmitCore

/// 실제 서버 없이 HTTP 응답을 흉내 낸다 (SSE 스트림 포함)
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let (code, body) = Self.handler?(request) ?? (500, "")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        // 줄 단위로 나눠 보내 스트리밍처럼
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            client?.urlProtocol(self, didLoad: Data((line + "\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIChatTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: c)
    }

    func run(_ style: ChatAPIStyle, sse: String, code: Int = 200) async throws -> (String, [String]) {
        MockURLProtocol.handler = { _ in (code, sse) }
        let e = APIChat.Endpoint(style: style, baseURL: "https://api.example.com/v1/", apiKey: "test-key", model: "m1")
        let deltas = LockedArray()
        let text = try await APIChat.stream(e, system: "너는 펫", messages: [.init(role: "user", content: "안녕")], session: session) { deltas.append($0) }
        return (text, deltas.items)
    }

    func testAnthropicStream() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"x"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안녕"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", 선배님!"}}

        event: message_stop
        data: {"type":"message_stop"}
        """
        let (text, deltas) = try await run(.anthropic, sse: sse)
        XCTAssertEqual(text, "안녕, 선배님!")
        XCTAssertEqual(deltas, ["안녕", "안녕, 선배님!"])
        let r = MockURLProtocol.lastRequest!
        XCTAssertEqual(r.url?.absoluteString, "https://api.example.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = JSONValue.parse(MockURLProtocol.lastBody ?? Data())
        XCTAssertEqual(body?["system"]?.string, "너는 펫")
        XCTAssertEqual(body?["stream"]?.bool, true)
    }

    func testOpenAICompatibleStream() async throws {
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"냐"}}]}

        data: {"choices":[{"delta":{"content":"옹"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """
        let (text, _) = try await run(.openai, sse: sse)
        XCTAssertEqual(text, "냐옹")
        let r = MockURLProtocol.lastRequest!
        XCTAssertEqual(r.url?.path, "/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = JSONValue.parse(MockURLProtocol.lastBody ?? Data())
        XCTAssertEqual(body?["messages"]?[0]?["role"]?.string, "system")
        XCTAssertEqual(body?["messages"]?[1]?["content"]?.string, "안녕")
    }

    func testResponsesStream() async throws {
        let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"r"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"반가"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"워!"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r"}}
        """
        let (text, _) = try await run(.responses, sse: sse)
        XCTAssertEqual(text, "반가워!")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/responses")
        let body = JSONValue.parse(MockURLProtocol.lastBody ?? Data())
        XCTAssertEqual(body?["instructions"]?.string, "너는 펫")
        XCTAssertEqual(body?["input"]?[0]?["content"]?.string, "안녕")
    }

    func testErrors() async {
        do {
            _ = try await run(.openai, sse: #"{"error":{"message":"Incorrect API key"}}"#, code: 401)
            XCTFail("401이면 실패해야")
        } catch {
            XCTAssertEqual(error as? APIChat.APIError, .http(401, "Incorrect API key"))
        }
        do {
            _ = try await run(.anthropic, sse: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? APIChat.APIError, .server("Overloaded"))
        }
    }

    func testListModels() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"data":[{"id":"gpt-x"},{"id":"gpt-x-mini"},{"id":"text-embedding-3"},{"id":"tts-1"}]}"#) }
        let ids = try await APIChat.listModels(style: .openai, baseURL: "https://api.example.com/v1", apiKey: "k", session: session)
        XCTAssertEqual(ids, ["gpt-x", "gpt-x-mini"])
        XCTAssertEqual(APIChat.pickFastModel(ids), "gpt-x-mini")
        XCTAssertEqual(APIChat.pickFastModel(["claude-opus-9", "claude-haiku-9"]), "claude-haiku-9")
        XCTAssertThrowsError(try APIChat.request(.init(style: .openai, baseURL: "ftp://x", apiKey: nil, model: "m"), system: "", messages: []))
    }

    func testProviderCatalogAndConfig() throws {
        XCTAssertEqual(ChatProviders.provider("claude", custom: [])?.id, "claude-cli", "예전 설정값")
        let custom = CustomChatProvider(id: "abc", name: "사내 GPT", style: .responses, baseURL: "https://llm.example.com/v1")
        XCTAssertEqual(ChatProviders.provider("custom:abc", custom: [custom])?.kind, .api(.responses))
        var c = PawmitConfig()
        c.chat.provider = "codex"
        c.chat.codexModel = "old-model"
        XCTAssertEqual(c.chat.providerID, "codex-cli")
        XCTAssertEqual(c.chat.model(for: "codex-cli"), "old-model")
        c.chat.models["codex-cli"] = "new-model"
        XCTAssertEqual(c.chat.model(for: "codex-cli"), "new-model")
        c.chat.customProviders = [custom]
        let back = try JSONDecoder().decode(PawmitConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.chat.customProviders, [custom])
        XCTAssertTrue(ChatProviders.isLocal("http://localhost:11434/v1"))
        XCTAssertFalse(ChatProviders.isLocal("http://llm.example.com"))
        let store = MemoryKeyStore()
        try store.setKey("sk-test", for: "openai")
        XCTAssertEqual(store.key(for: "openai"), "sk-test")
    }
}

final class LockedArray: @unchecked Sendable {
    private var a: [String] = []
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); a.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return a }
}
