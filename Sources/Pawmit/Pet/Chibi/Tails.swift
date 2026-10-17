import CoreGraphics
import Foundation
import PawmitCore

// 치비 꼬리 컴포넌트. 몸 뒤(왼쪽, -x)에 깔린다. 흔들림은 c.rig.tailSwing.

struct NoTail: ChibiTailPart {
    let id = "none"
    var label: String { L10n.t("없음") }
    func shape(_ c: ChibiPartContext) -> Ink.Shape? { nil }
}

/// 위로 말린 고양이 꼬리
struct CatTail: ChibiTailPart {
    let id = "cat"
    var label: String { L10n.t("고양이") }

    func shape(_ c: ChibiPartContext) -> Ink.Shape? {
        let b = c.rig.body, sw = c.rig.tailSwing
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.x - 9, y: b.y - 5))
        p.addCurve(to: CGPoint(x: b.x - 18 + sw * 10, y: b.y + 15),
                   control1: CGPoint(x: b.x - 21, y: b.y - 6),
                   control2: CGPoint(x: b.x - 22, y: b.y + 9))
        return Ink.Shape(path: p.copy(strokingWithWidth: 4.6, lineCap: .round, lineJoin: .round, miterLimit: 2), fill: c.species.accent)
    }
}

/// 동글동글 솜뭉치 꼬리
struct PuffTail: ChibiTailPart {
    let id = "puff"
    var label: String { L10n.t("솜뭉치") }

    func shape(_ c: ChibiPartContext) -> Ink.Shape? {
        let ctr = CGPoint(x: c.rig.body.x - 11.5, y: c.rig.body.y - 4)
        let rect = CGRect(x: ctr.x - 4.8, y: ctr.y - 4.6, width: 9.6, height: 9.2)
        return Ink.Shape(path: Ink.blob(rect, seed: c.seed &+ 21, wobble: 0.08), fill: c.species.belly ?? c.species.body)
    }
}

/// 등 뒤로 솟은 풍성한 꼬리 (날다람쥐)
struct FluffyTail: ChibiTailPart {
    let id = "fluffy"
    var label: String { L10n.t("풍성") }

    func shape(_ c: ChibiPartContext) -> Ink.Shape? {
        let b = c.rig.body, sw = c.rig.tailSwing
        // 몸과 다른 색이라야 실루엣이 덩어리로 뭉치지 않는다
        let p = CGMutablePath()
        let tip = CGPoint(x: b.x - 17 + sw * 7, y: b.y + 22)
        p.move(to: CGPoint(x: b.x - 8, y: b.y - 5))
        p.addCurve(to: tip, control1: CGPoint(x: b.x - 20, y: b.y - 6), control2: CGPoint(x: b.x - 23, y: b.y + 10))
        let shape = p.copy(strokingWithWidth: 8.5, lineCap: .round, lineJoin: .round, miterLimit: 2)
        let body = c.species.body
        return Ink.Shape(path: shape, fill: c.species.accent, detail: { ctx in
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.setFillColor(body)
            ctx.fillEllipse(in: CGRect(x: tip.x - 6.5, y: tip.y - 4, width: 13, height: 11))
            ctx.restoreGState()
        })
    }
}

/// 바닥에 끌리는 굵은 수달 꼬리
struct OtterTail: ChibiTailPart {
    let id = "otter"
    var label: String { L10n.t("수달") }

    func shape(_ c: ChibiPartContext) -> Ink.Shape? {
        let b = c.rig.body, sw = c.rig.tailSwing
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.x - 8, y: b.y - 6))
        p.addQuadCurve(to: CGPoint(x: b.x - 22, y: b.y - 8.5 + sw * 6), control: CGPoint(x: b.x - 16, y: b.y - 10))
        return Ink.Shape(path: p.copy(strokingWithWidth: 6.2, lineCap: .round, lineJoin: .round, miterLimit: 2), fill: c.species.body)
    }
}
