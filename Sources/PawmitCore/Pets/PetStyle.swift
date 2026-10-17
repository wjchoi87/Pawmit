import Foundation

/// 펫 스타일: 성격·말투·색. 생김새와 따로, 모든 펫(기본·커스텀·메이커)에 적용된다.
///
/// 저장 위치: 메이커 펫은 pet.json의 `style`(내보내면 같이 간다), 그리고 사용자가 설정에서 바꾼 값은
/// config.json의 `petStyles[펫 id]`. 둘 다 있으면 설정 값이 필드 단위로 우선한다.
public struct PetStyle: Codable, Equatable, Sendable {
    /// 성격 8가지 0…1 (energy curiosity sociability artistry mischief appetite laziness tidiness). 빠진 항목은 seed 값.
    public var personality: [String: Double]?
    public var speech: SpeechStyle?
    /// 색 바꾸기: 원래 색 → 새 색 (#RRGGBB). 기본 치비는 필드 이름(body·accent…)도 키로 쓸 수 있다.
    public var colors: [String: String]?

    public init(personality: [String: Double]? = nil, speech: SpeechStyle? = nil, colors: [String: String]? = nil) {
        self.personality = personality
        self.speech = speech
        self.colors = colors
    }

    public static let traits = ["energy", "curiosity", "sociability", "artistry", "mischief", "appetite", "laziness", "tidiness"]

    public var isEmpty: Bool {
        (personality?.isEmpty ?? true) && (speech.map { $0 == SpeechStyle() } ?? true) && (colors?.isEmpty ?? true)
    }

    /// other 값이 있는 필드는 other로 덮어쓴다 (설정 > pet.json)
    public func merged(with other: PetStyle?) -> PetStyle {
        guard let other else { return self }
        var out = self
        if let p = other.personality { out.personality = (personality ?? [:]).merging(p) { _, b in b } }
        if let s = other.speech { out.speech = (speech ?? SpeechStyle()).merged(with: s) }
        if let c = other.colors { out.colors = (colors ?? [:]).merging(c) { _, b in b } }
        return out
    }

    public func validate() -> [String] {
        var issues: [String] = []
        for (k, v) in personality ?? [:] {
            if !Self.traits.contains(k) { issues.append(L10n.format("style.personality '%@'는 없는 성격입니다 (%@)", k, Self.traits.joined(separator: ", "))) }
            if !(0...1).contains(v) { issues.append(L10n.format("style.personality.%@ %@는 0…1 범위를 벗어났습니다", k, "\(v)")) }
        }
        for (from, to) in colors ?? [:] {
            if !PetCatalog.isHexColor(to) { issues.append(L10n.format("style.colors '%@' → '%@'는 #RRGGBB가 아닙니다", from, to)) }
        }
        if let s = speech { issues += s.validate() }
        return issues
    }
}

/// 말투. 혼잣말(정해진 대사)에는 말버릇·말끝·이모지·말수가, 대화 AI에는 전부가 반영된다.
public struct SpeechStyle: Codable, Equatable, Sendable {
    /// 말 앞에 붙는 말버릇 (예: "몽!") — 비우면 펫 기본값
    public var prefix: String?
    /// 말끝 (예: "냥", "다요", "~")
    public var suffix: String?
    /// none · some · lots
    public var emoji: String?
    /// 혼잣말 빈도 0(조용)…1(수다)
    public var chattiness: Double?
    /// 대화할 때 존댓말
    public var polite: Bool?
    /// 대화 AI에게 주는 말투 설명 (예: "느긋한 할머니 말투, 사투리 조금")
    public var tone: String?

    public init(prefix: String? = nil, suffix: String? = nil, emoji: String? = nil, chattiness: Double? = nil, polite: Bool? = nil, tone: String? = nil) {
        self.prefix = prefix
        self.suffix = suffix
        self.emoji = emoji
        self.chattiness = chattiness
        self.polite = polite
        self.tone = tone
    }

    public static let emojiLevels = ["none", "some", "lots"]

    public func merged(with o: SpeechStyle) -> SpeechStyle {
        SpeechStyle(prefix: o.prefix ?? prefix, suffix: o.suffix ?? suffix, emoji: o.emoji ?? emoji,
                    chattiness: o.chattiness ?? chattiness, polite: o.polite ?? polite, tone: o.tone ?? tone)
    }

    public func validate() -> [String] {
        var issues: [String] = []
        if let e = emoji, !Self.emojiLevels.contains(e) { issues.append(L10n.format("style.speech.emoji '%@'는 none·some·lots 중 하나여야 합니다", e)) }
        if let c = chattiness, !(0...1).contains(c) { issues.append(L10n.format("style.speech.chattiness %@는 0…1 범위를 벗어났습니다", "\(c)")) }
        if (prefix?.count ?? 0) > 12 { issues.append(L10n.t("style.speech.prefix는 12자 이내")) }
        if (suffix?.count ?? 0) > 8 { issues.append(L10n.t("style.speech.suffix는 8자 이내")) }
        if (tone?.count ?? 0) > 200 { issues.append(L10n.t("style.speech.tone은 200자 이내")) }
        return issues
    }

    /// 정해진 대사에 말끝·이모지 반영. 문장 끝 부호·이모지 앞에 말끝을 끼운다.
    public func apply(to line: String, roll: Double) -> String {
        var text = line
        if emoji == "none" {
            text = String(text.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000) }
                .map(Character.init)).trimmingCharacters(in: .whitespaces)
        }
        if let suffix, !suffix.isEmpty {
            // 끝의 문장부호·이모지·공백 덩어리를 떼고, 그 앞에 말끝
            var body = text
            var tail = ""
            while let last = body.last, last.isPunctuation || last.isWhitespace || last == "~" || last == "♪"
                    || last.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                tail.insert(last, at: tail.startIndex)
                body.removeLast()
            }
            if !body.isEmpty, !body.hasSuffix(suffix) { text = body + suffix + tail }
        }
        if emoji == "lots", roll < 0.7 {
            let pool = ["✨", "💕", "🌟", "🎵", "😆", "🐾", "💫"]
            text += " " + pool[Int(roll * 100) % pool.count]
        }
        return text
    }
}

extension Personality {
    /// 스타일에서 직접 정한 성격 항목만 덮어쓴다
    public func overridden(by traits: [String: Double]?) -> Personality {
        guard let traits else { return self }
        var p = self
        func v(_ k: String) -> Double? { traits[k].map { max(0, min(1, $0)) } }
        if let x = v("energy") { p.energy = x }
        if let x = v("curiosity") { p.curiosity = x }
        if let x = v("sociability") { p.sociability = x }
        if let x = v("artistry") { p.artistry = x }
        if let x = v("mischief") { p.mischief = x }
        if let x = v("appetite") { p.appetite = x }
        if let x = v("laziness") { p.laziness = x }
        if let x = v("tidiness") { p.tidiness = x }
        return p
    }
}
