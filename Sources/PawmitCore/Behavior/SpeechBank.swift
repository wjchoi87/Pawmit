import Foundation

/// 펫 혼잣말 생성기: 여는 말 × 본문 × 맺음 조합 (기분별 수천 가지)
/// 문구 자체는 언어별 데이터(`SpeechBankData`)에 있다.
public enum SpeechBank {
    public static func line(_ mood: Mood, rng r: inout SplitMix64, interjection: String = "") -> String {
        let bank = SpeechBankData.current()
        let body = r.pick(bank.bodies[mood] ?? [L10n.t("히히")])
        var open = r.pick(bank.openings)
        if !interjection.isEmpty, r.chance(0.25) { open = interjection }
        let end = r.pick(bank.endings)
        return [open, body + end].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 만들 수 있는 대사 수
    public static var lineCount: Int {
        let bank = SpeechBankData.current()
        return bank.bodies.values.reduce(0) { $0 + $1.count } * (bank.openings.count + 1) * bank.endings.count
    }
}
