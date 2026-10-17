import Foundation
import PawmitCore
#if canImport(Darwin)
import Darwin
#endif

// pawmit — 에이전트 hook 중계 + 설치 도구
//
//   pawmit hook <agent> [event]      에이전트 hook에서 호출 (stdin JSON → Pawmit.app → stdout 결정)
//   pawmit notify [--title T] <msg>  펫에게 알림 보내기 (빌드 끝, 배포 완료 등)
//   pawmit say <msg>                 펫이 말하게 하기
//   pawmit install [agent...|all] [--dry-run] [--yes]
//   pawmit uninstall [agent...|all] [--dry-run] [--yes]
//   pawmit status

let args = Array(CommandLine.arguments.dropFirst())

func stderr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// CLI 문구는 앱 번들 밖(~/.pawmit/bin)에서도 실행되므로 .strings 테이블 대신 코드 분기를 쓴다.
func msg(_ ko: String, _ en: String) -> String { L10n.isKorean ? ko : en }
func msgF(_ ko: String, _ en: String, _ args: CVarArg...) -> String {
    String(format: L10n.isKorean ? ko : en, arguments: args)
}

func readStdin(limit: Int, timeout: TimeInterval) -> Data {
    // 에이전트가 stdin을 닫지 않는 경우를 대비해 poll로 시간 제한을 둔다
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    let deadline = Date().addingTimeInterval(timeout)
    if isatty(STDIN_FILENO) != 0 { return data }
    while data.count < limit {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        let pr = poll(&pfd, 1, Int32(remaining * 1000))
        if pr <= 0 { break }
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    return data
}

func emit(_ output: String?) {
    guard let output, !output.isEmpty else { return }
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
}

func terminalEnv() -> [String: String] {
    let env = ProcessInfo.processInfo.environment
    var out: [String: String] = [:]
    for key in HookEnvelope.forwardedEnvKeys { if let v = env[key], !v.isEmpty { out[key] = v } }
    return out
}

/// 제어 터미널 tty (bezel TerminalHintExtractor 방식: hook stdin은 파이프라 /dev/tty를 직접 연다)
func controllingTTY() -> String? {
    let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [CChar](repeating: 0, count: 256)
    guard ttyname_r(fd, &buf, buf.count) == 0 else { return nil }
    let s = String(cString: buf)
    return s.isEmpty ? nil : s
}

// MARK: - hook

func runHook(_ rest: [String]) -> Int32 {
    guard let agentArg = rest.first else {
        stderr("usage: pawmit hook <agent> [event]")
        return 0
    }
    let agent = AgentKind(loose: agentArg)
    // 펫 채팅용으로 띄운 에이전트가 다시 펫을 부르지 않게
    if ProcessInfo.processInfo.environment["PAWMIT_CHAT"] == "1" {
        emit(AgentAdapters.fallbackOutput(agent: agent, event: rest.count > 1 ? rest[1] : ""))
        return 0
    }
    let input = readStdin(limit: Wire.maxMessageBytes, timeout: 5)
    var payload = JSONValue.parse(input) ?? .object([:])
    if payload.object == nil { payload = .object(["raw": .string(String(decoding: input, as: UTF8.self))]) }
    let event = (rest.count > 1 ? rest[1] : nil) ?? payload["hook_event_name"]?.string ?? "Unknown"

    let interactive = AgentAdapters.isInteractiveCandidate(agent: agent, event: event, payload: payload)
    let config = PawmitConfig.load()
    // 앱이 응답을 못 줘도 에이전트 hook timeout(600초)보다 먼저 끝나야 기본 프롬프트로 넘어간다
    let wait: Double = interactive ? max(config.permissionTimeoutSeconds, config.stopReplySeconds) + 15 : 3

    let envelope = HookEnvelope(agent: agent.rawValue, event: event, expectsReply: interactive,
                                pid: getpid(), ppid: getppid(), tty: controllingTTY(), env: terminalEnv(),
                                cwd: FileManager.default.currentDirectoryPath, payload: payload, waitSeconds: wait)

    let client = UnixSocketClient()
    do {
        try client.connect(path: PawmitPaths.socket.path)
        try client.send(try WireCodec.encodeLine(envelope))
    } catch {
        // 앱이 꺼져 있음 → 에이전트 기본 동작
        emit(AgentAdapters.fallbackOutput(agent: agent, event: event))
        return 0
    }
    defer { client.close() }

    guard interactive else {
        // 상태 이벤트: 앱이 읽고 닫을 때까지 아주 잠깐만 기다린다
        _ = try? client.readLine(timeout: 0.5)
        emit(AgentAdapters.fallbackOutput(agent: agent, event: event))
        return 0
    }

    do {
        let line = try client.readLine(timeout: wait)
        let reply = try WireCodec.decode(HookReply.self, line: line)
        emit(AgentAdapters.render(reply, envelope: envelope))
    } catch {
        emit(AgentAdapters.fallbackOutput(agent: agent, event: event))
    }
    return 0
}

// MARK: - notify / say

func runNotify(_ rest: [String], speech: Bool) -> Int32 {
    var title: String?
    var parts: [String] = []
    var i = 0
    while i < rest.count {
        if rest[i] == "--title", i + 1 < rest.count { title = rest[i + 1]; i += 2; continue }
        parts.append(rest[i]); i += 1
    }
    var message = parts.joined(separator: " ")
    if message.isEmpty {
        message = String(decoding: readStdin(limit: 64 * 1024, timeout: 2), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !message.isEmpty else {
        stderr("usage: pawmit \(speech ? "say" : "notify") [--title T] <message>")
        return 2
    }
    var payload: [String: JSONValue] = ["hook_event_name": "Custom", "message": .string(message), "speech": .bool(speech)]
    if let title { payload["title"] = .string(title) }
    let envelope = HookEnvelope(agent: AgentKind.generic.rawValue, event: "Custom", expectsReply: false,
                                pid: getpid(), ppid: getppid(), tty: controllingTTY(), env: terminalEnv(),
                                cwd: FileManager.default.currentDirectoryPath, payload: .object(payload), waitSeconds: 1)
    let client = UnixSocketClient()
    do {
        try client.connect(path: PawmitPaths.socket.path)
        try client.send(try WireCodec.encodeLine(envelope))
        _ = try? client.readLine(timeout: 0.5)
        client.close()
        return 0
    } catch {
        stderr(msg("Pawmit 앱이 실행 중이 아니에요.", "The Pawmit app is not running."))
        return 1
    }
}

// MARK: - debug (개발·검증용)

func runDebug(_ rest: [String]) -> Int32 {
    guard let cmd = rest.first else {
        stderr("usage: pawmit debug state|snapshot|action <name>|say <text>")
        return 2
    }
    let arg = rest.dropFirst().joined(separator: " ")
    let envelope = HookEnvelope(agent: "debug", event: cmd, expectsReply: true, pid: getpid(), ppid: getppid(), tty: nil,
                                env: [:], cwd: nil, payload: .object(["arg": .string(arg)]), waitSeconds: 10)
    let client = UnixSocketClient()
    do {
        try client.connect(path: PawmitPaths.socket.path)
        try client.send(try WireCodec.encodeLine(envelope))
        let reply = try WireCodec.decode(HookReply.self, line: try client.readLine(timeout: 10))
        print(reply.message ?? "")
        return 0
    } catch {
        stderr(msgF("Pawmit 앱에 연결하지 못했어요: %@", "Could not reach the Pawmit app: %@", error.localizedDescription))
        return 1
    }
}

/// 앱 버전: 앱 번들 안(Contents/MacOS/pawmit-cli)이면 번들 Info.plist, 설치본(~/.pawmit/bin)이면 앱이 둔 VERSION 파일
func cliVersion() -> String {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
    let dir = exe.deletingLastPathComponent()
    let plist = dir.deletingLastPathComponent().appendingPathComponent("Info.plist")
    if let v = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String { return v }
    let file = dir.appendingPathComponent("VERSION")
    return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
}

// MARK: - install / uninstall / status

func selectTargets(_ names: [String]) -> [HookInstaller.Target] {
    let all = HookInstaller.targets(config: PawmitConfig.load())
    if names.isEmpty || names.contains("all") {
        // all: 설치돼 있는 에이전트만
        return all.filter { HookInstaller.status($0) != .agentMissing }
    }
    let wanted = Set(names.map { AgentKind(loose: $0) })
    return all.filter { wanted.contains($0.agent) }
}

func confirm(_ question: String) -> Bool {
    FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
    guard let line = readLine() else { return false }
    return ["y", "yes", "ㅇ", "응"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}

func runInstall(_ rest: [String], install: Bool) -> Int32 {
    let dryRun = rest.contains("--dry-run")
    let yes = rest.contains("--yes") || rest.contains("-y")
    let names = rest.filter { !$0.hasPrefix("-") }
    let targets = selectTargets(names)
    if targets.isEmpty {
        stderr(msg("대상 에이전트를 찾지 못했어요. (예: pawmit install claude codex)",
                   "No matching agents found. (e.g. pawmit install claude codex)"))
        return 1
    }
    var failed = false
    for target in targets {
        let label = "\(target.agent.displayName) (\(target.file.path))"
        do {
            let plan = try HookInstaller.makePlan(target, install: install)
            if plan.isNoop {
                print(msgF("· %@: 변경 없음", "· %@: no changes", label))
                continue
            }
            print("· \(label)")
            for c in plan.changes { print("    \(c)") }
            if dryRun { continue }
            if !yes, !confirm(msg("  적용할까요?", "  Apply?")) {
                print("    " + msg("건너뜀", "skipped"))
                continue
            }
            let backup = try HookInstaller.execute(plan)
            print("    " + msg("완료", "done") + (backup.map { msgF(" (백업: %@)", " (backup: %@)", $0.path) } ?? ""))
            if install, let note = target.note { print("    ※ \(note)") }
        } catch let error as HookInstaller.InstallError {
            if case .manual(let text) = error {
                print("· \(label)\n" + text.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
            } else {
                print("· \(label): \(error.localizedDescription)")
                failed = true
            }
        } catch {
            print("· \(label): \(error.localizedDescription)")
            failed = true
        }
    }
    return failed ? 1 : 0
}

func runStatus() -> Int32 {
    let running = UnixSocketServer.isServing(path: PawmitPaths.socket.path)
    print(msgF("Pawmit 앱: %@ (%@)", "Pawmit app: %@ (%@)",
               running ? msg("실행 중", "running") : msg("꺼져 있음", "not running"), PawmitPaths.socket.path))
    for target in HookInstaller.targets(config: PawmitConfig.load()) {
        let s: String
        switch HookInstaller.status(target) {
        case .installed: s = msg("연결됨", "connected")
        case .notInstalled: s = msg("미연결", "not connected")
        case .outdated: s = msgF("업데이트 필요 (pawmit install %@)", "update needed (pawmit install %@)", target.agent.rawValue)
        case .agentMissing: s = msg("에이전트 없음", "agent not installed")
        case .error(let e): s = msgF("오류: %@", "error: %@", e)
        }
        print(String(format: "  %-12@ %@", target.agent.displayName as NSString, s as NSString))
    }
    return 0
}

// MARK: - pet

/// 펫 지정: 기본 펫 id(mongle·cat …), ~/.pawmit/pets 폴더 이름(folder: 접두사 가능), 또는 폴더 경로
enum PetRef {
    case builtin(String)
    case folder(URL)

    init?(_ s: String) {
        let name = s.hasPrefix("folder:") ? String(s.dropFirst(7)) : s
        var isDir: ObjCBool = false
        if s.contains("/"), FileManager.default.fileExists(atPath: (s as NSString).expandingTildeInPath, isDirectory: &isDir), isDir.boolValue {
            self = .folder(URL(fileURLWithPath: (s as NSString).expandingTildeInPath))
        } else if PetCatalog.builtin(name) != nil, !s.hasPrefix("folder:") {
            self = .builtin(name)
        } else if !name.isEmpty, !name.contains("/"),
                  FileManager.default.fileExists(atPath: PawmitPaths.petsDir.appendingPathComponent(name).path) {
            self = .folder(PawmitPaths.petsDir.appendingPathComponent(name, isDirectory: true))
        } else {
            return nil
        }
    }

    /// 설정(config.pet)에 쓰는 id. ~/.pawmit/pets 밖의 폴더는 nil
    var configID: String? {
        switch self {
        case .builtin(let id): return id
        case .folder(let url):
            return url.deletingLastPathComponent().standardizedFileURL.path == PawmitPaths.petsDir.standardizedFileURL.path
                ? "folder:\(url.lastPathComponent)" : nil
        }
    }
}

/// 백업 파일 가져오기: 펫을 풀고, 물어본 뒤 펫 설정도 되돌린다
func importBackup(_ data: Data, yes: Bool) throws -> Int32 {
    let s = try PetBackup.inspect(data)
    print(msgF("백업: 펫 %lld마리 %@", "backup: %lld pet(s) %@", s.petNames.count, s.petNames.joined(separator: ", ")))
    if !yes, !confirm(msg("~/.pawmit/pets 에 가져올까요? (같은 펫은 건너뜀)", "Import into ~/.pawmit/pets? (identical pets are skipped)")) { print(msg("취소", "cancelled")); return 1 }
    try PawmitPaths.ensureHome()
    let result = try PetBackup.restore(data, into: PawmitPaths.petsDir)
    print(msgF("새 펫 %lld마리, 건너뜀 %lld마리", "%lld new, %lld skipped", result.installed.count, result.skipped.count))
    if let settings = s.settings, yes || confirm(msg("펫 설정(기본 펫 스타일·메인 펫·친구)도 백업대로 되돌릴까요?", "Also restore pet settings (built-in styles, main pet, friends)?")) {
        var config = PawmitConfig.load()
        settings.apply(to: &config, renamed: result.renamed) { id in
            if PetCatalog.builtin(id) != nil { return true }
            if id.hasPrefix("folder:") { return FileManager.default.fileExists(atPath: PawmitPaths.petsDir.appendingPathComponent(String(id.dropFirst(7))).path) }
            if id.hasPrefix("codex:") { return FileManager.default.fileExists(atPath: String(id.dropFirst(6))) }
            return false
        }
        try config.save()
        print(msg("펫 설정을 되돌렸어요 (앱이 켜져 있으면 바로 바뀌어요)", "pet settings restored (applies immediately if the app is running)"))
    }
    return 0
}

func readPetJSON(_ folder: URL) -> JSONValue? {
    (try? Data(contentsOf: folder.appendingPathComponent("pet.json"))).flatMap { JSONValue.parse($0) }
}

func runPet(_ rest: [String]) -> Int32 {
    let sub = rest.first ?? "help"
    var args = Array(rest.dropFirst())
    func option(_ names: String...) -> String? {
        for n in names {
            if let i = args.firstIndex(of: n), i + 1 < args.count {
                let v = args[i + 1]
                args.removeSubrange(i...(i + 1))
                return v
            }
        }
        return nil
    }
    let yes = args.contains("--yes") || args.contains("-y")
    args.removeAll { $0 == "--yes" || $0 == "-y" }

    switch sub {
    case "list":
        print(msg("기본 펫:", "Built-in pets:"))
        for b in PetCatalog.builtins {
            print("  \((b["id"]?.string ?? "?").padding(toLength: 10, withPad: " ", startingAt: 0)) \(b["kind"]?.string ?? "")  \(PetCatalog.localized(b, "name") ?? "") — \(PetCatalog.localized(b, "description") ?? "")")
        }
        let items = ((try? FileManager.default.contentsOfDirectory(at: PawmitPaths.petsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print(msgF("커스텀 펫 (%@):", "Custom pets (%@):", PawmitPaths.petsDir.path))
        if items.isEmpty { print(msg("  (없음) — pawmit pet new <이름> --base mongle", "  (none) — pawmit pet new <name> --base mongle")) }
        for f in items {
            let v = readPetJSON(f) ?? .object([:])
            let issues = PetCatalog.validate(v)
            let kind = PetCatalog.resolve(v)["kind"]?.string ?? "image"
            print("  \(f.lastPathComponent.padding(toLength: 10, withPad: " ", startingAt: 0)) \(kind)  \(v["name"]?.string ?? "")\(issues.isEmpty ? "" : msgF("  ⚠️ %lld개 문제", "  ⚠️ %lld issue(s)", issues.count))")
        }
        return 0

    case "show":
        guard let ref = args.first.flatMap(PetRef.init) else { stderr(msg("usage: pawmit pet show <펫>", "usage: pawmit pet show <pet>")); return 2 }
        switch ref {
        case .builtin(let id): print(PetCatalog.builtin(id)!.encoded(pretty: true))
        case .folder(let url):
            guard let v = readPetJSON(url) else { stderr(msgF("pet.json이 없거나 JSON이 아니에요: %@", "pet.json missing or not JSON: %@", url.path)); return 1 }
            print(v.encoded(pretty: true))
            if v["base"] != nil { print("\n" + msg("// base를 푼 결과:", "// resolved base:") + "\n" + PetCatalog.resolve(v).encoded(pretty: true)) }
        }
        return 0

    case "new":
        // --skeleton: 메이커 펫(완전히 새 생김새)을 뼈대 템플릿에서 시작
        // --base: 기본 펫을 바탕으로 일부만 바꾸는 변형
        let skeleton = option("--skeleton")
        let base = option("--base") ?? "mongle"
        let dir = option("--dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        guard let name = args.first, !name.isEmpty else {
            stderr(msg("usage: pawmit pet new <이름> [--skeleton biped|quadruped|blob|winged | --base mongle|banban|tokki|nalda|bamtol|haedal|cat] [--dir 폴더]",
                   "usage: pawmit pet new <name> [--skeleton biped|quadruped|blob|winged | --base mongle|banban|tokki|nalda|bamtol|haedal|cat] [--dir folder]"))
            return 2
        }
        let pet: JSONValue
        if let skeleton {
            guard var t = RigTemplates.template(skeleton) else { stderr(msgF("skeleton '%@'은 없어요 (biped quadruped blob winged)", "no such skeleton '%@' (biped quadruped blob winged)", skeleton)); return 2 }
            t.name = name
            pet = t.json
        } else {
            guard let def = PetCatalog.builtin(base) else { stderr(msgF("base '%@'는 기본 펫 id가 아니에요", "base '%@' is not a built-in pet id", base)); return 2 }
            pet = ["kind": def["kind"] ?? "chibi", "base": .string(base), "name": .string(name)]
        }
        let folderName = PetBundle.slug(name)
        let folder = (dir ?? PawmitPaths.petsDir).appendingPathComponent(folderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { stderr(msgF("이미 있어요: %@", "already exists: %@", folder.path)); return 1 }
        do {
            if dir == nil { try PawmitPaths.ensureHome() }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(pet.encoded(pretty: true).utf8).write(to: folder.appendingPathComponent("pet.json"))
            print(folder.appendingPathComponent("pet.json").path)
            if skeleton != nil {
                print(msgF("parts의 SVG path·색을 고치세요 (100×100 캔버스, y 아래, 바닥 y=96). 확인: pawmit pet svg %@ / pawmit pet preview %@", "Edit the SVG paths and colors in parts (100×100 canvas, y down, ground y=96). Check: pawmit pet svg %@ / pawmit pet preview %@", folder.path, folder.path))
            } else {
                print(msgF("pet.json에서 바꾸고 싶은 필드만 덮어쓰세요 (pawmit pet show %@ 로 전체 필드 확인). 미리보기: pawmit pet preview %@", "Override only the fields you want in pet.json (see all fields: pawmit pet show %@). Preview: pawmit pet preview %@", base, folderName))
            }
            return 0
        } catch {
            stderr(msgF("만들지 못했어요: %@", "could not create: %@", error.localizedDescription))
            return 1
        }

    case "svg":
        // 메이커 펫의 쉬는 자세를 SVG로 (아무 SVG 뷰어로 확인)
        guard let ref = args.first.flatMap(PetRef.init), case .folder(let url) = ref,
              let v = readPetJSON(url), let spec = RigSpec.decode(v) else { stderr(msg("usage: pawmit pet svg <메이커 펫 폴더> [-o 파일.svg]", "usage: pawmit pet svg <maker pet folder> [-o file.svg]")); return 2 }
        let svg = spec.svg()
        if let out = option("-o", "--output") {
            do {
                try Data(svg.utf8).write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
                print(out)
            } catch {
                stderr(msgF("저장 실패: %@", "save failed: %@", error.localizedDescription))
                return 1
            }
        } else {
            print(svg, terminator: "")
        }
        return 0

    case "validate":
        guard let target = args.first else { stderr(msg("usage: pawmit pet validate <펫|폴더|pet.json|파일.pawmitpet>", "usage: pawmit pet validate <pet|folder|pet.json|file.pawmitpet>")); return 2 }
        let path = (target as NSString).expandingTildeInPath
        if path.hasSuffix("." + PetBundle.fileExtension) {
            do {
                let s = try PetBundle.inspect(try Data(contentsOf: URL(fileURLWithPath: path)))
                print(msgF("✓ %@ (%@, 그림 %lld장)", "✓ %@ (%@, %lld image(s))", s.name, s.kind, s.fileNames.count))
                for w in s.warnings { print("  ⚠️ \(w)") }
                return 0
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        }
        let json: JSONValue?
        if path.hasSuffix(".json") {
            json = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { JSONValue.parse($0) }
        } else if let ref = PetRef(target), case .folder(let url) = ref {
            json = readPetJSON(url)
        } else if let ref = PetRef(target), case .builtin(let id) = ref {
            json = PetCatalog.builtin(id)
        } else {
            json = nil
        }
        guard let json else { print(msg("✗ pet.json을 찾지 못했거나 JSON이 아니에요", "✗ pet.json not found or not JSON")); return 1 }
        let issues = PetCatalog.validate(json)
        if issues.isEmpty { print(msg("✓ 문제 없음", "✓ no issues")); return 0 }
        for i in issues { print("✗ \(i)") }
        return 1

    case "export" where args.contains("--all"):
        // 커스텀 펫 전부 + 펫 설정 백업
        do {
            let (data, left) = try PetBackup.export(petsDir: PawmitPaths.petsDir, config: PawmitConfig.load())
            let out = URL(fileURLWithPath: ((option("-o", "--output") ?? "pawmit-pets.\(PetBundle.fileExtension)") as NSString).expandingTildeInPath)
            try data.write(to: out, options: .atomic)
            for name in left { stderr(msgF("빠진 펫 (그림 없음·너무 큼): %@", "left out (no art or too large): %@", name)) }
            print(out.path)
            return 0
        } catch {
            stderr(msgF("내보내지 못했어요: %@", "could not export: %@", error.localizedDescription))
            return 1
        }

    case "export":
        guard let ref = args.first.flatMap(PetRef.init) else { stderr(msg("usage: pawmit pet export <펫> [-o 파일.pawmitpet] | --all [-o 파일]", "usage: pawmit pet export <pet> [-o file.pawmitpet] | --all [-o file]")); return 2 }
        do {
            let data: Data
            let base: String
            switch ref {
            case .builtin(let id):
                var def = PetCatalog.builtin(id)!.object!
                def.removeValue(forKey: "id")
                data = PetBundle.export(pet: .object(def), name: def["name"]?.string ?? id)
                base = id
            case .folder(let url):
                data = try PetBundle.export(folder: url)
                base = url.lastPathComponent
            }
            let out = URL(fileURLWithPath: ((option("-o", "--output") ?? "\(base).\(PetBundle.fileExtension)") as NSString).expandingTildeInPath)
            try data.write(to: out, options: .atomic)
            print(out.path)
            return 0
        } catch {
            stderr(msgF("내보내지 못했어요: %@", "could not export: %@", error.localizedDescription))
            return 1
        }

    case "import":
        let folderName = option("--name")
        guard let file = args.first else { stderr(msg("usage: pawmit pet import <파일.pawmitpet> [--name 폴더] [--yes]", "usage: pawmit pet import <file.pawmitpet> [--name folder] [--yes]")); return 2 }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            if PetBackup.isBackup(data) { return try importBackup(data, yes: yes) }
            let s = try PetBundle.inspect(data)
            print(msgF("'%@' (%@, 그림 %lld장)", "'%@' (%@, %lld image(s))", s.name, s.kind, s.fileNames.count))
            for w in s.warnings { print("  ⚠️ \(w)") }
            if !yes, !confirm(msg("~/.pawmit/pets 에 가져올까요?", "Import into ~/.pawmit/pets?")) { print(msg("취소", "cancelled")); return 1 }
            try PawmitPaths.ensureHome()
            let folder = try PetBundle.install(data, into: PawmitPaths.petsDir, folderName: folderName)
            print(folder.path)
            print(msgF("쓰려면: pawmit pet use %@", "to use it: pawmit pet use %@", folder.lastPathComponent))
            return 0
        } catch {
            stderr(msgF("가져오지 못했어요: %@", "could not import: %@", error.localizedDescription))
            return 1
        }

    case "use":
        guard let ref = args.first.flatMap(PetRef.init) else { stderr(msg("usage: pawmit pet use <펫>", "usage: pawmit pet use <pet>")); return 2 }
        guard let id = ref.configID else { stderr(msg("~/.pawmit/pets 안의 펫만 쓸 수 있어요 (pawmit pet export 후 import)", "only pets inside ~/.pawmit/pets can be used (pawmit pet export then import)")); return 1 }
        var config = PawmitConfig.load()
        config.pet = id
        config.friends.removeAll { $0 == id }
        do {
            try config.save()
            print(msgF("메인 펫: %@ (앱이 켜져 있으면 바로 바뀌어요)", "main pet: %@ (switches immediately if the app is running)", id))
            return 0
        } catch {
            stderr(msgF("설정을 저장하지 못했어요: %@", "could not save settings: %@", error.localizedDescription))
            return 1
        }

    case "preview":
        // 실행 중인 앱이 그린 포즈 모음 PNG 경로를 출력 (pet.json을 고친 뒤 확인용)
        // 설치하지 않은 폴더도 경로로 미리보기 (pet.json만 고쳐 보며 확인)
        guard let ref = args.first.flatMap(PetRef.init) else { stderr(msg("usage: pawmit pet preview <펫|폴더 경로>", "usage: pawmit pet preview <pet|folder path>")); return 2 }
        if let id = ref.configID { return runDebug(["sheet", id]) }
        guard case .folder(let url) = ref else { return 2 }
        return runDebug(["sheet", "path:" + url.standardizedFileURL.path])

    default:
        print(L10n.isKorean ? """
        pawmit pet — 펫 만들기·고치기·주고받기 (형식: docs/PET_FORMAT.md)

          pawmit pet list                          기본·커스텀 펫 목록
          pawmit pet show <펫>                     pet.json 보기 (기본 펫은 전체 필드)
          pawmit pet new <이름> --skeleton biped     메이커 펫(새 생김새) 시작 — biped quadruped blob winged
          pawmit pet new <이름> --base mongle       기본 펫 변형 (색·부위만 바꾸기)
          pawmit pet svg <메이커 펫>                쉬는 자세 SVG (-o 파일)
          pawmit pet validate <펫|pet.json|파일>    정의 검사
          pawmit pet preview <펫|폴더>              포즈 모음 PNG 만들기 (앱 실행 중일 때, 설치 전 폴더도 가능)
          pawmit pet export <펫> [-o 파일]          .pawmitpet 파일로 내보내기
          pawmit pet export --all [-o 파일]         커스텀 펫 전부 + 펫 설정 백업
          pawmit pet import <파일> [--name 폴더]    .pawmitpet·백업 가져오기 (--yes: 확인 생략)
          pawmit pet use <펫>                      메인 펫으로 쓰기

        <펫>: 기본 펫 id(mongle banban tokki nalda bamtol haedal cat), ~/.pawmit/pets 폴더 이름, 또는 폴더 경로
        """ : """
        pawmit pet — create, edit, and share pets (format: docs/PET_FORMAT.md)

          pawmit pet list                          list built-in and custom pets
          pawmit pet show <pet>                    print pet.json (full fields for built-ins)
          pawmit pet new <name> --skeleton biped     start a maker pet (new look) — biped quadruped blob winged
          pawmit pet new <name> --base mongle       vary a built-in pet (colors & parts only)
          pawmit pet svg <maker pet>               idle-pose SVG (-o file)
          pawmit pet validate <pet|pet.json|file>    validate a definition
          pawmit pet preview <pet|folder>              render a pose sheet PNG (app running; uninstalled folders OK)
          pawmit pet export <pet> [-o file]          export as .pawmitpet
          pawmit pet export --all [-o file]          back up all custom pets + pet settings
          pawmit pet import <file> [--name folder]    import a .pawmitpet or backup (--yes: skip confirm)
          pawmit pet use <pet>                      set as the main pet

        <pet>: built-in id (mongle banban tokki nalda bamtol haedal cat), a ~/.pawmit/pets folder name, or a folder path
        """)
        return sub == "help" ? 0 : 2
    }
}

// MARK: - main

let command = args.first ?? "help"
let rest = Array(args.dropFirst())
let code: Int32
switch command {
case "hook": code = runHook(rest)
case "notify": code = runNotify(rest, speech: false)
case "say": code = runNotify(rest, speech: true)
case "install": code = runInstall(rest, install: true)
case "uninstall": code = runInstall(rest, install: false)
case "status": code = runStatus()
case "debug": code = runDebug(rest)
case "pet", "pets": code = runPet(rest)
case "version", "--version": print("pawmit \(cliVersion())"); code = 0
default:
    print(L10n.isKorean ? """
    pawmit — 데스크탑 펫 Pawmit의 에이전트 연결 도구

      pawmit status                         연결 상태 보기
      pawmit install [agent...|all]         hook 설치 (--dry-run, --yes)
      pawmit uninstall [agent...|all]       hook 제거
      pawmit notify [--title T] <메시지>     펫에게 알림 보내기
      pawmit say <메시지>                    펫이 말하게 하기
      pawmit pet <list|new|show|validate|preview|export|import|use>   펫 만들기·주고받기
      pawmit hook <agent> [event]           (에이전트 hook 전용)

    agent: claude codex gemini qwen droid cursor copilot opencode kiro
    """ : """
    pawmit — agent hookup tool for the Pawmit desktop pet

      pawmit status                         show connection status
      pawmit install [agent...|all]         install hooks (--dry-run, --yes)
      pawmit uninstall [agent...|all]       remove hooks
      pawmit notify [--title T] <message>   send the pet a notification
      pawmit say <message>                  make the pet speak
      pawmit pet <list|new|show|validate|preview|export|import|use>   create & share pets
      pawmit hook <agent> [event]           (for agent hooks only)

    agent: claude codex gemini qwen droid cursor copilot opencode kiro
    """)
    code = command == "help" || command == "--help" ? 0 : 2
}
exit(code)
