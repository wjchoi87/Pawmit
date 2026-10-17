import SwiftUI
import PawmitCore

// MARK: - 공통 스타일

enum PawTheme {
    static let allow = Color(red: 0.24, green: 0.68, blue: 0.47)
    static let deny = Color(red: 0.92, green: 0.38, blue: 0.42)
    static let accent = Color(red: 0.98, green: 0.55, blue: 0.62)
    /// 터미널 열기류 버튼 (CLI=개발자 파랑)
    static let terminal = Color(red: 0.30, green: 0.55, blue: 0.92)
    /// 닫기 같은 보조 버튼 (차분한 슬레이트)
    static let neutral = Color(red: 0.52, green: 0.53, blue: 0.58)

    /// 설정의 글씨 크기·글꼴 (Director가 설정을 읽을 때 갱신)
    nonisolated(unsafe) static var textScale: CGFloat = 1
    nonisolated(unsafe) static var fontName: String? = nil

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let s = size * textScale
        switch fontName {
        case nil, "": return .system(size: s, weight: weight, design: .rounded)
        case "system": return .system(size: s, weight: weight)
        case let name?: return .custom(name, size: s).weight(weight)
        }
    }

    static func mono() -> Font { .system(size: 11.5 * textScale, design: .monospaced) }

    /// 말풍선 폭도 글씨 크기에 맞춰 늘린다
    static func w(_ width: CGFloat) -> CGFloat { width * max(0.85, textScale) }

    /// 버튼 옆에 보여줄 단축키 (allow, deny, always, terminal, open, option) — 비어 있으면 표시 안 함
    nonisolated(unsafe) static var hints: [String: String] = [:]

    /// 본문 글씨 설정 (Director가 설정을 읽을 때 갱신)
    nonisolated(unsafe) static var hookText = PawmitConfig.MessageText(size: 13)
    nonisolated(unsafe) static var chatText = PawmitConfig.MessageText(size: 12)

    /// 본문 글꼴: 글꼴을 따로 안 골랐으면 말풍선 글꼴을 따른다. `scale`은 제목·코드처럼 본문보다 크거나 작게 쓸 때
    static func text(_ style: PawmitConfig.MessageText, _ weight: Font.Weight = .regular, scale: CGFloat = 1, mono: Bool = false) -> Font {
        let s = CGFloat(style.size) * scale * textScale
        if mono { return .system(size: s * 0.92, weight: weight, design: .monospaced) }
        switch style.fontName ?? fontName ?? "" {
        case "", "rounded": return .system(size: s, weight: weight, design: .rounded)
        case "system": return .system(size: s, weight: weight)
        case "mono": return .system(size: s * 0.92, weight: weight, design: .monospaced)
        case let name: return .custom(name, size: s).weight(weight)
        }
    }
}

/// 버튼 글자 + 작은 단축키 표시
struct KeyLabel: View {
    var title: String
    var key: String?

    init(_ title: String, _ key: String? = nil) {
        self.title = title
        self.key = key
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(L10n.t(title))
            if let key, let hint = PawTheme.hints[key], !hint.isEmpty {
                Text(hint).font(PawTheme.font(9.5, .medium)).opacity(0.65)
            }
        }
    }
}

extension PawTheme {

    static func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.25, green: 0.25, blue: 0.3)
        case .cursor: return Color(red: 0.35, green: 0.4, blue: 0.95)
        case .gemini: return Color(red: 0.3, green: 0.55, blue: 0.95)
        case .copilot: return Color(red: 0.5, green: 0.35, blue: 0.85)
        case .qwen: return Color(red: 0.45, green: 0.3, blue: 0.9)
        case .droid: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .opencode: return Color(red: 0.2, green: 0.6, blue: 0.55)
        case .kiro: return Color(red: 0.55, green: 0.4, blue: 0.95)
        case .zcode: return Color(red: 0.18, green: 0.42, blue: 0.95)
        case .generic: return .gray
        }
    }
}

struct PawButton: ButtonStyle {
    enum Kind { case primary(Color), outline(Color), plain }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(PawTheme.font(12.5, .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        let shape = RoundedRectangle(cornerRadius: 9 * PawTheme.textScale + 5, style: .continuous)
        return Group {
            switch kind {
            case .primary(let c):
                label.foregroundStyle(.white).background(shape.fill(c.opacity(configuration.isPressed ? 0.75 : 1)))
            case .outline(let c):
                // stroke 대신 바깥·안쪽 두 번 채워서 테두리를 만든다 (stroke는 가장자리 잔선이 생김)
                label.foregroundStyle(c)
                    .background(ZStack {
                        shape.fill(c.opacity(0.75))
                        shape.inset(by: 1.3).fill(Color(nsColor: .windowBackgroundColor))
                        shape.inset(by: 1.3).fill(c.opacity(configuration.isPressed ? 0.18 : 0.07))
                    })
            case .plain:
                label.foregroundStyle(.secondary).opacity(configuration.isPressed ? 0.6 : 1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct CardHeader: View {
    var agent: AgentKind
    var project: String?
    var queue: (Int, Int)?

    var body: some View {
        HStack(spacing: 6) {
            AgentBadge(agent: agent, size: 16 * PawTheme.textScale)
            Text([agent.displayName, project].compactMap { $0 }.joined(separator: " · "))
                .font(PawTheme.font(11, .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let queue, queue.1 > 1 {
                Text("\(queue.0)/\(queue.1)")
                    .font(PawTheme.font(10.5, .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

/// 내용만큼 커지다가 maxHeight부터는 스크롤. 말풍선 창은 내용 크기에 맞춰 잡히므로 높이를 재서 직접 정해 준다
/// (ScrollView만 두면 창이 내용 전체 높이로 늘거나, 반대로 잘려서 스크롤이 안 된다).
struct ScrollBox<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in Color.clear.preference(key: ScrollBoxHeight.self, value: g.size.height) })
        }
        .frame(height: min(max(height, 1), maxHeight))
        .scrollIndicators(height > maxHeight ? .visible : .hidden)
        .onPreferenceChange(ScrollBoxHeight.self) { height = ceil($0) }
    }
}

private struct ScrollBoxHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CodeBox: View {
    var text: String
    var maxHeight: CGFloat = 150

    var body: some View {
        ScrollBox(maxHeight: PawTheme.w(maxHeight)) {
            Text(text)
                .font(PawTheme.mono())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - 승인

struct PermissionCard: View {
    var agent: AgentKind
    var project: String?
    var queue: (Int, Int)?
    var summary: ToolSummary
    var canAlways: Bool
    var alwaysLabel: String?
    var onAllow: () -> Void
    var onAlways: () -> Void
    var onDeny: (String?) -> Void
    var onPass: () -> Void
    /// 입력칸을 누르면(포커스) 대기 시간 멈춤
    var onTyping: () -> Void = {}
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        BubbleFrame(width: PawTheme.w(340)) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(agent: agent, project: project, queue: queue)
                Text(summary.headline)
                    .font(PawTheme.font(15, .bold))
                ScrollBox(maxHeight: PawTheme.w(52)) {
                    Text(summary.subject)
                        .font(PawTheme.font(11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let body = summary.body, !body.isEmpty { CodeBox(text: body) }
                if let note = summary.note, !note.isEmpty {
                    ScrollBox(maxHeight: PawTheme.w(90)) {
                        MarkdownText(text: note, style: PawTheme.hookText)
                    }
                }
                if summary.risk == .high {
                    Label("되돌리기 어려운 명령일 수 있어요", systemImage: "exclamationmark.triangle.fill")
                        .font(PawTheme.font(11.5, .semibold))
                        .foregroundStyle(PawTheme.deny)
                }
                if canAlways, let alwaysLabel {
                    Text(L10n.isKorean ? "‘항상 허용’하면 다음부터 \(alwaysLabel) 은(는) 안 물어봐요"
                                       : L10n.format("With “Always Allow”, Pawmit won't ask about %@ again", alwaysLabel))
                        .font(PawTheme.font(10.5)).foregroundStyle(.tertiary)
                }
                TextField("거절 이유 (선택, 에이전트에게 전달돼요)", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .font(PawTheme.font(11.5))
                    .focused($reasonFocused)
                    .onChange(of: reasonFocused) { if reasonFocused { onTyping() } }
                HStack(spacing: 6) {
                    Button(action: onPass) { KeyLabel("터미널에서", "terminal") }.buttonStyle(PawButton(kind: .outline(PawTheme.terminal)))
                    Spacer(minLength: 2)
                    Button { onDeny(reason.isEmpty ? nil : reason) } label: { KeyLabel("거절", "deny") }
                        .buttonStyle(PawButton(kind: .outline(PawTheme.deny)))
                    if canAlways {
                        Button(action: onAlways) { KeyLabel("항상 허용", "always") }.buttonStyle(PawButton(kind: .outline(PawTheme.allow)))
                            .help("다음부터 같은 요청은 묻지 않아요")
                    }
                    Button(action: onAllow) { KeyLabel("허용", "allow") }.buttonStyle(PawButton(kind: .primary(PawTheme.allow)))
                }
            }
        }
    }
}

// MARK: - 질문 (AskUserQuestion)

final class QuestionModel: ObservableObject {
    let questions: [AgentEvent.Question]
    @Published var picked: [Int: Set<String>] = [:]
    @Published var custom: [Int: String] = [:]

    init(questions: [AgentEvent.Question]) {
        self.questions = questions
    }

    func answer(_ i: Int) -> String? {
        if let c = custom[i]?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        let labels = questions[i].options.map(\.label).filter { picked[i]?.contains($0) == true }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    var ready: Bool { questions.indices.allSatisfy { answer($0) != nil } }

    var answers: [String: String] {
        var map: [String: String] = [:]
        for (i, q) in questions.enumerated() { if let a = answer(i) { map[q.question] = a } }
        return map
    }

    func toggle(_ i: Int, _ label: String) {
        var set = picked[i] ?? []
        if questions[i].multiSelect { if set.contains(label) { set.remove(label) } else { set.insert(label) } } else { set = [label] }
        picked[i] = set
        custom[i] = nil
    }

    /// 단축키 숫자 → 아직 답 안 한 첫 질문의 n번째 선택지
    func pick(number n: Int) {
        guard !questions.isEmpty else { return }
        let i = questions.indices.first { answer($0) == nil } ?? questions.count - 1
        let opts = questions[i].options
        guard n >= 1, n <= opts.count else { return }
        toggle(i, opts[n - 1].label)
    }
}

struct QuestionCard: View {
    var agent: AgentKind
    var project: String?
    var queue: (Int, Int)?
    @ObservedObject var model: QuestionModel
    var onAnswer: ([String: String]) -> Void
    var onPass: () -> Void
    var onTyping: () -> Void = {}
    @FocusState private var customFocus: Int?

    var body: some View {
        BubbleFrame(width: PawTheme.w(340)) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(agent: agent, project: project, queue: queue)
                Text("물어볼 게 있대!").font(PawTheme.font(15, .bold))
                ScrollBox(maxHeight: PawTheme.w(330)) {
                VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.questions.enumerated()), id: \.offset) { i, q in
                    VStack(alignment: .leading, spacing: 6) {
                        if let h = q.header {
                            Text(h).font(PawTheme.font(10.5, .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(PawTheme.accent.opacity(0.18)))
                        }
                        Text(q.question).font(PawTheme.font(12.5, .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(q.options.enumerated()), id: \.offset) { n, opt in
                            let on = model.picked[i]?.contains(opt.label) == true
                            Button {
                                model.toggle(i, opt.label)
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: on ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                         : (q.multiSelect ? "square" : "circle"))
                                        .foregroundStyle(on ? PawTheme.allow : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(opt.label).font(PawTheme.font(12, .semibold))
                                        if let d = opt.description, !d.isEmpty {
                                            Text(d).font(PawTheme.font(11)).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if let prefix = PawTheme.hints["option"], !prefix.isEmpty, n < 9 {
                                        Text("\(prefix)\(n + 1)").font(PawTheme.font(9.5, .medium)).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(7)
                                .background(RoundedRectangle(cornerRadius: 9).fill(on ? PawTheme.allow.opacity(0.1) : Color.primary.opacity(0.04)))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("직접 입력…", text: Binding(get: { model.custom[i] ?? "" }, set: { model.custom[i] = $0 }))
                            .textFieldStyle(.roundedBorder).font(PawTheme.font(11.5))
                            .focused($customFocus, equals: i)
                    }
                }
                }
                .padding(.trailing, 4)
                }
                .onChange(of: customFocus) { if customFocus != nil { onTyping() } }
                HStack {
                    Button(action: onPass) { KeyLabel("터미널에서", "terminal") }.buttonStyle(PawButton(kind: .outline(PawTheme.terminal)))
                    Spacer()
                    Button { onAnswer(model.answers) } label: { KeyLabel("보내기", "allow") }
                        .buttonStyle(PawButton(kind: .primary(model.ready ? PawTheme.allow : .gray)))
                        .disabled(!model.ready)
                }
            }
        }
    }
}

// MARK: - 계획 (ExitPlanMode)

struct PlanCard: View {
    var agent: AgentKind
    var project: String?
    var queue: (Int, Int)?
    var plan: String
    var onApprove: () -> Void
    var onRevise: (String) -> Void
    var onPass: () -> Void
    var onTyping: () -> Void = {}
    @State private var feedback = ""
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        BubbleFrame(width: PawTheme.w(380)) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(agent: agent, project: project, queue: queue)
                Text("계획 세웠대! 봐줄래?").font(PawTheme.font(15, .bold))
                ScrollBox(maxHeight: PawTheme.w(260)) {
                    MarkdownText(text: plan, style: PawTheme.hookText)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
                TextField("고칠 점 (수정 요청 시)", text: $feedback).textFieldStyle(.roundedBorder).font(PawTheme.font(11.5))
                    .focused($feedbackFocused)
                    .onChange(of: feedbackFocused) { if feedbackFocused { onTyping() } }
                HStack(spacing: 6) {
                    Button(action: onPass) { KeyLabel("터미널에서", "terminal") }.buttonStyle(PawButton(kind: .outline(PawTheme.terminal)))
                    Spacer()
                    Button { onRevise(feedback.isEmpty ? L10n.t("계획을 조금 더 다듬어 줘.") : feedback) } label: { KeyLabel("수정 요청", "deny") }
                        .buttonStyle(PawButton(kind: .outline(PawTheme.deny)))
                    Button(action: onApprove) { KeyLabel("승인", "allow") }.buttonStyle(PawButton(kind: .primary(PawTheme.allow)))
                }
            }
        }
    }
}

// MARK: - 작업 끝 → 답장

struct StopCard: View {
    var agent: AgentKind
    var project: String?
    var message: String?
    var deadline: Date
    /// 답장 입력을 시작했을 때 (카운트다운 멈춤)
    var onTyping: () -> Void = {}
    var onReply: (String) -> Void
    var onOpenTerminal: () -> Void
    var onDismiss: () -> Void
    @State private var reply = ""
    @State private var typing = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        BubbleFrame(width: PawTheme.w(350)) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(agent: agent, project: project, queue: nil)
                Text("다 했어!").font(PawTheme.font(15, .bold))
                if let message, !message.isEmpty {
                    ScrollBox(maxHeight: PawTheme.w(200)) {
                        MarkdownText(text: message, style: PawTheme.hookText)
                    }
                }
                HStack(spacing: 6) {
                    TextField("이어서 시킬 말…", text: $reply, onCommit: send)
                        .textFieldStyle(.roundedBorder)
                        .font(PawTheme.font(12))
                        .focused($replyFocused)
                        // 입력칸을 누르기만 해도(포커스) 기다림 — 글자를 치기 시작할 때도
                        .onChange(of: replyFocused) { if replyFocused { startTyping() } }
                        .onChange(of: reply) { if !reply.isEmpty { startTyping() } }
                    Button("보내기", action: send).buttonStyle(PawButton(kind: .primary(reply.isEmpty ? .gray : PawTheme.allow)))
                        .disabled(reply.isEmpty)
                }
                // 남은 시간 줄: 숫자 폭을 고정하고 한 줄로만 (매초 줄바꿈이 바뀌며 말풍선 크기가 흔들리지 않게)
                HStack(spacing: 4) {
                    Image(systemName: typing ? "pause.circle" : "timer")
                    if typing {
                        Text("쓰는 동안은 기다려요")
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(ceil(deadline.timeIntervalSince(ctx.date))))
                            Text(L10n.format("%lld초", left)).monospacedDigit().frame(width: PawTheme.w(26), alignment: .trailing)
                        }
                        Text("안에 답장하면 이어서 작업해요")
                    }
                    Spacer(minLength: 0)
                }
                .font(PawTheme.font(10.5)).foregroundStyle(.tertiary)
                .lineLimit(1)
                HStack {
                    Spacer()
                    Button(action: onOpenTerminal) { KeyLabel("터미널") }.buttonStyle(PawButton(kind: .outline(PawTheme.terminal)))
                    Button(action: onDismiss) { KeyLabel("닫기", "terminal") }.buttonStyle(PawButton(kind: .outline(PawTheme.neutral)))
                }
            }
        }
    }

    /// 답장 칸을 누르거나(포커스) 글자를 치면 카운트다운을 멈춘다. 한 번 멈추면 다시 돌지 않는다.
    private func startTyping() {
        guard !typing else { return }
        typing = true
        onTyping()
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onReply(text)
    }
}

// MARK: - 알림

struct NoticeCard: View {
    var agent: AgentKind?
    var project: String?
    var title: String
    var message: String?
    var onOpenTerminal: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        BubbleFrame(width: PawTheme.w(320)) {
            VStack(alignment: .leading, spacing: 6) {
                if let agent { CardHeader(agent: agent, project: project, queue: nil) }
                Text(title).font(PawTheme.font(14, .bold))
                if let message, !message.isEmpty {
                    ScrollBox(maxHeight: PawTheme.w(170)) {
                        MarkdownText(text: message, style: PawTheme.hookText)
                    }
                }
                HStack {
                    Spacer()
                    if let onOpenTerminal { Button(action: onOpenTerminal) { KeyLabel("터미널 열기", "terminal") }.buttonStyle(PawButton(kind: .outline(PawTheme.terminal))) }
                    Button(action: onDismiss) { KeyLabel("확인", "allow") }.buttonStyle(PawButton(kind: .plain))
                }
            }
        }
    }
}

// MARK: - 말

struct SpeechBubble: View {
    var text: String

    var body: some View {
        BubbleFrame(width: nil, compact: true) {
            Text(text)
                .font(PawTheme.font(12.5, .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: PawTheme.w(220))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 채팅

final class ChatModel: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        var fromPet: Bool
        var text: String
    }

    @Published var lines: [Line] = []
    @Published var thinking = false
    @Published var draft = ""
    var petName = ""
    var provider = ""
}

struct ChatCard: View {
    @ObservedObject var model: ChatModel
    var onSend: (String) -> Void
    var onClose: () -> Void
    var onReset: () -> Void
    @FocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 0

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if model.thinking { proxy.scrollTo("thinking", anchor: .bottom) }
            else if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    var body: some View {
        BubbleFrame(width: PawTheme.w(320)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.isKorean ? "\(model.petName)랑 수다" : L10n.format("Chat with %@", model.petName)).font(PawTheme.font(13, .bold))
                    Spacer()
                    Button(action: onReset) { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("대화 새로 시작")
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if !model.lines.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.lines.suffix(200)) { line in
                                    HStack {
                                        if !line.fromPet { Spacer(minLength: 30) }
                                        Group {
                                            // 펫(AI) 답은 마크다운 설정을 따르고, 내가 쓴 말은 글자 그대로
                                            if line.fromPet {
                                                MarkdownText(text: line.text, style: PawTheme.chatText)
                                            } else {
                                                Text(line.text).font(PawTheme.text(PawTheme.chatText)).textSelection(.enabled)
                                            }
                                        }
                                            .padding(.horizontal, 9).padding(.vertical, 6)
                                            .background(RoundedRectangle(cornerRadius: 11)
                                                .fill(line.fromPet ? PawTheme.accent.opacity(0.16) : Color.primary.opacity(0.07)))
                                            .fixedSize(horizontal: false, vertical: true)
                                        if line.fromPet { Spacer(minLength: 30) }
                                    }
                                    .id(line.id)
                                }
                                if model.thinking {
                                    Text("생각 중…").font(PawTheme.font(11)).foregroundStyle(.secondary).id("thinking")
                                }
                            }
                            .padding(.trailing, 6)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChatContentHeight.self, value: g.size.height)
                            })
                        }
                        // 내용만큼 커지다가 최대 높이부터는 스크롤 (예전 대화도 위로 올려 볼 수 있게)
                        .frame(height: min(max(contentHeight, 24), PawTheme.w(260)))
                        .scrollIndicators(contentHeight > PawTheme.w(260) ? .visible : .hidden)
                        .onPreferenceChange(ChatContentHeight.self) { contentHeight = ceil($0) }
                        .onAppear { scrollToEnd(proxy) }
                        .onChange(of: model.lines.last?.text) { scrollToEnd(proxy) }
                        .onChange(of: model.thinking) { scrollToEnd(proxy) }
                    }
                }
                HStack(spacing: 6) {
                    TextField("말 걸기…", text: $model.draft, onCommit: send)
                        .textFieldStyle(.roundedBorder)
                        .font(PawTheme.font(12.5))
                        .focused($focused)
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .buttonStyle(PawButton(kind: .primary(model.draft.isEmpty ? .gray : PawTheme.accent)))
                        .disabled(model.draft.isEmpty || model.thinking)
                }
                Text(L10n.format("%@ · 행동도 시켜봐 (집에 가, 밥 먹어, 낙서해 …)", model.provider))
                    .font(PawTheme.font(10)).foregroundStyle(.tertiary)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }

    private func send() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.thinking else { return }
        model.draft = ""
        onSend(text)
    }
}

private struct ChatContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 새 버전 알림 카드 — [지금 업데이트]를 누르면 zip을 내려받아 앱을 교체하고 다시 띄운다
struct UpdateCard: View {
    @ObservedObject var model: UpdateCardModel
    var onInstall: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(L10n.format("Pawmit %@ 나왔어요", model.info.version)).font(PawTheme.font(13, .bold))
                Spacer()
            }
            if let notes = model.info.notes, !notes.isEmpty {
                Text(notes).font(PawTheme.font(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.status {
                Text(status).font(PawTheme.font(11)).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button(action: onClose) { Text("나중에") }.buttonStyle(PawButton(kind: .outline(PawTheme.neutral)))
                    .disabled(model.installing)
                Button(action: onInstall) { Text("지금 업데이트") }.buttonStyle(PawButton(kind: .primary(PawTheme.terminal)))
                    .disabled(model.installing)
            }
        }
        .padding(14)
    }
}

/// UpdateCard 관찰용 (상태 문구·설치 중 잠금)
final class UpdateCardModel: ObservableObject {
    let info: Updater.Info
    @Published var status: String?
    @Published var installing = false
    init(info: Updater.Info) { self.info = info }
}
