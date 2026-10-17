import Foundation

/// 에이전트별 hook 설정 설치·제거.
///
/// 안전 규칙 (coucou의 strict read·백업, bezel의 idempotent merge·uninstall을 참고해 다시 작성):
/// - 설정 파일이 JSON으로 읽히지 않거나 `hooks`가 예상 밖 형태면 throw 하고 파일을 건드리지 않는다.
/// - 쓰기 전에 원본을 `~/.pawmit/backups/`에 복사하고, 임시 파일 → rename 으로 원자적으로 쓴다.
/// - Pawmit 항목은 command 안의 `.pawmit/bin/pawmit` 경로로만 식별한다. 다른 hook은 순서·내용을 그대로 둔다.
public enum HookInstaller {

    public enum Format: Equatable, Sendable {
        /// `{"hooks": {Event: [{matcher?, hooks: [{type, command, timeout}]}]}}`
        case nested(millis: Bool)
        /// Droid `hooks.json`: 이벤트가 최상위 키
        case topLevel
        /// Cursor `{"version":1,"hooks":{event:[{command,timeout}]}}`
        case cursor
        /// Pawmit 전용 파일 (Copilot hooks/*.json, OpenCode plugin) — 통째로 쓰고 지운다
        case ownedFile
        /// 자동 설치 불가 — 안내 문구만 (Kiro)
        case manual
        /// ZCode `~/.zcode/cli/config.json`: `{"hooks":{"enabled":true,"events":{Event:[{matcher?, hooks:[{type:"process", command, args, timeoutMs}]}]}}}`
        case zcode
    }

    public struct Spec: Equatable, Sendable {
        public var event: String
        public var matcher: String?
        public var timeout: Int
        public var async: Bool = false
        public var statusMessage: String? = nil
    }

    public struct Target: Sendable {
        public var agent: AgentKind
        public var file: URL
        public var format: Format
        public var specs: [Spec]
        /// 설치 후 사용자에게 알려야 할 것
        public var note: String?
        /// 에이전트가 설치돼 있어 보이는지 판단할 디렉토리
        public var detectDir: URL
        /// ownedFile/manual 형식의 전체 내용
        public var ownedContent: String?
    }

    public struct Plan: Sendable {
        public var target: Target
        public var install: Bool
        public var original: Data?
        /// nil이면 파일 삭제
        public var updated: Data?
        public var changes: [String]
        public var isNoop: Bool { original == updated }
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case unexpectedShape(String)
        case manual(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let p): return L10n.format("%@ 를 JSON으로 읽을 수 없어서 건드리지 않았어요.", p)
            case .unexpectedShape(let m): return m
            case .manual(let m): return m
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case installed, notInstalled, outdated, agentMissing, error(String)
    }

    // MARK: - 대상 정의

    public static func cliCommand(cliPath: String, agent: AgentKind, event: String) -> String {
        let quoted = cliPath.contains(" ") ? "'\(cliPath.replacingOccurrences(of: "'", with: "'\\''"))'" : cliPath
        return "\(quoted) hook \(agent.rawValue) \(event)"
    }

    public static func isPawmitCommand(_ command: String) -> Bool {
        command.contains(".pawmit/bin/pawmit")
    }

    public static func targets(config: PawmitConfig, cliPath: String = PawmitPaths.cliLink.path,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        // Stop hook 제한은 넉넉히(600초): 답장을 쓰는 동안 카운트다운이 멈추기 때문이다.
        // 답장이 없으면 앱이 답장 대기 시간 뒤 바로 넘기므로 실제로 기다리는 시간은 그대로다.
        let stopTimeout = config.stopReplySeconds > 0 ? 600 : 10
        func cmd(_ agent: AgentKind, _ event: String) -> String { cliCommand(cliPath: cliPath, agent: agent, event: event) }

        var list: [Target] = []

        list.append(Target(
            agent: .claude, file: home.appendingPathComponent(".claude/settings.json"), format: .nested(millis: false),
            specs: [
                Spec(event: "SessionStart", timeout: 10),
                Spec(event: "SessionEnd", timeout: 10),
                Spec(event: "UserPromptSubmit", timeout: 10),
                Spec(event: "Notification", timeout: 10),
                Spec(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode", timeout: 600),
                Spec(event: "PermissionRequest", timeout: 600),
                Spec(event: "PostToolUse", timeout: 10, async: true),
                Spec(event: "Stop", timeout: stopTimeout),
            ],
            note: nil, detectDir: home.appendingPathComponent(".claude")))

        list.append(Target(
            agent: .codex, file: home.appendingPathComponent(".codex/hooks.json"), format: .nested(millis: false),
            specs: [
                Spec(event: "SessionStart", timeout: 10),
                Spec(event: "UserPromptSubmit", timeout: 10),
                Spec(event: "PermissionRequest", timeout: 600, statusMessage: L10n.t("Pawmit 펫이 대답을 기다리는 중…")),
                Spec(event: "PostToolUse", timeout: 10, async: true),
                Spec(event: "Stop", timeout: stopTimeout),
                Spec(event: "SessionEnd", timeout: 3),
            ],
            note: L10n.t("Codex는 새 hook을 trust해야 실행돼요. Codex에서 /hooks 를 열어 Pawmit hook을 승인해 주세요."),
            detectDir: home.appendingPathComponent(".codex")))

        list.append(Target(
            agent: .gemini, file: home.appendingPathComponent(".gemini/settings.json"), format: .nested(millis: true),
            specs: [
                Spec(event: "SessionStart", timeout: 10_000),
                Spec(event: "SessionEnd", timeout: 10_000),
                Spec(event: "BeforeAgent", timeout: 5_000),
                Spec(event: "AfterAgent", timeout: 5_000),
                Spec(event: "AfterTool", matcher: "*", timeout: 5_000),
                Spec(event: "Notification", timeout: 5_000),
            ],
            note: L10n.t("Gemini CLI는 hook으로 승인을 대신할 수 없어서 상태·알림만 받아요."),
            detectDir: home.appendingPathComponent(".gemini")))

        list.append(Target(
            agent: .qwen, file: home.appendingPathComponent(".qwen/settings.json"), format: .nested(millis: false),
            specs: [
                Spec(event: "SessionStart", timeout: 10),
                Spec(event: "UserPromptSubmit", timeout: 10),
                Spec(event: "PermissionRequest", timeout: 600),
                Spec(event: "PostToolUse", timeout: 10, async: true),
                Spec(event: "Notification", timeout: 10),
                Spec(event: "Stop", timeout: stopTimeout),
                Spec(event: "SessionEnd", timeout: 10),
            ],
            note: nil, detectDir: home.appendingPathComponent(".qwen")))

        list.append(Target(
            agent: .droid, file: home.appendingPathComponent(".factory/hooks.json"), format: .topLevel,
            specs: [
                Spec(event: "SessionStart", timeout: 10),
                Spec(event: "UserPromptSubmit", timeout: 10),
                Spec(event: "PreToolUse", matcher: config.droidInterceptTools.joined(separator: "|"), timeout: 600),
                Spec(event: "Notification", timeout: 10),
                Spec(event: "Stop", timeout: stopTimeout),
                Spec(event: "SessionEnd", timeout: 10),
            ],
            note: nil, detectDir: home.appendingPathComponent(".factory")))

        var cursorSpecs = [
            Spec(event: "sessionStart", timeout: 10),
            Spec(event: "sessionEnd", timeout: 10),
            Spec(event: "beforeSubmitPrompt", timeout: 10),
            Spec(event: "afterFileEdit", timeout: 10),
            Spec(event: "stop", timeout: stopTimeout),
        ]
        if config.cursorShellApproval {
            cursorSpecs.append(Spec(event: "beforeShellExecution", timeout: 600))
            cursorSpecs.append(Spec(event: "beforeMCPExecution", timeout: 600))
        }
        list.append(Target(
            agent: .cursor, file: home.appendingPathComponent(".cursor/hooks.json"), format: .cursor, specs: cursorSpecs,
            note: config.cursorShellApproval ? nil : L10n.t("Cursor 셸 명령 승인은 설정(cursorShellApproval)을 켜야 펫으로 와요."),
            detectDir: home.appendingPathComponent(".cursor")))

        let copilotEvents: [(String, Int)] = [("sessionStart", 10), ("userPromptSubmitted", 10), ("permissionRequest", 600),
                                              ("postToolUse", 10), ("agentStop", 10), ("notification", 10), ("sessionEnd", 5)]
        var copilotHooks: [String: JSONValue] = [:]
        for (ev, t) in copilotEvents {
            copilotHooks[ev] = .array([.object(["type": "command", "bash": .string(cmd(.copilot, ev)), "timeoutSec": .number(Double(t))])])
        }
        let copilotFile = JSONValue.object(["version": 1, "hooks": .object(copilotHooks)]).encoded(pretty: true) + "\n"
        list.append(Target(
            agent: .copilot, file: home.appendingPathComponent(".copilot/hooks/pawmit.json"), format: .ownedFile,
            specs: copilotEvents.map { Spec(event: $0.0, timeout: $0.1) }, note: nil,
            detectDir: home.appendingPathComponent(".copilot"), ownedContent: copilotFile))

        list.append(Target(
            agent: .opencode, file: home.appendingPathComponent(".config/opencode/plugins/pawmit.js"), format: .ownedFile,
            specs: [], note: L10n.t("OpenCode는 상태·알림만 받아요 (권한 응답 API가 문서화되지 않음)."),
            detectDir: home.appendingPathComponent(".config/opencode"), ownedContent: openCodePlugin(cliPath: cliPath)))

        list.append(Target(
            agent: .zcode, file: home.appendingPathComponent(".zcode/cli/config.json"), format: .zcode,
            specs: [
                Spec(event: "SessionStart", timeout: 10),
                Spec(event: "UserPromptSubmit", timeout: 10),
                Spec(event: "PermissionRequest", timeout: 600),
                Spec(event: "PostToolUse", timeout: 10),
                Spec(event: "Stop", timeout: stopTimeout),
            ],
            note: L10n.t("ZCode를 다시 시작하면 적용돼요. (사용자 설정 ~/.zcode/cli/config.json의 hooks에 들어가요)"),
            detectDir: home.appendingPathComponent(".zcode")))

        let kiroSnippet = L10n.t("Kiro CLI 2.x는 에이전트 설정(~/.kiro/agents/<이름>.json)의 \"hooks\"에 직접 넣어야 해요:") + "\n" + """
        "hooks": {
          "agentSpawn": [{"command": "\(cmd(.kiro, "agentSpawn"))"}],
          "userPromptSubmit": [{"command": "\(cmd(.kiro, "userPromptSubmit"))"}],
          "postToolUse": [{"command": "\(cmd(.kiro, "postToolUse"))"}],
          "stop": [{"command": "\(cmd(.kiro, "stop"))"}]
        }
        """
        list.append(Target(
            agent: .kiro, file: home.appendingPathComponent(".kiro/agents"), format: .manual, specs: [],
            note: kiroSnippet, detectDir: home.appendingPathComponent(".kiro"), ownedContent: kiroSnippet))

        return list
    }

    // MARK: - 순수 merge / strip

    static func hookEntry(_ spec: Spec, agent: AgentKind, cliPath: String, format: Format = .nested(millis: false)) -> JSONValue {
        if format == .zcode {
            // ZCode process hook: 셸 없이 실행 파일 + 인자, 시간은 밀리초
            return .object([
                "type": "process", "command": .string(cliPath),
                "args": .array(["hook", .string(agent.rawValue), .string(spec.event)]),
                "timeoutMs": .number(Double(spec.timeout * 1000)),
            ])
        }
        var o: [String: JSONValue] = [
            "type": "command",
            "command": .string(cliCommand(cliPath: cliPath, agent: agent, event: spec.event)),
            "timeout": .number(Double(spec.timeout)),
        ]
        if spec.async { o["async"] = true }
        if let m = spec.statusMessage { o["statusMessage"] = .string(m) }
        return .object(o)
    }

    /// `{matcher?, hooks:[...]}` 그룹 배열에서 Pawmit 항목만 뺀다. 빈 그룹은 지운다.
    static func stripGroups(_ groups: [JSONValue]) -> [JSONValue] {
        groups.compactMap { group in
            guard var obj = group.object, let inner = obj["hooks"]?.array else { return group }
            let kept = inner.filter { !isPawmitCommand($0["command"]?.string ?? "") }
            if kept.count == inner.count { return group }
            if kept.isEmpty { return nil }
            obj["hooks"] = .array(kept)
            return .object(obj)
        }
    }

    static func stripFlat(_ entries: [JSONValue]) -> [JSONValue] {
        entries.filter { !isPawmitCommand($0["command"]?.string ?? $0["bash"]?.string ?? "") }
    }

    /// hooks 맵(이벤트 → 배열)에 Pawmit 항목을 다시 넣는다. install=false면 빼기만 한다.
    static func rebuildHooksMap(_ hooks: [String: JSONValue], target: Target, cliPath: String, install: Bool,
                                path: String) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let flat = target.format == .cursor
        for (event, value) in hooks {
            guard let list = value.array else {
                // 배열이 아닌 값은 Pawmit 것이 아니므로 그대로 둔다 (Droid hooks.json의 다른 최상위 키 등)
                result[event] = value
                continue
            }
            let stripped = flat ? stripFlat(list) : stripGroups(list)
            if !stripped.isEmpty || stripped.count == list.count { result[event] = .array(stripped) }
        }
        guard install else { return result }
        for spec in target.specs {
            var list = result[spec.event]?.array ?? []
            if let existing = result[spec.event], existing.array == nil {
                throw InstallError.unexpectedShape(L10n.format("%@: hooks[%@] 형태가 예상과 달라서 건드리지 않았어요.", path, spec.event))
            }
            if flat {
                var o: [String: JSONValue] = ["command": .string(cliCommand(cliPath: cliPath, agent: target.agent, event: spec.event))]
                o["timeout"] = .number(Double(spec.timeout))
                list.append(.object(o))
            } else {
                var group: [String: JSONValue] = ["hooks": .array([hookEntry(spec, agent: target.agent, cliPath: cliPath, format: target.format)])]
                if let m = spec.matcher { group["matcher"] = .string(m) }
                list.append(.object(group))
            }
            result[spec.event] = .array(list)
        }
        return result
    }

    /// 설정 파일 루트 JSON에 적용 (순수 함수, 테스트 대상)
    public static func apply(to root: JSONValue?, target: Target, cliPath: String, install: Bool) throws -> JSONValue {
        let path = target.file.path
        var obj = root?.object ?? [:]
        switch target.format {
        case .nested, .cursor:
            if let h = obj["hooks"], h.object == nil {
                throw InstallError.unexpectedShape(L10n.format("%@: \"hooks\" 형태가 예상과 달라서 건드리지 않았어요.", path))
            }
            let hooks = try rebuildHooksMap(obj["hooks"]?.object ?? [:], target: target, cliPath: cliPath, install: install, path: path)
            if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = .object(hooks) }
            if target.format == .cursor, install, obj["version"] == nil { obj["version"] = 1 }
        case .topLevel:
            obj = try rebuildHooksMap(obj, target: target, cliPath: cliPath, install: install, path: path)
        case .zcode:
            if let h = obj["hooks"], h.object == nil {
                throw InstallError.unexpectedShape(L10n.format("%@: \"hooks\" 형태가 예상과 달라서 건드리지 않았어요.", path))
            }
            var hooks = obj["hooks"]?.object ?? [:]
            if let ev = hooks["events"], ev.object == nil {
                throw InstallError.unexpectedShape(L10n.format("%@: \"hooks.events\" 형태가 예상과 달라서 건드리지 않았어요.", path))
            }
            let events = try rebuildHooksMap(hooks["events"]?.object ?? [:], target: target, cliPath: cliPath, install: install, path: path)
            if events.isEmpty { hooks.removeValue(forKey: "events") } else { hooks["events"] = .object(events) }
            // hook이 꺼져 있으면 실행되지 않으므로 설치할 때 켠다 (제거할 때는 사용자 값 그대로)
            if install { hooks["enabled"] = true }
            if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = .object(hooks) }
        case .ownedFile, .manual:
            break
        }
        return .object(obj)
    }

    // MARK: - 파일 IO

    public static func makePlan(_ target: Target, install: Bool, cliPath: String = PawmitPaths.cliLink.path) throws -> Plan {
        let fm = FileManager.default
        let original = fm.fileExists(atPath: target.file.path) ? try Data(contentsOf: target.file) : nil
        switch target.format {
        case .manual:
            throw InstallError.manual(target.ownedContent ?? L10n.t("수동 설정이 필요해요."))
        case .ownedFile:
            let updated = install ? target.ownedContent.map { Data($0.utf8) } : nil
            var changes: [String] = []
            if install { changes.append(original == nil ? L10n.format("+ %@ 새로 만듦", target.file.path) : L10n.format("~ %@ 덮어씀", target.file.path)) }
            else if original != nil { changes.append(L10n.format("- %@ 삭제", target.file.path)) }
            return Plan(target: target, install: install, original: original, updated: install ? updated : nil, changes: changes)
        case .nested, .topLevel, .cursor, .zcode:
            var root: JSONValue? = nil
            if let original, !original.isEmpty {
                guard let parsed = JSONValue.parse(original), parsed.object != nil else {
                    throw InstallError.unreadable(target.file.path)
                }
                root = parsed
            }
            if !install, root == nil {
                return Plan(target: target, install: false, original: original, updated: original, changes: [])
            }
            let newRoot = try apply(to: root, target: target, cliPath: cliPath, install: install)
            let updated = Data((newRoot.encoded(pretty: true) + "\n").utf8)
            let before = Set(pawmitEntries(in: root, format: target.format))
            let after = Set(pawmitEntries(in: newRoot, format: target.format))
            var changes = after.subtracting(before).sorted().map { "+ \($0)" }
            changes += before.subtracting(after).sorted().map { "- \($0)" }
            if changes.isEmpty, original.map({ JSONValue.parse($0) }) != newRoot { changes.append(L10n.t("~ 형식 정리")) }
            let noop = changes.isEmpty
            return Plan(target: target, install: install, original: original, updated: noop ? original : updated, changes: changes)
        }
    }

    /// Pawmit 항목을 "Event[matcher] → command" 문자열로 나열 (변경 미리보기용)
    static func pawmitEntries(in root: JSONValue?, format: Format) -> [String] {
        guard let root else { return [] }
        let hooks: [String: JSONValue]
        switch format {
        case .topLevel: hooks = root.object ?? [:]
        case .zcode: hooks = root["hooks"]?["events"]?.object ?? [:]
        default: hooks = root["hooks"]?.object ?? [:]
        }
        var out: [String] = []
        for (event, value) in hooks {
            for item in value.array ?? [] {
                if let inner = item["hooks"]?.array {
                    for h in inner where isPawmitCommand(h["command"]?.string ?? "") {
                        let m = item["matcher"]?.string.map { "[\($0)]" } ?? ""
                        let extra = (h["async"]?.bool == true ? " async" : "") + " timeout=\(h["timeout"]?.string ?? h["timeoutMs"].flatMap { $0.string.map { "\($0)ms" } } ?? "-")"
                        out.append("\(event)\(m)\(extra)")
                    }
                } else if isPawmitCommand(item["command"]?.string ?? item["bash"]?.string ?? "") {
                    out.append("\(event) timeout=\(item["timeout"]?.string ?? item["timeoutSec"]?.string ?? "-")")
                }
            }
        }
        return out
    }

    /// 백업 후 원자적으로 쓴다. 반환값은 백업 파일 경로.
    @discardableResult
    public static func execute(_ plan: Plan, backupDir: URL = PawmitPaths.backups) throws -> URL? {
        guard !plan.isNoop else { return nil }
        let fm = FileManager.default
        let file = plan.target.file
        // 계획을 세운 뒤 파일이 바뀌었으면 덮어쓰지 않는다
        let current = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == plan.original else {
            throw InstallError.unexpectedShape(L10n.format("%@ 가 그 사이에 바뀌었어요. 다시 시도해 주세요.", file.path))
        }
        var backup: URL?
        if let original = plan.original {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let url = backupDir.appendingPathComponent("\(plan.target.agent.rawValue)-\(stamp)-\(file.lastPathComponent)")
            try original.write(to: url, options: .atomic)
            backup = url
        }
        if let updated = plan.updated {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: file, options: .atomic)
        } else if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
        return backup
    }

    public static func status(_ target: Target, cliPath: String = PawmitPaths.cliLink.path) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.detectDir.path) else { return .agentMissing }
        switch target.format {
        case .manual:
            return .notInstalled
        case .ownedFile:
            guard let data = fm.contents(atPath: target.file.path) else { return .notInstalled }
            return String(decoding: data, as: UTF8.self) == target.ownedContent ? .installed : .outdated
        default:
            guard let data = fm.contents(atPath: target.file.path), !data.isEmpty else { return .notInstalled }
            guard let root = JSONValue.parse(data) else { return .error(L10n.t("JSON 아님")) }
            let existing = pawmitEntries(in: root, format: target.format)
            if existing.isEmpty { return .notInstalled }
            guard let wanted = try? apply(to: root, target: target, cliPath: cliPath, install: true) else { return .error(L10n.t("형식 오류")) }
            return Set(pawmitEntries(in: wanted, format: target.format)) == Set(existing) && wanted == root ? .installed : .outdated
        }
    }

    // MARK: - OpenCode plugin

    static func openCodePlugin(cliPath: String) -> String {
        let escaped = cliPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        // Pawmit plugin for OpenCode — generated by Pawmit. 이벤트를 펫에게 보낸다 (fire-and-forget, 절대 막지 않음).
        import { spawn } from 'node:child_process';

        const PAWMIT = '\(escaped)';
        const EVENT_MAP = {
          'session.created': 'SessionStart',
          'session.idle': 'Stop',
          'session.error': 'StopFailure',
          'session.deleted': 'SessionEnd',
          'permission.asked': 'Notification',
          'permission.updated': 'Notification',
        };

        function forward(event, payload) {
          try {
            const p = spawn(PAWMIT, ['hook', 'opencode', event], { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
            p.on('error', () => {});
            p.stdin.on('error', () => {});
            p.stdin.end(JSON.stringify({ hook_event_name: event, ...payload }) + '\\n');
            p.unref();
          } catch (_) {}
        }

        export const PawmitPlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            const name = EVENT_MAP[event.type];
            if (!name) return;
            const props = event.properties || {};
            const payload = {
              session_id: props.sessionID || props.session_id || props.info?.id || '',
              cwd: props.directory || directory || '',
            };
            if (name === 'Notification') {
              payload.notification_type = 'permission_prompt';
              payload.message = props.title || props.message || 'OpenCode가 승인을 기다리고 있어요';
            }
            if (typeof props.tool === 'string') payload.tool_name = props.tool;
            forward(name, payload);
          },
          'tool.execute.after': async (input) => {
            forward('PostToolUse', { session_id: input.sessionID || '', cwd: directory || '', tool_name: input.tool || '' });
          },
        });

        """
    }
}
