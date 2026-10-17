import CoreGraphics
import Foundation
import PawmitCore

/// 펫 렌더러 공통 인터페이스. 좌표계는 발 중심 (0,0), y 위쪽, 오른쪽을 바라보는 기준.
protocol PetRenderer: AnyObject {
    func draw(_ pose: PetPose, in ctx: CGContext)
    /// 히트 테스트용 실루엣
    func silhouette(_ pose: PetPose) -> CGPath
    /// 머리 위 지점 (말풍선·파티클 기준)
    func headTop(_ pose: PetPose) -> CGPoint
    /// 입 위치 (크레용·먹이)
    func mouthPoint(_ pose: PetPose) -> CGPoint
    /// true면 렌더러가 좌우 방향을 직접 처리한다 (방향별 행이 있는 스프라이트 팩)
    var handlesFacing: Bool { get }
}

extension PetRenderer {
    var handlesFacing: Bool { false }
}

/// 몸통 프레임 캐시를 쓰는 렌더러 (코드로 그리는 기본 펫).
/// 자주 쓰는 동작은 몸통을 스프라이트처럼 몇 장만 그려 재사용하고, 눈·입은 작은 얼굴 레이어로 따로 그린다.
protocol LayeredPetRenderer: PetRenderer {
    /// 캐시를 구분하는 이름 (종족·색)
    var cacheID: String { get }
    /// 캐시 프레임이 차지하는 영역 (단위 좌표, 발 기준, x는 0 기준 대칭)
    var cacheBounds: CGRect { get }
    /// 얼굴 레이어 영역 (x는 0 기준 대칭)
    var faceBounds: CGRect { get }
    /// 그림자 (단위 좌표 사각형, 불투명도). hop과 무관하게 바닥에 그린다.
    func shadow(_ pose: PetPose) -> (CGRect, CGFloat)
    /// 그림자 없이 몸 전체(얼굴 포함)
    func renderBody(_ pose: PetPose, in ctx: CGContext, face: Bool)
    /// 얼굴만 (눈·볼·입·땀)
    func renderFace(_ pose: PetPose, in ctx: CGContext)
    /// 얼굴이 바뀌었는지 비교할 키
    func faceKey(_ pose: PetPose) -> String
}

/// 캐시 가능한 포즈를 반복 루프의 몇 칸으로 양자화한다.
/// 가만히·앉기: 3초 루프 12칸, 잠: 4초 루프 8칸, 걷기·달리기: 한 걸음 8칸.
enum FrameQuantizer {
    static let idlePeriod = 3.0, idleFrames = 12
    static let sleepPeriod = 4.0, sleepFrames = 8
    static let stepFrames = 8

    static func quantize(_ pose: PetPose) -> (key: String, pose: PetPose)? {
        guard pose.motion == nil, pose.crayon == nil, !pose.mop, pose.stretch == 1, pose.scale == 1, pose.opacity == 1,
              pose.heat < 0.6 else { return nil }
        var q = pose
        q.hop = 0
        q.look = .zero
        q.blink = 0
        let bucket: Int
        switch pose.anim {
        case .idle, .sit:
            bucket = Int(pose.clock.truncatingRemainder(dividingBy: idlePeriod) / idlePeriod * Double(idleFrames)) % idleFrames
            q.clock = Double(bucket) * idlePeriod / Double(idleFrames)
            q.animTime = 0
        case .sleep:
            bucket = Int(pose.clock.truncatingRemainder(dividingBy: sleepPeriod) / sleepPeriod * Double(sleepFrames)) % sleepFrames
            q.clock = Double(bucket) * sleepPeriod / Double(sleepFrames)
            q.animTime = 0
        case .walk, .run:
            let twoPi = CGFloat.pi * 2
            let phase = pose.walkPhase.truncatingRemainder(dividingBy: twoPi)
            bucket = Int((phase < 0 ? phase + twoPi : phase) / twoPi * CGFloat(stepFrames)) % stepFrames
            q.walkPhase = CGFloat(bucket) * twoPi / CGFloat(stepFrames)
            q.clock = 0
            q.animTime = 0
        default:
            return nil
        }
        let chubby = Int((pose.chubby * 20).rounded())
        q.chubby = CGFloat(chubby) / 20
        return ("\(pose.anim.rawValue)/\(bucket)/c\(chubby)", q)
    }
}

/// 렌더링된 몸통 프레임 저장소 (모든 펫 공용, 용량 상한이 있는 LRU)
@MainActor
final class FrameCache {
    static let shared = FrameCache()
    /// 끄면 매 프레임 직접 그린다 (비교 측정용)
    var enabled = true
    var maxBytes = 28 * 1024 * 1024
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private(set) var bytes = 0
    private(set) var hits = 0
    private(set) var misses = 0

    func image(_ key: String, make: () -> CGImage?) -> CGImage? {
        if let img = images[key] {
            hits += 1
            if let i = order.firstIndex(of: key), i < order.count - 8 {
                order.remove(at: i)
                order.append(key)
            }
            return img
        }
        misses += 1
        guard let img = make() else { return nil }
        images[key] = img
        order.append(key)
        bytes += img.bytesPerRow * img.height
        while bytes > maxBytes, let old = order.first {
            order.removeFirst()
            if let o = images.removeValue(forKey: old) { bytes -= o.bytesPerRow * o.height }
        }
        return img
    }

    func clear() {
        images.removeAll()
        order.removeAll()
        bytes = 0
    }

    var count: Int { images.count }
}

extension CatRenderer: LayeredPetRenderer {}

/// 펫 종류 (설정의 `pet` 값 하나에 대응)
struct PetIdentity {
    var id: String
    var name: String
    var interjection: String
    var renderer: PetRenderer
    /// 기본 펫 대비 화면 크기 보정
    var scale: CGFloat
}

enum PetRoster {
    struct Entry {
        var id: String
        var name: String
    }

    /// 기본 펫 (PetCatalog.builtinJSON 순서)
    static var builtins: [Entry] {
        PetCatalog.builtins.compactMap { v in
            guard let id = v["id"]?.string, let name = PetCatalog.localized(v, "name") else { return nil }
            return Entry(id: id, name: v["kind"]?.string == "cat" ? L10n.format("%@ (사족 고양이)", name) : name)
        }
    }

    /// `~/.pawmit/pets/<폴더>` 커스텀 팩
    static func customPacks() -> [Entry] {
        let dir = PawmitPaths.petsDir
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { folder -> Entry in
                let meta = (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
                let name = meta?["name"]?.string ?? meta?["displayName"]?.string ?? folder.lastPathComponent
                return Entry(id: "folder:\(folder.lastPathComponent)", name: name)
            }
            .sorted { $0.name < $1.name }
    }

    /// `~/.codex/pets/<id>` — Codex에 이미 설치한 펫을 그대로 읽는다 (복사·재배포하지 않음)
    static func codexPets() -> [Entry] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let dir = home.appendingPathComponent("pets")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pet.json").path) }
            .map { folder -> Entry in
                let meta = (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
                return Entry(id: "codex:\(folder.path)", name: meta?["displayName"]?.string ?? folder.lastPathComponent)
            }
    }

    /// 스타일(PetStyles.effective = pet.json style + 설정 petStyles[id])의 색 바꾸기·말버릇을 덮어 적용한다. styled: false면 원래 모습.
    static func make(id: String, config: PawmitConfig, styled: Bool = true) -> PetIdentity {
        let style = styled ? PetStyles.effective(id, config: config) : PetStyle()
        let prefix = style.speech?.prefix.flatMap { $0.isEmpty ? nil : $0 }
        if var species = ChibiSpecies.named(id) {
            PetStyles.apply(style.colors, to: &species)
            return PetIdentity(id: id, name: species.name, interjection: prefix ?? species.interjection,
                               renderer: ChibiRenderer(species: species), scale: 1)
        }
        if id == "cat" {
            let def = PetCatalog.builtin("cat")
            var palette = CatPalette.coat(config.catCoat)
            PetStyles.apply(style.colors, to: &palette)
            let key = style.colors?.isEmpty == false ? "\(config.catCoat)-styled-\(PetStyles.digest(style.colors))" : config.catCoat
            return PetIdentity(id: id, name: def.flatMap { PetCatalog.localized($0, "name") } ?? "Cheese",
                               interjection: prefix ?? def.flatMap { PetCatalog.localized($0, "interjection") } ?? "",
                               renderer: CatRenderer(palette: palette, key: key), scale: CGFloat(def?["scale"]?.number ?? 0.86))
        }
        // folder:<이름> = ~/.pawmit/pets 안, path:<경로> = 아무 폴더 (설치 전 미리보기용)
        if let (folder, meta) = PetStyles.petJSON(id) {
            if let meta, var species = ChibiSpecies.from(json: meta, fallbackName: folder.lastPathComponent) {
                species.id = id
                PetStyles.apply(style.colors, to: &species)
                let scale = CGFloat(PetCatalog.resolve(meta)["scale"]?.number ?? 1)
                return PetIdentity(id: id, name: species.name, interjection: prefix ?? species.interjection, renderer: ChibiRenderer(species: species),
                                   scale: max(0.5, min(1.5, scale)))
            }
            if let meta, meta["kind"]?.string == "rig", let r = RigRenderer.load(folder: folder, json: meta, key: id, colors: style.colors ?? [:]) {
                return PetIdentity(id: id, name: r.spec.name, interjection: prefix ?? r.spec.interjection ?? "",
                                   renderer: r, scale: max(0.5, min(1.5, CGFloat(r.spec.scale ?? 1))))
            }
            if let meta, PetCatalog.resolve(meta)["kind"]?.string == "cat" {
                let v = PetCatalog.resolve(meta)
                var palette = CatPalette.from(json: meta)
                PetStyles.apply(style.colors, to: &palette)
                return PetIdentity(id: id, name: v["name"]?.string ?? folder.lastPathComponent, interjection: prefix ?? v["interjection"]?.string ?? (L10n.isKorean ? "냐옹" : "Meow"),
                                   renderer: CatRenderer(palette: palette, key: id + PetStyles.digest(style.colors)),
                                   scale: max(0.5, min(1.5, CGFloat(v["scale"]?.number ?? 0.86))))
            }
            if let r = SpritePackRenderer.loadFolder(folder: folder) {
                return PetIdentity(id: id, name: r.name, interjection: prefix ?? "", renderer: r, scale: 1)
            }
        }
        if id.hasPrefix("codex:") {
            let folder = URL(fileURLWithPath: String(id.dropFirst("codex:".count)))
            if let r = SpritePackRenderer.loadCodex(folder: folder) {
                return PetIdentity(id: id, name: r.name, interjection: prefix ?? "", renderer: r, scale: 1)
            }
        }
        Log.info("펫 '\(id)'을(를) 불러오지 못해 몽글이로 대신합니다")
        return make(id: "mongle", config: config, styled: styled)
    }
}
