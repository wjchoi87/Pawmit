import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PawmitCore

/// 커스텀 펫 만들기 위자드
/// 1) 조립: 귀·꼬리·무늬·색·머리 크기를 고르면 실시간 미리보기 → `pet.json`("kind":"chibi")
/// 2) 내 그림: 상태별 이미지(GIF·PNG·APNG·WebP) 끌어다 놓기 — 한 장만 있어도 모션이 붙는다
/// 3) 고치기: 만든 이미지 펫의 그림·이름을 같은 폴더에 덮어쓰기
@MainActor
final class WizardModel: ObservableObject {
    enum Step { case choose, assemble, images, edit, done }

    @Published var step: Step = .choose
    @Published var name = ""
    @Published var interjection = ""
    @Published var ears = "round"
    @Published var tail = "none"
    @Published var pattern = "none"
    @Published var body = Color.white
    @Published var accent = Color(red: 0.56, green: 0.66, blue: 0.8)
    @Published var innerEar = Color(red: 0.97, green: 0.79, blue: 0.82)
    @Published var outline = Color(red: 0.25, green: 0.22, blue: 0.22)
    @Published var blush = Color(red: 0.97, green: 0.65, blue: 0.72)
    @Published var useBelly = false
    @Published var belly = Color(red: 1, green: 0.96, blue: 0.85)
    @Published var headWidth: Double = 17.5
    @Published var headHeight: Double = 14
    @Published var previewAnim: PetAnim = .walk

    @Published var images: [String: URL] = [:]
    @Published var facingLeft = false
    @Published var error: String?
    @Published var savedID: String?

    // "기존 펫 고치기" 상태 — editingSlug가 nil이면 새로 만들기 모드
    @Published var editingSlug: String?
    /// 이 펫 폴더에만 있는 상태 파일(wave_left 같은 것) 슬롯
    @Published var extraStates: [(String, String)] = []
    /// 편집 중 ✕로 뺀 상태 — 저장 시 폴더에서 파일 삭제
    @Published var removedStates: Set<String> = []

    var isEditing: Bool { editingSlug != nil }

    var allSlots: [(String, String)] { WizardModel.imageStates + extraStates }

    /// 고칠 수 있는 펫: `~/.pawmit/pets` 중 이미지 세트 폴더만 (메이커 rig·spritesheet 펫은 제외)
    static func editablePacks() -> [PetRoster.Entry] {
        let exts: Set<String> = ["gif", "png", "apng", "webp", "jpg", "jpeg", "heic"]
        return PetRoster.customPacks().filter { e in
            guard e.id.hasPrefix("folder:") else { return false }
            let f = PawmitPaths.petsDir.appendingPathComponent(String(e.id.dropFirst("folder:".count)))
            let meta = (try? Data(contentsOf: f.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
            if meta?["spritesheetPath"] != nil { return false }
            if meta?["kind"]?.string == "rig" { return false }
            let files = (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? []
            return files.contains { exts.contains($0.pathExtension.lowercased()) }
        }
    }

    static var imageStates: [(String, String)] {
        [("idle", L10n.t("가만히 (필수)")), ("walk", L10n.t("걷기")), ("run", L10n.t("달리기")), ("sit", L10n.t("앉기")), ("sleep", L10n.t("잠")), ("eat", L10n.t("먹기")),
         ("happy", L10n.t("기쁨")), ("sad", L10n.t("슬픔")), ("alert", L10n.t("놀람")), ("wave", L10n.t("손 흔들기")), ("dig", L10n.t("뒤지기")), ("draw", L10n.t("낙서")), ("play", L10n.t("놀기"))]
    }

    weak var director: Director?

    var species: ChibiSpecies {
        func cg(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1) }
        var sp = ChibiSpecies(id: "preview", name: name.isEmpty ? L10n.t("새 친구") : name, interjection: interjection,
                              ears: ears, tail: tail, pattern: pattern, body: cg(body), accent: cg(accent), innerEar: cg(innerEar),
                              belly: useBelly ? cg(belly) : nil, outline: cg(outline), blush: cg(blush).copy(alpha: 0.85)!)
        sp.headRX = CGFloat(headWidth)
        sp.headRY = CGFloat(headHeight)
        return sp
    }

    /// 귀여운 조합 무작위로
    func randomize() {
        var r = SplitMix64(seed: UInt64.random(in: 0...UInt64.max))
        let palettes: [(Color, Color, Color)] = [
            (.white, Color(red: 0.56, green: 0.66, blue: 0.8), Color(red: 0.97, green: 0.79, blue: 0.82)),
            (Color(red: 0.99, green: 0.91, blue: 0.64), Color(red: 0.95, green: 0.7, blue: 0.4), Color(red: 0.96, green: 0.73, blue: 0.65)),
            (Color(red: 0.96, green: 0.87, blue: 0.73), Color(red: 0.66, green: 0.41, blue: 0.23), Color(red: 0.96, green: 0.87, blue: 0.73)),
            (Color(red: 0.8, green: 0.9, blue: 0.98), Color(red: 0.5, green: 0.65, blue: 0.9), Color(red: 0.95, green: 0.78, blue: 0.85)),
            (Color(red: 0.98, green: 0.84, blue: 0.88), Color(red: 0.95, green: 0.55, blue: 0.65), Color(red: 1, green: 0.7, blue: 0.75)),
            (Color(red: 0.86, green: 0.95, blue: 0.82), Color(red: 0.45, green: 0.72, blue: 0.5), Color(red: 0.95, green: 0.8, blue: 0.8)),
            (Color(red: 0.79, green: 0.63, blue: 0.48), Color(red: 0.95, green: 0.89, blue: 0.81), Color(red: 0.61, green: 0.46, blue: 0.33)),
            (Color(red: 0.88, green: 0.85, blue: 0.97), Color(red: 0.62, green: 0.55, blue: 0.9), Color(red: 0.97, green: 0.78, blue: 0.86)),
        ]
        let p = r.pick(palettes)
        body = p.0
        accent = p.1
        innerEar = p.2
        ears = r.pick(ChibiParts.ears).id
        tail = r.pick(ChibiParts.tails).id
        pattern = r.pick(["none", "none"] + ChibiParts.patterns.map(\.id))
        useBelly = r.chance(0.4)
        headWidth = r.range(16, 19.5)
        headHeight = r.range(13, 15.5)
        if interjection.isEmpty { interjection = r.pick(L10n.isKorean ? ["뿅!", "말랑~", "쪼꼬!", "푸딩~", "콩콩"] : ["Boing!", "Squish~", "Tiny!", "Pudding~", "Pop!"]) }
    }

    /// 기본 펫 하나를 바탕으로 시작 (색·부위만 바꿔서 나만의 펫 만들기)
    func load(_ sp: ChibiSpecies) {
        name = sp.name
        interjection = sp.interjection
        ears = sp.ears
        tail = sp.tail
        pattern = sp.pattern
        body = Color(cgColor: sp.body)
        accent = Color(cgColor: sp.accent)
        innerEar = Color(cgColor: sp.innerEar)
        outline = Color(cgColor: sp.outline)
        blush = Color(cgColor: sp.blush.copy(alpha: 1) ?? sp.blush)
        useBelly = sp.belly != nil
        if let b = sp.belly { belly = Color(cgColor: b) }
        headWidth = Double(sp.headRX)
        headHeight = Double(sp.headRY)
    }

    // MARK: - 저장

    private func makeFolder() throws -> (URL, String) {
        try PawmitPaths.ensureHome()
        let base = name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(String.init).joined()
        var slug = base.isEmpty ? "pet-\(Int(Date().timeIntervalSince1970))" : base
        var n = 2
        while FileManager.default.fileExists(atPath: PawmitPaths.petsDir.appendingPathComponent(slug).path) {
            slug = (base.isEmpty ? "pet" : base) + "-\(n)"
            n += 1
        }
        let url = PawmitPaths.petsDir.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, slug)
    }

    func saveAssembled() {
        do {
            let (folder, slug) = try makeFolder()
            var sp = species
            sp.name = name.isEmpty ? L10n.t("새 친구") : name
            try Data(sp.toJSON().encoded(pretty: true).utf8).write(to: folder.appendingPathComponent("pet.json"))
            finish("folder:\(slug)")
        } catch {
            self.error = L10n.format("저장 실패: %@", error.localizedDescription)
        }
    }

    func saveImages() {
        guard images["idle"] != nil else {
            error = L10n.t("가만히(idle) 그림은 꼭 필요해요.")
            return
        }
        do {
            let (folder, slug) = try makeFolder()
            for (state, src) in images {
                let dest = folder.appendingPathComponent("\(state).\(src.pathExtension.lowercased())")
                try FileManager.default.copyItem(at: src, to: dest)
            }
            let meta: JSONValue = ["name": .string(name.isEmpty ? L10n.t("내 펫") : name), "facing": .string(facingLeft ? "left" : "right")]
            try Data(meta.encoded(pretty: true).utf8).write(to: folder.appendingPathComponent("pet.json"))
            finish("folder:\(slug)")
        } catch {
            self.error = L10n.format("저장 실패: %@", error.localizedDescription)
        }
    }

    private func finish(_ id: String) {
        error = nil
        savedID = id
        step = .done
    }

    /// 창을 다시 열거나 "하나 더 만들기" — 입력 중이던 내용을 버리고 처음부터
    func resetAll() {
        savedID = nil
        name = ""
        facingLeft = false
        images = [:]
        extraStates = []
        removedStates = []
        editingSlug = nil
        step = .choose
    }

    /// 이미지 세트 펫 고치기: 폴더의 상태별 그림·이름·방향을 불러와 같은 폴더에 덮어 저장한다.
    /// pet.json의 다른 필드(height 등)는 보존하고 name/facing만 갱신한다.
    func loadEdit(_ e: PetRoster.Entry) {
        let slug = String(e.id.dropFirst("folder:".count))
        let f = PawmitPaths.petsDir.appendingPathComponent(slug)
        images = [:]
        extraStates = []
        removedStates = []
        var known = Set(WizardModel.imageStates.map(\.0))
        let meta = (try? Data(contentsOf: f.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
        name = meta?["name"]?.string ?? e.name
        facingLeft = meta?["facing"]?.string == "left"
        let exts: Set<String> = ["gif", "png", "apng", "webp", "jpg", "jpeg", "heic"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard exts.contains(file.pathExtension.lowercased()) else { continue }
            let key = file.deletingPathExtension().lastPathComponent.lowercased()
            images[key] = file
            if !known.contains(key) {
                extraStates.append((key, key))
                known.insert(key)
            }
        }
        editingSlug = slug
        step = .images
    }

    func saveEdit() {
        guard let slug = editingSlug else { return }
        guard images["idle"] != nil else {
            error = L10n.t("가만히(idle) 그림은 꼭 필요해요.")
            return
        }
        let folder = PawmitPaths.petsDir.appendingPathComponent(slug)
        let exts: Set<String> = ["gif", "png", "apng", "webp", "jpg", "jpeg", "heic"]
        do {
            let fm = FileManager.default
            let existing = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
            // 뺀 상태의 파일 삭제 (idle은 ✕가 없어 여기 올 수 없다)
            for file in existing where removedStates.contains(file.deletingPathExtension().lastPathComponent.lowercased()) {
                try? fm.removeItem(at: file)
            }
            // 바꾼 그림 저장 — 같은 상태의 예전 파일(확장자가 다른 것 포함)은 치운다
            for (state, src) in images {
                let dest = folder.appendingPathComponent("\(state).\(src.pathExtension.lowercased())")
                if src.standardizedFileURL == dest.standardizedFileURL { continue }
                for file in existing where file.deletingPathExtension().lastPathComponent.lowercased() == state {
                    try? fm.removeItem(at: file)
                }
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
            }
            // pet.json: 기존 필드(height 등) 보존, name/facing만 갱신
            var m = (try? Data(contentsOf: folder.appendingPathComponent("pet.json")))
                .flatMap { JSONValue.parse($0) }?.object ?? [:]
            m["name"] = .string(name.isEmpty ? slug : name)
            m["facing"] = .string(facingLeft ? "left" : "right")
            try Data(JSONValue.object(m).encoded(pretty: true).utf8)
                .write(to: folder.appendingPathComponent("pet.json"), options: .atomic)
            let id = "folder:\(slug)"
            director?.petDefinitionChanged(id)
            removedStates = []
            finish(id)
        } catch {
            self.error = L10n.format("저장 실패: %@", error.localizedDescription)
        }
    }

    func pickFile(for state: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .webP, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { images[state] = url }
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            switch model.step {
            case .choose: choose
            case .assemble: assemble
            case .images: imagesStep
            case .edit: editStep
            case .done: done
            }
            if let e = model.error {
                Text(e).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520, alignment: .topLeading)
    }

    /// 뒤로·저장 — 단계마다 화면 상단에 고정
    @ViewBuilder private var topBar: some View {
        switch model.step {
        case .choose, .done:
            EmptyView()
        case .assemble:
            HStack {
                Button("← 뒤로") { model.step = .choose }
                Spacer()
                Button("저장") { model.saveAssembled() }.keyboardShortcut(.defaultAction)
            }
        case .images:
            HStack {
                Button("← 뒤로") { model.step = .choose }
                Spacer()
                if model.isEditing {
                    Button("이 폴더에 저장") { model.saveEdit() }
                        .keyboardShortcut(.defaultAction).disabled(model.images["idle"] == nil)
                } else {
                    Button("저장") { model.saveImages() }
                        .keyboardShortcut(.defaultAction).disabled(model.images["idle"] == nil)
                }
            }
        case .edit:
            HStack {
                Button("← 뒤로") { model.step = .choose }
                Spacer()
            }
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("어떤 펫을 만들까?").font(.title2.bold())
            Button { model.director?.openMaker() } label: {
                HStack(spacing: 14) {
                    Text("✏️").font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("펫 메이커 — 완전히 새로 만들기").font(.headline)
                        Text("직접 그리거나, 그림 파일을 부위별로 넣거나, 말로 설명하면 AI가 초안을 그려요. 두 발·네 발·다리 없음·날개 중 몸 구조를 고르면 모든 동작이 자동으로 붙어요.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            HStack(spacing: 14) {
                bigButton("🧸", L10n.t("기본 펫 변형"), L10n.t("기본 펫의 귀·꼬리·무늬·색을 바꿔서")) { model.resetAll(); model.randomize(); model.step = .assemble }
                bigButton("🖼️", L10n.t("내 그림으로 만들기"), L10n.t("PNG·GIF 한 장만 있어도 OK")) { model.resetAll(); model.step = .images }
                if !WizardModel.editablePacks().isEmpty {
                    bigButton("🔧", L10n.t("기존 펫 고치기"), L10n.t("만든 펫의 그림·이름 바꾸기")) { model.step = .edit }
                }
            }
        }
    }

    private func bigButton(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(icon).font(.system(size: 40))
                Text(title).font(.headline)
                Text(sub).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 180, height: 170)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private var assemble: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                ChibiPreview(species: model.species, anim: model.previewAnim)
                    .frame(width: 220, height: 220)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
                Picker("", selection: $model.previewAnim) {
                    Text("걷기").tag(PetAnim.walk); Text("기쁨").tag(PetAnim.happy); Text("먹기").tag(PetAnim.eat); Text("잠").tag(PetAnim.sleep); Text("울기").tag(PetAnim.sad)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                HStack {
                    Button("🎲 랜덤 조합") { model.randomize() }
                    Menu("기본 펫에서 시작") {
                        ForEach(ChibiSpecies.all, id: \.id) { sp in Button(sp.name) { model.load(sp) } }
                    }
                    .fixedSize()
                }
            }
            Form {
                TextField("이름", text: $model.name)
                TextField("말버릇 (예: 뿅!)", text: $model.interjection)
                Picker("귀", selection: $model.ears) {
                    ForEach(ChibiParts.ears, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("꼬리", selection: $model.tail) {
                    ForEach(ChibiParts.tails, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("무늬", selection: $model.pattern) {
                    ForEach(ChibiParts.patterns, id: \.id) { Text($0.label).tag($0.id) }
                }
                ColorPicker("몸 색", selection: $model.body)
                ColorPicker("무늬·꼬리 색", selection: $model.accent)
                ColorPicker("귀 안쪽", selection: $model.innerEar)
                ColorPicker("볼터치", selection: $model.blush)
                ColorPicker("외곽선", selection: $model.outline)
                Toggle("배 색 따로", isOn: $model.useBelly)
                if model.useBelly { ColorPicker("배 색", selection: $model.belly) }
                LabeledContent("머리 너비") { Slider(value: $model.headWidth, in: 14...21) }
                LabeledContent("머리 높이") { Slider(value: $model.headHeight, in: 11...17) }
            }
            .formStyle(.grouped)
        }
    }

    /// 고칠 커스텀 펫 고르기
    private var editStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("고칠 펫을 골라요").font(.title3.bold())
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(WizardModel.editablePacks(), id: \.id) { e in
                        Button { model.loadEdit(e) } label: {
                            HStack(spacing: 10) {
                                if let img = model.director?.previewImage(for: e.id) {
                                    Image(nsImage: img).resizable().scaledToFit().frame(width: 36, height: 36)
                                }
                                Text(e.name)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var imagesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isEditing ? L10n.format("고치기 — %@", model.name.isEmpty ? model.editingSlug ?? "" : model.name) : L10n.t("내 그림으로 만들기"))
                .font(.title3.bold())
            Text(model.isEditing
                 ? L10n.t("그림을 새로 놓아 바꾸거나 ✕로 뺄 수 있어요. 가만히(idle)는 못 뺀다. 저장하면 같은 펫 폴더에 덮어써요.")
                 : L10n.t("상태별 그림을 끌어다 놓거나 골라요. 가만히(idle) 한 장만 있어도 걷기·기쁨 같은 모션이 자동으로 붙어요."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("이름", text: $model.name).frame(width: 200)
                Toggle("그림이 왼쪽을 보고 있어요", isOn: $model.facingLeft)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                    ForEach(model.allSlots, id: \.0) { state, label in
                        ImageSlot(label: label, url: model.images[state],
                                  removable: model.isEditing && state != "idle") {
                            model.pickFile(for: state)
                        } onDrop: { url in model.images[state] = url } onRemove: {
                            model.images[state] = nil
                            model.removedStates.insert(state)
                        }
                    }
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.isEditing ? L10n.t("고쳤어요! ✅") : L10n.t("완성! 🎉")).font(.title2.bold())
            if let id = model.savedID, let img = model.director?.previewImage(for: id) {
                Image(nsImage: img).resizable().frame(width: 140, height: 140)
            }
            HStack(spacing: 10) {
                Button("메인 펫으로 쓰기") { if let id = model.savedID { model.director?.adoptPet(id, asFriend: false) } }
                Button("친구로 부르기") { if let id = model.savedID { model.director?.adoptPet(id, asFriend: true) } }
                Button("하나 더 만들기") { model.resetAll() }
            }
        }
    }
}

private struct ImageSlot: View {
    var label: String
    var url: URL?
    var removable = false
    var onPick: () -> Void
    var onDrop: (URL) -> Void
    var onRemove: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.12 : 0.05))
                if let url, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit().padding(8)
                } else {
                    Image(systemName: "plus").font(.title2).foregroundStyle(.secondary)
                }
                if url != nil, removable, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary, Color(nsColor: .windowBackgroundColor))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            .frame(height: 90)
            .onTapGesture(perform: onPick)
            .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { onDrop(url) } }
                }
                return true
            }
            Text(label).font(.caption)
        }
    }
}

/// 위자드 미리보기: 조립 중인 펫이 계속 움직인다 (12fps)
struct ChibiPreview: View {
    var species: ChibiSpecies
    var anim: PetAnim

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            Canvas { gc, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                var pose = PetPose()
                pose.anim = anim
                pose.clock = t
                pose.animTime = t.truncatingRemainder(dividingBy: 4)
                pose.walkPhase = CGFloat(t * 7)
                let renderer = ChibiRenderer(species: species)
                gc.withCGContext { cg in
                    cg.translateBy(x: size.width / 2, y: size.height - 24)
                    cg.scaleBy(x: 2.6, y: -2.6)
                    renderer.draw(pose, in: cg)
                }
            }
        }
    }
}

@MainActor
final class WizardWindowController {
    private let window: NSWindow
    private let model = WizardModel()

    init(director: Director) {
        model.director = director
        let host = NSHostingController(rootView: WizardView(model: model).pawmitLocalized())
        window = NSWindow(contentViewController: host)
        window.title = L10n.t("커스텀 펫 만들기")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func debugStep(_ step: WizardModel.Step) {
        if step == .assemble { model.randomize() }
        model.step = step
    }

    func languageChanged() {
        window.title = L10n.t("커스텀 펫 만들기")
    }

    func show() {
        // 창을 닫았다 다시 열면 항상 첫 화면(펫 종류 고르기)부터 — 입력 중이던 내용도 새로 시작한다
        model.resetAll()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
