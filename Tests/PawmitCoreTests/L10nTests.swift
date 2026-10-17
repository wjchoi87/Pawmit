import XCTest
@testable import PawmitCore

/// 다국어 데이터 정합성: ko/en 대사 뱅크가 같은 구조(기분 키·후보 수)를 유지하는지.
final class L10nTests: XCTestCase {
    func testSpeechBankEnglishParity() {
        XCTAssertEqual(SpeechBankData.ko.openings.count, SpeechBankData.en.openings.count)
        XCTAssertEqual(SpeechBankData.ko.endings.count, SpeechBankData.en.endings.count)
        XCTAssertEqual(Set(SpeechBankData.ko.bodies.keys), Set(SpeechBankData.en.bodies.keys))
        for (mood, koLines) in SpeechBankData.ko.bodies {
            let enLines = SpeechBankData.en.bodies[mood] ?? []
            XCTAssertEqual(koLines.count, enLines.count, "mood \(mood) line count mismatch")
        }
        for lines in SpeechBankData.en.bodies.values {
            XCTAssertFalse(lines.contains(where: \.isEmpty))
        }
    }

    func testSpeechBankLineInEnglish() {
        // Bundle이 없는 테스트 환경에서도 조합이 깨지지 않는지 (en 테이블 없이 ko 원문 폴백)
        var r = SplitMix64(seed: 42)
        for mood in SpeechBankData.ko.bodies.keys {
            XCTAssertTrue(SpeechBank.line(mood, rng: &r).count <= 60)
        }
    }

    /// 런타임 언어 전환: 현재 언어가 바뀌면 대사·기본 호칭·기본 펫 이름이 바로 따라간다
    func testRuntimeLanguageSwitch() {
        let saved = L10n.current
        defer { L10n.current = saved }

        L10n.current = .en
        XCTAssertFalse(L10n.isKorean)
        XCTAssertEqual(PawmitConfig.displayTitle(PawmitConfig.defaultUserTitle), "Buddy")
        XCTAssertEqual(PawmitConfig.displayTitle("선배님"), "선배님")
        XCTAssertEqual(PetCatalog.builtin("mongle").flatMap { PetCatalog.localized($0, "name") }, "Mongle")
        XCTAssertEqual(SpeechBankData.current().openings, SpeechBankData.en.openings)

        L10n.current = .ko
        XCTAssertTrue(L10n.isKorean)
        XCTAssertEqual(PawmitConfig.displayTitle(""), "사용자")
        XCTAssertEqual(PetCatalog.builtin("mongle").flatMap { PetCatalog.localized($0, "name") }, "몽글이")
        XCTAssertEqual(L10n.t("거절"), "거절")
    }

    /// 예전 설정값(system)·모르는 값은 시스템 언어로, 저장된 ko/en은 그대로
    func testLanguageConfigValues() throws {
        XCTAssertEqual(AppLanguage.from(config: "en"), .en)
        XCTAssertEqual(AppLanguage.from(config: "ko"), .ko)
        XCTAssertEqual(AppLanguage.from(config: "system"), AppLanguage.systemDefault)
        let c = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"language":"system"}"#.utf8))
        XCTAssertEqual(c.language, AppLanguage.systemDefault.rawValue)
    }

    /// 커스텀 펫(base 상속)은 기본 펫 영어 이름을 물려받지 않는다
    func testCustomPetKeepsOwnName() {
        let saved = L10n.current
        defer { L10n.current = saved }
        L10n.current = .en
        let custom = PetCatalog.resolve(.object(["base": "mongle", "name": "새싹감자"]))
        XCTAssertEqual(PetCatalog.localized(custom, "name"), "새싹감자")
    }
}
