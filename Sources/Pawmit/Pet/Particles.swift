import AppKit

/// 펫 주변에 뜨는 작은 효과 (Zzz, 하트, 먼지, 부스러기, 느낌표 …). 펫 창 안에서만 그린다.
struct Particle {
    enum Style { case text, dust, label }
    var text: String
    var style: Style = .text
    /// 펫 발 기준 좌표 (pt, y 위쪽)
    var pos: CGPoint
    var vel: CGVector
    var gravity: CGFloat = 0
    var life: TimeInterval = 0
    var maxLife: TimeInterval
    var size: CGFloat
    var color: NSColor = .labelColor
    var weight: NSFont.Weight = .bold
    var spin: CGFloat = 0
    /// 글자 조판 결과 캐시 (매 프레임 다시 재지 않게)
    var cached: (NSAttributedString, CGSize)? = nil
}

final class ParticleSystem {
    private(set) var items: [Particle] = []

    var isEmpty: Bool { items.isEmpty }

    func add(_ p: Particle) {
        if items.count > 60 { items.removeFirst() }
        var q = p
        if q.style != .dust {
            let font = NSFont.systemFont(ofSize: q.size, weight: q.style == .label ? .semibold : q.weight)
            let color = q.style == .label ? NSColor(srgbRed: 0.2, green: 0.18, blue: 0.2, alpha: 1) : q.color
            let str = NSAttributedString(string: q.text, attributes: [.font: font, .foregroundColor: color])
            q.cached = (str, str.size())
        }
        items.append(q)
    }

    func clear() { items.removeAll() }

    /// 중력 파티클(먼지·부스러기)은 발 바로 아래(floorY)에서 멈추고 옆으로만 미끄러진다 (펫 창 아래 경계에서 잘리지 않게).
    private let floorY: CGFloat = -2

    func update(dt: TimeInterval) {
        for i in items.indices {
            items[i].life += dt
            items[i].vel.dy -= items[i].gravity * CGFloat(dt)
            items[i].pos.x += items[i].vel.dx * CGFloat(dt)
            items[i].pos.y += items[i].vel.dy * CGFloat(dt)
            if items[i].gravity > 0, items[i].pos.y < floorY {
                items[i].pos.y = floorY
                items[i].vel.dy = 0
                items[i].vel.dx *= CGFloat(exp(-8 * dt))
                items[i].spin *= CGFloat(exp(-8 * dt))
            }
        }
        items.removeAll { $0.life >= $0.maxLife }
    }

    /// `origin` = 뷰 좌표에서 펫 발 위치
    func draw(origin: CGPoint, in ctx: CGContext) {
        for p in items {
            let t = p.life / p.maxLife
            let alpha = CGFloat(t < 0.15 ? t / 0.15 : (t > 0.7 ? (1 - t) / 0.3 : 1))
            let pt = CGPoint(x: origin.x + p.pos.x, y: origin.y + p.pos.y)
            switch p.style {
            case .dust:
                ctx.setFillColor(p.color.withAlphaComponent(alpha * 0.55).cgColor)
                ctx.fillEllipse(in: CGRect(x: pt.x - p.size / 2, y: pt.y - p.size / 2, width: p.size, height: p.size))
            case .label:
                // 친구 펫 말: 흰 알약 배경 + 진한 글씨 (어떤 배경에서도 읽히게)
                guard let (s, size) = p.cached else { continue }
                let rect = CGRect(x: pt.x - size.width / 2 - 6, y: pt.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
                ctx.saveGState()
                // 펫 크기를 작게 하면 창이 좁아진다 → 말풍선이 창 양옆에 잘리지 않게 줄여서 그린다 (origin.x = 창 폭의 절반)
                let fit = min(1, (origin.x * 2 - 4) / rect.width)
                if fit < 1 {
                    ctx.translateBy(x: pt.x, y: pt.y)
                    ctx.scaleBy(x: fit, y: fit)
                    ctx.translateBy(x: -pt.x, y: -pt.y)
                }
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.92 * alpha))
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18 * alpha))
                ctx.setLineWidth(1)
                ctx.drawPath(using: .fillStroke)
                ctx.setAlpha(alpha)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                s.draw(at: NSPoint(x: pt.x - size.width / 2, y: pt.y - size.height / 2))
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
            case .text:
                guard let (s, size) = p.cached else { continue }
                ctx.saveGState()
                ctx.translateBy(x: pt.x, y: pt.y)
                if p.spin != 0 { ctx.rotate(by: p.spin * CGFloat(p.life)) }
                ctx.setAlpha(alpha)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                s.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
            }
        }
    }
}

/// 자주 쓰는 효과 모음
enum FX {
    static func zzz(at head: CGPoint) -> Particle {
        Particle(text: ["z", "Z", "z"].randomElement()!, pos: CGPoint(x: head.x + 8, y: head.y - 4),
                 vel: CGVector(dx: .random(in: 8...16), dy: .random(in: 14...22)), maxLife: 2.4,
                 size: .random(in: 11...15), color: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.85, alpha: 1), weight: .heavy)
    }

    static func heart(at head: CGPoint) -> Particle {
        Particle(text: "♥", pos: CGPoint(x: head.x + .random(in: -14...14), y: head.y - 2),
                 vel: CGVector(dx: .random(in: -10...10), dy: .random(in: 22...34)), maxLife: 1.6,
                 size: .random(in: 12...17), color: NSColor(srgbRed: 0.98, green: 0.42, blue: 0.56, alpha: 1), weight: .black)
    }

    static func note(at head: CGPoint) -> Particle {
        Particle(text: ["♪", "♫"].randomElement()!, pos: CGPoint(x: head.x + .random(in: -12...12), y: head.y),
                 vel: CGVector(dx: .random(in: -12...12), dy: .random(in: 18...28)), maxLife: 1.8,
                 size: .random(in: 12...16), color: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.95, alpha: 1))
    }

    static func exclaim(at head: CGPoint) -> Particle {
        Particle(text: "!", pos: CGPoint(x: head.x + 16, y: head.y + 2), vel: CGVector(dx: 0, dy: 10), maxLife: 1.4,
                 size: 22, color: NSColor(srgbRed: 0.98, green: 0.33, blue: 0.33, alpha: 1), weight: .black)
    }

    static func question(at head: CGPoint) -> Particle {
        Particle(text: "?", pos: CGPoint(x: head.x + 16, y: head.y + 2), vel: CGVector(dx: 0, dy: 8), maxLife: 1.6,
                 size: 20, color: NSColor(srgbRed: 0.95, green: 0.6, blue: 0.2, alpha: 1), weight: .black)
    }

    static func dots(at head: CGPoint, index: Int) -> Particle {
        Particle(text: "•", pos: CGPoint(x: head.x + 10 + CGFloat(index) * 7, y: head.y + 4), vel: CGVector(dx: 0, dy: 4), maxLife: 1.2,
                 size: 12, color: .secondaryLabelColor)
    }

    static func dust(at foot: CGPoint, facing: CGFloat) -> Particle {
        Particle(text: "", style: .dust, pos: CGPoint(x: foot.x + .random(in: -4...4), y: foot.y + 2),
                 vel: CGVector(dx: -facing * .random(in: 20...55), dy: .random(in: 15...45)), gravity: 80, maxLife: 0.8,
                 size: .random(in: 3...6), color: NSColor(srgbRed: 0.6, green: 0.5, blue: 0.4, alpha: 1))
    }

    static func debris(at foot: CGPoint, facing: CGFloat) -> Particle {
        Particle(text: ["📄", "🦴", "🧦", "🐟", "🍌", "🧻", "🥫"].randomElement()!, pos: CGPoint(x: foot.x, y: foot.y + 6),
                 vel: CGVector(dx: -facing * .random(in: 25...60), dy: .random(in: 55...85)), gravity: 150, maxLife: 1.2,
                 size: .random(in: 10...13), spin: .random(in: -4...4))
    }

    static func crumb(at mouth: CGPoint) -> Particle {
        Particle(text: "", style: .dust, pos: mouth, vel: CGVector(dx: .random(in: -18...18), dy: .random(in: 0...16)), gravity: 90,
                 maxLife: 0.7, size: .random(in: 2...3.5), color: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.86, alpha: 1))
    }

    static func sparkle(at head: CGPoint) -> Particle {
        Particle(text: "✦", pos: CGPoint(x: head.x + .random(in: -20...20), y: head.y + .random(in: -10...6)),
                 vel: CGVector(dx: 0, dy: .random(in: 6...14)), maxLife: 0.9, size: .random(in: 9...13),
                 color: NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1), spin: 2)
    }
}
