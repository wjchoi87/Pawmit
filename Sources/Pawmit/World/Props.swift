import AppKit

/// 펫이 쓰는 소품(밥그릇·털실공·휴지통)을 띄우는 작은 투명 창. 펫 창보다 한 층 아래.
@MainActor
final class PropWindow {
    enum Kind { case bowl, ball, trashCan, thermometer, scale, bucket, ladder, rope, umbrella }

    let kind: Kind
    /// 바닥 중심 (전역 좌표)
    var position: CGPoint
    var velocity = CGVector.zero
    /// 밥그릇에 남은 주먹밥 수
    var food = 3 { didSet { dirty = true } }
    /// 온도계·체중계 눈금 (0...1)과 표시 글자
    var level: Double = 0 { didSet { dirty = true } }
    var readout: String? { didSet { dirty = true } }
    private var dirty = true
    private(set) var appearScale: CGFloat = 0.2
    private var alpha: CGFloat = 0
    private var disappearing = false
    private var spin: CGFloat = 0
    private let window: NSPanel
    private let view: PropView
    let size: CGSize
    /// 크기 기준 (펫 크기 비례)
    private let unit: CGFloat
    /// 우산 천 색
    private let tint: CGColor
    var onGone: (() -> Void)?

    /// length: 사다리·밧줄 길이, 우산 손잡이 길이 (pt)
    init(kind: Kind, at position: CGPoint, scale: CGFloat, length: CGFloat = 0) {
        self.kind = kind
        self.position = position
        unit = scale
        let tints: [(CGFloat, CGFloat, CGFloat)] = [(0.98, 0.62, 0.68), (0.55, 0.78, 0.98), (0.99, 0.82, 0.38), (0.66, 0.86, 0.62), (0.78, 0.66, 0.96)]
        let t = tints.randomElement()!
        tint = CGColor(srgbRed: t.0, green: t.1, blue: t.2, alpha: 1)
        switch kind {
        case .bowl: size = CGSize(width: 46 * scale, height: 34 * scale)
        case .ball: size = CGSize(width: 22 * scale, height: 22 * scale)
        case .trashCan: size = CGSize(width: 34 * scale, height: 42 * scale)
        case .thermometer: size = CGSize(width: 30 * scale, height: 78 * scale)
        case .scale: size = CGSize(width: 74 * scale, height: 40 * scale)
        case .bucket: size = CGSize(width: 36 * scale, height: 34 * scale)
        case .ladder: size = CGSize(width: 28 * scale, height: max(20, length))
        case .rope: size = CGSize(width: 14 * scale, height: max(20, length))
        case .umbrella: size = CGSize(width: 64 * scale, height: max(10, length) + 28 * scale)
        }
        let extra: CGFloat = kind == .thermometer ? 26 : kind == .umbrella ? 8 + 10 * scale : 8
        view = PropView(frame: NSRect(origin: .zero, size: CGSize(width: max(size.width + 8, 70), height: size.height + extra)))
        window = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.prop = self
        sync()
        window.orderFrontRegardless()
    }

    func dismiss() { disappearing = true }

    /// 디버그 스냅샷용
    var panel: NSWindow { window }

    var isGone: Bool { disappearing && alpha <= 0.01 }

    func update(dt: TimeInterval, bounds: CGRect) {
        if disappearing {
            alpha = max(0, alpha - CGFloat(dt) * 2.5)
            appearScale = max(0.2, appearScale - CGFloat(dt) * 1.2)
            if alpha <= 0.01 {
                window.orderOut(nil)
                window.close()
                onGone?()
                onGone = nil
                return
            }
        } else {
            alpha = min(1, alpha + CGFloat(dt) * 4)
            // 살짝 튀어오르며 등장
            appearScale = min(1, appearScale + CGFloat(dt) * 4.5)
        }
        if kind == .ball, velocity != .zero {
            position.x += velocity.dx * CGFloat(dt)
            position.y += velocity.dy * CGFloat(dt)
            // 바닥 마찰 (위에서 내려다보는 2D) + 화면 경계 튕김
            let friction = pow(0.25, CGFloat(dt))
            velocity.dx *= friction
            velocity.dy *= friction
            if position.x < bounds.minX || position.x > bounds.maxX { velocity.dx = -velocity.dx * 0.7; position.x = min(max(position.x, bounds.minX), bounds.maxX) }
            if position.y < bounds.minY || position.y > bounds.maxY { velocity.dy = -velocity.dy * 0.7; position.y = min(max(position.y, bounds.minY), bounds.maxY) }
            spin += velocity.dx * CGFloat(dt) * 0.08
            if hypot(velocity.dx, velocity.dy) < 4 { velocity = .zero }
        }
        sync()
        // 정지한 소품은 다시 그리지 않는다 (CPU 절약)
        if isAnimating || dirty {
            dirty = false
            view.needsDisplay = true
        }
    }

    var isAnimating: Bool { disappearing || appearScale < 1 || alpha < 1 || velocity != .zero }

    private func sync() {
        let f = view.frame.size
        let origin = CGPoint(x: position.x - f.width / 2, y: position.y - 4)
        // 그대로면 창을 옮기지 않는다 (WindowServer 왕복 절약)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    fileprivate func draw(in ctx: CGContext, bounds: CGRect) {
        ctx.setAlpha(alpha)
        let w = size.width, h = size.height
        ctx.translateBy(x: bounds.midX, y: 4)
        let s = appearScale < 1 ? appearScale + sin(appearScale * .pi) * 0.25 : 1
        ctx.scaleBy(x: s, y: s)
        let outline = CGColor(srgbRed: 0.27, green: 0.24, blue: 0.24, alpha: 1)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        switch kind {
        case .bowl:
            // 주먹밥
            for i in 0..<food {
                let x = -w * 0.22 + CGFloat(i) * w * 0.22
                let c = CGPoint(x: x, y: h * 0.5 + (i == 1 ? 4 : 0))
                let p = CGMutablePath()
                p.move(to: CGPoint(x: c.x, y: c.y + 8))
                p.addQuadCurve(to: CGPoint(x: c.x + 7.5, y: c.y - 4), control: CGPoint(x: c.x + 6.5, y: c.y + 4))
                p.addQuadCurve(to: CGPoint(x: c.x - 7.5, y: c.y - 4), control: CGPoint(x: c.x, y: c.y - 7))
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + 8), control: CGPoint(x: c.x - 6.5, y: c.y + 4))
                ctx.addPath(p)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.drawPath(using: .fillStroke)
                ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.25, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: c.x - 3.5, y: c.y - 5.5, width: 7, height: 5))
            }
            // 그릇
            let bowl = CGMutablePath()
            bowl.move(to: CGPoint(x: -w / 2, y: h * 0.48))
            bowl.addLine(to: CGPoint(x: w / 2, y: h * 0.48))
            bowl.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: w / 2, y: h * 0.1), control2: CGPoint(x: w * 0.3, y: 0))
            bowl.addCurve(to: CGPoint(x: -w / 2, y: h * 0.48), control1: CGPoint(x: -w * 0.3, y: 0), control2: CGPoint(x: -w / 2, y: h * 0.1))
            ctx.addPath(bowl)
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.62, blue: 0.62, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            for i in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: -w * 0.25 + CGFloat(i) * w * 0.22, y: h * 0.22, width: 4, height: 4))
            }
        case .ball:
            let r = w / 2
            ctx.translateBy(x: 0, y: r)
            ctx.rotate(by: spin)
            ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.75, blue: 0.98, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.55, blue: 0.85, alpha: 1))
            ctx.setLineWidth(1.2)
            for k in 0..<3 {
                let off = CGFloat(k - 1) * r * 0.45
                ctx.move(to: CGPoint(x: -r * 0.9, y: off - r * 0.2))
                ctx.addQuadCurve(to: CGPoint(x: r * 0.9, y: off + r * 0.2), control: CGPoint(x: 0, y: off + r * 0.6))
            }
            ctx.strokePath()
        case .thermometer:
            // 유리관 + 눈금 + 빨간 수은
            let tube = CGRect(x: -w * 0.16, y: h * 0.2, width: w * 0.32, height: h * 0.72)
            ctx.addPath(CGPath(roundedRect: tube, cornerWidth: w * 0.16, cornerHeight: w * 0.16, transform: nil))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
            ctx.drawPath(using: .fillStroke)
            let bulb = CGRect(x: -w * 0.3, y: 0, width: w * 0.6, height: w * 0.6)
            let red = CGColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
            ctx.addEllipse(in: bulb)
            ctx.setFillColor(red)
            ctx.drawPath(using: .fillStroke)
            let fillH = (tube.height - 6) * CGFloat(max(0.05, min(1, level)))
            ctx.setFillColor(red)
            ctx.fill(CGRect(x: -w * 0.07, y: h * 0.22, width: w * 0.14, height: fillH))
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.6))
            ctx.setLineWidth(0.8)
            for k in 1..<6 {
                let y = tube.minY + tube.height * CGFloat(k) / 6
                ctx.move(to: CGPoint(x: tube.maxX - 4, y: y))
                ctx.addLine(to: CGPoint(x: tube.maxX, y: y))
            }
            ctx.strokePath()
            drawReadout(in: ctx, at: CGPoint(x: 0, y: h + 2))
        case .scale:
            // 체중계: 판 + 둥근 눈금판 + 바늘
            let plate = CGRect(x: -w / 2, y: 0, width: w, height: h * 0.32)
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.9, blue: 0.96, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            let dial = CGRect(x: -w * 0.2, y: h * 0.06, width: w * 0.4, height: w * 0.4)
            ctx.addEllipse(in: dial)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            let c = CGPoint(x: dial.midX, y: dial.midY)
            let a = Double.pi * (0.9 - 0.8 * min(1, max(0, level)))
            ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.25, blue: 0.3, alpha: 1))
            ctx.setLineWidth(1.6)
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * dial.width * 0.42, y: c.y + CGFloat(sin(a)) * dial.width * 0.42))
            ctx.strokePath()
            drawReadout(in: ctx, at: CGPoint(x: 0, y: h * 0.62))
        case .bucket:
            // 물 양동이
            let body = CGMutablePath()
            body.move(to: CGPoint(x: -w * 0.42, y: h * 0.7))
            body.addLine(to: CGPoint(x: w * 0.42, y: h * 0.7))
            body.addLine(to: CGPoint(x: w * 0.32, y: 0))
            body.addLine(to: CGPoint(x: -w * 0.32, y: 0))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            ctx.setFillColor(CGColor(srgbRed: 0.7, green: 0.88, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: -w * 0.38, y: h * 0.6, width: w * 0.76, height: h * 0.18))
            ctx.setStrokeColor(outline)
            ctx.move(to: CGPoint(x: -w * 0.4, y: h * 0.7))
            ctx.addQuadCurve(to: CGPoint(x: w * 0.4, y: h * 0.7), control: CGPoint(x: 0, y: h * 1.25))
            ctx.strokePath()
        case .ladder:
            // 나무 사다리: 기둥 둘 + 가로대
            let wood = CGColor(srgbRed: 0.87, green: 0.64, blue: 0.4, alpha: 1)
            let rail = 3.6 * unit
            let rungGap = 11 * unit
            ctx.setFillColor(wood)
            var y = rungGap * 0.6
            while y < h - 3 * unit {
                let rung = CGRect(x: -w / 2 + rail * 0.5, y: y, width: w - rail, height: 2.8 * unit)
                ctx.addPath(CGPath(roundedRect: rung, cornerWidth: 1.2 * unit, cornerHeight: 1.2 * unit, transform: nil))
                ctx.drawPath(using: .fillStroke)
                y += rungGap
            }
            for x in [-w / 2, w / 2 - rail] {
                let r = CGRect(x: x, y: 0, width: rail, height: h)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: rail / 2, cornerHeight: rail / 2, transform: nil))
                ctx.drawPath(using: .fillStroke)
            }
        case .rope:
            // 꼬인 밧줄 + 위쪽 고리
            let rope = CGColor(srgbRed: 0.88, green: 0.76, blue: 0.54, alpha: 1)
            let rw = 4.2 * unit
            let body = CGRect(x: -rw / 2, y: 0, width: rw, height: h - 7 * unit)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: rw / 2, cornerHeight: rw / 2, transform: nil))
            ctx.setFillColor(rope)
            ctx.drawPath(using: .fillStroke)
            ctx.setStrokeColor(CGColor(srgbRed: 0.66, green: 0.52, blue: 0.32, alpha: 1))
            ctx.setLineWidth(0.9)
            var y = 3 * unit
            while y < body.maxY - 2 * unit {
                ctx.move(to: CGPoint(x: -rw / 2 + 0.6, y: y))
                ctx.addLine(to: CGPoint(x: rw / 2 - 0.6, y: y + 2.4 * unit))
                y += 4.5 * unit
            }
            ctx.strokePath()
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(1.6)
            let ring = CGRect(x: -4 * unit, y: h - 8 * unit, width: 8 * unit, height: 7 * unit)
            ctx.addEllipse(in: ring)
            ctx.setFillColor(CGColor(srgbRed: 0.7, green: 0.72, blue: 0.76, alpha: 1))
            ctx.drawPath(using: .fillStroke)
        case .umbrella:
            // 손잡이(J) + 대 + 물결 모양 천
            let canopyH = 26 * unit
            let stickTop = h - canopyH * 0.55
            ctx.setLineCap(.round)
            ctx.setLineWidth(3.2 * unit)
            ctx.move(to: CGPoint(x: 0, y: stickTop))
            ctx.addLine(to: CGPoint(x: 0, y: 5 * unit))
            ctx.addQuadCurve(to: CGPoint(x: -6 * unit, y: 4 * unit), control: CGPoint(x: -1 * unit, y: -1 * unit))
            ctx.strokePath()
            ctx.setLineWidth(1.6 * unit)
            ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.42, blue: 0.3, alpha: 1))
            ctx.move(to: CGPoint(x: 0, y: stickTop))
            ctx.addLine(to: CGPoint(x: 0, y: 5 * unit))
            ctx.addQuadCurve(to: CGPoint(x: -6 * unit, y: 4 * unit), control: CGPoint(x: -1 * unit, y: -1 * unit))
            ctx.strokePath()
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(1.6)
            let base = h - canopyH
            let canopy = CGMutablePath()
            canopy.move(to: CGPoint(x: -w / 2, y: base + 4 * unit))
            canopy.addCurve(to: CGPoint(x: w / 2, y: base + 4 * unit), control1: CGPoint(x: -w / 2, y: h + 6 * unit),
                            control2: CGPoint(x: w / 2, y: h + 6 * unit))
            // 아래 가장자리 물결 4개
            let n = 4
            for i in 0..<n {
                let x0 = w / 2 - w * CGFloat(i) / CGFloat(n)
                let x1 = x0 - w / CGFloat(n)
                canopy.addQuadCurve(to: CGPoint(x: x1, y: base + 4 * unit), control: CGPoint(x: (x0 + x1) / 2, y: base - 2 * unit))
            }
            canopy.closeSubpath()
            ctx.addPath(canopy)
            ctx.setFillColor(tint)
            ctx.drawPath(using: .fillStroke)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
            for x in [-w * 0.25, 0, w * 0.25] {
                ctx.move(to: CGPoint(x: x * 0.4, y: h + 1 * unit))
                ctx.addLine(to: CGPoint(x: x, y: base + 1 * unit))
            }
            ctx.strokePath()
            ctx.setFillColor(outline)
            ctx.fillEllipse(in: CGRect(x: -1.8 * unit, y: h + 0.5 * unit, width: 3.6 * unit, height: 3.6 * unit))
        case .trashCan:
            let body = CGMutablePath()
            body.move(to: CGPoint(x: -w * 0.4, y: h * 0.78))
            body.addLine(to: CGPoint(x: w * 0.4, y: h * 0.78))
            body.addLine(to: CGPoint(x: w * 0.32, y: 0))
            body.addLine(to: CGPoint(x: -w * 0.32, y: 0))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.84, blue: 0.9, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.62, blue: 0.7, alpha: 1))
            for x in [-w * 0.15, 0, w * 0.15] {
                ctx.move(to: CGPoint(x: x, y: h * 0.12))
                ctx.addLine(to: CGPoint(x: x * 1.15, y: h * 0.68))
            }
            ctx.strokePath()
            ctx.setStrokeColor(outline)
            let lid = CGRect(x: -w * 0.46, y: h * 0.78, width: w * 0.92, height: h * 0.12)
            ctx.addPath(CGPath(roundedRect: lid, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.68, green: 0.75, blue: 0.83, alpha: 1))
            ctx.drawPath(using: .fillStroke)
        }
    }
}

extension PropWindow {
    fileprivate func drawReadout(in ctx: CGContext, at p: CGPoint) {
        guard let readout else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                                                     .foregroundColor: NSColor(srgbRed: 0.25, green: 0.22, blue: 0.22, alpha: 1)]
        let str = NSAttributedString(string: readout, attributes: attrs)
        let sz = str.size()
        let bg = CGRect(x: p.x - sz.width / 2 - 4, y: p.y - 1, width: sz.width + 8, height: sz.height + 2)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.fillPath()
        str.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y))
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class PropView: NSView {
    weak var prop: PropWindow?
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        prop?.draw(in: ctx, bounds: bounds)
    }
}
