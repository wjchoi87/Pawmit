import Foundation

/// `~/.pawmit/config.json`. 모르는 키는 무시하고 없는 키는 기본값을 쓴다(버전이 바뀌어도 안 깨지게).
public struct PawmitConfig: Codable, Equatable, Sendable {
    /// 메인 펫: 기본 펫 id(mongle, banban, tokki, nalda, bamtol, haedal, cat), `~/.pawmit/pets/<폴더>`,
    /// 또는 `codex:<id>` (`~/.codex/pets/<id>`)
    public var pet: String = "mongle"
    /// 펫 이름 직접 지정 (없으면 종족 기본 이름)
    public var petName: String? = nil
    /// 펫이 사용자를 부르는 호칭 (혼잣말·대화 AI·거절 메시지에 쓴다, 최대 20자)
    public var userTitle: String = PawmitConfig.defaultUserTitle
    public static let defaultUserTitle = "사용자"
    /// 같이 돌아다니는 친구 펫들 (hook 알림은 메인 펫만 받는다)
    public var friends: [String] = []
    /// 메인 펫 행동 seed 직접 지정 (같은 seed = 같은 성격·같은 행동 순서). 없으면 무작위로 정해 저장한다.
    public var behaviorSeed: UInt64? = nil
    /// 고양이(cat) 털색: cheese, gray, black, white, tuxedo
    public var catCoat: String = "cheese"
    public var size: Double = 1.0
    /*
     변경 전 정책: updateURL 기본값은 비어 있음(nil) — 사용자가 주소를 넣어야만 자동 업데이트가 켜졌다.
     변경 후 정책: 기본값은 공개 저장소 주소(GitHub Releases). 설정에 키가 없으면 기본 주소를 쓰고,
                  빈 문자열("")이면 사용자가 끈 것으로 보고 확인하지 않는다.
     변경 이유: 공개 저장소의 GitHub Releases로 배포하므로 설치만 하면 업데이트를 받게 하려고.
     영향 범위: config.json에 updateURL이 없는 모든 사용자(시작 20초 뒤·주 1회 GitHub API 조회).
                설정에서 주소를 지우면 ""로 저장돼 계속 꺼진 상태로 남는다.
     */
    /// 자동 업데이트 주소: GitHub 저장소 주소 또는 update.json URL. "" = 끔
    public var updateURL: String? = PawmitConfig.defaultUpdateURL
    public static let defaultUpdateURL = "https://github.com/wjchoi87/Pawmit"
    /// 말풍선 글씨 크기 배율 (말풍선 폭도 같이 커진다)
    public var textScale: Double = 1.0
    /// 말풍선 글꼴: nil = 둥근 시스템 글꼴, "system" = 기본 시스템 글꼴, 그 외 = 설치된 글꼴 family 이름
    public var fontName: String? = nil
    /// hook 알림 본문 글씨 (작업 끝 메시지·알림·계획·승인 설명)
    public var hookText = MessageText(size: 13)
    /// 펫과 나누는 대화 글씨
    public var chatText = MessageText(size: 12)
    public var speed: Double = 1.0
    /// smooth(움직임 24fps) / balanced(18fps) / saver(10fps) — 가만히·잘 때는 더 낮다
    public var performance: String = "balanced"
    /// CPU→더위, RAM→느려짐, 디스크→통통 (시스템 상태를 펫 모습에 반영)
    public var systemReactive: Bool = true
    /// 가끔 시스템 상태를 알려주기 (분 단위 간격, 0이면 끔)
    public var statusReportMinutes: Double = 45
    /// free: 화면 어디든 / ground: 화면 아래쪽만
    public var roam: String = "free"
    public var doodles: Bool = true
    /// overlay: 모든 창 위(클릭은 통과) / desktop: 바탕화면 층(앱 창 뒤)
    public var doodleLayer: String = "overlay"
    /// 낙서가 남아 있는 시간(초, 10…60). 점점 흐려지다가 지워진다.
    public var doodleSeconds: Double = 60
    public var trashRummage: Bool = true
    public var sounds: Bool = true
    /// 에이전트 작업이 끝났을 때 답장을 기다리는 시간(초). 0이면 답장 기능 끔.
    public var stopReplySeconds: Double = 30
    /// 승인 말풍선 대기 시간(초). 지나면 터미널 프롬프트로 넘긴다. hook timeout(600)보다 작아야 한다.
    public var permissionTimeoutSeconds: Double = 570
    /// 방해 금지: 말풍선 대신 바로 터미널로 넘긴다
    public var quietMode: Bool = false
    /// Copilot·Droid처럼 모든 도구에 hook이 오는 에이전트에서 읽기 전용 도구는 묻지 않는다
    public var readonlyPassthrough: Bool = true
    /// Cursor 셸·MCP 명령 승인을 펫에서 받기 (켜면 Cursor의 모든 셸 명령이 펫을 거친다)
    public var cursorShellApproval: Bool = false
    /// Droid에서 펫이 승인할 도구
    public var droidInterceptTools: [String] = ["Execute", "Edit", "Create", "ApplyPatch", "MultiEdit"]
    public var chat: ChatConfig = ChatConfig()
    public var shortcuts: Shortcuts = Shortcuts()
    /// 펫별 스타일(성격·말투·색). 키는 펫 id. 메이커 펫의 pet.json style보다 우선한다.
    public var petStyles: [String: PetStyle] = [:]
    /// 표시 언어: ko / en. 값이 없거나 예전 값(system)이면 시스템 언어로 정한다. 바꾸면 바로 적용된다.
    public var language: String = AppLanguage.systemDefault.rawValue

    /// 말풍선 본문 글씨 설정 (hook 알림·대화 각각)
    public struct MessageText: Codable, Equatable, Sendable {
        /// nil = 말풍선 글꼴을 따름, "rounded" = 둥근 시스템, "system" = 기본 시스템, "mono" = 고정폭, 그 외 = 설치된 글꼴 family
        public var fontName: String? = nil
        /// 글씨 크기(pt, 10…20). 말풍선 글씨 크기 배율이 한 번 더 곱해진다
        public var size: Double = 13
        /// 마크다운(굵게·목록·코드·표·제목)으로 그리기
        public var markdown: Bool = true

        public init(fontName: String? = nil, size: Double = 13, markdown: Bool = true) {
            self.fontName = fontName
            self.size = size
            self.markdown = markdown
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
            size = min(20, max(10, (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 13))
            markdown = (try? c.decodeIfPresent(Bool.self, forKey: .markdown)) ?? true
        }
    }

    /// 전역 단축키 ("ctrl+opt+y" 형식). 승인류 단축키는 요청이 떠 있을 때만 잡는다.
    public struct Shortcuts: Codable, Equatable, Sendable {
        public var enabled = true
        public var allow = "ctrl+opt+y"
        public var deny = "ctrl+opt+n"
        public var always = "ctrl+opt+a"
        public var terminal = "ctrl+opt+t"
        /// 말풍선 열기 (대기 요청이 있으면 그 카드, 없으면 채팅)
        public var open = "ctrl+opt+p"
        /// 질문 선택지 번호 앞에 붙는 조합 (ctrl+opt+1 …)
        public var optionPrefix = "ctrl+opt"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Shortcuts()
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
            allow = (try? c.decodeIfPresent(String.self, forKey: .allow)) ?? d.allow
            deny = (try? c.decodeIfPresent(String.self, forKey: .deny)) ?? d.deny
            always = (try? c.decodeIfPresent(String.self, forKey: .always)) ?? d.always
            terminal = (try? c.decodeIfPresent(String.self, forKey: .terminal)) ?? d.terminal
            open = (try? c.decodeIfPresent(String.self, forKey: .open)) ?? d.open
            optionPrefix = (try? c.decodeIfPresent(String.self, forKey: .optionPrefix)) ?? d.optionPrefix
        }
    }

    public struct ChatConfig: Codable, Equatable, Sendable {
        /// 대화 provider id: auto(claude CLI → codex CLI), off, claude-cli·codex-cli·gemini-cli, 내장 API(anthropic·openai …),
        /// custom:<id>. 예전 값 claude·codex도 읽는다. 목록은 ChatProviders.
        public var provider: String = "auto"
        /// Claude CLI 모델 (예전 설정 호환 — 지금은 models["claude-cli"]가 우선)
        public var model: String = "haiku"
        /// 실행 파일 경로 직접 지정 (GUI 앱은 PATH가 짧아서 못 찾을 때)
        public var claudePath: String? = nil
        public var codexPath: String? = nil
        public var geminiPath: String? = nil
        /// Codex로 대화할 때 모델 (예전 설정 호환 — 지금은 models["codex-cli"]가 우선)
        public var codexModel: String? = nil
        /// provider id → 고른 모델
        public var models: [String: String] = [:]
        /// 사용자가 붙인 provider (API 키는 키체인에)
        public var customProviders: [CustomChatProvider] = []

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ChatConfig()
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
            codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath)
            geminiPath = try? c.decodeIfPresent(String.self, forKey: .geminiPath)
            codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel)
            models = (try? c.decodeIfPresent([String: String].self, forKey: .models)) ?? [:]
            customProviders = (try? c.decodeIfPresent([CustomChatProvider].self, forKey: .customProviders)) ?? []
        }

        /// 예전 값(claude·codex)을 지금 id로
        public var providerID: String {
            switch provider {
            case "claude": return "claude-cli"
            case "codex": return "codex-cli"
            default: return provider
            }
        }

        /// provider의 모델 (고른 값 → 예전 설정 → provider 기본값)
        public func model(for id: String) -> String? {
            if let m = models[id], !m.isEmpty { return m }
            switch id {
            case "claude-cli": return model
            case "codex-cli": return codexModel
            default: return ChatProviders.provider(id, custom: customProviders)?.defaultModel
            }
        }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PawmitConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        pet = v(.pet, d.pet)
        petName = try? c.decodeIfPresent(String.self, forKey: .petName)
        userTitle = Self.cleanTitle(v(.userTitle, d.userTitle))
        friends = v(.friends, d.friends)
        behaviorSeed = try? c.decodeIfPresent(UInt64.self, forKey: .behaviorSeed)
        catCoat = v(.catCoat, d.catCoat)
        size = v(.size, d.size)
        // 키가 없거나 null이면 기본 주소, 빈 문자열이면 끈 상태 그대로
        updateURL = (try? c.decodeIfPresent(String.self, forKey: .updateURL)) ?? d.updateURL
        textScale = v(.textScale, d.textScale)
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        hookText = v(.hookText, d.hookText)
        chatText = v(.chatText, d.chatText)
        speed = v(.speed, d.speed)
        performance = v(.performance, d.performance)
        systemReactive = v(.systemReactive, d.systemReactive)
        statusReportMinutes = v(.statusReportMinutes, d.statusReportMinutes)
        roam = v(.roam, d.roam)
        doodles = v(.doodles, d.doodles)
        doodleLayer = v(.doodleLayer, d.doodleLayer)
        doodleSeconds = min(60, max(10, v(.doodleSeconds, d.doodleSeconds)))
        trashRummage = v(.trashRummage, d.trashRummage)
        sounds = v(.sounds, d.sounds)
        stopReplySeconds = v(.stopReplySeconds, d.stopReplySeconds)
        permissionTimeoutSeconds = v(.permissionTimeoutSeconds, d.permissionTimeoutSeconds)
        quietMode = v(.quietMode, d.quietMode)
        readonlyPassthrough = v(.readonlyPassthrough, d.readonlyPassthrough)
        cursorShellApproval = v(.cursorShellApproval, d.cursorShellApproval)
        droidInterceptTools = v(.droidInterceptTools, d.droidInterceptTools)
        chat = v(.chat, d.chat)
        shortcuts = v(.shortcuts, d.shortcuts)
        petStyles = v(.petStyles, d.petStyles)
        language = AppLanguage.from(config: v(.language, d.language)).rawValue
    }

    /// 호칭 정리: 줄바꿈 없이 한 줄, 앞뒤 공백 제거, 최대 20자. 비우면 기본 호칭
    public static func cleanTitle(_ raw: String) -> String {
        let one = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return one.isEmpty ? defaultUserTitle : String(one.prefix(20))
    }

    /// 화면·대사에 쓸 호칭 (기본값이면 현재 언어의 기본 호칭)
    public static func displayTitle(_ raw: String) -> String {
        let t = cleanTitle(raw)
        return t == defaultUserTitle ? localizedDefaultTitle : t
    }

    /// 현재 언어의 기본 호칭
    public static var localizedDefaultTitle: String { L10n.isKorean ? defaultUserTitle : "Buddy" }

    /// 혼잣말 문구 안의 `{user}`를 호칭으로
    public func addressingUser(_ text: String) -> String {
        text.replacingOccurrences(of: "{user}", with: Self.displayTitle(userTitle))
    }

    public static func load(from url: URL = PawmitPaths.config) -> PawmitConfig {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return PawmitConfig() }
        return (try? JSONDecoder().decode(PawmitConfig.self, from: data)) ?? PawmitConfig()
    }

    public func save(to url: URL = PawmitPaths.config) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
