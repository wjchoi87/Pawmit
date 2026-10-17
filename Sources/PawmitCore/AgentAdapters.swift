import Foundation

/// 에이전트별 hook 입력 정규화와 출력 변환.
///
/// 이벤트명·필드명 정규화 규칙은 coucou(MIT, Louis-CFM/coucou `nb-hook.py`)의 relay를,
/// Claude 응답 JSON 형태는 bezel(MIT, boxed-dev/bezel `DecisionJSON`, `AskUserQuestionEncoder`,
/// `PlanReviewEncoder`)을 참고해 Swift로 다시 작성했다. 각 에이전트 형식은 공식 hook 문서 기준(2026-10-13).
public enum AgentAdapters {

    // MARK: - 이벤트 이름

    /// 에이전트 고유 이벤트 이름 → Pawmit 공통(Claude 스타일) 이름
    public static func canonicalEvent(_ raw: String, agent: AgentKind) -> String {
        let map: [String: String] = [
            // Gemini CLI
            "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse", "BeforeAgent": "UserPromptSubmit",
            "AfterAgent": "Stop", "PreCompress": "PreCompact",
            // Copilot CLI / Cursor / Kiro (camelCase)
            "sessionStart": "SessionStart", "sessionEnd": "SessionEnd", "userPromptSubmitted": "UserPromptSubmit",
            "userPromptSubmit": "UserPromptSubmit", "beforeSubmitPrompt": "UserPromptSubmit",
            "preToolUse": "PreToolUse", "postToolUse": "PostToolUse", "postToolUseFailure": "PostToolUseFailure",
            "permissionRequest": "PermissionRequest", "notification": "Notification",
            "agentStop": "Stop", "stop": "Stop", "subagentStart": "SubagentStart", "subagentStop": "SubagentStop",
            "preCompact": "PreCompact", "errorOccurred": "StopFailure", "agentSpawn": "SessionStart",
            "afterFileEdit": "PostToolUse", "afterShellExecution": "PostToolUse", "afterMCPExecution": "PostToolUse",
            "beforeShellExecution": "ShellPermission", "beforeMCPExecution": "MCPPermission",
            "afterAgentResponse": "AgentResponse",
            // snake_case 변형
            "pre_tool_use": "PreToolUse", "post_tool_use": "PostToolUse", "user_prompt_submit": "UserPromptSubmit",
            "session_start": "SessionStart", "session_end": "SessionEnd",
        ]
        return map[raw] ?? raw
    }

    // MARK: - CLI 대기 정책

    /// CLI가 앱 응답을 오래 기다려야 할 수 있는 이벤트인지. 실제로 말풍선을 띄울지는 앱이 결정하고,
    /// 띄우지 않으면 즉시 pass를 돌려준다.
    public static func isInteractiveCandidate(agent: AgentKind, event: String, payload: JSONValue) -> Bool {
        let ev = canonicalEvent(event, agent: agent)
        switch ev {
        case "PermissionRequest":
            return [.claude, .codex, .copilot, .qwen, .zcode].contains(agent)
        case "ShellPermission", "MCPPermission":
            return agent == .cursor
        case "PreToolUse":
            let tool = toolName(in: payload, agent: agent) ?? ""
            if agent == .claude { return tool == "AskUserQuestion" || tool == "ExitPlanMode" }
            return agent == .droid
        case "Stop":
            return supportsStopReply(agent)
        default:
            return false
        }
    }

    /// ZCode(Z.ai)는 Claude Code와 같은 hook 입출력(hookSpecificOutput·decision: block)을 쓴다 (ZCode 0.x 번들의 hook 스키마로 확인)
    public static func supportsStopReply(_ agent: AgentKind) -> Bool {
        [.claude, .codex, .qwen, .droid, .cursor, .zcode].contains(agent)
    }

    /// 앱이 없거나 응답이 없을 때 stdout에 낼 내용. nil이면 아무것도 출력하지 않는다(= 에이전트 기본 동작).
    public static func fallbackOutput(agent: AgentKind, event: String) -> String? {
        let ev = canonicalEvent(event, agent: agent)
        switch agent {
        case .copilot, .gemini:
            // Copilot은 권한 hook이 fail-closed라 반드시 유효한 JSON이 필요하다. {} = 기본 흐름.
            return "{}"
        case .cursor:
            if ev == "ShellPermission" || ev == "MCPPermission" { return #"{"permission":"ask"}"# }
            return "{}"
        default:
            return nil
        }
    }

    // MARK: - 정규화

    public static func normalize(_ env: HookEnvelope) -> AgentEvent {
        let agent = AgentKind(loose: env.agent)
        let p = env.payload
        let ev = canonicalEvent(p["hook_event_name"]?.string ?? env.event, agent: agent)
        let tool = toolName(in: p, agent: agent)
        let input = toolInput(in: p, agent: agent)
        let cwd = p.firstString("cwd", "workdir", "directory") ?? p["workspace_roots"]?[0]?.string
            ?? p["workspacePaths"]?[0]?.string ?? env.cwd
        let session = p.firstString("session_id", "sessionId", "sessionID", "conversation_id", "conversationId", "thread-id", "thread_id")

        var event = AgentEvent(kind: .other, agent: agent, rawEvent: ev, sessionID: session, cwd: cwd,
                               toolName: tool, toolInput: input)
        event.title = p.firstString("title")
        event.message = p.firstString("message")
        event.notificationType = p.firstString("notification_type", "notificationType")

        switch ev {
        case "PermissionRequest":
            if agent == .claude, tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                // 질문·계획은 PreToolUse 경로에서 처리한다. 여기서 승인 말풍선을 띄우면 질문이 "승인"처럼 보인다.
                event.kind = .other
            } else {
                event.kind = .permission
                event.permissionSuggestions = p["permission_suggestions"]
                event.capabilities = [.allow, .deny, .pass]
            }
        case "ShellPermission", "MCPPermission":
            event.kind = .permission
            event.capabilities = [.allow, .deny, .pass]
        case "PreToolUse":
            if agent == .claude, tool == "AskUserQuestion" {
                event.kind = .question
                event.questions = AgentEvent.Question.parseList(input?["questions"])
                event.capabilities = [.answer, .pass]
            } else if agent == .claude, tool == "ExitPlanMode" {
                event.kind = .plan
                event.plan = input?["plan"]?.string
                event.capabilities = [.allow, .deny, .pass]
            } else if agent == .droid {
                event.kind = .permission
                event.capabilities = [.allow, .deny, .pass]
            } else {
                event.kind = .toolStart
            }
        case "PostToolUse": event.kind = .toolEnd
        case "PostToolUseFailure": event.kind = .toolFailed
        case "Notification":
            event.kind = .notification
            if agent == .gemini, event.notificationType == "ToolPermission" {
                event.message = event.message ?? L10n.t("도구 실행 승인을 기다리고 있어요")
            }
        case "Stop":
            event.kind = .stop
            event.message = p.firstString("last_assistant_message", "prompt_response", "last-assistant-message", "lastAssistantMessage")
            // 답장은 사용자가 직접 입력할 때만 보내므로 stop_hook_active여도 무한 루프 위험이 없다.
            if supportsStopReply(agent) { event.capabilities = [.reply, .pass] }
        case "SubagentStop": event.kind = .subagentStop
        case "StopFailure":
            event.kind = .error
            event.message = event.message ?? p.firstString("error", "errorMessage")
        case "SessionStart": event.kind = .sessionStart
        case "SessionEnd": event.kind = .sessionEnd
        case "UserPromptSubmit":
            event.kind = .promptSubmit
            event.message = p.firstString("prompt")
        case "PreCompact": event.kind = .compact
        case "Custom":
            event.kind = .custom
        default:
            event.kind = .other
        }
        return event
    }

    public static func toolName(in p: JSONValue, agent: AgentKind) -> String? {
        if let n = p.firstString("tool_name", "toolName") { return n }
        if let n = p["toolCall"]?["name"]?.string { return n }
        if agent == .cursor {
            if p["command"] != nil { return "Shell" }
            if let n = p.firstString("mcp_tool_name") { return n }
        }
        return p["tool"]?.string
    }

    public static func toolInput(in p: JSONValue, agent: AgentKind) -> JSONValue? {
        if let input = p["tool_input"] ?? p["toolInput"] { return parseIfString(input) }
        if let args = p["toolArgs"] { return parseIfString(args) }
        if let args = p["toolCall"]?["args"]?.object {
            var flat = args
            for (src, dst) in [("CommandLine", "command"), ("FilePath", "file_path"), ("Path", "path"), ("Url", "url"), ("Query", "query")] {
                if let v = flat[src] { flat[dst] = v }
            }
            return .object(flat)
        }
        if agent == .cursor, let cmd = p["command"]?.string {
            var o: [String: JSONValue] = ["command": .string(cmd)]
            if let cwd = p["cwd"] { o["cwd"] = cwd }
            return .object(o)
        }
        return nil
    }

    private static func parseIfString(_ v: JSONValue) -> JSONValue {
        if case .string(let s) = v, let parsed = JSONValue.parse(s), parsed.object != nil { return parsed }
        return v
    }

    // MARK: - 출력

    /// 앱 응답을 에이전트가 이해하는 stdout으로 바꾼다. nil = 출력 없음(기본 동작).
    public static func render(_ reply: HookReply, envelope env: HookEnvelope) -> String? {
        let agent = AgentKind(loose: env.agent)
        let p = env.payload
        let ev = canonicalEvent(p["hook_event_name"]?.string ?? env.event, agent: agent)
        let tool = toolName(in: p, agent: agent)

        if reply.decision == .pass { return fallbackOutput(agent: agent, event: env.event) }

        switch (agent, ev) {
        case (.cursor, "ShellPermission"), (.cursor, "MCPPermission"):
            switch reply.decision {
            case .allow: return json(["permission": "allow"])
            case .deny:
                let msg = reply.message ?? L10n.t("사용자가 Pawmit에서 거절했어요")
                return json(["permission": "deny", "user_message": .string(msg), "agent_message": .string(msg)])
            default: return fallbackOutput(agent: agent, event: env.event)
            }

        case (.cursor, "Stop"):
            if reply.decision == .reply, let msg = reply.message, !msg.isEmpty {
                return json(["followup_message": .string(msg)])
            }
            return "{}"

        case (.copilot, "PermissionRequest"):
            switch reply.decision {
            case .allow: return json(["behavior": "allow"])
            case .deny:
                var o: [String: JSONValue] = ["behavior": "deny", "message": .string(reply.message ?? "Denied from Pawmit")]
                if reply.interrupt == true { o["interrupt"] = true }
                return json(.object(o))
            default: return "{}"
            }

        case (_, "PermissionRequest"):
            var decision: [String: JSONValue] = [:]
            switch reply.decision {
            case .allow:
                decision["behavior"] = "allow"
                // Codex는 updatedPermissions를 아직 받지 않는다(fail closed) → Claude/Qwen만 "항상 허용"
                if agent != .codex, let perms = reply.updatedPermissions, perms.array?.isEmpty == false {
                    decision["updatedPermissions"] = perms
                }
            case .deny:
                decision["behavior"] = "deny"
                decision["message"] = .string(reply.message ?? "Denied from Pawmit")
                if agent != .codex, reply.interrupt == true { decision["interrupt"] = true }
            default:
                return fallbackOutput(agent: agent, event: env.event)
            }
            return json(["hookSpecificOutput": .object(["hookEventName": "PermissionRequest", "decision": .object(decision)])])

        case (_, "PreToolUse"):
            var out: [String: JSONValue] = ["hookEventName": "PreToolUse"]
            let input = toolInput(in: p, agent: agent)
            switch reply.decision {
            case .answer where tool == "AskUserQuestion":
                guard let answers = reply.answers, !answers.isEmpty else { return nil }
                out["permissionDecision"] = "allow"
                out["permissionDecisionReason"] = "Answered from Pawmit"
                out["updatedInput"] = .object([
                    "questions": input?["questions"] ?? .array([]),
                    "answers": .object(answers.mapValues { .string($0) }),
                ])
            case .allow:
                out["permissionDecision"] = "allow"
                out["permissionDecisionReason"] = tool == "ExitPlanMode" ? "Plan approved from Pawmit" : "Allowed from Pawmit"
                // AskUserQuestion·ExitPlanMode는 allow만으로는 부족하고 updatedInput이 필요하다(공식 문서).
                if tool == "ExitPlanMode", let input { out["updatedInput"] = input }
            case .deny:
                out["permissionDecision"] = "deny"
                out["permissionDecisionReason"] = .string(reply.message ?? "Denied from Pawmit")
            default:
                return fallbackOutput(agent: agent, event: env.event)
            }
            return json(["hookSpecificOutput": .object(out)])

        case (_, "Stop"):
            if reply.decision == .reply, let msg = reply.message, !msg.isEmpty, supportsStopReply(agent) {
                return json(["decision": "block", "reason": .string(msg)])
            }
            return fallbackOutput(agent: agent, event: env.event)

        default:
            return fallbackOutput(agent: agent, event: env.event)
        }
    }

    static func json(_ v: JSONValue) -> String { v.encoded() }
}
