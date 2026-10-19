import AppKit
import SwiftUI
import ServiceManagement
import PawmitCore

/// 앱 전체를 잇는 감독: 펫·행동·월드·hook 대기열·말풍선·메뉴바.
@MainActor
final class Director: NSObject, NSMenuDelegate {
    private(set) var config: PawmitConfig
    private var state: PetState
    private let world: World
    private let props = PropManager()
    private var doodles: DoodleLayer?
    private let hub: AgentHub
    private let chat: ChatService
    private let chatModel = ChatModel()
    /// 자동 업데이트 (설정 updateURL: GitHub 저장소 주소 또는 update.json)
    private lazy var updater = Updater(config: config)
    /// 개발용 updatecheck 결과
    private var updateCheckResult = "-"

    private var pet: PetActor!
    private var brain: Brain!
    private var friends: [(actor: PetActor, brain: Brain)] = []

    private let card = BubbleController(interactive: true)
    private let speech = BubbleController(interactive: false)
    private var cardPendingID: String?
    private var chatOpen = false
    private var lastDecision: HookReply.Decision?

    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?
    private var slowTimer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSpeech = Date.distantPast
    private var lastSessionNotice: [String: Date] = [:]
    private var configMTime: Date?
    private var noticeToken: UUID?
    private let monitor = SystemMonitor()
    private var lastSample: TimeInterval = 0
    private var nextStatusReport = Date().addingTimeInterval(20 * 60)

    init(config: PawmitConfig) {
        self.config = config
        self.state = PetState.load()
        self.world = World(config: config)
        self.hub = AgentHub(config: config)
        self.chat = ChatService(config: config, sessionID: state.chatSessionID)
        super.init()
    }

    // MARK: - 시작

    func start() {
        applyTextStyle()
        scheduleAutoUpdateCheck()
        setupStatusItem()
        world.houseFrame = { [weak self] in
            guard let w = self?.statusItem.button?.window else { return nil }
            return w.frame
        }
        doodles = DoodleLayer(config: config)
        doodles?.onEraseGroup = { [weak self] g in
            self?.doodles?.removeGroup(g)
            self?.brain.react(.happy, seconds: 1)
        }
        doodles?.onAskPetToClean = { [weak self] g in
            guard let self else { return }
            self.brain.interrupt { [weak self] in
                guard let b = self?.brain else { return }
                if b.isHome { await b.comeOut() }
                _ = await b.clean(group: g, maxGroups: 1)
            }
        }
        doodles?.onEraseAll = { [weak self] in self?.clearAllDoodles() }
        spawnMainPet()
        spawnFriends()
        monitor.sample()
        applyPerformance()
        applySystemState()
        scheduleNextStatusReport()

        hub.onPendingAdded = { [weak self] p in self?.pendingAdded(p) }
        hub.onPendingRemoved = { [weak self] p, reason in self?.pendingRemoved(p, reason) }
        hub.onEvent = { [weak self] e, env in self?.agentEvent(e, env) }
        hub.onChange = { [weak self] in self?.refreshStatusItem() }
        hub.onDebug = { [weak self] cmd, arg in self?.debug(cmd, arg) ?? "{}" }
        do {
            try hub.start()
        } catch {
            Log.info("socket 시작 실패: \(error)")
            speakNow(L10n.format("앗, 에이전트 연결 통로를 못 열었어… (%@)", error.localizedDescription), 6)
        }

        scheduleTick(fps: 30)
        let slow = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        RunLoop.main.add(slow, forMode: .common)
        slowTimer = slow
        configMTime = modificationDate(PawmitPaths.config)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        refreshStatusItem()
    }

    func shutdown() {
        saveState()
        hub.stop()
        tickTimer?.invalidate()
    }

    private func spawnMainPet() {
        let identity = PetRoster.make(id: config.pet, config: config)
        let scale = displayScale(for: identity)
        var start = world.spawnPoint()
        if let x = state.x, let y = state.y, NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(CGPoint(x: x, y: y)) }) {
            start = CGPoint(x: x, y: y)
        }
        pet = PetActor(identity: displayName(identity), isMain: true, displayScale: scale, position: start)
        brain = Brain(pet: pet, world: world, props: props, doodles: doodles, config: config, needs: state.needs,
                      seed: config.behaviorSeed ?? seed(for: identity.id))
        brain.applyStyle(PetStyles.effective(config.pet, config: config))
        brain.partners = { [weak self] in self?.friends.map(\.brain) ?? [] }
        brain.agentBusy = { [weak self] in !(self?.hub.workingSessions.isEmpty ?? true) }
        brain.speak = { [weak self] text, secs in self?.speakNow(text, secs) }
        brain.onHomeChanged = { [weak self] home in
            self?.state.isHome = home
            self?.refreshStatusItem()
        }
        wireInput(pet, brain: brain, main: true)
        card.anchor = { [weak self] in self?.pet.isHidden == false ? self?.pet.steadyHeadTopGlobal : self?.houseAnchor }
        card.lowAnchor = { [weak self] in self.map { CGPoint(x: $0.pet.position.x, y: $0.pet.position.y - 6) } }
        speech.anchor = card.anchor
        speech.lowAnchor = card.lowAnchor
        card.panel.onCancel = { [weak self] in self?.cancelCard() }
        if state.isHome {
            // 집에 있던 상태로 시작
            brain.markHome()
        }
        brain.start()
    }

    /// 펫별 행동 seed: 처음 한 번 무작위로 정하고 state.json에 저장한다
    private func seed(for id: String) -> UInt64 {
        if let s = state.seeds[id] { return s }
        let s = UInt64.random(in: 1...UInt64.max)
        state.seeds[id] = s
        state.save()
        return s
    }

    private func displayName(_ identity: PetIdentity) -> PetIdentity {
        var id = identity
        if let custom = config.petName, !custom.isEmpty { id.name = custom }
        return id
    }

    private func displayScale(for identity: PetIdentity) -> CGFloat {
        CGFloat(config.size) * 1.65 * identity.scale
    }

    private func spawnFriends() {
        for f in friends { f.brain.stop(); f.actor.close() }
        friends.removeAll()
        for id in config.friends.prefix(4) where id != config.pet {
            let identity = PetRoster.make(id: id, config: config)
            let p = world.randomPoint(near: pet.position, min: 80, max: 260)
            let actor = PetActor(identity: identity, isMain: false, displayScale: displayScale(for: identity) * 0.92, position: p)
            let b = Brain(pet: actor, world: world, props: props, doodles: doodles, config: config, needs: Needs(),
                          seed: seed(for: "friend:" + id))
            b.applyStyle(PetStyles.effective(id, config: config))
            b.partners = { [weak self, weak b] in
                guard let self else { return [] }
                return ([self.brain] + self.friends.map(\.brain)).filter { $0 !== b }
            }
            b.speak = { [weak self, weak actor] text, secs in
                guard let self, let actor else { return }
                // 친구 펫 말은 짧게 머리 위 파티클로
                let short = text.count > 16 ? String(text.prefix(15)) + "…" : text
                actor.emit(Particle(text: short, style: .label, pos: CGPoint(x: 0, y: actor.headLocal.y * actor.displayScale + 6), vel: CGVector(dx: 0, dy: 5),
                                    maxLife: min(max(secs, 1.8), 3), size: 11))
                _ = self
            }
            wireInput(actor, brain: b, main: false)
            friends.append((actor, b))
            b.start()
        }
        if tickTimer != nil {
            applyPerformance()
            applySystemState()
        }
    }

    private func wireInput(_ actor: PetActor, brain: Brain, main: Bool) {
        actor.onClick = { [weak self, weak actor, weak brain] in
            guard let self, let actor, let brain else { return }
            if main { self.petClicked() } else {
                brain.react(.wave, seconds: 1.2, jump: 6)
                actor.emit(FX.heart(at: CGPoint(x: 0, y: actor.headLocal.y * actor.displayScale)))
            }
        }
        actor.onDoubleClick = { [weak brain, weak actor] in
            guard let brain, let actor else { return }
            brain.needs.affection = min(100, brain.needs.affection + 6)
            brain.react(.happy, seconds: 1.3, jump: 12)
            for _ in 0..<4 { actor.emit(FX.heart(at: CGPoint(x: 0, y: actor.headLocal.y * actor.displayScale))) }
        }
        actor.onPetted = { [weak self, weak brain, weak actor] in
            guard let brain, let actor else { return }
            brain.needs.affection = min(100, brain.needs.affection + 8)
            for _ in 0..<3 { actor.emit(FX.heart(at: CGPoint(x: 0, y: actor.headLocal.y * actor.displayScale))) }
            if !brain.isHeld { brain.react(.happy, seconds: 1.1) }
            if main, Double.random(in: 0...1) < 0.4 {
                self?.speakNow((L10n.isKorean ? ["헤헤", "기분 좋아~", "더 쓰다듬어줘!", "골골골…"]
                                : ["Hehe", "Feels nice~", "More pets please!", "Purrr…"]).randomElement()!, 1.8)
            }
            self?.sound("Purr", volume: 0.25)
        }
        actor.onDragStart = { [weak brain] in
            brain?.interrupt { [weak brain] in
                guard let brain else { return }
                while brain.pet.dragging { if !(await brain.pause(0.05)) { return } }
            }
        }
        actor.onDragEnd = { [weak self, weak brain, weak actor] in
            guard let brain, let actor else { return }
            brain.interrupt {
                actor.setAnim(.fall)
                actor.jump(height: 4)
                _ = await brain.pause(0.3)
                actor.stretch = 0.85
                actor.setAnim(.sit)
                _ = await brain.pause(0.12)
                actor.stretch = 1
                _ = await brain.pause(0.6)
            }
            if main { self?.saveState() }
        }
        actor.onContextMenu = { [weak self, weak brain] event in
            guard let self, let brain else { return }
            let menu = NSMenu()
            self.buildPetActions(into: menu, for: brain)
            NSMenu.popUpContextMenu(menu, with: event, for: actor.window.contentView!)
        }
    }

    private var houseAnchor: CGPoint? {
        guard let f = world.houseFrame() else { return nil }
        return CGPoint(x: f.midX, y: f.minY - 4)
    }

    // MARK: - 프레임

    private var currentFPS: Double = 0
    private var lastFPSCheck: TimeInterval = 0
    /// 개발용 clipwatch: 펫 그림이 창 가장자리에 닿는(= 창에 잘리는) 순간 기록
    private var clipWatchUntil: TimeInterval = 0
    private var clipLastCheck: TimeInterval = 0
    private var clipLog: [JSONValue] = []

    /// 시스템 자원을 아끼려고 펫이 하는 일에 맞춰 갱신 속도를 바꾼다
    private func scheduleTick(fps: Double) {
        guard fps != currentFPS else { return }
        currentFPS = fps
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.25 / fps
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func desiredFPS() -> Double {
        let actors = [pet!] + friends.map(\.actor)
        let (active, idle) = fpsProfile
        if actors.contains(where: { $0.dragging }) { return max(active, 24) }
        if actors.contains(where: { $0.isAnimatingActively }) || props.isAnimating { return active }
        if actors.allSatisfy({ $0.isHidden }) { return 2 }
        if actors.allSatisfy({ $0.anim == .sleep || $0.isHidden }) { return max(2, idle / 2) }
        return idle
    }

    /// (움직일 때, 가만히 있을 때) 프레임 수
    private var fpsProfile: (Double, Double) {
        switch config.performance {
        case "smooth": return (24, 10)
        case "saver": return (10, 4)
        default: return (18, 8)
        }
    }

    /// 절전 모드면 펫 그림자·그늘 꾸밈도 끈다 (clip 래스터화 비용). 바뀌면 캐시된 몸 프레임을 비운다.
    private func applyPerformance() {
        let shading = config.performance != "saver"
        if Ink.shading != shading {
            Ink.shading = shading
            FrameCache.shared.clear()
        }
        let (active, idle) = fpsProfile
        for a in [pet!] + friends.map(\.actor) {
            a.activeFPS = active
            a.idleFPS = idle
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, now - lastTick)
        lastTick = now
        let mouse = NSEvent.mouseLocation
        // 말풍선 위에 커서가 있으면 메인 펫이 제자리에 멈춘다 (말풍선이 도망가지 않게)
        pet.frozen = (card.isVisible && card.panel.frame.contains(mouse)) || (speech.isVisible && speech.panel.frame.contains(mouse))
        for (actor, b) in [(pet!, brain!)] + friends.map({ ($0.actor, $0.brain) }) {
            if b.eyesFollowCursor, [.idle, .sit, .alert, .think, .wave, .happy, .play, .groom].contains(actor.anim) {
                actor.lookAt = mouse
            } else {
                actor.lookAt = nil
            }
            actor.update(now: now, dt: dt)
        }
        props.update(dt: dt)
        card.tick()
        speech.tick()
        doodles?.updateHover(mouse: mouse, now: now)
        if now < clipWatchUntil, now - clipLastCheck > 0.08 {
            clipLastCheck = now
            checkClipping()
        }
        if now - lastFPSCheck > 0.25 {
            lastFPSCheck = now
            scheduleTick(fps: desiredFPS())
        }
    }

    private func slowTick() {
        brain.tickNeeds()
        let up = ProcessInfo.processInfo.systemUptime
        if up - lastSample >= 4 {
            lastSample = up
            monitor.sample()
            applySystemState()
        }
        maybeReportStatus()
        if let m = modificationDate(PawmitPaths.config), m != configMTime {
            configMTime = m
            applyConfig(PawmitConfig.load(), save: false)
        }
        // 수명이 끝난 낙서 정리 (흐려지기는 애니메이션이 한다)
        doodles?.tickFade()
        // 1분에 한 번: 상태 저장
        if Int(Date().timeIntervalSince1970) % 60 < 2 {
            saveState()
        }
    }

    private func screensChanged() {
        doodles?.rebuildWindows()
        let screen = world.screen(containing: pet.position)
        pet.position = world.clamp(pet.position, to: screen)
    }

    // MARK: - 시스템 상태

    /// CPU → 더위, RAM → 느려짐, 디스크 → 통통 (설정에서 끌 수 있음)
    private func applySystemState() {
        let on = config.systemReactive
        let heat = on ? CGFloat(monitor.heat) : 0
        let chubby = on ? CGFloat(monitor.chubby) : 0
        let slow = on ? monitor.sluggish : 0
        for (actor, b) in [(pet!, brain!)] + friends.map({ ($0.actor, $0.brain) }) {
            actor.heat = heat
            actor.chubby = chubby
            actor.tempo = 1 - 0.45 * slow
            b.sluggish = slow
        }
    }

    private func scheduleNextStatusReport() {
        let minutes = config.statusReportMinutes
        nextStatusReport = minutes > 0 ? Date().addingTimeInterval(minutes * 60 * .random(in: 0.8...1.2)) : .distantFuture
    }

    private func maybeReportStatus() {
        guard Date() >= nextStatusReport else { return }
        guard !brain.isHeld, !brain.isHome, !chatOpen, cardPendingID == nil, !pet.dragging else { return }
        scheduleNextStatusReport()
        reportStatusNow()
    }

    func reportStatusNow() {
        monitor.sample()
        let snap = monitor.latest
        let temp = monitor.temperature, kmh = monitor.speedKmh, weight = monitor.weightText
        brain.interrupt { [weak self] in
            guard let self else { return }
            if self.brain.isHome { await self.brain.comeOut() }
            _ = await self.brain.reportStatus(snap, temperature: temp, speedKmh: kmh, weight: weight)
        }
    }

    // MARK: - 말

    func speakNow(_ text: String, _ seconds: TimeInterval = 2.6) {
        guard !card.isVisible || cardPendingID == nil, !pet.isHidden else { return }
        lastSpeech = Date()
        speech.show(SpeechBubble(text: text), autoHide: seconds)
    }

    private func sound(_ name: String, volume: Float = 0.5) {
        guard config.sounds, let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = volume
        s.play()
    }

    // MARK: - 펫 클릭

    private func petClicked() {
        if let first = hub.pending.first {
            if !card.isVisible || cardPendingID != first.id { showCard(for: first) }
            return
        }
        if chatOpen {
            closeChat()
        } else {
            openChat()
        }
    }

    // MARK: - 채팅

    private func openChat() {
        chatOpen = true
        speech.hide()
        unbindCardKeys()
        chatModel.petName = pet.identity.name
        let modelName = config.chat.models[config.chat.providerID] ?? (config.chat.providerID == "claude-cli" ? config.chat.model : nil)
        chatModel.provider = chat.providerName == "없음" ? L10n.t("대화 AI 없음 (설정 → 대화)") : chat.providerName + (modelName.map { " · \($0)" } ?? "")
        // 지난 대화 복원 — 있으면 인사 대신 그 기록부터 보여준다
        if chatModel.lines.isEmpty, let log = state.chatLog, !log.isEmpty {
            chatModel.lines = log.suffix(60).map { .init(fromPet: $0.fromPet, text: $0.text) }
        }
        if chatModel.lines.isEmpty {
            chatModel.lines.append(.init(fromPet: true, text: "\(pet.identity.interjection.isEmpty ? "" : pet.identity.interjection + " ")\(L10n.t("무슨 일이야?"))"))
        }
        card.show(ChatCard(model: chatModel, onSend: { [weak self] text in self?.sendChat(text) },
                           onClose: { [weak self] in self?.closeChat() },
                           onReset: { [weak self] in
                               self?.chat.resetConversation()
                               self?.chatModel.lines = []
                               self?.state.chatSessionID = nil
                               self?.state.chatLog = nil
                               self?.saveState()
                           }), focus: true)
        brain.react(.wave, seconds: 1)
    }

    private func closeChat() {
        chatOpen = false
        chat.cancel()
        chatModel.thinking = false
        if cardPendingID == nil { hideCard() }
    }

    private func sendChat(_ text: String) {
        chatModel.lines.append(.init(fromPet: false, text: text))
        if let cmd = ChatActions.directCommand(text) {
            perform(action: cmd)
            chatModel.lines.append(.init(fromPet: true, text: cmd == "home" ? L10n.t("응! 집에 갈게~") : L10n.t("나간다~!")))
            if cmd == "home" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.closeChat() } }
            return
        }
        chatModel.thinking = true
        let reply = ChatModel.Line(fromPet: true, text: "")
        var replyIndex: Int?
        brain.react(.think, seconds: 1.5)
        chat.ask(text, persona: persona(), onDelta: { [weak self] partial in
            guard let self else { return }
            let clean = ChatActions.extract(partial).clean
            if replyIndex == nil {
                self.chatModel.lines.append(reply)
                replyIndex = self.chatModel.lines.count - 1
            }
            if let i = replyIndex, i < self.chatModel.lines.count { self.chatModel.lines[i].text = clean }
        }, onDone: { [weak self] final, error in
            guard let self else { return }
            self.chatModel.thinking = false
            self.state.chatSessionID = self.chat.sessionID
            let (clean, actions) = ChatActions.extract(final ?? error ?? "…")
            if let i = replyIndex, i < self.chatModel.lines.count {
                self.chatModel.lines[i].text = clean
            } else {
                self.chatModel.lines.append(.init(fromPet: true, text: clean))
            }
            if final == nil { self.brain.react(.sad, seconds: 1.2) }
            for a in actions.prefix(1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.perform(action: a) }
            }
            self.saveState()
        })
    }

    /// 대화 AI에게 줄 말투 (스타일 반영)
    private func speechPersona() -> String {
        let sp = PetStyles.effective(config.pet, config: config).speech
        var lines: [String]
        if L10n.isKorean {
            lines = ["말투: 한국어 \(sp?.polite == true ? "존댓말(해요체)" : "반말"), 다정하고 귀엽게, 보통 1~3문장으로 짧게."]
            if !pet.identity.interjection.isEmpty { lines.append("말버릇 '\(pet.identity.interjection)'을 가끔 써.") }
            if let s = sp?.suffix, !s.isEmpty { lines.append("문장 끝에 '\(s)'를 자주 붙여.") }
            switch sp?.emoji {
            case "none": lines.append("이모지는 쓰지 마.")
            case "lots": lines.append("이모지를 많이 써.")
            default: break
            }
        } else {
            lines = ["Tone: English, warm and cute, usually 1–3 short sentences."]
            if !pet.identity.interjection.isEmpty { lines.append("Occasionally use the catchphrase '\(pet.identity.interjection)'.") }
            if let s = sp?.suffix, !s.isEmpty { lines.append("Often append '\(s)' at the end of sentences.") }
            switch sp?.emoji {
            case "none": lines.append("Don't use emoji.")
            case "lots": lines.append("Use lots of emoji.")
            default: break
            }
        }
        if let tone = sp?.tone, !tone.isEmpty { lines.append(L10n.isKorean ? "말투 특징: \(tone)" : "Tone traits: \(tone)") }
        return lines.joined(separator: " ")
    }

    /// 펫이 부르는 호칭 (설정 userTitle, 기본값이면 현재 언어의 기본 호칭). 혼잣말·대화 AI 지시·거절 메시지에 같이 쓴다.
    private var userTitle: String { PawmitConfig.displayTitle(config.userTitle) }
    private var deniedMessage: String {
        if L10n.isKorean { return "\(Korean.particle(userTitle, "이", "가")) 펫(Pawmit)에서 거절했어요." }
        let isDefault = PawmitConfig.cleanTitle(config.userTitle) == PawmitConfig.defaultUserTitle
        return isDefault ? "The user declined via the Pawmit pet." : "\(userTitle) declined via the Pawmit pet."
    }

    /// 대화 persona. 말투 스타일·실시간 상태에 성격 요약 한 줄을 더해 펫마다 대답 문체가 달라지게 한다.
    private func persona() -> String {
        let n = brain.needs
        let working = hub.workingSessions.prefix(3).map { "\($0.project)(\($0.agent.displayName))" }.joined(separator: ", ")
        if !L10n.isKorean {
            let pendingText = hub.pending.isEmpty ? "none" : "\(hub.pending.count)"
            return """
            You are '\(pet.identity.name)', a tiny cute pet living on a macOS desktop. Call your owner '\(userTitle)'.
            You spend your days wandering the desktop, eating, napping, playing with a ball, digging through the trash, and doodling.
            You are also a secretary: when your owner's coding agents (Claude Code, Codex, …) need approvals or finish work, you relay it.
            Your personality is '\(brain.personality.summary)' — let it shape your tone and interests naturally.
            \(speechPersona())
            Answer coding questions briefly and accurately, and be honest that you cannot edit files or run commands.
            You can do a few things yourself. When your owner wants one, append a single tag at the very end of your reply:
            [[home]] go into the menu bar house, [[out]] come out, [[eat]] eat, [[sleep]] nap, [[play]] play ball,
            [[doodle]] doodle on the desktop, [[trash]] rummage the trash, [[chase]] chase the cursor, [[happy]] be happy, [[sad]] sulk, [[wave]] wave.
            Current state: hunger \(Int(n.hunger))/100, energy \(Int(n.energy))/100, fun \(Int(n.fun))/100, mood '\(n.mood)'.
            Working agents: \(working.isEmpty ? "none" : working). Pending approvals: \(pendingText).
            """
        }
        let pendingText = hub.pending.isEmpty ? "없음" : "\(hub.pending.count)개"
        return """
        너는 macOS 데스크탑에서 사는 작고 귀여운 펫 '\(pet.identity.name)'이야. 주인을 '\(Korean.particle(userTitle, "'이라고", "'라고")) 불러.
        평소엔 바탕화면을 돌아다니며 밥 먹고, 낮잠 자고, 공놀이하고, 휴지통을 뒤지고, 바탕화면에 낙서해.
        주인이 쓰는 코딩 에이전트(Claude Code, Codex 등)가 승인을 기다리거나 일을 끝내면 알려주는 비서이기도 해.
        너의 성격은 '\(brain.personality.summary)' — 말투와 관심사에 자연스럽게 반영해.
        \(speechPersona())
        코딩 질문에는 짧고 정확하게 답하되, 파일을 고치거나 명령을 실행할 수는 없다고 솔직히 말해.
        네가 직접 할 수 있는 행동이 있어. 주인이 그런 걸 원하면 답 맨 끝에 태그 하나를 붙여:
        [[home]] 메뉴바 집에 들어가기, [[out]] 집에서 나오기, [[eat]] 밥 먹기, [[sleep]] 낮잠, [[play]] 공놀이,
        [[doodle]] 바탕화면 낙서, [[trash]] 휴지통 뒤지기, [[chase]] 커서 쫓기, [[happy]] 기뻐하기, [[sad]] 시무룩, [[wave]] 손 흔들기.
        지금 상태: 배고픔 \(Int(n.hunger))/100, 기운 \(Int(n.energy))/100, 재미 \(Int(n.fun))/100, 기분 '\(n.mood)'.
        작업 중인 에이전트: \(working.isEmpty ? "없음" : working). 대기 중인 승인 요청: \(pendingText).
        """
    }

    // MARK: - 행동 명령 (메뉴·채팅 공통)

    func perform(action: String) { perform(action: action, on: brain) }

    func perform(action: String, on brain: Brain) {
        switch action {
        case "home":
            brain.interrupt { [weak brain] in _ = await brain?.goHome(reason: .user) }
        case "out":
            brain.interrupt { [weak brain] in await brain?.comeOut() }
        case "eat":
            brain.interrupt { [weak brain] in
                guard let brain else { return }
                if brain.isHome { await brain.comeOut() }
                _ = await brain.eat(fromUser: true)
            }
        case "play":
            brain.interrupt { [weak brain] in
                guard let brain else { return }
                if brain.isHome { await brain.comeOut() }
                _ = await brain.playBall(thrownFrom: NSEvent.mouseLocation)
            }
        case "sleep":
            brain.react(.sleep, seconds: 20)
        case "status":
            reportStatusNow()
        case "doodle", "trash", "chase", "dance", "friends", "clean":
            brain.interrupt { [weak brain] in
                guard let brain else { return }
                if brain.isHome { await brain.comeOut() }
                _ = await brain.runNamed(action)
            }
        case let a where a == "cross" || a.hasPrefix("cross:"):
            // 다른 모니터로 바닥을 따라 건너가기 (cross:ladder처럼 방법 지정 가능)
            let style = a.hasPrefix("cross:") ? String(a.dropFirst(6)) : nil
            brain.interrupt { [weak brain, weak self] in
                guard let brain, let self else { return }
                if brain.isHome { await brain.comeOut() }
                let here = self.world.screen(containing: brain.pet.position)
                guard let other = self.world.neighbors(of: here).first?.0 else { brain.say(L10n.t("건너갈 화면이 없어"), 1.6); return }
                let r = self.world.roamRect(other)
                brain.forcedClimb = style ?? "auto"
                _ = await brain.walk(to: CGPoint(x: r.midX + .random(in: -100...100), y: r.minY), run: false)
            }
        case "happy": brain.react(.happy, seconds: 1.4, jump: 12)
        case "sad": brain.react(.sad, seconds: 2)
        case "wave": brain.react(.wave, seconds: 1.5)
        default: break
        }
    }

    // MARK: - hook 대기열 → 카드

    private func pendingAdded(_ p: AgentHub.Pending) {
        brain.hold()
        sound(p.event.kind == .stop ? "Pop" : "Glass", volume: 0.45)
        if chatOpen { chatOpen = false }
        if cardPendingID == nil || !card.isVisible {
            // 펫이 놀라서 뛰어오른 다음 카드
            DispatchQueue.main.asyncAfter(deadline: .now() + (brain.isHome ? 1.1 : 0.45)) { [weak self] in
                guard let self, self.hub.pending.contains(where: { $0.id == p.id }) else { return }
                if self.cardPendingID == nil || !self.card.isVisible { self.showCard(for: p) }
            }
        } else if let current = hub.pending.first(where: { $0.id == cardPendingID }) {
            showCard(for: current)
        }
        refreshStatusItem()
    }

    private func pendingRemoved(_ p: AgentHub.Pending, _ reason: AgentHub.RemovalReason) {
        var reaction: PetAnim?
        switch reason {
        case .answered:
            reaction = lastDecision == .deny ? .sad : .happy
        case .closedByAgent, .answeredElsewhere:
            if p.event.kind != .stop { speakLater(L10n.t("터미널에서 답했구나!")) }
        case .timeout:
            if p.event.kind != .stop { speakLater(L10n.t("대답이 없어서 터미널로 넘겼어")) }
        }
        lastDecision = nil
        brain.release(reaction: reaction)
        if cardPendingID == p.id {
            cardPendingID = nil
            hideCard()
        }
        if let next = hub.pending.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.hub.pending.contains(where: { $0.id == next.id }) else { return }
                self.showCard(for: next)
            }
        }
        refreshStatusItem()
    }

    private func speakLater(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.speakNow(text, 2.4) }
    }

    private func respond(_ p: AgentHub.Pending, _ reply: HookReply) {
        lastDecision = reply.decision
        hub.respond(p.id, reply)
    }

    /// 결정을 터미널로 넘기기 전에 그 세션의 터미널(또는 앱 안 대화)을 연다. 방해 금지·시간 초과로 넘길 때는 쓰지 않는다.
    private func passToTerminal(_ p: AgentHub.Pending) {
        TerminalJumper.jump(p.envelope, cwd: p.event.cwd)
        respond(p, HookReply(id: p.id, decision: .pass))
    }

    private func cancelCard() {
        if let id = cardPendingID, let p = hub.pending.first(where: { $0.id == id }) {
            respond(p, HookReply(id: p.id, decision: .pass))
        } else if chatOpen {
            closeChat()
        } else {
            card.hide()
        }
    }

    private func showCard(for p: AgentHub.Pending) {
        speech.hide()
        cardPendingID = p.id
        let index = (hub.pending.firstIndex { $0.id == p.id } ?? 0) + 1
        let queue = (index, hub.pending.count)
        let e = p.event
        let project = e.projectName
        switch e.kind {
        case .permission:
            let suggestions = e.permissionSuggestions
            let canAlways = (e.agent == .claude || e.agent == .qwen) && suggestions?.array?.isEmpty == false
            card.show(PermissionCard(
                agent: e.agent, project: project, queue: queue,
                summary: ToolSummary.make(toolName: e.toolName, input: e.toolInput, agent: e.agent),  // 언어가 바뀌어도 맞게 표시할 때 다시 만든다
                canAlways: canAlways, alwaysLabel: alwaysLabel(suggestions),
                onAllow: { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow)) },
                onAlways: { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow, updatedPermissions: suggestions)) },
                onDeny: { [weak self] reason in
                    self?.respond(p, HookReply(id: p.id, decision: .deny, message: reason ?? self?.deniedMessage))
                },
                onPass: { [weak self] in self?.passToTerminal(p) },
                onTyping: { [weak self] in self?.hub.holdForTyping(p.id) }))
            var keys: [String: () -> Void] = [
                "allow": { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow)) },
                "deny": { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .deny, message: self?.deniedMessage)) },
                "terminal": { [weak self] in self?.passToTerminal(p) },
            ]
            if canAlways { keys["always"] = { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow, updatedPermissions: suggestions)) } }
            bindCardKeys(keys)
        case .question:
            let model = QuestionModel(questions: e.questions)
            let send: () -> Void = { [weak self] in
                guard model.ready else { return }
                self?.respond(p, HookReply(id: p.id, decision: .answer, answers: model.answers))
            }
            let pass: () -> Void = { [weak self] in self?.passToTerminal(p) }
            card.show(QuestionCard(
                agent: e.agent, project: project, queue: queue, model: model,
                onAnswer: { _ in send() }, onPass: pass,
                onTyping: { [weak self] in self?.hub.holdForTyping(p.id) }))
            var keys: [String: () -> Void] = ["allow": send, "terminal": pass]
            for n in 1...9 { keys["option\(n)"] = { model.pick(number: n) } }
            bindCardKeys(keys)
        case .plan:
            card.show(PlanCard(
                agent: e.agent, project: project, queue: queue, plan: e.plan ?? L10n.t("(계획 내용 없음)"),
                onApprove: { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow)) },
                onRevise: { [weak self] fb in self?.respond(p, HookReply(id: p.id, decision: .deny, message: fb)) },
                onPass: { [weak self] in self?.passToTerminal(p) },
                onTyping: { [weak self] in self?.hub.holdForTyping(p.id) }))
            bindCardKeys([
                "allow": { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .allow)) },
                "deny": { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .deny, message: L10n.t("계획을 조금 더 다듬어 줘."))) },
                "terminal": { [weak self] in self?.passToTerminal(p) },
            ])
        case .stop:
            card.show(StopCard(
                agent: e.agent, project: project, message: e.message, deadline: p.deadline,
                onTyping: { [weak self] in self?.hub.holdForTyping(p.id) },
                onReply: { [weak self] text in
                    self?.lastDecision = .allow
                    self?.hub.respond(p.id, HookReply(id: p.id, decision: .reply, message: text))
                },
                onOpenTerminal: { [weak self] in self?.passToTerminal(p) },
                onDismiss: { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .pass)) }))
            bindCardKeys(["terminal": { [weak self] in self?.respond(p, HookReply(id: p.id, decision: .pass)) }])
        default:
            respond(p, HookReply(id: p.id, decision: .pass))
        }
    }

    // MARK: - 단축키

    /// 카드가 떠 있는 동안만 승인류 전역 단축키를 잡는다
    private func bindCardKeys(_ actions: [String: () -> Void]) {
        let sc = config.shortcuts
        guard sc.enabled else { return }
        var bindings: [(HotKeyCenter.Combo, () -> Void)] = []
        let map: [String: String] = ["allow": sc.allow, "deny": sc.deny, "always": sc.always, "terminal": sc.terminal]
        for (name, action) in actions {
            if name.hasPrefix("option"), let n = Int(name.dropFirst("option".count)),
               let combo = HotKeyCenter.Combo.parse("\(sc.optionPrefix)+\(n)") {
                bindings.append((combo, action))
            } else if let text = map[name], let combo = HotKeyCenter.Combo.parse(text) {
                bindings.append((combo, action))
            }
        }
        HotKeyCenter.shared.register(group: "card", bindings)
    }

    private func unbindCardKeys() {
        HotKeyCenter.shared.unregister(group: "card")
    }

    private func applyShortcuts() {
        let sc = config.shortcuts
        guard sc.enabled else {
            PawTheme.hints = [:]
            HotKeyCenter.shared.unregister(group: "global")
            unbindCardKeys()
            return
        }
        PawTheme.hints = [
            "allow": HotKeyCenter.Combo.parse(sc.allow)?.label ?? "",
            "deny": HotKeyCenter.Combo.parse(sc.deny)?.label ?? "",
            "always": HotKeyCenter.Combo.parse(sc.always)?.label ?? "",
            "terminal": HotKeyCenter.Combo.parse(sc.terminal)?.label ?? "",
            "option": HotKeyCenter.Combo.parse("\(sc.optionPrefix)+1").map { String($0.label.dropLast()) } ?? "",
        ]
        if let open = HotKeyCenter.Combo.parse(sc.open) {
            HotKeyCenter.shared.register(group: "global", [(open, { [weak self] in self?.openFromShortcut() })])
        }
    }

    private func openFromShortcut() {
        if let first = hub.pending.first {
            showCard(for: first)
            card.panel.makeKey()
        } else if chatOpen {
            card.panel.makeKey()
        } else {
            openChat()
        }
    }

    private func alwaysLabel(_ suggestions: JSONValue?) -> String? {
        for entry in suggestions?.array ?? [] {
            if let rule = entry["rules"]?[0]?["ruleContent"]?.string, !rule.isEmpty {
                return "‘" + (rule.count > 28 ? String(rule.prefix(27)) + "…" : rule) + "’"
            }
            if let mode = entry["mode"]?.string { return L10n.format("‘%@’ 모드", mode) }
        }
        return nil
    }

    // MARK: - 응답 필요 없는 이벤트 → 반응

    private func agentEvent(_ e: AgentEvent, _ env: HookEnvelope) {
        let project = e.projectName ?? e.agent.displayName
        switch e.kind {
        case .notification:
            // PermissionRequest로 이미 카드를 띄운 경우 6초 뒤 오는 permission_prompt 알림은 무시
            if e.notificationType == "permission_prompt",
               hub.pending.contains(where: { $0.event.agent == e.agent && $0.event.sessionID == e.sessionID }) { return }
            if e.agent == .claude, e.notificationType == "permission_prompt", config.quietMode { return }
            sound("Tink", volume: 0.4)
            brain.react(.alert, seconds: 1.2, jump: 10)
            showNotice(e, env, title: noticeTitle(e), message: e.message)
        case .stop:
            brain.react(.happy, seconds: 1.4, jump: 12)
            if card.isVisible, cardPendingID != nil { return }
            showNotice(e, env, title: L10n.format("%@ 끝났어!", project), message: e.message.map { String($0.prefix(220)) }, autoHide: 9)
        case .error:
            brain.react(.sad, seconds: 2)
            speakNow(L10n.format("앗, %@ 에러났어… %@", e.agent.displayName, e.message.map { String($0.prefix(60)) } ?? ""), 4)
        case .sessionStart:
            if throttle("start:\(e.sessionID ?? project)", 60) {
                brain.react(.wave, seconds: 1.2)
                speakNow(L10n.format("%@ 왔다! (%@)", e.agent.displayName, project), 2.2)
            }
        case .promptSubmit:
            if throttle("prompt:\(e.sessionID ?? project)", 90), !brain.isHeld {
                brain.react(.think, seconds: 1.4)
                speakNow((L10n.isKorean ? ["\(project) 작업 시작!", "열심히 해보자~", "나도 응원할게!"]
                                        : ["\(project) is starting!", "Let's do our best~", "I'll cheer you on!"]).randomElement()!, 2)
            }
        case .custom:
            if env.payload["speech"]?.bool == true {
                speakNow(e.message ?? "", 4)
                brain.react(.wave, seconds: 1)
            } else {
                sound("Tink", volume: 0.4)
                brain.react(.alert, seconds: 1.2, jump: 10)
                showNotice(e, env, title: e.title ?? L10n.t("알림"), message: e.message, autoHide: 12, terminal: false)
            }
        case .compact:
            if throttle("compact", 120) { speakNow(L10n.t("기억 정리 중~ 🧹"), 2) }
        default:
            break
        }
    }

    private func noticeTitle(_ e: AgentEvent) -> String {
        switch e.notificationType {
        case "idle_prompt": return L10n.t("기다리고 있대!")
        case "permission_prompt": return L10n.t("승인이 필요하대!")
        case "elicitation_dialog", "agent_needs_input": return L10n.t("입력이 필요하대!")
        case "auth_success": return L10n.t("로그인 완료!")
        default: return e.title ?? L10n.t("확인해 줘!")
        }
    }

    private func showNotice(_ e: AgentEvent, _ env: HookEnvelope, title: String, message: String?, autoHide: TimeInterval = 14, terminal: Bool = true) {
        guard cardPendingID == nil else {
            speakNow(title, 3)
            return
        }
        if chatOpen { return }
        let agent: AgentKind? = e.agent == .generic ? nil : e.agent
        let open: (() -> Void)? = terminal ? { [weak self] in
            TerminalJumper.jump(env, cwd: e.cwd)
            self?.hideCard()
        } : nil
        card.show(NoticeCard(agent: agent, project: e.projectName, title: title, message: message,
                             onOpenTerminal: open,
                             onDismiss: { [weak self] in self?.hideCard() }), autoHide: autoHide)
        var keys: [String: () -> Void] = ["allow": { [weak self] in self?.hideCard() }]
        if let open { keys["terminal"] = open }
        bindCardKeys(keys)
        let token = UUID()
        noticeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHide) { [weak self] in
            if self?.noticeToken == token, self?.cardPendingID == nil { self?.unbindCardKeys() }
        }
    }

    @objc private func checkUpdatesAction() { checkForUpdates(auto: false) }

    /// updateURL(GitHub 저장소 주소 또는 update.json)을 읽어 새 버전이면 카드로 알리고, [지금 업데이트]로 zip을 받아 앱을 교체·재시작한다.
    /// 시작 20초 뒤와 주 1회 자동 확인한다 (기본: 공개 저장소). updateURL을 비우면("") 아무것도 하지 않는다.
    func checkForUpdates(auto: Bool) {
        Task { @MainActor in
            do {
                guard let info = try await updater.check() else {
                    if !auto { brain.say(L10n.format("이미 최신 버전이에요! (%@)", Updater.currentVersion), 2.5) }
                    return
                }
                let cardModel = UpdateCardModel(info: info)
                updater.onStateChange = { cardModel.status = $0 }
                card.show(UpdateCard(model: cardModel,
                                     onInstall: { [weak self] in
                                         cardModel.installing = true
                                         Task { @MainActor in
                                             do { try await self?.updater.downloadAndInstall(info) }
                                             catch {
                                                 cardModel.installing = false
                                                 cardModel.status = error.localizedDescription
                                             }
                                         }
                                     },
                                     onClose: { [weak self] in
                                         self?.updater.onStateChange = nil
                                         self?.hideCard()
                                     }), focus: true)
                if auto { state.lastUpdateCheck = Date(); saveState() }
            } catch {
                if !auto { brain.say(error.localizedDescription, 3) }
            }
        }
    }

    /// 시작 직후 자동 확인 (주 1회)
    private func scheduleAutoUpdateCheck() {
        guard config.updateURL?.isEmpty == false else { return }
        if let last = state.lastUpdateCheck, Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdates(auto: true) }
    }

    private func hideCard() {
        card.hide()
        unbindCardKeys()
    }

    private func throttle(_ key: String, _ seconds: TimeInterval) -> Bool {
        if let last = lastSessionNotice[key], Date().timeIntervalSince(last) < seconds { return false }
        lastSessionNotice[key] = Date()
        return true
    }

    // MARK: - 메뉴바

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = HouseIcon.image(.away)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = hub.pending.count
        let state: HouseIcon.State = count > 0 ? .calling : (brain?.isHome == true ? .home : .away)
        button.image = HouseIcon.image(state)
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0
            ? (L10n.isKorean ? "\(pet?.identity.name ?? "펫")이(가) 대답을 기다려요 (\(count))"
                             : "\(pet?.identity.name ?? "pet") is waiting for your answer (\(count))")
            : "Pawmit"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = brain.needs
        let header = NSMenuItem(title: "\(pet.identity.name) · \(n.mood)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let needsItem = NSMenuItem(title: L10n.format("배부름 %lld · 기운 %lld · 재미 %lld · 애정 %lld", 100 - Int(n.hunger), Int(n.energy), Int(n.fun), Int(n.affection)), action: nil, keyEquivalent: "")
        needsItem.isEnabled = false
        menu.addItem(needsItem)
        let persona = NSMenuItem(title: L10n.format("성격: %@", brain.personality.summary), action: nil, keyEquivalent: "")
        persona.isEnabled = false
        menu.addItem(persona)

        let working = hub.workingSessions
        if !working.isEmpty {
            menu.addItem(.separator())
            for s in working.prefix(5) {
                let item = NSMenuItem(title: L10n.format("작업 중 · %@ (%@)", s.project, s.agent.displayName), action: #selector(jumpToSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.envelope
                menu.addItem(item)
            }
        }
        if !hub.pending.isEmpty {
            let item = NSMenuItem(title: L10n.format("대답 기다리는 요청 %lld개 보기", hub.pending.count), action: #selector(showPending), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        buildPetActions(into: menu, for: brain)
        menu.addItem(.separator())
        if let d = doodles, !d.strokes.isEmpty {
            menu.addItem(item(L10n.format("낙서 모두 지우기 (%lld개)", d.groupIDs.count), #selector(clearDoodlesAction)))
            menu.addItem(.separator())
        }
        menu.addItem(item(L10n.t("설정…"), #selector(openSettingsAction), key: ","))
        menu.addItem(item(L10n.t("커스텀 펫 만들기…"), #selector(openWizardAction)))
        menu.addItem(item(L10n.t("업데이트 확인…"), #selector(checkUpdatesAction)))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("Pawmit 종료"), #selector(quit), key: "q"))
    }

    /// 메뉴 항목이 어느 펫에게 내리는 명령인지
    final class PetCommand: NSObject {
        let action: String
        weak var brain: Brain?
        init(_ action: String, _ brain: Brain) {
            self.action = action
            self.brain = brain
        }
    }

    private func buildPetActions(into menu: NSMenu, for target: Brain) {
        let isMain = target === brain
        func add(_ title: String, _ action: String) {
            let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = PetCommand(action, target)
            menu.addItem(i)
        }
        if !isMain {
            let header = NSMenuItem(title: target.pet.identity.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        if isMain {
            if target.isHome { add(L10n.t("밖으로 나와!"), "out") } else { add(L10n.t("집으로 들어가"), "home") }
            menu.addItem(item(L10n.t("대화하기…"), #selector(menuChat)))
        }
        add(L10n.t("밥 주기 🍙"), "eat")
        add(L10n.t("공 던지기 🧶"), "play")
        add(L10n.t("낙서해 줘 🖍️"), "doodle")
        add(L10n.t("낙서 청소해 줘 🧽"), "clean")
        add(L10n.t("휴지통 뒤져봐 🗑️"), "trash")
        add(L10n.t("춤춰 줘 💃"), "dance")
        if !friends.isEmpty { add(L10n.t("친구랑 놀아 🤝"), "friends") }
        if isMain { add(L10n.t("시스템 상태 알려줘 🌡️"), "status") }
    }

    private func item(_ title: String, _ action: Selector, tag: String? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.representedObject = tag
        return i
    }

    /// 설치돼 있는 글꼴만 보여준다. 표시 이름은 언어별(영어에선 글꼴 영문명 그대로).
    static var fontCandidates: [(String, String)] {
        L10n.isKorean
            ? [("Apple SD Gothic Neo", "애플 SD 산돌고딕"), ("Pretendard", "Pretendard"), ("Noto Sans KR", "Noto Sans KR"),
               ("NanumSquareRound", "나눔스퀘어라운드"), ("NanumGothic", "나눔고딕"), ("Nanum Pen Script", "나눔손글씨 펜"),
               ("NanumBarunpen", "나눔바른펜"), ("BM JUA_OTF", "배민 주아"), ("BM Jua", "배민 주아"), ("BMHANNAPro", "배민 한나"),
               ("Gmarket Sans", "G마켓 산스"), ("Spoqa Han Sans Neo", "스포카 한 산스"), ("Cafe24 Ssurround", "카페24 써라운드"),
               ("AppleMyungjo", "애플 명조"), ("Chalkboard SE", "Chalkboard"), ("Marker Felt", "Marker Felt")]
            : [("Apple SD Gothic Neo", "Apple SD Gothic Neo"), ("Pretendard", "Pretendard"), ("Noto Sans KR", "Noto Sans KR"),
               ("NanumSquareRound", "NanumSquareRound"), ("NanumGothic", "NanumGothic"), ("Nanum Pen Script", "Nanum Pen Script"),
               ("NanumBarunpen", "NanumBarunpen"), ("BM JUA_OTF", "BM JUA"), ("BM Jua", "BM Jua"), ("BMHANNAPro", "BM HANNA"),
               ("Gmarket Sans", "Gmarket Sans"), ("Spoqa Han Sans Neo", "Spoqa Han Sans"), ("Cafe24 Ssurround", "Cafe24 Ssurround"),
               ("AppleMyungjo", "Apple Myungjo"), ("Chalkboard SE", "Chalkboard"), ("Marker Felt", "Marker Felt")]
    }

    static func installedFonts() -> [(String, String)] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var seen = Set<String>()
        return fontCandidates.filter { installed.contains($0.0) && seen.insert($0.1).inserted }
    }

    // MARK: - 메뉴 동작

    @objc private func menuAction(_ sender: NSMenuItem) {
        if let cmd = sender.representedObject as? PetCommand, let target = cmd.brain {
            perform(action: cmd.action, on: target)
        } else if let tag = sender.representedObject as? String {
            perform(action: tag)
        }
    }

    @objc private func menuChat() {
        if brain.isHome {
            perform(action: "out")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openChat() }
        } else {
            openChat()
        }
    }

    @objc private func showPending() {
        if let first = hub.pending.first { showCard(for: first) }
    }

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let env = sender.representedObject as? HookEnvelope else { return }
        TerminalJumper.jump(env, cwd: AgentAdapters.normalize(env).cwd)
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func clearDoodlesAction() { clearAllDoodles() }
    @objc private func openWizardAction() { openWizard() }

    // MARK: - 설정 창이 쓰는 API

    let settingsWindow = SettingsWindowController()
    private var wizardWindow: WizardWindowController?
    private var makerWindows: [MakerWindowController] = []

    func openSettings() {
        settingsWindow.show(director: self)
    }

    func openWizard() {
        if wizardWindow == nil { wizardWindow = WizardWindowController(director: self) }
        wizardWindow?.show()
    }

    /// 펫 메이커: 새 펫, 또는 메이커로 만든 펫(folder:…) 고치기
    func openMaker(editing id: String? = nil) {
        var spec: RigSpec?
        var folder: URL?
        if let id, id.hasPrefix("folder:") {
            let f = PawmitPaths.petsDir.appendingPathComponent(String(id.dropFirst("folder:".count)))
            if let v = (try? Data(contentsOf: f.appendingPathComponent("pet.json"))).flatMap({ JSONValue.parse($0) }),
               let s = RigSpec.decode(v) {
                spec = s
                folder = f
            }
        }
        let controller = MakerWindowController(director: self, spec: spec, folder: folder)
        makerWindows.append(controller)
        controller.onClose = { [weak self, weak controller] in self?.makerWindows.removeAll { $0 === controller } }
        controller.show()
    }

    /// 지금 펫이 메이커 펫인지 (설정에서 "메이커로 고치기" 표시용)
    func isMakerPet(_ id: String) -> Bool {
        guard id.hasPrefix("folder:") else { return false }
        let f = PawmitPaths.petsDir.appendingPathComponent(String(id.dropFirst("folder:".count)))
        return (try? Data(contentsOf: f.appendingPathComponent("pet.json"))).flatMap({ JSONValue.parse($0) })?["kind"]?.string == "rig"
    }

    var personalitySummary: String {
        L10n.format("성격: %@", brain.personality.summary) + "\nNo. \(String(brain.behaviorSeed, radix: 16).suffix(6).uppercased())"
    }

    func previewImage(for id: String) -> NSImage? {
        let identity = PetRoster.make(id: id, config: config)
        let size = NSSize(width: 110, height: 110)
        return NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var pose = PetPose()
            pose.anim = .wave
            pose.clock = 1.2
            pose.animTime = 0.4
            ctx.translateBy(x: 55, y: 12)
            ctx.scaleBy(x: 1.45 * identity.scale, y: 1.45 * identity.scale)
            identity.renderer.draw(pose, in: ctx)
            return true
        }
    }

    /// 위자드에서 만든 펫을 메인 또는 친구로
    func adoptPet(_ id: String, asFriend: Bool) {
        var c = config
        if asFriend {
            if !c.friends.contains(id), c.friends.count < 4 { c.friends.append(id) }
        } else {
            c.pet = id
            c.friends.removeAll { $0 == id }
        }
        applyConfig(c, save: true)
        settingsWindow.refresh()
    }

    func clearAllDoodles() {
        doodles?.clearAll()
        speakNow(L10n.t("깨끗하게 지웠어!"), 1.8)
    }

    func toggleAgent(_ agent: AgentKind) {
        guard let target = HookInstaller.targets(config: config).first(where: { $0.agent == agent }) else { return }
        let installed = HookInstaller.status(target) == .installed
        runInstaller(target, install: !installed)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert(L10n.t("로그인 시 실행 설정 실패"), error.localizedDescription + "\n" + L10n.t("Pawmit.app을 /Applications 에 두고 다시 시도해 주세요."))
        }
    }

    func requestAccessibility() { world.requestAccessibility() }

    @objc func openFontPanel() {
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(fontPanelChanged(_:))
        let current = config.fontName.flatMap { NSFont(name: $0, size: 13) } ?? NSFont.systemFont(ofSize: 13)
        fm.setSelectedFont(current, isMultiple: false)
        NSApp.activate(ignoringOtherApps: true)
        fm.orderFrontFontPanel(nil)
    }

    @objc private func fontPanelChanged(_ sender: NSFontManager) {
        let font = sender.convert(NSFont.systemFont(ofSize: 13))
        guard let family = font.familyName else { return }
        var c = config
        c.fontName = family
        applyConfig(c, save: true)
        settingsWindow.refresh()
        speakNow(L10n.format("%@ 글꼴이야!", family), 2)
    }

    func rerollPersonality() {
        let s = UInt64.random(in: 1...UInt64.max)
        state.seeds[pet.identity.id] = s
        brain.behaviorSeed = s
        brain.behaviorIndex = 0
        brain.applyStyle(PetStyles.effective(config.pet, config: config))
        saveState()
        brain.react(.happy, seconds: 1.4, jump: 12)
        speakNow(L10n.format("새로운 나! %@", brain.personality.summary), 3)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func runInstaller(_ target: HookInstaller.Target, install: Bool) {
        do {
            let plan = try HookInstaller.makePlan(target, install: install)
            if plan.isNoop {
                alert(target.agent.displayName, install ? L10n.t("이미 연결돼 있어요.") : L10n.t("연결된 hook이 없어요."))
                return
            }
            let a = NSAlert()
            a.messageText = install ? L10n.format("%@에 Pawmit 연결", target.agent.displayName) : L10n.format("%@ 연결 해제", target.agent.displayName)
            a.informativeText = "\(target.file.path)\n\n" + plan.changes.joined(separator: "\n") +
                "\n\n" + L10n.t("원본은 ~/.pawmit/backups 에 백업돼요. 다른 hook은 건드리지 않아요.")
            a.addButton(withTitle: install ? L10n.t("연결") : L10n.t("해제"))
            a.addButton(withTitle: L10n.t("취소"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
            try HookInstaller.execute(plan)
            var msg = install ? L10n.t("연결했어요! 새로 시작하는 세션부터 펫이 알려줘요.") : L10n.t("연결을 해제했어요.")
            if install, let note = target.note { msg += "\n\n※ \(note)" }
            alert(target.agent.displayName, msg)
            if install { brain.react(.happy, seconds: 1.4, jump: 12) }
        } catch let error as HookInstaller.InstallError {
            if case .manual(let text) = error { alert(L10n.format("%@ 수동 설정", target.agent.displayName), text) }
            else { alert(L10n.t("연결 실패"), error.localizedDescription) }
        } catch {
            alert(L10n.t("연결 실패"), error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - 설정 반영

    func applyConfig(_ c: PawmitConfig, save: Bool) {
        let old = config
        config = c
        if save {
            try? c.save()
            configMTime = modificationDate(PawmitPaths.config)
        }
        applyTextStyle()
        world.config = c
        hub.config = c
        // 업데이트 주소를 고친 뒤 [지금 확인]을 눌러도 새 주소로 (예전엔 처음 만든 설정을 계속 썼다)
        updater.config = c
        defer {
            applyPerformance()
            applySystemState()
            if old.statusReportMinutes != c.statusReportMinutes { scheduleNextStatusReport() }
        }
        chat.config = c
        brain.config = c
        doodles?.config = c
        for f in friends { f.brain.config = c }
        // 스타일: 색·말버릇이 바뀌면 모습을 다시 만들고, 성격·말투만 바뀌면 바로 적용
        let styleChanged = old.petStyles != c.petStyles
        func looks(_ st: PetStyle?) -> [String] { [PetStyles.digest(st?.colors), st?.speech?.prefix ?? ""] }
        let mainLooksChanged = looks(old.petStyles[c.pet]) != looks(c.petStyles[c.pet])
        let friendStylesChanged = c.friends.contains { old.petStyles[$0] != c.petStyles[$0] }
        if styleChanged, !mainLooksChanged, old.pet == c.pet { brain.applyStyle(PetStyles.effective(c.pet, config: c)) }
        if old.pet != c.pet || old.catCoat != c.catCoat || old.petName != c.petName || (styleChanged && mainLooksChanged) {
            replaceMainPet()
        } else if old.size != c.size {
            pet.resize(scale: displayScale(for: pet.identity))
        }
        if old.friends != c.friends || old.pet != c.pet || old.size != c.size || friendStylesChanged { spawnFriends() }
        if old.language != c.language { applyLanguage(AppLanguage.from(config: c.language)) }
    }

    /// 언어를 바로 바꾸고 열린 설정·위자드·메이커 창과 메뉴를 그 자리에서 다시 그린다.
    /// 기본 펫 이름·말버릇도 언어별이라 펫을 다시 불러온다(위치·상태 유지). 시스템 열기·저장 패널은 다음 실행부터 바뀐다.
    func applyLanguage(_ lang: AppLanguage) {
        L10n.current = lang
        lang.applyToAppleLanguages()
        LanguageStore.shared.language = lang
        settingsWindow.languageChanged()
        wizardWindow?.languageChanged()
        makerWindows.forEach { $0.languageChanged() }
        refreshStatusItem()
        let reshowCard = card.isVisible ? cardPendingID : nil
        replaceMainPet()
        spawnFriends()
        // 떠 있던 승인·질문·계획 카드는 요청 시점에 만든 제목까지 새 언어로 다시 만든다
        if let id = reshowCard, let p = hub.pending.first(where: { $0.id == id }) { showCard(for: p) }
    }

    private func applyTextStyle() {
        PawTheme.textScale = CGFloat(max(0.7, min(2, config.textScale)))
        PawTheme.fontName = config.fontName
        PawTheme.hookText = config.hookText
        PawTheme.chatText = config.chatText
        applyShortcuts()
        // 열려 있는 말풍선은 다음에 열 때 반영된다. 채팅 창은 바로 다시 그린다.
        if chatOpen { openChat() }
    }

    /// 펫 정의(pet.json)가 바뀌었을 때: 그 펫을 쓰고 있으면 다시 불러온다 (메이커 저장 등)
    func petDefinitionChanged(_ id: String) {
        FrameCache.shared.clear()
        if config.pet == id { replaceMainPet() }
        if config.friends.contains(id) { spawnFriends() }
        settingsWindow.refresh()
    }

    private func replaceMainPet() {
        let pos = pet.position
        let needs = brain.needs
        brain.stop()
        pet.close()
        state.x = Double(pos.x)
        state.y = Double(pos.y)
        state.needs = needs
        state.isHome = false
        spawnMainPet()
        brain.react(.wave, seconds: 1.4, jump: 10)
        speakNow(L10n.format("안녕! 나는 %@!", pet.identity.name), 2.6)
    }

    // MARK: - 개발용 검증 명령 (`pawmit debug …`)

    private func debug(_ cmd: String, _ arg: String?) -> String {
        switch cmd {
        case "state":
            let n = brain.needs
            let v: JSONValue = [
                "pet": .string(pet.identity.id), "name": .string(pet.identity.name), "anim": .string(pet.anim.rawValue),
                "x": .number(Double(pet.position.x)), "y": .number(Double(pet.position.y)),
                "facing": .string(pet.facing == .left ? "left" : "right"), "home": .bool(brain.isHome), "hidden": .bool(pet.isHidden),
                "held": .bool(brain.isHeld), "pending": .number(Double(hub.pending.count)), "crossing": .string(brain.lastCrossing),
                "card": .bool(card.isVisible), "speech": .bool(speech.isVisible), "chat": .bool(chatOpen),
                "friends": .array(friends.map { .string($0.actor.identity.id) }),
                "friendPos": .array(friends.map { .string("\($0.actor.identity.id) \(Int($0.actor.position.x)),\(Int($0.actor.position.y)) \($0.brain.lastCrossing)") }), "props": .number(Double(props.props.count)),
                "propList": .array(props.props.map { .string("\($0.kind) \(Int($0.position.x)),\(Int($0.position.y))") }),
                "doodles": .number(Double(doodles?.strokes.count ?? 0)),
                "needs": ["hunger": .number(n.hunger.rounded()), "energy": .number(n.energy.rounded()), "fun": .number(n.fun.rounded())],
                "house": world.houseFrame().map { .array([.number(Double($0.midX)), .number(Double($0.midY))]) } ?? .null,
                "dockTrash": world.dockTrashRect().map { .array([.number(Double($0.midX)), .number(Double($0.midY))]) } ?? .null,
                "accessibility": .bool(world.hasAccessibility),
            ]
            return v.encoded()
        case "snapshot":
            return snapshot(name: arg?.isEmpty == false ? arg! : "snapshot")
        case "open":
            switch arg ?? "" {
            case "settings": openSettings()
            case let a where a.hasPrefix("settings:"):
                openSettings()
                if let pane = SettingsPane(rawValue: String(a.dropFirst(9))) { settingsWindow.select(pane) }
            case "wizard": openWizard()
            case "wizard-assemble": openWizard(); wizardWindow?.debugStep(.assemble)
            case "wizard-images": openWizard(); wizardWindow?.debugStep(.images)
            case "maker": openMaker()
            default: return "unknown"
            }
            return "ok"
        case "winsnap":
            // 제목으로 우리 앱 창 하나를 PNG로 (설정·위자드 화면 확인용)
            guard let w = NSApp.windows.first(where: { $0.title == (arg ?? "") && $0.isVisible }),
                  let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no window" }
            view.cacheDisplay(in: view.bounds, to: rep)
            // 창 배경색 위에 합성 (다크 모드 흰 글씨가 투명 배경에서 사라지지 않게)
            let img = NSImage(size: view.bounds.size)
            img.lockFocus()
            (w.backgroundColor ?? .windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            img.unlockFocus()
            let url = PawmitPaths.home.appendingPathComponent("debug/win.png")
            if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
                try? bmp.representation(using: .png, properties: [:])?.write(to: url)
            }
            return url.path
        case "plans":
            // 실행 중인 펫의 성격과 최근 행동 분포
            var h: [String: Int] = [:]
            for a in brain.planHistory { h[a, default: 0] += 1 }
            let p = brain.personality
            let v: JSONValue = [
                "personality": ["energy": .number(p.energy), "curiosity": .number(p.curiosity), "sociability": .number(p.sociability),
                                "artistry": .number(p.artistry), "mischief": .number(p.mischief), "appetite": .number(p.appetite),
                                "laziness": .number(p.laziness), "tidiness": .number(p.tidiness)],
                "summary": .string(p.summary), "plans": .number(Double(brain.planHistory.count)),
                "histogram": .object(h.mapValues { .number(Double($0)) }),
            ]
            return v.encoded()
        case "system":
            monitor.sample()
            let m = monitor.latest
            return JSONValue.object([
                "cpu": .number((m.cpu * 100).rounded()), "ram": .number((m.ram * 100).rounded()), "disk": .number((m.disk * 100).rounded()),
                "temperature": .number(Double(monitor.temperature)), "speedKmh": .number(Double(monitor.speedKmh)),
                "weight": .string(monitor.weightText), "heat": .number(monitor.heat), "sluggish": .number(monitor.sluggish),
                "chubby": .number(monitor.chubby), "speedFactor": .number(brain.speedFactor),
            ]).encoded()
        case "framecache":
            // 몸통 프레임 캐시 상태와, 캐시·얼굴 영역 밖으로 삐져나가는 그림이 있는지 검사
            let c = FrameCache.shared
            if arg == "on" || arg == "off" { c.enabled = arg == "on" }
            var overflow: [JSONValue] = []
            if arg == "bounds" {
                var big = ChibiSpecies.named("tokki")!
                big.headRX = 21
                big.headRY = 17
                let renderers: [(String, LayeredPetRenderer)] = ChibiSpecies.all.map { ($0.id, ChibiRenderer(species: $0)) }
                    + [("custom-big", ChibiRenderer(species: big))]
                    + ["orange", "gray", "black", "white"].map { ("cat-\($0)", CatRenderer(coat: $0)) }
                for (id, r) in renderers {
                    var body = CGRect.null, face = CGRect.null
                    for anim in [PetAnim.idle, .sit, .walk, .run, .sleep] {
                        for i in 0..<12 {
                            for chubby in [0.0, 1.0] as [CGFloat] {
                                for look in [CGVector(dx: -1, dy: -1), CGVector(dx: 1, dy: 1)] {
                                    var p = PetPose()
                                    p.anim = anim
                                    p.clock = Double(i) * 0.25
                                    p.walkPhase = CGFloat(i) * .pi / 6
                                    p.chubby = chubby
                                    p.look = look
                                    p.heat = 0.55
                                    guard let q = FrameQuantizer.quantize(p) else { continue }
                                    var fp = q.pose
                                    fp.look = look
                                    fp.heat = 0.55
                                    body = body.union(Self.inkBounds { r.renderBody(q.pose, in: $0, face: false) })
                                    face = face.union(Self.inkBounds { r.renderFace(fp, in: $0) })
                                }
                            }
                        }
                    }
                    let okBody = r.cacheBounds.contains(body), okFace = r.faceBounds.contains(face)
                    if !okBody || !okFace {
                        overflow.append(["id": .string(id), "body": .string("\(body.integral)"), "cache": .string("\(r.cacheBounds)"),
                                         "face": .string("\(face.integral)"), "faceBox": .string("\(r.faceBounds)")])
                    }
                }
            }
            return JSONValue.object([
                "frames": .number(Double(c.count)), "kb": .number(Double(c.bytes / 1024)),
                "hits": .number(Double(c.hits)), "misses": .number(Double(c.misses)), "overflow": .array(overflow), "enabled": .bool(c.enabled),
                "partsMismatch": .array(ChibiParts.catalogMismatches().map { .string($0) }),
            ]).encoded()
        case "sheet":
            // 펫 × 포즈 한 장 (모습 고칠 때 비교용). arg: 펫 id 여러 개(공백 구분) 또는 비우면 기본 펫 전부
            // path:<폴더>는 경로에 공백이 있을 수 있어 통째로 하나
            let ids = arg.flatMap { $0.hasPrefix("path:") ? [$0] : nil }
                ?? (arg?.split(separator: " ").map(String.init)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (ChibiSpecies.all.map(\.id) + ["cat"])
            let name = ids.count == 1 && PetCatalog.builtin(ids[0]) == nil
                ? "preview-" + (ids[0] as NSString).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" } : "sheet"
            return renderSheet(ids: ids, name: name)
        case "bench":
            // 펫마다 걷기·춤(모션) 포즈를 화면 크기로 300번 그린 평균 시간 (그림을 고친 뒤 비용 확인용)
            var words = arg?.split(separator: " ").map(String.init) ?? []
            let plain = words.contains("plain")
            words.removeAll { $0 == "plain" }
            let ids = words.isEmpty ? ["mongle", "banban", "cat"] : words
            let saved = Ink.shading
            if plain { Ink.shading = false }
            defer { Ink.shading = saved }
            var out: [String: JSONValue] = [:]
            for id in ids {
                let identity = PetRoster.make(id: id, config: config)
                let s = displayScaleFor(identity) * 2
                guard let ctx = CGContext(data: nil, width: Int(110 * s), height: Int(120 * s), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                let n = 300
                let t0 = ProcessInfo.processInfo.systemUptime
                for i in 0..<n {
                    var pose = PetPose()
                    pose.anim = .walk
                    pose.walkPhase = CGFloat(i) * 0.3
                    pose.clock = Double(i) / 30
                    if i % 2 == 1 { pose.motion = MotionSpec(base: "walk", leftArm: Wave(2.4, amp: 0.4, freq: 1.5), bounce: Wave(1, amp: 2, freq: 2)); pose.motionTime = Double(i) / 30 }
                    ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                    ctx.saveGState()
                    ctx.translateBy(x: 55 * s, y: 10 * s)
                    ctx.scaleBy(x: s, y: s)
                    identity.renderer.draw(pose, in: ctx)
                    ctx.restoreGState()
                }
                out[id] = .number((ProcessInfo.processInfo.systemUptime - t0) / Double(n) * 1000 * 1000)
            }
            return JSONValue.object(["usPerFrame": .object(out)]).encoded()
        case "cleardoodles":
            clearAllDoodles()
            return "strokes=\(doodles?.strokes.count ?? 0)"
        case "chattest":
            // provider 하나로 모델 목록 + 짧은 대화 (설정은 바꾸지 않음). 결과는 debug/chattest.json
            let parts = (arg ?? "").split(separator: " ").map(String.init)
            var c = config
            c.chat.provider = parts.first ?? "auto"
            if parts.count > 1 { c.chat.models[c.chat.providerID] = parts[1] }
            let url = PawmitPaths.home.appendingPathComponent("debug/chattest.json")
            try? FileManager.default.removeItem(at: url)
            let started = Date()
            let chat = ChatService(config: c, sessionID: nil)
            Task { @MainActor in
                var out: [String: JSONValue] = ["provider": .string(chat.providerName)]
                if let info = ChatProviders.provider(c.chat.providerID, custom: c.chat.customProviders) {
                    do { out["models"] = .array(try await ChatService.models(for: info).prefix(12).map { .string($0) }) }
                    catch { out["modelsError"] = .string(error.localizedDescription) }
                }
                var deltas = 0
                chat.ask("한 문장으로 인사해 줘.", persona: "너는 귀여운 데스크탑 펫이야. 한국어 반말로 아주 짧게 대답해.", onDelta: { _ in deltas += 1 }) { text, err in
                    out["reply"] = text.map { .string($0) } ?? .null
                    out["error"] = err.map { .string($0) } ?? .null
                    out["deltas"] = .number(Double(deltas))
                    out["seconds"] = .number(Date().timeIntervalSince(started).rounded())
                    try? Data(JSONValue.object(out).encoded(pretty: true).utf8).write(to: url)
                    _ = chat
                }
            }
            return "started"
        case "makertest":
            // 메이커 편집 동작을 코드로 그대로 실행해 본다 (펫 폴더에는 저장하지 않고 debug/maker-test에 결과만)
            let m = MakerModel(spec: nil, folder: nil)
            m.director = self
            m.rename("테스트 펫")
            m.selected = "acc1"
            m.paint = .red
            let wobbly = (0..<60).map { i -> CGPoint in
                let a = Double(i) / 60 * 2 * .pi
                let r = (i % 6 < 3 ? 8.0 : 5.0) + sin(Double(i) * 1.7) * 0.4
                return CGPoint(x: 50 + cos(a) * r, y: 30 + sin(a) * r * 0.7)
            }
            if let path = MakerCanvasView.closedShape(from: wobbly) { m.addShape(path) }
            m.selected = "body"
            m.markMode = true
            m.paint = Color(red: 1, green: 0.8, blue: 0.85)
            m.addShape(CGPath(ellipseIn: CGRect(x: 44, y: 76, width: 12, height: 9), transform: nil))
            m.markMode = false
            m.translatePart("armR", by: CGSize(width: 1.5, height: -1))
            m.setPivot("armR", to: CGPoint(x: 62, y: 72))
            m.setFace(at: CGPoint(x: 50, y: 56), onHead: true)
            m.updateFace { $0.eyes = "sparkle"; $0.mouth = "cat" }
            m.selected = "earL"
            m.erase(at: CGPoint(x: 34, y: 37))
            let beforeUndo = m.spec.parts["earL"] == nil
            m.undo()
            m.updateStyle { $0.speech = SpeechStyle(suffix: "뿅") }
            let issues = m.validationIssues()
            let dir = PawmitPaths.home.appendingPathComponent("debug/maker-test", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(m.spec.json.encoded(pretty: true).utf8).write(to: dir.appendingPathComponent("pet.json"))
            let sheet = renderSheet(ids: ["path:" + dir.path], name: "maker-test")
            m.cleanUp()
            return JSONValue.object([
                "issues": .array(issues.map { .string($0) }), "earErasedThenUndone": .bool(beforeUndo && m.spec.parts["earL"] != nil),
                "accShapes": .number(Double(m.spec.parts["acc1"]?.shapes?.count ?? 0)),
                "bodyMarks": .number(Double(m.spec.parts["body"]?.shapes?.filter { $0.line == false }.count ?? 0)),
                "sheet": .string(sheet),
            ]).encoded()
        case "makerai":
            // 말로 설명 → AI 초안 (오래 걸려서 바로 돌아오고, 끝나면 debug/maker-ai/에 pet.json·미리보기)
            let parts = (arg ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            let sk = Skeleton.named(parts.first ?? "") ?? .biped
            let desc = parts.count > 1 ? parts[1] : (arg ?? "")
            let dir = PawmitPaths.home.appendingPathComponent("debug/maker-ai", isDirectory: true)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("result.json"))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let started = Date()
            MakerAI.generate(description: desc, skeleton: sk, config: config) { [weak self] spec, note in
                guard let self else { return }
                var out: [String: JSONValue] = ["seconds": .number(Date().timeIntervalSince(started).rounded()), "note": note.map { .string($0) } ?? .null]
                if let spec {
                    try? Data(spec.json.encoded(pretty: true).utf8).write(to: dir.appendingPathComponent("pet.json"))
                    out["issues"] = .array(spec.validate().map { .string($0) })
                    out["sheet"] = .string(self.renderSheet(ids: ["path:" + dir.path], name: "maker-ai"))
                    out["name"] = .string(spec.name)
                }
                try? Data(JSONValue.object(out).encoded(pretty: true).utf8).write(to: dir.appendingPathComponent("result.json"))
            }
            return "started"
        case "doodlesnap":
            return doodles?.snapshot(to: PawmitPaths.home.appendingPathComponent("debug/doodles.png")) ?? "no layer"
        case "action":
            // friend:<동작> 이면 첫 번째 친구에게
            if let a = arg, a.hasPrefix("friend:"), let f = friends.first {
                perform(action: String(a.dropFirst(7)), on: f.brain)
                return "ok"
            }
            perform(action: arg ?? "")
            return "ok"
        case "say":
            speakNow(arg ?? "", 4)
            return "ok"
        case "chat":
            openChat()
            return "ok"
        case "ask":
            // 개발용: 채팅창에 말 걸기 (대답은 debug chatlog 로 확인)
            if !chatOpen { openChat() }
            sendChat(arg ?? "안녕")
            return "sent"
        case "chatfill":
            // 개발용: 가짜 대화 N줄로 채팅창 열기 (스크롤 확인)
            let n = Int(arg ?? "") ?? 40
            chatModel.lines = (1...max(1, n)).map { i in .init(fromPet: i % 2 == 0, text: i % 2 == 0 ? "대답 \(i): 냐옹~ 그건 **이렇게** 하면 돼!\n- `swift test`\n- 다시 빌드" : "질문 \(i): 이거 어떻게 해?") }
            openChat()
            return "lines=\(chatModel.lines.count)"
        case "windowcheck":
            // 가장 많이 기울인·흔든·뛴 자세가 펫 창(PetActor.windowSize) 안에 들어오는지 (단위 좌표)
            let unitW: CGFloat = 140, room = PetActor.footRoom, unitH: CGFloat = 126 + room
            var out: [String: JSONValue] = [:]
            for id in ChibiSpecies.all.map(\.id) + ["cat"] {
                let r = PetRoster.make(id: id, config: config).renderer
                var box = CGRect.null
                for anim in [PetAnim.idle, .sit, .walk, .run, .happy, .wave, .dig, .drag, .fall, .eat] {
                    for lean in [-0.4, 0.4] {
                        for sway in [-3.0, 3.0] {
                            var p = PetPose()
                            p.anim = anim
                            p.walkPhase = .pi / 2
                            p.motion = MotionSpec(base: anim.rawValue, lean: Wave(lean), bounce: Wave(0, amp: 3.5, freq: 1), sway: Wave(sway))
                            p.motionTime = 0.25
                            p.hop = 18
                            box = box.union(Self.inkBounds { ctx in ctx.translateBy(x: 0, y: p.hop); r.draw(p, in: ctx) })
                        }
                    }
                    // 모션 없이 바닥에서 (떨어지기·끌리기는 땅에 닿은 채로도 그린다)
                    for i in 0..<8 {
                        var p = PetPose()
                        p.anim = anim
                        p.walkPhase = CGFloat(i) * .pi / 4
                        p.clock = Double(i) * 0.37
                        p.animTime = Double(i) * 0.37
                        box = box.union(Self.inkBounds { ctx in r.draw(p, in: ctx) })
                    }
                }
                // 창: 가로 ±70, 발 아래 footRoom ~ 발 위 126
                let fits = box.minX >= -unitW / 2 && box.maxX <= unitW / 2 && box.minY >= -room && box.maxY <= unitH - room
                out[id] = .string("\(fits ? "OK" : "넘침") x \(Int(box.minX))…\(Int(box.maxX)) y \(Int(box.minY))…\(Int(box.maxY))")
            }
            return JSONValue.object(out).encoded(pretty: true)
        case "clipwatch":
            // 개발용: N초 동안 펫 창 가장자리에 그림이 닿는 순간을 모은다. 인자 없이 부르면 지금까지 기록
            if let s = arg.flatMap(Double.init) {
                clipLog = []
                clipWatchUntil = ProcessInfo.processInfo.systemUptime + s
                return "watching \(Int(s))s"
            }
            return JSONValue.array(clipLog).encoded(pretty: true)
        case "updatecheck":
            // 개발용: 설치 없이 업데이트 확인만 (인자 없이 시작, "result"로 결과 읽기)
            if arg == "result" { return updateCheckResult }
            updateCheckResult = "running"
            Task { @MainActor in
                do {
                    if let info = try await updater.check() { updateCheckResult = "newer \(info.version) \(info.url)" }
                    else { updateCheckResult = "latest \(Updater.currentVersion) (url: \(updater.config.updateURL ?? "-"))" }
                } catch { updateCheckResult = "error: \(error.localizedDescription)" }
            }
            return "started"
        case "cardsize":
            let f = card.panel.frame
            let p = hub.pending.first
            return JSONValue.object([
                "visible": .bool(card.isVisible), "w": .number(Double(f.width)), "h": .number(Double(f.height)),
                "typing": .bool(p?.typing ?? false), "left": .number(p.map { $0.deadline.timeIntervalSinceNow.rounded() } ?? -1),
                "key": .bool(card.panel.isKeyWindow), "responder": .string(card.panel.firstResponder.map { String(describing: type(of: $0)) } ?? "-"),
            ]).encoded()
        case "cardtype":
            // 개발용: 답장 입력을 시작한 것처럼 (마감 멈춤 확인)
            guard let p = hub.pending.first else { return "no pending" }
            hub.holdForTyping(p.id)
            return "ok"
        case "cardfocus":
            // 개발용: 카드의 첫 입력칸을 누른 것처럼 포커스만 준다 (글자는 안 침)
            func field(in v: NSView) -> NSTextField? {
                if let f = v as? NSTextField, f.isEditable { return f }
                for s in v.subviews { if let f = field(in: s) { return f } }
                return nil
            }
            guard card.isVisible, let root = card.panel.contentView, let f = field(in: root) else { return "no field" }
            card.panel.makeKey()
            return card.panel.makeFirstResponder(f) ? "focused" : "refused"
        case "cardterminal":
            // 개발용: 카드의 터미널 버튼을 누른 것처럼 (그 세션으로 이동 + 결정 넘기기)
            guard let p = hub.pending.first else { return "no pending" }
            passToTerminal(p)
            return "ok"
        case "chatlog":
            return JSONValue.array(chatModel.lines.map { .string(($0.fromPet ? "pet: " : "me: ") + $0.text) }).encoded()
        #if DEBUG
        // 디버그 빌드 전용: 첫 대기 요청에 응답. 릴리스에 있으면 에이전트가 스스로 승인할 수 있으므로 절대 넣지 않는다.
        case "respond":
            guard let p = hub.pending.first else { return "no pending" }
            let parts = (arg ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            let decision = HookReply.Decision(rawValue: parts.first ?? "") ?? .pass
            var reply = HookReply(id: p.id, decision: decision, message: parts.count > 1 ? parts[1] : nil)
            if decision == .answer, let q = p.event.questions.first, let label = q.options.first?.label {
                reply.answers = [q.question: parts.count > 1 ? parts[1] : label]
                reply.message = nil
            }
            respond(p, reply)
            return "responded \(decision.rawValue)"
        #endif
        default:
            return "unknown"
        }
    }

    private func displayScaleFor(_ identity: PetIdentity) -> CGFloat {
        CGFloat(config.size) * 1.65 * identity.scale
    }

    /// 펫마다 한 줄, 대표 포즈를 칸마다 그린 PNG
    private func renderSheet(ids: [String], name: String) -> String {
        let poses: [(PetAnim, Double, CGFloat)] = [
            (.idle, 0.5, 0), (.walk, 0, .pi / 2), (.walk, 0, .pi * 1.5), (.run, 0, .pi / 2), (.sit, 0.8, 0),
            (.sleep, 1, 0), (.wave, 0.3, 0), (.happy, 0.2, 0), (.eat, 0.5, 0), (.alert, 0.2, 0),
        ]
        let cell: CGFloat = 130, k: CGFloat = 2
        let w = Int(cell * CGFloat(poses.count) * k), h = Int(cell * CGFloat(ids.count) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "ctx fail" }
        ctx.scaleBy(x: k, y: k)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w) / k, height: CGFloat(h) / k))
        for (row, id) in ids.enumerated() {
            let identity = PetRoster.make(id: id, config: config)
            for (col, p) in poses.enumerated() {
                var pose = PetPose()
                pose.anim = p.0
                pose.clock = 0.6
                pose.animTime = p.1
                pose.walkPhase = p.2
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(col) * cell + cell / 2, y: CGFloat(ids.count - 1 - row) * cell + 16)
                ctx.scaleBy(x: 1.55 * identity.scale, y: 1.55 * identity.scale)
                identity.renderer.draw(pose, in: ctx)
                ctx.restoreGState()
            }
        }
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "image fail" }
        let dir = PawmitPaths.home.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        return url.path
    }

    /// 단위 좌표로 그린 그림의 실제 잉크 영역 (-120...120 × -40...160 범위에서 알파로 판정)
    private static func inkBounds(_ draw: (CGContext) -> Void) -> CGRect {
        let k: CGFloat = 2, ox: CGFloat = 120, oy: CGFloat = 40
        let w = Int(240 * k), h = Int(200 * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return .null }
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: ox, y: oy)
        draw(ctx)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .null }
        // 비트맵 행 0이 맨 위
        return CGRect(x: CGFloat(minX) / k - ox, y: CGFloat(h - 1 - maxY) / k - oy,
                      width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
    }

    /// clipwatch: 실제 펫 창을 그려 테두리 픽셀에 그림이 있으면 기록하고 처음 몇 장은 PNG로 남긴다
    private func checkClipping() {
        for (actor, b) in [(pet!, brain!)] + friends.map({ ($0.actor, $0.brain) }) where actor.window.isVisible {
            guard let view = actor.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let w = rep.pixelsWide, h = rep.pixelsHigh
            guard rep.bitsPerSample == 8, let data = rep.bitmapData else { continue }
            let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
            let alphaAt = rep.bitmapFormat.contains(.alphaFirst) ? 0 : spp - 1
            func ink(_ x: Int, _ y: Int) -> Bool { data[y * bpr + x * spp + alphaAt] > 12 }
            var edges: [String] = []
            if (0..<w).contains(where: { ink($0, 0) }) { edges.append("top") }
            if (0..<w).contains(where: { ink($0, h - 1) }) { edges.append("bottom") }
            if (0..<h).contains(where: { ink(0, $0) }) { edges.append("left") }
            if (0..<h).contains(where: { ink(w - 1, $0) }) { edges.append("right") }
            // 그림이 어느 화면에도 없는 곳(모니터 바깥·높이가 다른 모니터 사이 빈 곳)에 걸리면 거기서 잘린다
            let frame = actor.window.frame
            let kx = frame.width / CGFloat(w), ky = frame.height / CGFloat(h)
            var lost = 0
            for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: 0, to: w, by: 3) where ink(x, y) {
                    let p = CGPoint(x: frame.minX + CGFloat(x) * kx, y: frame.maxY - CGFloat(y) * ky)
                    if !NSScreen.screens.contains(where: { $0.frame.contains(p) }) { lost += 1 }
                }
            }
            if lost > 4 { edges.append("offscreen:\(lost)") }
            guard !edges.isEmpty, clipLog.count < 300 else { continue }
            let n = clipLog.count
            if n < 8, let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: PawmitPaths.home.appendingPathComponent("debug/clip-\(n).png"))
            }
            clipLog.append([
                "pet": .string(actor.identity.id), "anim": .string(actor.anim.rawValue), "edges": .string(edges.joined(separator: ",")),
                "motion": .string(actor.motion?.base ?? ""), "hop": .number(Double(actor.hop.rounded())),
                "plan": .string(b.planHistory.last ?? ""), "facing": .string(actor.facing == .left ? "left" : "right"),
                "scale": .number(Double(actor.visualScale)),
                "x": .number(Double(actor.position.x.rounded())), "y": .number(Double(actor.position.y.rounded())),
            ])
        }
    }

    /// 펫·말풍선·소품 창을 화면 배치 그대로 한 장의 PNG로 (화면 녹화 권한 없이 자기 창만)
    private func snapshot(name: String) -> String {
        var wins: [NSWindow] = [pet.window]
        if card.isVisible { wins.append(card.panel) }
        if speech.isVisible { wins.append(speech.panel) }
        if !name.hasPrefix("solo") { wins += friends.map { $0.actor.window } }
        wins += props.props.map { $0.panel }
        wins = wins.filter { $0.isVisible }
        guard let first = wins.first else { return "no windows" }
        let union = wins.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -12, dy: -12)
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "ctx fail" }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: union.size))
        for w in wins.sorted(by: { $0.level.rawValue < $1.level.rawValue }) {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let img = rep.cgImage {
                ctx.draw(img, in: CGRect(x: w.frame.minX - union.minX, y: w.frame.minY - union.minY, width: w.frame.width, height: w.frame.height))
            }
        }
        guard let image = ctx.makeImage() else { return "image fail" }
        let dir = PawmitPaths.home.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "snapshot" : safe).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "png fail" }
        try? data.write(to: url)
        return url.path
    }

    // MARK: - 저장

    private func saveState() {
        state.needs = brain.needs
        state.x = Double(pet.position.x)
        state.y = Double(pet.position.y)
        state.isHome = brain.isHome
        state.chatSessionID = chat.sessionID
        state.chatLog = chatModel.lines.suffix(60).map { ChatLogLine(fromPet: $0.fromPet, text: $0.text) }
        state.save()
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

extension Brain {
    /// 메뉴·채팅에서 이름으로 활동 실행
    func runNamed(_ name: String) async -> Bool {
        switch name {
        case "doodle", "trash", "chase", "dance", "friends", "clean": return await runActivity(name)
        default: return true
        }
    }

}
