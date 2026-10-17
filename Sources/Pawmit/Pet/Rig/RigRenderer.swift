import CoreGraphics
import Foundation
import ImageIO
import PawmitCore

/// 메이커 펫(pet.json `"kind": "rig"`) 렌더러.
///
/// 부위 그림(SVG path 또는 그림 파일)을 뼈대 관절에 붙이고 RigPoser가 정한 포즈대로 돌려 그린다.
/// 벡터 부위는 기본 펫과 같은 공통 그리기(InkKit)를 쓴다: 모든 부위 외곽선을 한 실루엣으로 잇고,
/// 다른 부위 위에 겹친 부위만 얇은 주름선을 긋는다(관절 뿌리는 비워서 몸에서 자라난 것처럼).
/// 얼굴(눈·입·볼)은 코드로 그려서 기본 펫과 똑같이 표정이 바뀐다.
final class RigRenderer: LayeredPetRenderer {
    let spec: RigSpec
    let skeleton: Skeleton
    let cacheID: String
    /// 캔버스 1 = 펫 단위 0.8
    static let unit: CGFloat = 0.8

    struct Part {
        let id: String
        let bone: String
        let parent: String?
        let pivot: CGPoint
        let z: Int
        let lines: [(CGPath, CGColor)]
        let marks: [(CGPath, CGColor)]
        /// 외곽선 모양들을 합친 것 (무늬 clip·주름선·히트 테스트)
        let silhouette: CGPath?
        let image: CGImage?
        let imageRect: CGRect
        /// 관절 뿌리를 비울지 (팔다리·꼬리·날개·귀)
        let rootGap: CGFloat
    }

    let parts: [Part]
    private let outline: CGColor
    private let lineWidth: CGFloat
    private let faceParent: String
    private let face: RigFace
    private let shapeSeed: UInt64
    private(set) var cacheBounds: CGRect = .zero
    private(set) var faceBounds: CGRect = .zero

    /// - folder: 그림 파일이 있는 폴더
    /// - colors: 스타일 색 바꾸기 (원래 색 → 새 색)
    init(spec: RigSpec, folder: URL?, key: String, colors: [String: String] = [:]) {
        self.spec = spec
        skeleton = Skeleton.named(spec.skeleton) ?? .biped
        let remap = Dictionary(uniqueKeysWithValues: colors.compactMap { k, v -> (String, String)? in
            PetCatalog.isHexColor(k) && PetCatalog.isHexColor(v) ? (k.uppercased(), v) : nil
        })
        func color(_ hex: String) -> CGColor {
            CGColor.fromHex(remap[hex.uppercased()] ?? hex) ?? CGColor(gray: 1, alpha: 1)
        }
        outline = color(spec.outline)
        lineWidth = CGFloat(spec.lineWidth ?? 3)
        face = spec.face
        faceParent = spec.face.parent ?? (spec.parts["head"] != nil ? "head" : "body")
        shapeSeed = Ink.seed(key)
        let sk = skeleton
        var built: [Part] = []
        for (id, p) in spec.parts {
            let bone = sk.bone(id)
            let parentBone = Skeleton.isAccessory(id) ? (p.parent ?? (spec.parts["head"] != nil ? "head" : "body")) : nil
            var lines: [(CGPath, CGColor)] = [], marks: [(CGPath, CGColor)] = []
            for s in p.shapes ?? [] {
                guard let path = try? SVGPath.parse(s.d) else { continue }
                if s.line == false { marks.append((path, color(s.fill))) } else { lines.append((path, color(s.fill))) }
            }
            var sil: CGPath?
            if !lines.isEmpty {
                let u = CGMutablePath()
                for (path, _) in lines { u.addPath(path) }
                sil = u
            }
            var image: CGImage?
            if let name = p.image, let folder, PetBundle.isSafeName(name),
               let src = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) {
                image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            let r = p.imageRect ?? [0, 0, 0, 0]
            let pivot = p.pivot.map { CGPoint(x: $0[0], y: $0[1]) } ?? bone?.pivot
                ?? (sil?.boundingBoxOfPath).map { CGPoint(x: $0.midX, y: $0.maxY) } ?? CGPoint(x: 50, y: 60)
            let limb = id.hasPrefix("arm") || id.hasPrefix("leg") || id.hasPrefix("wing") || id == "tail" || id.hasPrefix("ear")
            built.append(Part(id: id, bone: bone != nil ? id : (parentBone ?? "body"), parent: bone?.parent ?? parentBone,
                              pivot: pivot, z: p.z ?? bone?.z ?? 4, lines: lines, marks: marks, silhouette: sil,
                              image: image, imageRect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                              rootGap: limb ? 3.6 : 0))
        }
        parts = built.sorted { $0.z == $1.z ? $0.id < $1.id : $0.z < $1.z }
        let digest = spec.json.encoded().utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        cacheID = "rig:\(key):\(String(digest, radix: 16)):\(colors.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined())"
        computeBounds()
    }

    /// 그림 폴더에서 읽기 (pet.json + 그림들)
    static func load(folder: URL, json: JSONValue, key: String, colors: [String: String]) -> RigRenderer? {
        guard let spec = RigSpec.decode(json) else { return nil }
        return RigRenderer(spec: spec, folder: folder, key: key, colors: colors)
    }

    // MARK: - 좌표

    /// 캔버스(y 아래) → 펫 단위(발 중심, y 위)
    static func toPet(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - 50) * unit, y: (RigSpec.groundY - p.y) * unit) }

    /// 펫 단위 컨텍스트를 캔버스 좌표로 그릴 수 있게
    private static func enterCanvas(_ ctx: CGContext) {
        ctx.scaleBy(x: unit, y: -unit)
        ctx.translateBy(x: -50, y: -RigSpec.groundY)
    }

    private static let canvasToPet = CGAffineTransform(translationX: -50, y: -RigSpec.groundY).concatenating(CGAffineTransform(scaleX: unit, y: -unit))

    /// 뼈마다 캔버스 좌표 변환 (부모 → 자식 순으로 누적)
    private func transforms(_ pose: RigPose) -> [String: CGAffineTransform] {
        let r = pose.root
        let ground = CGPoint(x: 50, y: RigSpec.groundY)
        let root = local(r, pivot: ground)
        var out: [String: CGAffineTransform] = [:]
        func world(_ bone: String, depth: Int = 0) -> CGAffineTransform {
            if let t = out[bone] { return t }
            guard depth < 6 else { return root }
            let b = skeleton.bone(bone)
            let pivot = parts.first { $0.id == bone }?.pivot ?? b?.pivot ?? CGPoint(x: 50, y: 70)
            let l = local(pose[bone], pivot: pivot)
            let parentT = b?.parent.map { world($0, depth: depth + 1) } ?? root
            let t = l.concatenating(parentT)
            out[bone] = t
            return t
        }
        for b in skeleton.bones { _ = world(b.id) }
        return out
    }

    /// 관절 기준 회전(화면 반시계 +)·크기·이동 → 캔버스 변환
    private func local(_ b: RigPose.Bone, pivot p: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -p.x, y: -p.y)
            .concatenating(CGAffineTransform(scaleX: b.sx, y: b.sy))
            .concatenating(CGAffineTransform(rotationAngle: -b.rot))
            .concatenating(CGAffineTransform(translationX: p.x + b.dx * 1, y: p.y - b.dy))
    }

    private func partTransform(_ part: Part, _ t: [String: CGAffineTransform]) -> CGAffineTransform {
        t[part.bone] ?? .identity
    }

    // MARK: - 그리기

    func draw(_ pose: PetPose, in ctx: CGContext) {
        let (srect, salpha) = shadow(pose)
        ctx.setFillColor(CGColor(gray: 0, alpha: salpha))
        ctx.fillEllipse(in: srect.offsetBy(dx: 0, dy: -pose.hop))
        renderBody(pose, in: ctx, face: true)
    }

    func renderBody(_ pose: PetPose, in ctx: CGContext, face drawFaceToo: Bool) {
        render(RigPoser.make(pose, skeleton: skeleton.id), pose: pose, in: ctx, face: drawFaceToo)
    }

    /// 그린 그대로의 쉬는 자세 (메이커 캔버스: 화면 좌표와 그린 좌표가 같아야 편집할 수 있다)
    func renderRest(in ctx: CGContext) {
        render(RigPose(), pose: PetPose(), in: ctx, face: true)
    }

    private func render(_ rp: RigPose, pose: PetPose, in ctx: CGContext, face drawFaceToo: Bool) {
        let t = transforms(rp)
        ctx.saveGState()
        Self.enterCanvas(ctx)

        // 1) 외곽선: 모든 벡터 부위를 한 실루엣으로 (아래쪽이 살짝 굵은 손그림 선)
        var outlinePaths: [CGPath] = []
        for part in parts {
            var tf = partTransform(part, t)
            for (path, _) in part.lines { if let p = path.copy(using: &tf) { outlinePaths.append(p) } }
        }
        Ink.sticker([], outline: outline, width: lineWidth, weight: 0.7, extraOutlines: outlinePaths, in: ctx)

        // 2) 채움: 뒤 → 앞. 앞 부위가 뒤 부위 위에 겹친 곳은 얇은 주름선
        let crease = Ink.tint(outline, 0.85)
        let below = CGMutablePath()
        for part in parts {
            var tf = partTransform(part, t)
            if let img = part.image, part.imageRect.width > 0 {
                ctx.saveGState()
                ctx.concatenate(tf)
                ctx.translateBy(x: part.imageRect.minX, y: part.imageRect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(origin: .zero, size: part.imageRect.size))
                ctx.restoreGState()
            }
            guard let sil = part.silhouette, let silT = sil.copy(using: &tf) else { continue }
            for (path, fill) in part.lines {
                guard let p = path.copy(using: &tf) else { continue }
                ctx.addPath(p)
                ctx.setFillColor(fill)
                ctx.fillPath()
            }
            if !part.marks.isEmpty {
                ctx.saveGState()
                ctx.addPath(silT)
                ctx.clip()
                for (path, fill) in part.marks {
                    guard let p = path.copy(using: &tf) else { continue }
                    ctx.addPath(p)
                    ctx.setFillColor(fill)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
            if !below.isEmpty {
                let root = part.pivot.applying(tf)
                Ink.crease(silT, inside: below, excluding: part.rootGap > 0 ? [(root, part.rootGap)] : [],
                           color: crease, width: lineWidth * 0.5, in: ctx)
            }
            if part.id == "body" || part.id == "head" {
                Ink.shade(silT, offset: CGVector(dx: -1.6, dy: 2.6), color: Ink.tint(outline, part.id == "body" ? 0.09 : 0.06), in: ctx)
            }
            below.addPath(silT)
        }
        if drawFaceToo { drawFace(rp, pose: pose, transforms: t, in: ctx) }
        ctx.restoreGState()
    }

    func renderFace(_ pose: PetPose, in ctx: CGContext) {
        let rp = RigPoser.make(pose, skeleton: skeleton.id)
        let t = transforms(rp)
        ctx.saveGState()
        Self.enterCanvas(ctx)
        drawFace(rp, pose: pose, transforms: t, in: ctx)
        ctx.restoreGState()
    }

    func faceKey(_ pose: PetPose) -> String {
        let rp = RigPoser.make(pose, skeleton: skeleton.id)
        let lx = Int((pose.look.dx * 4).rounded()), ly = Int((pose.look.dy * 4).rounded())
        return "\(rp.eyes)|\(rp.mouth)|\(lx),\(ly)|\(Int(rp.heat * 10))|\(rp.sweat)"
    }

    private func drawFace(_ rp: RigPose, pose: PetPose, transforms t: [String: CGAffineTransform], in ctx: CGContext) {
        guard face.anchor.count == 2 else { return }
        ctx.saveGState()
        ctx.concatenate(t[faceParent] ?? .identity)
        RigFaceArt.draw(face, anchor: CGPoint(x: face.anchor[0], y: face.anchor[1]), eyes: rp.eyes, mouth: rp.mouth,
                        look: pose.look, heat: rp.heat, sweat: rp.sweat, clock: pose.clock, outline: outline, in: ctx)
        ctx.restoreGState()
    }

    // MARK: - 위치

    func shadow(_ pose: PetPose) -> (CGRect, CGFloat) {
        let body = parts.first { $0.id == "body" }?.silhouette?.boundingBoxOfPath ?? CGRect(x: 35, y: 70, width: 30, height: 26)
        let k = max(0.45, 1 - pose.hop / 60)
        let rp = RigPoser.make(pose, skeleton: skeleton.id)
        // 떠 있으면(날개·통통 튀기) 그림자가 작고 옅다
        let lift = max(0, rp.root.dy) * Self.unit
        let f = k * max(0.5, 1 - lift / 40)
        let w = body.width * Self.unit * 1.05 * f
        return (CGRect(x: -w / 2, y: -2.5, width: w, height: 6 * f), 0.15 * f)
    }

    func silhouette(_ pose: PetPose) -> CGPath {
        let t = transforms(RigPoser.make(pose, skeleton: skeleton.id))
        let out = CGMutablePath()
        for part in parts {
            var tf = partTransform(part, t).concatenating(Self.canvasToPet)
            if let s = part.silhouette, let p = s.copy(using: &tf) { out.addPath(p) }
            if part.image != nil { out.addRect(part.imageRect, transform: tf) }
        }
        return out
    }

    func headTop(_ pose: PetPose) -> CGPoint {
        let t = transforms(RigPoser.make(pose, skeleton: skeleton.id))
        let top = parts.first { $0.id == "head" } ?? parts.first { $0.id == "body" }
        guard let top else { return CGPoint(x: 0, y: 60) }
        let box = top.silhouette?.boundingBoxOfPath ?? top.imageRect
        var highest = box.minY
        // 귀가 더 높으면 귀 위
        for ear in parts where ear.id.hasPrefix("ear") { highest = min(highest, (ear.silhouette?.boundingBoxOfPath ?? ear.imageRect).minY) }
        let p = CGPoint(x: box.midX, y: highest).applying(partTransform(top, t))
        return Self.toPet(p)
    }

    func mouthPoint(_ pose: PetPose) -> CGPoint {
        let t = transforms(RigPoser.make(pose, skeleton: skeleton.id))
        guard face.anchor.count == 2 else { return CGPoint(x: 6, y: 30) }
        let p = CGPoint(x: face.anchor[0], y: face.anchor[1] + 5).applying(t[faceParent] ?? .identity)
        return Self.toPet(p)
    }

    // MARK: - 캐시 영역

    /// 캐시되는 포즈(쉬기·앉기·걷기·달리기·잠)를 훑어 몸통·얼굴이 차지하는 영역을 구한다
    private func computeBounds() {
        var body = CGRect.null, faceBox = CGRect.null
        let faceR: CGFloat = 16
        for anim in [PetAnim.idle, .sit, .walk, .run, .sleep] {
            for i in 0..<8 {
                var p = PetPose()
                p.anim = anim
                p.clock = Double(i) * 0.5
                p.walkPhase = CGFloat(i) * .pi / 4
                for chubby in [0.0, 1.0] as [CGFloat] {
                    p.chubby = chubby
                    let t = transforms(RigPoser.make(p, skeleton: skeleton.id))
                    for part in parts {
                        var box = part.silhouette?.boundingBoxOfPath ?? .null
                        if part.image != nil { box = box.union(part.imageRect) }
                        guard !box.isNull else { continue }
                        body = body.union(box.applying(partTransform(part, t)))
                    }
                    if face.anchor.count == 2 {
                        let a = CGPoint(x: face.anchor[0], y: face.anchor[1])
                        faceBox = faceBox.union(CGRect(x: a.x - faceR, y: a.y - faceR, width: faceR * 2, height: faceR * 2)
                            .applying(t[faceParent] ?? .identity))
                    }
                }
            }
        }
        func pet(_ r: CGRect, margin: CGFloat) -> CGRect {
            guard !r.isNull else { return CGRect(x: -40, y: -6, width: 80, height: 90) }
            return r.applying(Self.canvasToPet).insetBy(dx: -margin, dy: -margin)
        }
        cacheBounds = pet(body, margin: lineWidth * Self.unit + 2)
        faceBounds = pet(faceBox, margin: 2)
    }
}
