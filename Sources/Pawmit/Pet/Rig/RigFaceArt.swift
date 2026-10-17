import CoreGraphics
import Foundation
import PawmitCore

/// 메이커 펫 얼굴: 기준점(두 눈 가운데)에 눈 모양 스타일 + 표정을 그린다. 좌표는 캔버스(y 아래).
enum RigFaceArt {
    static func draw(_ face: RigFace, anchor a: CGPoint, eyes: EyeExpr, mouth: MouthExpr, look: CGVector, heat: CGFloat,
                     sweat: Bool, clock: TimeInterval, outline: CGColor, in ctx: CGContext) {
        let style = face.eyes ?? "dot"
        let gap = CGFloat(face.eyeGap ?? 13)
        let size = CGFloat(face.eyeSize ?? 1)
        let ink = CGColor.fromHex(face.eyeColor ?? "#2A2724") ?? CGColor(gray: 0.15, alpha: 1)
        let lookX = max(-1, min(1, look.dx)) * 1.1, lookY = -max(-1, min(1, look.dy)) * 0.9
        let xs = [a.x - gap / 2, a.x + gap / 2]
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 볼터치 (더우면 더 빨갛고 크게)
        if let bh = face.blush, let blush = CGColor.fromHex(bh) {
            let grow = 1 + 0.4 * heat
            for (i, x) in xs.enumerated() {
                let bx = x + (i == 0 ? -1 : 1) * 3.2 * size
                let r = CGRect(x: bx - 3.4 * grow, y: a.y + 3.2 * size, width: 6.8 * grow, height: 3.6 * grow)
                ctx.setFillColor(blush.copy(alpha: 0.75 + 0.2 * heat) ?? blush)
                ctx.fillEllipse(in: r)
            }
        }

        if style != "none" {
            for (i, x) in xs.enumerated() {
                let e = CGPoint(x: x, y: a.y)
                var expr = eyes
                if expr == .wink { expr = i == 0 ? .open : .happy }
                drawEye(expr, style: style, at: e, left: i == 0, size: size, look: CGPoint(x: lookX, y: lookY), ink: ink, clock: clock, in: ctx)
            }
        }

        drawMouth(mouth, style: face.mouth ?? "smile", at: CGPoint(x: a.x, y: a.y + 5 * size), size: size, ink: ink, in: ctx)

        if sweat {
            let wob = CGFloat(sin(clock * 6)) * 0.6
            let d = CGPoint(x: a.x + gap / 2 + 7 * size, y: a.y - 6 * size + wob)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: d.x, y: d.y - 2.6))
            p.addQuadCurve(to: CGPoint(x: d.x, y: d.y + 2.2), control: CGPoint(x: d.x + 2.6, y: d.y + 1.6))
            p.addQuadCurve(to: CGPoint(x: d.x, y: d.y - 2.6), control: CGPoint(x: d.x - 2.6, y: d.y + 1.6))
            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.8, blue: 0.98, alpha: 0.95))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawEye(_ expr: EyeExpr, style: String, at e: CGPoint, left: Bool, size s: CGFloat, look: CGPoint, ink: CGColor,
                                clock: TimeInterval, in ctx: CGContext) {
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(1.5 * s)
        let base: CGFloat = style == "round" || style == "sparkle" ? 3.1 : 2.3
        switch expr {
        case .closed:
            ctx.move(to: CGPoint(x: e.x - 2.6 * s, y: e.y))
            ctx.addQuadCurve(to: CGPoint(x: e.x + 2.6 * s, y: e.y), control: CGPoint(x: e.x, y: e.y + 2.4 * s))
            ctx.strokePath()
        case .happy:
            ctx.move(to: CGPoint(x: e.x - 2.6 * s, y: e.y + 1))
            ctx.addQuadCurve(to: CGPoint(x: e.x + 2.6 * s, y: e.y + 1), control: CGPoint(x: e.x, y: e.y - 3 * s))
            ctx.strokePath()
        case .squeeze:
            let d: CGFloat = left ? 1 : -1
            ctx.move(to: CGPoint(x: e.x - d * 2.4 * s, y: e.y - 2 * s))
            ctx.addLine(to: CGPoint(x: e.x + d * 2 * s, y: e.y))
            ctx.addLine(to: CGPoint(x: e.x - d * 2.4 * s, y: e.y + 2 * s))
            ctx.strokePath()
        case .half:
            ctx.fillEllipse(in: CGRect(x: e.x - base * s, y: e.y - 0.6 * s, width: base * 2 * s, height: base * 1.4 * s))
            ctx.move(to: CGPoint(x: e.x - (base + 0.8) * s, y: e.y - 0.6 * s))
            ctx.addLine(to: CGPoint(x: e.x + (base + 0.8) * s, y: e.y - 0.9 * s))
            ctx.strokePath()
        case .dot:
            ctx.fillEllipse(in: CGRect(x: e.x - 1.2 * s, y: e.y - 1.2 * s, width: 2.4 * s, height: 2.4 * s))
        case .heart:
            let p = CGMutablePath()
            let c = e, r = 2.4 * s
            p.move(to: CGPoint(x: c.x, y: c.y + r * 1.1))
            p.addCurve(to: CGPoint(x: c.x, y: c.y - r * 0.4), control1: CGPoint(x: c.x - r * 1.6, y: c.y - r * 0.2), control2: CGPoint(x: c.x - r * 0.9, y: c.y - r * 1.4))
            p.addCurve(to: CGPoint(x: c.x, y: c.y + r * 1.1), control1: CGPoint(x: c.x + r * 0.9, y: c.y - r * 1.4), control2: CGPoint(x: c.x + r * 1.6, y: c.y - r * 0.2))
            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.35, blue: 0.5, alpha: 1))
            ctx.fillPath()
        case .star:
            let p = CGMutablePath()
            for k in 0..<10 {
                let r = (k % 2 == 0 ? 3.0 : 1.3) * s
                let ang = CGFloat(k) * .pi / 5 - .pi / 2
                let q = CGPoint(x: e.x + cos(ang) * r, y: e.y + sin(ang) * r)
                if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1))
            ctx.fillPath()
        case .spiral:
            let turns = 2.0, steps = 24
            for k in 0...steps {
                let f = CGFloat(k) / CGFloat(steps)
                let ang = f * CGFloat(turns) * 2 * .pi + CGFloat(clock * 6)
                let r = f * 2.8 * s
                let q = CGPoint(x: e.x + cos(ang) * r, y: e.y + sin(ang) * r)
                if k == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
            }
            ctx.setLineWidth(1 * s)
            ctx.strokePath()
        case .open, .wide, .teary, .wink:
            let w: CGFloat = expr == .wide ? 1.2 : 1
            if style == "sleepy" {
                ctx.fillEllipse(in: CGRect(x: e.x - base * s, y: e.y - 0.4 * s, width: base * 2 * s, height: base * 1.2 * s))
                ctx.move(to: CGPoint(x: e.x - (base + 0.6) * s, y: e.y - 0.4 * s))
                ctx.addLine(to: CGPoint(x: e.x + (base + 0.6) * s, y: e.y - 0.4 * s))
                ctx.strokePath()
            } else {
                let rx = base * s * w, ry = base * s * w * (style == "dot" ? 1.15 : 1.1)
                let c = CGPoint(x: e.x + look.x, y: e.y + look.y)
                ctx.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                let hl = rx * (style == "dot" ? 0.42 : 0.45)
                ctx.fillEllipse(in: CGRect(x: c.x - rx * 0.55 - hl / 2 + rx * 0.2, y: c.y - ry * 0.55 - hl / 2, width: hl, height: hl))
                if style == "round" || style == "sparkle" {
                    let h2 = hl * 0.5
                    ctx.fillEllipse(in: CGRect(x: c.x + rx * 0.35 - h2 / 2, y: c.y + ry * 0.35 - h2 / 2, width: h2, height: h2))
                }
                if style == "sparkle" {
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                    ctx.setLineWidth(0.6 * s)
                    let sc = CGPoint(x: c.x + rx * 0.2, y: c.y - ry * 0.1)
                    ctx.move(to: CGPoint(x: sc.x - 1 * s, y: sc.y)); ctx.addLine(to: CGPoint(x: sc.x + 1 * s, y: sc.y))
                    ctx.move(to: CGPoint(x: sc.x, y: sc.y - 1 * s)); ctx.addLine(to: CGPoint(x: sc.x, y: sc.y + 1 * s))
                    ctx.strokePath()
                }
                if expr == .teary {
                    ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.8, blue: 0.98, alpha: 0.95))
                    let drop = 1.4 + CGFloat((clock * 2).truncatingRemainder(dividingBy: 1)) * 2.5
                    ctx.fillEllipse(in: CGRect(x: e.x - 1.1 * s, y: e.y + ry + drop * s, width: 2.2 * s, height: 2.8 * s))
                }
            }
        }
    }

    private static func drawMouth(_ expr: MouthExpr, style: String, at m: CGPoint, size s: CGFloat, ink: CGColor, in ctx: CGContext) {
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.3 * s)
        let red = CGColor(srgbRed: 0.85, green: 0.35, blue: 0.42, alpha: 1)
        // 기본 표정(smile)은 펫이 고른 입 모양으로
        var expr = expr
        if expr == .smile {
            switch style {
            case "none": return
            case "cat": expr = .cat
            case "tiny":
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: CGRect(x: m.x - 0.8 * s, y: m.y - 0.2, width: 1.6 * s, height: 1.3 * s))
                return
            default: break
            }
        }
        switch expr {
        case .smile, .grin:
            let w: CGFloat = (expr == .grin ? 3.4 : 2.2) * s
            ctx.move(to: CGPoint(x: m.x - w, y: m.y - 0.4))
            ctx.addQuadCurve(to: CGPoint(x: m.x + w, y: m.y - 0.4), control: CGPoint(x: m.x, y: m.y + w * 0.9))
            ctx.strokePath()
        case .cat:
            ctx.move(to: CGPoint(x: m.x - 2.6 * s, y: m.y - 0.3))
            ctx.addQuadCurve(to: CGPoint(x: m.x, y: m.y - 0.3), control: CGPoint(x: m.x - 1.3 * s, y: m.y + 1.8 * s))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 2.6 * s, y: m.y - 0.3), control: CGPoint(x: m.x + 1.3 * s, y: m.y + 1.8 * s))
            ctx.strokePath()
        case .open, .chomp:
            let h: CGFloat = (expr == .chomp ? 1.6 : 3.2) * s
            ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.18, blue: 0.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: m.x - 2.4 * s, y: m.y - 0.6, width: 4.8 * s, height: h))
            ctx.setFillColor(red)
            ctx.fillEllipse(in: CGRect(x: m.x - 1.4 * s, y: m.y - 0.6 + h * 0.45, width: 2.8 * s, height: h * 0.5))
        case .o:
            ctx.strokeEllipse(in: CGRect(x: m.x - 1.4 * s, y: m.y - 0.4, width: 2.8 * s, height: 2.8 * s))
        case .wobbly:
            ctx.move(to: CGPoint(x: m.x - 3 * s, y: m.y + 1))
            ctx.addCurve(to: CGPoint(x: m.x + 3 * s, y: m.y + 1), control1: CGPoint(x: m.x - 1 * s, y: m.y - 1.5), control2: CGPoint(x: m.x + 1 * s, y: m.y + 3.5))
            ctx.strokePath()
        case .flat:
            ctx.move(to: CGPoint(x: m.x - 2 * s, y: m.y + 0.6))
            ctx.addLine(to: CGPoint(x: m.x + 2 * s, y: m.y + 0.6))
            ctx.strokePath()
        case .tongue:
            ctx.move(to: CGPoint(x: m.x - 2.2 * s, y: m.y - 0.4))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 2.2 * s, y: m.y - 0.4), control: CGPoint(x: m.x, y: m.y + 2 * s))
            ctx.strokePath()
            ctx.setFillColor(red)
            ctx.fillEllipse(in: CGRect(x: m.x - 1.1 * s, y: m.y + 0.6 * s, width: 2.2 * s, height: 2.4 * s))
        case .kiss:
            ctx.move(to: CGPoint(x: m.x - 0.6 * s, y: m.y - 1 * s))
            ctx.addQuadCurve(to: CGPoint(x: m.x - 0.6 * s, y: m.y + 0.6 * s), control: CGPoint(x: m.x + 1.6 * s, y: m.y - 0.2 * s))
            ctx.addQuadCurve(to: CGPoint(x: m.x - 0.6 * s, y: m.y + 2.2 * s), control: CGPoint(x: m.x + 1.6 * s, y: m.y + 1.4 * s))
            ctx.strokePath()
        }
    }
}
