import AppKit
import PawmitCore

/// 청소(낙서 닦기)와 시스템 상태 알려주기
@MainActor
extension Brain {
    // MARK: - 청소

    /// 낙서를 물걸레로 닦는다. group이 nil이면 오래된 그림부터 maxGroups개.
    func clean(group target: String?, maxGroups: Int) async -> Bool {
        guard let doodles else { return true }
        let groups = target.map { [$0] } ?? Array(doodles.groupIDs.prefix(maxGroups))
        Log.info("clean start groups=\(groups.count) strokes=\(groups.map { doodles.strokes(inGroup: $0).count })")
        guard !groups.isEmpty else {
            say(L10n.t("이미 깨끗해! ✨"), 1.8)
            return true
        }
        var r = SplitMix64(seed: UInt64.random(in: 0...UInt64.max))
        say(r.pick(L10n.isKorean ? ["더러워! 청소하자 🧽", "어휴, 닦아야겠다", "물걸레 출동!", "깨끗하게 해줄게~"]
                                : ["So dirty! Time to clean 🧽", "Whew, needs a wipe", "Mop deploy!", "I'll make it sparkly~"]), 2)
        let screen = world.screen(containing: pet.position)
        let k = pet.displayScale / 1.65
        let bucketPos = world.clamp(CGPoint(x: pet.position.x + pet.facing.sign * 60 * k, y: pet.position.y), to: screen)
        let bucket = props.spawn(.bucket, at: bucketPos, scale: k)
        defer {
            bucket.dismiss()
            pet.mop = false
        }
        guard await pause(0.4) else { return false }
        // 양동이에 걸레 적시기
        guard await walk(to: CGPoint(x: bucketPos.x - pet.facing.sign * 26 * k, y: bucketPos.y)) else { return false }
        pet.face(toward: bucketPos.x)
        pet.setAnim(.dig)
        for _ in 0..<4 {
            pet.emit(Particle(text: "💧", pos: CGPoint(x: pet.facing.sign * 20 * k, y: 10), vel: CGVector(dx: .random(in: -14...14), dy: .random(in: 30...50)),
                              gravity: 90, maxLife: 0.9, size: 11))
            guard await pause(0.25) else { return false }
        }
        pet.mop = true
        let radius = 11 * k
        for g in groups {
            let strokes = doodles.strokes(inGroup: g)
            for stroke in strokes {
                let pts = Brain.resample(stroke.points, spacing: 7)
                guard let first = pts.first else { continue }
                pet.mop = false
                guard await walk(to: first) else { Log.info("clean cancelled while walking to stroke"); return false }
                pet.mop = true
                pet.moveSpeed = baseSpeed * 1.6
                pet.setAnim(.draw)
                var step = 0
                for p in pts.dropFirst() {
                    pet.target = p
                    while pet.target != nil {
                        guard await pause(0.03) else { return false }
                        doodles.erase(around: pet.position, radius: radius)
                    }
                    step += 1
                    if step % 9 == 0 {
                        pet.emit(Particle(text: r.pick(["💧", "🫧", "✨"]), pos: CGPoint(x: 0, y: 6), vel: CGVector(dx: .random(in: -16...16), dy: .random(in: 14...30)),
                                          maxLife: 1.0, size: 10))
                    }
                }
            }
            // 놓친 조각까지 마저 지우고 반짝
            Log.info("clean group done \(g.prefix(6))")
            doodles.removeGroup(g)
            pet.emit(FX.sparkle(at: headParticlePoint))
            pet.emit(FX.sparkle(at: headParticlePoint))
        }
        pet.mop = false
        pet.setAnim(.happy)
        pet.jump(height: 9)
        say(r.pick(L10n.isKorean ? ["반짝반짝! ✨", "깨끗해졌다!", "청소 끝~ 상쾌해"] : ["Sparkly! ✨", "All clean!", "Done~ so fresh"]), 2.2)
        needs.fun = min(100, needs.fun + 8)
        return await pause(1.3)
    }

    // MARK: - 시스템 상태 알려주기

    /// 온도계로 CPU(기온 ℃), 걸음으로 메모리 여유(시속 km/h), 체중계로 디스크 사용량(몸무게 GB)을 보여준다
    func reportStatus(_ s: SystemMonitor.Snapshot, temperature: Int, speedKmh: Int, weight: String) async -> Bool {
        let screen = world.screen(containing: pet.position)
        let k = pet.displayScale / 1.65
        var r = SplitMix64(seed: UInt64.random(in: 0...UInt64.max))

        // 1) 온도계 = 기온
        let tPos = world.clamp(CGPoint(x: pet.position.x + pet.facing.sign * 48 * k, y: pet.position.y), to: screen)
        let thermo = props.spawn(.thermometer, at: tPos, scale: k)
        thermo.level = 0
        thermo.readout = "…"
        defer { thermo.dismiss() }
        pet.face(toward: tPos.x)
        pet.setAnim(.think)
        say(L10n.t("지금 기온이 얼마지? 🌡️"), 1.8)
        guard await pause(0.6) else { return false }
        for i in 1...12 {
            thermo.level = s.cpu * Double(i) / 12
            guard await pause(0.06) else { return false }
        }
        thermo.readout = "\(temperature)℃"
        if temperature >= 34 {
            say(L10n.format("%lld℃!! 너무 더워 🥵", temperature), 3)
            let fan = MotionSpec(base: "idle", leftArm: Wave(0.3), rightArm: Wave(3.35, amp: 0.3, freq: 2.2), squash: Wave(0.97), eyes: .squeeze, mouth: .tongue)
            guard await performAct(ActSpec(act: .shiver, motion: fan, seconds: 2.4, emote: .sweat, emoteEvery: 0.5)) else { return false }
        } else if temperature <= 21 {
            say(L10n.format("%lld℃, 선선하다~", temperature), 3)
            guard await performAct(ActRecipes.make(r.pick([.stretch, .nod]), rng: &r)) else { return false }
        } else {
            say(L10n.format("%lld℃, 딱 좋아!", temperature), 3)
            guard await performAct(ActRecipes.make(r.pick([.nod, .wave, .giggle]), rng: &r)) else { return false }
        }
        thermo.dismiss()

        // 2) 시속 = 메모리 여유
        if speedKmh < 10 {
            say(L10n.format("지금 내 속도는 시속 %lldkm… 몸이 무거워", speedKmh), 3)
        } else if speedKmh > 20 {
            say(L10n.format("지금 시속 %lldkm! 쌩쌩 달릴 수 있어 💨", speedKmh), 3)
        } else {
            say(L10n.format("지금 내 속도는 시속 %lldkm야", speedKmh), 3)
        }
        let gait: Gait = speedKmh < 8 ? .wobble : (speedKmh < 16 ? .walk : (speedKmh < 24 ? .skip : .run))
        let a = pet.position
        let b = world.clamp(CGPoint(x: a.x - pet.facing.sign * 120 * k, y: a.y), to: screen)
        guard await walk(to: b, gait: gait), await walk(to: a, gait: gait) else { return false }
        pet.motion = nil

        // 3) 체중계 = 디스크 사용량
        let sPos = world.clamp(CGPoint(x: pet.position.x + pet.facing.sign * 74 * k, y: pet.position.y), to: screen)
        let scale = props.spawn(.scale, at: sPos, scale: k)
        scale.level = 0
        scale.readout = "0GB"
        defer { scale.dismiss() }
        guard await pause(0.4) else { return false }
        say(L10n.t("몸무게 재볼까? ⚖️"), 1.6)
        guard await walk(to: CGPoint(x: sPos.x, y: sPos.y + 6 * k)) else { return false }
        pet.jump(height: 5)
        pet.setAnim(.idle)
        guard await pause(0.3) else { return false }
        for i in 1...16 {
            let f = Double(i) / 16
            scale.level = s.disk * f
            let gb = s.diskUsedGB * f
            scale.readout = gb >= 1000 ? String(format: "%.1fTB", gb / 1000) : "\(Int(gb.rounded()))GB"
            guard await pause(0.07) else { return false }
        }
        scale.readout = weight
        if s.disk >= 0.85 {
            say(L10n.format("몸무게 %@… 헉, 다이어트해야겠다 😵", weight), 3.4)
            guard await performAct(ActRecipes.make(.sulk, rng: &r)) else { return false }
        } else if s.disk < 0.5 {
            say(L10n.format("몸무게 %@! 날씬하다 ✨", weight), 3)
            guard await performAct(ActRecipes.make(.cheer, rng: &r)) else { return false }
        } else {
            say(L10n.format("몸무게 %@, 적당해~", weight), 3)
            guard await performAct(ActRecipes.make(.nod, rng: &r)) else { return false }
        }
        // 내려오기
        pet.jump(height: 6)
        return await walk(to: world.clamp(CGPoint(x: sPos.x - pet.facing.sign * 50 * k, y: sPos.y), to: screen))
    }
}
