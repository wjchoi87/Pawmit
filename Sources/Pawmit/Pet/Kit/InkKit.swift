import CoreGraphics
import Foundation
import PawmitCore

/// 코드로 그리는 펫(치비·고양이)이 같이 쓰는 그리기 도구.
///
/// "도형을 붙여 놓은" 느낌을 줄이려고:
/// - 정확한 타원 대신 seed로 살짝 찌그러진 덩어리(blob)를 쓴다 (펫마다 모양 고정, 프레임마다 흔들리지 않음)
/// - 팔다리는 뿌리가 넓고 끝이 둥근 모양으로 몸 실루엣에 붙이고, 몸 위에 겹친 부분만 얇은 주름선으로 그린다
/// - 외곽선은 아래·오른쪽이 조금 더 굵다 (손으로 그린 선의 무게감)
/// - 몸 아래쪽 반달 그림자와 머리 밑 그늘로 납작한 스티커 느낌을 줄인다
enum Ink {
    /// 그림자·그늘 같은 꾸밈 (절전 모드에서는 끈다). 몸 위 팔다리 주름선은 모양에 필요해서 항상 그린다.
    nonisolated(unsafe) static var shading = true

    struct Shape {
        var path: CGPath
        var fill: CGColor
        var detail: ((CGContext) -> Void)? = nil
    }

    // MARK: - 모양

    /// 손으로 그린 듯한 둥근 덩어리. 8개 점을 지나는 매끄러운 닫힌 곡선(Catmull-Rom)이다.
    /// - squareness: 대각선 쪽을 부풀려 찹쌀떡처럼 (0...1)
    /// - bottomBias: 아래쪽을 넓혀 서양배처럼 (0...0.2)
    /// - wobble: 점마다 반지름을 이만큼 무작위로 (seed 고정)
    static func blob(_ rect: CGRect, seed: UInt64, wobble: CGFloat = 0.012, squareness: CGFloat = 0,
                     bottomBias: CGFloat = 0, transform: CGAffineTransform = .identity) -> CGPath {
        var rng = SplitMix64(seed: seed)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        var pts: [CGPoint] = []
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            var k = 1 + wobble * CGFloat(rng.range(-1, 1))
            if i % 2 == 1 { k *= 1 + 0.07 * squareness }
            let s = sin(a)
            let wx: CGFloat = s < -0.1 ? 1 + bottomBias * -s : 1
            pts.append(CGPoint(x: c.x + cos(a) * rx * k * wx, y: c.y + s * ry * k))
        }
        return smoothClosed(pts, transform: transform)
    }

    /// 점들을 지나는 닫힌 Catmull-Rom 곡선
    static func smoothClosed(_ p: [CGPoint], transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        let n = p.count
        guard n > 2 else { return path }
        path.move(to: p[0], transform: transform)
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2, transform: transform)
        }
        path.closeSubpath()
        return path
    }

    /// 뿌리가 넓고 끝이 둥근 팔다리 (뭉툭한 벙어리장갑). bend > 0이면 바깥쪽으로 살짝 휜다.
    static func limb(from root: CGPoint, to tip: CGPoint, rootWidth: CGFloat, tipWidth: CGFloat, bend: CGFloat = 0) -> CGPath {
        let dx = tip.x - root.x, dy = tip.y - root.y
        let len = max(0.001, hypot(dx, dy))
        let d = CGVector(dx: dx / len, dy: dy / len)
        let n = CGVector(dx: -d.dy, dy: d.dx)
        let rw = rootWidth / 2, tw = tipWidth / 2
        let mid = CGPoint(x: (root.x + tip.x) / 2 + n.dx * bend, y: (root.y + tip.y) / 2 + n.dy * bend)
        let p = CGMutablePath()
        let a0 = CGPoint(x: root.x + n.dx * rw, y: root.y + n.dy * rw)
        let a1 = CGPoint(x: tip.x + n.dx * tw, y: tip.y + n.dy * tw)
        let b1 = CGPoint(x: tip.x - n.dx * tw, y: tip.y - n.dy * tw)
        let b0 = CGPoint(x: root.x - n.dx * rw, y: root.y - n.dy * rw)
        p.move(to: a0)
        p.addQuadCurve(to: a1, control: CGPoint(x: mid.x + n.dx * (rw + tw) / 2, y: mid.y + n.dy * (rw + tw) / 2))
        // 손끝: 반원보다 살짝 통통하게
        let k: CGFloat = 0.62
        p.addCurve(to: CGPoint(x: tip.x + d.dx * tw * 1.08, y: tip.y + d.dy * tw * 1.08),
                   control1: CGPoint(x: a1.x + d.dx * tw * k * 1.1, y: a1.y + d.dy * tw * k * 1.1),
                   control2: CGPoint(x: tip.x + d.dx * tw * 1.08 + n.dx * tw * k, y: tip.y + d.dy * tw * 1.08 + n.dy * tw * k))
        p.addCurve(to: b1,
                   control1: CGPoint(x: tip.x + d.dx * tw * 1.08 - n.dx * tw * k, y: tip.y + d.dy * tw * 1.08 - n.dy * tw * k),
                   control2: CGPoint(x: b1.x + d.dx * tw * k * 1.1, y: b1.y + d.dy * tw * k * 1.1))
        p.addQuadCurve(to: b0, control: CGPoint(x: mid.x - n.dx * (rw + tw) / 2, y: mid.y - n.dy * (rw + tw) / 2))
        // 뿌리: 몸 안쪽으로 둥글게
        p.addCurve(to: a0, control1: CGPoint(x: b0.x - d.dx * rw * 1.2, y: b0.y - d.dy * rw * 1.2),
                   control2: CGPoint(x: a0.x - d.dx * rw * 1.2, y: a0.y - d.dy * rw * 1.2))
        p.closeSubpath()
        return p
    }

    /// 위는 둥글고 바닥은 납작한 콩 모양 (발)
    static func bean(center c: CGPoint, rx: CGFloat, ry: CGFloat, tilt: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        let tf = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt)
        p.move(to: CGPoint(x: -rx, y: -ry * 0.15), transform: tf)
        p.addCurve(to: CGPoint(x: rx, y: -ry * 0.15), control1: CGPoint(x: -rx, y: ry * 1.3), control2: CGPoint(x: rx, y: ry * 1.3), transform: tf)
        p.addCurve(to: CGPoint(x: -rx, y: -ry * 0.15), control1: CGPoint(x: rx * 1.02, y: -ry * 1.05), control2: CGPoint(x: -rx * 1.02, y: -ry * 1.05), transform: tf)
        p.closeSubpath()
        return p
    }

    // MARK: - 그리기

    /// 스티커 방식: 모든 부위의 외곽선을 먼저 굵게 칠한 뒤 채움을 올려 부위끼리 겹친 안쪽 선이 없는 하나의 실루엣을 만든다.
    /// 외곽선은 오른쪽 아래로 한 번 더 찍어 그쪽이 조금 굵다.
    /// - extraOutlines: 외곽선만 실루엣에 넣고 채움은 호출자가 나중에 하는 부위 (얼굴 뒤에 칠할 팔 등)
    static func sticker(_ shapes: [Shape], outline: CGColor, width: CGFloat, weight: CGFloat = 0.6,
                        extraOutlines: [CGPath] = [], in ctx: CGContext) {
        // 외곽선은 선만 긋는다 (안쪽은 어차피 채움 패스가 덮는다)
        let paths = shapes.map(\.path) + extraOutlines
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(width)
        for p in paths {
            ctx.addPath(p)
            ctx.strokePath()
        }
        if weight > 0 {
            ctx.translateBy(x: weight * 0.45, y: -weight)
            for p in paths {
                ctx.addPath(p)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
        for s in shapes {
            ctx.addPath(s.path)
            ctx.setFillColor(s.fill)
            ctx.fillPath()
            s.detail?(ctx)
        }
    }

    /// 겹친 부위의 경계선을 `inside` 영역 안에서만 얇게 (몸 위에 놓인 팔·발)
    /// - excluding: 이 원들 안에는 긋지 않는다 (어깨처럼 몸에 묻히는 뿌리)
    static func crease(_ path: CGPath, inside clip: CGPath, excluding holes: [(CGPoint, CGFloat)] = [],
                       color: CGColor, width: CGFloat = 1.3, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        if !holes.isEmpty {
            ctx.addRect(clip.boundingBoxOfPath.insetBy(dx: -10, dy: -10))
            for (c, r) in holes { ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
            ctx.clip(using: .evenOdd)
        }
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 덩어리 오른쪽 아래의 반달 그림자 (path 안쪽만). 같은 path를 왼쪽 위로 민 만큼이 빠진다.
    static func shade(_ path: CGPath, offset: CGVector, color: CGColor, in ctx: CGContext) {
        guard shading else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let box = path.boundingBoxOfPath.insetBy(dx: -4, dy: -4)
        var tf = CGAffineTransform(translationX: -offset.dx, y: -offset.dy)
        ctx.addRect(box)
        if let shifted = path.copy(using: &tf) { ctx.addPath(shifted) }
        ctx.setFillColor(color)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// 머리가 몸에 드리우는 그늘 등, path 안쪽에 부드러운 타원
    static func occlusion(_ path: CGPath, ellipse: CGRect, color: CGColor, in ctx: CGContext) {
        guard shading else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(color)
        ctx.fillEllipse(in: ellipse)
        ctx.restoreGState()
    }

    /// 그림자·주름선 색: 외곽선 색을 옅게
    static func tint(_ outline: CGColor, _ alpha: CGFloat) -> CGColor {
        outline.copy(alpha: alpha) ?? CGColor(gray: 0, alpha: alpha)
    }

    /// 펫마다 고정된 모양 seed
    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
