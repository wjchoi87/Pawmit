import PawmitCore
import CoreGraphics
import Foundation

// 치비 귀 컴포넌트. 좌표는 펫 단위(발 중심 0,0, 오른쪽을 보는 기준), 머리 위치는 c.rig.head.

struct NoEars: ChibiEarPart {
    let id = "none"
    var label: String { L10n.t("없음") }
    let extraTop: CGFloat = 4
    func shapes(_ c: ChibiPartContext) -> [Ink.Shape] { [] }
}

/// 둥근 곰 귀
struct RoundEars: ChibiEarPart {
    let id = "round"
    var label: String { L10n.t("둥근 곰 귀") }
    let extraTop: CGFloat = 6

    func shapes(_ c: ChibiPartContext) -> [Ink.Shape] {
        let h = c.rig.head
        return [-1, 1].map { (s: CGFloat) -> Ink.Shape in
            let ctr = CGPoint(x: h.x + s * 11.2, y: c.headTop - 3.2 + c.rig.earPerk * 3)
            let rect = CGRect(x: ctr.x - 5.4, y: ctr.y - 5.2, width: 10.8, height: 10.4)
            let inner = c.species.innerEar
            return Ink.Shape(path: Ink.blob(rect, seed: c.seed &+ (s > 0 ? 11 : 12), wobble: 0.03, squareness: 0.3),
                             fill: c.species.body, detail: { ctx in
                ctx.setFillColor(inner)
                ctx.fillEllipse(in: rect.insetBy(dx: 2.8, dy: 2.9).offsetBy(dx: -s * 0.4, dy: 0.2))
            })
        }
    }
}

/// 작은 동그란 귀 (해달)
struct TinyEars: ChibiEarPart {
    let id = "tiny"
    var label: String { L10n.t("작은 귀") }
    let extraTop: CGFloat = 4

    func shapes(_ c: ChibiPartContext) -> [Ink.Shape] {
        let h = c.rig.head
        return [-1, 1].map { (s: CGFloat) -> Ink.Shape in
            let ctr = CGPoint(x: h.x + s * 14.6, y: h.y + 8.5)
            let rect = CGRect(x: ctr.x - 3.4, y: ctr.y - 3.4, width: 6.8, height: 6.8)
            let inner = c.species.innerEar
            return Ink.Shape(path: Ink.blob(rect, seed: c.seed &+ (s > 0 ? 13 : 14), wobble: 0.04), fill: c.species.body, detail: { ctx in
                ctx.setFillColor(inner)
                ctx.fillEllipse(in: rect.insetBy(dx: 1.8, dy: 1.8))
            })
        }
    }
}

/// 세모 귀: 고양이(높고 넓게)·다람쥐(작게)
struct PointyEars: ChibiEarPart {
    let id: String
    let label: String
    /// true면 고양이 귀
    let tall: Bool
    var extraTop: CGFloat { 6 }

    func shapes(_ c: ChibiPartContext) -> [Ink.Shape] {
        let h = c.rig.head
        let r = c.rig
        return [-1, 1].map { (s: CGFloat) -> Ink.Shape in
            let base = CGPoint(x: h.x + s * (tall ? 9.6 : 10.4), y: c.headTop - 4.5)
            let height: CGFloat = (tall ? 11 : 9) + r.earPerk * 5 - r.earFlop * 4
            let half: CGFloat = tall ? 6.4 : 5.2
            // 끝이 살짝 둥근 세모 (뾰족한 꼭짓점 대신 작은 곡선)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: base.x - half, y: base.y))
            p.addQuadCurve(to: CGPoint(x: base.x - 0.9, y: base.y + height - 0.6), control: CGPoint(x: base.x - half * 0.8, y: base.y + height * 0.72))
            p.addQuadCurve(to: CGPoint(x: base.x + 0.9, y: base.y + height - 0.6), control: CGPoint(x: base.x, y: base.y + height + 0.7))
            p.addQuadCurve(to: CGPoint(x: base.x + half, y: base.y), control: CGPoint(x: base.x + half * 0.8, y: base.y + height * 0.72))
            p.closeSubpath()
            let tilt = s * (tall ? -0.3 : -0.38) - s * r.earFlop * 0.5
            let outer = p.rotated(around: base, by: tilt)
            let ip = CGMutablePath()
            ip.move(to: CGPoint(x: base.x - half * 0.5, y: base.y + 1.4))
            ip.addQuadCurve(to: CGPoint(x: base.x, y: base.y + height * 0.66), control: CGPoint(x: base.x - half * 0.32, y: base.y + height * 0.5))
            ip.addQuadCurve(to: CGPoint(x: base.x + half * 0.5, y: base.y + 1.4), control: CGPoint(x: base.x + half * 0.32, y: base.y + height * 0.5))
            ip.closeSubpath()
            let innerPath = ip.rotated(around: base, by: tilt)
            let inner = c.species.innerEar
            return Ink.Shape(path: outer, fill: c.earFill, detail: { ctx in
                ctx.addPath(innerPath)
                ctx.setFillColor(inner)
                ctx.fillPath()
            })
        }
    }
}

/// 긴 토끼 귀
struct BunnyEars: ChibiEarPart {
    let id = "bunny"
    var label: String { L10n.t("토끼 귀") }
    let extraTop: CGFloat = 18

    func shapes(_ c: ChibiPartContext) -> [Ink.Shape] {
        let h = c.rig.head
        let r = c.rig
        return [-1, 1].map { (s: CGFloat) -> Ink.Shape in
            let base = CGPoint(x: h.x + s * 6.2, y: c.headTop - 4)
            let len: CGFloat = 21 + r.earPerk * 4
            let flop = r.earFlop * 1.1 + CGFloat(sin(Double(r.tailSwing) * 6)) * 0.03
            let angle = -s * (0.14 + flop)
            // 뿌리는 좁고 가운데가 통통한 잎 모양
            let w: CGFloat = 4.4
            let p = CGMutablePath()
            p.move(to: CGPoint(x: base.x - w * 0.75, y: base.y))
            p.addCurve(to: CGPoint(x: base.x, y: base.y + len),
                       control1: CGPoint(x: base.x - w * 1.25, y: base.y + len * 0.45), control2: CGPoint(x: base.x - w * 1.1, y: base.y + len))
            p.addCurve(to: CGPoint(x: base.x + w * 0.75, y: base.y),
                       control1: CGPoint(x: base.x + w * 1.1, y: base.y + len), control2: CGPoint(x: base.x + w * 1.25, y: base.y + len * 0.45))
            p.closeSubpath()
            let outer = p.rotated(around: base, by: angle)
            let ip = CGMutablePath()
            ip.move(to: CGPoint(x: base.x - 1.2, y: base.y + 3))
            ip.addCurve(to: CGPoint(x: base.x, y: base.y + len - 4.5),
                        control1: CGPoint(x: base.x - 2.6, y: base.y + len * 0.5), control2: CGPoint(x: base.x - 2.2, y: base.y + len - 4.5))
            ip.addCurve(to: CGPoint(x: base.x + 1.2, y: base.y + 3),
                        control1: CGPoint(x: base.x + 2.2, y: base.y + len - 4.5), control2: CGPoint(x: base.x + 2.6, y: base.y + len * 0.5))
            ip.closeSubpath()
            let innerPath = ip.rotated(around: base, by: angle)
            let inner = c.species.innerEar
            return Ink.Shape(path: outer, fill: c.species.body, detail: { ctx in
                ctx.addPath(innerPath)
                ctx.setFillColor(inner)
                ctx.fillPath()
            })
        }
    }
}
