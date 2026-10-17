import AppKit
import SwiftUI
import PawmitCore

/// 펫 메이커 창: 부위 목록 · 그리기 캔버스 · 실시간 미리보기 / 얼굴 / AI 초안 / 스타일
struct MakerView: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        VStack(spacing: 0) {
            MakerTopBar(model: model)
            Divider()
            HStack(spacing: 0) {
                MakerPartList(model: model).frame(width: 190)
                Divider()
                VStack(spacing: 8) {
                    MakerToolBar(model: model)
                    MakerCanvas(model: model)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                                if let url { DispatchQueue.main.async { model.importImage(url) } }
                            }
                            return true
                        }
                    Text(model.message ?? hint).font(.callout).foregroundStyle(model.message == nil ? .secondary : .primary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                Divider()
                MakerSidePanel(model: model).frame(width: 300)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }

    private var hint: String {
        switch model.tool {
        case .pen: return L10n.format("%@에 그려요. 손을 떼면 매끈한 모양으로 닫혀요. 그림 파일을 캔버스에 끌어다 놓아도 돼요.", model.label(model.selected))
        case .ellipse: return L10n.format("끌어서 동그라미를 %@에 더해요.", model.label(model.selected))
        case .move: return L10n.t("부위를 끌어 옮기고, 주황 점(관절)을 끌어 어디를 중심으로 움직일지 정해요.")
        case .face: return L10n.t("눈 사이 가운데를 눌러 얼굴 위치를 정해요. 표정은 자동으로 바뀌어요.")
        case .erase: return L10n.t("모양을 눌러 지워요.")
        }
    }
}

private struct MakerTopBar: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        HStack(spacing: 12) {
            TextField("이름", text: Binding(get: { model.spec.name }, set: { model.rename($0) }))
                .textFieldStyle(.roundedBorder).frame(width: 170)
            Picker("", selection: Binding(get: { model.spec.skeleton }, set: { id in confirmSkeleton(id) })) {
                ForEach(Skeleton.all, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented).frame(width: 300)
            .help("몸 구조. 바꾸면 그 구조의 기본 모양으로 다시 시작해요.")
            Spacer()
            Button { model.undo() } label: { Label("되돌리기", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
            Button("저장") { model.save() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            if let id = model.savedID {
                Menu("데려가기") {
                    Button("메인 펫으로") { model.director?.adoptPet(id, asFriend: false) }
                    Button("친구로") { model.director?.adoptPet(id, asFriend: true) }
                    Button("파일로 내보내기…") { model.director?.exportPetWithPanel(id: id) }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func confirmSkeleton(_ id: String) {
        guard id != model.spec.skeleton else { return }
        let a = NSAlert()
        a.messageText = L10n.format("%@ 구조로 바꿀까요?", Skeleton.named(id)?.label ?? id)
        a.informativeText = L10n.t("지금 그린 모양은 사라지고 그 구조의 기본 모양으로 시작해요. (되돌리기로 돌아올 수 있어요)")
        a.addButton(withTitle: L10n.t("바꾸기"))
        a.addButton(withTitle: L10n.t("취소"))
        if a.runModal() == .alertFirstButtonReturn { model.setSkeleton(id) }
    }
}

private struct MakerPartList: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("부위").font(.headline).padding(.horizontal, 12).padding(.top, 12)
            List(selection: Binding(get: { Optional(model.selected) }, set: { if let v = $0 { model.selected = v } })) {
                ForEach(model.partIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.label(id))
                        Text(model.summary(id)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(id)
                }
            }
            .listStyle(.sidebar)
            Button { model.addAccessory() } label: { Label("장식 추가", systemImage: "plus") }
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
}

private struct MakerToolBar: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.tool) {
                ForEach(MakerModel.Tool.allCases) { t in Label(t.label, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            ColorPicker("", selection: $model.paint).labelsHidden().help("새로 그릴 색")
            Toggle("무늬", isOn: $model.markMode).toggleStyle(.button).help("켜면 외곽선 없이 부위 안쪽에만 칠해요 (점·배·귀 안쪽)")
            Spacer(minLength: 0)
        }
    }
}

private struct MakerSidePanel: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("생김새").tag(MakerModel.Tab.look)
                Text("스타일").tag(MakerModel.Tab.style)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.tab == .look {
                        MakerPreview(model: model)
                        MakerAIBox(model: model)
                        MakerPartInspector(model: model)
                        MakerFaceInspector(model: model)
                    } else {
                        MakerStyleInspector(model: model)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }
}

/// 실시간 미리보기: 동작을 3초씩 돌아가며 (고르면 그 동작만)
private struct MakerPreview: View {
    @ObservedObject var model: MakerModel
    private static let cycle: [PetAnim] = [.walk, .idle, .happy, .wave, .eat, .run, .sit, .sleep, .alert]

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                Canvas { gc, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    var pose = PetPose()
                    pose.anim = model.previewAnim ?? Self.cycle[Int(t / 3) % Self.cycle.count]
                    pose.clock = t
                    pose.animTime = t.truncatingRemainder(dividingBy: 3)
                    pose.walkPhase = CGFloat(t * 7)
                    pose.blink = t.truncatingRemainder(dividingBy: 4) < 0.12 ? 1 : 0
                    let r = model.renderer
                    gc.withCGContext { cg in
                        cg.translateBy(x: size.width / 2, y: size.height - 16)
                        cg.scaleBy(x: 2.6, y: -2.6)
                        r.draw(pose, in: cg)
                    }
                }
            }
            .frame(height: 230)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            Picker("동작", selection: $model.previewAnim) {
                Text("돌아가며").tag(PetAnim?.none)
                ForEach(Self.cycle, id: \.self) { Text(name($0)).tag(PetAnim?.some($0)) }
            }
        }
    }

    private func name(_ a: PetAnim) -> String {
        ["walk": "걷기", "idle": "가만히", "happy": "기쁨", "wave": "손 흔들기", "eat": "먹기", "run": "달리기", "sit": "앉기",
         "sleep": "잠", "alert": "놀람"][a.rawValue].map(L10n.t) ?? a.rawValue
    }
}

private struct MakerAIBox: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        GroupBox(L10n.t("말로 설명해서 초안 받기")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("예: 머리에 새싹이 난 통통한 감자", text: $model.aiPrompt, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                HStack {
                    Button(model.aiBusy ? L10n.t("그리는 중…") : L10n.t("초안 만들기")) { model.generateAI() }
                        .disabled(model.aiBusy || model.aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.aiBusy { ProgressView().controlSize(.small) }
                }
                Text("로그인된 claude 또는 codex로 지금 고른 몸 구조에 맞춰 그려요. 받은 뒤 펜으로 다듬으면 돼요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }
}

private struct MakerPartInspector: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        GroupBox(model.label(model.selected)) {
            VStack(alignment: .leading, spacing: 8) {
                let part = model.spec.parts[model.selected]
                if let shapes = part?.shapes, !shapes.isEmpty {
                    ColorPicker("모양 색", selection: Binding(
                        get: { Color(cgColor: CGColor.fromHex(shapes.first { $0.line != false }?.fill ?? shapes[0].fill) ?? .white) },
                        set: { model.recolorSelected($0, marks: false) }))
                    if shapes.contains(where: { $0.line == false }) {
                        ColorPicker("무늬 색", selection: Binding(
                            get: { Color(cgColor: CGColor.fromHex(shapes.first { $0.line == false }!.fill) ?? .white) },
                            set: { model.recolorSelected($0, marks: true) }))
                    }
                }
                if part?.image != nil {
                    HStack {
                        Text("그림 크기")
                        Spacer()
                        Button("−") { model.scaleImage(0.9) }
                        Button("+") { model.scaleImage(1.1) }
                    }
                }
                if Skeleton.isAccessory(model.selected), part != nil {
                    Picker("붙는 곳", selection: Binding(get: { part?.parent ?? "head" }, set: { model.setAccessoryParent($0) })) {
                        ForEach(model.skeleton.bones.map(\.id), id: \.self) { Text(model.label($0)).tag($0) }
                    }
                }
                if part == nil { Text("펜·동그라미로 그리거나 그림을 넣어요").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button { model.importImage() } label: { Label("그림 넣기…", systemImage: "photo") }
                        .help("이 부위에 PNG·GIF 그림 넣기 (캔버스에 끌어다 놓아도 돼요)")
                    Button(role: .destructive) { model.clearSelected() } label: { Label("비우기", systemImage: "trash") }
                }
                Divider()
                ColorPicker("외곽선", selection: Binding(get: { Color(cgColor: CGColor.fromHex(model.spec.outline) ?? .black) },
                                                      set: { model.setOutline($0) }))
                LabeledContent("선 굵기") {
                    Slider(value: Binding(get: { model.spec.lineWidth ?? 3 }, set: { model.setLineWidth($0) }), in: 0...6)
                }
            }
            .padding(4)
        }
    }
}

private struct MakerFaceInspector: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        GroupBox("얼굴") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("눈", selection: Binding(get: { model.spec.face.eyes ?? "dot" }, set: { v in model.updateFace { $0.eyes = v } })) {
                    Text("콩알").tag("dot"); Text("동글").tag("round"); Text("반짝").tag("sparkle"); Text("졸린").tag("sleepy"); Text("없음").tag("none")
                }
                Picker("입", selection: Binding(get: { model.spec.face.mouth ?? "smile" }, set: { v in model.updateFace { $0.mouth = v } })) {
                    Text("웃음").tag("smile"); Text("고양이").tag("cat"); Text("작게").tag("tiny"); Text("없음").tag("none")
                }
                LabeledContent("눈 사이") {
                    Slider(value: Binding(get: { model.spec.face.eyeGap ?? 13 }, set: { v in model.updateFace { $0.eyeGap = (v * 10).rounded() / 10 } }), in: 6...24)
                }
                LabeledContent("눈 크기") {
                    Slider(value: Binding(get: { model.spec.face.eyeSize ?? 1 }, set: { v in model.updateFace { $0.eyeSize = (v * 100).rounded() / 100 } }), in: 0.6...1.8)
                }
                ColorPicker("눈 색", selection: Binding(get: { Color(cgColor: CGColor.fromHex(model.spec.face.eyeColor ?? "#2A2724") ?? .black) },
                                                      set: { c in let h = model.hex(c); model.updateFace { $0.eyeColor = h } }))
                Toggle("볼터치", isOn: Binding(get: { model.spec.face.blush != nil }, set: { on in model.updateFace { $0.blush = on ? "#F7A5B8" : nil } }))
                if let blush = model.spec.face.blush {
                    ColorPicker("볼터치 색", selection: Binding(get: { Color(cgColor: CGColor.fromHex(blush) ?? CGColor(srgbRed: 0.97, green: 0.65, blue: 0.72, alpha: 1)) },
                                                            set: { c in let h = model.hex(c); model.updateFace { $0.blush = h } }))
                }
                Text("얼굴 위치는 위 도구의 '얼굴 위치'로 캔버스를 눌러 정해요.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }
}

/// 성격·말투·크기 (모든 펫에 공통인 스타일 — 메이커 펫은 pet.json에 같이 저장돼 내보낼 때 따라간다)
struct MakerStyleInspector: View {
    @ObservedObject var model: MakerModel

    var body: some View {
        StyleEditor(style: Binding(get: { model.style() }, set: { st in model.updateStyle { $0 = st } }),
                    interjection: Binding(get: { model.spec.interjection ?? "" }, set: { v in model.mutate { $0.interjection = v.isEmpty ? nil : v } }),
                    showColors: false)
        GroupBox("크기") {
            Slider(value: Binding(get: { model.spec.scale ?? 1 }, set: { v in model.mutate { $0.scale = (v * 100).rounded() / 100 } }), in: 0.6...1.4)
                .padding(4)
        }
    }
}

/// 스타일 편집 (설정 창의 펫 스타일과 메이커가 같이 쓴다)
struct StyleEditor: View {
    @Binding var style: PetStyle
    @Binding var interjection: String
    var showColors: Bool
    var colorFields: [(String, String, String)] = []   // (키, 이름, 기본 색)
    /// 설정 창 Form 안이면 상자 대신 폼 섹션으로 (상자 안의 상자가 되지 않게)
    var inForm = false

    static var traitNames: [(String, String)] {
        L10n.isKorean
            ? [("energy", "활발"), ("curiosity", "호기심"), ("sociability", "다정"), ("artistry", "예술"),
               ("mischief", "장난"), ("appetite", "식탐"), ("laziness", "느긋"), ("tidiness", "깔끔")]
            : [("energy", "Energy"), ("curiosity", "Curiosity"), ("sociability", "Sweetness"), ("artistry", "Artistry"),
               ("mischief", "Mischief"), ("appetite", "Appetite"), ("laziness", "Chill"), ("tidiness", "Tidiness")]
    }

    @ViewBuilder
    private func box<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        if inForm {
            Section {
                content()
            } header: {
                Text(L10n.t(title))
            } footer: {
                if let footer { Text(L10n.t(footer)) }
            }
        } else {
            GroupBox(L10n.t(title)) {
                VStack(alignment: .leading, spacing: 8) { content() }.padding(4)
            }
        }
    }

    var body: some View {
        box("성격") { personality }
        box("말투", footer: inForm ? "말버릇·말끝·이모지·혼잣말은 펫 혼잣말에, 존댓말·대화 말투는 대화 AI에도 들어가요." : nil) { speech }
        if showColors, !colorFields.isEmpty {
            box("색") { colors }
        }
    }

    @ViewBuilder private var personality: some View {
                Toggle("직접 정하기", isOn: Binding(get: { style.personality != nil }, set: { on in
                    style.personality = on ? Dictionary(uniqueKeysWithValues: Self.traitNames.map { ($0.0, 0.5) }) : nil
                }))
                if style.personality != nil {
                    ForEach(Self.traitNames, id: \.0) { key, name in
                        LabeledContent(name) {
                            Slider(value: Binding(get: { style.personality?[key] ?? 0.5 }, set: { v in style.personality?[key] = (v * 100).rounded() / 100 }), in: 0...1)
                        }
                    }
                } else {
                    Text("끄면 펫 번호(No.)로 정해진 성격을 써요").font(.caption).foregroundStyle(.secondary)
                }
    }

    @ViewBuilder private var speech: some View {
                TextField("말버릇", text: $interjection, prompt: Text("말 앞에 붙음, 예: 몽!"))
                TextField("말끝", text: Binding(get: { style.speech?.suffix ?? "" }, set: { v in
                    edit { $0.suffix = v.isEmpty ? nil : String(v.prefix(8)) }
                }), prompt: Text("예: 냥, 다요"))
                Picker("이모지", selection: Binding(get: { style.speech?.emoji ?? "some" }, set: { v in edit { $0.emoji = v } })) {
                    Text("안 씀").tag("none"); Text("가끔").tag("some"); Text("많이").tag("lots")
                }
                LabeledContent("혼잣말") {
                    Slider(value: Binding(get: { style.speech?.chattiness ?? 0.5 }, set: { v in edit { $0.chattiness = (v * 100).rounded() / 100 } }), in: 0...1)
                }
                Toggle("대화할 때 존댓말", isOn: Binding(get: { style.speech?.polite ?? false }, set: { v in edit { $0.polite = v ? true : nil } }))
                TextField("대화 말투", text: Binding(get: { style.speech?.tone ?? "" }, set: { v in
                    edit { $0.tone = v.isEmpty ? nil : String(v.prefix(200)) }
                }), prompt: Text("예: 느긋한 할머니 말투"), axis: .vertical).lineLimit(1...3)
    }

    @ViewBuilder private var colors: some View {
                    ForEach(colorFields, id: \.0) { key, name, def in
                        HStack {
                            ColorPicker(name, selection: Binding(get: { Color(cgColor: CGColor.fromHex(style.colors?[key] ?? def) ?? .white) }, set: { c in
                                var cols = style.colors ?? [:]
                                cols[key] = (NSColor(c).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)).hex
                                style.colors = cols
                            }))
                            if style.colors?[key] != nil {
                                Button("원래대로") { style.colors?[key] = nil; if style.colors?.isEmpty == true { style.colors = nil } }.controlSize(.small)
                            }
                        }
                    }
    }

    private func edit(_ change: (inout SpeechStyle) -> Void) {
        var sp = style.speech ?? SpeechStyle()
        change(&sp)
        style.speech = sp == SpeechStyle() ? nil : sp
    }
}

@MainActor
final class MakerWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let model: MakerModel
    var onClose: (() -> Void)?

    init(director: Director, spec: RigSpec?, folder: URL?) {
        model = MakerModel(spec: spec, folder: folder)
        model.director = director
        let host = NSHostingController(rootView: MakerView(model: model).pawmitLocalized())
        window = NSWindow(contentViewController: host)
        window.title = Self.title(spec)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.center()
        super.init()
        window.delegate = self
    }

    private static func title(_ spec: RigSpec?) -> String {
        spec.map { L10n.format("펫 메이커 — %@", $0.name) } ?? L10n.t("펫 메이커")
    }

    func languageChanged() {
        window.title = Self.title(model.editingFolder == nil ? nil : model.spec)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cleanUp()
        onClose?()
    }
}
