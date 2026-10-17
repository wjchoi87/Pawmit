import CoreGraphics
import Foundation
import PawmitCore

/// "말로 설명 → AI 초안": 사용자가 이미 로그인한 claude(안 되면 codex) CLI에게 뼈대 규칙과 예시를 주고
/// 메이커 펫 JSON을 받는다. 받은 것은 남이 쓴 데이터처럼 다룬다 — 고칠 수 있는 건 고치고(모르는 부위·깨진 모양 버림),
/// 검사(RigSpec.validate)를 통과해야 캔버스에 올린다.
@MainActor
enum MakerAI {
    static func prompt(description: String, skeleton: Skeleton, retryIssues: [String] = [], previous: String? = nil) -> String {
        let bones = skeleton.bones.map { "- \($0.id) (\($0.label)): pivot [\(Int($0.pivot.x)), \(Int($0.pivot.y))], z \($0.z)" }.joined(separator: "\n")
        let facing = skeleton.id == "quadruped" ? "faces RIGHT (side view)" : "faces the viewer (front view)"
        let example = RigTemplates.template(skeleton.id)?.json.encoded() ?? "{}"
        var p = """
        You design a cute desktop pet for the Pawmit pet maker. Reply with ONLY one JSON object — no prose, no code fences.

        Coordinates: SVG viewBox 0 0 100 100, y grows DOWN, ground line y=96 (feet/bottom touch it), center x=50. The pet \(facing). Total height about 50-70 units.

        Skeleton "\(skeleton.id)" bones (part id: pivot where it attaches, z draw order):
        \(bones)

        Rules:
        - "parts" keys must be the bone ids above, or acc1..acc6 for extras (hat, horn, bow, beak...) with "parent": "head" or "body".
        - Each part: {"shapes": [{"d": "<SVG path>", "fill": "#RRGGBB"}], "pivot": [x, y]}. Add "line": false only for markings (spots, belly patch, inner ear) that sit inside the part and need no outline.
        - Draw every part in its REST pose: arms hang down at the sides, legs straight down to y≈96, tail behind the body. Each part must overlap its parent a little around its pivot so joints look attached.
        - Use only absolute M L C Q A Z commands. Every shape is closed (ends with Z). Stay inside 0..100.
        - Do NOT draw eyes or a mouth: set "face" and the app draws an animated face: {"anchor": [x, y] (point between the eyes, on the head), "parent": "head" (or "body" if there is no head), "eyes": "dot"|"round"|"sparkle"|"sleepy", "eyeGap": 8-18, "mouth": "smile"|"cat"|"tiny"|"none", "blush": "#RRGGBB" (optional)}.
        - Cute chibi proportions (big head, small body, short limbs), simple rounded shapes, 2-4 harmonious colors. "outline" is a darker color of the palette, "lineWidth": 3.
        - Also give "kind": "rig", "skeleton": "\(skeleton.id)", "name" (short Korean name), "interjection" (short Korean catchphrase).

        A plain template for this skeleton, only to show the format (design your own shapes and colors):
        \(example)

        Pet description: \(description)
        """
        if !retryIssues.isEmpty, let previous {
            p += "\n\nYour previous answer had problems:\n" + retryIssues.prefix(8).map { "- \($0)" }.joined(separator: "\n")
                + "\nPrevious answer:\n\(previous.prefix(6000))\nReply with the full corrected JSON only."
        }
        return p
    }

    /// AI 답에서 JSON을 꺼내 메이커 펫으로. 고칠 수 있는 문제는 고치고 남은 문제 목록과 함께 돌려준다.
    static func parse(_ text: String, skeleton: Skeleton) -> (RigSpec?, [String]) {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              var v = JSONValue.parse(String(text[start...end]))?.object else {
            return (nil, [L10n.t("JSON을 찾지 못했어요")])
        }
        v["kind"] = "rig"
        v["skeleton"] = .string(skeleton.id)
        if v["outline"]?.string.map(PetCatalog.isHexColor) != true { v["outline"] = "#403838" }
        if v["name"]?.string == nil { v["name"] = .string(L10n.t("새 친구")) }
        // 부위: 모르는 뼈는 버리고, 깨진 모양·색은 빼거나 고친다
        var parts: [String: JSONValue] = [:]
        for (id, raw) in v["parts"]?.object ?? [:] {
            guard skeleton.bone(id) != nil || Skeleton.isAccessory(id), var part = raw.object else { continue }
            let shapes = (part["shapes"]?.array ?? []).compactMap { sv -> JSONValue? in
                guard var s = sv.object, let d = s["d"]?.string, (try? SVGPath.parse(d)) != nil else { return nil }
                if s["fill"]?.string.map(PetCatalog.isHexColor) != true { s["fill"] = "#FFFFFF" }
                return .object(s)
            }
            guard !shapes.isEmpty else { continue }
            part["shapes"] = .array(shapes)
            part.removeValue(forKey: "image")
            part.removeValue(forKey: "imageRect")
            if let pv = part["pivot"]?.array, pv.count != 2 || pv.contains(where: { $0.number == nil }) { part.removeValue(forKey: "pivot") }
            if Skeleton.isAccessory(id), let pr = part["parent"]?.string, skeleton.bone(pr) == nil { part["parent"] = "head" }
            parts[id] = .object(part)
        }
        v["parts"] = .object(parts)
        var face = v["face"]?.object ?? [:]
        if face["anchor"]?.array?.count != 2 {
            var headBox: CGRect?
            if let d = parts["head"]?["shapes"]?[0]?["d"]?.string, let hp = try? SVGPath.parse(d) { headBox = hp.boundingBoxOfPath }
            let c = headBox.map { CGPoint(x: $0.midX, y: $0.midY + 2) } ?? CGPoint(x: 50, y: 60)
            face["anchor"] = [.number(Double(c.x)), .number(Double(c.y))]
        }
        if let e = face["eyes"]?.string, !RigFace.eyeStyles.contains(e) { face["eyes"] = "dot" }
        if let m = face["mouth"]?.string, !RigFace.mouthStyles.contains(m) { face["mouth"] = "smile" }
        if face["blush"]?.string.map(PetCatalog.isHexColor) == false { face.removeValue(forKey: "blush") }
        if face["eyeColor"]?.string.map(PetCatalog.isHexColor) == false { face.removeValue(forKey: "eyeColor") }
        if let p = face["parent"]?.string, skeleton.bone(p) == nil || parts[p] == nil { face["parent"] = parts["head"] != nil ? "head" : "body" }
        v["face"] = .object(face)
        v.removeValue(forKey: "style")
        guard let spec = RigSpec.decode(.object(v)) else { return (nil, [L10n.t("형식이 맞지 않아요")]) }
        return (spec, spec.validate())
    }

    /// 대화 CLI로 초안 받기 (문제가 있으면 한 번 고쳐 달라고 다시 묻는다)
    static func generate(description: String, skeleton: Skeleton, config: PawmitConfig,
                         completion: @escaping (RigSpec?, String?) -> Void) {
        let chat = ChatService(config: config, sessionID: nil)
        let persona = "You are a JSON generator. Output only valid JSON."
        func attempt(_ prompt: String, retry: Bool) {
            chat.ask(prompt, persona: persona, onDelta: { _ in }, onDone: { text, err in
                guard let text else { completion(nil, err ?? L10n.t("AI가 대답하지 않았어요")); return }
                let (spec, issues) = parse(text, skeleton: skeleton)
                if let spec, issues.isEmpty { completion(spec, nil); return }
                if retry {
                    attempt(Self.prompt(description: description, skeleton: skeleton, retryIssues: issues, previous: text), retry: false)
                } else if let spec, spec.parts["body"] != nil {
                    // 사소한 문제만 남았으면 그대로 올리고 알려준다
                    completion(spec, L10n.t("초안에 고칠 곳이 있어요: ") + issues.prefix(2).joined(separator: " / "))
                } else {
                    completion(nil, L10n.t("초안을 만들지 못했어요: ") + issues.prefix(2).joined(separator: " / "))
                }
            })
        }
        attempt(prompt(description: description, skeleton: skeleton), retry: true)
    }
}
