import AppKit
import QuartzCore
import PawmitCore

/// 펫이 화면에 남기는 크레용 낙서.
///
/// 화면마다 클릭이 통과되는 투명 창 하나를 두고, 획마다 `CAShapeLayer`(벡터, GPU 렌더)를 붙인다.
/// 화면 크기 비트맵을 다시 그리지 않으므로 CPU·메모리를 거의 쓰지 않는다.
/// 기본은 모든 창 위(펫보다는 아래), 설정 `doodleLayer: "desktop"`이면 바탕화면 층.
@MainActor
final class DoodleLayer {
    struct Stroke: Codable {
        var points: [CGPoint]
        var rgba: [Double]
        var width: Double
        var created: Date
        /// 한 번에 그린 그림 묶음 (우클릭 지우기·청소 단위)
        var group: String?
        /// true면 채워진 도형(외곽선 획 뒤에 덧붙는 색 면). 지우기·수명은 외곽선과 같이 간다.
        var filled: Bool = false

        init(points: [CGPoint], rgba: [Double], width: Double, created: Date, group: String?, filled: Bool = false) {
            self.points = points
            self.rgba = rgba
            self.width = width
            self.created = created
            self.group = group
            self.filled = filled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            points = try c.decode([CGPoint].self, forKey: .points)
            rgba = try c.decode([Double].self, forKey: .rgba)
            width = try c.decode(Double.self, forKey: .width)
            created = try c.decode(Date.self, forKey: .created)
            group = try c.decodeIfPresent(String.self, forKey: .group)
            filled = try c.decodeIfPresent(Bool.self, forKey: .filled) ?? false
        }
    }

    /// 우클릭 메뉴 동작 (Director가 설정)
    var onEraseGroup: (String) -> Void = { _ in }
    var onAskPetToClean: (String) -> Void = { _ in }
    var onEraseAll: () -> Void = {}

    var config: PawmitConfig {
        didSet {
            if oldValue.doodleLayer != config.doodleLayer { applyLevel() }
            if oldValue.doodleSeconds != config.doodleSeconds { tickFade(); reapplyFades() }
        }
    }
    private(set) var strokes: [Stroke] = []
    private var current: Stroke?
    private var currentLayers: [CAShapeLayer] = []
    private var screens: [(screen: NSScreen, window: NSWindow, root: CALayer)] = []
    private var strokeLayers: [[CAShapeLayer]] = []

    init(config: PawmitConfig) {
        self.config = config
        load()
        rebuildWindows()
    }

    private var level: NSWindow.Level {
        config.doodleLayer == "desktop"
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 4)
            : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    private func applyLevel() {
        for s in screens { s.window.level = level }
    }

    func rebuildWindows() {
        for s in screens { s.window.orderOut(nil); s.window.close() }
        screens = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.level = level
            let view = DoodleHitView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.owner = self
            let root = CALayer()
            root.frame = view.bounds
            root.sublayerTransform = CATransform3DMakeTranslation(-screen.frame.minX, -screen.frame.minY, 0)
            view.layer = root
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return (screen, window, root)
        }
        for layers in strokeLayers { layers.forEach { $0.removeFromSuperlayer() } }
        strokeLayers = strokes.map { makeLayers(for: $0) }
    }

    private func makeLayers(for stroke: Stroke) -> [CAShapeLayer] {
        let path = CGMutablePath()
        path.addLines(between: stroke.points)
        if stroke.filled { path.closeSubpath() }
        let pad = CGFloat(stroke.filled ? 2 : stroke.width)
        let box = path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)
        return screens.filter { $0.screen.frame.intersects(box) }.map { s in
            let l = CAShapeLayer()
            l.path = path
            if stroke.filled {
                l.fillColor = CGColor(srgbRed: stroke.rgba[0], green: stroke.rgba[1], blue: stroke.rgba[2], alpha: stroke.rgba[3])
                l.strokeColor = nil
            } else {
                l.fillColor = nil
                l.strokeColor = CGColor(srgbRed: stroke.rgba[0], green: stroke.rgba[1], blue: stroke.rgba[2], alpha: stroke.rgba[3])
                l.lineWidth = CGFloat(stroke.width)
            }
            l.lineCap = .round
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "opacity": NSNull()]
            s.root.addSublayer(l)
            if !stroke.filled { applyFade(l, stroke) }
            return l
        }
    }

    /// 외곽선 획을 다 그린 뒤 그 안을 색으로 채운다 — 명화·풍경·만화 도안의 색 면. 서서히 차오른다.
    func fillShape(points: [CGPoint], color: NSColor, group: String?) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let stroke = Stroke(points: points, rgba: [c.redComponent, c.greenComponent, c.blueComponent, 0.62].map(Double.init),
                            width: 0, created: Date(), group: group, filled: true)
        let layers = makeLayers(for: stroke)
        CATransaction.begin()
        for l in layers {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 0
            anim.toValue = 0.75
            anim.duration = 0.9
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            l.opacity = 0.75
            l.add(anim, forKey: "fill-in")
        }
        CATransaction.commit()
        strokes.append(stroke)
        strokeLayers.append(layers)
        dirtySave()
    }

    func begin(color: NSColor, width: CGFloat, group: String? = nil) {
        let c = color.usingColorSpace(.sRGB) ?? color
        current = Stroke(points: [], rgba: [c.redComponent, c.greenComponent, c.blueComponent, 1].map(Double.init),
                         width: Double(width), created: Date(), group: group)
        currentLayers = []
    }

    func add(_ p: CGPoint) {
        guard var stroke = current else { return }
        if let last = stroke.points.last, hypot(last.x - p.x, last.y - p.y) < 1.5 { return }
        stroke.points.append(CGPoint(x: p.x + .random(in: -0.5...0.5), y: p.y + .random(in: -0.5...0.5)))
        current = stroke
        guard stroke.points.count > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 다른 화면으로 넘어가면 레이어를 다시 만들고, 아니면 경로만 갱신
        let path = CGMutablePath()
        path.addLines(between: stroke.points)
        let box = path.boundingBoxOfPath.insetBy(dx: -CGFloat(stroke.width), dy: -CGFloat(stroke.width))
        let needed = screens.filter { $0.screen.frame.intersects(box) }.count
        if currentLayers.count != needed {
            currentLayers.forEach { $0.removeFromSuperlayer() }
            currentLayers = makeLayers(for: stroke)
        } else {
            for l in currentLayers { l.path = path }
        }
        CATransaction.commit()
    }

    func end() {
        if let stroke = current, stroke.points.count > 1 {
            strokes.append(stroke)
            // 다 그린 획부터 흐려지기 시작
            currentLayers.forEach { applyFade($0, stroke) }
            strokeLayers.append(currentLayers.isEmpty ? makeLayers(for: stroke) : currentLayers)
            if strokes.count > 400 {
                strokeLayers.first?.forEach { $0.removeFromSuperlayer() }
                strokes.removeFirst()
                strokeLayers.removeFirst()
            }
            save()
        } else {
            currentLayers.forEach { $0.removeFromSuperlayer() }
        }
        current = nil
        currentLayers = []
    }

    /// 모두 지우기를 할 때마다 1씩. 그리던 그림은 이 값이 바뀌면 나머지 획을 그리지 않는다.
    private(set) var generation = 0

    /// 세대 번호를 올려 그리던 그림을 멈추게 하고(Brain.doodle이 확인), 화면마다 붙은 낙서 레이어를 기록과 상관없이 모두 뗀다.
    func clearAll() {
        generation += 1
        release()
        current = nil
        currentLayers.forEach { $0.removeFromSuperlayer() }
        currentLayers = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layers in strokeLayers { layers.forEach { $0.removeFromSuperlayer() } }
        for s in screens { s.root.sublayers?.forEach { $0.removeFromSuperlayer() } }
        CATransaction.commit()
        strokes.removeAll()
        strokeLayers.removeAll()
        hoverGroup = nil
        save()
    }

    // MARK: - 지우기

    var groupIDs: [String] {
        var seen = Set<String>()
        return strokes.compactMap { $0.group ?? "legacy" }.filter { seen.insert($0).inserted }
    }

    func strokes(inGroup g: String) -> [Stroke] { strokes.filter { ($0.group ?? "legacy") == g } }

    /// 그림 묶음 하나를 통째로 지운다
    func removeGroup(_ g: String) {
        var i = 0
        while i < strokes.count {
            if (strokes[i].group ?? "legacy") == g {
                strokeLayers[i].forEach { $0.removeFromSuperlayer() }
                strokes.remove(at: i)
                strokeLayers.remove(at: i)
            } else {
                i += 1
            }
        }
        save()
    }

    /// p 주변 radius 안의 선을 지운다(걸레질). 획이 중간에서 끊기면 둘로 나눈다. 지운 점 수를 돌려준다.
    @discardableResult
    func erase(around p: CGPoint, radius: CGFloat) -> Int {
        var erased = 0
        var i = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while i < strokes.count {
            let stroke = strokes[i]
            let box = Self.bounds(of: stroke).insetBy(dx: -radius, dy: -radius)
            guard box.contains(p) else { i += 1; continue }
            var pieces: [[CGPoint]] = [[]]
            var removedHere = 0
            for q in stroke.points {
                if hypot(q.x - p.x, q.y - p.y) <= radius {
                    removedHere += 1
                    if !(pieces.last?.isEmpty ?? true) { pieces.append([]) }
                } else {
                    pieces[pieces.count - 1].append(q)
                }
            }
            guard removedHere > 0 else { i += 1; continue }
            erased += removedHere
            strokeLayers[i].forEach { $0.removeFromSuperlayer() }
            strokes.remove(at: i)
            strokeLayers.remove(at: i)
            for piece in pieces where piece.count > 1 {
                var s = stroke
                s.points = piece
                strokes.insert(s, at: i)
                strokeLayers.insert(makeLayers(for: s), at: i)
                i += 1
            }
        }
        CATransaction.commit()
        if erased > 0 { dirtySave() }
        return erased
    }

    static func bounds(of stroke: Stroke) -> CGRect {
        guard let first = stroke.points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for q in stroke.points {
            minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y)
        }
        let pad = CGFloat(stroke.width)
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    /// 전역 좌표 p에 걸린 낙서 묶음 (선에서 tolerance 이내)
    func group(at p: CGPoint, tolerance: CGFloat = 6) -> String? {
        for stroke in strokes.reversed() {
            let box = Self.bounds(of: stroke).insetBy(dx: -tolerance, dy: -tolerance)
            guard box.contains(p) else { continue }
            for (a, b) in zip(stroke.points, stroke.points.dropFirst()) where Self.distance(p, a, b) <= tolerance + CGFloat(stroke.width) / 2 {
                return stroke.group ?? "legacy"
            }
        }
        return nil
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - 우클릭으로 지우기 (커서가 낙서 위에 잠깐 머물 때만 클릭을 받는다)

    private var hoverGroup: String?
    private var hoverSince: TimeInterval = 0
    private var captured: NSWindow?
    private var passThroughUntil: TimeInterval = 0
    private var lastHoverMouse = CGPoint(x: -1, y: -1)

    func updateHover(mouse: CGPoint, now: TimeInterval) {
        guard mouse != lastHoverMouse else {
            if let g = hoverGroup, captured == nil, now - hoverSince > 0.35, now > passThroughUntil { capture(g, mouse) }
            return
        }
        lastHoverMouse = mouse
        let g = strokes.isEmpty ? nil : group(at: mouse)
        if g != hoverGroup {
            hoverGroup = g
            hoverSince = now
            release()
        }
    }

    private func capture(_ g: String, _ mouse: CGPoint) {
        guard let s = screens.first(where: { $0.screen.frame.contains(mouse) }) else { return }
        s.window.ignoresMouseEvents = false
        captured = s.window
        highlight(g, true)
    }

    private func release() {
        if let w = captured { w.ignoresMouseEvents = true }
        captured = nil
        for (stroke, layers) in zip(strokes, strokeLayers) {
            for l in layers where l.lineWidth != CGFloat(stroke.width) { l.lineWidth = CGFloat(stroke.width); l.shadowOpacity = 0 }
        }
    }

    private func highlight(_ g: String, _ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (stroke, layers) in zip(strokes, strokeLayers) where (stroke.group ?? "legacy") == g {
            for l in layers {
                l.lineWidth = CGFloat(stroke.width) + (on ? 2.5 : 0)
                l.shadowColor = CGColor(gray: 0, alpha: 1)
                l.shadowOpacity = on ? 0.35 : 0
                l.shadowRadius = 3
                l.shadowOffset = .zero
            }
        }
        CATransaction.commit()
    }

    fileprivate func rightClicked(_ event: NSEvent, in view: NSView) {
        guard let g = hoverGroup else { return }
        let menu = NSMenu()
        let erase = NSMenuItem(title: L10n.t("이 낙서 지우기"), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let clean = NSMenuItem(title: L10n.t("펫한테 닦아달라고 하기 🧽"), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let all = NSMenuItem(title: L10n.t("낙서 모두 지우기"), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let target = MenuTarget()
        target.actions = [
            erase: { [weak self] in self?.onEraseGroup(g); self?.release() },
            clean: { [weak self] in self?.onAskPetToClean(g); self?.release() },
            all: { [weak self] in self?.onEraseAll(); self?.release() },
        ]
        for i in [erase, clean, all] { i.target = target; menu.addItem(i) }
        menuTarget = target
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    fileprivate func leftClicked() {
        // 낙서 위 왼쪽 클릭은 아래 앱에 양보: 잠깐 클릭 통과 모드로
        passThroughUntil = ProcessInfo.processInfo.systemUptime + 2
        release()
    }

    private var menuTarget: MenuTarget?

    final class MenuTarget: NSObject {
        var actions: [NSMenuItem: () -> Void] = [:]
        @objc func fire(_ sender: NSMenuItem) { actions[sender]?() }
    }

    private var saveScheduled = false
    private func dirtySave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    /// 낙서 수명(10…60초). 처음 1/4은 그대로, 그 뒤로 Core Animation으로 흐려지고 1초마다 수명이 끝난 획을 정리한다.
    var lifetime: TimeInterval { min(60, max(10, config.doodleSeconds)) }

    /// 1초마다: 수명이 끝난 획 지우기
    func tickFade() {
        var removed = false
        var i = 0
        let now = Date()
        while i < strokes.count {
            if now.timeIntervalSince(strokes[i].created) >= lifetime {
                strokeLayers[i].forEach { $0.removeFromSuperlayer() }
                strokes.remove(at: i)
                strokeLayers.remove(at: i)
                removed = true
            } else {
                i += 1
            }
        }
        if removed { save() }
    }

    /// 나이(수명 대비 0…1)에 따른 진하기: 처음 1/4은 그대로, 그 뒤 부드럽게 0까지
    func alpha(age t: Double) -> Double {
        guard t > 0.25 else { return 0.9 }
        let x = min(1, (t - 0.25) / 0.75)
        return 0.9 * (1 - x * x * (3 - 2 * x))
    }

    func alpha(for stroke: Stroke) -> CGFloat {
        CGFloat(alpha(age: Date().timeIntervalSince(stroke.created) / lifetime))
    }

    /// 지금부터 수명이 끝날 때까지 흐려지는 애니메이션 (렌더 서버가 돌리므로 앱 CPU를 쓰지 않는다)
    private func applyFade(_ layer: CAShapeLayer, _ stroke: Stroke) {
        let life = lifetime
        let age = Date().timeIntervalSince(stroke.created)
        let remaining = life - age
        layer.removeAnimation(forKey: "fade")
        guard remaining > 0.05 else { layer.opacity = 0; return }
        let steps = 12
        var values: [Double] = []
        var times: [NSNumber] = []
        for k in 0...steps {
            let f = Double(k) / Double(steps)
            values.append(alpha(age: (age + remaining * f) / life))
            times.append(NSNumber(value: f))
        }
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = values
        anim.keyTimes = times
        anim.duration = remaining
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(anim, forKey: "fade")
    }

    /// 수명 설정이 바뀌면 다시 건다
    private func reapplyFades() {
        for (stroke, layers) in zip(strokes, strokeLayers) { layers.forEach { applyFade($0, stroke) } }
    }

    /// 개발용 상태
    func snapshot(to url: URL) -> String {
        "strokes=\(strokes.count) layers=\(strokeLayers.reduce(0) { $0 + $1.count }) level=\(level.rawValue) visible=\(screens.allSatisfy { $0.window.isVisible })"
    }

    private func load() {
        guard let data = try? Data(contentsOf: PawmitPaths.doodles),
              var list = try? JSONDecoder.pawmit.decode([Stroke].self, from: data) else { return }
        // 묶음 정보가 없는 예전 낙서: 20초 안에 이어서 그린 획끼리 한 그림으로 묶는다
        var current = UUID().uuidString
        var last: Date?
        for i in list.indices where list[i].group == nil {
            if let l = last, list[i].created.timeIntervalSince(l) > 20 { current = UUID().uuidString }
            list[i].group = current
            last = list[i].created
        }
        strokes = list
    }

    private func save() {
        guard let data = try? JSONEncoder.pawmit.encode(strokes) else { return }
        try? data.write(to: PawmitPaths.doodles, options: .atomic)
    }
}


/// 낙서 창 내용 뷰: 커서가 낙서 위에 있을 때만 클릭을 받는다
final class DoodleHitView: NSView {
    weak var owner: DoodleLayer?
    override func rightMouseDown(with event: NSEvent) { owner?.rightClicked(event, in: self) }
    override func mouseDown(with event: NSEvent) { owner?.leftClicked() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
