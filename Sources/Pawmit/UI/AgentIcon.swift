import AppKit
import SwiftUI
import PawmitCore

/// 알림 카드에서 어느 에이전트가 보낸 건지 한눈에 알아보게 하는 아이콘.
/// 그 에이전트의 앱이 설치돼 있으면 앱 아이콘을 쓰고, 없으면(CLI 전용 등) 에이전트 색 배지에 기호를 그린다.
@MainActor
enum AgentIcons {
    /// 에이전트별 앱 bundle id 후보 (앞에서부터 찾는다)
    static func bundleIDs(_ agent: AgentKind) -> [String] {
        switch agent {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .kiro: return ["dev.kiro.desktop", "com.amazon.codewhisperer"]
        case .zcode: return ["dev.zcode.app"]
        case .gemini, .copilot, .opencode, .droid, .qwen, .generic: return []
        }
    }

    /// 배지에 그릴 기호 (SF Symbol, 없으면 글자)
    static func glyph(_ agent: AgentKind) -> (symbol: String?, text: String) {
        switch agent {
        case .claude: return ("asterisk", "C")
        case .codex: return ("chevron.left.forwardslash.chevron.right", "X")
        case .cursor: return ("cursorarrow", "C")
        case .gemini: return ("sparkle", "G")
        case .copilot: return ("eyeglasses", "P")
        case .opencode: return ("terminal", "O")
        case .kiro: return (nil, "K")
        case .droid: return ("cpu", "D")
        case .qwen: return (nil, "Q")
        case .zcode: return (nil, "Z")
        case .generic: return ("pawprint.fill", "A")
        }
    }

    /// 앱 찾기는 한 번만 (카드는 매 tick 다시 그려진다)
    private static var cache: [AgentKind: NSImage?] = [:]

    static func appIcon(_ agent: AgentKind) -> NSImage? {
        if let hit = cache[agent] { return hit }
        let icon = bundleIDs(agent).lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[agent] = .some(icon)
        return icon
    }
}

struct AgentBadge: View {
    var agent: AgentKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = AgentIcons.appIcon(agent) {
                // 앱 아이콘은 가장자리에 투명 여백이 있어 조금 크게 그려야 배지와 크기가 맞는다
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.2, height: size * 1.2)
                    .frame(width: size, height: size)
            } else {
                let g = AgentIcons.glyph(agent)
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(PawTheme.agentColor(agent))
                    .frame(width: size, height: size)
                    .overlay {
                        if let symbol = g.symbol {
                            Image(systemName: symbol).font(.system(size: size * 0.56, weight: .bold))
                        } else {
                            Text(g.text).font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(agent.displayName)
    }
}
