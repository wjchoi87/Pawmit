import CoreGraphics
import Foundation
import PawmitCore

/// 펫 스타일(성격·말투·색) 계산과 적용. 생김새 정의와 따로 두고 모든 펫에 같은 방식으로 얹는다.
enum PetStyles {
    /// folder:<이름> / path:<경로> 펫의 폴더와 pet.json
    static func petJSON(_ id: String) -> (URL, JSONValue?)? {
        guard let folder = folder(id) else { return nil }
        let meta = (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
        return (folder, meta)
    }

    static func folder(_ id: String) -> URL? {
        if id.hasPrefix("path:") { return URL(fileURLWithPath: String(id.dropFirst("path:".count)), isDirectory: true) }
        if id.hasPrefix("folder:") { return PawmitPaths.petsDir.appendingPathComponent(String(id.dropFirst("folder:".count)), isDirectory: true) }
        return nil
    }

    /// pet.json의 style 위에 설정(petStyles[id])을 덮은 최종 스타일
    static func effective(_ id: String, config: PawmitConfig) -> PetStyle {
        var base = PetStyle()
        if let (_, meta) = petJSON(id), let st = meta?["style"], let data = st.encoded().data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PetStyle.self, from: data) {
            base = decoded
        }
        return base.merged(with: config.petStyles[id])
    }

    static func digest(_ colors: [String: String]?) -> String {
        (colors ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    // MARK: - 색 바꾸기

    static var chibiFields: [(String, String)] {
        [("body", L10n.t("몸")), ("accent", L10n.t("무늬·꼬리")), ("belly", L10n.t("배")), ("innerEar", L10n.t("귀 안쪽")),
         ("outline", L10n.t("외곽선")), ("blush", L10n.t("볼터치"))]
    }
    static var catFields: [(String, String)] {
        [("body", L10n.t("털")), ("stripe", L10n.t("줄무늬")), ("belly", L10n.t("배")), ("earInner", L10n.t("귀 안쪽")),
         ("outline", L10n.t("외곽선")), ("eye", L10n.t("눈")), ("nose", L10n.t("코")), ("cheek", L10n.t("볼"))]
    }

    static func apply(_ colors: [String: String]?, to sp: inout ChibiSpecies) {
        guard let colors else { return }
        func c(_ k: String) -> CGColor? { colors[k].flatMap(CGColor.fromHex) }
        if let v = c("body") { sp.body = v }
        if let v = c("accent") { sp.accent = v }
        if let v = c("belly") { sp.belly = v }
        if let v = c("innerEar") { sp.innerEar = v }
        if let v = c("outline") { sp.outline = v }
        if let v = c("blush") { sp.blush = v.copy(alpha: sp.blush.alpha) ?? v }
    }

    static func apply(_ colors: [String: String]?, to p: inout CatPalette) {
        guard let colors else { return }
        func c(_ k: String) -> CGColor? { colors[k].flatMap(CGColor.fromHex) }
        if let v = c("body") { p.body = v }
        if let v = c("stripe") { p.stripe = v }
        if let v = c("belly") { p.belly = v }
        if let v = c("earInner") { p.earInner = v }
        if let v = c("outline") { p.outline = v }
        if let v = c("eye") { p.eye = v }
        if let v = c("nose") { p.nose = v }
        if let v = c("cheek") { p.cheek = v.copy(alpha: 0.55) ?? v }
    }

    /// 설정 창 색 칸: (스타일 키, 이름, 원래 색). 메이커 펫은 쓰인 색마다 한 칸 (키가 원래 색).
    static func colorFields(for id: String, config: PawmitConfig) -> [(String, String, String)] {
        let identity = PetRoster.make(id: id, config: config, styled: false)
        switch identity.renderer {
        case let r as ChibiRenderer:
            let sp = r.species
            let current: [String: CGColor?] = ["body": sp.body, "accent": sp.accent, "belly": sp.belly, "innerEar": sp.innerEar,
                                               "outline": sp.outline, "blush": sp.blush]
            return chibiFields.compactMap { k, name in (current[k] ?? nil).map { (k, name, $0.hex) } }
        case let r as CatRenderer:
            let p = r.palette
            let current: [String: CGColor?] = ["body": p.body, "stripe": p.stripe, "belly": p.belly, "earInner": p.earInner,
                                               "outline": p.outline, "eye": p.eye, "nose": p.nose, "cheek": p.cheek]
            return catFields.compactMap { k, name in (current[k] ?? nil).map { (k, name, $0.hex) } }
        case let r as RigRenderer:
            var seen: [String] = []
            for part in r.spec.parts.keys.sorted() {
                for s in r.spec.parts[part]?.shapes ?? [] where !seen.contains(s.fill.uppercased()) { seen.append(s.fill.uppercased()) }
            }
            var out = [(r.spec.outline.uppercased(), L10n.t("외곽선"), r.spec.outline.uppercased())]
            out += seen.prefix(10).enumerated().map { ($1, L10n.format("색 %lld", $0 + 1), $1) }
            return out
        default:
            return []
        }
    }
}
