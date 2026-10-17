import PawmitCore
import CoreGraphics
import Foundation

// 치비 무늬 컴포넌트. 머리를 다 칠한 뒤 머리 안쪽(c.headPath)에 그린다.

struct NoPattern: ChibiPatternPart {
    let id = "none"
    var label: String { L10n.t("없음") }
    func draw(_ c: ChibiPartContext, in ctx: CGContext) {}
}

/// 정수리를 덮고 이마 가운데가 ∧ 모양으로 갈라지는 하치와레 무늬. 귀도 무늬 색.
struct HachiwarePattern: ChibiPatternPart {
    let id = "hachiware"
    var label: String { L10n.t("반반(하치와레)") }
    var tintsEars: Bool { true }

    func draw(_ c: ChibiPartContext, in ctx: CGContext) {
        let rect = c.headRect, fx = c.faceX, hy = c.rig.head.y
        ctx.saveGState()
        ctx.addPath(c.headPath)
        ctx.clip()
        let p = CGMutablePath()
        let topY = rect.maxY + 2
        let sideY = hy + 1.5
        p.move(to: CGPoint(x: rect.minX - 2, y: sideY))
        p.addQuadCurve(to: CGPoint(x: fx - 2.2, y: hy + 4.2), control: CGPoint(x: rect.minX + 8, y: hy + 7.5))
        p.addQuadCurve(to: CGPoint(x: fx - 1.2, y: topY), control: CGPoint(x: fx - 7, y: hy + 10))
        p.addLine(to: CGPoint(x: fx + 1.2, y: topY))
        p.addQuadCurve(to: CGPoint(x: fx + 2.2, y: hy + 4.2), control: CGPoint(x: fx + 7, y: hy + 10))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + 2, y: sideY), control: CGPoint(x: rect.maxX - 8, y: hy + 7.5))
        p.addLine(to: CGPoint(x: rect.maxX + 2, y: topY + 4))
        p.addLine(to: CGPoint(x: rect.minX - 2, y: topY + 4))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(c.species.accent)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// 밤 모양 머리 + 물결 모양 밤 껍질 모자
struct ChestnutPattern: ChibiPatternPart {
    let id = "chestnut"
    var label: String { L10n.t("밤 모자") }

    /// 꼭지 없이 위가 둥그스름한 밤 (위쪽은 타원 호, 아래는 살짝 넓게)
    func headOutline(_ rect: CGRect) -> CGPath? {
        let p = CGMutablePath()
        let cx = rect.midX, top = rect.maxY + 1.2, bottom = rect.minY
        let side = rect.midY - 1
        let rx = rect.width / 2
        p.move(to: CGPoint(x: cx, y: top))
        p.addCurve(to: CGPoint(x: rect.maxX, y: side),
                   control1: CGPoint(x: cx + rx * 0.56, y: top),
                   control2: CGPoint(x: rect.maxX, y: side + (top - side) * 0.56))
        p.addCurve(to: CGPoint(x: cx, y: bottom),
                   control1: CGPoint(x: rect.maxX, y: rect.minY + 4),
                   control2: CGPoint(x: cx + rect.width * 0.32, y: bottom))
        p.addCurve(to: CGPoint(x: rect.minX, y: side),
                   control1: CGPoint(x: cx - rect.width * 0.32, y: bottom),
                   control2: CGPoint(x: rect.minX, y: rect.minY + 4))
        p.addCurve(to: CGPoint(x: cx, y: top),
                   control1: CGPoint(x: rect.minX, y: side + (top - side) * 0.56),
                   control2: CGPoint(x: cx - rx * 0.56, y: top))
        p.closeSubpath()
        return p
    }

    func draw(_ c: ChibiPartContext, in ctx: CGContext) {
        let rect = c.headRect
        ctx.saveGState()
        ctx.addPath(c.headPath)
        ctx.clip()
        let p = CGMutablePath()
        let edgeY = c.rig.head.y + 3.5
        p.move(to: CGPoint(x: rect.minX - 3, y: edgeY - 1))
        var x = rect.minX - 3
        var up = true
        while x < rect.maxX + 3 {
            let nx = x + 5.2
            p.addQuadCurve(to: CGPoint(x: nx, y: edgeY), control: CGPoint(x: x + 2.6, y: edgeY + (up ? 2.2 : -2.2)))
            up.toggle()
            x = nx
        }
        p.addLine(to: CGPoint(x: rect.maxX + 3, y: rect.maxY + 8))
        p.addLine(to: CGPoint(x: rect.minX - 3, y: rect.maxY + 8))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(c.species.accent)
        ctx.fillPath()
        // 윤기
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
        ctx.fillEllipse(in: CGRect(x: rect.minX + 6, y: rect.maxY - 6, width: 6, height: 3.2))
        ctx.restoreGState()
    }
}

/// 입 주변이 밝은 주둥이 (해달)
struct MuzzlePattern: ChibiPatternPart {
    let id = "muzzle"
    var label: String { L10n.t("주둥이") }

    func draw(_ c: ChibiPartContext, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(c.headPath)
        ctx.clip()
        ctx.setFillColor(c.species.accent)
        ctx.addPath(Ink.blob(CGRect(x: c.faceX - 12.5, y: c.headRect.minY - 3, width: 25, height: 16), seed: c.seed &+ 31, wobble: 0.03))
        ctx.fillPath()
        ctx.restoreGState()
    }
}
