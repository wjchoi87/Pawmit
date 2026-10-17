import Foundation

/// 제자리에서 하는 동작. 레시피가 seed로 팔 동작·박자·표정·감정을 골라 같은 동작도 매번 다르게 만든다.
public enum Act: String, CaseIterable, Codable, Sendable {
    case sit, groom, think, wave, dance, stretch, yawn, lookAround, spin, nod, bow, shakeHead, sneeze, hiccup
    case stargaze, cheer, sulk, pounceAir, bounce, wiggle, clap, daydream, sing, salute, shiver, flex, sniff
    case tailChase, napShort, giggle, pout, fistPump, love, dizzy
}

public struct ActSpec: Equatable, Sendable {
    public var act: Act
    public var motion: MotionSpec
    public var seconds: Double
    public var emote: Emote?
    /// 감정 표현을 몇 초마다 띄울지 (0이면 시작할 때 한 번)
    public var emoteEvery: Double = 0
    public var jumpEvery: Double?
    public var jumpHeight: Double = 8
    public var say: String?

    public init(act: Act, motion: MotionSpec, seconds: Double, emote: Emote? = nil, emoteEvery: Double = 0,
                jumpEvery: Double? = nil, jumpHeight: Double = 8, say: String? = nil) {
        self.act = act
        self.motion = motion
        self.seconds = seconds
        self.emote = emote
        self.emoteEvery = emoteEvery
        self.jumpEvery = jumpEvery
        self.jumpHeight = jumpHeight
        self.say = say
    }
}

public enum ActRecipes {
    // 팔 각도 상수
    static let down = 0.22, side = 1.45, up = 2.7, face = 3.62, chest = 3.95, chin = 3.3

    /// 레시피별 이산 선택지 조합 수 (연속값 변화는 제외한 하한)
    public static func variants(_ act: Act) -> Int {
        switch act {
        case .sit: return 18
        case .groom: return 36
        case .think: return 36
        case .wave: return 81
        case .dance: return 6912
        case .stretch: return 16
        case .yawn: return 8
        case .lookAround: return 36
        case .spin: return 81
        case .nod: return 16
        case .bow: return 8
        case .shakeHead: return 24
        case .sneeze: return 4
        case .hiccup: return 4
        case .stargaze: return 12
        case .cheer: return 108
        case .sulk: return 24
        case .pounceAir: return 8
        case .bounce: return 81
        case .wiggle: return 48
        case .clap: return 36
        case .daydream: return 12
        case .sing: return 48
        case .salute: return 4
        case .shiver: return 4
        case .flex: return 8
        case .sniff: return 6
        case .tailChase: return 4
        case .napShort: return 1
        case .giggle: return 9
        case .pout: return 18
        case .fistPump: return 8
        case .love: return 6
        case .dizzy: return 2
        }
    }

    public static var totalVariants: Int { Act.allCases.reduce(0) { $0 + variants($1) } }

    public static func make(_ act: Act, rng r: inout SplitMix64) -> ActSpec {
        func w(_ base: Double, _ amp: Double = 0, _ freq: Double = 0, _ phase: Double = 0) -> Wave {
            Wave(base, amp: amp, freq: freq, phase: phase)
        }
        func spec(_ m: MotionSpec, _ secs: ClosedRange<Double>, emote: Emote? = nil, every: Double = 0) -> ActSpec {
            ActSpec(act: act, motion: m, seconds: r.range(secs.lowerBound, secs.upperBound), emote: emote, emoteEvery: every)
        }

        switch act {
        case .sit:
            let m = MotionSpec(base: "sit", headTilt: w(0, r.pick([0, 0.08]), 0.3), eyes: r.pick([.open, .half, .happy]))
            return spec(m, 3...7, emote: r.pick([nil, .thought, .leaves]), every: 2.5)

        case .groom:
            let f = r.pick([1.5, 2.5, 3.5])
            let m = MotionSpec(base: "sit", leftArm: w(face, 0.22, f), rightArm: w(face, 0.22, f, .pi), headTilt: w(0, r.pick([0.06, 0.12]), f / 2),
                               eyes: r.pick([.closed, .happy]), mouth: .smile)
            return spec(m, 2.5...4.5, emote: r.pick([nil, .sparkles, .bubbles]), every: 1.2)

        case .think:
            let right = r.chance(0.5)
            let m = MotionSpec(base: "sit", leftArm: right ? w(down) : w(chin), rightArm: right ? w(chin) : w(down),
                               headTilt: w(r.pick([0.1, -0.1, 0.15]), 0.03, 0.4), eyes: r.pick([.open, .half, .dot]), mouth: .flat)
            return spec(m, 2.5...5, emote: r.pick([.thought, .question]), every: 1.6)

        case .wave:
            let style = r.int(0, 2), f = r.pick([1.5, 2.5, 3.5])
            let waving = w(2.75, 0.4, f)
            let m = MotionSpec(base: "idle", leftArm: style >= 1 ? waving : w(down), rightArm: style != 1 ? waving : w(down),
                               eyes: r.pick([.happy, .open, .wink]), mouth: r.pick([.open, .grin, .smile]))
            return spec(m, 1.4...2.6, emote: .hearts)

        case .dance:
            let base = r.pick(["idle", "sit"])
            let tempo = r.pick([1.5, 2.0, 2.5, 3.0])
            let style = r.int(0, 5)
            var la = w(up, 0.25, tempo), ra = w(up, 0.25, tempo, .pi)
            switch style {
            case 0: la = w(up, 0.3, tempo); ra = w(up, 0.3, tempo)               // 만세
            case 1: la = w(1.6, 1.1, tempo); ra = w(1.6, 1.1, tempo, .pi)        // 번갈아
            case 2: la = w(down); ra = w(2.75, 0.45, tempo * 1.5)                // 한 손 흔들기
            case 3: la = w(chest, 0.35, tempo * 2); ra = w(chest, 0.35, tempo * 2) // 박수
            case 4: la = w(side, 0.5, tempo / 2); ra = w(side, 0.5, tempo / 2, .pi) // 물결
            default: la = w(side, 0.9, tempo * 2, .pi / 2); ra = w(side, 0.9, tempo * 2, -.pi / 2) // 로봇
            }
            let m = MotionSpec(base: base, leftArm: la, rightArm: ra, lean: w(0, r.range(0.04, 0.15), tempo / 2),
                               bounce: w(0, r.range(1, 3.5), tempo), squash: w(1, 0.04, tempo),
                               eyes: r.pick([.happy, .closed, .star, .wink]), mouth: r.pick([.open, .grin, .smile]),
                               flipEvery: r.pick([nil, 0.6, 1.0]))
            return spec(m, 2.5...5.5, emote: r.pick([.notes, .music, .confetti, .stars]), every: 0.7)

        case .stretch:
            let m = MotionSpec(base: "idle", leftArm: w(up + 0.15), rightArm: w(up + 0.15), lean: w(r.pick([-0.1, 0.1])),
                               squash: w(1.08, 0.06, r.pick([0.5, 0.8])), eyes: r.pick([.closed, .squeeze]), mouth: .o)
            return spec(m, 1.6...2.8, emote: r.pick([nil, .sparkles]))

        case .yawn:
            let both = r.chance(0.5)
            let m = MotionSpec(base: "sit", leftArm: both ? w(up) : w(down), rightArm: w(up), squash: w(1.04, 0.03, 0.6),
                               eyes: r.pick([.closed, .half]), mouth: .o)
            var s = spec(m, 1.6...2.6, emote: r.pick([.zzz, .bubbles]), every: 0.8)
            s.say = L10n.t("하암~")
            return s

        case .lookAround:
            let m = MotionSpec(base: "idle", headTilt: w(0, r.pick([0.08, 0.15]), 0.7), eyes: r.pick([.open, .wide]),
                               flipEvery: r.pick([0.7, 1.1, 1.5]))
            return spec(m, 2.2...4, emote: r.pick([nil, .question, .exclaim]), every: 1.5)

        case .spin:
            let arms = r.pick([up, side, down])
            let m = MotionSpec(base: "idle", leftArm: w(arms), rightArm: w(arms), eyes: r.pick([.spiral, .happy, .squeeze]),
                               mouth: .open, flipEvery: r.pick([0.12, 0.18, 0.25]))
            return spec(m, 1.2...2.2, emote: r.pick([nil, .sparkles, .stars]), every: 0.5)

        case .nod:
            let m = MotionSpec(base: "idle", headTilt: w(0, 0.05, 2), bounce: w(0, r.pick([1, 1.8]), r.pick([2, 3])),
                               eyes: r.pick([.happy, .closed]), mouth: r.pick([.smile, .grin]))
            return spec(m, 1.2...2.2)

        case .bow:
            let m = MotionSpec(base: "idle", leftArm: w(r.pick([side, chest])), rightArm: w(r.pick([side, chest])),
                               lean: w(-0.25, 0.15, r.pick([0.5, 0.8])), eyes: .closed, mouth: .smile)
            return spec(m, 1.4...2.2, emote: r.pick([nil, .sparkles]))

        case .shakeHead:
            let m = MotionSpec(base: "idle", headTilt: w(0, r.pick([0.15, 0.25]), r.pick([2, 3])),
                               eyes: r.pick([.squeeze, .closed, .half]), mouth: r.pick([.flat, .wobbly]))
            return spec(m, 1...1.8)

        case .sneeze:
            let big = r.chance(0.5)
            let m = MotionSpec(base: "idle", leftArm: w(r.chance(0.5) ? face : side), rightArm: w(face),
                               lean: w(0, big ? 0.18 : 0.08, 1.4), squash: w(1, big ? 0.12 : 0.06, 1.4), eyes: .squeeze, mouth: .o)
            var s = spec(m, 1.2...1.8, emote: .steam)
            s.say = L10n.isKorean ? (big ? "에에취!!" : "에취!") : (big ? "Ah-choo!!" : "Achoo!")
            return s

        case .hiccup:
            let m = MotionSpec(base: "sit", eyes: r.pick([.wide, .open]), mouth: .o)
            var s = spec(m, 2.5...4)
            s.jumpEvery = r.pick([0.8, 1.2])
            s.jumpHeight = 4
            s.say = L10n.t("딸꾹!")
            return s

        case .stargaze:
            let m = MotionSpec(base: "sit", leftArm: w(down), rightArm: w(r.pick([down, chin])), headTilt: w(0.2, 0.04, 0.3),
                               eyes: r.pick([.open, .star, .wide]), mouth: .smile)
            return spec(m, 3...6, emote: r.pick([.stars, .sparkles]), every: 1.2)

        case .cheer:
            let f = r.pick([2.0, 3.0, 4.0])
            let m = MotionSpec(base: "idle", leftArm: w(up, 0.3, f), rightArm: w(up, 0.3, f), bounce: w(0, 1.5, f),
                               eyes: r.pick([.happy, .star, .squeeze]), mouth: r.pick([.open, .grin]), earPerk: 0.3)
            var s = spec(m, 1.6...2.8, emote: r.pick([.confetti, .stars, .sparkles]), every: 0.5)
            s.jumpEvery = r.pick([0.5, 0.7])
            s.jumpHeight = 10
            return s

        case .sulk:
            let m = MotionSpec(base: "sit", leftArm: w(chest), rightArm: w(chest), headTilt: w(r.pick([-0.15, 0.15])),
                               eyes: r.pick([.half, .teary]), mouth: r.pick([.flat, .wobbly]))
            var s = spec(m, 2.5...4.5, emote: r.pick([.angry, .steam, .thought]), every: 1.4)
            s.say = r.pick(L10n.isKorean ? ["흥", "칫", "삐졌어"] : ["Hmph", "Tch", "I'm sulking"])
            return s

        case .pounceAir:
            let m = MotionSpec(base: "pounce", eyes: r.pick([.wide, .squeeze]), mouth: .open)
            var s = spec(m, 1.4...2.4)
            s.jumpEvery = r.pick([0.7, 1.0])
            s.jumpHeight = r.pick([10, 16])
            return s

        case .bounce:
            let arms = r.pick([up, side, down])
            let m = MotionSpec(base: "idle", leftArm: w(arms), rightArm: w(arms), eyes: r.pick([.happy, .wide, .star]), mouth: .open)
            var s = spec(m, 1.5...3)
            s.jumpEvery = r.pick([0.4, 0.55, 0.7])
            s.jumpHeight = r.pick([5, 8, 12])
            return s

        case .wiggle:
            let arms = r.pick([up, side])
            let f = r.pick([1.5, 2.5])
            let m = MotionSpec(base: "idle", leftArm: w(arms, 0.2, f), rightArm: w(arms, 0.2, f, .pi), lean: w(0, r.pick([0.05, 0.1]), f),
                               sway: w(0, r.pick([1.5, 3]), f), eyes: r.pick([.happy, .closed, .wink]), mouth: .grin)
            return spec(m, 1.8...3.2, emote: .notes, every: 0.9)

        case .clap:
            let f = r.pick([3.0, 4.0, 5.0])
            let m = MotionSpec(base: r.pick(["idle", "sit"]), leftArm: w(chest, 0.3, f), rightArm: w(chest, 0.3, f),
                               eyes: r.pick([.happy, .star]), mouth: .open)
            return spec(m, 1.4...2.6, emote: r.pick([.sparkles, .confetti, .notes]), every: 0.6)

        case .daydream:
            let m = MotionSpec(base: "sit", headTilt: w(0.12, 0.06, 0.25), eyes: r.pick([.half, .closed, .heart]), mouth: .smile)
            return spec(m, 3...6, emote: r.pick([.thought, .hearts, .bubbles, .flowers]), every: 1.5)

        case .sing:
            let style = r.int(0, 2)
            let la = style == 0 ? w(chest) : (style == 1 ? w(side, 0.3, 0.8) : w(up, 0.2, 1))
            let ra = style == 0 ? w(chest) : (style == 1 ? w(side, 0.3, 0.8, .pi) : w(down))
            let m = MotionSpec(base: r.pick(["idle", "sit"]), leftArm: la, rightArm: ra, lean: w(0, 0.06, 0.6),
                               eyes: r.pick([.closed, .happy]), mouth: r.pick([.open, .o]))
            return spec(m, 2.5...4.5, emote: r.pick([.notes, .music]), every: 0.6)

        case .salute:
            let m = MotionSpec(base: "idle", leftArm: w(down), rightArm: w(chin + 0.1), eyes: r.pick([.open, .wink]), mouth: r.pick([.grin, .smile]))
            return spec(m, 1.2...2)

        case .shiver:
            let m = MotionSpec(base: "idle", leftArm: w(chest), rightArm: w(chest), sway: w(0, 0.8, 12),
                               eyes: r.pick([.squeeze, .teary]), mouth: .wobbly)
            return spec(m, 1.4...2.4, emote: r.pick([nil, .sweat]))

        case .flex:
            let f = r.pick([1.0, 2.0])
            let m = MotionSpec(base: "idle", leftArm: w(2.0, 0.25, f), rightArm: w(2.0, 0.25, f), lean: w(0.05),
                               eyes: r.pick([.half, .wink]), mouth: .grin)
            return spec(m, 1.5...2.5, emote: r.pick([.shine, .sparkles]), every: 0.8)

        case .sniff:
            let m = MotionSpec(base: "idle", lean: w(-0.2, 0.05, 1.5), headTilt: w(-0.1, 0.06, 2),
                               eyes: r.pick([.half, .closed, .dot]), mouth: .cat)
            return spec(m, 1.5...3, emote: r.pick([.question, .leaves]), every: 1.2)

        case .tailChase:
            let m = MotionSpec(base: "run", eyes: r.pick([.spiral, .squeeze]), mouth: .open, flipEvery: r.pick([0.25, 0.35]))
            return spec(m, 1.6...2.8, emote: .sweat)

        case .napShort:
            return spec(MotionSpec(base: "sleep"), 6...15, emote: .zzz, every: 1.3)

        case .giggle:
            let m = MotionSpec(base: "idle", leftArm: w(3.7), rightArm: w(3.7), bounce: w(0, 0.8, 4),
                               eyes: r.pick([.happy, .closed, .wink]), mouth: .grin)
            var s = spec(m, 1.2...2.2, emote: r.pick([nil, .notes, .sparkles]), every: 0.7)
            s.say = r.pick(L10n.isKorean ? ["키득키득", "히히히", "큭큭"] : ["Tee-hee", "Hehehe", "Heh heh"])
            return s

        case .pout:
            let m = MotionSpec(base: "sit", headTilt: w(r.pick([-0.12, 0.12])), eyes: r.pick([.half, .wink, .open]), mouth: .kiss)
            return spec(m, 1.6...3, emote: r.pick([nil, .hearts, .angry]))

        case .fistPump:
            let f = r.pick([2.0, 3.0])
            let m = MotionSpec(base: "idle", leftArm: w(down), rightArm: w(up, 0.35, f), eyes: r.pick([.squeeze, .star]),
                               mouth: r.pick([.open, .grin]))
            var s = spec(m, 1.2...2)
            s.jumpEvery = 1.0
            s.jumpHeight = 7
            s.say = r.pick(L10n.isKorean ? ["아자!", "좋았어!", "가즈아!"] : ["Let's go!", "Yes!", "Full speed!"])
            return s

        case .love:
            let m = MotionSpec(base: "idle", leftArm: w(face), rightArm: w(face), sway: w(0, r.pick([0, 1.5]), 0.8),
                               eyes: .heart, mouth: r.pick([.smile, .kiss, .open]))
            return spec(m, 1.8...3, emote: .hearts, every: 0.4)

        case .dizzy:
            let m = MotionSpec(base: "idle", lean: w(0, 0.15, 0.8), headTilt: w(0, 0.12, 1.1), eyes: .spiral, mouth: .wobbly)
            return spec(m, 1.6...2.6, emote: r.pick([.stars, .sweat]), every: 0.6)
        }
    }
}
