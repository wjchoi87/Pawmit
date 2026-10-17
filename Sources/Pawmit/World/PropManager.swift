import AppKit

/// 화면에 떠 있는 소품들을 프레임마다 움직이고, 사라진 것은 정리한다.
@MainActor
final class PropManager {
    private(set) var props: [PropWindow] = []
    var ballBounds: CGRect = .zero

    @discardableResult
    func spawn(_ kind: PropWindow.Kind, at p: CGPoint, scale: CGFloat, length: CGFloat = 0) -> PropWindow {
        let prop = PropWindow(kind: kind, at: p, scale: max(0.6, scale), length: length)
        props.append(prop)
        return prop
    }

    func update(dt: TimeInterval) {
        for prop in props { prop.update(dt: dt, bounds: ballBounds) }
        props.removeAll { $0.isGone }
    }

    var isAnimating: Bool { props.contains { $0.isAnimating } }

    func dismissAll() {
        for prop in props { prop.dismiss() }
    }
}
