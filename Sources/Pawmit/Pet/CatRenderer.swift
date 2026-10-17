import AppKit
import CoreGraphics
import PawmitCore

/// 기본 펫 "고양이"를 코드로 그린다. 외부 이미지 없이 모든 동작(먹기·자기·뒤지기·낙서 등)을 표현하기 위해
/// 스프라이트 대신 부위(몸·머리·다리·꼬리)를 포즈에 맞춰 배치하는 방식이다.
///
/// 좌표계: 발 중심이 (0,0), y는 위쪽, 오른쪽을 바라보는 기준. 왼쪽은 호출자가 x를 뒤집는다.
/// 외곽선은 "스티커" 방식 — 모든 부위를 굵은 외곽선 색으로 먼저 칠하고 그 위에 채움색을 올려
/// 부위끼리 겹친 내부 선 없이 하나의 실루엣 외곽선이 나오게 한다.
struct CatPalette {
    var body: CGColor
    var stripe: CGColor?
    var belly: CGColor
    var outline: CGColor
    var earInner: CGColor
    var nose: CGColor
    var eye: CGColor
    var pupil: CGColor
    var cheek: CGColor

    static func coat(_ name: String) -> CatPalette {
        func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        switch name {
        case "gray":
            return CatPalette(body: c(0xA7B0BC), stripe: c(0x7A8492), belly: c(0xEEF1F5), outline: c(0x353A43),
                              earInner: c(0xF2A7B0), nose: c(0xE9798B), eye: c(0x24262B), pupil: c(0x24262B), cheek: c(0xF59AAA, 0.55))
        case "black":
            return CatPalette(body: c(0x34343C), stripe: nil, belly: c(0x4A4A54), outline: c(0x16161A),
                              earInner: c(0xC9828E), nose: c(0xC9828E), eye: c(0xF2D45C), pupil: c(0x16161A), cheek: c(0xE58A9B, 0.45))
        case "white":
            return CatPalette(body: c(0xFBF8F3), stripe: nil, belly: c(0xFFFFFF), outline: c(0x5E554C),
                              earInner: c(0xF6AEB6), nose: c(0xEF8394), eye: c(0x2A2724), pupil: c(0x2A2724), cheek: c(0xF7A2B1, 0.55))
        case "tuxedo":
            return CatPalette(body: c(0x2F3036), stripe: nil, belly: c(0xF7F5F0), outline: c(0x141418),
                              earInner: c(0xD08A96), nose: c(0xE58A9B), eye: c(0x9BD36B), pupil: c(0x141418), cheek: c(0xE58A9B, 0.45))
        default: // cheese
            return CatPalette(body: c(0xF6B65C), stripe: c(0xE08A33), belly: c(0xFFF1DA), outline: c(0x5A381C),
                              earInner: c(0xF6A3A3), nose: c(0xEE7A8A), eye: c(0x2B1E14), pupil: c(0x2B1E14), cheek: c(0xF6909E, 0.55))
        }
    }
}

extension CatPalette {
    /// pet.json("kind": "cat") → 털색. `coat`(cheese·gray·black·white·tuxedo)를 바탕으로 색 필드만 덮어쓴다.
    /// "stripe": null 이면 줄무늬 없음.
    static func from(json raw: JSONValue) -> CatPalette {
        let v = PetCatalog.resolve(raw)
        var p = CatPalette.coat(v["coat"]?.string ?? "cheese")
        func set(_ key: String, _ apply: (CGColor) -> Void) {
            if let s = v[key]?.string, let c = CGColor.fromHex(s) { apply(c) }
        }
        set("body") { p.body = $0 }
        set("belly") { p.belly = $0 }
        set("outline") { p.outline = $0 }
        set("earInner") { p.earInner = $0 }
        set("nose") { p.nose = $0 }
        set("eye") { p.eye = $0 }
        set("pupil") { p.pupil = $0 }
        set("cheek") { p.cheek = $0.copy(alpha: 0.55) ?? $0 }
        if v["stripe"] == .null { p.stripe = nil } else { set("stripe") { p.stripe = $0 } }
        return p
    }
}

final class CatRenderer {
    var palette: CatPalette
    /// 렌더러 기준 크기 (scale 1일 때). PetView가 창 크기 계산에 쓴다.
    static let unitHeight: CGFloat = 64
    static let unitWidth: CGFloat = 70

    convenience init(coat: String) {
        self.init(palette: .coat(coat), key: coat)
    }

    /// 커스텀 털색 고양이 (pet.json "kind": "cat"). key는 캐시·모양 seed 구분용.
    init(palette: CatPalette, key: String) {
        self.palette = palette
        coatName = key
        shapeSeed = Ink.seed("cat:" + key)
    }

    private let coatName: String
    private let shapeSeed: UInt64

    // MARK: - Rig

    private enum EyeStyle { case open, closed, happy, wide, half, focused }
    private enum MouthStyle { case smile, open, chomp, flat }

    private struct Leg {
        var x: CGFloat
        var top: CGFloat
        var length: CGFloat
        var angle: CGFloat
        var lift: CGFloat
        var far: Bool
        var width: CGFloat = 7
    }

    private struct Rig {
        var body = CGPoint(x: -2, y: 17)
        var bodyRX: CGFloat = 21
        var bodyRY: CGFloat = 12.5
        var bodyTilt: CGFloat = 0
        var haunch: (CGPoint, CGFloat, CGFloat)? = nil
        var head = CGPoint(x: 16, y: 31)
        var headR: CGFloat = 14.5
        var headTilt: CGFloat = 0
        var legs: [Leg] = []
        var backPaw: CGPoint? = nil
        var frontPaws: CGPoint? = nil
        var tail = CGMutablePath()
        var tailWidth: CGFloat = 6.5
        var tailInFront = false
        var earLift: CGFloat = 0
        var earDroop: CGFloat = 0
        var eyes: EyeStyle = .open
        var mouth: MouthStyle = .smile
        var faceShift: CGFloat = 4
    }

    // MARK: - Public

    func draw(_ pose: PetPose, in ctx: CGContext) {
        let (srect, salpha) = shadow(pose)
        ctx.setFillColor(CGColor(gray: 0, alpha: salpha))
        ctx.fillEllipse(in: srect.offsetBy(dx: 0, dy: -pose.hop))
        renderBody(pose, in: ctx, face: true)
    }

    // MARK: - 레이어·캐시용

    var cacheID: String { "cat:\(coatName)" }
    /// 실측(framecache bounds) 몸통 x -37...37, y -7...59 / 얼굴 x -9...40, y 6...42 에 여유를 둔 값
    var cacheBounds: CGRect { CGRect(x: -40, y: -9, width: 80, height: 72) }
    var faceBounds: CGRect { CGRect(x: -14, y: 2, width: 60, height: 46) }

    func shadow(_ pose: PetPose) -> (CGRect, CGFloat) {
        let k = max(0.45, 1 - pose.hop / 60)
        return (CGRect(x: -24 * k, y: -3, width: 48 * k, height: 7 * k), 0.16 * k)
    }

    func renderBody(_ pose: PetPose, in ctx: CGContext, face: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let m = pose.motion {
            let t = pose.motionTime
            if let b = m.bounce { ctx.translateBy(x: 0, y: CGFloat(b.base + abs(b.amp * sin(2 * .pi * b.freq * t + b.phase)))) }
            if let l = m.lean { ctx.rotate(by: CGFloat(l.value(at: t))) }
            if let sw = m.sway { ctx.translateBy(x: CGFloat(sw.value(at: t)), y: 0) }
        }
        renderBodyNoMotion(pose, in: ctx, face: face)
    }

    func renderFace(_ pose: PetPose, in ctx: CGContext) {
        let rig = makeRig(pose)
        drawFace(rig, pose: pose, in: ctx)
    }

    func faceKey(_ pose: PetPose) -> String {
        let rig = makeRig(pose)
        let lx = Int((pose.look.dx * 4).rounded()), ly = Int((pose.look.dy * 4).rounded())
        return "\(rig.eyes)|\(rig.mouth)|\(lx),\(ly)|\(pose.anim.rawValue)"
    }

    /// 손그림 느낌: 다리는 위가 넓고 발이 콩 모양으로 퍼지게, 몸·머리는 고양이마다 고정된 손그림 덩어리,
    /// 외곽선은 아래쪽이 조금 굵게, 앉을 때 겹친 엉덩이는 얇은 주름선, 몸·머리에 반달 그림자.
    private func renderBodyNoMotion(_ pose: PetPose, in ctx: CGContext, face: Bool) {
        let rig = makeRig(pose)
        let shapes = silhouetteShapes(rig)
        Ink.sticker(shapes.map { Ink.Shape(path: $0.path, fill: $0.color) }, outline: palette.outline, width: 2.9, in: ctx)

        // 앉았을 때 엉덩이(허벅지)가 몸에 겹친 경계
        let body = bodyPath(rig)
        if let h = rig.haunch {
            Ink.crease(haunchPath(h), inside: body, color: Ink.tint(palette.outline, 0.85), width: 1.3, in: ctx)
        }
        Ink.shade(body, offset: CGVector(dx: 1.2, dy: -2.4), color: Ink.tint(palette.outline, 0.1), in: ctx)

        drawBodyDetails(rig, in: ctx)
        Ink.shade(headPath(rig), offset: CGVector(dx: 1.3, dy: -2.2), color: Ink.tint(palette.outline, 0.07), in: ctx)
        drawEars(rig, in: ctx, inner: true)
        if face { drawFace(rig, pose: pose, in: ctx) }
        if let crayon = pose.crayon { drawCrayon(rig, color: crayon, in: ctx) }
    }

    /// 히트 테스트용 실루엣 (로컬 좌표, 오른쪽 바라봄 기준)
    func silhouette(_ pose: PetPose) -> CGPath {
        let rig = makeRig(pose)
        let path = CGMutablePath()
        for s in silhouetteShapes(rig) { path.addPath(s.path) }
        // 작은 펫도 잡기 쉽게 머리·몸 둘레를 넉넉히 잡는다
        path.addEllipse(in: CGRect(x: rig.head.x - rig.headR - 4, y: rig.head.y - rig.headR - 4,
                                   width: (rig.headR + 4) * 2, height: (rig.headR + 4) * 2))
        return path
    }

    /// 머리 위 좌표 (말풍선·파티클 기준점)
    func headTop(_ pose: PetPose) -> CGPoint {
        let rig = makeRig(pose)
        return CGPoint(x: rig.head.x, y: rig.head.y + rig.headR + 10)
    }

    /// 입 위치 (크레용 끝, 먹이 위치 계산용)
    func mouthPoint(_ pose: PetPose) -> CGPoint {
        let rig = makeRig(pose)
        return CGPoint(x: rig.head.x + rig.faceShift + 9, y: rig.head.y - 8)
    }

    // MARK: - Pose → Rig

    private func makeRig(_ p: PetPose) -> Rig {
        var r = Rig()
        let t = p.clock
        let at = p.animTime
        let omega = 2 * Double.pi / FrameQuantizer.idlePeriod
        let omegaSleep = 2 * Double.pi / FrameQuantizer.sleepPeriod
        let walking = p.anim == .walk || p.anim == .run
        let breath = sin(t * (p.anim == .sleep ? omegaSleep : omega)) * 0.025
        let sway = walking ? sin(p.walkPhase) * 3 : sin(t * omega) * 3

        switch p.anim {
        case .sleep:
            r.body = CGPoint(x: 0, y: 11)
            r.bodyRX = 24
            r.bodyRY = 11 * (1 + breath * 1.6)
            r.head = CGPoint(x: 15, y: 13 + sin(t * omegaSleep) * 0.4)
            r.headR = 13
            r.headTilt = -0.28
            r.frontPaws = CGPoint(x: 21, y: 2.5)
            r.tail = curve((-21, 7), (-27, -2), (-2, -4), (14, 1))
            r.tailInFront = true
            r.eyes = .closed
            r.mouth = .flat
            r.earDroop = 0.25
            r.faceShift = 3

        case .drag, .fall:
            let swing = sin(t * (p.anim == .fall ? 14 : 5)) * 0.25
            r.head = CGPoint(x: 0, y: 46)
            r.headR = 14
            r.body = CGPoint(x: 0, y: 26)
            r.bodyRX = 11.5
            r.bodyRY = 16
            r.legs = [
                Leg(x: -5, top: 22, length: 13, angle: -0.35 + swing, lift: 0, far: true),
                Leg(x: 5, top: 22, length: 13, angle: 0.35 - swing, lift: 0, far: false),
                Leg(x: -6, top: 16, length: 13, angle: 0.15 + swing, lift: 0, far: true),
                Leg(x: 6, top: 16, length: 13, angle: -0.15 - swing, lift: 0, far: false),
            ]
            let tx = sin(t * 4) * 5
            r.tail = curve((0, 12), (2, 2), (tx, -4), (tx * 1.4, -12))
            r.eyes = .wide
            r.mouth = .open
            r.earLift = 0.15
            r.faceShift = 0

        case .sit, .idle, .alert, .happy, .sad, .think, .groom, .wave, .play:
            r.body = CGPoint(x: -3, y: 15)
            r.bodyRX = 15
            r.bodyRY = 15.5 * (1 + breath)
            r.bodyTilt = -0.12
            r.haunch = (CGPoint(x: -9, y: 8.5), 12.5, 8.5)
            r.head = CGPoint(x: 5, y: 36 + breath * 20)
            r.headR = 14.5
            r.backPaw = CGPoint(x: -15, y: 1.8)
            r.legs = [
                Leg(x: -0.5, top: 16, length: 16, angle: 0, lift: 0, far: true),
                Leg(x: 5, top: 16, length: 16, angle: 0, lift: 0, far: false),
            ]
            let flick = sin(t * omega * 2) * 1.6
            r.tail = curve((-18, 6), (-29, 1), (-8, -4), (11, 2 + flick))
            r.tailInFront = true
            r.faceShift = 4

            switch p.anim {
            case .alert:
                r.earLift = 0.35
                r.eyes = .wide
                r.mouth = .open
                r.tail = curve((-17, 12), (-27, 18), (-25, 36), (-20 + sway * 0.4, 46))
                r.tailInFront = false
            case .happy:
                r.eyes = .happy
                r.mouth = .open
                r.tail = curve((-17, 12), (-28, 18), (-28, 34), (-21 + sin(t * 9) * 4, 44))
                r.tailInFront = false
            case .sad:
                r.eyes = .half
                r.mouth = .flat
                r.earDroop = 0.6
                r.head.y -= 2.5
                r.headTilt = -0.1
                r.tail = curve((-18, 5), (-26, 1), (-26, 0), (-34, 1))
            case .think:
                r.eyes = .open
                r.mouth = .flat
                r.headTilt = 0.12
            case .groom:
                r.eyes = .closed
                r.headTilt = sin(at * 7) * 0.1 - 0.12
                r.head.x -= 1
                r.legs[1] = Leg(x: 6, top: 18, length: 15, angle: -2.25 + sin(at * 7) * 0.15, lift: 0, far: false)
                r.mouth = .open
            case .wave:
                r.eyes = .happy
                r.mouth = .open
                r.legs[1] = Leg(x: 6, top: 19, length: 15, angle: -2.45 + sin(at * 11) * 0.45, lift: 0, far: false)
                r.tail = curve((-17, 12), (-28, 18), (-28, 34), (-21 + sway, 44))
                r.tailInFront = false
            case .play:
                r.eyes = .wide
                r.mouth = .smile
                r.earLift = 0.2
                r.legs[1] = Leg(x: 6, top: 17, length: 15, angle: -1.15 + sin(at * 10) * 0.55, lift: 0, far: false)
            default:
                r.eyes = .open
            }

        default:
            // 서 있는 계열: walk, run, eat, dig, draw, pounce
            let running = p.anim == .run
            let amp: CGFloat = running ? 0.75 : (p.anim == .walk || p.anim == .draw ? 0.45 : 0)
            let ph = p.walkPhase
            let bob = amp > 0 ? abs(sin(ph)) * (running ? 2 : 1.1) : breath * 12
            r.body = CGPoint(x: -2, y: 17 + bob)
            r.bodyRX = running ? 22.5 : 21
            r.bodyRY = 12.5
            r.head = CGPoint(x: running ? 18 : 16, y: 31 + bob)
            let offsets: [CGFloat] = [0, .pi, .pi, 0]
            let xs: [CGFloat] = [-13, -8, 9, 14]
            for i in 0..<4 {
                let a = amp > 0 ? sin(ph + offsets[i]) * amp : 0
                let lift = amp > 0 ? max(0, sin(ph + offsets[i] + .pi / 2)) * (running ? 3.5 : 2.2) : 0
                r.legs.append(Leg(x: xs[i], top: 15 + bob, length: 15 + bob, angle: a, lift: lift, far: i % 2 == 0))
            }
            let tailUp: CGFloat = running ? 4 : 0
            r.tail = curve((-21, 21 + bob), (-32, 24 + sway + tailUp), (-34, 39 + tailUp), (-27 + sway, 47 + tailUp))
            r.eyes = .open
            r.mouth = .smile

            switch p.anim {
            case .eat:
                let chomp = abs(sin(at * 9)) * 1.8
                r.head = CGPoint(x: 21, y: 18 + chomp)
                r.headTilt = -0.18
                r.eyes = .happy
                r.mouth = chomp > 0.9 ? .chomp : .smile
                r.bodyTilt = -0.08
            case .dig:
                r.bodyTilt = -0.14
                r.head = CGPoint(x: 22, y: 20)
                r.headTilt = -0.2
                r.eyes = .focused
                r.earLift = 0.1
                r.legs[3] = Leg(x: 15, top: 13, length: 14, angle: sin(at * 24) * 0.95 - 0.3, lift: 3, far: false)
                r.legs[2] = Leg(x: 10, top: 13, length: 14, angle: sin(at * 24 + .pi) * 0.7 - 0.2, lift: 2, far: true)
                r.tail = curve((-21, 21), (-32, 30), (-30, 44), (-22 + sin(t * 8) * 4, 52))
            case .draw:
                r.eyes = .focused
                r.head.y -= 2
                r.headTilt = -0.1
            case .pounce:
                if p.hop > 1 {
                    r.legs = [
                        Leg(x: -13, top: 15, length: 15, angle: 0.9, lift: 0, far: true),
                        Leg(x: -8, top: 15, length: 15, angle: 0.8, lift: 0, far: false),
                        Leg(x: 9, top: 15, length: 15, angle: -0.95, lift: 0, far: true),
                        Leg(x: 14, top: 15, length: 15, angle: -0.85, lift: 0, far: false),
                    ]
                    r.eyes = .wide
                    r.mouth = .open
                } else {
                    // 웅크림: 엉덩이 들썩
                    r.body.y = 12 + sin(at * 18) * 0.8
                    r.head.y = 24
                    r.head.x = 18
                    r.eyes = .focused
                    r.earLift = 0.15
                    for i in r.legs.indices { r.legs[i].top = 10; r.legs[i].length = 10 }
                    r.tail = curve((-21, 15), (-30, 14), (-36, 18 + sin(at * 16) * 3), (-42, 16 + sin(at * 16) * 5))
                }
            default:
                break
            }
        }

        if p.chubby > 0.01 {
            r.bodyRX *= 1 + 0.45 * p.chubby
            r.bodyRY *= 1 + 0.15 * p.chubby
        }
        if p.heat > 0.6, r.mouth == .smile { r.mouth = .open }
        if p.blink > 0.5, r.eyes == .open || r.eyes == .focused || r.eyes == .wide { r.eyes = .closed }
        if p.stretch != 1 {
            r.body.y *= p.stretch
            r.head.y *= p.stretch
            r.bodyRY *= p.stretch
        }
        return r
    }

    private func curve(_ a: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.0, y: a.1))
        path.addCurve(to: CGPoint(x: b.0, y: b.1), control1: CGPoint(x: c1.0, y: c1.1), control2: CGPoint(x: c2.0, y: c2.1))
        return path
    }

    // MARK: - Shapes

    private struct Shape {
        var path: CGPath
        var color: CGColor
    }

    private func silhouetteShapes(_ r: Rig) -> [Shape] {
        var shapes: [Shape] = []
        let farLeg = palette.body.copy(alpha: 1).map { darken($0, 0.88) } ?? palette.body

        for leg in r.legs where leg.far { shapes.append(Shape(path: legPath(leg), color: farLeg)) }
        let tailShape = r.tail.copy(strokingWithWidth: r.tailWidth, lineCap: .round, lineJoin: .round, miterLimit: 2)
        if !r.tailInFront { shapes.append(Shape(path: tailShape, color: palette.body)) }
        if let paw = r.backPaw {
            shapes.append(Shape(path: Ink.bean(center: CGPoint(x: paw.x, y: paw.y + 0.4), rx: 6.2, ry: 3.4), color: palette.body))
        }
        if let h = r.haunch {
            shapes.append(Shape(path: haunchPath(h), color: palette.body))
        }
        shapes.append(Shape(path: bodyPath(r), color: palette.body))
        if r.tailInFront { shapes.append(Shape(path: tailShape, color: palette.body)) }
        for leg in r.legs where !leg.far { shapes.append(Shape(path: legPath(leg), color: palette.body)) }
        if let paws = r.frontPaws {
            shapes.append(Shape(path: Ink.bean(center: CGPoint(x: paws.x, y: paws.y + 0.3), rx: 6.3, ry: 3.6), color: palette.belly))
        }
        for ear in earPaths(r) { shapes.append(Shape(path: ear.outer, color: palette.body)) }
        shapes.append(Shape(path: headPath(r), color: palette.body))
        return shapes
    }

    /// 머리: 볼이 살짝 통통한 덩어리 (고양이마다 모양 고정)
    private func headPath(_ r: Rig) -> CGPath {
        Ink.blob(CGRect(x: r.head.x - r.headR, y: r.head.y - r.headR * 0.93, width: r.headR * 2, height: r.headR * 1.86),
                 seed: shapeSeed &+ 1, wobble: 0.012, squareness: 0.45, bottomBias: 0.06)
    }

    private func bodyPath(_ r: Rig) -> CGPath {
        let tf = CGAffineTransform(translationX: r.body.x, y: r.body.y).rotated(by: r.bodyTilt)
        return Ink.blob(CGRect(x: -r.bodyRX, y: -r.bodyRY, width: r.bodyRX * 2, height: r.bodyRY * 2),
                        seed: shapeSeed &+ 2, wobble: 0.015, squareness: 0.3, bottomBias: 0.06, transform: tf)
    }

    private func haunchPath(_ h: (CGPoint, CGFloat, CGFloat)) -> CGPath {
        Ink.blob(CGRect(x: h.0.x - h.1, y: h.0.y - h.2, width: h.1 * 2, height: h.2 * 2), seed: shapeSeed &+ 3, wobble: 0.02, squareness: 0.2)
    }

    /// 다리: 위는 넓게 몸에 묻히고 아래로 좁아지다가 발이 콩 모양으로 퍼진다
    private func legPath(_ leg: Leg) -> CGPath {
        let w = leg.width
        let bottom = -leg.length + leg.lift
        let tf = CGAffineTransform(translationX: leg.x, y: leg.top).rotated(by: leg.angle)
        let p = CGMutablePath()
        let limb = Ink.limb(from: CGPoint(x: 0, y: 1.5), to: CGPoint(x: 0, y: bottom + w * 0.5), rootWidth: w * 1.2, tipWidth: w * 0.86)
        p.addPath(limb, transform: tf)
        p.addPath(Ink.bean(center: CGPoint(x: 0.7, y: bottom + w * 0.38), rx: w * 0.6, ry: w * 0.44), transform: tf)
        return p
    }

    private func earPaths(_ r: Rig) -> [(outer: CGPath, inner: CGPath)] {
        let defs: [(CGFloat, CGFloat)] = [(2.05, 1.0), (1.05, 1.0)] // (각도, 크기)
        return defs.map { def in
            let angle = def.0 + r.headTilt + (def.0 > 1.5 ? r.earDroop : -r.earDroop)
            let h: CGFloat = (10.5 + r.earLift * 8) * (1 - r.earDroop * 0.35)
            let base = CGPoint(x: r.head.x + cos(angle) * (r.headR - 2.5), y: r.head.y + sin(angle) * (r.headR - 2.5))
            let dir = CGVector(dx: cos(angle), dy: sin(angle))
            let perp = CGVector(dx: -dir.dy, dy: dir.dx)
            let half: CGFloat = 6.2
            let tip = CGPoint(x: base.x + dir.dx * h, y: base.y + dir.dy * h)
            let outer = CGMutablePath()
            outer.move(to: CGPoint(x: base.x + perp.dx * half, y: base.y + perp.dy * half))
            outer.addQuadCurve(to: tip, control: CGPoint(x: base.x + perp.dx * half * 0.6 + dir.dx * h * 0.6, y: base.y + perp.dy * half * 0.6 + dir.dy * h * 0.6))
            outer.addQuadCurve(to: CGPoint(x: base.x - perp.dx * half, y: base.y - perp.dy * half),
                               control: CGPoint(x: base.x - perp.dx * half * 0.6 + dir.dx * h * 0.6, y: base.y - perp.dy * half * 0.6 + dir.dy * h * 0.6))
            outer.closeSubpath()
            let ih = h * 0.62
            let ihalf = half * 0.5
            let ibase = CGPoint(x: base.x + dir.dx * 1.5, y: base.y + dir.dy * 1.5)
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: ibase.x + perp.dx * ihalf, y: ibase.y + perp.dy * ihalf))
            inner.addLine(to: CGPoint(x: ibase.x + dir.dx * ih, y: ibase.y + dir.dy * ih))
            inner.addLine(to: CGPoint(x: ibase.x - perp.dx * ihalf, y: ibase.y - perp.dy * ihalf))
            inner.closeSubpath()
            return (outer, inner)
        }
    }

    // MARK: - Details

    private func drawEars(_ r: Rig, in ctx: CGContext, inner: Bool) {
        guard inner else { return }
        ctx.setFillColor(palette.earInner)
        for ear in earPaths(r) {
            ctx.addPath(ear.inner)
            ctx.fillPath()
        }
    }

    private func drawBodyDetails(_ r: Rig, in ctx: CGContext) {
        // 배 (몸 안쪽으로 클립)
        ctx.saveGState()
        ctx.addPath(bodyPath(r))
        ctx.clip()
        ctx.setFillColor(palette.belly)
        let bellyCenter = CGPoint(x: r.body.x + r.bodyRX * 0.35, y: r.body.y - r.bodyRY * 0.55)
        ctx.fillEllipse(in: CGRect(x: bellyCenter.x - r.bodyRX * 0.6, y: bellyCenter.y - r.bodyRY * 0.55,
                                   width: r.bodyRX * 1.2, height: r.bodyRY * 0.9))
        if let stripe = palette.stripe {
            ctx.setStrokeColor(stripe)
            ctx.setLineWidth(2.6)
            ctx.setLineCap(.round)
            for i in 0..<3 {
                let x = r.body.x - r.bodyRX * 0.45 + CGFloat(i) * r.bodyRX * 0.3
                let top = r.body.y + r.bodyRY
                ctx.move(to: CGPoint(x: x - 1.5, y: top + 1))
                ctx.addLine(to: CGPoint(x: x + 1, y: top - r.bodyRY * 0.45))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 머리 무늬 + 주둥이
        ctx.saveGState()
        ctx.addPath(headPath(r))
        ctx.clip()
        let fx = r.head.x + r.faceShift
        if let stripe = palette.stripe {
            ctx.setStrokeColor(stripe)
            ctx.setLineWidth(2.3)
            ctx.setLineCap(.round)
            for dx in [-4.0, 0.0, 4.0] as [CGFloat] {
                ctx.move(to: CGPoint(x: fx + dx - 1, y: r.head.y + r.headR + 1))
                ctx.addLine(to: CGPoint(x: fx + dx * 0.8, y: r.head.y + r.headR - 5.5 + abs(dx) * 0.3))
            }
            ctx.strokePath()
        }
        ctx.setFillColor(palette.belly)
        ctx.fillEllipse(in: CGRect(x: fx - 6.5, y: r.head.y - 10.5, width: 13, height: 8.5))
        ctx.restoreGState()
    }

    private func drawFace(_ r: Rig, pose: PetPose, in ctx: CGContext) {
        let fx = r.head.x + r.faceShift
        let ey = r.head.y + 1.5
        let eyeXs: [CGFloat] = [fx - 5.6, fx + 5.6]
        let look = CGVector(dx: max(-1, min(1, pose.look.dx)), dy: max(-1, min(1, pose.look.dy)))

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch r.eyes {
        case .closed:
            ctx.setStrokeColor(palette.outline)
            ctx.setLineWidth(1.8)
            for x in eyeXs {
                ctx.move(to: CGPoint(x: x - 2.6, y: ey))
                ctx.addQuadCurve(to: CGPoint(x: x + 2.6, y: ey), control: CGPoint(x: x, y: ey - 2.4))
            }
            ctx.strokePath()
        case .happy:
            ctx.setStrokeColor(palette.outline)
            ctx.setLineWidth(1.9)
            for x in eyeXs {
                ctx.move(to: CGPoint(x: x - 2.6, y: ey - 1))
                ctx.addQuadCurve(to: CGPoint(x: x + 2.6, y: ey - 1), control: CGPoint(x: x, y: ey + 3.2))
            }
            ctx.strokePath()
        case .half:
            for x in eyeXs {
                ctx.setFillColor(palette.eye)
                ctx.fillEllipse(in: CGRect(x: x - 2.3, y: ey - 2.6, width: 4.6, height: 3.6))
                ctx.setFillColor(palette.body)
                ctx.fill(CGRect(x: x - 3, y: ey, width: 6, height: 2.5))
                ctx.setStrokeColor(palette.outline)
                ctx.setLineWidth(1.3)
                ctx.move(to: CGPoint(x: x - 2.8, y: ey + 0.2))
                ctx.addLine(to: CGPoint(x: x + 2.8, y: ey - 0.3))
                ctx.strokePath()
            }
        case .open, .wide, .focused:
            let rx: CGFloat = r.eyes == .wide ? 2.9 : 2.4
            let ry: CGFloat = r.eyes == .wide ? 3.6 : (r.eyes == .focused ? 2.4 : 3.2)
            for x in eyeXs {
                let c = CGPoint(x: x + look.dx * 0.9, y: ey + look.dy * 0.8)
                ctx.setFillColor(palette.eye)
                ctx.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                if palette.eye != palette.pupil {
                    ctx.setFillColor(palette.pupil)
                    ctx.fillEllipse(in: CGRect(x: c.x - 1, y: c.y - ry * 0.85, width: 2, height: ry * 1.7))
                }
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
                ctx.fillEllipse(in: CGRect(x: c.x - rx * 0.15, y: c.y + ry * 0.2, width: 1.6, height: 1.6))
            }
        }

        // 볼터치
        ctx.setFillColor(palette.cheek)
        for x in [fx - 9.2, fx + 9.2] {
            ctx.fillEllipse(in: CGRect(x: x - 2.6, y: r.head.y - 5.2, width: 5.2, height: 3))
        }

        // 코
        let nose = CGPoint(x: fx, y: r.head.y - 3.2)
        ctx.setFillColor(palette.nose)
        ctx.move(to: CGPoint(x: nose.x - 1.8, y: nose.y + 1))
        ctx.addLine(to: CGPoint(x: nose.x + 1.8, y: nose.y + 1))
        ctx.addLine(to: CGPoint(x: nose.x, y: nose.y - 1.2))
        ctx.closePath()
        ctx.fillPath()

        // 입
        ctx.setStrokeColor(palette.outline)
        ctx.setLineWidth(1.3)
        let my = nose.y - 1.4
        switch r.mouth {
        case .smile:
            ctx.move(to: CGPoint(x: nose.x - 3, y: my - 0.6))
            ctx.addQuadCurve(to: CGPoint(x: nose.x, y: my), control: CGPoint(x: nose.x - 1.5, y: my - 2.2))
            ctx.addQuadCurve(to: CGPoint(x: nose.x + 3, y: my - 0.6), control: CGPoint(x: nose.x + 1.5, y: my - 2.2))
            ctx.strokePath()
        case .open, .chomp:
            let h: CGFloat = r.mouth == .chomp ? 1.6 : 2.6
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.18, blue: 0.22, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: nose.x - 1.9, y: my - h - 0.6, width: 3.8, height: h + 0.6))
            ctx.strokeEllipse(in: CGRect(x: nose.x - 1.9, y: my - h - 0.6, width: 3.8, height: h + 0.6))
        case .flat:
            ctx.move(to: CGPoint(x: nose.x - 2, y: my - 0.8))
            ctx.addLine(to: CGPoint(x: nose.x + 2, y: my - 0.8))
            ctx.strokePath()
        }

        // 수염
        ctx.setStrokeColor(palette.outline.copy(alpha: 0.55) ?? palette.outline)
        ctx.setLineWidth(0.8)
        for (dy, slope) in [(0.0, 0.6), (-1.8, -0.3)] as [(CGFloat, CGFloat)] {
            ctx.move(to: CGPoint(x: fx + 8, y: r.head.y - 3.5 + dy))
            ctx.addLine(to: CGPoint(x: fx + 17, y: r.head.y - 3.5 + dy + slope * 2))
            ctx.move(to: CGPoint(x: fx - 8, y: r.head.y - 3.5 + dy))
            ctx.addLine(to: CGPoint(x: fx - 17, y: r.head.y - 3.5 + dy + slope * 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawCrayon(_ r: Rig, color: CGColor, in ctx: CGContext) {
        let fx = r.head.x + r.faceShift
        let start = CGPoint(x: fx + 1, y: r.head.y - 6.5)
        ctx.saveGState()
        ctx.translateBy(x: start.x, y: start.y)
        ctx.rotate(by: -0.35)
        ctx.setFillColor(color)
        ctx.setStrokeColor(palette.outline)
        ctx.setLineWidth(1)
        let body = CGRect(x: 0, y: -1.8, width: 11, height: 3.6)
        ctx.addRect(body)
        ctx.drawPath(using: .fillStroke)
        ctx.move(to: CGPoint(x: 11, y: -1.8))
        ctx.addLine(to: CGPoint(x: 15, y: 0))
        ctx.addLine(to: CGPoint(x: 11, y: 1.8))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.6))
        ctx.fill(CGRect(x: 2, y: -1.8, width: 2.2, height: 3.6))
        ctx.restoreGState()
    }

    private func darken(_ c: CGColor, _ f: CGFloat) -> CGColor {
        guard let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              comps.count >= 3 else { return c }
        return CGColor(srgbRed: comps[0] * f, green: comps[1] * f, blue: comps[2] * f, alpha: comps.count > 3 ? comps[3] : 1)
    }
}
