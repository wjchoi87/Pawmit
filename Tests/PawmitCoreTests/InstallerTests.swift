import XCTest
@testable import PawmitCore

final class InstallerTests: XCTestCase {
    let cli = "/Users/test/.pawmit/bin/pawmit"
    let home = URL(fileURLWithPath: "/Users/test")

    func target(_ agent: AgentKind, config: PawmitConfig = PawmitConfig()) -> HookInstaller.Target {
        HookInstaller.targets(config: config, cliPath: cli, home: home).first { $0.agent == agent }!
    }

    /// 사용자가 이미 쓰고 있는 hook (실제 ~/.claude/settings.json과 같은 모양)
    let existing: JSONValue = [
        "model": "opus",
        "hooks": [
            "PreToolUse": [[
                "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
                "hooks": [["type": "command", "command": "/usr/bin/python3 /Users/test/.agents/hooks/guard.py --cli claude", "timeout": 10]],
            ]],
        ],
    ]

    func testClaudeInstallPreservesForeignHooksAndIsIdempotent() throws {
        let t = target(.claude)
        let once = try HookInstaller.apply(to: existing, target: t, cliPath: cli, install: true)
        XCTAssertEqual(once["model"]?.string, "opus")
        let pre = once["hooks"]?["PreToolUse"]?.array ?? []
        XCTAssertEqual(pre.count, 2, "기존 가드 hook + Pawmit 질문 hook")
        XCTAssertEqual(pre[0], existing["hooks"]?["PreToolUse"]?[0], "기존 hook은 그대로, 순서도 유지")
        XCTAssertEqual(pre[1]["matcher"]?.string, "AskUserQuestion|ExitPlanMode")
        XCTAssertEqual(once["hooks"]?["PostToolUse"]?[0]?["hooks"]?[0]?["async"]?.bool, true)
        XCTAssertEqual(once["hooks"]?["PermissionRequest"]?[0]?["hooks"]?[0]?["command"]?.string,
                       "/Users/test/.pawmit/bin/pawmit hook claude PermissionRequest")

        let twice = try HookInstaller.apply(to: once, target: t, cliPath: cli, install: true)
        XCTAssertEqual(once, twice, "두 번 설치해도 같은 결과")

        let removed = try HookInstaller.apply(to: twice, target: t, cliPath: cli, install: false)
        XCTAssertEqual(removed, existing, "제거하면 원래 설정으로 정확히 돌아온다")
    }

    func testRejectsUnexpectedShape() {
        let weird: JSONValue = ["hooks": "nope"]
        XCTAssertThrowsError(try HookInstaller.apply(to: weird, target: target(.claude), cliPath: cli, install: true))
        let weirdEvent: JSONValue = ["hooks": ["Stop": "nope"]]
        XCTAssertThrowsError(try HookInstaller.apply(to: weirdEvent, target: target(.claude), cliPath: cli, install: true))
    }

    func testCursorFlatFormatKeepsOtherTools() throws {
        let muxy: JSONValue = ["version": 1, "hooks": ["stop": [["command": "'/x/muxy-cursor-hook.sh' stop # muxy-notification-hook"]]]]
        var config = PawmitConfig()
        config.cursorShellApproval = true
        let t = target(.cursor, config: config)
        let out = try HookInstaller.apply(to: muxy, target: t, cliPath: cli, install: true)
        XCTAssertEqual(out["hooks"]?["stop"]?.array?.count, 2)
        XCTAssertNotNil(out["hooks"]?["beforeShellExecution"])
        let back = try HookInstaller.apply(to: out, target: t, cliPath: cli, install: false)
        XCTAssertEqual(back, muxy)
    }

    func testDroidTopLevelAndGeminiMillis() throws {
        let droid = try HookInstaller.apply(to: nil, target: target(.droid), cliPath: cli, install: true)
        XCTAssertEqual(droid["PreToolUse"]?[0]?["matcher"]?.string, "Execute|Edit|Create|ApplyPatch|MultiEdit")
        XCTAssertNil(droid["hooks"])
        let gemini = try HookInstaller.apply(to: ["theme": "x"], target: target(.gemini), cliPath: cli, install: true)
        XCTAssertEqual(gemini["hooks"]?["BeforeAgent"]?[0]?["hooks"]?[0]?["timeout"]?.number, 5000)
        XCTAssertEqual(gemini["theme"]?.string, "x")
    }

    func testPlanAndExecuteWithBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        try Data(existing.encoded(pretty: true).utf8).write(to: settings)
        var t = target(.claude)
        t.file = settings
        t.detectDir = dir

        let plan = try HookInstaller.makePlan(t, install: true, cliPath: cli)
        XCTAssertFalse(plan.isNoop)
        XCTAssertTrue(plan.changes.contains { $0.hasPrefix("+ PermissionRequest") })
        let backup = try HookInstaller.execute(plan, backupDir: dir.appendingPathComponent("backups"))
        XCTAssertNotNil(backup)
        XCTAssertEqual(JSONValue.parse(try Data(contentsOf: backup!)), existing)
        XCTAssertEqual(HookInstaller.status(t, cliPath: cli), .installed)

        let again = try HookInstaller.makePlan(t, install: true, cliPath: cli)
        XCTAssertTrue(again.isNoop)

        let un = try HookInstaller.makePlan(t, install: false, cliPath: cli)
        try HookInstaller.execute(un, backupDir: dir.appendingPathComponent("backups"))
        XCTAssertEqual(JSONValue.parse(try Data(contentsOf: settings)), existing)
    }

    func testBrokenJSONIsNotTouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        try Data("{ broken".utf8).write(to: settings)
        var t = target(.claude)
        t.file = settings
        XCTAssertThrowsError(try HookInstaller.makePlan(t, install: true, cliPath: cli))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }
}

final class ZCodeTests: XCTestCase {
    let cli = "/Users/test/.pawmit/bin/pawmit"
    let home = URL(fileURLWithPath: "/Users/test")

    /// 실제 ~/.zcode/cli/config.json과 같은 모양 (사용자 가드 hook이 이미 있음)
    let existing: JSONValue = [
        "hooks": [
            "enabled": true,
            "events": [
                "PreToolUse": [[
                    "matcher": "Bash|Edit",
                    "hooks": [["type": "process", "command": "/usr/bin/python3", "args": ["/Users/test/.agents/hooks/guard.py", "--cli", "zcode"], "timeoutMs": 10000]],
                ]],
                "Stop": [["hooks": [["type": "process", "command": "/usr/bin/python3", "args": ["/Users/test/.agents/hooks/x.py"], "timeoutMs": 30000]]]],
            ],
        ],
        "mcpServers": ["foo": ["command": "foo"]],
    ]

    func testInstallMergesProcessHooksAndRoundTrips() throws {
        let t = HookInstaller.targets(config: PawmitConfig(), cliPath: cli, home: home).first { $0.agent == .zcode }!
        XCTAssertEqual(t.file.path, "/Users/test/.zcode/cli/config.json")
        let once = try HookInstaller.apply(to: existing, target: t, cliPath: cli, install: true)
        XCTAssertEqual(once["mcpServers"], existing["mcpServers"])
        XCTAssertEqual(once["hooks"]?["enabled"]?.bool, true)
        let perm = once["hooks"]?["events"]?["PermissionRequest"]?[0]?["hooks"]?[0]
        XCTAssertEqual(perm?["type"]?.string, "process")
        XCTAssertEqual(perm?["command"]?.string, cli)
        XCTAssertEqual(perm?["args"], ["hook", "zcode", "PermissionRequest"])
        XCTAssertEqual(perm?["timeoutMs"]?.number, 600_000)
        let stop = once["hooks"]?["events"]?["Stop"]?.array ?? []
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(stop[0], existing["hooks"]?["events"]?["Stop"]?[0], "기존 hook은 그대로 앞에")
        XCTAssertEqual(try HookInstaller.apply(to: once, target: t, cliPath: cli, install: true), once, "두 번 설치해도 같음")
        XCTAssertEqual(try HookInstaller.apply(to: once, target: t, cliPath: cli, install: false), existing, "제거하면 원래대로")
        XCTAssertFalse(HookInstaller.pawmitEntries(in: once, format: .zcode).isEmpty)
        // hooks가 이상한 모양이면 건드리지 않는다
        XCTAssertThrowsError(try HookInstaller.apply(to: ["hooks": ["events": "nope"]], target: t, cliPath: cli, install: true))
    }

    func testZCodeUsesClaudeDecisionFormat() {
        let env = HookEnvelope(agent: "zcode", event: "PermissionRequest", expectsReply: true, pid: 1, ppid: 1, tty: nil, env: [:], cwd: "/tmp",
                               payload: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]],
                               waitSeconds: 10)
        XCTAssertTrue(AgentAdapters.isInteractiveCandidate(agent: .zcode, event: "PermissionRequest", payload: env.payload))
        let out = AgentAdapters.render(HookReply(id: env.id, decision: .deny, message: "안 돼"), envelope: env).flatMap { JSONValue.parse($0) }
        XCTAssertEqual(out?["hookSpecificOutput"]?["hookEventName"]?.string, "PermissionRequest")
        XCTAssertEqual(out?["hookSpecificOutput"]?["decision"]?["behavior"]?.string, "deny")
        XCTAssertTrue(AgentAdapters.supportsStopReply(.zcode))
        let stopEnv = HookEnvelope(agent: "zcode", event: "Stop", expectsReply: true, pid: 1, ppid: 1, tty: nil, env: [:], cwd: "/tmp",
                                   payload: ["hook_event_name": "Stop"], waitSeconds: 10)
        let stop = AgentAdapters.render(HookReply(id: stopEnv.id, decision: .reply, message: "테스트도 돌려줘"), envelope: stopEnv).flatMap { JSONValue.parse($0) }
        XCTAssertEqual(stop?["decision"]?.string, "block")
        XCTAssertEqual(AgentKind(loose: "z-code"), .zcode)
    }
}
