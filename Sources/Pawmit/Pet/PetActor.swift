import AppKit
import PawmitCore

/// 펫 한 마리. 화면 좌표(AppKit 전역, 왼쪽 아래 원점)에서 발 위치를 가지고, 자기 투명 창을 따라 움직인다.
///
/// 창 설정(투명·항상 위·모든 Space)과 포커스를 뺏지 않는 패널은 hookling(MIT) `PetWindow`,
/// 투명 영역 클릭 통과는 OpenPets(MIT)처럼 매 프레임 커서 위치를 실루엣으로 hit-test해
/// `ignoresMouseEvents`를 토글하는 방식을 썼다.
@MainActor
final class PetActor {
    let identity: PetIdentity
    var renderer: PetRenderer { identity.renderer }
    let isMain: Bool
    /// 렌더러 1단위 = 몇 pt
    var displayScale: CGFloat

    // 움직임 상태
    var position: CGPoint
    var facing: Facing = .right
    private(set) var anim: PetAnim = .idle
    private var animStart: TimeInterval = 0
    private var walkPhase: CGFloat = 0
    var target: CGPoint?
    var moveSpeed: CGFloat = 70
    var hop: CGFloat = 0
    private var hopVelocity: CGFloat = 0
    var stretch: CGFloat = 1
    /// 시선이 따라갈 전역 좌표 (보통 커서)
    var lookAt: CGPoint?
    var crayon: CGColor?
    var mop = false
    /// 행동 조합기가 얹는 모션 (nil이면 기본 포즈만)
    var motion: MotionSpec? {
        didSet { if motion != oldValue { motionStart = poseNow } }
    }
    private var motionStart: TimeInterval = 0
    var visualScale: CGFloat = 1
    var opacity: CGFloat = 1
    /// 사다리·밧줄·우산처럼 공중에 있을 때 바닥 그림자를 숨긴다
    var hideShadow = false
    /// 말풍선 위에 커서가 있는 동안 이동을 멈춘다 (버튼을 누르려는데 말풍선이 따라 움직이지 않게).
    var frozen = false
    var isHidden = false {
        didSet { isHidden ? window.orderOut(nil) : window.orderFrontRegardless() }
    }
    private(set) var dragging = false
    private var dragGrab: CGFloat = 0
    private var mouseDownAt: CGPoint?
    private var nextBlink: TimeInterval = 0
    private var blinkEnd: TimeInterval = 0
    private var lastEmit: TimeInterval = 0
    private var lastHeatEmit: TimeInterval = 0
    private var strokeDistance: CGFloat = 0
    private var strokeStart: TimeInterval = 0
    private var lastMouse: CGPoint = .zero
    private(set) var now: TimeInterval = 0

    let particles = ParticleSystem()
    let window: PetWindow
    private let view: PetView

    // 입력 콜백
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onPetted: (() -> Void)?

    init(identity: PetIdentity, isMain: Bool, displayScale: CGFloat, position: CGPoint) {
        self.identity = identity
        self.isMain = isMain
        self.displayScale = displayScale
        self.position = position
        let size = PetActor.windowSize(scale: displayScale)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        window = PetWindow(contentRect: NSRect(origin: .zero, size: size))
        window.contentView = view
        view.actor = self
        nextBlink = ProcessInfo.processInfo.systemUptime + .random(in: 2...5)
        syncWindow()
        window.orderFrontRegardless()
    }

    /// 발 아래 여백(단위). 끌리거나 떨어질 때 늘어진 꼬리·먼지가 창 아래 경계에서 잘리지 않게 넉넉히 둔다.
    /// 클릭은 실루엣에서만 받으므로 투명 여백이 클릭을 막지 않는다.
    static let footRoom: CGFloat = 20

    static func windowSize(scale: CGFloat) -> NSSize {
        NSSize(width: ceil(140 * scale), height: ceil((126 + footRoom) * scale))
    }

    /// 창 안에서 발이 놓이는 위치
    var anchor: CGPoint { CGPoint(x: view.bounds.width / 2, y: (PetActor.footRoom * displayScale).rounded()) }

    var pose: PetPose {
        var p = PetPose()
        // 멈춰 선 동안은 걷는 다리를 쉬는 자세로
        p.anim = frozen && target != nil && (anim == .walk || anim == .run) ? .idle : anim
        p.facing = facing
        p.animTime = poseNow - animStart
        p.clock = poseNow
        p.walkPhase = walkPhase
        p.hop = hop
        p.stretch = stretch
        p.blink = now < blinkEnd ? 1 : 0
        p.crayon = crayon
        p.mop = mop
        p.motion = motion
        p.motionTime = poseNow - motionStart
        p.heat = heat
        p.chubby = chubby
        p.scale = visualScale
        p.opacity = opacity
        if let lookAt {
            // 시선 계산에 쓰는 머리 위치는 look이 없는 기본 포즈로 구한다 (headTopGlobal → pose 재귀 방지)
            let head = headTopGlobal(for: p)
            var dx = (lookAt.x - head.x) / 140
            let dy = (lookAt.y - (head.y - 14 * displayScale)) / 140
            if facing == .left, !renderer.handlesFacing { dx = -dx }
            p.look = CGVector(dx: max(-1, min(1, dx)), dy: max(-1, min(1, dy)))
        }
        return p
    }

    /// 전역 좌표의 머리 위 지점 (말풍선 꼬리가 가리킬 곳)
    var headTopGlobal: CGPoint { headTopGlobal(for: pose) }

    /// 말풍선이 붙을 머리 위: 숨쉬기·걸음 출렁임·모션을 뺀 자세로 구해 가만히 있을 때 말풍선이 들썩이지 않게
    var steadyHeadTopGlobal: CGPoint {
        var p = PetPose()
        p.anim = anim
        p.facing = facing
        p.hop = hop
        p.chubby = chubby
        return headTopGlobal(for: p)
    }

    private func headTopGlobal(for pose: PetPose) -> CGPoint {
        let h = renderer.headTop(pose)
        let sx: CGFloat = (facing == .left && !renderer.handlesFacing) ? -1 : 1
        return CGPoint(x: position.x + h.x * sx * displayScale * visualScale,
                       y: position.y + (h.y + hop) * displayScale * visualScale)
    }

    /// 크레용·입 위치 (전역)
    var mouthGlobal: CGPoint {
        let m = renderer.mouthPoint(pose)
        let sx: CGFloat = (facing == .left && !renderer.handlesFacing) ? -1 : 1
        return CGPoint(x: position.x + m.x * sx * displayScale, y: position.y + (m.y + hop) * displayScale)
    }

    var headLocal: CGPoint { renderer.headTop(pose) }

    // MARK: - 동작 제어

    func setAnim(_ a: PetAnim) {
        guard a != anim else { return }
        anim = a
        animStart = poseNow
    }

    /// 시스템 상태 반영값 (Director가 설정)
    var heat: CGFloat = 0
    var chubby: CGFloat = 0
    /// 1 = 보통, 작을수록 동작 템포가 느려진다 (메모리 부하)
    var tempo: Double = 1
    /// 템포가 반영된 애니메이션 시계
    private var poseNow: TimeInterval = 0

    func face(toward x: CGFloat) {
        if abs(x - position.x) > 2 { facing = x > position.x ? .right : .left }
    }

    /// 렌더러 단위 높이만큼 깡총
    func jump(height: CGFloat = 14) {
        hopVelocity = sqrt(2 * PetActor.gravity * height)
        hop = max(hop, 0.01)
    }

    static let gravity: CGFloat = 420

    func emit(_ p: Particle) { particles.add(p) }

    /// 지금 부드럽게 움직여야 하는지 (프레임 속도 결정용)
    var isAnimatingActively: Bool {
        if isHidden { return false }
        if target != nil || hop > 0 || dragging || motion != nil || !particles.isEmpty || visualScale != 1 || opacity != 1 { return true }
        switch anim {
        case .walk, .run, .draw, .dig, .eat, .play, .pounce, .happy, .alert, .wave, .fall, .drag, .groom: return true
        default: return false
        }
    }

    // MARK: - 프레임 업데이트

    func update(now: TimeInterval, dt: TimeInterval) {
        self.now = now
        poseNow += dt * max(0.3, tempo)
        let mouse = NSEvent.mouseLocation

        if dragging {
            position = CGPoint(x: mouse.x, y: mouse.y - dragGrab)
            target = nil
        } else if frozen, target != nil {
            // 말풍선 hover 중: 목적지는 그대로 두고 멈춰 선다
        } else if let target {
            let dx = target.x - position.x
            let dy = target.y - position.y
            let dist = hypot(dx, dy)
            let step = moveSpeed * CGFloat(dt)
            if dist <= max(step, 0.5) {
                position = target
                self.target = nil
            } else {
                position.x += dx / dist * step
                position.y += dy / dist * step
                if abs(dx) > 0.5 { facing = dx > 0 ? .right : .left }
                walkPhase += step / displayScale * (.pi * 2 / 24)
                if anim == .run, Int(now * 10) % 3 == 0, now - lastEmit > 0.12 {
                    lastEmit = now
                    emit(FX.dust(at: CGPoint(x: 0, y: 0), facing: facing.sign))
                }
            }
        }

        // 점프 물리 (단위: 렌더러 좌표)
        if hop > 0 || hopVelocity != 0 {
            hop += hopVelocity * CGFloat(dt)
            hopVelocity -= PetActor.gravity * CGFloat(dt)
            if hop <= 0 { hop = 0; hopVelocity = 0 }
        }

        // 눈 깜빡임
        if now > nextBlink {
            blinkEnd = now + 0.13
            nextBlink = now + .random(in: 2.2...6.0)
        }

        emitAmbient(now: now)
        particles.update(dt: dt)
        updateMouseInteraction(mouse: mouse, now: now)
        syncWindow()
        // 창 이동은 매 프레임, 몸 그림은 "투스"로: 움직일 때 이동 속도의 2/3, 가만히 idleFPS, 잘 때 그 절반
        let interval: TimeInterval = isAnimatingActively ? 1.0 / (activeFPS * 0.67 + 1) : (anim == .sleep ? 1.0 / (idleFPS / 2) : 1.0 / idleFPS)
        if !isHidden, now - lastDraw >= interval * 0.9 {
            lastDraw = now
            view.render()
        }
    }

    private var lastDraw: TimeInterval = 0
    /// 성능 설정에 따른 그리기 속도
    var activeFPS: Double = 18
    var idleFPS: Double = 8

    private func emitAmbient(now: TimeInterval) {
        let head = renderer.headTop(pose)
        let headPt = CGPoint(x: head.x * displayScale * (facing == .left && !renderer.handlesFacing ? -1 : 1),
                             y: (head.y - 6) * displayScale)
        if heat > 0.45, now - lastHeatEmit > 3.2 - Double(heat) * 1.6 {
            lastHeatEmit = now
            emit(Particle(text: heat > 0.8 ? ["💦", "🥵", "💨"].randomElement()! : ["💦", "💨"].randomElement()!,
                          pos: CGPoint(x: headPt.x + .random(in: -16...16), y: headPt.y), vel: CGVector(dx: .random(in: -10...10), dy: .random(in: 10...22)),
                          maxLife: 1.5, size: 12, color: .labelColor))
        }
        switch anim {
        case .sleep where now - lastEmit > 1.3:
            lastEmit = now
            emit(FX.zzz(at: headPt))
        case .eat where now - lastEmit > 0.35:
            lastEmit = now
            let m = renderer.mouthPoint(pose)
            emit(FX.crumb(at: CGPoint(x: m.x * displayScale * (facing == .left && !renderer.handlesFacing ? -1 : 1), y: m.y * displayScale)))
        case .dig where now - lastEmit > 0.09:
            lastEmit = now
            let front = CGPoint(x: facing.sign * 14 * displayScale, y: 2)
            emit(Double.random(in: 0...1) < 0.12 ? FX.debris(at: front, facing: facing.sign) : FX.dust(at: front, facing: facing.sign))
        default:
            break
        }
    }

    // MARK: - 마우스

    /// 커서가 실루엣 위에 있는지 (펫 좌표계로 변환해 판정)
    func contains(globalPoint m: CGPoint) -> Bool {
        guard !isHidden else { return false }
        var local = CGPoint(x: (m.x - position.x) / (displayScale * visualScale), y: (m.y - position.y) / (displayScale * visualScale) - hop)
        if facing == .left, !renderer.handlesFacing { local.x = -local.x }
        return renderer.silhouette(pose).contains(local)
    }

    private var lastHitMouse = CGPoint(x: -1, y: -1)
    private var lastHitPosition = CGPoint(x: -1, y: -1)
    private var lastInside = false

    private func updateMouseInteraction(mouse: CGPoint, now: TimeInterval) {
        // 커서·펫이 그대로면 실루엣 판정을 다시 하지 않는다
        let inside: Bool
        if mouse == lastHitMouse, position == lastHitPosition, !dragging {
            inside = lastInside
        } else {
            inside = contains(globalPoint: mouse)
            lastHitMouse = mouse
            lastHitPosition = position
            lastInside = inside
        }
        let interactive = inside || dragging || mouseDownAt != nil
        if window.ignoresMouseEvents == interactive { window.ignoresMouseEvents = !interactive }

        // 쓰다듬기: 버튼 없이 펫 위를 왔다갔다
        if inside, !dragging, NSEvent.pressedMouseButtons == 0 {
            if strokeDistance == 0 { strokeStart = now }
            strokeDistance += hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
            if now - strokeStart > 2.5 { strokeDistance = 0 }
            if strokeDistance > 260 {
                strokeDistance = 0
                onPetted?()
            }
        } else if !inside {
            strokeDistance = 0
        }
        lastMouse = mouse
    }

    func mouseDown(_ event: NSEvent) {
        mouseDownAt = NSEvent.mouseLocation
    }

    func mouseDragged(_ event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let m = NSEvent.mouseLocation
        if !dragging, hypot(m.x - start.x, m.y - start.y) > 4 {
            dragging = true
            setAnim(.drag)
            let grabPose: PetPose = { var p = pose; p.anim = .drag; return p }()
            dragGrab = (renderer.headTop(grabPose).y - 10) * displayScale
            onDragStart?()
        }
    }

    func mouseUp(_ event: NSEvent) {
        mouseDownAt = nil
        if dragging {
            dragging = false
            onDragEnd?()
            return
        }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    // MARK: - 창

    func syncWindow() {
        let size = window.frame.size
        let origin = CGPoint(x: position.x - anchor.x, y: position.y - anchor.y)
        if window.frame.origin != origin || window.frame.size != size {
            window.setFrameOrigin(origin)
        }
    }

    func resize(scale: CGFloat) {
        displayScale = scale
        let size = PetActor.windowSize(scale: scale)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        syncWindow()
        view.render()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

/// 투명·항상 위·포커스를 뺏지 않는 펫 창
final class PetWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 펫 그리기 뷰.
/// AppKit 기본 경로(draw(_:))는 넓은 색역 화면에서 64비트 백킹 스토어에 래스터화하고,
/// 매 프레임 새 CGImage를 contents로 넘기면 CA가 매번 색 변환·복사를 한다.
/// 그래서 레이어 백킹 스토어를 8비트(RGBA8)로 지정하고 레이어 delegate로 바로 그린다.
///
/// 레이어 구성 (아래→위): 그림자 · 몸통(캐시 프레임) · 얼굴 · 라이브 · 파티클
/// - 가만히·앉기·걷기·달리기·잠은 몸통을 FrameCache의 같은 CGImage로 돌려 쓴다 (한 번 그리면 다시 안 그림).
///   눈·입은 작은 얼굴 레이어에서 바뀔 때만 다시 그리고, 좌우 뒤집기·점프 높이는 레이어 변환으로 처리한다.
/// - 춤·낙서·청소처럼 모션이 얹힌 동작은 라이브 레이어에 매번 그린다 (이전 방식).
final class PetView: NSView, CALayerDelegate {
    weak var actor: PetActor?
    private let host = CALayer()
    private let shadowLayer = CAShapeLayer()
    private let bodyLayer = CALayer()
    private let faceLayer = CALayer()
    private let liveLayer = CALayer()
    private let particleLayer = CALayer()

    private var cachedMode = false
    private var bodyKey = ""
    private var faceKey = ""
    private var shadowRect = CGRect.null
    private var facePose = PetPose()
    private var particlesDrawn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.actions = PetView.noActions
        host.isOpaque = false
        for l in [shadowLayer, bodyLayer, faceLayer, liveLayer, particleLayer] as [CALayer] {
            l.actions = PetView.noActions
            l.isOpaque = false
            host.addSublayer(l)
        }
        for l in [faceLayer, liveLayer, particleLayer] {
            l.contentsFormat = .RGBA8Uint
            l.delegate = self
        }
        shadowLayer.fillColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.isHidden = true
        bodyLayer.isHidden = true
        faceLayer.isHidden = true
        layer = host
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let noActions: [String: CAAction] = Dictionary(uniqueKeysWithValues: [
        "contents", "bounds", "position", "transform", "hidden", "path", "opacity", "anchorPoint", "frame", "sublayers", "fillColor",
    ].map { ($0, NSNull() as CAAction) })

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// needsDisplay 대신 이것을 부른다
    func render() {
        guard let actor else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [faceLayer, liveLayer, particleLayer] where l.contentsScale != scale { l.contentsScale = scale }
        if liveLayer.frame != bounds { liveLayer.frame = bounds; particleLayer.frame = bounds }

        let pose = actor.pose
        if FrameCache.shared.enabled, let layered = actor.renderer as? LayeredPetRenderer, let q = FrameQuantizer.quantize(pose) {
            renderCached(actor: actor, renderer: layered, pose: pose, quantized: q, backing: scale)
        } else {
            if cachedMode {
                cachedMode = false
                shadowLayer.isHidden = true
                bodyLayer.isHidden = true
                faceLayer.isHidden = true
                bodyKey = ""
                faceKey = ""
                liveLayer.isHidden = false
            }
            liveLayer.setNeedsDisplay()
        }

        if !actor.particles.isEmpty {
            particlesDrawn = true
            particleLayer.setNeedsDisplay()
        } else if particlesDrawn {
            particlesDrawn = false
            particleLayer.contents = nil
        }
    }

    private func renderCached(actor: PetActor, renderer: LayeredPetRenderer, pose: PetPose,
                              quantized q: (key: String, pose: PetPose), backing: CGFloat) {
        if !cachedMode {
            cachedMode = true
            liveLayer.isHidden = true
            liveLayer.contents = nil
            shadowLayer.isHidden = false
            bodyLayer.isHidden = false
            faceLayer.isHidden = false
        }
        let s = actor.displayScale
        let anchor = actor.anchor
        let flip = actor.facing == .left && !renderer.handlesFacing
        let transform = flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        let feet = CGPoint(x: anchor.x, y: anchor.y + actor.hop * s)
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        // 그림자: 바닥에 그대로, 점프하면 작아진다
        let (sr, alpha) = renderer.shadow(pose)
        let rect = CGRect(x: anchor.x + sr.minX * s, y: anchor.y + sr.minY * s, width: sr.width * s, height: sr.height * s)
        if rect != shadowRect {
            shadowRect = rect
            shadowLayer.frame = bounds
            shadowLayer.path = CGPath(ellipseIn: rect, transform: nil)
        }
        let shadowAlpha = actor.hideShadow ? 0 : Float(alpha)
        if shadowLayer.opacity != shadowAlpha { shadowLayer.opacity = shadowAlpha }

        // 몸통: 같은 키면 같은 이미지를 다시 쓴다
        let colorName = (space.name as String?) ?? "rgb"
        let key = "\(renderer.cacheID)|\(q.key)|s\(Int((s * 100).rounded()))|b\(Int(backing))|\(colorName)"
        if key != bodyKey {
            let box = renderer.cacheBounds
            let img = FrameCache.shared.image(key) {
                PetView.renderFrame(box: box, scale: s, backing: backing, space: space) { ctx in
                    renderer.renderBody(q.pose, in: ctx, face: false)
                }
            }
            if let img {
                bodyKey = key
                bodyLayer.contents = img
                place(bodyLayer, box: box, scale: s, backing: backing,
                      pixels: CGSize(width: img.width, height: img.height))
            }
        }
        bodyLayer.position = feet
        bodyLayer.transform = transform

        // 얼굴: 몸통 프레임과 같은 포즈에 실제 시선·깜빡임만 얹는다
        var fp = q.pose
        fp.look = pose.look
        fp.blink = pose.blink
        fp.heat = pose.heat
        let fk = q.key + "#" + renderer.faceKey(fp) + "|s\(Int((s * 100).rounded()))|b\(Int(backing))"
        if fk != faceKey {
            faceKey = fk
            facePose = fp
            let box = renderer.faceBounds
            let px = CGSize(width: ceil(box.width * s * backing), height: ceil(box.height * s * backing))
            place(faceLayer, box: box, scale: s, backing: backing, pixels: px)
            faceLayer.setNeedsDisplay()
        }
        faceLayer.position = feet
        faceLayer.transform = transform
    }

    /// 발(단위 좌표 0,0)이 레이어의 anchorPoint가 되게 크기를 맞춘다. 발 위치는 픽셀에 맞춰 반올림해 흐려지지 않게 한다.
    private func place(_ l: CALayer, box: CGRect, scale s: CGFloat, backing: CGFloat, pixels: CGSize) {
        let footX = (-box.minX * s * backing).rounded(), footY = (-box.minY * s * backing).rounded()
        l.bounds = CGRect(x: 0, y: 0, width: pixels.width / backing, height: pixels.height / backing)
        l.anchorPoint = CGPoint(x: footX / pixels.width, y: footY / pixels.height)
    }

    /// 단위 좌표 영역 box를 픽셀 비트맵에 그린다 (발 위치는 place와 같은 반올림)
    private static func renderFrame(box: CGRect, scale s: CGFloat, backing: CGFloat, space: CGColorSpace,
                                    draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(ceil(box.width * s * backing)), h = Int(ceil(box.height * s * backing))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: (-box.minX * s * backing).rounded(), y: (-box.minY * s * backing).rounded())
        ctx.scaleBy(x: s * backing, y: s * backing)
        draw(ctx)
        return ctx.makeImage()
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let actor else { return }
        if layer === faceLayer {
            guard let renderer = actor.renderer as? LayeredPetRenderer else { return }
            let s = actor.displayScale
            let box = renderer.faceBounds
            let backing = layer.contentsScale
            ctx.translateBy(x: (-box.minX * s * backing).rounded() / backing, y: (-box.minY * s * backing).rounded() / backing)
            ctx.scaleBy(x: s, y: s)
            renderer.renderFace(facePose, in: ctx)
        } else if layer === liveLayer {
            let pose = actor.pose
            let s = actor.displayScale * actor.visualScale
            let anchor = actor.anchor
            ctx.saveGState()
            ctx.setAlpha(actor.opacity)
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.scaleBy(x: s, y: s)
            if actor.facing == .left, !actor.renderer.handlesFacing { ctx.scaleBy(x: -1, y: 1) }
            // 몸은 hop만큼 위로. 렌더러는 그림자를 -hop 위치(바닥)에 그린다.
            ctx.translateBy(x: 0, y: actor.hop)
            if actor.hideShadow, let layered = actor.renderer as? LayeredPetRenderer {
                layered.renderBody(pose, in: ctx, face: true)
            } else {
                actor.renderer.draw(pose, in: ctx)
            }
            ctx.restoreGState()
        } else if layer === particleLayer {
            if !actor.particles.isEmpty { actor.particles.draw(origin: actor.anchor, in: ctx) }
        }
    }

    override func mouseDown(with event: NSEvent) { actor?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { actor?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { actor?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { actor?.onContextMenu?(event) }
}
