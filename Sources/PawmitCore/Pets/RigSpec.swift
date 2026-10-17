import CoreGraphics
import Foundation

/// 메이커로 만든 펫 (pet.json `"kind": "rig"`).
///
/// 펫은 부위 그림의 묶음이고, 각 부위는 뼈대(skeleton)의 관절(pivot)에 붙는다. 앱의 포즈 엔진이 뼈대를 움직이므로
/// 생김새가 무엇이든 모든 행동·모션이 그대로 붙는다.
///
/// 좌표는 SVG와 같다: 100×100 캔버스, y는 아래로, 바닥선 y=96, 가운데 x=50, 오른쪽(또는 정면)을 본다.
/// 부위 모양은 SVG path(`d`)라서 그대로 SVG 뷰어에 붙여 확인할 수 있다.
public struct RigSpec: Codable, Equatable, Sendable {
    public var kind = "rig"
    public var name: String
    public var interjection: String?
    public var description: String?
    /// biped · quadruped · blob · winged
    public var skeleton: String
    /// 외곽선 색 (#RRGGBB)과 굵기(캔버스 단위)
    public var outline: String
    public var lineWidth: Double?
    public var parts: [String: RigPart]
    public var face: RigFace
    /// 펫 크기 보정 (0.5…1.5)
    public var scale: Double?
    /// 스타일(성격·말투·색). 앱 설정에서 바꾼 값이 있으면 그쪽이 우선.
    public var style: PetStyle?

    public init(name: String, skeleton: String, outline: String, parts: [String: RigPart], face: RigFace) {
        self.name = name
        self.skeleton = skeleton
        self.outline = outline
        self.parts = parts
        self.face = face
    }
}

public struct RigPart: Codable, Equatable, Sendable {
    /// 벡터 모양들. 앞의 모양부터 그린다.
    public var shapes: [RigShape]?
    /// 그림 파일(같은 폴더의 png 등)과 캔버스 위 위치 [x, y, w, h]
    public var image: String?
    public var imageRect: [Double]?
    /// 관절 위치 [x, y] (생략하면 뼈대 기본값)
    public var pivot: [Double]?
    /// 그리는 순서 (생략하면 뼈대 기본값, 클수록 앞)
    public var z: Int?
    /// 장식(acc…)이 붙을 뼈 (head·body …, 기본 head)
    public var parent: String?

    public init(shapes: [RigShape]? = nil, image: String? = nil, imageRect: [Double]? = nil, pivot: [Double]? = nil, z: Int? = nil, parent: String? = nil) {
        self.shapes = shapes
        self.image = image
        self.imageRect = imageRect
        self.pivot = pivot
        self.z = z
        self.parent = parent
    }
}

public struct RigShape: Codable, Equatable, Sendable {
    /// SVG path
    public var d: String
    public var fill: String
    /// false면 외곽선 없는 무늬 (같은 부위의 외곽선 모양 안쪽에만 칠해진다)
    public var line: Bool?

    public init(d: String, fill: String, line: Bool? = nil) {
        self.d = d
        self.fill = fill
        self.line = line
    }
}

public struct RigFace: Codable, Equatable, Sendable {
    /// 두 눈 사이 가운데 [x, y]
    public var anchor: [Double]
    /// 얼굴이 붙는 뼈 (head가 없으면 body)
    public var parent: String?
    /// dot · round · sparkle · sleepy · none
    public var eyes: String?
    public var eyeGap: Double?
    public var eyeSize: Double?
    public var eyeColor: String?
    /// smile · cat · tiny · none
    public var mouth: String?
    /// 볼터치 색 (없으면 볼터치 없음)
    public var blush: String?

    public init(anchor: [Double], parent: String? = nil, eyes: String? = nil, eyeGap: Double? = nil, eyeSize: Double? = nil,
                eyeColor: String? = nil, mouth: String? = nil, blush: String? = nil) {
        self.anchor = anchor
        self.parent = parent
        self.eyes = eyes
        self.eyeGap = eyeGap
        self.eyeSize = eyeSize
        self.eyeColor = eyeColor
        self.mouth = mouth
        self.blush = blush
    }
}

/// 뼈대 프리셋. 뼈 이름·부모·기본 관절·그리는 순서.
public struct Skeleton: Sendable {
    public struct Bone: Sendable {
        public let id: String
        public let label: String
        public let parent: String?
        public let pivot: CGPoint
        public let z: Int
        /// 필수 부위인지 (없으면 그 부위는 그냥 안 그림)
        public let required: Bool
    }

    public let id: String
    public let label: String
    public let summary: String
    public let bones: [Bone]

    public func bone(_ id: String) -> Bone? { bones.first { $0.id == id } }

    /// 장식은 acc1…acc6
    public static func isAccessory(_ id: String) -> Bool {
        id.hasPrefix("acc") && Int(id.dropFirst(3)).map { (1...6).contains($0) } == true
    }

    private static func b(_ id: String, _ label: String, _ parent: String?, _ x: CGFloat, _ y: CGFloat, _ z: Int, required: Bool = false) -> Bone {
        Bone(id: id, label: label, parent: parent, pivot: CGPoint(x: x, y: y), z: z, required: required)
    }

    public static let biped = Skeleton(id: "biped", label: L10n.t("두 발"), summary: L10n.t("아장아장 걷는 치비형"), bones: [
        b("tail", L10n.t("꼬리"), "body", 38, 84, -3),
        b("legL", L10n.t("왼다리"), "body", 44, 86, -1), b("legR", L10n.t("오른다리"), "body", 56, 86, -1),
        b("body", L10n.t("몸"), nil, 50, 84, 0, required: true),
        b("earL", L10n.t("왼귀"), "head", 38, 42, 1), b("earR", L10n.t("오른귀"), "head", 62, 42, 1),
        b("head", L10n.t("머리"), "body", 50, 66, 2),
        b("armL", L10n.t("왼팔"), "body", 37, 73, 3), b("armR", L10n.t("오른팔"), "body", 63, 73, 3),
    ])

    public static let quadruped = Skeleton(id: "quadruped", label: L10n.t("네 발"), summary: L10n.t("고양이·강아지처럼 네 발로 걷는"), bones: [
        b("tail", L10n.t("꼬리"), "body", 29, 72, -3),
        b("legBF", L10n.t("뒷다리(먼 쪽)"), "body", 39, 82, -2), b("legFF", L10n.t("앞다리(먼 쪽)"), "body", 61, 82, -2),
        b("body", L10n.t("몸"), nil, 47, 80, 0, required: true),
        b("legBN", L10n.t("뒷다리"), "body", 35, 82, 1), b("legFN", L10n.t("앞다리"), "body", 57, 82, 1),
        b("earL", L10n.t("뒤쪽 귀"), "head", 62, 50, 2), b("earR", L10n.t("앞쪽 귀"), "head", 72, 50, 2),
        b("head", L10n.t("머리"), "body", 62, 70, 3),
    ])

    public static let blob = Skeleton(id: "blob", label: L10n.t("다리 없음"), summary: L10n.t("슬라임·유령처럼 통통 튀며 다니는"), bones: [
        b("tail", L10n.t("꼬리"), "body", 30, 84, -3),
        b("body", L10n.t("몸"), nil, 50, 96, 0, required: true),
        b("earL", L10n.t("왼귀"), "body", 38, 58, -1), b("earR", L10n.t("오른귀"), "body", 62, 58, -1),
        b("head", L10n.t("머리(선택)"), "body", 50, 70, 2),
        b("armL", L10n.t("왼팔"), "body", 30, 82, 3), b("armR", L10n.t("오른팔"), "body", 70, 82, 3),
    ])

    public static let winged = Skeleton(id: "winged", label: L10n.t("날개"), summary: L10n.t("날개를 파닥이며 둥실 떠다니는"), bones: [
        b("wingL", L10n.t("왼날개"), "body", 42, 72, -4), b("wingR", L10n.t("오른날개"), "body", 58, 72, -4),
        b("tail", L10n.t("꼬리"), "body", 38, 84, -3),
        b("legL", L10n.t("왼다리"), "body", 44, 86, -1), b("legR", L10n.t("오른다리"), "body", 56, 86, -1),
        b("body", L10n.t("몸"), nil, 50, 84, 0, required: true),
        b("earL", L10n.t("왼귀"), "head", 38, 42, 1), b("earR", L10n.t("오른귀"), "head", 62, 42, 1),
        b("head", L10n.t("머리"), "body", 50, 66, 2),
        b("armL", L10n.t("왼팔"), "body", 37, 73, 3), b("armR", L10n.t("오른팔"), "body", 63, 73, 3),
    ])

    public static let all: [Skeleton] = [biped, quadruped, blob, winged]

    public static func named(_ id: String) -> Skeleton? { all.first { $0.id == id } }
}

extension RigSpec {
    public static let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    public static let groundY: CGFloat = 96

    /// 문제 목록 (비어 있으면 통과). fileExists: 그림 파일 확인 (nil이면 건너뜀)
    public func validate(fileExists: ((String) -> Bool)? = nil) -> [String] {
        var issues: [String] = []
        guard let sk = Skeleton.named(skeleton) else {
            return [L10n.format("skeleton '%@'은 없습니다 (%@)", skeleton, Skeleton.all.map(\.id).joined(separator: ", "))]
        }
        if !PetCatalog.isHexColor(outline) { issues.append(L10n.format("outline '%@'은 #RRGGBB가 아닙니다", outline)) }
        if let w = lineWidth, !(0...8).contains(w) { issues.append(L10n.format("lineWidth %@는 0…8 범위를 벗어났습니다", "\(w)")) }
        if let s = scale, !(0.5...1.5).contains(s) { issues.append(L10n.format("scale %@는 0.5…1.5 범위를 벗어났습니다", "\(s)")) }
        if parts["body"] == nil { issues.append(L10n.t("body(몸) 부위가 필요합니다")) }
        if parts.count > 24 { issues.append(L10n.t("부위가 너무 많습니다 (최대 24)")) }
        func inCanvas(_ v: [Double], _ what: String) {
            if v.contains(where: { !$0.isFinite || $0 < -60 || $0 > 160 }) { issues.append(L10n.format("%@ 좌표가 캔버스(0…100) 밖으로 너무 멉니다", what)) }
        }
        for (id, part) in parts {
            if sk.bone(id) == nil, !Skeleton.isAccessory(id) {
                issues.append(L10n.format("부위 '%@'는 %@ 뼈대에 없습니다 (%@, acc1…acc6)", id, sk.label, sk.bones.map(\.id).joined(separator: ", ")))
            }
            if let p = part.parent, sk.bone(p) == nil { issues.append(L10n.format("%@.parent '%@'는 없는 뼈입니다", id, p)) }
            if let pv = part.pivot {
                if pv.count != 2 { issues.append(L10n.format("%@.pivot은 [x, y]여야 합니다", id)) } else { inCanvas(pv, "\(id).pivot") }
            }
            let shapes = part.shapes ?? []
            if shapes.isEmpty, part.image == nil { issues.append(L10n.format("%@에 모양(shapes)도 그림(image)도 없습니다", id)) }
            if shapes.count > 16 { issues.append(L10n.format("%@ 모양이 너무 많습니다 (최대 16)", id)) }
            for (i, s) in shapes.enumerated() {
                if !PetCatalog.isHexColor(s.fill) { issues.append(L10n.format("%@.shapes[%lld].fill '%@'은 #RRGGBB가 아닙니다", id, i, s.fill)) }
                do {
                    let path = try SVGPath.parse(s.d)
                    let b = path.boundingBoxOfPath
                    inCanvas([Double(b.minX), Double(b.minY), Double(b.maxX), Double(b.maxY)], "\(id).shapes[\(i)]")
                } catch {
                    issues.append("\(id).shapes[\(i)].d: \(error.localizedDescription)")
                }
            }
            if let img = part.image {
                if part.imageRect?.count != 4 { issues.append(L10n.format("%@.imageRect는 [x, y, w, h]여야 합니다", id)) } else { inCanvas(part.imageRect!, "\(id).imageRect") }
                if let fileExists, !fileExists(img) { issues.append(L10n.format("%@.image '%@' 파일이 없습니다", id, img)) }
            }
        }
        if face.anchor.count != 2 { issues.append(L10n.t("face.anchor는 [x, y]여야 합니다")) } else { inCanvas(face.anchor, "face.anchor") }
        if let e = face.eyes, !RigFace.eyeStyles.contains(e) { issues.append(L10n.format("face.eyes '%@'는 없습니다 (%@)", e, RigFace.eyeStyles.joined(separator: ", "))) }
        if let m = face.mouth, !RigFace.mouthStyles.contains(m) { issues.append(L10n.format("face.mouth '%@'는 없습니다 (%@)", m, RigFace.mouthStyles.joined(separator: ", "))) }
        for (k, v) in [("eyeColor", face.eyeColor), ("blush", face.blush)] {
            if let v, !PetCatalog.isHexColor(v) { issues.append(L10n.format("face.%@ '%@'는 #RRGGBB가 아닙니다", k, v)) }
        }
        if let st = style { issues += st.validate() }
        return issues
    }

    public static func decode(_ v: JSONValue) -> RigSpec? {
        guard v["kind"]?.string == "rig", let data = v.encoded().data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RigSpec.self, from: data)
    }

    public var json: JSONValue {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(self) else { return .null }
        return JSONValue.parse(data) ?? .null
    }

    /// 쉬는 자세 그대로의 SVG (확인·공유용). 그림 부위는 자리만 점선으로.
    public func svg() -> String {
        let sk = Skeleton.named(skeleton) ?? .biped
        let lw = lineWidth ?? 3
        func z(_ id: String) -> Int { parts[id]?.z ?? sk.bone(id)?.z ?? 4 }
        var body: [String] = []
        for id in parts.keys.sorted(by: { z($0) < z($1) }) {
            guard let p = parts[id] else { continue }
            for s in p.shapes ?? [] {
                let stroke = s.line == false ? "" : " stroke=\"\(outline)\" stroke-width=\"\(lw)\" stroke-linejoin=\"round\""
                body.append("  <path d=\"\(s.d)\" fill=\"\(s.fill)\"\(stroke)/>")
            }
            if let r = p.imageRect, r.count == 4 {
                body.append("  <rect x=\"\(r[0])\" y=\"\(r[1])\" width=\"\(r[2])\" height=\"\(r[3])\" fill=\"none\" stroke=\"#999\" stroke-dasharray=\"2\"/>")
            }
        }
        let a = face.anchor
        if a.count == 2, face.eyes != "none" {
            let gap = face.eyeGap ?? 12, r = 2.2 * (face.eyeSize ?? 1)
            body.append("  <circle cx=\"\(a[0] - gap / 2)\" cy=\"\(a[1])\" r=\"\(r)\" fill=\"\(face.eyeColor ?? "#2A2724")\"/>")
            body.append("  <circle cx=\"\(a[0] + gap / 2)\" cy=\"\(a[1])\" r=\"\(r)\" fill=\"\(face.eyeColor ?? "#2A2724")\"/>")
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\" width=\"300\" height=\"300\">\n"
            + "  <line x1=\"0\" y1=\"96\" x2=\"100\" y2=\"96\" stroke=\"#ccc\" stroke-width=\"0.5\"/>\n"
            + body.joined(separator: "\n") + "\n</svg>\n"
    }
}

extension RigFace {
    public static let eyeStyles = ["dot", "round", "sparkle", "sleepy", "none"]
    public static let mouthStyles = ["smile", "cat", "tiny", "none"]
}
