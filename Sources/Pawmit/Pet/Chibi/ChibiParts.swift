import CoreGraphics
import Foundation
import PawmitCore

/// 치비 펫 부위 컴포넌트 레지스트리.
///
/// 새 부위 추가 방법 (예: 날개 귀):
/// 1. Ears.swift(또는 Tails.swift·Patterns.swift)에 해당 프로토콜을 따르는 struct를 만든다
/// 2. 아래 목록에 한 줄 추가한다
/// 3. PawmitCore `PetCatalog.chibiEars`에 같은 id를 추가한다 (pet.json 검사·CLI용)
/// 그러면 pet.json의 `"ears": "<id>"`, 위자드 선택지, `pawmit debug sheet` 미리보기에 바로 쓰인다.
enum ChibiParts {
    static let ears: [ChibiEarPart] = [
        RoundEars(), PointyEars(id: "cat", label: L10n.t("고양이 귀"), tall: true), BunnyEars(),
        PointyEars(id: "squirrel", label: L10n.t("다람쥐 귀"), tall: false), TinyEars(), NoEars(),
    ]
    static let tails: [ChibiTailPart] = [NoTail(), CatTail(), PuffTail(), FluffyTail(), OtterTail()]
    static let patterns: [ChibiPatternPart] = [NoPattern(), HachiwarePattern(), ChestnutPattern(), MuzzlePattern()]

    static func ear(_ id: String) -> ChibiEarPart { ears.first { $0.id == id } ?? ears[0] }
    static func tail(_ id: String) -> ChibiTailPart { tails.first { $0.id == id } ?? tails[0] }
    static func pattern(_ id: String) -> ChibiPatternPart { patterns.first { $0.id == id } ?? patterns[0] }

    /// 코어의 부위 목록(PetCatalog)과 어긋난 곳 — 비어 있어야 한다
    static func catalogMismatches() -> [String] {
        var out: [String] = []
        if ears.map(\.id) != PetCatalog.chibiEars { out.append("ears") }
        if tails.map(\.id) != PetCatalog.chibiTails { out.append("tails") }
        if patterns.map(\.id) != PetCatalog.chibiPatterns { out.append("patterns") }
        return out
    }
}

/// 부위가 그릴 때 받는 정보: 지금 포즈의 뼈대와 종족 정의
struct ChibiPartContext {
    let rig: ChibiRenderer.Rig
    let species: ChibiSpecies
    /// 머리 외곽선 (무늬가 모양을 바꿨으면 그 모양, 고개 기울기 반영)
    let headPath: CGPath
    /// 기울이기 전 머리 사각형
    let headRect: CGRect
    /// 귀 색 (무늬가 귀까지 칠하면 무늬 색)
    let earFill: CGColor
    /// 펫마다 고정된 모양 seed
    let seed: UInt64

    var faceX: CGFloat { rig.head.x + rig.faceShift }
    /// 정수리 높이
    var headTop: CGFloat { rig.head.y + species.headRY * rig.headScaleY }
}

protocol ChibiEarPart {
    var id: String { get }
    var label: String { get }
    /// 귀가 머리 위로 올라오는 높이 (말풍선·파티클 위치)
    var extraTop: CGFloat { get }
    /// 실루엣에 들어갈 모양 (외곽선이 머리와 이어진다). 머리보다 먼저 깔린다.
    func shapes(_ c: ChibiPartContext) -> [Ink.Shape]
}

protocol ChibiTailPart {
    var id: String { get }
    var label: String { get }
    /// 몸 뒤에 깔리는 꼬리 (바라보는 반대쪽)
    func shape(_ c: ChibiPartContext) -> Ink.Shape?
}

protocol ChibiPatternPart {
    var id: String { get }
    var label: String { get }
    /// 귀도 무늬 색으로 칠할지
    var tintsEars: Bool { get }
    /// 머리 모양 자체를 바꾸는 무늬 (예: 밤). nil이면 기본 찹쌀떡 머리.
    func headOutline(_ rect: CGRect) -> CGPath?
    /// 머리를 다 칠한 뒤 그 위에 그린다 (보통 머리 안으로 clip)
    func draw(_ c: ChibiPartContext, in ctx: CGContext)
}

extension ChibiPatternPart {
    var tintsEars: Bool { false }
    func headOutline(_ rect: CGRect) -> CGPath? { nil }
}

extension CGPath {
    func rotated(around p: CGPoint, by a: CGFloat) -> CGPath {
        var tf = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: a).translatedBy(x: -p.x, y: -p.y)
        return copy(using: &tf) ?? self
    }
}
