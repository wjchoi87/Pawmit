import Foundation

/// 시간에 따라 흔들리는 값: base + amp·sin(2π·freq·t + phase)
public struct Wave: Codable, Equatable, Sendable {
    public var base: Double
    public var amp: Double
    public var freq: Double
    public var phase: Double

    public init(_ base: Double, amp: Double = 0, freq: Double = 0, phase: Double = 0) {
        self.base = base
        self.amp = amp
        self.freq = freq
        self.phase = phase
    }

    public func value(at t: Double) -> Double { base + amp * sin(2 * .pi * freq * t + phase) }
}

public enum EyeExpr: String, CaseIterable, Codable, Sendable {
    case open, closed, happy, wide, squeeze, teary, half, heart, star, spiral, dot, wink
}

public enum MouthExpr: String, CaseIterable, Codable, Sendable {
    case smile, open, chomp, o, wobbly, flat, tongue, grin, cat, kiss
}

/// 기본 포즈 위에 얹는 절차적 모션 층. 팔·몸·고개를 파형으로 움직이고 표정을 바꾼다.
/// 동작(Act) 레시피가 seed로 이 값들을 골라서 같은 동작도 매번 조금씩 다르게 움직인다.
public struct MotionSpec: Codable, Equatable, Sendable {
    /// 기본 포즈 (PetAnim rawValue: idle, sit, walk …)
    public var base: String
    /// 팔 각도(라디안): 0 아래, π/2 옆, π 위, π보다 크면 안쪽 위
    public var leftArm: Wave?
    public var rightArm: Wave?
    /// 몸 기울기 (라디안, +는 뒤로)
    public var lean: Wave?
    public var headTilt: Wave?
    /// 몸 전체 위아래 (렌더러 단위)
    public var bounce: Wave?
    /// 납작/길쭉 (1 = 보통)
    public var squash: Wave?
    /// 좌우 흔들기 (렌더러 단위)
    public var sway: Wave?
    public var eyes: EyeExpr?
    public var mouth: MouthExpr?
    public var earPerk: Double?
    /// 이 간격(초)마다 좌우로 돌아본다 (빙글빙글·도리도리)
    public var flipEvery: Double?

    public init(base: String, leftArm: Wave? = nil, rightArm: Wave? = nil, lean: Wave? = nil, headTilt: Wave? = nil,
                bounce: Wave? = nil, squash: Wave? = nil, sway: Wave? = nil, eyes: EyeExpr? = nil, mouth: MouthExpr? = nil,
                earPerk: Double? = nil, flipEvery: Double? = nil) {
        self.base = base
        self.leftArm = leftArm
        self.rightArm = rightArm
        self.lean = lean
        self.headTilt = headTilt
        self.bounce = bounce
        self.squash = squash
        self.sway = sway
        self.eyes = eyes
        self.mouth = mouth
        self.earPerk = earPerk
        self.flipEvery = flipEvery
    }
}

/// 이동 경로 모양
public enum MovePattern: String, CaseIterable, Codable, Sendable {
    case wander, line, zigzag, circle, figure8, spiral, square, triangle, wave, backAndForth
    case toCorner, toEdge, toCenter, toCursor, awayFromCursor, orbitCursor, patrolBottom, peekEdge
    case randomHops, pace, heartPath, starPath
}

/// 걸음걸이
public enum Gait: String, CaseIterable, Codable, Sendable {
    case walk, run, tiptoe, hop, skip, sneak, wobble, strut, scurry

    /// 기본 걷기 대비 속도
    public var speed: Double {
        switch self {
        case .walk: return 1
        case .run: return 2.6
        case .tiptoe: return 0.45
        case .hop: return 1.15
        case .skip: return 1.7
        case .sneak: return 0.6
        case .wobble: return 0.8
        case .strut: return 1.0
        case .scurry: return 3.1
        }
    }

    public var usesRunPose: Bool { self == .run || self == .skip || self == .scurry }
    /// 이동 중 깡충 뛰는 간격(초)과 높이
    public var hop: (every: Double, height: Double)? {
        switch self {
        case .hop: return (0.42, 8)
        case .skip: return (0.3, 5)
        default: return nil
        }
    }

    /// 걸음걸이에 따라 이동 중에 얹을 모션
    public var motion: MotionSpec? {
        switch self {
        case .tiptoe:
            return MotionSpec(base: "walk", leftArm: Wave(2.3, amp: 0.1, freq: 1.5), rightArm: Wave(2.3, amp: 0.1, freq: 1.5, phase: .pi),
                              squash: Wave(1.05), eyes: .half, mouth: .flat)
        case .sneak:
            return MotionSpec(base: "walk", leftArm: Wave(1.2), rightArm: Wave(1.2), lean: Wave(-0.12), squash: Wave(0.88), eyes: .half)
        case .wobble:
            return MotionSpec(base: "walk", lean: Wave(0, amp: 0.13, freq: 1.6), headTilt: Wave(0, amp: 0.12, freq: 1.1), eyes: .spiral, mouth: .wobbly)
        case .strut:
            return MotionSpec(base: "walk", leftArm: Wave(0.5, amp: 0.6, freq: 1.8), rightArm: Wave(0.5, amp: 0.6, freq: 1.8, phase: .pi),
                              lean: Wave(0.06), eyes: .half, mouth: .grin)
        case .scurry:
            return MotionSpec(base: "run", leftArm: Wave(2.6, amp: 0.3, freq: 6), rightArm: Wave(2.6, amp: 0.3, freq: 6, phase: .pi), eyes: .squeeze, mouth: .open)
        default:
            return nil
        }
    }
}

/// 머리 위로 띄우는 감정 표현
public enum Emote: String, CaseIterable, Codable, Sendable {
    case hearts, notes, sparkles, zzz, sweat, question, exclaim, flowers, stars, steam, bubbles, leaves, thought, angry, shine, food, confetti, music

    public var glyphs: [String] {
        switch self {
        case .hearts: return ["♥", "💕", "💗"]
        case .notes: return ["♪", "♫"]
        case .sparkles: return ["✦", "✧", "✨"]
        case .zzz: return ["z", "Z"]
        case .sweat: return ["💦"]
        case .question: return ["?", "❓"]
        case .exclaim: return ["!", "❗"]
        case .flowers: return ["🌸", "🌼", "🌷"]
        case .stars: return ["⭐", "🌟"]
        case .steam: return ["💨"]
        case .bubbles: return ["🫧", "°"]
        case .leaves: return ["🍃", "🍂"]
        case .thought: return ["💭"]
        case .angry: return ["💢"]
        case .shine: return ["✨", "💫"]
        case .food: return ["🍙", "🍡", "🐟"]
        case .confetti: return ["🎉", "🎊"]
        case .music: return ["🎵", "🎶"]
        }
    }
}

/// 시간이 걸리는 대형 활동 (소품·다른 펫이 필요한 것)
public enum Macro: String, CaseIterable, Codable, Sendable {
    case eat, ball, chaseCursor, trash, doodle, nap, home, clean
}

/// 친구 펫과 같이 하는 놀이
public enum FriendGame: String, CaseIterable, Codable, Sendable {
    case greet, tag, danceTogether, ballPass, napTogether, highFive, shareSnack, followLeader, chatter
}

public enum Mood: String, CaseIterable, Codable, Sendable {
    case calm, cheerful, curious, proud, sleepy, hungry, affectionate, grumpy, coding, playful
}
