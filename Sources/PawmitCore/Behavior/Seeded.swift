import Foundation

/// 재현 가능한 난수 (SplitMix64). 같은 seed면 같은 행동이 나온다.
/// hookling(MIT)의 `SeededRandom`과 같은 공개 알고리즘(Steele et al.)을 쓴다.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 두 값을 섞어 새 seed (펫 seed + 행동 번호 → 행동 seed)
    public static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var r = SplitMix64(seed: a ^ (b &* 0xD6E8_FEB8_6659_FD93))
        return r.next()
    }
}

extension RandomNumberGenerator {
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    public mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }

    /// 가중치 룰렛 (eSheep `getNextAnimation`과 같은 방식)
    public mutating func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return items[0].0 }
        var roll = unit() * total
        for (item, w) in items {
            roll -= max(0, w)
            if roll < 0 { return item }
        }
        return items[items.count - 1].0
    }
}

/// 펫 성격. seed와 종족으로 정해지고, 행동 가중치에 곱해진다. 모든 값 0...1.
public struct Personality: Codable, Equatable, Sendable {
    public var energy: Double
    public var curiosity: Double
    public var sociability: Double
    public var artistry: Double
    public var mischief: Double
    public var appetite: Double
    public var laziness: Double
    public var tidiness: Double

    public static func make(seed: UInt64, species: String) -> Personality {
        var r = SplitMix64(seed: SplitMix64.mix(seed, 0x5045_5253))
        var p = Personality(energy: r.unit(), curiosity: r.unit(), sociability: r.unit(), artistry: r.unit(),
                            mischief: r.unit(), appetite: r.unit(), laziness: r.unit(), tidiness: r.unit())
        // 종족 기질
        func bias(_ k: WritableKeyPath<Personality, Double>, _ d: Double) { p[keyPath: k] = min(1, max(0, p[keyPath: k] * 0.7 + d)) }
        switch species {
        case "mongle": bias(\.sociability, 0.3); bias(\.appetite, 0.25)
        case "banban": bias(\.curiosity, 0.3); bias(\.mischief, 0.25)
        case "tokki": bias(\.energy, 0.35); bias(\.mischief, 0.15)
        case "nalda": bias(\.energy, 0.3); bias(\.curiosity, 0.2)
        case "bamtol": bias(\.laziness, 0.3); bias(\.appetite, 0.3)
        case "haedal": bias(\.laziness, 0.2); bias(\.tidiness, 0.3); bias(\.sociability, 0.15)
        case "cat": bias(\.curiosity, 0.25); bias(\.laziness, 0.2)
        default: break
        }
        return p
    }

    /// 가장 두드러진 성격 두 가지 (메뉴 표시용)
    public var summary: String {
        let names: [(String, Double)] = L10n.isKorean
            ? [("활발한", energy), ("호기심 많은", curiosity), ("다정한", sociability), ("예술가", artistry),
               ("장난꾸러기", mischief), ("먹보", appetite), ("느긋한", laziness), ("깔끔쟁이", tidiness)]
            : [("lively", energy), ("curious", curiosity), ("sweet", sociability), ("artistic", artistry),
               ("mischievous", mischief), ("gluttonous", appetite), ("laid-back", laziness), ("tidy", tidiness)]
        return names.sorted { $0.1 > $1.1 }.prefix(2).map(\.0).joined(separator: " · ")
    }
}
