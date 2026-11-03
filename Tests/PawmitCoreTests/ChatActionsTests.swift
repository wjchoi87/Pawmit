import XCTest
@testable import PawmitCore

/// 채팅 문장에서 AI 호출 없이 바로 실행하는 명령 판별.
final class ChatActionsTests: XCTestCase {
    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.current
    }

    override func tearDown() {
        L10n.current = savedLanguage
        super.tearDown()
    }

    func testKoreanHomePhrases() {
        L10n.current = .ko
        for text in ["집에 가", "집으로 가", "집으로 돌아가", "집에 돌아가", "집에 들어가", "가서 자"] {
            XCTAssertEqual(ChatActions.directCommand(text), "home", text)
        }
    }

    func testEnglishHomePhrases() {
        L10n.current = .en
        for text in ["go home", "go back home", "return home", "go to bed"] {
            XCTAssertEqual(ChatActions.directCommand(text), "home", text)
        }
    }

    func testOutPhrases() {
        L10n.current = .ko
        XCTAssertEqual(ChatActions.directCommand("나와"), "out")
        XCTAssertEqual(ChatActions.directCommand("나와봐"), "out")
    }

    func testOrdinarySentenceIsNotACommand() {
        L10n.current = .ko
        XCTAssertNil(ChatActions.directCommand("밥 먹어"))
        XCTAssertNil(ChatActions.directCommand("오늘 뭐 해?"))
    }
}
