import Foundation

/// 펫 정의(pet.json)의 공통 규격.
///
/// 기본 펫과 커스텀 펫은 같은 형식의 JSON 하나로 정의된다. 앱은 이 JSON을 읽어 부위(귀·꼬리·무늬)를
/// 조립해 그리고, CLI(`pawmit pet …`)와 내보내기 파일(.pawmitpet)도 같은 형식을 쓴다. 자세한 필드는 docs/PET_FORMAT.md.
///
///     { "kind": "chibi", "name": "몽글이", "ears": "round", "tail": "none", "pattern": "none",
///       "body": "#FFFFFF", "outline": "#403838", ... }
///     { "kind": "chibi", "base": "mongle", "body": "#FFE4EC" }   // 기본 펫을 바탕으로 일부만 바꾸기
///     { "kind": "cat", "coat": "gray", "name": "회색냥" }
public enum PetCatalog {
    public static let formatVersion = 1

    /// 코드로 그리는 펫 종류
    public static let kinds = ["chibi", "cat", "rig"]

    /// 치비 부위 id. 앱의 부위 레지스트리(ChibiParts)와 같아야 한다 — 새 부위를 추가하면 여기에도 추가.
    public static let chibiEars = ["round", "cat", "bunny", "squirrel", "tiny", "none"]
    public static let chibiTails = ["none", "cat", "puff", "fluffy", "otter"]
    public static let chibiPatterns = ["none", "hachiware", "chestnut", "muzzle"]
    public static let catCoats = ["cheese", "gray", "black", "white", "tuxedo"]

    /// 색 필드 (모두 "#RRGGBB")
    public static let chibiColorKeys = ["body", "accent", "innerEar", "belly", "outline", "blush"]
    public static let catColorKeys = ["body", "stripe", "belly", "outline", "earInner", "nose", "eye", "pupil", "cheek"]

    /// 기본 펫. 특정 작품 캐릭터를 복제하지 않은 오리지널 디자인이다.
    public static let builtinJSON = """
    [
      {"id": "mongle", "kind": "chibi", "name": "몽글이", "interjection": "몽!", "description": "하얀 찹쌀떡 곰",
       "ears": "round", "tail": "none", "pattern": "none",
       "body": "#FFFFFF", "accent": "#FFFFFF", "innerEar": "#F8C9D2", "outline": "#403838", "blush": "#F7A5B8", "blushAlpha": 0.85},
      {"id": "banban", "kind": "chibi", "name": "반반이", "interjection": "냥~", "description": "이마가 반반 나뉜 하치와레 무늬 고양이",
       "ears": "cat", "tail": "cat", "pattern": "hachiware",
       "body": "#FFFFFF", "accent": "#8FA9CC", "innerEar": "#F6C2CC", "outline": "#3D3F48", "blush": "#F5A3B5", "blushAlpha": 0.85},
      {"id": "tokki", "kind": "chibi", "name": "토깽이", "interjection": "깡총!", "description": "노란 크림 토끼",
       "ears": "bunny", "tail": "puff", "pattern": "none",
       "body": "#FCE8A4", "accent": "#FCE8A4", "innerEar": "#F5BBA6", "belly": "#FFF6D8", "outline": "#55462E",
       "blush": "#F59C9C", "blushAlpha": 0.8, "headRX": 17, "headRY": 14},
      {"id": "nalda", "kind": "chibi", "name": "날다람", "interjection": "슝~", "description": "꼬리가 풍성한 하늘다람쥐",
       "ears": "squirrel", "tail": "fluffy", "pattern": "none",
       "body": "#FFFFFF", "accent": "#C9CFE3", "innerEar": "#E9C9D6", "outline": "#3E3C46", "blush": "#F4A8BC", "blushAlpha": 0.85},
      {"id": "bamtol", "kind": "chibi", "name": "밤톨이", "interjection": "톨톨", "description": "밤 모양 머리",
       "ears": "none", "tail": "none", "pattern": "chestnut",
       "body": "#F5DEB9", "accent": "#A9683A", "innerEar": "#F5DEB9", "outline": "#4A2E1B",
       "blush": "#F19A8C", "blushAlpha": 0.75, "headRX": 17.5, "headRY": 14.5},
      {"id": "haedal", "kind": "chibi", "name": "해달이", "interjection": "달달~", "description": "둥실둥실 해달",
       "ears": "tiny", "tail": "otter", "pattern": "muzzle",
       "body": "#C9A07A", "accent": "#F3E4CF", "innerEar": "#9C7655", "belly": "#E8D2B6", "outline": "#45301F",
       "blush": "#EE9A92", "blushAlpha": 0.7},
      {"id": "cat", "kind": "cat", "name": "치즈냥", "interjection": "냐옹", "description": "사족 보행 고양이", "coat": "cheese", "scale": 0.86}
    ]
    """

    public static let builtins: [JSONValue] = JSONValue.parse(builtinJSON)?.array ?? []

    /// 기본 펫의 영어 이름·말버릇·설명. pet.json 원본(한국어)은 그대로 두고 화면에 보일 때만 바꾼다.
    private static let englishText: [String: [String: String]] = [
        "mongle": ["name": "Mongle", "interjection": "Mong!", "description": "a white mochi bear"],
        "banban": ["name": "Banban", "interjection": "Meow~", "description": "a hachiware cat with a split-color forehead"],
        "tokki": ["name": "Tokki", "interjection": "Hop!", "description": "a cream-yellow bunny"],
        "nalda": ["name": "Nalda", "interjection": "Whoosh~", "description": "a flying squirrel with a fluffy tail"],
        "bamtol": ["name": "Bamtol", "interjection": "Tok-tok", "description": "a chestnut-headed buddy"],
        "haedal": ["name": "Haedal", "interjection": "Bobble~", "description": "a bobbing sea otter"],
        "cat": ["name": "Cheese", "interjection": "Meow", "description": "a four-legged cat"],
    ]

    /// 기본 펫(id가 있는 정의)이면 현재 언어로, 그 밖(커스텀 펫)은 pet.json 값 그대로
    public static func localized(_ v: JSONValue, _ field: String) -> String? {
        if !L10n.isKorean, let id = v["id"]?.string, let text = englishText[id]?[field] { return text }
        return v[field]?.string
    }

    public static func builtin(_ id: String) -> JSONValue? {
        builtins.first { $0["id"]?.string == id }
    }

    /// `base`를 풀어서 기본 펫 정의 위에 덮어쓴 완전한 정의를 돌려준다 (base 체인은 한 단계만).
    public static func resolve(_ v: JSONValue) -> JSONValue {
        guard var own = v.object, let baseID = own["base"]?.string, let base = builtin(baseID)?.object else { return v }
        own.removeValue(forKey: "base")
        var merged = base
        merged.removeValue(forKey: "id")
        for (k, value) in own { merged[k] = value }
        return .object(merged)
    }

    /// 문제 목록 (비어 있으면 통과). 모르는 부위 id·잘못된 색·범위를 벗어난 숫자를 잡는다.
    public static func validate(_ raw: JSONValue) -> [String] {
        guard raw.object != nil else { return [L10n.t("pet.json이 JSON 객체가 아닙니다")] }
        var issues: [String] = []
        if let b = raw["base"]?.string, builtin(b) == nil { issues.append(L10n.format("base '%@'는 기본 펫 id가 아닙니다 (%@)", b, builtins.compactMap { $0["id"]?.string }.joined(separator: ", "))) }
        let v = resolve(raw)
        guard let kind = v["kind"]?.string else { return issues } // kind가 없으면 이미지 폴더 펫
        func checkPart(_ key: String, _ allowed: [String]) {
            if let s = v[key]?.string, !allowed.contains(s) { issues.append(L10n.format("%@ '%@'는 없는 부위입니다 (%@)", key, s, allowed.joined(separator: ", "))) }
        }
        func checkColors(_ keys: [String]) {
            for k in keys { if let s = v[k]?.string, !isHexColor(s) { issues.append(L10n.format("%@ '%@'는 #RRGGBB 형식이 아닙니다", k, s)) } }
        }
        func checkRange(_ key: String, _ lo: Double, _ hi: Double) {
            if let n = v[key]?.number, !(lo...hi).contains(n) { issues.append(L10n.format("%@ %@는 %@…%@ 범위를 벗어났습니다", key, "\(n)", "\(lo)", "\(hi)")) }
        }
        switch kind {
        case "chibi":
            checkPart("ears", chibiEars)
            checkPart("tail", chibiTails)
            checkPart("pattern", chibiPatterns)
            checkColors(chibiColorKeys)
            checkRange("headRX", 14, 21)
            checkRange("headRY", 11, 17)
            checkRange("blushAlpha", 0, 1)
        case "cat":
            checkPart("coat", catCoats)
            checkColors(catColorKeys)
        case "rig":
            // 메이커 펫: 부위·모양·관절·얼굴 검사는 RigSpec이
            if let spec = RigSpec.decode(v) {
                issues += spec.validate()
            } else {
                issues.append(L10n.t("메이커 펫(rig) 형식을 읽을 수 없습니다 (필수: name, skeleton, outline, parts, face)"))
            }
        default:
            issues.append(L10n.format("kind '%@'는 지원하지 않습니다 (%@, 이미지 펫은 kind 없이)", kind, kinds.joined(separator: ", ")))
        }
        checkRange("scale", 0.5, 1.5)
        if kind != "rig", let st = v["style"] {
            if let data = st.encoded().data(using: .utf8), let style = try? JSONDecoder().decode(PetStyle.self, from: data) {
                issues += style.validate()
            } else {
                issues.append(L10n.t("style 형식을 읽을 수 없습니다"))
            }
        }
        return issues
    }

    public static func isHexColor(_ s: String) -> Bool {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        return h.count == 6 && UInt32(h, radix: 16) != nil
    }
}
