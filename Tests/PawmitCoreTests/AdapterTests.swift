import XCTest
@testable import PawmitCore

final class AdapterTests: XCTestCase {
    func envelope(_ agent: String, _ event: String, _ payload: JSONValue) -> HookEnvelope {
        HookEnvelope(agent: agent, event: event, expectsReply: true, pid: 1, ppid: 1, tty: nil, env: [:], cwd: "/tmp/proj",
                     payload: payload, waitSeconds: 10)
    }

    func decode(_ s: String?) -> JSONValue? { s.flatMap { JSONValue.parse($0) } }

    func testClaudePermissionAllowDenyAlways() {
        let suggestions: JSONValue = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]], "behavior": "allow", "destination": "localSettings"]]
        let env = envelope("claude", "PermissionRequest", ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                                           "tool_input": ["command": "npm test"], "permission_suggestions": suggestions])
        let allow = decode(AgentAdapters.render(HookReply(id: env.id, decision: .allow), envelope: env))
        XCTAssertEqual(allow?["hookSpecificOutput"]?["hookEventName"]?.string, "PermissionRequest")
        XCTAssertEqual(allow?["hookSpecificOutput"]?["decision"]?["behavior"]?.string, "allow")
        XCTAssertNil(allow?["hookSpecificOutput"]?["decision"]?["updatedPermissions"])

        let always = decode(AgentAdapters.render(HookReply(id: env.id, decision: .allow, updatedPermissions: suggestions), envelope: env))
        XCTAssertEqual(always?["hookSpecificOutput"]?["decision"]?["updatedPermissions"], suggestions)

        let deny = decode(AgentAdapters.render(HookReply(id: env.id, decision: .deny, message: "안 돼", interrupt: true), envelope: env))
        XCTAssertEqual(deny?["hookSpecificOutput"]?["decision"]?["behavior"]?.string, "deny")
        XCTAssertEqual(deny?["hookSpecificOutput"]?["decision"]?["message"]?.string, "안 돼")
        XCTAssertEqual(deny?["hookSpecificOutput"]?["decision"]?["interrupt"]?.bool, true)

        XCTAssertNil(AgentAdapters.render(HookReply(id: env.id, decision: .pass), envelope: env), "pass면 출력 없이 터미널로")
    }

    func testCodexDropsUnsupportedFields() {
        let env = envelope("codex", "PermissionRequest", ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        let out = decode(AgentAdapters.render(HookReply(id: env.id, decision: .allow, updatedPermissions: [["type": "setMode"]]), envelope: env))
        XCTAssertNil(out?["hookSpecificOutput"]?["decision"]?["updatedPermissions"])
        let deny = decode(AgentAdapters.render(HookReply(id: env.id, decision: .deny, interrupt: true), envelope: env))
        XCTAssertNil(deny?["hookSpecificOutput"]?["decision"]?["interrupt"])
    }

    func testAskUserQuestionAnswer() {
        let questions: JSONValue = [["question": "Which framework?", "header": "Framework",
                                     "options": [["label": "React", "description": "a"], ["label": "Vue", "description": "b"]], "multiSelect": false]]
        let env = envelope("claude", "PreToolUse", ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": ["questions": questions]])
        let event = AgentAdapters.normalize(env)
        XCTAssertEqual(event.kind, .question)
        XCTAssertEqual(event.questions.first?.options.map(\.label), ["React", "Vue"])
        XCTAssertTrue(AgentAdapters.isInteractiveCandidate(agent: .claude, event: "PreToolUse", payload: env.payload))

        let out = decode(AgentAdapters.render(HookReply(id: env.id, decision: .answer, answers: ["Which framework?": "Vue"]), envelope: env))
        XCTAssertEqual(out?["hookSpecificOutput"]?["permissionDecision"]?.string, "allow")
        XCTAssertEqual(out?["hookSpecificOutput"]?["updatedInput"]?["answers"]?["Which framework?"]?.string, "Vue")
        XCTAssertEqual(out?["hookSpecificOutput"]?["updatedInput"]?["questions"], questions)
    }

    func testAskUserQuestionInPermissionRequestIsIgnored() {
        let env = envelope("claude", "PermissionRequest", ["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": [:]])
        XCTAssertEqual(AgentAdapters.normalize(env).kind, .other)
    }

    func testExitPlanModeApproveEchoesInput() {
        let input: JSONValue = ["plan": "# Plan\n1. do it", "planFilePath": "/tmp/plan.md"]
        let env = envelope("claude", "PreToolUse", ["hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": input])
        XCTAssertEqual(AgentAdapters.normalize(env).kind, .plan)
        let out = decode(AgentAdapters.render(HookReply(id: env.id, decision: .allow), envelope: env))
        XCTAssertEqual(out?["hookSpecificOutput"]?["updatedInput"], input)
        let reject = decode(AgentAdapters.render(HookReply(id: env.id, decision: .deny, message: "테스트도 추가"), envelope: env))
        XCTAssertEqual(reject?["hookSpecificOutput"]?["permissionDecision"]?.string, "deny")
        XCTAssertEqual(reject?["hookSpecificOutput"]?["permissionDecisionReason"]?.string, "테스트도 추가")
    }

    func testStopReply() {
        let env = envelope("claude", "Stop", ["hook_event_name": "Stop", "last_assistant_message": "끝!", "stop_hook_active": false])
        let event = AgentAdapters.normalize(env)
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.message, "끝!")
        XCTAssertTrue(event.capabilities.contains(.reply))
        let out = decode(AgentAdapters.render(HookReply(id: env.id, decision: .reply, message: "테스트도 돌려줘"), envelope: env))
        XCTAssertEqual(out?["decision"]?.string, "block")
        XCTAssertEqual(out?["reason"]?.string, "테스트도 돌려줘")

        let cursor = envelope("cursor", "stop", ["hook_event_name": "stop", "status": "completed"])
        XCTAssertEqual(decode(AgentAdapters.render(HookReply(id: cursor.id, decision: .reply, message: "다음"), envelope: cursor))?["followup_message"]?.string, "다음")
    }

    func testCopilotAndCursorFormats() {
        let cop = envelope("copilot", "permissionRequest", ["sessionId": "s1", "toolName": "bash", "toolArgs": "{\"command\":\"rm -rf build\"}", "cwd": "/w"])
        let ev = AgentAdapters.normalize(cop)
        XCTAssertEqual(ev.kind, .permission)
        XCTAssertEqual(ev.toolInput?["command"]?.string, "rm -rf build")
        XCTAssertEqual(ev.sessionID, "s1")
        XCTAssertEqual(AgentAdapters.render(HookReply(id: cop.id, decision: .allow), envelope: cop), #"{"behavior":"allow"}"#)
        XCTAssertEqual(AgentAdapters.render(HookReply(id: cop.id, decision: .pass), envelope: cop), "{}")
        XCTAssertEqual(AgentAdapters.fallbackOutput(agent: .copilot, event: "permissionRequest"), "{}")

        let cur = envelope("cursor", "beforeShellExecution", ["hook_event_name": "beforeShellExecution", "command": "git push", "cwd": "/w", "conversation_id": "c1"])
        let cev = AgentAdapters.normalize(cur)
        XCTAssertEqual(cev.kind, .permission)
        XCTAssertEqual(cev.toolName, "Shell")
        XCTAssertEqual(cev.toolInput?["command"]?.string, "git push")
        XCTAssertEqual(decode(AgentAdapters.render(HookReply(id: cur.id, decision: .deny, message: "no"), envelope: cur))?["permission"]?.string, "deny")
        XCTAssertEqual(AgentAdapters.render(HookReply(id: cur.id, decision: .pass), envelope: cur), #"{"permission":"ask"}"#)
    }

    func testGeminiNormalization() {
        let env = envelope("gemini", "PreToolUse", ["hook_event_name": "BeforeTool", "tool_name": "run_shell_command", "tool_input": ["command": "ls"], "session_id": "g"])
        XCTAssertEqual(AgentAdapters.normalize(env).kind, .toolStart)
        XCTAssertFalse(AgentAdapters.isInteractiveCandidate(agent: .gemini, event: "BeforeTool", payload: env.payload))
        XCTAssertEqual(AgentAdapters.fallbackOutput(agent: .gemini, event: "BeforeTool"), "{}")
        let stop = envelope("gemini", "AfterAgent", ["hook_event_name": "AfterAgent", "prompt_response": "done"])
        let s = AgentAdapters.normalize(stop)
        XCTAssertEqual(s.kind, .stop)
        XCTAssertEqual(s.message, "done")
        XCTAssertFalse(s.capabilities.contains(.reply))
    }

    func testToolSummary() {
        let s = ToolSummary.make(toolName: "Bash", input: ["command": "rm -rf node_modules && npm i", "description": "재설치"], agent: .claude)
        XCTAssertEqual(s.risk, .high)
        XCTAssertEqual(s.body, "rm -rf node_modules && npm i")
        XCTAssertEqual(s.note, "재설치")
        let e = ToolSummary.make(toolName: "Edit", input: ["file_path": "/a/b.swift", "old_string": "x", "new_string": "y"], agent: .claude)
        XCTAssertTrue(e.subject.contains("b.swift"))
        XCTAssertTrue(e.body?.contains("- x") == true && e.body?.contains("+ y") == true)
        XCTAssertTrue(ToolSummary.isReadOnly(toolName: "view"))
    }
}
