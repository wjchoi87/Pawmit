import AppKit
import PawmitCore

/// 행동 조합기(BehaviorComposer)가 만든 계획을 실제 움직임으로 옮기는 실행기 + 친구 펫 놀이.
@MainActor
extension Brain {
    // MARK: - 계획

    func nextPlan() -> BehaviorPlan {
        behaviorIndex &+= 1
        let ctx = BehaviorContext(
            hunger: needs.hunger, energy: needs.energy, fun: needs.fun, affection: needs.affection,
            hour: Calendar.current.component(.hour, from: Date()),
            hasFriends: partners().contains { $0.isAvailable }, agentBusy: agentBusy(),
            canDoodle: config.doodles && doodles != nil, canTrash: config.trashRummage,
            interjection: pet.identity.interjection, doodleCount: doodles?.groupIDs.count ?? 0)
        return BehaviorComposer.compose(personality: personality, context: ctx, seed: SplitMix64.mix(behaviorSeed, behaviorIndex))
    }

    func execute(_ plan: BehaviorPlan) async -> Bool {
        var rng = SplitMix64(seed: plan.seed ^ 0xA5A5)
        for step in plan.steps {
            let ok: Bool
            switch step {
            case .move(let pattern, let gait, let size, let repeats):
                ok = await move(pattern, gait: gait, size: size, repeats: repeats, rng: &rng)
            case .perform(let spec):
                ok = await performAct(spec)
            case .emote(let e, let count):
                for _ in 0..<count { emote(e, rng: &rng) }
                ok = await pause(0.8)
            case .say(let line):
                say(line, 2.4)
                ok = await pause(0.3)
            case .macro(let m, let variant):
                ok = await runMacro(m, variant: variant)
            case .friend(let game, let variant):
                ok = await playWithFriend(game, variant: variant)
            case .pause(let s):
                ok = await pause(s)
            }
            if !ok { return false }
        }
        return true
    }

    private func runMacro(_ m: Macro, variant: UInt64) async -> Bool {
        switch m {
        case .eat: return await eat(fromUser: false)
        case .ball: return await playBall(thrownFrom: nil)
        case .chaseCursor: return await chaseCursor()
        case .trash: return config.trashRummage ? await rummageTrash() : true
        case .doodle: return config.doodles ? await doodle(variant: variant) : true
        case .nap: return await nap()
        case .home: return await goHome(reason: .tired)
        case .clean: return await clean(group: nil, maxGroups: 3)
        }
    }

    // MARK: - 이동

    func move(_ pattern: MovePattern, gait: Gait, size: Double, repeats: Int, rng: inout SplitMix64) async -> Bool {
        let screen = world.screen(containing: pet.position)
        // 산책류는 가끔 화면 전체·다른 모니터로 멀리 간다
        if config.roam != "ground", [.wander, .line, .toCorner, .toEdge].contains(pattern),
           rng.chance(world.screens.count > 1 ? 0.3 : 0.2) {
            let far = world.randomPointAnywhere(excluding: world.screens.count > 1 ? screen : nil)
            let long = hypot(far.x - pet.position.x, far.y - pet.position.y) > 700
            return await walk(to: far, gait: long && gait == .walk ? .run : gait)
        }
        let points = PathPlanner.waypoints(pattern, from: pet.position, size: size * Double(pet.displayScale / 1.65), repeats: repeats,
                                           bounds: world.roamRect(screen), cursor: world.cursor, rng: &rng)
        for p in points {
            guard await walk(to: p, gait: gait) else { return false }
        }
        pet.motion = nil
        return true
    }

    /// 걸음걸이를 살려서 걷기 (깡충·살금살금·뒤뚱·으쓱). 다른 화면이면 먼저 건너간다.
    func walk(to p: CGPoint, gait: Gait) async -> Bool {
        guard await travel(toward: p, run: gait.usesRunPose) else { return false }
        pet.moveSpeed = baseSpeed * CGFloat(gait.speed)
        pet.target = p
        pet.setAnim(gait.usesRunPose ? .run : .walk)
        pet.motion = gait.motion
        var t = 0.0, lastHop = 0.0
        while pet.target != nil {
            guard await pause(0.03) else { return false }
            t += 0.03
            if let hop = gait.hop, t - lastHop >= hop.every {
                lastHop = t
                pet.jump(height: CGFloat(hop.height))
            }
            if gait == .scurry, Int(t * 10) % 16 == 0 {
                // 우다다 … 멈칫 … 우다다
                let saved = pet.target
                pet.target = nil
                guard await pause(0.18) else { return false }
                pet.target = saved
            }
            if t > 40 { pet.target = nil }
        }
        return true
    }

    // MARK: - 동작

    func performAct(_ spec: ActSpec) async -> Bool {
        let base = PetAnim(rawValue: spec.motion.base) ?? .idle
        pet.target = nil
        pet.setAnim(base)
        pet.motion = spec.motion
        if let line = spec.say { say(line, 1.8) }
        var rng = SplitMix64(seed: UInt64(spec.seconds * 1000) ^ behaviorIndex)
        if let e = spec.emote { emote(e, rng: &rng) }
        var t = 0.0, lastEmote = 0.0, lastJump = -10.0, lastFlip = 0.0
        while t < spec.seconds {
            guard await pause(0.05) else { return false }
            t += 0.05
            if let e = spec.emote, spec.emoteEvery > 0, t - lastEmote >= spec.emoteEvery {
                lastEmote = t
                emote(e, rng: &rng)
            }
            if let every = spec.jumpEvery, t - lastJump >= every {
                lastJump = t
                pet.jump(height: CGFloat(spec.jumpHeight))
            }
            if let every = spec.motion.flipEvery, t - lastFlip >= every {
                lastFlip = t
                pet.facing = pet.facing == .left ? .right : .left
            }
        }
        pet.motion = nil
        if base == .sleep { needs.energy = min(100, needs.energy + spec.seconds * 0.4) }
        needs.fun = min(100, needs.fun + spec.seconds * 0.6)
        return true
    }

    func emote(_ e: Emote, rng: inout SplitMix64) {
        let head = headParticlePoint
        let glyph = rng.pick(e.glyphs)
        let colors: [Emote: NSColor] = [
            .hearts: NSColor(srgbRed: 0.98, green: 0.42, blue: 0.56, alpha: 1), .notes: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.95, alpha: 1),
            .sparkles: NSColor(srgbRed: 1, green: 0.78, blue: 0.25, alpha: 1), .zzz: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.85, alpha: 1),
            .question: NSColor(srgbRed: 0.95, green: 0.6, blue: 0.2, alpha: 1), .exclaim: NSColor(srgbRed: 0.98, green: 0.33, blue: 0.33, alpha: 1),
        ]
        pet.emit(Particle(text: glyph, pos: CGPoint(x: head.x + CGFloat(rng.range(-14, 14)), y: head.y),
                          vel: CGVector(dx: rng.range(-12, 12), dy: rng.range(16, 30)), maxLife: rng.range(1.2, 1.9),
                          size: CGFloat(rng.range(11, 16)), color: colors[e] ?? .labelColor, weight: .heavy,
                          spin: e == .sparkles || e == .stars ? 1.5 : 0))
    }

    /// 메뉴 "춤춰 줘"
    func danceShow() async -> Bool {
        var r = SplitMix64(seed: UInt64.random(in: 0...UInt64.max))
        say(SpeechBank.line(.cheerful, rng: &r, interjection: pet.identity.interjection), 2)
        for _ in 0..<r.int(2, 3) {
            guard await performAct(ActRecipes.make(r.pick([.dance, .dance, .wiggle, .spin, .clap, .sing]), rng: &r)) else { return false }
        }
        return true
    }

    // MARK: - 친구 펫 놀이

    /// 같이 놀 상대를 데려와서 둘을 함께 움직인다. 상대 펫은 놀이 동안 자기 루프를 쉰다.
    func playWithFriend(_ requested: FriendGame?, variant: UInt64) async -> Bool {
        guard let partner = partners().filter({ $0.isAvailable }).min(by: {
            hypot($0.pet.position.x - pet.position.x, $0.pet.position.y - pet.position.y)
                < hypot($1.pet.position.x - pet.position.x, $1.pet.position.y - pet.position.y)
        }) else {
            return await danceShow()
        }
        var r = SplitMix64(seed: variant)
        let game = requested ?? r.pick(FriendGame.allCases)
        partner.borrow()
        defer { partner.giveBack() }
        let me = pet, them = partner.pet
        let screen = world.screen(containing: me.position)
        let bounds = world.roamRect(screen)
        let gap = 46 * me.displayScale / 1.65

        // 둘이 만날 자리로 이동
        func meet(spacing: CGFloat) async -> Bool {
            let mid = world.clamp(CGPoint(x: (me.position.x + them.position.x) / 2, y: (me.position.y + them.position.y) / 2), to: screen)
            async let a: Bool = partner.walk(to: CGPoint(x: mid.x + spacing / 2, y: mid.y), gait: .walk)
            let b = await walk(to: CGPoint(x: mid.x - spacing / 2, y: mid.y), gait: .walk)
            let ok = await a && b
            me.facing = .right
            them.facing = .left
            return ok
        }

        switch game {
        case .greet:
            guard await meet(spacing: gap * 1.6) else { return false }
            let aSpec = ActRecipes.make(.wave, rng: &r)
            async let a = partner.performAct(aSpec)
            partner.say(partner.pet.identity.interjection.isEmpty ? L10n.t("안녕!") : L10n.format("%@ 안녕!", partner.pet.identity.interjection), 1.6)
            let b = await performAct(ActRecipes.make(r.pick([.wave, .love, .giggle]), rng: &r))
            return await a && b

        case .highFive:
            guard await meet(spacing: gap * 1.1) else { return false }
            let up = MotionSpec(base: "idle", leftArm: Wave(1.2), rightArm: Wave(2.4), eyes: .squeeze, mouth: .grin)
            me.motion = up
            them.motion = up
            guard await pause(0.4) else { return false }
            me.jump(height: 12)
            them.jump(height: 12)
            for _ in 0..<4 { emote(.sparkles, rng: &r) }
            say(L10n.t("하이파이브!"), 1.6)
            guard await pause(0.7) else { return false }
            let aSpec = ActRecipes.make(.cheer, rng: &r)
            async let a = partner.performAct(aSpec)
            let b = await performAct(ActRecipes.make(.cheer, rng: &r))
            return await a && b

        case .danceTogether:
            guard await meet(spacing: gap * 1.8) else { return false }
            // 같은 seed로 만든 춤 → 둘이 똑같이 춘다
            let seed = r.next()
            var r1 = SplitMix64(seed: seed), r2 = SplitMix64(seed: seed)
            let s1 = ActRecipes.make(.dance, rng: &r1), s2 = ActRecipes.make(.dance, rng: &r2)
            say(L10n.t("같이 춤추자!"), 1.6)
            async let a = partner.performAct(s2)
            let b = await performAct(s1)
            return await a && b

        case .chatter:
            guard await meet(spacing: gap * 1.7) else { return false }
            for turn in 0..<r.int(3, 5) {
                let speaker = turn % 2 == 0 ? self : partner
                let listener = turn % 2 == 0 ? partner : self
                speaker.say(SpeechBank.line(r.pick([.cheerful, .curious, .playful, .affectionate, .coding]), rng: &r,
                                            interjection: speaker.pet.identity.interjection), 2)
                let lSpec = ActRecipes.make(r.pick([.nod, .giggle, .think]), rng: &r)
                async let l = listener.performAct(lSpec)
                let s = await speaker.performAct(ActRecipes.make(r.pick([.wave, .sing, .clap, .flex]), rng: &r))
                guard await l, s else { return false }
            }
            return true

        case .tag:
            say(L10n.t("술래잡기 하자!"), 1.6)
            var chaser = self, runner = partner
            var swapped = false
            var t = 0.0
            while t < r.range(7, 11) {
                let dx = runner.pet.position.x - chaser.pet.position.x, dy = runner.pet.position.y - chaser.pet.position.y
                let d = max(1, hypot(dx, dy))
                if d < 20 * me.displayScale / 1.65 {
                    chaser.say(L10n.t("잡았다!"), 1.2)
                    runner.pet.jump(height: 10)
                    if swapped { break }
                    swapped = true
                    swap(&chaser, &runner)
                    guard await pause(0.6) else { return false }
                    continue
                }
                let flee = world.clamp(CGPoint(x: runner.pet.position.x + dx / d * 120, y: runner.pet.position.y + dy / d * 80 + CGFloat(r.range(-40, 40))), to: screen)
                runner.pet.moveSpeed = baseSpeed * 2.3
                runner.pet.target = flee
                runner.pet.setAnim(.run)
                chaser.pet.moveSpeed = baseSpeed * 2.6
                chaser.pet.target = runner.pet.position
                chaser.pet.setAnim(.run)
                guard await pause(0.05) else { return false }
                t += 0.05
            }
            me.target = nil
            them.target = nil
            let aSpec = ActRecipes.make(.bounce, rng: &r)
            async let a = partner.performAct(aSpec)
            let b = await performAct(ActRecipes.make(.cheer, rng: &r))
            return await a && b

        case .followLeader:
            say(L10n.t("나 따라와~"), 1.6)
            var target = me.position
            var t = 0.0
            while t < r.range(7, 11) {
                if me.target == nil {
                    target = world.randomPoint(near: me.position, min: 80, max: 240)
                    me.moveSpeed = baseSpeed * 1.1
                    me.target = target
                    me.setAnim(.walk)
                }
                let behind = CGPoint(x: me.position.x - me.facing.sign * gap * 1.4, y: me.position.y)
                if hypot(behind.x - them.position.x, behind.y - them.position.y) > 6 {
                    them.moveSpeed = baseSpeed * 1.3
                    them.target = behind
                    if them.anim != .walk { them.setAnim(.walk) }
                } else {
                    them.target = nil
                    them.setAnim(.idle)
                }
                guard await pause(0.05) else { return false }
                t += 0.05
            }
            me.target = nil
            them.target = nil
            return await performAct(ActRecipes.make(.nod, rng: &r))

        case .napTogether:
            let spot = world.randomPoint(near: me.position, min: 40, max: 160)
            async let a: Bool = partner.walk(to: CGPoint(x: spot.x + gap, y: spot.y), gait: .tiptoe)
            let b = await walk(to: spot, gait: .tiptoe)
            guard await a, b else { return false }
            me.facing = .right
            them.facing = .left
            say(L10n.t("같이 낮잠 자자…"), 1.8)
            let nap = Double(r.range(14, 28))
            var s1 = ActRecipes.make(.napShort, rng: &r)
            s1.seconds = nap
            let s2 = s1
            async let c = partner.performAct(s2)
            let d = await performAct(s1)
            needs.energy = min(100, needs.energy + 10)
            return await c && d

        case .shareSnack:
            guard await meet(spacing: gap * 2.2) else { return false }
            let mid = CGPoint(x: (me.position.x + them.position.x) / 2, y: me.position.y)
            let bowl = props.spawn(.bowl, at: mid, scale: me.displayScale / 1.65)
            defer { bowl.dismiss() }
            say(L10n.t("나눠 먹자!"), 1.6)
            guard await pause(0.5) else { return false }
            me.setAnim(.eat)
            them.setAnim(.eat)
            for _ in 0..<3 {
                guard await pause(1.5) else { return false }
                bowl.food = max(0, bowl.food - 1)
            }
            needs.hunger = max(0, needs.hunger - 45)
            partner.needs.hunger = max(0, partner.needs.hunger - 45)
            let aSpec = ActRecipes.make(.love, rng: &r)
            async let a = partner.performAct(aSpec)
            let b = await performAct(ActRecipes.make(.love, rng: &r))
            return await a && b

        case .ballPass:
            guard await meet(spacing: min(bounds.width * 0.4, 240 * me.displayScale / 1.65)) else { return false }
            let ball = props.spawn(.ball, at: CGPoint(x: me.position.x + gap * 0.6, y: me.position.y), scale: me.displayScale / 1.65)
            defer { ball.dismiss() }
            props.ballBounds = bounds
            say(L10n.t("받아라~!"), 1.4)
            var kicker = me, receiver = them
            for _ in 0..<r.int(3, 6) {
                kicker.setAnim(.pounce)
                guard await pause(0.3) else { return false }
                kicker.jump(height: 8)
                let dx = receiver.position.x - ball.position.x, dy = receiver.position.y - ball.position.y
                let d = max(1, hypot(dx, dy))
                ball.velocity = CGVector(dx: dx / d * 330, dy: dy / d * 330)
                kicker.setAnim(.idle)
                receiver.setAnim(.play)
                var waited = 0.0
                while hypot(ball.position.x - receiver.position.x, ball.position.y - receiver.position.y) > 26 * me.displayScale / 1.65, waited < 2.5 {
                    guard await pause(0.03) else { return false }
                    waited += 0.03
                }
                ball.velocity = .zero
                swap(&kicker, &receiver)
            }
            needs.fun = min(100, needs.fun + 25)
            partner.needs.fun = min(100, partner.needs.fun + 25)
            let aSpec = ActRecipes.make(.cheer, rng: &r)
            async let a = partner.performAct(aSpec)
            let b = await performAct(ActRecipes.make(.clap, rng: &r))
            return await a && b
        }
    }
}
