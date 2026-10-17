import Foundation
import CoreGraphics

/// 행동 한 단계
public enum BehaviorStep: Equatable, Sendable {
    case move(MovePattern, Gait, size: Double, repeats: Int)
    case perform(ActSpec)
    case emote(Emote, count: Int)
    case say(String)
    /// variant: 활동 안의 세부(공 차는 횟수, 낙서 도안, 가는 구석…)를 정하는 seed
    case macro(Macro, variant: UInt64)
    case friend(FriendGame, variant: UInt64)
    case pause(Double)
}

public struct BehaviorPlan: Equatable, Sendable {
    public var archetype: String
    public var steps: [BehaviorStep]
    public var seed: UInt64
}

/// 지금 상황 (욕구·시간·친구 유무)
public struct BehaviorContext: Sendable {
    public var hunger: Double
    public var energy: Double
    public var fun: Double
    public var affection: Double
    public var hour: Int
    public var hasFriends: Bool
    public var agentBusy: Bool
    public var canDoodle: Bool
    public var canTrash: Bool
    public var interjection: String
    /// 화면에 남아 있는 낙서 묶음 수 (깔끔쟁이일수록 치우고 싶어한다)
    public var doodleCount: Int

    public init(hunger: Double, energy: Double, fun: Double, affection: Double, hour: Int, hasFriends: Bool,
                agentBusy: Bool, canDoodle: Bool, canTrash: Bool, interjection: String, doodleCount: Int = 0) {
        self.hunger = hunger
        self.energy = energy
        self.fun = fun
        self.affection = affection
        self.hour = hour
        self.hasFriends = hasFriends
        self.agentBusy = agentBusy
        self.canDoodle = canDoodle
        self.canTrash = canTrash
        self.interjection = interjection
        self.doodleCount = doodleCount
    }
}

/// seed 기반 행동 조합기.
///
/// 아키타입(산책·운동·춤·자랑·휴식·탐험·장난·창작·먹이·사교·안절부절·순찰·삐짐·놀이·친구) 하나를 성격·욕구 가중치로 고르고,
/// 그 안의 칸(이동 패턴 × 걸음걸이 × 동작 레시피 × 감정 × 대사)을 같은 seed의 난수로 채운다.
/// 펫 seed와 행동 번호를 섞어 행동 seed를 만들므로 같은 펫은 같은 순서로, 다른 펫은 다르게 논다.
public enum BehaviorComposer {
    struct Archetype {
        var name: String
        var moves: [MovePattern]
        var gaits: [Gait]
        var acts: [Act]
        var emotes: [Emote]
        var moods: [Mood]
        /// 이동 없이 동작만 할 수도 있는지
        var moveOptional: Bool
        var actCount: ClosedRange<Int>
    }

    static let archetypes: [Archetype] = [
        Archetype(name: "stroll", moves: [.wander, .line, .wave, .pace, .backAndForth], gaits: [.walk, .tiptoe, .strut, .wobble],
                  acts: [.lookAround, .sniff, .stargaze, .think, .sit, .nod], emotes: [.leaves, .flowers, .notes], moods: [.calm, .curious],
                  moveOptional: false, actCount: 0...1),
        Archetype(name: "exercise", moves: [.circle, .square, .triangle, .figure8, .zigzag, .patrolBottom], gaits: [.run, .skip, .hop, .scurry],
                  acts: [.stretch, .flex, .fistPump, .cheer, .bounce], emotes: [.sweat, .steam, .sparkles], moods: [.cheerful, .proud],
                  moveOptional: false, actCount: 1...2),
        Archetype(name: "dance", moves: [.circle, .backAndForth, .heartPath, .starPath], gaits: [.skip, .hop, .strut],
                  acts: [.dance, .wiggle, .spin, .bounce, .clap, .nod, .sing], emotes: [.notes, .music, .confetti, .stars], moods: [.cheerful, .playful],
                  moveOptional: true, actCount: 2...4),
        Archetype(name: "showoff", moves: [.toCenter, .toCursor], gaits: [.strut, .skip],
                  acts: [.flex, .salute, .bow, .cheer, .spin, .fistPump], emotes: [.shine, .sparkles, .stars], moods: [.proud],
                  moveOptional: false, actCount: 1...2),
        Archetype(name: "rest", moves: [.toCorner, .toEdge, .wander], gaits: [.walk, .tiptoe, .wobble],
                  acts: [.sit, .yawn, .daydream, .stargaze, .napShort, .groom], emotes: [.zzz, .bubbles, .thought], moods: [.sleepy, .calm],
                  moveOptional: true, actCount: 1...2),
        Archetype(name: "curious", moves: [.toCursor, .peekEdge, .toCorner, .toEdge, .spiral], gaits: [.tiptoe, .sneak, .walk],
                  acts: [.sniff, .lookAround, .think, .shakeHead, .nod], emotes: [.question, .exclaim, .thought], moods: [.curious],
                  moveOptional: false, actCount: 1...2),
        Archetype(name: "mischief", moves: [.orbitCursor, .toCursor, .randomHops, .zigzag, .awayFromCursor], gaits: [.scurry, .sneak, .hop],
                  acts: [.pounceAir, .giggle, .wiggle, .tailChase, .pout], emotes: [.exclaim, .sparkles, .angry], moods: [.playful],
                  moveOptional: false, actCount: 1...2),
        Archetype(name: "social", moves: [.toCursor], gaits: [.walk, .skip],
                  acts: [.wave, .clap, .giggle, .nod, .sing, .love], emotes: [.hearts, .flowers], moods: [.affectionate],
                  moveOptional: true, actCount: 1...2),
        Archetype(name: "fidget", moves: [], gaits: [],
                  acts: [.groom, .shiver, .sneeze, .hiccup, .stretch, .yawn, .shakeHead, .nod, .wiggle, .dizzy], emotes: [.sweat, .bubbles],
                  moods: [.calm, .playful], moveOptional: true, actCount: 2...3),
        Archetype(name: "patrol", moves: [.patrolBottom, .square, .toEdge, .peekEdge], gaits: [.walk, .strut, .run],
                  acts: [.salute, .lookAround, .sniff], emotes: [.exclaim, .question], moods: [.proud, .coding],
                  moveOptional: false, actCount: 1...1),
        Archetype(name: "sulk", moves: [.toCorner, .awayFromCursor], gaits: [.walk, .wobble],
                  acts: [.sulk, .pout, .sit], emotes: [.steam, .angry, .thought], moods: [.grumpy],
                  moveOptional: true, actCount: 1...2),
    ]

    /// 가능한 행동 조합 수 (이동 × 걸음 × 동작 변형 × 감정 × 대사 기분, 연속값 변화 제외)
    public static var combinationCount: Int {
        var total = 0
        for a in archetypes {
            let moveCombos = max(1, a.moves.count * a.gaits.count) + (a.moveOptional ? 1 : 0)
            let actVariants = a.acts.reduce(0) { $0 + ActRecipes.variants($1) }
            let emotes = a.emotes.count + 1
            let moods = a.moods.count + 1
            total += moveCombos * actVariants * emotes * moods
        }
        // 대형 활동(먹기·공·낙서·휴지통·추격·낮잠)과 친구 놀이 조합
        total += Macro.allCases.count * 12 + FriendGame.allCases.count * 40
        return total
    }

    public static func compose(personality p: Personality, context c: BehaviorContext, seed: UInt64) -> BehaviorPlan {
        var r = SplitMix64(seed: seed)

        // 급한 욕구 먼저
        if c.hunger > 72, r.chance(0.8) {
            return BehaviorPlan(archetype: "eat", steps: [.macro(.eat, variant: r.next())], seed: seed)
        }
        if c.energy < 12 {
            return BehaviorPlan(archetype: "home", steps: [.say(SpeechBank.line(.sleepy, rng: &r, interjection: c.interjection)), .macro(.home, variant: r.next())], seed: seed)
        }

        let night = c.hour >= 23 || c.hour < 6
        let tired = (100 - c.energy) / 100
        let bored = (100 - c.fun) / 100
        var weights: [(String, Double)] = [
            ("stroll", 2.2 + p.curiosity),
            ("exercise", (0.6 + p.energy * 1.8) * (1 - tired)),
            ("dance", 0.5 + p.energy * 1.2 + p.sociability * 0.4),
            ("showoff", 0.3 + p.mischief * 0.6 + p.energy * 0.3),
            ("rest", 0.6 + p.laziness * 1.8 + tired * 3 + (night ? 2 : 0)),
            ("curious", 0.8 + p.curiosity * 2),
            ("mischief", 0.3 + p.mischief * 2 + bored),
            ("social", 0.4 + p.sociability * 1.6 + (c.affection < 40 ? 1.2 : 0)),
            ("fidget", 1.0 + p.tidiness * 0.8),
            ("patrol", 0.3 + (c.agentBusy ? 1.2 : 0.2)),
            ("sulk", c.affection < 25 || c.fun < 15 ? 1.2 : 0.05),
            // 대형 활동
            ("m:eat", c.hunger > 45 ? 0.6 + p.appetite * 2 : 0.1 * p.appetite),
            ("m:ball", (0.4 + p.energy + bored) * (1 - tired)),
            ("m:chaseCursor", (0.3 + p.mischief + p.energy * 0.5) * (1 - tired)),
            ("m:trash", c.canTrash ? 0.3 + p.curiosity * 0.8 + p.mischief * 0.6 : 0),
            ("m:doodle", c.canDoodle ? (0.3 + p.artistry * 1.6) * (c.doodleCount > 25 ? 0.3 : 1) : 0),
            ("m:clean", c.doodleCount >= 3 ? 0.15 + p.tidiness * 2.2 + Double(min(c.doodleCount, 40)) / 25 : 0),
            ("m:nap", 0.2 + p.laziness + tired * 2.5 + (night ? 1.5 : 0)),
            ("m:home", tired > 0.75 ? 1.5 : 0),
            ("friend", c.hasFriends ? 0.6 + p.sociability * 2.2 : 0),
        ]
        if c.agentBusy { weights.append(("coding", 0.8)) }
        let choice = r.weighted(weights)

        if choice.hasPrefix("m:"), let macro = Macro(rawValue: String(choice.dropFirst(2))) {
            var steps: [BehaviorStep] = []
            if r.chance(0.35) {
                let mood: Mood = macro == .eat ? .hungry : (macro == .nap || macro == .home ? .sleepy : (macro == .clean ? .calm : .playful))
                steps.append(.say(SpeechBank.line(mood, rng: &r, interjection: c.interjection)))
            }
            steps.append(.macro(macro, variant: r.next()))
            if r.chance(0.3) { steps.append(.perform(ActRecipes.make(r.pick([.cheer, .clap, .nod, .bounce, .stretch]), rng: &r))) }
            return BehaviorPlan(archetype: choice, steps: steps, seed: seed)
        }
        if choice == "friend" {
            let game = r.weighted(FriendGame.allCases.map { g -> (FriendGame, Double) in
                switch g {
                case .napTogether: return (g, 0.4 + tired * 2)
                case .tag, .ballPass: return (g, (1 + p.energy) * (1 - tired))
                case .danceTogether: return (g, 0.8 + p.energy)
                default: return (g, 1)
                }
            })
            return BehaviorPlan(archetype: "friend", steps: [.friend(game, variant: r.next())], seed: seed)
        }
        if choice == "coding" {
            var steps: [BehaviorStep] = [.say(SpeechBank.line(.coding, rng: &r, interjection: c.interjection))]
            steps.append(.perform(ActRecipes.make(r.pick([.think, .nod, .salute, .flex]), rng: &r)))
            return BehaviorPlan(archetype: "coding", steps: steps, seed: seed)
        }

        let a = archetypes.first { $0.name == choice } ?? archetypes[0]
        var steps: [BehaviorStep] = []
        let wantsMove = !a.moves.isEmpty && (!a.moveOptional || r.chance(0.6))
        let moodLine: () -> BehaviorStep = {
            .say(SpeechBank.line(r.pick(a.moods), rng: &r, interjection: c.interjection))
        }
        if r.chance(0.3) { steps.append(moodLine()) }
        if wantsMove {
            let pattern = r.pick(a.moves)
            let gait = r.pick(a.gaits)
            let size = r.range(0.6, 1.4) * (0.7 + p.energy * 0.6)
            let repeats = [.circle, .square, .triangle, .figure8, .backAndForth, .pace].contains(pattern) ? r.int(1, 2) : 1
            steps.append(.move(pattern, gait, size: size, repeats: repeats))
        }
        let count = r.int(a.actCount.lowerBound, a.actCount.upperBound)
        for i in 0..<max(count, wantsMove ? 0 : 1) {
            var spec = ActRecipes.make(r.pick(a.acts), rng: &r)
            if spec.emote == nil, r.chance(0.5) { spec.emote = r.pick(a.emotes) }
            steps.append(.perform(spec))
            if i < count - 1, r.chance(0.4) { steps.append(.pause(r.range(0.3, 1.2))) }
        }
        if r.chance(0.25) { steps.append(.emote(r.pick(a.emotes), count: r.int(2, 4))) }
        if r.chance(0.2) { steps.append(moodLine()) }
        return BehaviorPlan(archetype: a.name, steps: steps, seed: seed)
    }
}

/// 이동 패턴 → 경유점 (전역 좌표, 순수 계산)
public enum PathPlanner {
    public static func waypoints(_ pattern: MovePattern, from p: CGPoint, size s: Double, repeats: Int, bounds b: CGRect,
                                 cursor: CGPoint, rng r: inout SplitMix64) -> [CGPoint] {
        let unit = CGFloat(110 * s)
        func clamp(_ q: CGPoint) -> CGPoint { CGPoint(x: min(max(q.x, b.minX), b.maxX), y: min(max(q.y, b.minY), b.maxY)) }
        func around(_ c: CGPoint, _ n: Int, _ radius: CGFloat, start: Double = 0, turns: Double = 1) -> [CGPoint] {
            (0...n).map { i in
                let a = start + Double(i) / Double(n) * 2 * .pi * turns
                return CGPoint(x: c.x + CGFloat(cos(a)) * radius, y: c.y + CGFloat(sin(a)) * radius * 0.75)
            }
        }
        var pts: [CGPoint]
        let dir: CGFloat = r.chance(0.5) ? 1 : -1
        switch pattern {
        case .wander:
            let a = r.range(0, 2 * .pi)
            let d = unit * CGFloat(r.range(1.2, 3.5))
            pts = [CGPoint(x: p.x + CGFloat(cos(a)) * d, y: p.y + CGFloat(sin(a)) * d * 0.7)]
        case .line:
            let a = r.range(0, 2 * .pi)
            pts = [CGPoint(x: p.x + CGFloat(cos(a)) * unit * 3, y: p.y + CGFloat(sin(a)) * unit * 1.5)]
        case .zigzag:
            pts = (1...6).map { i in CGPoint(x: p.x + dir * CGFloat(i) * unit * 0.55, y: p.y + (i % 2 == 0 ? unit * 0.35 : -unit * 0.35)) }
        case .circle:
            let c = CGPoint(x: p.x + dir * unit * 0.8, y: p.y)
            pts = around(c, 16 * repeats, unit * 0.8, start: dir > 0 ? .pi : 0, turns: Double(repeats))
        case .figure8:
            pts = (0...32).map { i in
                let t = Double(i) / 32 * 2 * .pi
                return CGPoint(x: p.x + CGFloat(sin(t)) * unit, y: p.y + CGFloat(sin(t) * cos(t)) * unit * 0.6)
            }
        case .spiral:
            pts = (0...36).map { i in
                let t = Double(i) / 36
                let a = t * 4 * .pi
                return CGPoint(x: p.x + CGFloat(cos(a) * t) * unit * 1.4, y: p.y + CGFloat(sin(a) * t) * unit)
            }
        case .square:
            let w = unit * 1.3
            pts = [CGPoint(x: p.x + dir * w, y: p.y), CGPoint(x: p.x + dir * w, y: p.y + w * 0.7), CGPoint(x: p.x, y: p.y + w * 0.7), p]
        case .triangle:
            let w = unit * 1.4
            pts = [CGPoint(x: p.x + dir * w, y: p.y), CGPoint(x: p.x + dir * w / 2, y: p.y + w * 0.8), p]
        case .wave:
            pts = (1...10).map { i in CGPoint(x: p.x + dir * CGFloat(i) * unit * 0.4, y: p.y + CGFloat(sin(Double(i) * 0.9)) * unit * 0.4) }
        case .backAndForth, .pace:
            let w = unit * (pattern == .pace ? 0.8 : 1.6)
            pts = [CGPoint(x: p.x + dir * w, y: p.y), p, CGPoint(x: p.x + dir * w, y: p.y), p]
        case .toCorner:
            let corners = [CGPoint(x: b.minX + 20, y: b.minY + 10), CGPoint(x: b.maxX - 20, y: b.minY + 10),
                           CGPoint(x: b.minX + 20, y: b.maxY - 20), CGPoint(x: b.maxX - 20, y: b.maxY - 20)]
            pts = [corners.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }!]
            if r.chance(0.5) { pts = [r.pick(corners)] }
        case .toEdge:
            let edges = [CGPoint(x: b.minX + 8, y: p.y), CGPoint(x: b.maxX - 8, y: p.y), CGPoint(x: p.x, y: b.minY + 4), CGPoint(x: p.x, y: b.maxY - 10)]
            pts = [r.pick(edges)]
        case .toCenter:
            pts = [CGPoint(x: b.midX + CGFloat(r.range(-40, 40)), y: b.midY + CGFloat(r.range(-30, 30)))]
        case .toCursor:
            pts = [CGPoint(x: cursor.x + CGFloat(r.range(-50, 50)), y: cursor.y - unit * 0.6)]
        case .awayFromCursor:
            let dx = p.x - cursor.x, dy = p.y - cursor.y
            let len = max(1, hypot(dx, dy))
            pts = [CGPoint(x: p.x + dx / len * unit * 2.5, y: p.y + dy / len * unit * 1.6)]
        case .orbitCursor:
            pts = around(CGPoint(x: cursor.x, y: cursor.y - unit * 0.4), 14, unit * 0.9, start: r.range(0, 2 * .pi))
        case .patrolBottom:
            pts = [CGPoint(x: b.minX + 30, y: b.minY + 6), CGPoint(x: b.maxX - 30, y: b.minY + 6)]
            if dir < 0 { pts.reverse() }
        case .peekEdge:
            let left = p.x - b.minX < b.maxX - p.x
            let edgeX = left ? b.minX + 4 : b.maxX - 4
            pts = [CGPoint(x: edgeX, y: p.y), CGPoint(x: edgeX + (left ? 1 : -1) * unit * 0.6, y: p.y)]
        case .randomHops:
            pts = (0..<r.int(3, 6)).map { _ in CGPoint(x: p.x + CGFloat(r.range(-1.5, 1.5)) * unit, y: p.y + CGFloat(r.range(-1, 1)) * unit) }
        case .heartPath:
            pts = (0...30).map { i in
                let t = Double(i) / 30 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return CGPoint(x: p.x + CGFloat(x) * unit / 20, y: p.y + CGFloat(y) * unit / 20)
            }
        case .starPath:
            pts = (0...5).map { i in
                let a = Double.pi / 2 + Double(i) * 4 * .pi / 5
                return CGPoint(x: p.x + CGFloat(cos(a)) * unit, y: p.y + CGFloat(sin(a)) * unit * 0.8)
            }
        }
        return pts.map(clamp)
    }
}
