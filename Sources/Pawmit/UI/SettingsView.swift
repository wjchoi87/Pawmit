import AppKit
import SwiftUI
import ServiceManagement
import PawmitCore

/// 설정 창과 감독(Director) 사이 다리. 값을 바꾸면 바로 적용하고, 파일 저장은 잠깐 모았다가 한 번에 한다.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: PawmitConfig
    @Published var personality = ""
    @Published var agentRows: [AgentRow] = []
    @Published var launchAtLogin = false
    @Published var accessibility = false
    @Published var petPreview: NSImage?
    @Published var pane: SettingsPane = .pet

    struct AgentRow: Identifiable {
        var id: String { agent.rawValue }
        var agent: AgentKind
        var status: String
        var installed: Bool
        var available: Bool
        var note: String?
    }

    weak var director: Director?
    private var saveWork: DispatchWorkItem?

    init(director: Director) {
        self.director = director
        config = director.config
        refresh()
    }

    func refresh() {
        guard let d = director else { return }
        config = d.config
        personality = d.personalitySummary
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibility = AXIsProcessTrusted()
        agentRows = HookInstaller.targets(config: config).map { t in
            let s = HookInstaller.status(t)
            let label: String
            switch s {
            case .installed: label = L10n.t("연결됨")
            case .notInstalled: label = L10n.t("연결 안 됨")
            case .outdated: label = L10n.t("업데이트 필요")
            case .agentMissing: label = L10n.t("설치 안 됨")
            case .error(let e): label = L10n.format("오류: %@", e)
            }
            return AgentRow(agent: t.agent, status: label, installed: s == .installed, available: s != .agentMissing, note: t.note)
        }
        petPreview = d.previewImage(for: config.pet)
    }

    /// 값 하나 바꾸기: 즉시 적용, 저장은 0.4초 모아서
    func update(_ change: (inout PawmitConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        director?.applyConfig(c, save: false)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in try? self?.config.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        if c.pet != petPreviewID {
            petPreviewID = c.pet
            petPreview = director?.previewImage(for: c.pet)
        }
    }

    private var petPreviewID = ""

    func binding<T>(_ key: WritableKeyPath<PawmitConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: key] }, set: { v in self.update { $0[keyPath: key] = v } })
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case pet, bubble, behavior, agents, shortcuts, chat, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pet: return L10n.t("펫")
        case .bubble: return L10n.t("말풍선")
        case .behavior: return L10n.t("행동")
        case .agents: return L10n.t("에이전트")
        case .shortcuts: return L10n.t("단축키")
        case .chat: return L10n.t("대화")
        case .general: return L10n.t("일반")
        }
    }
    var symbol: String {
        switch self {
        case .pet: return "pawprint.fill"
        case .bubble: return "text.bubble"
        case .behavior: return "figure.walk"
        case .agents: return "terminal"
        case .shortcuts: return "keyboard"
        case .chat: return "bubble.left.and.bubble.right"
        case .general: return "gearshape"
        }
    }
}

/// 시스템 설정처럼 왼쪽 목록 + 오른쪽 폼. 폼은 grouped 스타일 하나로 여백을 맞추고 바깥 여백을 따로 주지 않는다.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch model.pane {
                case .pet: PetTab(model: model)
                case .bubble: BubbleTab(model: model)
                case .behavior: BehaviorTab(model: model)
                case .agents: AgentTab(model: model)
                case .shortcuts: ShortcutTab(model: model)
                case .chat: ChatTab(model: model)
                case .general: GeneralTab(model: model)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { p in
                let selected = model.pane == p
                Button { model.pane = p } label: {
                    // 심볼마다 폭이 달라 텍스트 시작점이 들쑥날쑥하지 않게 아이콘 칸 폭을 고정
                    HStack(spacing: 8) {
                        Image(systemName: p.symbol)
                            .frame(width: 20, alignment: .center)
                        Text(p.title)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 180)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

/// 값이 오른쪽에 붙는 슬라이더 행 (값 칸 폭을 맞춰 줄이 흔들리지 않게)
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    let format: (Double) -> String

    var body: some View {
        LabeledContent(L10n.t(title)) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(minWidth: 180)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - 펫

private struct PetTab: View {
    @ObservedObject var model: SettingsModel
    /// 스타일을 고칠 펫 (비우면 메인 펫)
    @State private var styleTarget = ""

    /// 친구로 데려다니기 체크박스 (기본 펫·커스텀 펫 그룹에서 공용)
    private func friendToggle(_ e: PetRoster.Entry) -> some View {
        Toggle(e.name, isOn: Binding(get: { model.config.friends.contains(e.id) }, set: { on in
            model.update { c in
                if on { if !c.friends.contains(e.id), c.friends.count < 4 { c.friends.append(e.id) } } else { c.friends.removeAll { $0 == e.id } }
            }
        }))
        .toggleStyle(.checkbox)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    if let img = model.petPreview {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 96, height: 96)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.personality).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("성격 다시 뽑기 🎲") { model.director?.rerollPersonality(); model.refresh() }.controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Picker("메인 펫", selection: model.binding(\.pet)) {
                    Section("기본 펫") {
                        ForEach(PetRoster.builtins, id: \.id) { e in
                            Text(e.name).tag(e.id)
                        }
                    }
                    let custom = PetRoster.customPacks()
                    if !custom.isEmpty {
                        Section("커스텀 펫") {
                            ForEach(custom, id: \.id) { e in
                                Text(e.name).tag(e.id)
                            }
                        }
                    }
                    let codex = PetRoster.codexPets()
                    if !codex.isEmpty {
                        Section("Codex") {
                            ForEach(codex, id: \.id) { e in
                                Text(e.name).tag(e.id)
                            }
                        }
                    }
                }
                TextField("이름", text: Binding(get: { model.config.petName ?? "" },
                                               set: { v in model.update { $0.petName = v.isEmpty ? nil : v } }), prompt: Text("비우면 기본 이름"))
                if model.config.pet == "cat" {
                    Picker("털색", selection: model.binding(\.catCoat)) {
                        Text("치즈").tag("cheese"); Text("회색").tag("gray"); Text("검정").tag("black")
                        Text("흰색").tag("white"); Text("턱시도").tag("tuxedo")
                    }
                }
                SliderRow(title: "크기", value: model.binding(\.size), range: 0.6...1.8) { String(format: "%.0f%%", $0 * 100) }
            }
            Section {
                LabeledContent("새로 만들기") {
                    Button("커스텀 펫 만들기…") { model.director?.openWizard() }
                }
                if model.director?.isMakerPet(model.config.pet) == true {
                    LabeledContent("지금 펫") {
                        Button("메이커로 고치기…") { model.director?.openMaker(editing: model.config.pet) }
                    }
                }
                LabeledContent("주고받기") {
                    HStack(spacing: 8) {
                        Button("모두 내보내기…") { model.director?.exportAllPetsWithPanel() }
                            .help("커스텀 펫 전부와 펫 설정(기본 펫 스타일·메인 펫·친구)을 파일 하나로 백업해요")
                        Button("지금 펫만…") { model.director?.exportPetWithPanel(id: model.config.pet) }
                            .help("지금 펫을 .pawmitpet 파일로 저장해 다른 사람에게 줄 수 있어요")
                        Button("가져오기…") { model.director?.importPetWithPanel(); model.refresh() }
                            .help("받은 .pawmitpet 파일이나 백업 파일로 펫을 데려와요")
                    }
                }
            } header: {
                Text("만들기·주고받기")
            }
            let target = styleTarget.isEmpty || !([model.config.pet] + model.config.friends).contains(styleTarget) ? model.config.pet : styleTarget
            Section {
                let names = Dictionary((PetRoster.builtins + PetRoster.customPacks() + PetRoster.codexPets()).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                Picker("고칠 펫", selection: Binding(get: { target }, set: { styleTarget = $0 })) {
                    Text(L10n.format("%@ (메인)", names[model.config.pet] ?? model.config.pet)).tag(model.config.pet)
                    ForEach(model.config.friends.filter { $0 != model.config.pet }, id: \.self) { Text(L10n.format("%@ (친구)", names[$0] ?? $0)).tag($0) }
                }
                if model.config.petStyles[target] != nil {
                    LabeledContent("") { Button("이 펫 스타일 처음으로") { model.update { $0.petStyles[target] = nil } } }
                }
            } header: {
                Text("스타일")
            } footer: {
                Text("성격·말투·색은 생김새와 따로 정해요. 기본 펫에도 똑같이 적용돼요.")
            }
            StyleEditor(style: Binding(get: { PetStyles.effective(target, config: model.config) }, set: { st in
                            model.update { $0.petStyles[target] = st.isEmpty ? nil : st }
                        }),
                        interjection: Binding(get: { PetStyles.effective(target, config: model.config).speech?.prefix ?? "" }, set: { v in
                            model.update { c in
                                var st = PetStyles.effective(target, config: c)
                                var sp = st.speech ?? SpeechStyle()
                                sp.prefix = v.isEmpty ? nil : String(v.prefix(12))
                                st.speech = sp == SpeechStyle() ? nil : sp
                                c.petStyles[target] = st.isEmpty ? nil : st
                            }
                        }),
                        showColors: true, colorFields: PetStyles.colorFields(for: target, config: model.config), inForm: true)
            Section {
                let cols = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                    ForEach(PetRoster.builtins.filter { $0.id != model.config.pet }, id: \.id) { e in
                        friendToggle(e)
                    }
                }
                .padding(.vertical, 2)
                let custom = PetRoster.customPacks().filter { $0.id != model.config.pet }
                if !custom.isEmpty {
                    Divider()
                    Text("커스텀 펫").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(custom, id: \.id) { e in
                            friendToggle(e)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("같이 다니는 친구")
            } footer: {
                Text("최대 4마리. 친구들은 서로 놀고, 모니터를 건널 때 도와줘요.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 말풍선

private struct BubbleTab: View {
    @ObservedObject var model: SettingsModel

    /// 미리보기에 쓸 호칭 (비우면 현재 언어의 기본 호칭)
    private var title: String { PawmitConfig.displayTitle(model.config.userTitle) }

    var body: some View {
        Form {
            Section {
                // 기본 호칭은 칸을 비워 두고 자리표시자로 현재 언어의 기본 호칭을 보여 준다
                TextField("펫이 부르는 내 호칭", text: Binding(get: {
                    PawmitConfig.cleanTitle(model.config.userTitle) == PawmitConfig.defaultUserTitle ? "" : model.config.userTitle
                }, set: { v in
                    let one = String(v.replacingOccurrences(of: "\n", with: " ").prefix(20))
                    model.update { $0.userTitle = one.trimmingCharacters(in: .whitespaces).isEmpty ? PawmitConfig.defaultUserTitle : one }
                }), prompt: Text(PawmitConfig.localizedDefaultTitle))
            } footer: {
                Text(L10n.format("펫 혼잣말과 대화, 펫에서 거절할 때 에이전트에게 남기는 말에 써요. 비우면 ‘%@’.", PawmitConfig.localizedDefaultTitle))
            }
            Section {
                SliderRow(title: "글씨 크기", value: model.binding(\.textScale), range: 0.8...1.6) { String(format: "%.0f%%", $0 * 100) }
                Picker("글꼴", selection: Binding(get: { model.config.fontName ?? "" }, set: { v in model.update { $0.fontName = v.isEmpty ? nil : v } })) {
                    Text("둥근 기본 글꼴").tag("")
                    Text("시스템 기본 글꼴").tag("system")
                    ForEach(Director.installedFonts(), id: \.0) { f in Text(f.1).tag(f.0) }
                    if let cur = model.config.fontName, !cur.isEmpty, cur != "system", !Director.installedFonts().contains(where: { $0.0 == cur }) {
                        Text(cur).tag(cur)
                    }
                }
                LabeledContent("") { Button("다른 글꼴 고르기…") { model.director?.openFontPanel() } }
            }
            Section("미리보기") {
                HStack {
                    Text(L10n.format("%@, 명령 실행해도 돼? 🐾", title))
                        .font(PawTheme.previewFont(size: 15 * model.config.textScale, name: model.config.fontName))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15)))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
            MessageTextSection(model: model, key: \.hookText, title: L10n.t("hook 알림 글씨"),
                               footer: L10n.t("작업 끝 메시지·알림·계획·승인 설명에 써요."),
                               sample: L10n.format("**%@, 다 했어요!** 바꾼 것:\n- `Cards.swift` 본문 글씨를 진하게\n- 마크다운으로 보기\n\n| 항목 | 결과 |\n|---|---|\n| 빌드 | 통과 |", title))
            MessageTextSection(model: model, key: \.chatText, title: L10n.t("대화 글씨"),
                               footer: L10n.t("펫과 나누는 대화에 써요. 마크다운은 펫(AI)의 답에만 적용돼요."),
                               sample: L10n.format("%@, 오늘은 **산책** 어때? 🐾\n1. 물 마시기\n2. `기지개` 켜기", title))
        }
        .formStyle(.grouped)
    }
}

/// hook 알림 / 대화 본문 글씨: 글꼴·크기·마크다운
private struct MessageTextSection: View {
    @ObservedObject var model: SettingsModel
    let key: WritableKeyPath<PawmitConfig, PawmitConfig.MessageText>
    let title: String
    let footer: String
    let sample: String

    var body: some View {
        let style = model.config[keyPath: key]
        Section {
            Picker("글꼴", selection: Binding(get: { style.fontName ?? "" }, set: { v in
                model.update { $0[keyPath: key].fontName = v.isEmpty ? nil : v }
            })) {
                Text("말풍선 글꼴 따르기").tag("")
                Text("둥근 기본 글꼴").tag("rounded")
                Text("시스템 기본 글꼴").tag("system")
                Text("고정폭 글꼴").tag("mono")
                ForEach(Director.installedFonts(), id: \.0) { f in Text(f.1).tag(f.0) }
                if let cur = style.fontName, !["", "rounded", "system", "mono"].contains(cur),
                   !Director.installedFonts().contains(where: { $0.0 == cur }) {
                    Text(cur).tag(cur)
                }
            }
            SliderRow(title: "글씨 크기", value: model.binding(key.appending(path: \.size)), range: 10...20, step: 0.5) {
                String(format: "%.1fpt", $0)
            }
            Toggle("마크다운으로 보기 (굵게·목록·코드·표)", isOn: model.binding(key.appending(path: \.markdown)))
            HStack {
                MarkdownText(text: sample, style: style)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 340, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15)))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

// MARK: - 행동

private struct BehaviorTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("돌아다니는 범위", selection: model.binding(\.roam)) {
                    Text("모든 화면 전체").tag("free")
                    Text("화면 아래쪽만").tag("ground")
                }
                SliderRow(title: "이동 속도", value: model.binding(\.speed), range: 0.5...2, step: 0.1) { L10n.format("%.1f배", $0) }
                Picker("성능", selection: model.binding(\.performance)) {
                    Text("부드럽게").tag("smooth"); Text("균형").tag("balanced"); Text("절전").tag("saver")
                }
                Toggle("휴지통 뒤지기", isOn: model.binding(\.trashRummage))
                Toggle("효과음", isOn: model.binding(\.sounds))
            } footer: {
                Text("절전은 프레임을 낮추고 펫 그림자 같은 꾸밈을 빼요.")
            }
            Section {
                Toggle("낙서하기", isOn: model.binding(\.doodles))
                Picker("낙서 위치", selection: model.binding(\.doodleLayer)) {
                    Text("모든 창 위 (클릭은 통과)").tag("overlay")
                    Text("바탕화면 (앱 창 뒤)").tag("desktop")
                }
                SliderRow(title: "낙서 유지 시간", value: model.binding(\.doodleSeconds), range: 10...60, step: 5) { L10n.format("%lld초", Int($0)) }
                LabeledContent("") {
                    Button("지금 모든 낙서 지우기", role: .destructive) { model.director?.clearAllDoodles() }
                }
            } header: {
                Text("낙서")
            } footer: {
                Text("낙서는 이 시간 동안 점점 흐려지다가 저절로 지워져요. 메뉴바 집 메뉴와 낙서 우클릭에서도 바로 지울 수 있어요.")
            }
            Section {
                Toggle("시스템 상태를 모습에 반영", isOn: model.binding(\.systemReactive))
                Picker("가끔 상태 알려주기", selection: model.binding(\.statusReportMinutes)) {
                    Text("끔").tag(0.0); Text("15분마다").tag(15.0); Text("30분마다").tag(30.0); Text("45분마다").tag(45.0); Text("1시간마다").tag(60.0)
                }
            } header: {
                Text("시스템 상태")
            } footer: {
                Text("CPU가 바쁘면 더워하고, 메모리가 차면 느려지고, 디스크가 차면 통통해져요. 온도(℃)·속도(km/h)·몸무게(GB)로 알려줘요.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 에이전트

private struct AgentTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.agentRows) { row in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(row.status).font(.callout).foregroundStyle(row.installed ? Color.green : Color.secondary)
                            if row.available {
                                Button(row.installed ? L10n.t("해제") : L10n.t("연결")) {
                                    model.director?.toggleAgent(row.agent)
                                    model.refresh()
                                }
                                .controlSize(.small)
                                .frame(minWidth: 52)
                            }
                        }
                    } label: {
                        Label { Text(row.agent.displayName) } icon: { AgentBadge(agent: row.agent, size: 18) }
                    }
                    .help(row.note ?? "")
                }
            } header: {
                Text("연결")
            } footer: {
                Text("연결하면 바꿀 내용을 보여주고 원본을 ~/.pawmit/backups에 백업한 뒤 각 에이전트 설정에 hook을 더해요. 다른 hook은 건드리지 않아요.")
            }
            Section {
                Toggle("방해 금지", isOn: model.binding(\.quietMode))
                SliderRow(title: "작업 끝나면 답장 기다리기", value: model.binding(\.stopReplySeconds), range: 0...120, step: 5) {
                    $0 == 0 ? L10n.t("끔") : L10n.format("%lld초", Int($0))
                }
                SliderRow(title: "승인 말풍선 대기", value: model.binding(\.permissionTimeoutSeconds), range: 30...570, step: 10) { L10n.format("%lld초", Int($0)) }
                Toggle("Copilot·Droid 읽기 전용 도구는 묻지 않기", isOn: model.binding(\.readonlyPassthrough))
                Toggle("Cursor 셸·MCP 명령도 펫이 승인", isOn: model.binding(\.cursorShellApproval))
            } header: {
                Text("승인·답장")
            } footer: {
                Text("방해 금지를 켜면 말풍선 대신 터미널로 바로 넘겨요. Cursor 승인을 켜면 모든 셸 명령이 펫을 거쳐요. 바꾼 뒤 ‘업데이트 필요’가 뜨면 다시 연결해 주세요.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 단축키

private struct ShortcutTab: View {
    @ObservedObject var model: SettingsModel

    private func row(_ title: String, _ key: WritableKeyPath<PawmitConfig, String>) -> some View {
        let text = model.config[keyPath: key]
        let ok = HotKeyCenter.Combo.parse(text) != nil
        return LabeledContent(title) {
            HStack(spacing: 10) {
                TextField("", text: model.binding(key), prompt: Text("ctrl+opt+y")).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 150)
                Text(ok ? (HotKeyCenter.Combo.parse(text)?.label ?? "") : L10n.t("형식 오류"))
                    .foregroundStyle(ok ? Color.secondary : Color.red).frame(width: 64, alignment: .leading)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("단축키 사용", isOn: model.binding(\.shortcuts.enabled))
            } footer: {
                Text("승인류 단축키는 말풍선이 떠 있을 때만 잡아서 다른 앱 단축키와 부딪히지 않아요.")
            }
            Section {
                row(L10n.t("허용 · 보내기 · 승인"), \.shortcuts.allow)
                row(L10n.t("거절 · 수정 요청"), \.shortcuts.deny)
                row(L10n.t("항상 허용"), \.shortcuts.always)
                row(L10n.t("터미널로 넘기기 · 닫기"), \.shortcuts.terminal)
                row(L10n.t("말풍선 열기 (항상)"), \.shortcuts.open)
                LabeledContent("질문 선택지 앞 조합") {
                    HStack(spacing: 10) {
                        TextField("", text: model.binding(\.shortcuts.optionPrefix), prompt: Text("ctrl+opt")).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 150)
                        Text("+ 1~9").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    }
                }
            } footer: {
                Text("ctrl, opt, cmd, shift와 글자·숫자를 +로 이어 적어요. 예) ctrl+opt+y")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 대화

private struct ChatTab: View {
    @ObservedObject var model: SettingsModel
    @State private var models: [String] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var modelSource: String?
    @State private var keyDraft = ""
    @State private var keyVersion = 0
    @State private var testing = false
    @State private var testResult: String?
    @State private var adding = false
    @State private var draftName = ""
    @State private var draftStyle: ChatAPIStyle = .openai
    @State private var draftURL = ""
    @State private var draftKey = ""
    @State private var draftNeedsKey = true

    private var all: [ChatProviderInfo] { ChatProviders.all(custom: model.config.chat.customProviders) }
    private var providerID: String { model.config.chat.providerID }
    private var info: ChatProviderInfo? { ChatProviders.provider(providerID, custom: model.config.chat.customProviders) }

    var body: some View {
        Form {
            Section("대화에 쓸 AI") {
                Picker("제공자", selection: Binding(get: { providerID }, set: { v in model.update { $0.chat.provider = v } })) {
                    Text("자동 (Claude CLI → Codex CLI)").tag("auto")
                    ForEach(ChatProviderInfo.Group.allCases, id: \.self) { g in
                        let items = all.filter { $0.group == g }
                        if !items.isEmpty {
                            Section(g.displayName) { ForEach(items) { Text($0.name).tag($0.id) } }
                        }
                    }
                    Text("끄기").tag("off")
                }
                if let info { detail(info) }
            }
            Section("커스텀 제공자") {
                ForEach(model.config.chat.customProviders) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                            Text("\(c.style.label) · \(c.baseURL)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("삭제", role: .destructive) { removeCustom(c) }.controlSize(.small)
                    }
                }
                if adding {
                    TextField("이름", text: $draftName)
                    Picker("방식", selection: $draftStyle) {
                        ForEach(ChatAPIStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Base URL (예: https://llm.example.com/v1)", text: $draftURL)
                    Toggle("API 키 필요", isOn: $draftNeedsKey)
                    if draftNeedsKey { SecureField("API 키 (키체인에 저장)", text: $draftKey) }
                    if insecure(draftURL, needsKey: draftNeedsKey) {
                        Text("http 주소는 API 키가 암호화되지 않고 전송돼요. https를 써 주세요.").font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("취소") { adding = false }
                        Spacer()
                        Button("추가") { addCustom() }
                            .disabled(draftName.isEmpty || URL(string: draftURL)?.scheme == nil)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button { adding = true; draftNeedsKey = true } label: { Label("제공자 추가", systemImage: "plus") }
                }
            }
            Section {
                pathField("claude", \.chat.claudePath)
                pathField("codex", \.chat.codexPath)
                pathField("gemini", \.chat.geminiPath)
            } header: {
                Text("CLI 실행 파일")
            } footer: {
                Text("비우면 자동으로 찾아요. CLI는 이미 로그인한 계정을 쓰고, API 키는 macOS 키체인에만 보관해요(설정 파일에 저장하지 않음). 펫 대화에는 파일·명령 도구와 hook이 꺼져 있어요.")
            }
        }
        .formStyle(.grouped)
        .task(id: "\(providerID)#\(keyVersion)") { await loadModels() }
    }

    @ViewBuilder
    private func detail(_ info: ChatProviderInfo) -> some View {
        if case .api = info.kind, info.needsKey {
            let saved = ChatKeychain().key(for: info.id) != nil
            HStack {
                SecureField(saved ? L10n.t("키체인에 저장됨 — 바꾸려면 새 키 입력") : L10n.t("API 키"), text: $keyDraft)
                Button("저장") { saveKey(info) }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved { Button("지우기", role: .destructive) { try? ChatKeychain().setKey(nil, for: info.id); keyVersion += 1 } }
            }
            .id(keyVersion)
            if let page = info.keyPage, let url = URL(string: page) {
                Link("키 발급 페이지 열기", destination: url).font(.caption)
            }
        }
        LabeledContent {
            // Picker는 내용 폭에 맞추고 새로고침을 바로 옆에 붙인다 (고정 최소폭이면 오른쪽 정렬돼 사이가 벌어진다)
            HStack(spacing: 2) {
                Picker("", selection: Binding(get: { model.config.chat.models[info.id] ?? "" }, set: { v in
                    model.update { $0.chat.models[info.id] = v.isEmpty ? nil : v }
                })) {
                    Text(autoLabel(info)).tag("")
                    let current = model.config.chat.models[info.id] ?? ""
                    if !current.isEmpty, !models.contains(current) { Text(current).tag(current) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                ZStack {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { keyVersion += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("모델 목록 다시 불러오기")
                    }
                }
                .frame(width: 22, height: 22)
            }
        } label: {
            Text("모델")
            if let modelSource { Text(modelSource) }
        }
        TextField("모델 직접 입력", text: Binding(get: { model.config.chat.models[info.id] ?? "" }, set: { v in
            model.update { $0.chat.models[info.id] = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v.trimmingCharacters(in: .whitespaces) }
        }))
        if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
        HStack {
            Button(testing ? L10n.t("물어보는 중…") : L10n.t("대화 테스트")) { test() }.disabled(testing)
            if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private func autoLabel(_ info: ChatProviderInfo) -> String {
        if let d = info.defaultModel { return L10n.format("기본 (%@)", d) }
        switch info.kind {
        case .cli: return L10n.t("CLI 기본 모델")
        case .api: return L10n.t("자동 (빠른 모델)")
        }
    }

    private func pathField(_ name: String, _ key: WritableKeyPath<PawmitConfig, String?>) -> some View {
        TextField(name, text: Binding(get: { model.config[keyPath: key] ?? "" }, set: { v in
            model.update { $0[keyPath: key] = v.isEmpty ? nil : v }
        }), prompt: Text("자동"))
    }

    private func insecure(_ url: String, needsKey: Bool) -> Bool {
        needsKey && url.lowercased().hasPrefix("http://") && !ChatProviders.isLocal(url)
    }

    private func loadModels() async {
        guard let info else { models = []; modelSource = nil; return }
        loading = true
        loadError = nil
        modelSource = nil
        defer { loading = false }
        do {
            models = try await ChatService.models(for: info)
            modelSource = Self.sourceLabel(info, count: models.count)
        } catch {
            models = []
            loadError = L10n.format("모델 목록을 못 불러왔어요: %@", error.localizedDescription)
        }
    }

    /// 목록이 어디서 왔는지 그대로 보여준다 (실제 조회인지 고정 목록인지 헷갈리지 않게)
    private static func sourceLabel(_ info: ChatProviderInfo, count: Int) -> String {
        switch info.kind {
        case .cli("claude"):
            return L10n.t("Claude CLI는 모델 목록을 주지 않아 별칭을 보여줘요 (항상 최신 버전)")
        case .cli("codex"):
            return count > 0 ? L10n.format("Codex가 받아 둔 목록에서 %lld개", count) : L10n.t("Codex 모델 목록이 아직 없어요 — codex를 한 번 실행해 주세요")
        case .cli:
            return L10n.t("이 CLI는 모델 목록을 주지 않아요 — 직접 입력해 주세요")
        case .api:
            let host = info.baseURL.flatMap { URL(string: $0)?.host } ?? "API"
            let time = Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: L10n.languageCode)))
            return L10n.format("%@에서 %lld개 불러옴 · %@", host, count, time)
        }
    }

    private func saveKey(_ info: ChatProviderInfo) {
        do {
            try ChatKeychain().setKey(keyDraft, for: info.id)
            keyDraft = ""
            keyVersion += 1
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let chat = ChatService(config: model.config, sessionID: nil)
        chat.ask(L10n.t("한 문장으로 인사해 줘."), persona: L10n.t("너는 귀여운 데스크탑 펫이야. 한국어 반말로 아주 짧게 대답해."), onDelta: { _ in }) { text, err in
            testing = false
            testResult = text.map { "✓ \($0)" } ?? "✗ \(err ?? L10n.t("실패"))"
            _ = chat
        }
    }

    private func addCustom() {
        let c = CustomChatProvider(name: draftName.trimmingCharacters(in: .whitespaces), style: draftStyle,
                                   baseURL: draftURL.trimmingCharacters(in: .whitespaces), needsKey: draftNeedsKey)
        if draftNeedsKey, !draftKey.isEmpty { try? ChatKeychain().setKey(draftKey, for: c.providerID) }
        model.update { cfg in
            cfg.chat.customProviders.append(c)
            cfg.chat.provider = c.providerID
        }
        adding = false
        draftName = ""; draftURL = ""; draftKey = ""
        keyVersion += 1
    }

    private func removeCustom(_ c: CustomChatProvider) {
        try? ChatKeychain().setKey(nil, for: c.providerID)
        model.update { cfg in
            cfg.chat.customProviders.removeAll { $0.id == c.id }
            cfg.chat.models.removeValue(forKey: c.providerID)
            if cfg.chat.providerID == c.providerID { cfg.chat.provider = "auto" }
        }
    }
}

// MARK: - 일반

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // 바꾸면 Director.applyConfig → applyLanguage로 창을 유지한 채 바로 적용된다
                Picker("언어", selection: Binding(
                    get: { AppLanguage.from(config: model.config.language) },
                    set: { v in model.update { $0.language = v.rawValue } })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("로그인 시 실행", isOn: Binding(get: { model.launchAtLogin }, set: { on in
                    model.director?.setLaunchAtLogin(on)
                    model.refresh()
                }))
                LabeledContent("Dock 휴지통 찾기") {
                    if model.accessibility { Text("허용됨").foregroundStyle(.green) } else {
                        Button("손쉬운 사용 권한 요청") { model.director?.requestAccessibility() }
                    }
                }
            }
            Section("파일") {
                LabeledContent("설정") { Button("열기") { NSWorkspace.shared.open(PawmitPaths.config) } }
                LabeledContent("펫 폴더") { Button("열기") { NSWorkspace.shared.open(PawmitPaths.petsDir) } }
                LabeledContent("로그") { Button("열기") { NSWorkspace.shared.open(PawmitPaths.log) } }
            }
            Section("업데이트") {
                TextField("저장소 주소 (https://github.com/owner/Pawmit) 또는 update.json URL",
                          text: Binding(get: { model.config.updateURL ?? "" },
                                        // 비우면 ""로 저장 — nil이면 다시 읽을 때 기본 주소로 돌아가 끌 수 없다
                                        set: { v in model.update { $0.updateURL = v.trimmingCharacters(in: .whitespaces).isEmpty ? "" : v } }),
                          prompt: Text("비우면 자동 업데이트 끔"))
                    .font(.callout)
                Text("GitHub 저장소 주소를 넣으면 최신 Release 태그와 첨부 zip(Pawmit-버전.zip)으로 확인해요.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("새 버전 확인") {
                    Button("지금 확인") { model.director?.checkForUpdates(auto: false) }
                        .help("새 버전이 있으면 말풍선으로 알려줘요. 실행 중에도 주 1회 자동으로 확인해요.")
                }
            }
            Section {
                LabeledContent("버전", value: "Pawmit \(Updater.currentVersion)")
            } header: {
                Text("정보")
            } footer: {
                Text("데스크탑 펫 + 코딩 에이전트 승인 도우미. 가져온 오픈소스와 라이선스는 THIRD_PARTY_NOTICES.md에 있어요.")
            }
        }
        .formStyle(.grouped)
    }
}

extension PawTheme {
    static func previewFont(size: CGFloat, name: String?) -> Font {
        switch name {
        case nil, "": return .system(size: size, weight: .semibold, design: .rounded)
        case "system": return .system(size: size, weight: .semibold)
        case let n?: return .custom(n, size: size).weight(.semibold)
        }
    }
}

/// 설정 창
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?

    func show(director: Director) {
        if window == nil {
            let model = SettingsModel(director: director)
            let host = NSHostingController(rootView: SettingsView(model: model).pawmitLocalized())
            let w = NSWindow(contentViewController: host)
            w.title = L10n.t("Pawmit 설정")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 620))
            w.center()
            window = w
            self.model = model
        }
        model?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() { model?.refresh() }

    /// 언어가 바뀌면 창은 그대로 두고 제목·내용만 다시 그린다
    func languageChanged() {
        window?.title = L10n.t("Pawmit 설정")
        model?.refresh()
    }

    func select(_ pane: SettingsPane) { model?.pane = pane }
}
