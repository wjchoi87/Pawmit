import CoreGraphics
import Foundation
import PawmitCore

/// 치비 펫 렌더러: 큰 찹쌀떡 머리 + 작은 몸 + 짧은 팔다리로 두 발로 아장아장 걷는 화풍.
/// 포즈(뼈대)와 몸·머리·팔다리 배치는 여기서, 귀·꼬리·무늬는 ChibiParts의 부위 컴포넌트가 그리고,
/// 선·그림자 같은 공통 그리기는 Ink(InkKit)를 쓴다. 종족 정의는 pet.json(ChibiSpecies).
final class ChibiRenderer: LayeredPetRenderer {
    let species: ChibiSpecies
    private let eyeColor = CGColor(srgbRed: 0.16, green: 0.15, blue: 0.16, alpha: 1)
    private let tearColor = CGColor(srgbRed: 0.55, green: 0.80, blue: 0.98, alpha: 0.95)
    private let mouthColor = CGColor(srgbRed: 0.93, green: 0.45, blue: 0.52, alpha: 1)

    let earPart: ChibiEarPart
    let tailPart: ChibiTailPart
    let patternPart: ChibiPatternPart
    /// 펫마다 고정된 손그림 모양 seed
    private let shapeSeed: UInt64

    init(species: ChibiSpecies) {
        self.species = species
        earPart = ChibiParts.ear(species.ears)
        tailPart = ChibiParts.tail(species.tail)
        patternPart = ChibiParts.pattern(species.pattern)
        // 커스텀 펫은 id가 모두 "custom"이라 모양·색을 전부 키에 넣는다 (매 프레임 만들지 않게 한 번만)
        cacheID = "chibi:\(species.id):\(species.ears):\(species.tail):\(species.pattern):"
            + "\(species.body.hex)\(species.accent.hex)\(species.innerEar.hex)\(species.belly?.hex ?? "-")\(species.outline.hex)"
            + ":\(Int(species.headRX * 10)):\(Int(species.headRY * 10))"
        shapeSeed = Ink.seed(species.id + species.ears + species.tail + species.pattern)
    }

    // MARK: - Rig

    enum Eyes { case open, closed, happy, wide, squeeze, teary, half, heart, star, spiral, dot, wink }
    enum Mouth { case smile, open, chomp, o, wobbly, flat, tongue, grin, cat, kiss }
    enum Hold { case onigiri, crayon(CGColor), mop }

    struct Arm {
        var shoulder: CGPoint
        /// 0 = 아래로, π/2 = 바깥쪽 수평, π = 위로, π보다 크면 안쪽 위
        var angle: CGFloat
        var length: CGFloat = 5.6
        var right: Bool
        /// 내린 팔일수록(cos 각도) 뿌리를 최대 2.4만큼 몸 쪽 아래로 내려 어깨가 솟아 보이지 않게 한다.
        var pivot: CGPoint { CGPoint(x: shoulder.x, y: shoulder.y - 2.4 * max(0, cos(angle))) }
        /// 손은 뼈대 길이의 32%만 뻗는다 (내린 팔의 손끝이 배 높이쯤).
        var hand: CGPoint {
            let s = right ? sin(angle) : -sin(angle)
            let l = length * 0.32
            let p = pivot
            return CGPoint(x: p.x + s * l, y: p.y - cos(angle) * l)
        }
    }

    struct Rig {
        var root = CGAffineTransform.identity
        var feet: [CGPoint] = [CGPoint(x: -5.8, y: 3.4), CGPoint(x: 5.8, y: 3.4)]
        var footRX: CGFloat = 4.8
        var footRY: CGFloat = 3.9
        var body = CGPoint(x: 0, y: 13)
        var bodyRX: CGFloat = 12
        var bodyRY: CGFloat = 10
        var head = CGPoint(x: 0, y: 30.5)
        var headScaleY: CGFloat = 1
        var headTilt: CGFloat = 0
        var arms: [Arm] = []
        var earPerk: CGFloat = 0
        var earFlop: CGFloat = 0
        var tailSwing: CGFloat = 0
        var eyes: Eyes = .open
        var mouth: Mouth = .smile
        var faceShift: CGFloat = 2.5
        var hold: Hold? = nil
        var sweat = false
        var noseBubble: CGFloat = 0
        /// 머리 가로 배율 (통통)
        var headScaleX: CGFloat = 1
        /// 더위 0...1 (볼 빨개짐)
        var heat: CGFloat = 0
    }

    private func makeRig(_ p: PetPose) -> Rig {
        var r = Rig()
        let t = p.clock
        let at = p.animTime
        // 반복 루프를 맞춰 몸통 프레임을 캐시할 수 있게: 가만히·앉기 3초, 잠 4초, 걷기는 걸음 위상만 쓴다
        let omega = 2 * Double.pi / FrameQuantizer.idlePeriod
        let omegaSleep = 2 * Double.pi / FrameQuantizer.sleepPeriod
        let walking = p.anim == .walk || p.anim == .run
        let breath = walking ? 0 : CGFloat(sin(t * (p.anim == .sleep ? omegaSleep : omega))) * 0.022
        let shoulderY: CGFloat = 16.5
        func arms(_ left: CGFloat, _ right: CGFloat, length: CGFloat = 5.6) -> [Arm] {
            [Arm(shoulder: CGPoint(x: -9.8, y: shoulderY), angle: left, length: length, right: false),
             Arm(shoulder: CGPoint(x: 9.8, y: shoulderY), angle: right, length: length, right: true)]
        }
        r.arms = arms(0.32, 0.32)
        r.tailSwing = walking ? CGFloat(sin(p.walkPhase)) * 0.25 : CGFloat(sin(t * omega)) * 0.18
        r.bodyRY *= 1 + breath
        r.head.y += breath * 9

        switch p.anim {
        case .idle:
            r.root = CGAffineTransform(rotationAngle: CGFloat(sin(t * omega)) * 0.018)

        case .walk, .run, .draw:
            let running = p.anim == .run
            let ph = p.walkPhase
            let s = sin(ph)
            let bob = abs(s) * (running ? 2.3 : 1.5)
            let lean: CGFloat = running ? -0.13 : (p.anim == .draw ? -0.08 : 0)
            r.root = CGAffineTransform(rotationAngle: lean + s * (running ? 0.05 : 0.075))
            r.body.y += bob
            r.head.y += bob
            let lift: CGFloat = running ? 3.6 : 2.6
            r.feet[0] = CGPoint(x: -5.8 - s * 1.4, y: 3.4 + max(0, s) * lift)
            r.feet[1] = CGPoint(x: 5.8 - s * 1.4, y: 3.4 + max(0, -s) * lift)
            if running {
                r.arms = arms(0.95 + s * 0.55, 0.95 - s * 0.55)
                r.mouth = .open
                r.sweat = true
            } else {
                r.arms = arms(0.35 + s * 0.45, 0.35 - s * 0.45)
            }
            r.arms[0].shoulder.y += bob
            r.arms[1].shoulder.y += bob
            if p.anim == .draw {
                r.arms = arms(3.75, 1.25)
                r.arms[0].shoulder.y += bob
                r.arms[1].shoulder.y += bob
                if p.mop {
                    r.arms = arms(1.05 + s * 0.25, 0.95 - s * 0.25)
                    r.arms[0].shoulder.y += bob
                    r.arms[1].shoulder.y += bob
                    r.hold = .mop
                    r.eyes = .squeeze
                    r.mouth = .open
                    r.sweat = true
                } else {
                    r.hold = .crayon(p.crayon ?? CGColor(srgbRed: 0.95, green: 0.35, blue: 0.45, alpha: 1))
                    r.eyes = .open
                    r.mouth = .tongue
                }
            }

        case .sit, .think, .groom, .eat, .sad:
            r.feet = [CGPoint(x: -5.5, y: 3.3), CGPoint(x: 6.5, y: 3.3)]
            r.footRX = 5
            r.footRY = 3.6
            r.body.y = 11
            r.bodyRX = 12.8
            r.head.y = 28.5 + breath * 9
            r.arms = arms(0.15, 0.15)
            for i in r.arms.indices { r.arms[i].shoulder.y = 14.5 }
            switch p.anim {
            case .think:
                r.arms = arms(0.2, 3.3, length: 6.0)
                for i in r.arms.indices { r.arms[i].shoulder.y = 14.5 }
                r.headTilt = 0.1
                r.mouth = .flat
            case .groom:
                let a = CGFloat(sin(at * 9)) * 0.25
                r.arms = arms(3.6 + a, 3.6 - a, length: 7.2)
                for i in r.arms.indices { r.arms[i].shoulder.y = 14.5 }
                r.eyes = .closed
                r.mouth = .smile
                r.headTilt = CGFloat(sin(at * 4.5)) * 0.06
            case .eat:
                let chomp = abs(sin(at * 8.5))
                r.arms = arms(3.75, 3.75, length: 5.6)
                for i in r.arms.indices { r.arms[i].shoulder.y = 15 }
                r.hold = .onigiri
                r.eyes = .happy
                r.mouth = chomp > 0.6 ? .chomp : .smile
                r.head.y += chomp * 0.9
            case .sad:
                let wipe = CGFloat(sin(at * 6)) * 0.12
                r.arms = arms(3.55 + wipe, 3.55 - wipe, length: 7.4)
                for i in r.arms.indices { r.arms[i].shoulder.y = 14.5 }
                r.eyes = .teary
                r.mouth = .wobbly
                r.earFlop = 0.5
                r.head.y -= 1
            default:
                break
            }

        case .sleep:
            // 앉은 채로 꾸벅꾸벅 — 고개를 떨구고 콧방울
            r.feet = [CGPoint(x: -5.5, y: 3.3), CGPoint(x: 6.5, y: 3.3)]
            r.footRX = 5
            r.footRY = 3.6
            r.body.y = 10.5
            r.bodyRX = 13.2
            r.bodyRY = 9.6 * (1 + breath * 1.8)
            r.head.y = 25.5 + CGFloat(sin(t * omegaSleep)) * 0.7
            r.headTilt = -0.16
            r.arms = arms(0.05, 0.05, length: 5.6)
            for i in r.arms.indices { r.arms[i].shoulder.y = 13.5 }
            r.eyes = .closed
            r.mouth = .o
            r.earFlop = 0.25
            r.noseBubble = 0.5 + 0.5 * CGFloat(sin(t * omegaSleep))
            r.tailSwing = 0

        case .dig:
            let a = CGFloat(sin(at * 22))
            r.root = CGAffineTransform(rotationAngle: -0.32)
            r.arms = arms(1.05 + a * 0.55, 1.05 - a * 0.55, length: 6.8)
            r.eyes = .squeeze
            r.mouth = .open
            r.sweat = true
            r.tailSwing = CGFloat(sin(t * 9)) * 0.35

        case .pounce:
            if p.hop > 1 {
                r.arms = arms(2.4, 2.4)
                r.feet = [CGPoint(x: -6.5, y: 5), CGPoint(x: 6.5, y: 5)]
                r.eyes = .wide
                r.mouth = .open
            } else {
                r.arms = arms(0.9, 0.9)
                r.eyes = .squeeze
                r.mouth = .flat
                r.root = CGAffineTransform(rotationAngle: -0.1 + CGFloat(sin(at * 18)) * 0.03)
            }

        case .alert:
            let wob = CGFloat(sin(at * 14)) * 0.08
            r.arms = arms(2.65 + wob, 2.65 - wob)
            r.eyes = .wide
            r.mouth = .o
            r.earPerk = 0.25

        case .happy:
            let wob = CGFloat(sin(at * 12)) * 0.25
            r.arms = arms(2.7 + wob, 2.7 - wob)
            r.eyes = .happy
            r.mouth = .open
            r.earPerk = 0.15
            r.tailSwing = CGFloat(sin(t * 10)) * 0.4

        case .wave:
            r.arms = arms(0.3, 2.75 + CGFloat(sin(at * 12)) * 0.4)
            r.eyes = .happy
            r.mouth = .open

        case .play:
            r.arms = arms(0.4, 1.55 + CGFloat(sin(at * 10)) * 0.65)
            r.eyes = .wide
            r.mouth = .open
            r.root = CGAffineTransform(rotationAngle: CGFloat(sin(at * 5)) * 0.06)

        case .drag, .fall:
            let flail = p.anim == .fall
            let sw = CGFloat(sin(t * (flail ? 15 : 5)))
            r.head = CGPoint(x: 0, y: 41)
            r.body = CGPoint(x: 0, y: 22)
            r.bodyRY = 11
            r.bodyRX = 11
            r.feet = [CGPoint(x: -5 + sw * 1.5, y: 9), CGPoint(x: 5 - sw * 1.5, y: 9)]
            r.arms = flail ? arms(2.3 + sw * 0.5, 2.3 - sw * 0.5) : arms(0.12 + sw * 0.15, 0.12 - sw * 0.15)
            for i in r.arms.indices { r.arms[i].shoulder.y = 26 }
            r.eyes = .wide
            r.mouth = .o
            r.tailSwing = sw * 0.5
            r.faceShift = 0
        }

        if let m = p.motion { applyMotion(m, t: p.motionTime, to: &r) }
        applySystem(heat: p.heat, chubby: p.chubby, t: p.clock, hasMotion: p.motion != nil, anim: p.anim, to: &r)
        if p.blink > 0.5, r.eyes == .open || r.eyes == .wide || r.eyes == .dot { r.eyes = .closed }
        if p.stretch != 1 {
            r.body.y *= p.stretch
            r.head.y *= p.stretch
            r.bodyRY *= p.stretch
            for i in r.arms.indices { r.arms[i].shoulder.y *= p.stretch }
        }
        return r
    }

    /// 시스템 상태: 디스크 → 통통, CPU → 더위 (볼 빨개짐·땀·헥헥·부채질)
    private func applySystem(heat: CGFloat, chubby: CGFloat, t: TimeInterval, hasMotion: Bool, anim: PetAnim, to r: inout Rig) {
        if chubby > 0.01 {
            r.bodyRX *= 1 + 0.5 * chubby
            r.bodyRY *= 1 + 0.14 * chubby
            r.headScaleX = 1 + 0.12 * chubby
            for i in r.feet.indices { r.feet[i].x *= 1 + 0.35 * chubby }
            for i in r.arms.indices { r.arms[i].shoulder.x *= 1 + 0.42 * chubby }
        }
        guard heat > 0.01 else { return }
        r.heat = heat
        if heat > 0.35 { r.sweat = true }
        if heat > 0.6, r.mouth == .smile || r.mouth == .flat { r.mouth = .tongue }
        if heat > 0.85, r.eyes == .open { r.eyes = .half }
        // 가만히 있을 땐 한 손으로 부채질
        if heat > 0.65, !hasMotion, anim == .idle || anim == .sit, r.arms.count == 2 {
            r.arms[1].angle = 3.35 + 0.28 * CGFloat(sin(t * 11))
        }
    }

    /// 행동 조합기의 모션 층을 기본 포즈 위에 얹는다
    private func applyMotion(_ m: MotionSpec, t: TimeInterval, to r: inout Rig) {
        if r.arms.count == 2 {
            if let la = m.leftArm { r.arms[0].angle = CGFloat(la.value(at: t)) }
            if let ra = m.rightArm { r.arms[1].angle = CGFloat(ra.value(at: t)) }
        }
        if let h = m.headTilt { r.headTilt += CGFloat(h.value(at: t)) }
        if let sq = m.squash {
            let k = CGFloat(sq.value(at: t))
            r.body.y *= k
            r.head.y *= k
            r.bodyRY *= k
            for i in r.arms.indices { r.arms[i].shoulder.y *= k }
        }
        var extra = CGAffineTransform.identity
        if let l = m.lean { extra = extra.rotated(by: CGFloat(l.value(at: t))) }
        if let b = m.bounce {
            let v = b.base + abs(b.amp * sin(2 * .pi * b.freq * t + b.phase))
            extra = extra.concatenating(CGAffineTransform(translationX: 0, y: CGFloat(v)))
        }
        if let sw = m.sway { extra = extra.concatenating(CGAffineTransform(translationX: CGFloat(sw.value(at: t)), y: 0)) }
        r.root = r.root.concatenating(extra)
        if let e = m.eyes {
            switch e {
            case .open: r.eyes = .open
            case .closed: r.eyes = .closed
            case .happy: r.eyes = .happy
            case .wide: r.eyes = .wide
            case .squeeze: r.eyes = .squeeze
            case .teary: r.eyes = .teary
            case .half: r.eyes = .half
            case .heart: r.eyes = .heart
            case .star: r.eyes = .star
            case .spiral: r.eyes = .spiral
            case .dot: r.eyes = .dot
            case .wink: r.eyes = .wink
            }
        }
        if let mo = m.mouth {
            switch mo {
            case .smile: r.mouth = .smile
            case .open: r.mouth = .open
            case .chomp: r.mouth = .chomp
            case .o: r.mouth = .o
            case .wobbly: r.mouth = .wobbly
            case .flat: r.mouth = .flat
            case .tongue: r.mouth = .tongue
            case .grin: r.mouth = .grin
            case .cat: r.mouth = .cat
            case .kiss: r.mouth = .kiss
            }
        }
        if let ep = m.earPerk { r.earPerk = CGFloat(ep) }
    }

    // MARK: - PetRenderer

    func draw(_ pose: PetPose, in ctx: CGContext) {
        let (rect, alpha) = shadow(pose)
        ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
        ctx.fillEllipse(in: rect.offsetBy(dx: 0, dy: -pose.hop))
        renderBody(pose, in: ctx, face: true)
    }

    // MARK: - 레이어·캐시용

    let cacheID: String
    /// 기본 6종 실측(framecache bounds) 몸통 x -28...29, y -4...66 / 얼굴 x -16...28, y 16...48 에 여유를 두고,
    /// 머리가 큰 커스텀 펫은 그만큼 넓힌다
    var cacheBounds: CGRect {
        let dx = max(0, species.headRX - 17.5) * 1.4, dy = max(0, species.headRY - 14.5) * 2.2
        return CGRect(x: -32 - dx, y: -6, width: 64 + dx * 2, height: 78 + dy)
    }
    var faceBounds: CGRect {
        let dx = max(0, species.headRX - 17.5) * 1.4, dy = max(0, species.headRY - 14.5) * 2.2
        return CGRect(x: -32 - dx, y: 8, width: 66 + dx * 2, height: 50 + dy)
    }

    func shadow(_ pose: PetPose) -> (CGRect, CGFloat) {
        let k = max(0.45, 1 - pose.hop / 60)
        let w: CGFloat = pose.anim == .sleep ? 54 : 34
        return (CGRect(x: -w / 2 * k, y: -2.5, width: w * k, height: 6 * k), 0.15 * k)
    }

    func renderFace(_ pose: PetPose, in ctx: CGContext) {
        let r = makeRig(pose)
        ctx.saveGState()
        ctx.concatenate(r.root)
        drawFace(r, pose: pose, in: ctx)
        if r.sweat { drawSweat(r, t: pose.clock, in: ctx) }
        ctx.restoreGState()
    }

    func faceKey(_ pose: PetPose) -> String {
        let r = makeRig(pose)
        let lx = Int((pose.look.dx * 4).rounded()), ly = Int((pose.look.dy * 4).rounded())
        let anim = r.eyes == .spiral || r.eyes == .teary || r.sweat ? Int(pose.clock * 8) : 0
        return "\(r.eyes)|\(r.mouth)|\(lx),\(ly)|\(Int(r.heat * 10))|\(r.sweat)|\(r.noseBubble > 0 ? Int(r.noseBubble * 10) : -1)|\(anim)"
    }

    /// 팔·발 외곽선을 몸 실루엣과 한 번에 칠해 한 덩어리로 잇고, 몸 위에 겹친 부분만 얇은 주름선으로 그린다.
    /// 머리·몸은 펫마다 고정된 손그림 덩어리, 외곽선은 아래쪽이 굵고, 반달 그림자와 머리 밑 그늘을 넣는다.
    func renderBody(_ pose: PetPose, in ctx: CGContext, face: Bool) {
        let r = makeRig(pose)
        let c = partContext(r)
        ctx.saveGState()
        ctx.concatenate(r.root)

        let body = bodyPath(r)
        let feet = r.feet.map { footPath($0, r) }
        let arms = r.arms.map(armPath)
        var shapes: [Ink.Shape] = []
        if let tail = tailPart.shape(c) { shapes.append(tail) }
        for f in feet { shapes.append(Ink.Shape(path: f, fill: species.body)) }
        let belly = species.belly
        let bodyRect = CGRect(x: r.body.x - r.bodyRX, y: r.body.y - r.bodyRY, width: r.bodyRX * 2, height: r.bodyRY * 2)
        shapes.append(Ink.Shape(path: body, fill: species.body, detail: { ctx in
            guard let belly else { return }
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.setFillColor(belly)
            ctx.fillEllipse(in: CGRect(x: bodyRect.midX - bodyRect.width * 0.32, y: bodyRect.minY + 0.5,
                                       width: bodyRect.width * 0.64, height: bodyRect.height * 0.74))
            ctx.restoreGState()
        }))
        shapes += earPart.shapes(c)
        shapes.append(Ink.Shape(path: c.headPath, fill: species.body))
        // 팔은 외곽선만 실루엣과 함께 칠하고, 채움은 얼굴 뒤에 (얼굴을 가리는 포즈가 있어서)
        Ink.sticker(shapes, outline: species.outline, width: outlineWidth, extraOutlines: arms, in: ctx)

        // 발이 몸에 묻힌 경계, 몸·머리 그늘
        let crease = Ink.tint(species.outline, 0.85)
        for f in feet { Ink.crease(f, inside: body, color: crease, width: 1.25, in: ctx) }
        Ink.shade(body, offset: CGVector(dx: 1.3, dy: -2.1), color: Ink.tint(species.outline, 0.09), in: ctx)
        Ink.occlusion(body, ellipse: CGRect(x: r.head.x - species.headRX * 0.55, y: c.headRect.minY - 1.8,
                                            width: species.headRX * 1.1, height: 4),
                      color: Ink.tint(species.outline, 0.06), in: ctx)
        patternPart.draw(c, in: ctx)
        Ink.shade(c.headPath, offset: CGVector(dx: 1.4, dy: -2.2), color: Ink.tint(species.outline, 0.06), in: ctx)

        if face { drawFace(r, pose: pose, in: ctx) }
        if let hold = r.hold, case .crayon = hold { drawHold(hold, r: r, in: ctx) }
        if let hold = r.hold, case .mop = hold { drawHold(hold, r: r, in: ctx) }
        // 팔: 몸·머리 위에 겹친 부분은 얇은 주름선, 바깥은 이미 칠한 굵은 실루엣 선
        let torso = CGMutablePath()
        torso.addPath(body)
        torso.addPath(c.headPath)
        for (arm, bone) in zip(arms, r.arms) {
            ctx.addPath(arm)
            ctx.setFillColor(species.body)
            ctx.fillPath()
            // 어깨 위로 솟는 둥근 끝(뿌리 쪽)에는 선을 긋지 않아 몸에서 자라난 것처럼. 팔 안쪽 선과 손끝 선은 남긴다
            let h = bone.hand, p = bone.pivot
            let len = max(0.001, hypot(h.x - p.x, h.y - p.y))
            let cap = CGPoint(x: p.x - (h.x - p.x) / len * 2.0, y: p.y - (h.y - p.y) / len * 2.0)
            Ink.crease(arm, inside: torso, excluding: [(cap, 3.4)], color: crease, width: 1.3, in: ctx)
        }
        if let hold = r.hold, case .onigiri = hold { drawHold(hold, r: r, in: ctx) }
        if face, r.sweat { drawSweat(r, t: pose.clock, in: ctx) }
        ctx.restoreGState()
    }

    private let outlineWidth: CGFloat = 2.45

    func silhouette(_ pose: PetPose) -> CGPath {
        let r = makeRig(pose)
        let path = CGMutablePath()
        var root = r.root
        path.addEllipse(in: CGRect(x: r.head.x - species.headRX - 3, y: r.head.y - species.headRY - 3,
                                   width: (species.headRX + 3) * 2, height: (species.headRY + 3) * 2), transform: root)
        path.addEllipse(in: CGRect(x: r.body.x - r.bodyRX - 2, y: 0, width: (r.bodyRX + 2) * 2, height: r.body.y + r.bodyRY), transform: root)
        _ = withUnsafeMutablePointer(to: &root) { $0 }
        return path
    }

    func headTop(_ pose: PetPose) -> CGPoint {
        let r = makeRig(pose)
        let earExtra = earPart.extraTop
        return CGPoint(x: r.head.x, y: r.head.y + species.headRY + earExtra).applying(r.root)
    }

    func mouthPoint(_ pose: PetPose) -> CGPoint {
        let r = makeRig(pose)
        return CGPoint(x: r.head.x + r.faceShift, y: r.head.y - 5).applying(r.root)
    }

    // MARK: - Shapes

    private func headRect(_ r: Rig) -> CGRect {
        let ry = species.headRY * r.headScaleY
        let rx = species.headRX * r.headScaleX
        return CGRect(x: r.head.x - rx, y: r.head.y - ry, width: rx * 2, height: ry * 2)
    }

    /// 머리: 무늬가 모양을 정하면 그 모양, 아니면 볼이 통통한 찹쌀떡 덩어리
    private func headPath(_ r: Rig) -> CGPath {
        let rect = headRect(r)
        let tf = CGAffineTransform(translationX: r.head.x, y: r.head.y).rotated(by: r.headTilt).translatedBy(x: -r.head.x, y: -r.head.y)
        if let custom = patternPart.headOutline(rect) {
            var t = tf
            return custom.copy(using: &t) ?? custom
        }
        return Ink.blob(rect, seed: shapeSeed &+ 1, wobble: 0.01, squareness: 0.55, bottomBias: 0.05, transform: tf)
    }

    /// 몸: 아래가 살짝 넓은 서양배 덩어리
    private func bodyPath(_ r: Rig) -> CGPath {
        let rect = CGRect(x: r.body.x - r.bodyRX, y: r.body.y - r.bodyRY, width: r.bodyRX * 2, height: r.bodyRY * 2)
        return Ink.blob(rect, seed: shapeSeed &+ 2, wobble: 0.015, squareness: 0.35, bottomBias: 0.1)
    }

    private func footPath(_ f: CGPoint, _ r: Rig) -> CGPath {
        Ink.bean(center: f, rx: r.footRX, ry: r.footRY)
    }

    /// 팔: 어깨 쪽은 몸 안으로 파묻히고 손끝이 둥근 벙어리장갑
    private func armPath(_ arm: Arm) -> CGPath {
        let h = arm.hand
        let p = arm.pivot
        let dx = h.x - p.x, dy = h.y - p.y
        let len = max(0.001, hypot(dx, dy))
        // 뿌리를 짧게 묻어 어깨 쪽 둥근 끝이 덜 솟게
        let root = CGPoint(x: p.x - dx / len * 1.2, y: p.y - dy / len * 1.2)
        return Ink.limb(from: root, to: h, rootWidth: 6.3, tipWidth: 5.2, bend: arm.right ? 0.4 : -0.4)
    }

    private func partContext(_ r: Rig) -> ChibiPartContext {
        ChibiPartContext(rig: r, species: species, headPath: headPath(r), headRect: headRect(r),
                         earFill: patternPart.tintsEars ? species.accent : species.body, seed: shapeSeed)
    }

    // MARK: - Details

    private func drawFace(_ r: Rig, pose: PetPose, in ctx: CGContext) {
        let fx = r.head.x + r.faceShift
        let ey = r.head.y - 0.8
        let eyeXs: [CGFloat] = [fx - 6.9, fx + 6.9]
        let look = CGVector(dx: max(-1, min(1, pose.look.dx)), dy: max(-1, min(1, pose.look.dy)))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 볼터치 + 빗금
        if r.heat > 0.05 {
            // 얼굴 전체가 살짝 달아오름
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 0.16 * r.heat))
            ctx.fillEllipse(in: CGRect(x: fx - 15, y: r.head.y - 9, width: 30, height: 12))
        }
        for (i, x) in [fx - 11.6, fx + 11.6].enumerated() {
            let grow = 1 + 0.45 * r.heat
            let rect = CGRect(x: x - 3.7 * grow, y: r.head.y - 6.4 - r.heat, width: 7.4 * grow, height: 4.2 * grow)
            ctx.setFillColor(r.heat > 0.05 ? mix(species.blush, CGColor(srgbRed: 0.95, green: 0.22, blue: 0.25, alpha: 1), r.heat) : species.blush)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.42, blue: 0.52, alpha: 0.55))
            ctx.setLineWidth(0.7)
            for k in 0..<3 {
                let bx = rect.minX + 1.8 + CGFloat(k) * 1.9 + (i == 0 ? 0 : 0.2)
                ctx.move(to: CGPoint(x: bx, y: rect.minY + 1))
                ctx.addLine(to: CGPoint(x: bx + 1.3, y: rect.maxY - 0.8))
            }
            ctx.strokePath()
        }

        ctx.setFillColor(eyeColor)
        ctx.setStrokeColor(eyeColor)
        switch r.eyes {
        case .open, .wide, .teary:
            let rx: CGFloat = r.eyes == .wide ? 2.4 : 2.0
            let ry: CGFloat = r.eyes == .wide ? 3.2 : 2.8
            for x in eyeXs {
                let c = CGPoint(x: x + look.dx * 0.8, y: ey + look.dy * 0.8)
                ctx.setFillColor(eyeColor)
                ctx.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: c.x - rx * 0.55, y: c.y + ry * 0.12, width: 1.5, height: 1.5))
                if r.eyes != .open {
                    ctx.fillEllipse(in: CGRect(x: c.x + rx * 0.2, y: c.y - ry * 0.55, width: 0.9, height: 0.9))
                }
            }
            if r.eyes == .teary {
                // 눈물 고임 + 흘러내림
                for x in eyeXs {
                    ctx.setFillColor(tearColor)
                    ctx.fillEllipse(in: CGRect(x: x - 2.9, y: ey - 3.6, width: 5.8, height: 2.2))
                    let drop = CGFloat(fmod(pose.clock * 0.9, 1))
                    let dy = ey - 4 - drop * 7
                    ctx.move(to: CGPoint(x: x, y: dy + 2.4))
                    ctx.addQuadCurve(to: CGPoint(x: x, y: dy - 1.2), control: CGPoint(x: x + 1.9, y: dy - 0.6))
                    ctx.addQuadCurve(to: CGPoint(x: x, y: dy + 2.4), control: CGPoint(x: x - 1.9, y: dy - 0.6))
                    ctx.fillPath()
                }
            }
        case .closed:
            ctx.setLineWidth(1.5)
            for x in eyeXs {
                ctx.move(to: CGPoint(x: x - 2.3, y: ey + 0.3))
                ctx.addQuadCurve(to: CGPoint(x: x + 2.3, y: ey + 0.3), control: CGPoint(x: x, y: ey - 2))
            }
            ctx.strokePath()
        case .happy:
            ctx.setLineWidth(1.6)
            for x in eyeXs {
                ctx.move(to: CGPoint(x: x - 2.4, y: ey - 1))
                ctx.addQuadCurve(to: CGPoint(x: x + 2.4, y: ey - 1), control: CGPoint(x: x, y: ey + 2.6))
            }
            ctx.strokePath()
        case .squeeze:
            // > <
            ctx.setLineWidth(1.5)
            let s: CGFloat = 2.2
            ctx.move(to: CGPoint(x: eyeXs[0] - s, y: ey + s))
            ctx.addLine(to: CGPoint(x: eyeXs[0] + s, y: ey))
            ctx.addLine(to: CGPoint(x: eyeXs[0] - s, y: ey - s))
            ctx.move(to: CGPoint(x: eyeXs[1] + s, y: ey + s))
            ctx.addLine(to: CGPoint(x: eyeXs[1] - s, y: ey))
            ctx.addLine(to: CGPoint(x: eyeXs[1] + s, y: ey - s))
            ctx.strokePath()
        case .half:
            ctx.setLineWidth(1.5)
            for x in eyeXs {
                ctx.move(to: CGPoint(x: x - 2.3, y: ey))
                ctx.addLine(to: CGPoint(x: x + 2.3, y: ey))
            }
            ctx.strokePath()
        case .heart:
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.3, blue: 0.45, alpha: 1))
            for x in eyeXs {
                let c = CGPoint(x: x, y: ey + 0.4)
                let h = CGMutablePath()
                h.move(to: CGPoint(x: c.x, y: c.y - 2.6))
                h.addCurve(to: CGPoint(x: c.x, y: c.y + 1.4), control1: CGPoint(x: c.x - 3.6, y: c.y - 0.6), control2: CGPoint(x: c.x - 2.2, y: c.y + 3.2))
                h.addCurve(to: CGPoint(x: c.x, y: c.y - 2.6), control1: CGPoint(x: c.x + 2.2, y: c.y + 3.2), control2: CGPoint(x: c.x + 3.6, y: c.y - 0.6))
                ctx.addPath(h)
                ctx.fillPath()
            }
        case .star:
            for x in eyeXs {
                let c = CGPoint(x: x, y: ey)
                let st = CGMutablePath()
                for k in 0..<8 {
                    let a = Double(k) * .pi / 4 + .pi / 2
                    let rad: CGFloat = k % 2 == 0 ? 3.2 : 1.2
                    let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
                    if k == 0 { st.move(to: pt) } else { st.addLine(to: pt) }
                }
                st.closeSubpath()
                ctx.addPath(st)
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 1))
                ctx.setStrokeColor(eyeColor)
                ctx.setLineWidth(0.7)
                ctx.drawPath(using: .fillStroke)
            }
        case .spiral:
            ctx.setLineWidth(1.1)
            for x in eyeXs {
                let sp = CGMutablePath()
                for k in 0...22 {
                    let tt = Double(k) / 22
                    let a = tt * 4 * .pi + pose.clock * 6
                    let pt = CGPoint(x: x + CGFloat(cos(a) * tt) * 2.8, y: ey + CGFloat(sin(a) * tt) * 2.8)
                    if k == 0 { sp.move(to: pt) } else { sp.addLine(to: pt) }
                }
                ctx.addPath(sp)
            }
            ctx.strokePath()
        case .dot:
            for x in eyeXs {
                ctx.fillEllipse(in: CGRect(x: x - 1.1 + look.dx * 0.6, y: ey - 1.1 + look.dy * 0.6, width: 2.2, height: 2.2))
            }
        case .wink:
            // 왼쪽은 뜬 눈, 오른쪽은 ^
            let c = CGPoint(x: eyeXs[0] + look.dx * 0.8, y: ey + look.dy * 0.8)
            ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2.8, width: 4, height: 5.6))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - 1.1, y: c.y + 0.3, width: 1.5, height: 1.5))
            ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: eyeXs[1] - 2.4, y: ey - 1))
            ctx.addQuadCurve(to: CGPoint(x: eyeXs[1] + 2.4, y: ey - 1), control: CGPoint(x: eyeXs[1], y: ey + 2.6))
            ctx.strokePath()
        }

        // 입
        let m = CGPoint(x: fx, y: r.head.y - 5.6)
        ctx.setStrokeColor(species.outline)
        ctx.setLineWidth(1.2)
        switch r.mouth {
        case .smile:
            ctx.move(to: CGPoint(x: m.x - 1.9, y: m.y + 0.7))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 1.9, y: m.y + 0.7), control: CGPoint(x: m.x, y: m.y - 1.4))
            ctx.strokePath()
        case .open, .chomp:
            let h: CGFloat = r.mouth == .chomp ? 1.6 : 2.8
            let rect = CGRect(x: m.x - 2.1, y: m.y - h + 0.8, width: 4.2, height: h)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - h * 0.7))
            ctx.addPath(p)
            ctx.setFillColor(mouthColor)
            ctx.drawPath(using: .fillStroke)
        case .o:
            ctx.setFillColor(mouthColor)
            let rect = CGRect(x: m.x - 1.4, y: m.y - 1.2, width: 2.8, height: 2.6)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
        case .wobbly:
            ctx.move(to: CGPoint(x: m.x - 3, y: m.y))
            ctx.addQuadCurve(to: CGPoint(x: m.x - 1, y: m.y), control: CGPoint(x: m.x - 2, y: m.y + 1.3))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 1, y: m.y), control: CGPoint(x: m.x, y: m.y - 1.3))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 3, y: m.y), control: CGPoint(x: m.x + 2, y: m.y + 1.3))
            ctx.strokePath()
        case .flat:
            ctx.move(to: CGPoint(x: m.x - 1.6, y: m.y))
            ctx.addLine(to: CGPoint(x: m.x + 1.6, y: m.y))
            ctx.strokePath()
        case .tongue:
            ctx.move(to: CGPoint(x: m.x - 1.9, y: m.y + 0.7))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 1.9, y: m.y + 0.7), control: CGPoint(x: m.x, y: m.y - 1.4))
            ctx.strokePath()
            ctx.setFillColor(mouthColor)
            ctx.fillEllipse(in: CGRect(x: m.x + 0.6, y: m.y - 2.4, width: 2.4, height: 2.6))
        case .grin:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: m.x - 3.2, y: m.y + 0.9))
            p.addLine(to: CGPoint(x: m.x + 3.2, y: m.y + 0.9))
            p.addQuadCurve(to: CGPoint(x: m.x - 3.2, y: m.y + 0.9), control: CGPoint(x: m.x, y: m.y - 4.2))
            ctx.addPath(p)
            ctx.setFillColor(mouthColor)
            ctx.drawPath(using: .fillStroke)
        case .cat:
            ctx.move(to: CGPoint(x: m.x - 2.8, y: m.y + 0.6))
            ctx.addQuadCurve(to: CGPoint(x: m.x, y: m.y + 0.6), control: CGPoint(x: m.x - 1.4, y: m.y - 1.4))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 2.8, y: m.y + 0.6), control: CGPoint(x: m.x + 1.4, y: m.y - 1.4))
            ctx.strokePath()
        case .kiss:
            ctx.move(to: CGPoint(x: m.x - 0.4, y: m.y + 1.6))
            ctx.addQuadCurve(to: CGPoint(x: m.x - 0.4, y: m.y), control: CGPoint(x: m.x + 1.9, y: m.y + 0.8))
            ctx.addQuadCurve(to: CGPoint(x: m.x - 0.4, y: m.y - 1.6), control: CGPoint(x: m.x + 1.9, y: m.y - 0.8))
            ctx.strokePath()
        }

        if r.noseBubble > 0 {
            let size = 2.5 + r.noseBubble * 4.5
            let c = CGPoint(x: fx + 2.6 + size * 0.5, y: r.head.y - 5.4 - size * 0.05)
            ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.9, blue: 1, alpha: 0.55))
            ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.7, blue: 0.95, alpha: 0.8))
            ctx.setLineWidth(0.8)
            let rect = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: c.x - size * 0.25, y: c.y + size * 0.08, width: size * 0.22, height: size * 0.22))
        }
        ctx.restoreGState()
    }

    private func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let sp = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ca = a.converted(to: sp, intent: .defaultIntent, options: nil)?.components,
              let cb = b.converted(to: sp, intent: .defaultIntent, options: nil)?.components, ca.count >= 3, cb.count >= 3 else { return a }
        let alpha = (ca.count > 3 ? ca[3] : 1) * (1 - t) + t
        return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t, blue: ca[2] + (cb[2] - ca[2]) * t, alpha: alpha)
    }

    private func drawHold(_ hold: Hold, r: Rig, in ctx: CGContext) {
        let hands = r.arms.map(\.hand)
        let mid = CGPoint(x: (hands[0].x + hands[1].x) / 2, y: (hands[0].y + hands[1].y) / 2)
        ctx.saveGState()
        ctx.setLineJoin(.round)
        switch hold {
        case .onigiri:
            let c = CGPoint(x: mid.x + 0.5, y: mid.y - 1.5)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y + 6.5))
            p.addQuadCurve(to: CGPoint(x: c.x + 6.5, y: c.y - 4), control: CGPoint(x: c.x + 5.5, y: c.y + 3))
            p.addQuadCurve(to: CGPoint(x: c.x - 6.5, y: c.y - 4), control: CGPoint(x: c.x, y: c.y - 6.5))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + 6.5), control: CGPoint(x: c.x - 5.5, y: c.y + 3))
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.setStrokeColor(species.outline)
            ctx.setLineWidth(1.4)
            ctx.drawPath(using: .fillStroke)
            ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.25, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: c.x - 3, y: c.y - 5.2, width: 6, height: 4.4))
        case .mop:
            // 손잡이는 손에서 앞쪽 바닥으로, 끝에 하늘색 걸레
            let foot = CGPoint(x: mid.x + 16, y: 1.5)
            ctx.setStrokeColor(CGColor(srgbRed: 0.62, green: 0.45, blue: 0.3, alpha: 1))
            ctx.setLineWidth(2.2)
            ctx.setLineCap(.round)
            ctx.move(to: mid)
            ctx.addLine(to: CGPoint(x: foot.x - 2, y: foot.y + 4))
            ctx.strokePath()
            let head = CGRect(x: foot.x - 7, y: foot.y - 1.5, width: 14, height: 6)
            ctx.addPath(CGPath(roundedRect: head, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.62, green: 0.85, blue: 1, alpha: 1))
            ctx.setStrokeColor(species.outline)
            ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
        case .crayon(let color):
            ctx.translateBy(x: mid.x, y: mid.y)
            ctx.rotate(by: -0.9)
            ctx.setFillColor(color)
            ctx.setStrokeColor(species.outline)
            ctx.setLineWidth(1)
            ctx.addRect(CGRect(x: -5, y: -1.9, width: 10, height: 3.8))
            ctx.drawPath(using: .fillStroke)
            ctx.move(to: CGPoint(x: 5, y: -1.9))
            ctx.addLine(to: CGPoint(x: 9, y: 0))
            ctx.addLine(to: CGPoint(x: 5, y: 1.9))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
            ctx.fill(CGRect(x: -3, y: -1.9, width: 2, height: 3.8))
        }
        ctx.restoreGState()
    }

    private func drawSweat(_ r: Rig, t: TimeInterval, in ctx: CGContext) {
        let rect = headRect(r)
        let wobble = CGFloat(sin(t * 6)) * 0.6
        let c = CGPoint(x: rect.maxX - 1, y: rect.maxY - 4 + wobble)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + 4))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - 2), control: CGPoint(x: c.x + 3.2, y: c.y - 1))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + 4), control: CGPoint(x: c.x - 3.2, y: c.y - 1))
        ctx.addPath(p)
        ctx.setFillColor(tearColor)
        ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.6, blue: 0.9, alpha: 0.9))
        ctx.setLineWidth(0.9)
        ctx.drawPath(using: .fillStroke)
    }
}
