import CoreGraphics
import Foundation
import PawmitCore

/// 치비 펫 하나의 정의. 기본 펫·커스텀 펫 모두 pet.json(`"kind": "chibi"`)에서 만들어진다.
/// 부위(귀·꼬리·무늬)는 이름(id)만 들고 있고, 그리는 법은 ChibiParts 레지스트리의 부위 컴포넌트가 안다.
/// 특정 작품의 캐릭터를 복제하지 않고, 같은 계열의 귀여움을 노린 오리지널 디자인이다.
struct ChibiSpecies {
    var id: String
    var name: String
    /// 말버릇 (말풍선 앞에 붙는 감탄사)
    var interjection: String
    /// 부위 id — ChibiParts.ears / tails / patterns
    var ears: String
    var tail: String
    var pattern: String
    var body: CGColor
    var accent: CGColor
    var innerEar: CGColor
    var belly: CGColor?
    var outline: CGColor
    var blush: CGColor
    var headRX: CGFloat = 17.5
    var headRY: CGFloat = 14
}

extension ChibiSpecies {
    /// pet.json → 종족. `base`(기본 펫 위에 덮어쓰기)는 PetCatalog.resolve가 푼다. 모르는 부위 id는 기본 부위로.
    static func from(json raw: JSONValue, fallbackName: String) -> ChibiSpecies? {
        let v = PetCatalog.resolve(raw)
        guard v["kind"]?.string == "chibi" else { return nil }
        func color(_ key: String, _ def: String) -> CGColor { CGColor.fromHex(v[key]?.string ?? def) ?? CGColor.fromHex(def)! }
        let alpha = CGFloat(v["blushAlpha"]?.number ?? 0.85)
        var sp = ChibiSpecies(
            id: v["id"]?.string ?? "custom", name: v["name"]?.string ?? fallbackName, interjection: v["interjection"]?.string ?? "",
            ears: ChibiParts.ear(v["ears"]?.string ?? "").id, tail: ChibiParts.tail(v["tail"]?.string ?? "").id,
            pattern: ChibiParts.pattern(v["pattern"]?.string ?? "").id,
            body: color("body", "#FFFFFF"), accent: color("accent", "#8FA9CC"), innerEar: color("innerEar", "#F8C9D2"),
            belly: v["belly"]?.string.flatMap { CGColor.fromHex($0) }, outline: color("outline", "#403838"),
            blush: color("blush", "#F7A5B8").copy(alpha: max(0, min(1, alpha)))!)
        if let rx = v["headRX"]?.number { sp.headRX = CGFloat(rx) }
        if let ry = v["headRY"]?.number { sp.headRY = CGFloat(ry) }
        return sp
    }

    func toJSON() -> JSONValue {
        var o: [String: JSONValue] = [
            "kind": "chibi", "name": .string(name), "interjection": .string(interjection),
            "ears": .string(ears), "tail": .string(tail), "pattern": .string(pattern),
            "body": .string(body.hex), "accent": .string(accent.hex), "innerEar": .string(innerEar.hex),
            "outline": .string(outline.hex), "blush": .string(blush.hex),
            "blushAlpha": .number((Double(blush.alpha) * 100).rounded() / 100),
            "headRX": .number((Double(headRX) * 10).rounded() / 10), "headRY": .number((Double(headRY) * 10).rounded() / 10),
        ]
        if let belly { o["belly"] = .string(belly.hex) }
        return .object(o)
    }

    /// 기본 펫 (PetCatalog.builtinJSON). 이름·말버릇은 현재 언어로.
    static var all: [ChibiSpecies] {
        PetCatalog.builtins.compactMap { v -> ChibiSpecies? in
            guard var sp = from(json: v, fallbackName: v["id"]?.string ?? "") else { return nil }
            sp.name = PetCatalog.localized(v, "name") ?? sp.name
            sp.interjection = PetCatalog.localized(v, "interjection") ?? sp.interjection
            return sp
        }
    }

    static func named(_ id: String) -> ChibiSpecies? { all.first { $0.id == id } }
}

extension CGColor {
    static func fromHex(_ hex: String) -> CGColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        let r = Int((c[0] * 255).rounded()), g = Int((c[min(1, c.count - 1)] * 255).rounded()), b = Int((c[min(2, c.count - 1)] * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
