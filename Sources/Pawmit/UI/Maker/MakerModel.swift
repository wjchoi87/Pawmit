import AppKit
import SwiftUI
import PawmitCore

/// 펫 메이커 상태. 편집 대상은 RigSpec 하나이고, 그림 파일은 임시 작업 폴더에 모았다가 저장할 때 펫 폴더로 옮긴다.
@MainActor
final class MakerModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, ellipse, move, face, erase
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pen: return L10n.t("펜")
            case .ellipse: return L10n.t("동그라미")
            case .move: return L10n.t("옮기기")
            case .face: return L10n.t("얼굴 위치")
            case .erase: return L10n.t("지우개")
            }
        }
        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .ellipse: return "circle"
            case .move: return "hand.draw"
            case .face: return "face.smiling"
            case .erase: return "eraser"
            }
        }
    }

    enum Tab: String { case look, style }

    @Published private(set) var spec: RigSpec
    @Published var selected = "body"
    @Published var tool: Tool = .pen
    @Published var paint = Color.white
    /// 새로 그리는 모양을 외곽선 없는 무늬로
    @Published var markMode = false
    @Published var previewAnim: PetAnim? = nil
    @Published var tab: Tab = .look
    @Published var aiPrompt = ""
    @Published var aiBusy = false
    @Published var message: String?
    @Published var savedID: String?
    @Published private(set) var revision = 0

    weak var director: Director?
    /// 고치는 중인 펫 폴더 (새 펫이면 nil)
    private(set) var editingFolder: URL?
    let draftFolder: URL
    private var undoStack: [RigSpec] = []
    private var liveEditing = false
    private var cachedRenderer: (Int, RigRenderer)?

    init(spec: RigSpec? = nil, folder: URL? = nil) {
        draftFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-maker-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: true)
        var s = spec ?? RigTemplates.template("biped")!
        if spec == nil { s.name = "" }
        self.spec = s
        editingFolder = folder
        // 고치는 펫의 그림들을 작업 폴더로
        if let folder {
            for img in s.parts.values.compactMap(\.image) where PetBundle.isSafeName(img) {
                try? FileManager.default.copyItem(at: folder.appendingPathComponent(img), to: draftFolder.appendingPathComponent(img))
            }
        }
        if let first = Skeleton.named(s.skeleton)?.bones.first(where: { $0.id == "body" }) { selected = first.id }
    }

    var skeleton: Skeleton { Skeleton.named(spec.skeleton) ?? .biped }

    /// 미리보기·캔버스용 렌더러 (편집할 때마다 새로)
    var renderer: RigRenderer {
        if let (rev, r) = cachedRenderer, rev == revision { return r }
        let r = RigRenderer(spec: spec, folder: draftFolder, key: "maker-\(revision)")
        cachedRenderer = (revision, r)
        return r
    }

    /// 뼈대 부위 + 쓰고 있는 장식
    var partIDs: [String] {
        skeleton.bones.sorted { $0.z > $1.z }.map(\.id) + spec.parts.keys.filter { Skeleton.isAccessory($0) }.sorted()
    }

    func label(_ id: String) -> String {
        if let b = skeleton.bone(id) { return b.label }
        return L10n.format("장식 %@", String(id.dropFirst(3)))
    }

    func summary(_ id: String) -> String {
        guard let p = spec.parts[id] else { return L10n.t("비어 있음") }
        var bits: [String] = []
        if let n = p.shapes?.count, n > 0 { bits.append(L10n.format("모양 %lld", n)) }
        if p.image != nil { bits.append(L10n.t("그림")) }
        return bits.isEmpty ? L10n.t("비어 있음") : bits.joined(separator: " · ")
    }

    // MARK: - 편집

    func mutate(_ change: (inout RigSpec) -> Void) {
        if !liveEditing {
            undoStack.append(spec)
            if undoStack.count > 60 { undoStack.removeFirst() }
        }
        var s = spec
        change(&s)
        spec = s
        revision += 1
        message = nil
    }

    /// 끌기처럼 여러 번 바뀌는 편집: 시작할 때 한 번만 되돌리기에 쌓는다
    func beginLiveEdit() {
        undoStack.append(spec)
        if undoStack.count > 60 { undoStack.removeFirst() }
        liveEditing = true
    }

    func endLiveEdit() { liveEditing = false }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        spec = prev
        revision += 1
    }

    func rename(_ name: String) { mutate { $0.name = name } }

    func setSkeleton(_ id: String) {
        guard id != spec.skeleton, var t = RigTemplates.template(id) else { return }
        t.name = spec.name
        t.interjection = spec.interjection
        t.style = spec.style
        mutate { $0 = t }
        selected = "body"
    }

    func hex(_ c: Color) -> String {
        (NSColor(c).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)).hex
    }

    /// 펜·동그라미로 그린 모양을 고른 부위에 더한다
    func addShape(_ path: CGPath) {
        let d = SVGPath.string(from: path, precision: 1)
        let fill = hex(paint)
        let line = !markMode
        let id = selected
        mutate { s in
            var part = s.parts[id] ?? RigPart()
            var shapes = part.shapes ?? []
            shapes.append(RigShape(d: d, fill: fill, line: line ? nil : false))
            part.shapes = shapes
            if part.parent == nil, Skeleton.isAccessory(id) { part.parent = s.parts["head"] != nil ? "head" : "body" }
            s.parts[id] = part
        }
    }

    func translatePart(_ id: String, by d: CGSize) {
        mutate { s in
            guard var part = s.parts[id] else { return }
            var tf = CGAffineTransform(translationX: d.width, y: d.height)
            part.shapes = part.shapes?.map { sh in
                guard let p = try? SVGPath.parse(sh.d), let moved = p.copy(using: &tf) else { return sh }
                var out = sh
                out.d = SVGPath.string(from: moved, precision: 1)
                return out
            }
            if var r = part.imageRect, r.count == 4 { r[0] += Double(d.width); r[1] += Double(d.height); part.imageRect = r }
            let pv = part.pivot.map { CGPoint(x: $0[0], y: $0[1]) } ?? self.skeleton.bone(id)?.pivot
            if let pv { part.pivot = [Double(pv.x + d.width), Double(pv.y + d.height)].map { ($0 * 10).rounded() / 10 } }
            s.parts[id] = part
        }
    }

    func setPivot(_ id: String, to p: CGPoint) {
        mutate { s in
            var part = s.parts[id] ?? RigPart()
            part.pivot = [Double(p.x), Double(p.y)].map { ($0 * 10).rounded() / 10 }
            s.parts[id] = part
        }
    }

    func setFace(at p: CGPoint, onHead: Bool) {
        mutate { s in
            s.face.anchor = [Double(p.x), Double(p.y)].map { ($0 * 10).rounded() / 10 }
            s.face.parent = onHead ? "head" : "body"
        }
    }

    func updateFace(_ change: (inout RigFace) -> Void) { mutate { change(&$0.face) } }

    /// 점을 덮는 맨 위 모양(고른 부위 먼저)을 지운다
    func erase(at p: CGPoint) {
        let order = [selected] + renderer.parts.reversed().map(\.id).filter { $0 != selected }
        for id in order {
            guard let part = spec.parts[id] else { continue }
            if let shapes = part.shapes {
                for (i, sh) in shapes.enumerated().reversed() {
                    if let path = try? SVGPath.parse(sh.d), path.contains(p) {
                        mutate { s in
                            s.parts[id]?.shapes?.remove(at: i)
                            if s.parts[id]?.shapes?.isEmpty == true, s.parts[id]?.image == nil, id != "body" { s.parts[id] = nil }
                        }
                        selected = id
                        return
                    }
                }
            }
            if part.image != nil, let r = part.imageRect, r.count == 4,
               CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).contains(p) {
                mutate { s in
                    s.parts[id]?.image = nil
                    s.parts[id]?.imageRect = nil
                }
                selected = id
                return
            }
        }
    }

    /// 점에 있는 부위 (맨 위부터)
    func part(at p: CGPoint) -> String? {
        for part in renderer.parts.reversed() {
            if let sil = part.silhouette, sil.contains(p) { return part.id }
            if part.image != nil, part.imageRect.contains(p) { return part.id }
        }
        return nil
    }

    func pivot(of id: String) -> CGPoint? {
        if let pv = spec.parts[id]?.pivot, pv.count == 2 { return CGPoint(x: pv[0], y: pv[1]) }
        return skeleton.bone(id)?.pivot
    }

    func clearSelected() {
        let id = selected
        mutate { s in
            if id == "body" { s.parts[id] = RigPart(shapes: []) } else { s.parts[id] = nil }
        }
    }

    func addAccessory() {
        guard let n = (1...6).first(where: { spec.parts["acc\($0)"] == nil }) else {
            message = L10n.t("장식은 6개까지예요")
            return
        }
        selected = "acc\(n)"
        tool = .pen
        message = L10n.format("장식 %lld: 그려서 붙여요 (머리에 붙음)", n)
    }

    func setAccessoryParent(_ parent: String) {
        let id = selected
        mutate { $0.parts[id]?.parent = parent }
    }

    func setOutline(_ c: Color) { let h = hex(c); mutate { $0.outline = h } }
    func setLineWidth(_ w: Double) { mutate { $0.lineWidth = (w * 10).rounded() / 10 } }

    /// 고른 부위의 모든 모양 색을 바꾼다
    func recolorSelected(_ c: Color, marks: Bool) {
        let h = hex(c), id = selected
        mutate { s in
            let recolored = s.parts[id]?.shapes?.map { sh -> RigShape in
                var o = sh
                if (sh.line == false) == marks { o.fill = h }
                return o
            }
            s.parts[id]?.shapes = recolored
        }
    }

    // MARK: - 그림 넣기

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .webP, .jpeg, .heic]
        panel.message = L10n.format("%@에 넣을 그림 (투명 배경 PNG 추천)", label(selected))
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url)
    }

    func importImage(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard PetBundle.imageExtensions.contains(ext),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            message = L10n.t("그림을 읽을 수 없어요")
            return
        }
        let id = selected
        let name = "\(id)-\(Int(Date().timeIntervalSince1970) % 100000).\(ext)"
        do {
            try FileManager.default.copyItem(at: url, to: draftFolder.appendingPathComponent(name))
        } catch {
            message = L10n.format("그림을 복사하지 못했어요: %@", error.localizedDescription)
            return
        }
        // 지금 부위가 있던 자리에, 없으면 관절 근처에 비율 맞춰 놓는다
        let existing = renderer.parts.first { $0.id == id }?.silhouette?.boundingBoxOfPath
        let pv = pivot(of: id) ?? CGPoint(x: 50, y: 60)
        var box = existing ?? CGRect(x: pv.x - 15, y: pv.y - 30, width: 30, height: 30)
        let aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
        if box.width / box.height > aspect { let w = box.height * aspect; box = CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height) }
        else { let h = box.width / aspect; box = CGRect(x: box.minX, y: box.maxY - h, width: box.width, height: h) }
        mutate { s in
            var part = s.parts[id] ?? RigPart()
            part.image = name
            part.imageRect = [box.minX, box.minY, box.width, box.height].map { (Double($0) * 10).rounded() / 10 }
            if Skeleton.isAccessory(id), part.parent == nil { part.parent = s.parts["head"] != nil ? "head" : "body" }
            s.parts[id] = part
        }
    }

    func scaleImage(_ factor: Double) {
        let id = selected
        mutate { s in
            guard let r = s.parts[id]?.imageRect, r.count == 4 else { return }
            let cx = r[0] + r[2] / 2, cy = r[1] + r[3] / 2
            let w = r[2] * factor, h = r[3] * factor
            s.parts[id]?.imageRect = [cx - w / 2, cy - h / 2, w, h].map { ($0 * 10).rounded() / 10 }
        }
    }

    // MARK: - AI 초안

    func generateAI() {
        guard let config = director?.config, !aiBusy else { return }
        aiBusy = true
        message = L10n.t("AI가 그리는 중이에요… (30초~1분)")
        let desc = String(aiPrompt.prefix(400))
        MakerAI.generate(description: desc, skeleton: skeleton, config: config) { [weak self] spec, note in
            guard let self else { return }
            self.aiBusy = false
            guard var spec else {
                self.message = note
                return
            }
            if !self.spec.name.trimmingCharacters(in: .whitespaces).isEmpty { spec.name = self.spec.name }
            if let i = self.spec.interjection { spec.interjection = i }
            spec.style = self.spec.style
            spec.scale = self.spec.scale
            self.mutate { $0 = spec }
            self.selected = "body"
            self.message = note ?? L10n.t("초안이 왔어요! 마음에 안 드는 부위는 지우고 펜으로 다시 그려 보세요.")
        }
    }

    // MARK: - 스타일

    func style() -> PetStyle { spec.style ?? PetStyle() }

    func updateStyle(_ change: (inout PetStyle) -> Void) {
        mutate { s in
            var st = s.style ?? PetStyle()
            change(&st)
            s.style = st.isEmpty ? nil : st
        }
    }

    // MARK: - 저장

    func validationIssues() -> [String] {
        spec.validate { [draftFolder] name in FileManager.default.fileExists(atPath: draftFolder.appendingPathComponent(name).path) }
    }

    @discardableResult
    func save() -> String? {
        var s = spec
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = L10n.t("새 친구") }
        let issues = s.validate { [draftFolder] in FileManager.default.fileExists(atPath: draftFolder.appendingPathComponent($0).path) }
        guard issues.isEmpty else {
            message = L10n.t("저장 전에 고쳐 주세요: ") + issues.prefix(3).joined(separator: " / ")
            return nil
        }
        do {
            try PawmitPaths.ensureHome()
            let fm = FileManager.default
            let folder: URL
            if let editingFolder { folder = editingFolder } else {
                let base = PetBundle.slug(s.name)
                var f = PawmitPaths.petsDir.appendingPathComponent(base, isDirectory: true)
                var n = 2
                while fm.fileExists(atPath: f.path) { f = PawmitPaths.petsDir.appendingPathComponent("\(base)-\(n)", isDirectory: true); n += 1 }
                try fm.createDirectory(at: f, withIntermediateDirectories: true)
                folder = f
            }
            for img in s.parts.values.compactMap(\.image) {
                let dest = folder.appendingPathComponent(img)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: draftFolder.appendingPathComponent(img), to: dest) }
            }
            try Data(s.json.encoded(pretty: true).utf8).write(to: folder.appendingPathComponent("pet.json"), options: .atomic)
            editingFolder = folder
            spec = s
            let id = "folder:\(folder.lastPathComponent)"
            savedID = id
            director?.petDefinitionChanged(id)
            message = L10n.format("저장했어요: %@", folder.lastPathComponent)
            return id
        } catch {
            message = L10n.format("저장 실패: %@", error.localizedDescription)
            return nil
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: draftFolder)
    }
}
