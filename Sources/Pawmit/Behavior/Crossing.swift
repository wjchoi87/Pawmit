import AppKit
import PawmitCore

/// 모니터 사이 이동. 화면 배치(시스템 설정 > 디스플레이)에서 맞닿은 변을 찾아 그쪽으로 걸어가고,
/// 두 화면의 바닥 높이가 다르면 사다리·밧줄·점프·우산·친구 도움 중 하나로 오르내린 뒤 베젤을 넘는다.
/// 방법은 성격(활발·호기심·사교성·장난)과 높이 차이로 가중치를 매겨 seed로 고른다.
@MainActor
extension Brain {
    enum ClimbStyle: String, CaseIterable {
        case ladder, rope, jump, umbrella, friendPull, friendCatch
    }

    /// 목적지 화면까지 맞닿은 화면을 차례로 건너간다. 자유 이동 모드에서도 45%(바닥 근처면 항상)는 바닥을 따라가
    /// 높이 차이를 오르내리고, 땅 모드는 항상 바닥을 따라간다. 이어진 변이 없으면 직선으로 간다.
    func travel(toward dest: CGPoint, run: Bool) async -> Bool {
        var hops = 0
        while hops < 4 {
            let here = world.screen(containing: pet.position), there = world.screen(containing: dest)
            guard here != there, let path = world.screenPath(from: here, to: there), path.count >= 2 else { return true }
            hops += 1
            crossings &+= 1
            var rng = SplitMix64(seed: SplitMix64.mix(behaviorSeed, 0xC0_55 &+ crossings))
            let nearFloor = pet.position.y - world.roamRect(here).minY < 140
            let alongFloor = config.roam == "ground" || nearFloor || forcedClimb != nil || rng.chance(0.45)
            guard let c = world.crossing(from: here, to: path[1], at: pet.position, toward: dest, alongFloor: alongFloor) else { return true }
            guard await cross(c, run: run, rng: &rng) else { return false }
        }
        return true
    }

    private func cross(_ c: World.Crossing, run: Bool, rng: inout SplitMix64) async -> Bool {
        guard await walkDirect(to: c.exit, run: run) else { return false }
        if c.dir != 0 { pet.facing = c.dir > 0 ? .right : .left }
        if let leg = c.pre { guard await climb(leg, rng: &rng) else { return false } }
        if let hop = c.hop {
            // 베젤 넘기: 폴짝
            pet.jump(height: 12)
            guard await walkDirect(to: hop, run: run) else { return false }
        }
        if let leg = c.post { guard await climb(leg, rng: &rng) else { return false } }
        return true
    }

    // MARK: - 오르내리기

    private func climb(_ leg: World.Leg, rng: inout SplitMix64) async -> Bool {
        // 공중에 그림자가 떠 있지 않게 (취소돼도 다음 걷기·착지에서 다시 켠다)
        pet.hideShadow = true
        defer { pet.hideShadow = false }
        let d = pet.displayScale
        let up = leg.rise > 0
        let dist = abs(leg.rise)
        let landing = CGPoint(x: leg.x, y: leg.to)
        let legScreen = world.screen(containing: landing)
        // 화면 안쪽 방향 (친구가 설 자리)
        let inward: CGFloat = leg.x < legScreen.frame.midX ? 1 : -1
        let helper = partners()
            .filter { $0.isAvailable && world.screen(containing: $0.pet.position) == legScreen }
            .min { hypot($0.pet.position.x - leg.x, $0.pet.position.y - leg.to) < hypot($1.pet.position.x - leg.x, $1.pet.position.y - leg.to) }

        let p = personality
        var options: [(ClimbStyle, Double)]
        if up {
            options = [(.ladder, 1), (.rope, 0.8)]
            if dist <= 50 * d { options.append((.jump, 0.4 + p.energy * 1.6)) }
            if helper != nil { options.append((.friendPull, 0.5 + p.sociability * 2)) }
        } else {
            options = [(.ladder, 0.7), (.rope, 0.9)]
            if dist <= 80 * d { options.append((.jump, 0.4 + (p.energy + p.mischief) * 0.9)) }
            options.append((.umbrella, dist >= 60 * d ? 0.8 + p.curiosity * 1.2 : 0.15))
            if helper != nil { options.append((.friendCatch, 0.5 + p.sociability * 2)) }
        }
        var style = rng.weighted(options)
        if let forced = forcedClimb.flatMap(ClimbStyle.init(rawValue:)), options.contains(where: { $0.0 == forced }) { style = forced }
        forcedClimb = nil
        lastCrossing = style.rawValue
        planHistory.append("cross:" + style.rawValue)
        #if DEBUG
        Log.info("cross \(pet.identity.id) \(style.rawValue) rise=\(Int(leg.rise))")
        #endif

        switch style {
        case .ladder: return await ladder(leg)
        case .rope: return up ? await ropeUp(leg) : await ropeDown(leg)
        case .jump: return await jump(leg)
        case .umbrella: return await umbrella(leg)
        case .friendPull:
            guard let helper else { return await ladder(leg) }
            return await friendPull(leg, helper: helper, inward: inward)
        case .friendCatch:
            guard let helper else { return await jump(leg) }
            return await friendCatch(leg, helper: helper, inward: inward)
        }
    }

    /// 소품 크기 (기본 펫 크기 1.65 기준)
    private var propScale: CGFloat { pet.displayScale / 1.65 }

    private func climbMotion(up: Bool, rope: Bool) -> MotionSpec {
        if pet.renderer is CatRenderer {
            // 고양이는 몸을 세워 머리부터 오르고, 내려올 때는 머리를 아래로.
            // 렌더러는 발을 축으로 돌려서 꼬리가 펫 창 밖으로 잘린다 → 몸 가운데(0, 25)를 축으로 돌린 것과 같게
            // 이동(sway: 돌린 뒤 x, bounce: 돌리기 전 y)을 더하고 조금 띄운다.
            let angle = up ? 0.75 : -0.55, lift = up ? 16.0 : 14.0
            let sx = 25 * sin(angle) / cos(angle)
            let by = 25 - 25 * cos(angle) - sx * sin(angle) + lift
            return MotionSpec(base: "walk", lean: Wave(angle), bounce: Wave(by, amp: 0.8, freq: rope ? 4 : 3), sway: Wave(sx),
                              eyes: up ? nil : .wide)
        }
        let f = rope ? 2.2 : 1.6
        return MotionSpec(base: rope ? "idle" : "walk",
                          leftArm: Wave(2.75, amp: 0.4, freq: f), rightArm: Wave(2.75, amp: 0.4, freq: f, phase: .pi),
                          bounce: Wave(0.4, amp: 0.8, freq: f * 2), eyes: up ? .squeeze : .wide, mouth: up ? .flat : .o)
    }

    /// 방향은 그대로 두고 직선으로 미끄러지듯 이동 (오르내리기용)
    private func glide(to q: CGPoint, speed: CGFloat, anim: PetAnim) async -> Bool {
        let facing = pet.facing
        pet.moveSpeed = speed
        pet.target = q
        pet.setAnim(anim)
        var waited = 0.0
        while pet.target != nil {
            guard await pause(0.03) else { return false }
            waited += 0.03
            if waited > 30 { pet.position = q; pet.target = nil }
        }
        pet.facing = facing
        return true
    }

    /// 포물선으로 뛰기 (발 위치를 직접 옮긴다)
    private func leap(to q: CGPoint, apex: CGFloat, duration: TimeInterval) async -> Bool {
        let start = pet.position
        pet.target = nil
        let t0 = ProcessInfo.processInfo.systemUptime
        while true {
            guard await pause(0.016) else { return false }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - t0) / duration)
            let e = CGFloat(t)
            pet.setAnim(e < 0.5 && q.y >= start.y ? .pounce : .fall)
            pet.position = CGPoint(x: start.x + (q.x - start.x) * e, y: start.y + (q.y - start.y) * e + 4 * apex * e * (1 - e))
            if t >= 1 { return true }
        }
    }

    /// 쿵 착지: 납작했다가 펴진다
    private func land() async -> Bool {
        pet.setAnim(.idle)
        pet.stretch = 0.8
        pet.emit(FX.dust(at: CGPoint(x: -10, y: 0), facing: -1))
        pet.emit(FX.dust(at: CGPoint(x: 10, y: 0), facing: 1))
        guard await pause(0.14) else { return false }
        pet.stretch = 1
        return true
    }

    private func crouch() async -> Bool {
        pet.setAnim(.idle)
        pet.stretch = 0.82
        guard await pause(0.25) else { return false }
        pet.stretch = 1.06
        return true
    }

    private func ladder(_ leg: World.Leg) async -> Bool {
        let d = pet.displayScale
        let up = leg.rise > 0
        let bottom = min(leg.from, leg.to), top = max(leg.from, leg.to)
        let ladder = props.spawn(.ladder, at: CGPoint(x: leg.x, y: bottom - 3 * d), scale: propScale, length: top - bottom + 18 * d)
        say((up ? (L10n.isKorean ? ["영차영차", "사다리 등장!", "올라가 볼까"] : ["Heave-ho", "Ladder time!", "Let's climb up"])
                  : (L10n.isKorean ? ["조심조심…", "한 칸씩 내려가자", "높다…"] : ["Careful now…", "One step at a time", "So high…"])).randomElement()!, 1.8, chance: 0.7)
        guard await pause(0.45) else { ladder.dismiss(); return false }
        pet.motion = climbMotion(up: up, rope: false)
        guard await glide(to: CGPoint(x: leg.x, y: leg.to), speed: 30 * d, anim: .walk) else { ladder.dismiss(); return false }
        pet.motion = nil
        pet.setAnim(.idle)
        ladder.dismiss()
        return await pause(0.2)
    }

    private func ropeUp(_ leg: World.Leg) async -> Bool {
        let d = pet.displayScale
        let rope = props.spawn(.rope, at: CGPoint(x: leg.x, y: leg.from - 2 * d), scale: propScale, length: leg.rise + 40 * d)
        say((L10n.isKorean ? ["밧줄 타기!", "으쌰으쌰", "팔 힘 자랑"] : ["Rope climbing!", "Up we go", "Arm day!"]).randomElement()!, 1.6, chance: 0.7)
        guard await pause(0.4) else { rope.dismiss(); return false }
        pet.motion = climbMotion(up: true, rope: true)
        // 한 손씩 끌어올리기: 쭉 올라갔다 잠깐 쉬었다
        while pet.position.y < leg.to - 0.5 {
            let next = min(leg.to, pet.position.y + 10 * d)
            guard await glide(to: CGPoint(x: leg.x, y: next), speed: 60 * d, anim: .idle) else { rope.dismiss(); return false }
            guard await pause(0.12) else { rope.dismiss(); return false }
        }
        pet.motion = nil
        rope.dismiss()
        return await pause(0.15)
    }

    private func ropeDown(_ leg: World.Leg) async -> Bool {
        let d = pet.displayScale
        let rope = props.spawn(.rope, at: CGPoint(x: leg.x, y: leg.to - 2 * d), scale: propScale, length: -leg.rise + 40 * d)
        guard await pause(0.4) else { rope.dismiss(); return false }
        say((L10n.isKorean ? ["슝~", "미끄럼 타기!", "우와아~"] : ["Whoosh~", "Slide time!", "Wooah~"]).randomElement()!, 1.4, chance: 0.8)
        pet.motion = climbMotion(up: false, rope: true)
        guard await glide(to: CGPoint(x: leg.x, y: leg.to), speed: 85 * d, anim: .idle) else { rope.dismiss(); return false }
        pet.motion = nil
        rope.dismiss()
        return await land()
    }

    private func jump(_ leg: World.Leg) async -> Bool {
        let d = pet.displayScale
        let up = leg.rise > 0
        if up {
            say((L10n.isKorean ? ["점프!", "할 수 있어!", "얍!"] : ["Jump!", "I can do it!", "Hup!"]).randomElement()!, 1.2, chance: 0.6)
            guard await crouch() else { return false }
            guard await leap(to: CGPoint(x: leg.x, y: leg.to), apex: 18 * d, duration: 0.5) else { return false }
        } else {
            say((L10n.isKorean ? ["뛰어내린다!", "에잇!", "착지 준비~"] : ["Here I go!", "Hup!", "Brace for landing~"]).randomElement()!, 1.2, chance: 0.6)
            guard await crouch() else { return false }
            let duration = 0.35 + sqrt(Double(abs(leg.rise) / (400 * d))) * 0.5
            guard await leap(to: CGPoint(x: leg.x, y: leg.to), apex: 14 * d, duration: duration) else { return false }
        }
        return await land()
    }

    private func umbrella(_ leg: World.Leg) async -> Bool {
        let d = pet.displayScale
        let u = propScale
        pet.target = nil
        pet.setAnim(.idle)
        // 손잡이는 몸 뒤, 우산 천은 머리 위
        let stickX = pet.facing.sign * 4 * d
        let stickY = 26 * d
        let headTop = pet.headTopGlobal.y - pet.position.y
        let length = max(20 * d, headTop + 4 * d - stickY - 2 * u)
        let umbrella = props.spawn(.umbrella, at: CGPoint(x: pet.position.x + stickX, y: pet.position.y + stickY), scale: u, length: length)
        pet.motion = MotionSpec(base: "idle", leftArm: Wave(2.95), rightArm: Wave(0.5, amp: 0.25, freq: 1.1),
                                sway: Wave(0, amp: 2, freq: 0.7), eyes: .happy, mouth: .grin)
        say((L10n.isKorean ? ["둥실둥실~", "우산 낙하!", "메리 포핀스~"] : ["Floating down~", "Umbrella drop!", "Mary Poppins~"]).randomElement()!, 1.8, chance: 0.8)
        guard await pause(0.5) else { umbrella.dismiss(); return false }
        let x0 = leg.x
        let speed = 26 * d
        var t = 0.0
        while pet.position.y > leg.to + 0.5 {
            guard await pause(0.03) else { umbrella.dismiss(); return false }
            t += 0.03
            let y = max(leg.to, pet.position.y - speed * 0.03)
            let fade = min(1, (y - leg.to) / (20 * d))
            let x = x0 + CGFloat(sin(t * 2.1)) * 7 * d * fade
            pet.position = CGPoint(x: x, y: y)
            umbrella.position = CGPoint(x: x + stickX, y: y + stickY)
        }
        pet.position = CGPoint(x: x0, y: leg.to)
        umbrella.dismiss()
        pet.motion = nil
        say(L10n.t("휴~ 도착!"), 1.4, chance: 0.5)
        return await pause(0.3)
    }

    // MARK: - 친구 도움

    /// 친구가 위에서 밧줄을 내려 끌어올려 준다
    private func friendPull(_ leg: World.Leg, helper partner: Brain, inward: CGFloat) async -> Bool {
        let d = pet.displayScale
        let them = partner.pet
        partner.borrow()
        defer { partner.giveBack() }
        say((L10n.isKorean ? ["너무 높다… 도와줘~", "영차… 안 닿아!"] : ["Too high… help~", "Heave… can't reach!"]).randomElement()!, 1.8)
        partner.say((L10n.isKorean ? ["내가 끌어줄게!", "잡아!", "기다려~"] : ["I'll pull you up!", "Grab on!", "Hold on~"]).randomElement()!, 1.8)
        guard await partner.walk(to: CGPoint(x: leg.x + inward * 34 * d, y: leg.to), gait: .run) else { return false }
        them.facing = inward > 0 ? .left : .right
        let rope = props.spawn(.rope, at: CGPoint(x: leg.x, y: leg.from - 2 * d), scale: propScale, length: leg.rise + 34 * d)
        them.motion = MotionSpec(base: "idle", leftArm: Wave(1.3, amp: 0.25, freq: 1.4), rightArm: Wave(1.1, amp: 0.25, freq: 1.4, phase: 0.6),
                                 lean: Wave(0.1, amp: 0.1, freq: 1.4), eyes: .squeeze, mouth: .grin)
        guard await pause(0.5) else { rope.dismiss(); return false }
        pet.motion = climbMotion(up: true, rope: true)
        guard await glide(to: CGPoint(x: leg.x, y: leg.to), speed: 52 * d, anim: .idle) else { rope.dismiss(); return false }
        rope.dismiss()
        pet.motion = nil
        them.motion = nil
        pet.jump(height: 10)
        them.jump(height: 10)
        for _ in 0..<2 {
            pet.emit(FX.heart(at: headParticlePoint))
            them.emit(FX.heart(at: partner.headParticlePoint))
        }
        say((L10n.isKorean ? ["고마워!", "역시 최고야!"] : ["Thanks!", "You're the best!"]).randomElement()!, 1.6)
        return await pause(0.9)
    }

    /// 친구가 아래에서 받아 준다
    private func friendCatch(_ leg: World.Leg, helper partner: Brain, inward: CGFloat) async -> Bool {
        let d = pet.displayScale
        let them = partner.pet
        partner.borrow()
        defer { partner.giveBack() }
        partner.say((L10n.isKorean ? ["뛰어! 받아줄게!", "여기야 여기!"] : ["Jump! I'll catch you!", "Here, here!"]).randomElement()!, 1.8)
        guard await partner.walk(to: CGPoint(x: leg.x + inward * 30 * d, y: leg.to), gait: .run) else { return false }
        them.facing = inward > 0 ? .left : .right
        them.motion = MotionSpec(base: "idle", leftArm: Wave(2.6, amp: 0.15, freq: 2), rightArm: Wave(2.6, amp: 0.15, freq: 2, phase: 1),
                                 bounce: Wave(0.5, amp: 1, freq: 2), eyes: .wide, mouth: .open)
        say((L10n.isKorean ? ["간다~!", "믿는다!"] : ["Here I go~!", "I trust you!"]).randomElement()!, 1.2)
        guard await crouch() else { return false }
        let duration = 0.4 + sqrt(Double(abs(leg.rise) / (400 * d))) * 0.5
        guard await leap(to: CGPoint(x: leg.x + inward * 12 * d, y: leg.to), apex: 16 * d, duration: duration) else { return false }
        guard await land() else { return false }
        them.motion = nil
        them.jump(height: 8)
        for _ in 0..<2 {
            pet.emit(FX.heart(at: headParticlePoint))
            them.emit(FX.heart(at: partner.headParticlePoint))
        }
        partner.say(L10n.t("잡았다!"), 1.4)
        say(L10n.t("고마워!"), 1.4)
        return await pause(0.9)
    }
}
