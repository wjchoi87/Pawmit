import AppKit
import ApplicationServices
import PawmitCore

/// 펫이 사는 공간: 화면들, Dock·휴지통 위치, 메뉴바 집 위치.
///
/// Dock 휴지통 위치는 Accessibility API로 Dock 프로세스의 `AXTrashDockItem`을 찾는다(손쉬운 사용 권한 필요).
/// 권한이 없으면 화면 오른쪽 아래에 Pawmit 휴지통 소품을 대신 놓는다.
@MainActor
final class World {
    var config: PawmitConfig
    /// 메뉴바 집(NSStatusItem)의 화면 좌표
    var houseFrame: () -> NSRect? = { nil }
    private var trashCache: (rect: CGRect?, at: Date)?

    init(config: PawmitConfig) {
        self.config = config
    }

    /// 펫이 쓰는 화면들. `PAWMIT_DISPLAY`(CGDirectDisplayID)를 주면 그 화면 하나에만 머문다 (README 녹화용).
    private static let pinnedDisplay = ProcessInfo.processInfo.environment["PAWMIT_DISPLAY"].flatMap(UInt32.init)

    var screens: [NSScreen] {
        let all = NSScreen.screens
        guard let id = Self.pinnedDisplay else { return all }
        let only = all.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return only.isEmpty ? all : only
    }

    /// 커서 위치. 화면을 하나로 묶었는데(PAWMIT_DISPLAY) 커서가 밖에 있으면 그 화면 가운데로 본다.
    var cursor: CGPoint {
        let m = NSEvent.mouseLocation
        guard Self.pinnedDisplay != nil, !screens.contains(where: { $0.frame.contains(m) }), let s = screens.first
        else { return m }
        return CGPoint(x: s.frame.midX, y: s.frame.midY)
    }

    func screen(containing p: CGPoint) -> NSScreen {
        screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
            ?? screens.min { distance(p, $0.frame) < distance(p, $1.frame) }
            ?? NSScreen.main!
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// 펫이 돌아다닐 수 있는 영역 (발 위치 기준).
    /// 좌우는 펫 몸 절반만큼 띄워 가장자리에서 몸이 화면 밖으로 잘리지 않게 한다.
    func roamRect(_ screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        let side = min(max(28, (42 * 1.65 * CGFloat(config.size)).rounded()), v.width / 4)
        // 머리가 메뉴바 아래에 오도록 위쪽만 펫 키만큼 비운다
        var r = CGRect(x: v.minX + side, y: v.minY + 6, width: v.width - side * 2, height: v.height - 96)
        if config.roam == "ground" { r.size.height = 30 }
        return r
    }

    /// 아무 화면이든 무작위 지점 (화면이 넓을수록 자주 뽑힌다)
    func randomPointAnywhere(excluding current: NSScreen? = nil) -> CGPoint {
        let candidates = screens.filter { $0 != current }
        let pool = candidates.isEmpty ? screens : candidates
        let total = pool.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        var roll = CGFloat.random(in: 0..<max(total, 1))
        var pick = pool[0]
        for sc in pool {
            roll -= sc.frame.width * sc.frame.height
            if roll < 0 { pick = sc; break }
        }
        let r = roamRect(pick)
        return CGPoint(x: CGFloat.random(in: r.minX...r.maxX), y: CGFloat.random(in: r.minY...max(r.minY, r.maxY)))
    }

    func clamp(_ p: CGPoint, to screen: NSScreen) -> CGPoint {
        let r = roamRect(screen)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// 현재 위치 근처의 무작위 목적지
    func randomPoint(near p: CGPoint, min minDist: CGFloat = 120, max maxDist: CGFloat = 480) -> CGPoint {
        let screen = screen(containing: p)
        // 가끔은 멀리, 다른 모니터까지 놀러 간다
        if config.roam != "ground", Double.random(in: 0...1) < (screens.count > 1 ? 0.18 : 0.12) {
            return randomPointAnywhere(excluding: screens.count > 1 ? screen : nil)
        }
        let r = roamRect(screen)
        for _ in 0..<12 {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let d = CGFloat.random(in: minDist...maxDist)
            let q = CGPoint(x: p.x + cos(a) * d, y: p.y + sin(a) * d * (config.roam == "ground" ? 0 : 0.7))
            if r.contains(q) { return q }
        }
        return CGPoint(x: CGFloat.random(in: r.minX...r.maxX), y: CGFloat.random(in: r.minY...max(r.minY, r.maxY)))
    }

    // MARK: - 모니터 사이 이동

    /// 한 화면 안에서의 수직 이동 구간 (사다리·밧줄·점프 등으로 오르내린다)
    struct Leg {
        var x: CGFloat
        var from: CGFloat
        var to: CGFloat
        var rise: CGFloat { to - from }
    }

    /// 이웃한 두 화면 사이를 건너는 방법: 출구까지 걸어가서 → (오르내리기) → 베젤 넘기 → (오르내리기)
    struct Crossing {
        /// 출발 화면에서 걸어갈 지점
        var exit: CGPoint
        /// 출발 화면 쪽에서 오르내리기
        var pre: Leg?
        /// 베젤을 넘어 도착하는 지점 (위아래로 붙은 화면이면 nil — 오르내리기가 곧 넘기)
        var hop: CGPoint?
        /// 도착 화면 쪽에서 오르내리기
        var post: Leg?
        /// 진행 방향 (좌우)
        var dir: CGFloat
    }

    /// 두 화면이 맞닿은 변. 화면 배치(시스템 설정 > 디스플레이)를 그대로 따른다.
    enum Side { case left, right, top, bottom }

    func neighbors(of a: NSScreen) -> [(NSScreen, Side)] {
        var out: [(NSScreen, Side)] = []
        for b in screens where b != a {
            let fa = a.frame, fb = b.frame
            let yOverlap = min(fa.maxY, fb.maxY) - max(fa.minY, fb.minY)
            let xOverlap = min(fa.maxX, fb.maxX) - max(fa.minX, fb.minX)
            if abs(fa.maxX - fb.minX) < 2, yOverlap > 40 { out.append((b, .right)) }
            else if abs(fa.minX - fb.maxX) < 2, yOverlap > 40 { out.append((b, .left)) }
            else if abs(fa.maxY - fb.minY) < 2, xOverlap > 40 { out.append((b, .top)) }
            else if abs(fa.minY - fb.maxY) < 2, xOverlap > 40 { out.append((b, .bottom)) }
        }
        return out
    }

    /// 화면을 건너 가는 순서 (BFS). 이어진 길이 없으면 nil.
    func screenPath(from a: NSScreen, to b: NSScreen) -> [NSScreen]? {
        if a == b { return [a] }
        var prev: [ObjectIdentifier: NSScreen] = [:]
        var queue = [a]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(a)]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for (n, _) in neighbors(of: cur) where !seen.contains(ObjectIdentifier(n)) {
                seen.insert(ObjectIdentifier(n))
                prev[ObjectIdentifier(n)] = cur
                if n == b {
                    var path = [b]
                    var c = b
                    while let p = prev[ObjectIdentifier(c)] { path.insert(p, at: 0); c = p }
                    return path
                }
                queue.append(n)
            }
        }
        return nil
    }

    /// a에서 이웃 화면 b로 건너는 경로. `alongFloor`면 바닥을 따라 걸어가서 바닥 높이 차이를 오르내린다.
    func crossing(from a: NSScreen, to b: NSScreen, at p: CGPoint, toward q: CGPoint, alongFloor: Bool) -> Crossing? {
        guard let side = neighbors(of: a).first(where: { $0.0 == b })?.1 else { return nil }
        let r1 = roamRect(a), r2 = roamRect(b)
        switch side {
        case .left, .right:
            let dir: CGFloat = side == .right ? 1 : -1
            let edge = side == .right ? a.frame.maxX : a.frame.minX
            let x1 = side == .right ? r1.maxX : r1.minX
            let x2 = side == .right ? r2.minX : r2.maxX
            // 양쪽 화면 모두에서 보이는 높이
            let lo = max(r1.minY, r2.minY), hi = min(r1.maxY, r2.maxY)
            guard lo <= hi else { return nil }
            let y1: CGFloat
            if alongFloor {
                y1 = r1.minY
            } else {
                // 지금 위치에서 목적지까지 직선이 경계를 지나는 높이
                let t = abs(q.x - p.x) > 1 ? (edge - p.x) / (q.x - p.x) : 0
                y1 = min(max(p.y + (q.y - p.y) * min(max(t, 0), 1), r1.minY), r1.maxY)
            }
            let yc = min(max(y1, lo), hi)
            var c = Crossing(exit: CGPoint(x: x1, y: y1), pre: nil, hop: CGPoint(x: x2, y: yc), post: nil, dir: dir)
            if abs(yc - y1) >= 20 { c.pre = Leg(x: x1, from: y1, to: yc) }
            if alongFloor, abs(r2.minY - yc) >= 20 { c.post = Leg(x: x2, from: yc, to: r2.minY) }
            return c
        case .top, .bottom:
            let lo = max(r1.minX, r2.minX), hi = min(r1.maxX, r2.maxX)
            guard lo <= hi else { return nil }
            let edge = side == .top ? a.frame.maxY : a.frame.minY
            let t = abs(q.y - p.y) > 1 ? (edge - p.y) / (q.y - p.y) : 0
            let x = min(max(p.x + (q.x - p.x) * min(max(t, 0), 1), lo), hi)
            let y1 = side == .top ? r1.maxY : r1.minY
            let y2 = side == .top ? r2.minY : r2.maxY
            return Crossing(exit: CGPoint(x: x, y: y1), pre: Leg(x: x, from: y1, to: y2), hop: nil, post: nil, dir: 0)
        }
    }

    /// 처음 나타날 위치
    func spawnPoint() -> CGPoint {
        let screen = NSScreen.main.flatMap { screens.contains($0) ? $0 : nil } ?? screens[0]
        let r = roamRect(screen)
        return CGPoint(x: r.midX + .random(in: -120...120), y: r.minY + min(60, r.height * 0.2))
    }

    // MARK: - 메뉴바 집

    /// 집 앞 (메뉴바 바로 아래) 발 위치
    func houseDoor() -> CGPoint? {
        guard let f = houseFrame(), f.width > 0 else { return nil }
        let screen = screen(containing: CGPoint(x: f.midX, y: f.midY))
        return CGPoint(x: f.midX, y: screen.visibleFrame.maxY - 6)
    }

    // MARK: - Dock / 휴지통

    enum DockEdge { case bottom, left, right, hidden }

    func dockEdge(_ screen: NSScreen) -> DockEdge {
        let f = screen.frame, v = screen.visibleFrame
        if v.minY - f.minY > 2 { return .bottom }
        if v.minX - f.minX > 2 { return .left }
        if f.maxX - v.maxX > 2 { return .right }
        return .hidden
    }

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Dock 휴지통 아이콘 영역 (AppKit 좌표). 권한이 없거나 못 찾으면 nil.
    func dockTrashRect() -> CGRect? {
        if let cache = trashCache, Date().timeIntervalSince(cache.at) < 15 { return cache.rect }
        let rect = findDockTrash()
        trashCache = (rect, Date())
        return rect
    }

    private func findDockTrash() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for list in children(of: app) {
            for item in children(of: list) {
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subrole)
                guard (subrole as? String) == "AXTrashDockItem" else { continue }
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef)
                var pos = CGPoint.zero
                var size = CGSize.zero
                guard let posRef, let sizeRef else { return nil }
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                // AX 좌표: 주 화면 왼쪽 위 원점, y 아래로 → AppKit 좌표로 변환
                let primaryHeight = screens.first?.frame.height ?? 0
                return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// 휴지통을 뒤지러 갈 발 위치와, 진짜 Dock 휴지통인지 여부
    func trashSpot(near p: CGPoint) -> (foot: CGPoint, dock: Bool, facing: Facing) {
        if let rect = dockTrashRect() {
            let screen = screen(containing: CGPoint(x: rect.midX, y: rect.midY))
            switch dockEdge(screen) {
            case .left:
                return (CGPoint(x: rect.maxX + 18, y: rect.midY - 6), true, .left)
            case .right:
                return (CGPoint(x: rect.minX - 18, y: rect.midY - 6), true, .right)
            default:
                // 아래 Dock: 휴지통 바로 위 왼쪽에 서서 오른쪽(휴지통)을 바라보며 뒤진다
                return (CGPoint(x: rect.midX - 16, y: rect.maxY - 10), true, .right)
            }
        }
        let screen = screen(containing: p)
        let r = roamRect(screen)
        return (CGPoint(x: r.maxX - 70, y: r.minY + 6), false, .right)
    }

    /// 소품 휴지통을 놓을 자리 (Dock 휴지통이 없을 때)
    func fallbackTrashCan(for foot: CGPoint) -> CGPoint {
        CGPoint(x: foot.x + 34, y: foot.y)
    }
}
