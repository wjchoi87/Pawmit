import AppKit
import ImageIO
import PawmitCore

/// 사용자 이미지 펫 렌더러.
///
/// 지원 형식
/// 1. Codex pet: `pet.json` + `spritesheet.webp|png` (192×208 셀, 8열 × 9행, v2는 11행).
///    셀 규격과 행별 프레임·ms는 openai/codex(Apache-2.0)의 pets 데이터를 정리한 hookling(MIT)
///    `assets/pet/animations.json`, OpenPets(MIT) `codex-pets-core.ts`를 따랐다.
/// 2. 폴더 팩: `idle.gif`, `walk.gif`, `sleep.png` ... 처럼 상태 이름 파일 (GIF·APNG·WebP·PNG).
///    GIF/APNG 프레임 delay 처리는 bssm-oss/desktop-pet(MIT) `GIFDecoder`·`APNGDecoder`를 참고.
final class SpritePackRenderer: PetRenderer {
    struct Clip {
        var frames: [CGImage]
        var delays: [TimeInterval]
        /// 원본이 이미 이 방향을 보고 있으면 뒤집지 않는다
        var facing: Facing?
        var total: TimeInterval { delays.reduce(0, +) }

        func frame(at t: TimeInterval) -> CGImage {
            guard frames.count > 1, total > 0 else { return frames[0] }
            var time = t.truncatingRemainder(dividingBy: total)
            for (i, d) in delays.enumerated() {
                if time < d { return frames[i] }
                time -= d
            }
            return frames[frames.count - 1]
        }
    }

    let name: String
    private var clips: [String: Clip] = [:]
    /// 원본 그림이 기본으로 바라보는 방향
    private let nativeFacing: Facing
    /// 렌더러 단위 좌표에서의 그림 높이 (기본 펫과 비슷한 크기)
    private let unitHeight: CGFloat
    private var aspect: CGFloat = 1

    private init(name: String, nativeFacing: Facing, unitHeight: CGFloat) {
        self.name = name
        self.nativeFacing = nativeFacing
        self.unitHeight = unitHeight
    }

    // MARK: - 로딩

    static let codexRows: [(name: String, durations: [Int])] = [
        ("idle", [1680, 660, 660, 840, 840, 1920]),
        ("running-right", [120, 120, 120, 120, 120, 120, 120, 220]),
        ("running-left", [120, 120, 120, 120, 120, 120, 120, 220]),
        ("waving", [140, 140, 140, 280]),
        ("jumping", [140, 140, 140, 140, 280]),
        ("failed", [140, 140, 140, 140, 140, 140, 140, 240]),
        ("waiting", [150, 150, 150, 150, 150, 260]),
        ("running", [120, 120, 120, 120, 120, 220]),
        ("review", [150, 150, 150, 150, 150, 280]),
    ]

    /// Codex pet 폴더 (`pet.json` + spritesheet)
    static func loadCodex(folder: URL) -> SpritePackRenderer? {
        let meta = (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
        let sheetName = meta?["spritesheetPath"]?.string ?? "spritesheet.webp"
        let candidates = [sheetName, "spritesheet.webp", "spritesheet.png"].map { folder.appendingPathComponent($0) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cellW = 192, cellH = 208
        guard sheet.width == cellW * 8, sheet.height == cellH * 9 || sheet.height == cellH * 11 else {
            Log.info("codex pet \(folder.lastPathComponent): 시트 크기 \(sheet.width)x\(sheet.height) 미지원")
            return nil
        }
        let name = meta?["displayName"]?.string ?? folder.lastPathComponent
        let r = SpritePackRenderer(name: name, nativeFacing: .right, unitHeight: 62)
        r.aspect = CGFloat(cellW) / CGFloat(cellH)
        for (row, def) in codexRows.enumerated() {
            var frames: [CGImage] = []
            for col in 0..<def.durations.count {
                if let img = sheet.cropping(to: CGRect(x: col * cellW, y: row * cellH, width: cellW, height: cellH)) {
                    frames.append(img)
                }
            }
            guard !frames.isEmpty else { continue }
            let facing: Facing? = def.name == "running-right" ? .right : (def.name == "running-left" ? .left : nil)
            r.clips[def.name] = Clip(frames: frames, delays: def.durations.prefix(frames.count).map { Double($0) / 1000 }, facing: facing)
        }
        return r.clips["idle"] == nil ? nil : r
    }

    /// 상태 이름 파일 폴더
    static func loadFolder(folder: URL) -> SpritePackRenderer? {
        let meta = (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
        if meta?["spritesheetPath"] != nil || FileManager.default.fileExists(atPath: folder.appendingPathComponent("spritesheet.webp").path) {
            return loadCodex(folder: folder)
        }
        let native: Facing = meta?["facing"]?.string == "left" ? .left : .right
        let height = CGFloat(meta?["height"]?.number ?? 60)
        let r = SpritePackRenderer(name: meta?["name"]?.string ?? folder.lastPathComponent, nativeFacing: native, unitHeight: height)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ["gif", "png", "apng", "webp", "jpg", "jpeg", "heic"].contains(ext) else { continue }
            let key = file.deletingPathExtension().lastPathComponent.lowercased()
            if var clip = decode(file) {
                if key.hasSuffix("_left") || key.hasSuffix("-left") { clip.facing = .left }
                if key.hasSuffix("_right") || key.hasSuffix("-right") { clip.facing = .right }
                r.clips[key] = clip
                if key == "idle", let f = clip.frames.first { r.aspect = CGFloat(f.width) / CGFloat(max(1, f.height)) }
            }
        }
        if r.clips["idle"] == nil, let any = r.clips.values.first { r.clips["idle"] = any }
        return r.clips.isEmpty ? nil : r
    }

    static func decode(_ url: URL) -> Clip? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        // 큰 애니메이션은 메모리를 많이 먹으므로 앞쪽 240프레임까지만
        for i in 0..<min(count, 240) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, opts) else { continue }
            frames.append(img)
            delays.append(frameDelay(src, i))
        }
        return frames.isEmpty ? nil : Clip(frames: frames, delays: delays, facing: nil)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dict, unclamped, clamped) in dicts {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            if let u = d[unclamped] as? Double, u > 0 { return max(u, 0.02) }
            if let c = d[clamped] as? Double, c > 0 { return max(c, 0.02) }
        }
        return 0.1
    }

    // MARK: - 상태 → 클립

    private static let fallbacks: [PetAnim: [String]] = [
        .idle: ["idle"],
        .sit: ["sit", "idle"],
        .walk: ["walk", "running", "idle"],
        .run: ["run", "walk", "running", "idle"],
        .sleep: ["sleep", "sit", "idle"],
        .eat: ["eat", "sit", "idle"],
        .dig: ["dig", "play", "running", "walk", "idle"],
        .draw: ["draw", "walk", "review", "idle"],
        .play: ["play", "happy", "jumping", "idle"],
        .pounce: ["pounce", "play", "jumping", "idle"],
        .alert: ["alert", "wave", "waving", "idle"],
        .happy: ["happy", "jumping", "idle"],
        .sad: ["sad", "failed", "sit", "idle"],
        .groom: ["groom", "sit", "idle"],
        .think: ["think", "review", "sit", "idle"],
        .drag: ["drag", "fall", "waiting", "idle"],
        .fall: ["fall", "drag", "waiting", "idle"],
        .wave: ["wave", "waving", "happy", "idle"],
    ]

    private func clip(for pose: PetPose) -> Clip {
        let moving = pose.anim == .walk || pose.anim == .run || pose.anim == .draw
        if moving {
            let dir = pose.facing == .left ? "left" : "right"
            for key in ["\(pose.anim.rawValue)_\(dir)", "\(pose.anim.rawValue)-\(dir)", "running-\(dir)", "walk_\(dir)"] {
                if let c = clips[key] { return c }
            }
        }
        for key in Self.fallbacks[pose.anim] ?? ["idle"] {
            if let c = clips[key] { return c }
        }
        return clips["idle"] ?? clips.values.first!
    }

    // MARK: - PetRenderer

    var handlesFacing: Bool { true }

    func draw(_ pose: PetPose, in ctx: CGContext) {
        let clip = clip(for: pose)
        let img = clip.frame(at: pose.animTime)
        let h = unitHeight
        let w = h * aspect
        // 그림자
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.14))
        ctx.fillEllipse(in: CGRect(x: -w * 0.32, y: -2.5 - pose.hop, width: w * 0.64, height: 5))
        ctx.saveGState()
        // 그림이 한 장뿐이어도 살아 보이게: 걷기 뒤뚱·숨쉬기·모션 층(기울기·통통·찌그러짐)
        let t = pose.motionTime
        var lean: CGFloat = 0, bounce: CGFloat = 0, squash: CGFloat = 1
        let single = clip.frames.count == 1
        if single {
            switch pose.anim {
            case .walk, .run, .draw, .dig:
                lean += sin(pose.walkPhase) * (pose.anim == .run ? 0.08 : 0.06)
                bounce += abs(sin(pose.walkPhase)) * (pose.anim == .run ? 4 : 2.5)
            case .sleep:
                squash *= 0.92 + 0.02 * CGFloat(sin(pose.clock * 1.6))
            case .happy, .alert, .wave, .play:
                bounce += abs(CGFloat(sin(pose.animTime * 9))) * 3
            default:
                squash *= 1 + 0.018 * CGFloat(sin(pose.clock * 2.3))
            }
        }
        if let m = pose.motion {
            if let l = m.lean { lean += CGFloat(l.value(at: t)) }
            if let b = m.bounce { bounce += CGFloat(b.base + abs(b.amp * sin(2 * .pi * b.freq * t + b.phase))) }
            if let q = m.squash { squash *= CGFloat(q.value(at: t)) }
            if let sw = m.sway { ctx.translateBy(x: CGFloat(sw.value(at: t)), y: 0) }
        }
        ctx.translateBy(x: 0, y: bounce)
        ctx.rotate(by: lean * (pose.facing == .left ? -1 : 1))
        ctx.scaleBy(x: (1 / max(0.6, squash).squareRoot()) * (1 + 0.3 * pose.chubby), y: squash)
        let source = clip.facing ?? nativeFacing
        if source != pose.facing && clip.facing == nil {
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.interpolationQuality = img.width < 96 ? .none : .high
        if pose.anim == .sleep { ctx.setAlpha(0.95) }
        ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    func silhouette(_ pose: PetPose) -> CGPath {
        let h = unitHeight, w = h * aspect
        return CGPath(roundedRect: CGRect(x: -w * 0.36, y: 0, width: w * 0.72, height: h * 0.86), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    func headTop(_ pose: PetPose) -> CGPoint { CGPoint(x: 0, y: unitHeight * 0.9) }
    func mouthPoint(_ pose: PetPose) -> CGPoint { CGPoint(x: unitHeight * aspect * 0.18, y: unitHeight * 0.45) }
}
