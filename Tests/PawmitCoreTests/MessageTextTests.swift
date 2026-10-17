import XCTest
@testable import PawmitCore

final class MarkdownBlockTests: XCTestCase {
    func testBlocks() {
        let md = """
        ## 결과
        빌드 **통과**
        두 번째 줄

        - 하나
          - 안쪽
        1. 첫째
        - [x] 끝남

        ```swift
        let a = 1
        ```
        > 인용
        ---
        | 항목 | 결과 |
        |---|:--:|
        | 빌드 | 통과 |
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 2, text: "결과"),
            .paragraph("빌드 **통과**\n두 번째 줄"),
            .listItem(indent: 0, marker: "•", text: "하나"),
            .listItem(indent: 1, marker: "•", text: "안쪽"),
            .listItem(indent: 0, marker: "1.", text: "첫째"),
            .listItem(indent: 0, marker: "☑", text: "끝남"),
            .code(language: "swift", text: "let a = 1"),
            .quote("인용"),
            .rule,
            .table(rows: [["항목", "결과"], ["빌드", "통과"]]),
        ])
    }

    func testPlainTextStaysOneParagraph() {
        XCTAssertEqual(MarkdownBlock.parse("그냥 한 줄"), [.paragraph("그냥 한 줄")])
        XCTAssertEqual(MarkdownBlock.parse("#해시태그"), [.paragraph("#해시태그")])
        XCTAssertEqual(MarkdownBlock.parse("| 표 아님"), [.paragraph("| 표 아님")])
        // 닫는 펜스가 없어도 끝까지 코드로
        XCTAssertEqual(MarkdownBlock.parse("```\nx"), [.code(language: nil, text: "x")])
    }
}

final class AppSessionsTests: XCTestCase {
    func testClaudeDesktopLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-sessions-\(UUID().uuidString)")
        let org = root.appendingPathComponent("acct/org", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = "31acc1a5-4e6d-417b-95d5-87838d5eae2c"
        try #"{"sessionId":"local_aaa-111","cliSessionId":"\#(cli)","isArchived":false}"#
            .write(to: org.appendingPathComponent("local_aaa-111.json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"local_bbb-222","cliSessionId":"other","isArchived":false}"#
            .write(to: org.appendingPathComponent("local_bbb-222.json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"local_ccc-333","cliSessionId":"archived-one","isArchived":true}"#
            .write(to: org.appendingPathComponent("local_ccc-333.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AppSessions.claudeLocalSessionID(cliSessionID: cli, root: root), "local_aaa-111")
        XCTAssertNil(AppSessions.claudeLocalSessionID(cliSessionID: "archived-one", root: root))
        XCTAssertNil(AppSessions.claudeLocalSessionID(cliSessionID: "missing", root: root))
        // 주소에 섞이면 안 되는 글자는 찾지도 않는다
        XCTAssertNil(AppSessions.claudeLocalSessionID(cliSessionID: "a\"b", root: root))

        XCTAssertEqual(AppSessions.claudeDesktopURL(localSessionID: "local_aaa-111")?.absoluteString,
                       "claude://code/continue?session=local_aaa-111")
        XCTAssertNil(AppSessions.claudeDesktopURL(localSessionID: "local_a&b=c"))
        XCTAssertEqual(AppSessions.codexThreadURL(sessionID: "019a-thread")?.absoluteString, "codex://threads/019a-thread")
        XCTAssertNil(AppSessions.codexThreadURL(sessionID: "../x"))
    }
}

final class MessageTextConfigTests: XCTestCase {
    func testDefaultsAndClamp() throws {
        let d = PawmitConfig()
        XCTAssertEqual(d.hookText.size, 13)
        XCTAssertEqual(d.chatText.size, 12)
        XCTAssertTrue(d.hookText.markdown)

        let c = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"hookText":{"size":40,"markdown":false,"fontName":"mono"}}"#.utf8))
        XCTAssertEqual(c.hookText.size, 20)
        XCTAssertFalse(c.hookText.markdown)
        XCTAssertEqual(c.hookText.fontName, "mono")
        XCTAssertEqual(c.chatText, d.chatText)
    }
}

final class UserTitleTests: XCTestCase {
    func testParticles() {
        XCTAssertEqual(Korean.particle("선배님", "이", "가"), "선배님이")
        XCTAssertEqual(Korean.particle("사용자", "이", "가"), "사용자가")
        XCTAssertEqual(Korean.particle("보스", "이", "가"), "보스가")
        XCTAssertEqual(Korean.particle("집사", "'이라고", "'라고"), "집사'라고")
        XCTAssertEqual(Korean.particle("Boss", "이", "가"), "Boss가")
    }

    func testTitleConfig() throws {
        XCTAssertEqual(PawmitConfig().userTitle, "사용자")
        let c = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"userTitle":"  주인님\n "}"#.utf8))
        XCTAssertEqual(c.userTitle, "주인님")
        XCTAssertEqual(c.addressingUser("{user}! {user} 최고"), "주인님! 주인님 최고")
        let empty = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"userTitle":"   "}"#.utf8))
        XCTAssertEqual(empty.userTitle, "사용자")
        XCTAssertEqual(PawmitConfig.cleanTitle(String(repeating: "가", count: 30)).count, 20)
        // 혼잣말 문구에는 호칭이 직접 박혀 있지 않고 자리표시자만
        var rng = SplitMix64(seed: 7)
        for _ in 0..<300 {
            XCTAssertFalse(SpeechBank.line(.affectionate, rng: &rng).contains("사용자"))
        }
    }
}
