import AppKit
import SwiftUI

/// 펫 머리 위에 붙어 다니는 말풍선 창. 카드(버튼·입력 있음)와 말(텍스트만) 두 종류를 쓴다.
/// 포커스를 뺏지 않는 패널이라 사용자가 입력칸을 직접 누를 때만 키 입력을 가져온다.
@MainActor
final class BubbleController {
    enum Edge { case below, above }

    final class Panel: NSPanel {
        var allowKey = true
        override var canBecomeKey: Bool { allowKey }
        override var canBecomeMain: Bool { false }
        /// Esc
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
        /// 새 카드로 바뀐 직후 잠깐은 입력칸이 포커스를 못 가져가게
        var blockAutoFocusUntil: TimeInterval = 0

        // 입력칸은 패널이 키 창이고 카드가 바뀐 직후(0.35초)가 아닐 때만 포커스를 받는다.
        // 저절로 생긴 포커스가 답장 대기 시간을 멈추지 않게 (사용자가 입력칸을 누르면 패널이 먼저 키가 된다).
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder is NSTextView || responder is NSTextField,
               !isKeyWindow || ProcessInfo.processInfo.systemUptime < blockAutoFocusUntil {
                return false
            }
            return super.makeFirstResponder(responder)
        }
    }

    let panel: Panel
    private let host: NSHostingView<AnyView>
    private let interactive: Bool
    private(set) var isVisible = false
    private var hideWork: DispatchWorkItem?
    private var lastSize: CGSize = .zero
    private var frameCount = 0
    /// 꼬리가 가리킬 전역 좌표 (보통 펫 머리 위)
    var anchor: () -> CGPoint? = { nil }
    /// 아래로 뒤집힐 때 꼬리가 가리킬 곳 (펫 발 근처)
    var lowAnchor: () -> CGPoint? = { nil }
    let tail = TailState()

    final class TailState: ObservableObject {
        @Published var x: CGFloat = 0.5
        @Published var edge: Edge = .below
    }

    init(interactive: Bool) {
        self.interactive = interactive
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = interactive
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.allowKey = interactive
        panel.ignoresMouseEvents = !interactive
        panel.contentView = host
    }

    func show<V: View>(_ view: V, autoHide: TimeInterval? = nil, focus: Bool = false) {
        hideWork?.cancel()
        // 앞 카드 입력칸의 포커스가 새 카드로 이어지지 않게 (포커스만으로 답장 대기 시간이 멈추므로)
        panel.blockAutoFocusUntil = focus ? 0 : ProcessInfo.processInfo.systemUptime + 0.35
        if panel.isKeyWindow { _ = panel.makeFirstResponder(nil) }
        host.rootView = AnyView(view.environmentObject(tail).pawmitLocalized())
        relayout(force: true)
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        isVisible = true
        if focus { panel.makeKey() }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard isVisible else { return }
        isVisible = false
        if panel.isKeyWindow { panel.resignKey() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.host.rootView = AnyView(EmptyView())
            }
        })
    }

    /// 매 프레임: 펫을 따라다니고, 내용 크기가 바뀌면 다시 잰다
    func tick() {
        guard isVisible else { return }
        frameCount += 1
        relayout(force: frameCount % 8 == 0)
    }

    func relayout(force: Bool) {
        if force {
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            // 정수로 올리고 1pt 미만 변화는 무시 (글자 측정 오차로 창이 매초 들썩이지 않게)
            let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
            if size.width > 0, abs(size.width - lastSize.width) >= 1 || abs(size.height - lastSize.height) >= 1 {
                lastSize = size
                panel.setContentSize(size)
            }
        }
        position()
    }

    private func position() {
        guard let a = anchor() else { return }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? .infinite
        var edge: Edge = .below
        var y = a.y + 2
        if y + size.height > v.maxY - 4 {
            // 위에 공간이 없으면 펫 아래쪽에 띄운다
            edge = .above
            let low = lowAnchor() ?? a
            y = low.y - size.height - 2
        }
        var x = a.x - size.width / 2
        x = min(max(x, v.minX + 6), v.maxX - size.width - 6)
        let tailX = max(0.12, min(0.88, (a.x - x) / max(size.width, 1)))
        if abs(tail.x - tailX) > 0.01 { tail.x = tailX }
        if tail.edge != edge { tail.edge = edge }
        let origin = CGPoint(x: round(x), y: round(y))
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

// MARK: - 말풍선 모양

struct BubbleShape: Shape {
    var tailX: CGFloat
    var edge: BubbleController.Edge
    var radius: CGFloat = 18
    var tail: CGFloat = 9

    /// 둥근 몸통과 꼬리를 끊김 없는 하나의 외곽선으로 그린다 (이음새가 생기지 않게)
    func path(in rect: CGRect) -> Path {
        var body = rect
        if edge == .below { body.size.height -= tail } else { body.origin.y += tail; body.size.height -= tail }
        let r = min(radius, body.height / 2, body.width / 2)
        let half: CGFloat = tail * 0.95
        let tx = min(max(rect.minX + rect.width * tailX, body.minX + r + half), body.maxX - r - half)
        var p = Path()
        // SwiftUI 좌표는 y 아래로. edge == .below → 꼬리가 아래(maxY)쪽.
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if edge == .above {
            p.addLine(to: CGPoint(x: tx - half, y: body.minY))
            p.addQuadCurve(to: CGPoint(x: tx + half * 0.15, y: rect.minY), control: CGPoint(x: tx - half * 0.25, y: body.minY - tail * 0.35))
            p.addQuadCurve(to: CGPoint(x: tx + half, y: body.minY), control: CGPoint(x: tx + half * 0.35, y: body.minY - tail * 0.25))
        }
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        if edge == .below {
            p.addLine(to: CGPoint(x: tx + half, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: tx - half * 0.15, y: rect.maxY), control: CGPoint(x: tx + half * 0.25, y: body.maxY + tail * 0.35))
            p.addQuadCurve(to: CGPoint(x: tx - half, y: body.maxY), control: CGPoint(x: tx - half * 0.35, y: body.maxY + tail * 0.25))
        }
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

struct BubbleFrame<Content: View>: View {
    @EnvironmentObject var tail: BubbleController.TailState
    var width: CGFloat?
    var compact = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = BubbleShape(tailX: tail.x, edge: tail.edge, radius: compact ? 14 : 18)
        content
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 8 : 14)
            .padding(tail.edge == .below ? .bottom : .top, 9)
            .frame(width: width)
            .fixedSize(horizontal: width == nil, vertical: true)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.97)))
            .overlay(shape.stroke(Color.primary.opacity(0.18), lineWidth: 1.2))
            .padding(4)
    }
}
