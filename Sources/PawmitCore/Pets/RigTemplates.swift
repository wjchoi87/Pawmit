import Foundation

/// 뼈대마다 메이커가 처음 보여주는 기본 모양. 빈 캔버스 대신 여기서 고쳐 나가고, AI 초안의 예시로도 쓴다.
public enum RigTemplates {
    public static func template(_ skeleton: String) -> RigSpec? {
        guard let json = templates[skeleton], let v = JSONValue.parse(json), var spec = RigSpec.decode(v) else { return nil }
        spec.name = L10n.t(spec.name)  // 템플릿 이름("새 친구")을 현재 언어로
        return spec
    }

    static let templates: [String: String] = [
        "biped": """
        {"kind": "rig", "name": "새 친구", "skeleton": "biped", "outline": "#403838", "lineWidth": 3,
         "parts": {
          "legL": {"shapes": [{"d": "M39 89 C39 85 49 85 49 89 L49 92 C49 97 39 97 39 92 Z", "fill": "#FFFFFF"}]},
          "legR": {"shapes": [{"d": "M51 89 C51 85 61 85 61 89 L61 92 C61 97 51 97 51 92 Z", "fill": "#FFFFFF"}]},
          "body": {"shapes": [{"d": "M35 80 A15 13.5 0 1 1 65 80 A15 13.5 0 1 1 35 80 Z", "fill": "#FFFFFF"}]},
          "earL": {"shapes": [{"d": "M27.5 37 A6.5 6.5 0 1 1 40.5 37 A6.5 6.5 0 1 1 27.5 37 Z", "fill": "#FFFFFF"},
                              {"d": "M31 37.5 A3.2 3.2 0 1 1 37.4 37.5 A3.2 3.2 0 1 1 31 37.5 Z", "fill": "#F8C9D2", "line": false}]},
          "earR": {"shapes": [{"d": "M59.5 37 A6.5 6.5 0 1 1 72.5 37 A6.5 6.5 0 1 1 59.5 37 Z", "fill": "#FFFFFF"},
                              {"d": "M62.6 37.5 A3.2 3.2 0 1 1 69 37.5 A3.2 3.2 0 1 1 62.6 37.5 Z", "fill": "#F8C9D2", "line": false}]},
          "head": {"shapes": [{"d": "M28 52 A22 18 0 1 1 72 52 A22 18 0 1 1 28 52 Z", "fill": "#FFFFFF"}]},
          "armL": {"shapes": [{"d": "M39 70 C33 70 29 79 31 84 C33 88 38 86 40 80 Z", "fill": "#FFFFFF"}]},
          "armR": {"shapes": [{"d": "M61 70 C67 70 71 79 69 84 C67 88 62 86 60 80 Z", "fill": "#FFFFFF"}]}
         },
         "face": {"anchor": [50, 54], "eyes": "dot", "eyeGap": 14, "mouth": "smile", "blush": "#F7A5B8"}}
        """,
        "quadruped": """
        {"kind": "rig", "name": "새 친구", "skeleton": "quadruped", "outline": "#5A381C", "lineWidth": 3,
         "parts": {
          "tail": {"shapes": [{"d": "M28 72 C19 69 15 56 21 49 C23 47 27 48 25 52 C21 58 24 66 31 69 Z", "fill": "#F6B65C"}]},
          "legBF": {"shapes": [{"d": "M35.5 80 L42.5 80 L42.5 93 C42.5 97 35.5 97 35.5 93 Z", "fill": "#E0A04E"}]},
          "legFF": {"shapes": [{"d": "M57.5 80 L64.5 80 L64.5 93 C64.5 97 57.5 97 57.5 93 Z", "fill": "#E0A04E"}]},
          "body": {"shapes": [{"d": "M26 75 A20 11.5 0 1 1 66 75 A20 11.5 0 1 1 26 75 Z", "fill": "#F6B65C"},
                              {"d": "M36 82 C40 86 54 86 58 81 C54 78 40 78 36 82 Z", "fill": "#FFF1DA", "line": false}]},
          "legBN": {"shapes": [{"d": "M31.5 80 L38.5 80 L38.5 93 C38.5 97 31.5 97 31.5 93 Z", "fill": "#F6B65C"}]},
          "legFN": {"shapes": [{"d": "M53.5 80 L60.5 80 L60.5 93 C60.5 97 53.5 97 53.5 93 Z", "fill": "#F6B65C"}]},
          "earL": {"shapes": [{"d": "M57 53 L59 40 L67 49 Z", "fill": "#F6B65C"}]},
          "earR": {"shapes": [{"d": "M69 49 L77 39 L79.5 53 Z", "fill": "#F6B65C"},
                              {"d": "M72 49 L76.5 43 L77.8 51 Z", "fill": "#F6A3A3", "line": false}]},
          "head": {"shapes": [{"d": "M55 60 A13 12 0 1 1 81 60 A13 12 0 1 1 55 60 Z", "fill": "#F6B65C"},
                              {"d": "M67 64 C68 61 76 61 77 64 C77 68 67 68 67 64 Z", "fill": "#FFF1DA", "line": false}]}
         },
         "face": {"anchor": [72, 58], "eyes": "dot", "eyeGap": 10, "mouth": "cat", "blush": "#F6909E"}}
        """,
        "blob": """
        {"kind": "rig", "name": "새 친구", "skeleton": "blob", "outline": "#2F5A43", "lineWidth": 3,
         "parts": {
          "body": {"shapes": [{"d": "M24 94 C22 66 38 52 50 52 C62 52 78 66 76 94 C76 97 24 97 24 94 Z", "fill": "#B9E6C9"},
                              {"d": "M33 66 C35 60 41 57 44 58 C40 61 37 65 36 70 Z", "fill": "#E8FFF0", "line": false}]},
          "armL": {"shapes": [{"d": "M30 79 C23 79 20 86 23 88 C25 90 29 88 31 85 Z", "fill": "#B9E6C9"}]},
          "armR": {"shapes": [{"d": "M70 79 C77 79 80 86 77 88 C75 90 71 88 69 85 Z", "fill": "#B9E6C9"}]}
         },
         "face": {"anchor": [50, 74], "parent": "body", "eyes": "round", "eyeGap": 16, "mouth": "smile", "blush": "#F4A0B5"}}
        """,
        "winged": """
        {"kind": "rig", "name": "새 친구", "skeleton": "winged", "outline": "#6B4E16", "lineWidth": 3,
         "parts": {
          "wingL": {"shapes": [{"d": "M42 70 C30 58 18 62 20 74 C22 80 32 80 42 76 Z", "fill": "#FFD54F"}]},
          "wingR": {"shapes": [{"d": "M58 70 C70 58 82 62 80 74 C78 80 68 80 58 76 Z", "fill": "#FFD54F"}]},
          "legL": {"shapes": [{"d": "M40 93 C40 89 48 89 48 93 C48 96 40 96 40 93 Z", "fill": "#F2A541"}]},
          "legR": {"shapes": [{"d": "M52 93 C52 89 60 89 60 93 C60 96 52 96 52 93 Z", "fill": "#F2A541"}]},
          "body": {"shapes": [{"d": "M34 79 A16 14 0 1 1 66 79 A16 14 0 1 1 34 79 Z", "fill": "#FFE27A"}]},
          "head": {"shapes": [{"d": "M31 52 A19 17 0 1 1 69 52 A19 17 0 1 1 31 52 Z", "fill": "#FFE27A"}]},
          "acc1": {"parent": "head", "shapes": [{"d": "M46.5 57 L53.5 57 L50 61.5 Z", "fill": "#F2A541"}]},
          "acc2": {"parent": "head", "shapes": [{"d": "M48 36 C46 30 50 28 51 33 C53 29 56 31 52 36 Z", "fill": "#FFE27A"}]}
         },
         "face": {"anchor": [50, 51], "eyes": "dot", "eyeGap": 13, "mouth": "none", "blush": "#F7A07A"}}
        """,
    ]
}
