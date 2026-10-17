import Foundation
import PawmitCore

/// 펫의 욕구. 0...100. 배고픔은 높을수록 배고픔, 나머지는 높을수록 좋음.
/// 감소 속도는 OpenPets virtual-pet(MIT)의 시간당 감소 값을 데스크탑 체류 시간에 맞게 키운 것.
struct Needs: Codable, Equatable {
    var hunger: Double = 20
    var energy: Double = 85
    var fun: Double = 70
    var affection: Double = 60

    mutating func clamp() {
        hunger = min(100, max(0, hunger))
        energy = min(100, max(0, energy))
        fun = min(100, max(0, fun))
        affection = min(100, max(0, affection))
    }

    /// 분 단위 시간 경과
    mutating func decay(minutes: Double, sleeping: Bool, home: Bool) {
        hunger += minutes * 1.4
        if sleeping || home {
            energy += minutes * (home ? 9 : 6)
            fun -= minutes * 0.3
        } else {
            energy -= minutes * 0.9
            fun -= minutes * 1.1
        }
        affection -= minutes * 0.4
        clamp()
    }

    var mood: String {
        if hunger > 75 { return L10n.t("배고파요") }
        if energy < 20 { return L10n.t("졸려요") }
        if fun < 25 { return L10n.t("심심해요") }
        if (100 - hunger + energy + fun + affection) / 4 > 72 { return L10n.t("기분 최고") }
        return L10n.t("평온해요")
    }
}

/// 재시작해도 이어지는 상태 (`~/.pawmit/state.json`)
struct PetState: Codable {
    var needs = Needs()
    var x: Double?
    var y: Double?
    var isHome = false
    var chatSessionID: String?
    /// 말풍선 대화 기록 (재시작 후 복원용, 최근 60줄)
    var chatLog: [ChatLogLine]?
    /// 펫 종류별 행동 seed (성격이 여기서 나온다)
    var seeds: [String: UInt64] = [:]
    /// 마지막 자동 업데이트 확인 시각 (주 1회)
    var lastUpdateCheck: Date?
    var lastSaved: Date = Date()

    static func load() -> PetState {
        guard let data = try? Data(contentsOf: PawmitPaths.state),
              let s = try? JSONDecoder.pawmit.decode(PetState.self, from: data) else { return PetState() }
        return s
    }

    func save() {
        var copy = self
        copy.lastSaved = Date()
        if let data = try? JSONEncoder.pawmit.encode(copy) {
            try? data.write(to: PawmitPaths.state, options: .atomic)
        }
    }
}

/// 말풍선 한 줄 (표시용 ChatModel.Line에서 휘발성 id만 뺀 저장 형태)
struct ChatLogLine: Codable, Equatable {
    var fromPet: Bool
    var text: String
}

extension JSONEncoder {
    static var pawmit: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var pawmit: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
