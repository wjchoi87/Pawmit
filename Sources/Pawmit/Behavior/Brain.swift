import AppKit
import PawmitCore

/// 펫의 자율 행동. 활동 하나하나를 async 스크립트로 쓰고(걷기 → 멈추기 → 먹기…),
/// hook 알림이 오면 `interrupt`로 지금 하던 걸 취소한다.
///
/// 활동 선택은 욕구(배고픔·기운·재미)에 따른 가중 랜덤이다. 가중치 룰렛은 eSheep(MIT, orta/esheep-macos)
/// `getNextAnimation`, 욕구 모델은 OpenPets virtual-pet(MIT), 상태 지속 시간은 vscode-pets(MIT)를 참고했다.
@MainActor
final class Brain {
    enum HomeReason { case user, tired }

    unowned let pet: PetActor
    let world: World
    let props: PropManager
    let doodles: DoodleLayer?
    var config: PawmitConfig
    var needs: Needs
    /// 펫 말풍선 (텍스트, 표시 시간)
    var speak: (String, TimeInterval) -> Void = { _, _ in }
    var onHomeChanged: (Bool) -> Void = { _ in }

    /// seed로 정해진 성격과 행동 번호 (같은 seed → 같은 행동 순서)
    var personality: Personality
    var behaviorSeed: UInt64
    var behaviorIndex: UInt64 = 0
    var lastPlan: BehaviorPlan? {
        didSet { if let a = lastPlan?.archetype { planHistory.append(a); if planHistory.count > 200 { planHistory.removeFirst() } } }
    }
    /// 최근 실행한 행동 종류 (성격대로 노는지 확인용)
    var planHistory: [String] = []
    /// 같이 놀 수 있는 다른 펫들
    var partners: () -> [Brain] = { [] }
    /// 다른 펫이 같이 놀자고 데려간 상태 (자기 루프는 쉰다)
    private(set) var borrowed = false
    var agentBusy: () -> Bool = { false }
    var _sluggish: Double = 0

    private var loopTask: Task<Void, Never>?
    private(set) var isHome = false
    private var homeReason: HomeReason = .tired
    private var homeSince = Date()
    private var holdCount = 0
    var lastActivity = ""
    private var lastNeedsTick = Date()
    /// true면 매 프레임 시선을 커서로
    var eyesFollowCursor = true

    init(pet: PetActor, world: World, props: PropManager, doodles: DoodleLayer?, config: PawmitConfig, needs: Needs, seed: UInt64) {
        self.pet = pet
        self.world = world
        self.props = props
        self.doodles = doodles
        self.config = config
        self.needs = needs
        self.behaviorSeed = seed
        self.personality = Personality.make(seed: seed, species: pet.identity.id)
    }

    /// 명령·hook 반응 같은 끼어든 스크립트를 실행 중인지 (이때는 친구가 데려가지 못한다)
    private(set) var scripted = false

    /// 모니터 건너기 횟수 (건너는 방법을 고르는 seed)
    var crossings: UInt64 = 0
    /// 디버그: 다음 건너기 방법 지정 (ladder, rope, jump, umbrella, friendPull, friendCatch)
    var forcedClimb: String?
    /// 마지막으로 오르내린 방법
    var lastCrossing = ""
    /// 말투 스타일 (말끝·이모지·수다 정도)
    var speech: SpeechStyle?

    /// 놀이 상대로 데려갈 수 있는지
    var isAvailable: Bool { !borrowed && !scripted && !isHeld && !isHome && !pet.dragging && !pet.isHidden }

    func borrow() {
        #if DEBUG
        Log.info("borrow \(pet.identity.id)")
        #endif
        borrowed = true
        loopTask?.cancel()
        cleanupActivity()
        loopTask = nil
    }

    func giveBack() {
        guard borrowed else { return }
        borrowed = false
        pet.motion = nil
        start()
    }

    var isHeld: Bool { holdCount > 0 }

    // MARK: - 루프 제어

    func start() {
        scripted = false
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in await self?.loop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 지금 하던 활동을 멈추고 script를 실행한 뒤 다시 자율 행동으로 돌아간다
    func interrupt(_ script: @escaping @MainActor () async -> Void, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        Log.info("interrupt \(pet.identity.id) from \(file):\(line)")
        #endif
        loopTask?.cancel()
        cleanupActivity()
        scripted = true
        loopTask = Task { @MainActor [weak self] in
            await script()
            guard !Task.isCancelled else { return }
            self?.scripted = false
            await self?.loop()
        }
    }

    /// hook 요청 처리 중: 펫이 앉아서 기다린다
    func hold() {
        holdCount += 1
        guard holdCount == 1 else { return }
        interrupt { [weak self] in
            guard let self else { return }
            if self.isHome { await self.comeOut() }
            self.pet.target = nil
            self.pet.setAnim(.alert)
            self.pet.jump(height: 12)
            self.pet.emit(FX.exclaim(at: self.headParticlePoint))
            _ = await self.pause(0.9)
        }
    }

    func release(reaction: PetAnim? = nil) {
        holdCount = max(0, holdCount - 1)
        guard holdCount == 0 else { return }
        interrupt { [weak self] in
            guard let self, let reaction else { return }
            self.pet.setAnim(reaction)
            if reaction == .happy { self.pet.jump(height: 10); for _ in 0..<3 { self.pet.emit(FX.heart(at: self.headParticlePoint)) } }
            _ = await self.pause(1.4)
        }
    }

    /// 짧은 반응 (지금 활동을 끊지 않음)
    func react(_ anim: PetAnim, seconds: TimeInterval = 1.2, jump: CGFloat = 0) {
        guard !isHome else { return }
        interrupt { [weak self] in
            guard let self else { return }
            self.pet.target = nil
            self.pet.setAnim(anim)
            if jump > 0 { self.pet.jump(height: jump) }
            _ = await self.pause(seconds)
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            tickNeeds()
            if isHeld {
                pet.target = nil
                if pet.anim != .sit, pet.anim != .think, pet.anim != .alert { pet.setAnim(.sit) }
                if !(await pause(0.4)) { return }
                continue
            }
            if isHome {
                if !(await pause(1)) { return }
                let rested = needs.energy > 92 && Date().timeIntervalSince(homeSince) > 120
                if homeReason == .tired, rested { await comeOut() }
                continue
            }
            let plan = nextPlan()
            lastPlan = plan
            lastActivity = plan.archetype
            let finished = await execute(plan)
            // 취소된 경우 정리는 interrupt()가 이미 했다. 여기서 또 건드리면 새 스크립트의 상태를 덮어쓴다.
            if Task.isCancelled || !finished { return }
            cleanupActivity()
            pet.setAnim(.idle)
            if !(await pause(.random(in: 1.5...4.5))) { return }
        }
    }

    func cleanupActivity() {
        pet.target = nil
        pet.crayon = nil
        pet.motion = nil
        pet.stretch = 1
        doodles?.end()
        if pet.anim == .walk || pet.anim == .run || pet.anim == .draw || pet.anim == .dig { pet.setAnim(.idle) }
    }

    // MARK: - 욕구

    func tickNeeds() {
        let now = Date()
        let minutes = now.timeIntervalSince(lastNeedsTick) / 60
        guard minutes > 0.05 else { return }
        lastNeedsTick = now
        needs.decay(minutes: minutes, sleeping: pet.anim == .sleep, home: isHome)
    }

    func run(_ activity: String) async -> Bool {
        switch activity {
        case "dance": return await danceShow()
        case "clean": return await clean(group: nil, maxGroups: 12)
        case "friends": return await playWithFriend(nil, variant: UInt64.random(in: 0...UInt64.max))
        case "wander": return await wander()
        case "sit": return await sitAround()
        case "groom": return await groom()
        case "play": return await playBall(thrownFrom: nil)
        case "chase": return await chaseCursor()
        case "doodle": return await doodle(variant: UInt64.random(in: 0...UInt64.max))
        case "trash": return await rummageTrash()
        case "nap": return await nap()
        case "eat": return await eat(fromUser: false)
        case "home": return await goHome(reason: .tired)
        default: return await wander()
        }
    }

    // MARK: - 기본 동작

    /// 취소되면 false
    func pause(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }

    /// 메모리 부하만큼 느려짐 (0...1, 시스템 상태 반영이 켜져 있을 때만)
    var sluggish: Double {
        get { _sluggish }
        set { _sluggish = newValue }
    }

    var speedFactor: Double { 1 - 0.5 * sluggish }

    var baseSpeed: CGFloat { CGFloat(config.speed) * 58 * sqrt(pet.displayScale / 1.65) * CGFloat(speedFactor) }

    /// 목적지가 다른 모니터면 맞닿은 변을 따라 건너간다(travel). 높이 차이는 사다리·밧줄·점프·우산·친구 도움으로 오르내린다.
    func walk(to p: CGPoint, run: Bool = false, anim: PetAnim? = nil) async -> Bool {
        guard await travel(toward: p, run: run) else { return false }
        return await walkDirect(to: p, run: run, anim: anim)
    }

    /// 화면 경계를 따지지 않고 직선으로 걷기
    func walkDirect(to p: CGPoint, run: Bool = false, anim: PetAnim? = nil) async -> Bool {
        pet.moveSpeed = baseSpeed * (run ? 2.6 : 1)
        pet.target = p
        pet.setAnim(anim ?? (run ? .run : .walk))
        var waited: TimeInterval = 0
        while pet.target != nil {
            if !(await pause(0.03)) { return false }
            waited += 0.03
            if waited > 60 { pet.target = nil; break }
        }
        pet.setAnim(.idle)
        return true
    }

    func act(_ anim: PetAnim, _ seconds: TimeInterval) async -> Bool {
        pet.setAnim(anim)
        return await pause(seconds)
    }

    var headParticlePoint: CGPoint {
        let h = pet.headLocal
        let sx: CGFloat = (pet.facing == .left && !pet.renderer.handlesFacing) ? -1 : 1
        return CGPoint(x: h.x * sx * pet.displayScale, y: (h.y - 6) * pet.displayScale)
    }

    /// 스타일 말투가 있으면 말끝·이모지를 반영하고, 혼잣말(chance < 1) 빈도는 수다 정도(chattiness)로 조절한다.
    func say(_ line: String, _ seconds: TimeInterval = 2.6, chance: Double = 1) {
        var p = chance
        if chance < 1, let c = speech?.chattiness { p = min(1, chance * (0.2 + 1.6 * c)) }
        guard Double.random(in: 0...1) <= p else { return }
        let named = config.addressingUser(line)
        let text = speech?.apply(to: named, roll: .random(in: 0...1)) ?? named
        let prefix = pet.identity.interjection.isEmpty || Bool.random() ? "" : pet.identity.interjection + " "
        speak(prefix + text, seconds)
    }

    /// 스타일 적용: 성격은 seed 성격 위에 직접 정한 항목만 덮고, 말투는 say에서 쓴다
    func applyStyle(_ style: PetStyle) {
        personality = Personality.make(seed: behaviorSeed, species: pet.identity.id).overridden(by: style.personality)
        speech = style.speech
    }

    // MARK: - 활동

    func wander() async -> Bool {
        let dest = world.randomPoint(near: pet.position)
        let far = hypot(dest.x - pet.position.x, dest.y - pet.position.y) > 380
        guard await walk(to: dest, run: far && Double.random(in: 0...1) < 0.4) else { return false }
        if Double.random(in: 0...1) < 0.3 {
            say((L10n.isKorean ? ["흥얼흥얼~", "오늘 날씨 어때?", "산책 최고!", "여기 좋다", "어디 보자~"]
                               : ["Humming~", "How's the weather?", "Walks are the best!", "Nice spot here", "Let's see~"]).randomElement()!, chance: 0.5)
        }
        return await act(.idle, .random(in: 1...2.5))
    }

    func sitAround() async -> Bool {
        pet.setAnim(.sit)
        if Double.random(in: 0...1) < 0.25 {
            let lines = needs.hunger > 60 ? (L10n.isKorean ? ["배고파…", "밥 줘~", "꼬르륵"] : ["Hungry…", "Food please~", "Grrumble"]) :
                needs.energy < 30 ? (L10n.isKorean ? ["졸려…", "하암~"] : ["Sleepy…", "Yawn~"]) :
                (L10n.isKorean ? ["뭐 하고 있어?", "같이 놀자!", "물 마셨어?", "스트레칭 한 번 해!", "히히", "열일 중이구나", "심심해~"]
                               : ["Whatcha doing?", "Let's play!", "Did you drink water?", "Time to stretch!", "Hehe", "Working hard", "Bored~"])
            say(lines.randomElement()!)
        }
        let total = Double.random(in: 4...9)
        var t = 0.0
        while t < total {
            if !(await pause(0.5)) { return false }
            t += 0.5
            if Double.random(in: 0...1) < 0.04 { pet.setAnim(.think) }
            if pet.anim == .think, Double.random(in: 0...1) < 0.2 { pet.setAnim(.sit) }
        }
        return true
    }

    func groom() async -> Bool {
        pet.setAnim(.sit)
        guard await pause(0.6) else { return false }
        return await act(.groom, .random(in: 2.5...4))
    }

    func nap() async -> Bool {
        pet.setAnim(.sit)
        say(L10n.t("하암~ 잠깐 잘게"), 2, chance: 0.6)
        guard await pause(1.2) else { return false }
        pet.setAnim(.sleep)
        let duration = Double.random(in: 25...60)
        var t = 0.0
        while t < duration {
            if !(await pause(1)) { return false }
            t += 1
            needs.energy = min(100, needs.energy + 0.5)
        }
        pet.setAnim(.sit)
        pet.jump(height: 6)
        return await pause(0.8)
    }

    func eat(fromUser: Bool) async -> Bool {
        let screen = world.screen(containing: pet.position)
        let side: CGFloat = pet.facing.sign
        let bowlPos = world.clamp(CGPoint(x: pet.position.x + side * .random(in: 70...160), y: pet.position.y + .random(in: -40...40)), to: screen)
        let bowl = props.spawn(.bowl, at: bowlPos, scale: pet.displayScale / 1.65)
        defer { bowl.dismiss() }
        if fromUser { say(L10n.t("밥이다!!"), 1.6) } else { say(L10n.t("밥 먹을 시간~"), 1.8, chance: 0.6) }
        guard await pause(0.4) else { return false }
        let stand = CGPoint(x: bowlPos.x - (bowlPos.x > pet.position.x ? 1 : -1) * 30 * pet.displayScale / 1.65, y: bowlPos.y + 2)
        guard await walk(to: stand, run: fromUser) else { return false }
        pet.face(toward: bowlPos.x)
        for _ in 0..<3 {
            guard await act(.eat, 1.7) else { return false }
            bowl.food = max(0, bowl.food - 1)
            needs.hunger = max(0, needs.hunger - 25)
        }
        needs.fun = min(100, needs.fun + 5)
        pet.setAnim(.happy)
        pet.jump(height: 8)
        say((L10n.isKorean ? ["잘 먹었습니다!", "냠냠 최고!", "배불러~"] : ["Thanks for the food!", "Yum yum!", "So full~"]).randomElement()!)
        return await pause(1.4)
    }

    func playBall(thrownFrom: CGPoint?) async -> Bool {
        let screen = world.screen(containing: pet.position)
        let bounds = world.roamRect(screen)
        let start = thrownFrom.map { world.clamp($0, to: screen) }
            ?? world.clamp(CGPoint(x: pet.position.x + pet.facing.sign * 90, y: pet.position.y + 10), to: screen)
        let ball = props.spawn(.ball, at: start, scale: pet.displayScale / 1.65)
        defer { ball.dismiss() }
        props.ballBounds = bounds
        if let thrownFrom {
            ball.velocity = CGVector(dx: (pet.position.x - thrownFrom.x) * 0.4 + .random(in: -80...80), dy: .random(in: -60...60))
            say(L10n.t("공이다!!"), 1.4)
        }
        for _ in 0..<Int.random(in: 3...5) {
            // 공 쫓아가기
            var chased = 0.0
            pet.moveSpeed = baseSpeed * 2.6
            pet.setAnim(.run)
            while chased < 8 {
                let side: CGFloat = ball.position.x > pet.position.x ? -1 : 1
                let spot = CGPoint(x: ball.position.x + side * 20 * pet.displayScale / 1.65, y: ball.position.y)
                if hypot(spot.x - pet.position.x, spot.y - pet.position.y) < 6 { break }
                pet.target = spot
                if pet.anim != .run { pet.setAnim(.run) }
                guard await pause(0.04) else { return false }
                chased += 0.04
            }
            pet.target = nil
            pet.face(toward: ball.position.x)
            // 웅크렸다가 툭
            guard await act(.pounce, 0.35) else { return false }
            pet.jump(height: 10)
            let dir: CGFloat = ball.position.x >= pet.position.x ? 1 : -1
            ball.velocity = CGVector(dx: dir * .random(in: 180...320), dy: .random(in: -120...120))
            guard await pause(0.55) else { return false }
            needs.fun = min(100, needs.fun + 8)
            needs.energy = max(0, needs.energy - 2)
        }
        pet.setAnim(.happy)
        pet.jump(height: 8)
        say((L10n.isKorean ? ["재밌다!", "한 번 더!", "잡았다!"] : ["Fun!", "One more time!", "Got it!"]).randomElement()!, chance: 0.7)
        return await pause(1.2)
    }

    func chaseCursor() async -> Bool {
        say((L10n.isKorean ? ["거기 서!", "잡을 거야~", "커서다!"] : ["Stop right there!", "I'll catch you~", "The cursor!"]).randomElement()!, 1.6, chance: 0.7)
        let duration = Double.random(in: 5...9)
        var t = 0.0
        while t < duration {
            let screen = world.screen(containing: pet.position)
            let mouse = NSEvent.mouseLocation
            // 다른 화면이면 포기
            guard world.screen(containing: mouse) == screen else { break }
            let goal = world.clamp(CGPoint(x: mouse.x, y: mouse.y - 40 * pet.displayScale / 1.65), to: screen)
            let dist = hypot(goal.x - pet.position.x, goal.y - pet.position.y)
            if dist < 26 {
                pet.target = nil
                pet.face(toward: mouse.x)
                if pet.anim != .play { pet.setAnim(.play) }
            } else {
                pet.moveSpeed = baseSpeed * (dist > 140 ? 2.6 : 1.4)
                pet.target = goal
                let wanted: PetAnim = dist > 140 ? .run : .walk
                if pet.anim != wanted { pet.setAnim(wanted) }
            }
            guard await pause(0.05) else { return false }
            t += 0.05
        }
        pet.target = nil
        needs.fun = min(100, needs.fun + 15)
        return await act(.happy, 1)
    }

    static var trashFinds: [String] {
        L10n.isKorean
            ? ["양말 한 짝 🧦", "생선뼈 🐟", "바나나 껍질 🍌", "구겨진 기획서 📄", "어제 지운 코드 💾", "빈 커피컵 ☕️", "버그 세 마리 🐛", "반짝이는 병뚜껑 ✨"]
            : ["a lone sock 🧦", "fish bone 🐟", "banana peel 🍌", "a crumpled spec 📄", "yesterday's deleted code 💾", "empty coffee cup ☕️", "three bugs 🐛", "shiny bottle cap ✨"]
    }

    func rummageTrash() async -> Bool {
        let spot = world.trashSpot(near: pet.position)
        var can: PropWindow?
        if !spot.dock {
            can = props.spawn(.trashCan, at: world.fallbackTrashCan(for: spot.foot), scale: pet.displayScale / 1.65)
        }
        defer { can?.dismiss() }
        let far = hypot(spot.foot.x - pet.position.x, spot.foot.y - pet.position.y) > 500
        guard await walk(to: spot.foot, run: far) else { return false }
        pet.facing = spot.facing
        say(L10n.t("뭐 있나~"), 1.6, chance: 0.7)
        guard await act(.dig, .random(in: 3...4.5)) else { return false }
        let found = Brain.trashFinds.randomElement()!
        pet.setAnim(.happy)
        pet.jump(height: 9)
        pet.emit(FX.sparkle(at: headParticlePoint))
        speak(L10n.format("찾았다! %@", found), 3)
        needs.fun = min(100, needs.fun + 18)
        guard await pause(1.6) else { return false }
        // 휴지통에서 조금 떨어지기
        return await walk(to: world.randomPoint(near: pet.position, min: 80, max: 180))
    }

    static let crayons: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.36, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.30, green: 0.62, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.72, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.36, green: 0.78, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.47, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.98, green: 0.55, blue: 0.30, alpha: 1),
    ]

    /// 낙서 물감 팔레트 — 그림 도안(명화·풍경·만화)의 색 번호는 이 순서를 뜻한다.
    static let palettes: [[NSColor]] = [
        crayons,                                                          // 크레용(기본)
        [NSColor(srgbRed: 0.99, green: 0.72, blue: 0.76, alpha: 1), NSColor(srgbRed: 0.66, green: 0.83, blue: 0.99, alpha: 1),
         NSColor(srgbRed: 0.99, green: 0.92, blue: 0.61, alpha: 1), NSColor(srgbRed: 0.70, green: 0.92, blue: 0.77, alpha: 1),
         NSColor(srgbRed: 0.83, green: 0.74, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.99, green: 0.80, blue: 0.66, alpha: 1)],   // 파스텔
        [NSColor(srgbRed: 0.85, green: 0.13, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.10, green: 0.23, blue: 0.55, alpha: 1),
         NSColor(srgbRed: 0.98, green: 0.75, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.14, green: 0.42, blue: 0.24, alpha: 1),
         NSColor(srgbRed: 0.35, green: 0.20, blue: 0.50, alpha: 1), NSColor(srgbRed: 0.55, green: 0.35, blue: 0.14, alpha: 1)],   // 유화(짙음)
        [NSColor(srgbRed: 0.55, green: 0.35, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.24, green: 0.30, blue: 0.55, alpha: 1),
         NSColor(srgbRed: 0.95, green: 0.79, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.35, green: 0.42, blue: 0.38, alpha: 1),
         NSColor(srgbRed: 0.45, green: 0.32, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.40, green: 0.44, blue: 0.62, alpha: 1)],   // 밤
        [NSColor(calibratedWhite: 0.12, alpha: 1), NSColor(calibratedWhite: 0.35, alpha: 1), NSColor(calibratedWhite: 0.6, alpha: 1),
         NSColor(calibratedWhite: 0.8, alpha: 1), NSColor(calibratedWhite: 0.95, alpha: 1), NSColor(calibratedWhite: 0.22, alpha: 1)], // 잉크(모노)
    ]

    func doodle(variant: UInt64) async -> Bool {
        guard let doodles else { return true }
        let screen = world.screen(containing: pet.position)
        var vr = SplitMix64(seed: variant)
        let art = DoodleGenerator.generate(seed: variant)
        let palette = vr.pick(Brain.palettes)
        let size = CGFloat(vr.range(42, 78)) * pet.displayScale / 1.65
        let margin = size * 1.6
        let r = world.roamRect(screen).insetBy(dx: margin, dy: margin * 0.8)
        guard r.width > 40, r.height > 30 else { return true }
        let center = CGPoint(x: min(max(pet.position.x + CGFloat(vr.range(-160, 160)), r.minX), r.maxX),
                             y: min(max(pet.position.y + CGFloat(vr.range(-80, 140)), r.minY), r.maxY))
        let paletteShift = vr.int(0, palette.count - 1)
        say(vr.pick(L10n.isKorean ? ["낙서해야지~", "뭐 그리지?", "명작 탄생 예정", "크레용 어디 있지", "이번엔 그림이다!", "화가 모드!", "풍경이 좋겠어"]
                                  : ["Time to doodle~", "What to draw?", "A masterpiece incoming", "Where are my crayons", "A picture this time!", "Painter mode!", "A landscape sounds nice"]), 1.6, chance: 0.6)

        // 길이에 맞춰 펜 속도를 정해 한 그림이 대략 6~14초 안에 끝나게
        let length = art.totalLength * size
        let penSpeed = max(baseSpeed * 0.8, min(baseSpeed * 3.2, length / 10))
        let group = UUID().uuidString
        let generation = doodles.generation
        for stroke in art.strokes {
            // 그리는 도중 "모두 지우기"를 하면 남은 획은 그리지 않고 그만둔다
            guard doodles.generation == generation else { pet.crayon = nil; return true }
            let pts = Brain.resample(stroke.points.map { CGPoint(x: center.x + $0.x * size, y: center.y + $0.y * size) }, spacing: 5)
            guard let first = pts.first else { continue }
            pet.crayon = nil
            guard await walk(to: first) else { return false }
            let color = palette[(paletteShift + stroke.color) % palette.count]
            pet.crayon = color.cgColor
            doodles.begin(color: color, width: 5.5 * CGFloat(stroke.width), group: group)
            doodles.add(pet.position)
            pet.moveSpeed = penSpeed
            pet.setAnim(.draw)
            for p in pts.dropFirst() {
                pet.target = p
                while pet.target != nil {
                    guard await pause(0.02) else { doodles.end(); return false }
                    guard doodles.generation == generation else { pet.target = nil; pet.crayon = nil; return true }
                    doodles.add(pet.position)
                }
            }
            doodles.add(pet.position)
            doodles.end()
            // 채움 획이면 외곽선 안을 색으로 차오르게 한다
            if stroke.fill {
                let fc = palette[(paletteShift + stroke.color) % palette.count]
                doodles.fillShape(points: pts, color: fc, group: group)
                pet.setAnim(.happy)
                if await pause(0.18) == false { return false }
            }
        }
        pet.crayon = nil
        // 한 발 물러나서 감상
        let back = CGPoint(x: center.x + (pet.position.x >= center.x ? 1 : -1) * (size * 1.5 + 20), y: center.y - size * 0.5)
        guard await walk(to: world.clamp(back, to: screen)) else { return false }
        pet.face(toward: center.x)
        pet.setAnim(.happy)
        pet.jump(height: 8)
        say(L10n.format("%@ 완성!", L10n.t(art.name)), 2.4)
        needs.fun = min(100, needs.fun + 20)
        return await pause(1.5)
    }

    /// 펫이 따라 걷기 좋게 점 간격을 고르게
    static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out = [pts[0]]
        var carry: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            guard d > 0 else { continue }
            var t = spacing - carry
            while t < d {
                out.append(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                t += spacing
            }
            carry = d - (t - spacing)
        }
        if out.last != pts.last { out.append(pts[pts.count - 1]) }
        return out
    }

    func runActivity(_ name: String) async -> Bool { await run(name) }

    // MARK: - 집

    /// 애니메이션 없이 바로 집에 있는 상태로 (앱 시작 시 복원)
    func markHome() {
        isHome = true
        homeReason = .user
        homeSince = Date()
        pet.isHidden = true
        onHomeChanged(true)
    }

    func goHome(reason: HomeReason) async -> Bool {
        guard !isHome, let door = world.houseDoor(), let house = world.houseFrame() else { return true }
        homeReason = reason
        say(reason == .user ? L10n.t("응, 집에 갈게~") : L10n.t("졸려… 집에서 잘래"), 2)
        let far = hypot(door.x - pet.position.x, door.y - pet.position.y) > 350
        guard await walk(to: door, run: far) else { return false }
        pet.setAnim(.happy)
        pet.jump(height: 14)
        guard await pause(0.3) else { return false }
        // 메뉴바 집 안으로 쏙
        let from = pet.position
        let to = CGPoint(x: house.midX, y: house.midY - 6)
        let steps = 18
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let e = t * t
            pet.position = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            pet.visualScale = 1 - 0.75 * e
            pet.opacity = 1 - e
            guard await pause(0.022) else { pet.visualScale = 1; pet.opacity = 1; return false }
        }
        pet.isHidden = true
        pet.visualScale = 1
        pet.opacity = 1
        isHome = true
        homeSince = Date()
        onHomeChanged(true)
        return true
    }

    func comeOut() async {
        guard isHome else { return }
        isHome = false
        onHomeChanged(false)
        guard let house = world.houseFrame(), let door = world.houseDoor() else {
            pet.position = world.spawnPoint()
            pet.isHidden = false
            return
        }
        pet.position = CGPoint(x: house.midX, y: house.midY - 6)
        pet.visualScale = 0.25
        pet.opacity = 0
        pet.setAnim(.fall)
        pet.isHidden = false
        let landing = CGPoint(x: door.x, y: door.y - 60 * pet.displayScale / 1.65)
        let from = pet.position
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            pet.position = CGPoint(x: from.x + (landing.x - from.x) * t, y: from.y + (landing.y - from.y) * t * t)
            pet.visualScale = 0.25 + 0.75 * min(1, t * 1.6)
            pet.opacity = min(1, t * 2)
            if !(await pause(0.02)) { break }
        }
        pet.visualScale = 1
        pet.opacity = 1
        pet.stretch = 0.82
        pet.setAnim(.wave)
        _ = await pause(0.12)
        pet.stretch = 1
        say((L10n.isKorean ? ["나왔다!", "다녀왔어~", "짠!"] : ["I'm out!", "I'm back~", "Ta-da!"]).randomElement()!, 1.8)
        _ = await pause(1.2)
    }
}
