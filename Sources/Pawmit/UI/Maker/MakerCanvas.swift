import AppKit
import SwiftUI
import PawmitCore

/// 메이커 캔버스: 100×100 펫 캔버스(y 아래, 바닥 y=96)를 그대로 확대해서 보여주고 펜·동그라미·옮기기·얼굴·지우개로 편집한다.
struct MakerCanvas: NSViewRepresentable {
    @ObservedObject var model: MakerModel

    func makeNSView(context: Context) -> MakerCanvasView {
        let v = MakerCanvasView()
        v.model = model
        return v
    }

    func updateNSView(_ v: MakerCanvasView, context: Context) {
        v.model = model
        v.needsDisplay = true
    }
}

final class MakerCanvasView: NSView {
    weak var model: MakerModel?
    private var stroke: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragLast: CGPoint?
    private enum Drag { case pivot(String), part(String) }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 화면 1pt당 캔버스 단위
    private var S: CGFloat { min(bounds.width, bounds.height) / 100 }
    private var origin: CGPoint { CGPoint(x: (bounds.width - 100 * S) / 2, y: (bounds.height - 100 * S) / 2) }

    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: (p.x - origin.x) / S, y: (p.y - origin.y) / S)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model else { return }
        let S = self.S, o = origin
        // 바탕: 옅은 모눈 + 바닥선
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.5)
        for i in stride(from: 0, through: 100, by: 10) {
            ctx.move(to: CGPoint(x: CGFloat(i) * S, y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(i) * S, y: 100 * S))
            ctx.move(to: CGPoint(x: 0, y: CGFloat(i) * S)); ctx.addLine(to: CGPoint(x: 100 * S, y: CGFloat(i) * S))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: 0, y: RigSpec.groundY * S)); ctx.addLine(to: CGPoint(x: 100 * S, y: RigSpec.groundY * S))
        ctx.strokePath()

        // 펫 (쉬는 자세): 펫 단위 → 캔버스 → 화면
        let k = RigRenderer.unit
        ctx.saveGState()
        ctx.translateBy(x: 50 * S, y: RigSpec.groundY * S)
        ctx.scaleBy(x: S / k, y: -S / k)
        model.renderer.renderRest(in: ctx)
        ctx.restoreGState()

        ctx.scaleBy(x: S, y: S)
        // 고른 부위 강조
        if let part = model.renderer.parts.first(where: { $0.id == model.selected }) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.2 / S * 1.5)
            ctx.setLineDash(phase: 0, lengths: [3 / S * 2, 2 / S * 2])
            if let sil = part.silhouette { ctx.addPath(sil); ctx.strokePath() }
            if part.image != nil { ctx.stroke(part.imageRect) }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // 관절 점
        for id in model.partIDs {
            guard let pv = model.pivot(of: id), model.spec.parts[id] != nil || id == model.selected else { continue }
            let sel = id == model.selected
            let r: CGFloat = sel ? 1.6 : 1.0
            ctx.setFillColor((sel ? NSColor.controlAccentColor : NSColor.systemOrange).withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: pv.x - r, y: pv.y - r, width: r * 2, height: r * 2))
        }
        // 얼굴 기준점
        if model.spec.face.anchor.count == 2, model.tool == .face {
            let a = CGPoint(x: model.spec.face.anchor[0], y: model.spec.face.anchor[1])
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: a.x - 4, y: a.y)); ctx.addLine(to: CGPoint(x: a.x + 4, y: a.y))
            ctx.move(to: CGPoint(x: a.x, y: a.y - 4)); ctx.addLine(to: CGPoint(x: a.x, y: a.y + 4))
            ctx.strokePath()
        }
        // 그리는 중인 선·동그라미
        if stroke.count > 1 {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(0.8)
            ctx.addLines(between: stroke)
            ctx.strokePath()
        }
        if model.tool == .ellipse, let a = dragStart, let b = dragLast {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        ctx.restoreGState()
    }

    override func mouseDown(with e: NSEvent) {
        guard let model else { return }
        let p = canvasPoint(e)
        dragStart = p
        dragLast = p
        switch model.tool {
        case .pen:
            stroke = [p]
        case .ellipse:
            break
        case .move:
            // 관절 점을 잡으면 관절만, 부위를 잡으면 부위 통째로
            let hitPivot = model.partIDs.compactMap { id -> (String, CGFloat)? in
                guard let pv = model.pivot(of: id), model.spec.parts[id] != nil else { return nil }
                return (id, hypot(pv.x - p.x, pv.y - p.y))
            }.filter { $0.1 < 2.6 }.min { $0.1 < $1.1 }
            if let (id, _) = hitPivot {
                model.selected = id
                drag = .pivot(id)
                model.beginLiveEdit()
            } else if let id = model.part(at: p) {
                model.selected = id
                drag = .part(id)
                model.beginLiveEdit()
            }
        case .face:
            let onHead = model.renderer.parts.first { $0.id == "head" }?.silhouette?.contains(p) == true
            model.setFace(at: p, onHead: onHead)
        case .erase:
            model.erase(at: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let model else { return }
        let p = canvasPoint(e)
        switch model.tool {
        case .pen:
            if let last = stroke.last, hypot(p.x - last.x, p.y - last.y) > 0.35 { stroke.append(p) }
        case .move:
            if let last = dragLast {
                switch drag {
                case .pivot(let id): model.setPivot(id, to: p)
                case .part(let id): model.translatePart(id, by: CGSize(width: p.x - last.x, height: p.y - last.y))
                case nil: break
                }
            }
        default:
            break
        }
        dragLast = p
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let model else { return }
        let p = canvasPoint(e)
        switch model.tool {
        case .pen:
            stroke.append(p)
            if let path = Self.closedShape(from: stroke) { model.addShape(path) }
            stroke = []
        case .ellipse:
            if let a = dragStart {
                let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                if r.width > 1.5, r.height > 1.5 { model.addShape(CGPath(ellipseIn: r, transform: nil)) }
            }
        case .move:
            if drag != nil { model.endLiveEdit() }
            drag = nil
        default:
            break
        }
        dragStart = nil
        dragLast = nil
        needsDisplay = true
    }

    /// 손으로 그은 선 → 점을 줄이고 매끄럽게 닫힌 모양 (손떨림은 줄이되 손그림 느낌은 남김)
    static func closedShape(from raw: [CGPoint]) -> CGPath? {
        guard raw.count >= 5 else { return nil }
        var length: CGFloat = 0
        for i in 1..<raw.count { length += hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y) }
        guard length > 5 else { return nil }
        let simple = simplify(raw, epsilon: 0.45)
        guard simple.count >= 3 else { return nil }
        // 너무 성긴 곳은 사이 점을 넣어 곡선이 튀지 않게
        var pts: [CGPoint] = []
        for (i, a) in simple.enumerated() {
            pts.append(a)
            let b = simple[(i + 1) % simple.count]
            let d = hypot(b.x - a.x, b.y - a.y)
            if d > 8 { pts.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) }
        }
        return Ink.smoothClosed(pts)
    }

    /// Ramer–Douglas–Peucker
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let a = pts.first!, b = pts.last!
        var maxD: CGFloat = 0, idx = 0
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.0001, hypot(dx, dy))
        for i in 1..<(pts.count - 1) {
            let d = abs(dy * pts[i].x - dx * pts[i].y + b.x * a.y - b.y * a.x) / len
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > epsilon {
            let l = simplify(Array(pts[...idx]), epsilon: epsilon)
            let r = simplify(Array(pts[idx...]), epsilon: epsilon)
            return Array(l.dropLast()) + r
        }
        return [a, b]
    }
}
