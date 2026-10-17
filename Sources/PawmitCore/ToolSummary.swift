import Foundation

/// 승인 말풍선에 보여줄 도구 요약. 위험한 승인을 막으려고 명령·경로는 자르지 않고 전문을 `body`에 담는다.
public struct ToolSummary: Equatable, Sendable {
    public enum Risk: Int, Sendable { case low, medium, high }

    /// 말풍선 제목 (예: "명령 실행해도 돼?")
    public var headline: String
    /// 도구·대상 한 줄 (예: "Bash · npm test")
    public var subject: String
    /// 고정폭으로 보여줄 본문 (명령 전문, diff, JSON)
    public var body: String?
    /// 도구가 스스로 적은 설명
    public var note: String?
    public var risk: Risk

    public static func make(toolName: String?, input: JSONValue?, agent: AgentKind) -> ToolSummary {
        let name = toolName ?? L10n.t("도구")
        let lower = name.lowercased()
        let i = input ?? .object([:])

        if ["bash", "shell", "run_shell_command", "execute", "exec_command", "local_shell", "powershell", "terminal"].contains(lower)
            || lower.hasPrefix("bash") {
            let cmd = i.firstString("command", "cmd", "commandLine", "CommandLine") ?? i["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
            return ToolSummary(headline: L10n.t("명령 실행해도 돼?"), subject: "\(name) · \(firstLine(cmd, max: 60))",
                               body: cmd, note: i.firstString("description", "justification"), risk: shellRisk(cmd))
        }
        if ["edit", "multiedit", "write", "create", "apply_patch", "applypatch", "write_file", "replace", "str_replace_editor", "notebookedit", "edit_file"].contains(lower) {
            let path = i.firstString("file_path", "path", "filePath", "notebook_path") ?? ""
            var body: String?
            if let old = i["old_string"]?.string, let new = i["new_string"]?.string {
                body = diffish(old: old, new: new)
            } else if let edits = i["edits"]?.array {
                body = edits.compactMap { e -> String? in
                    guard let o = e["old_string"]?.string, let n = e["new_string"]?.string else { return nil }
                    return diffish(old: o, new: n)
                }.joined(separator: "\n···\n")
            } else if let content = i.firstString("content", "file_text", "new_source") {
                body = clip(content, lines: 40)
            } else if let patch = i.firstString("patch", "input", "command") {
                body = clip(patch, lines: 60)
            }
            let shortPath = path.isEmpty ? "" : " · " + (path as NSString).lastPathComponent
            return ToolSummary(headline: L10n.t("파일 고쳐도 돼?"), subject: "\(name)\(shortPath)", body: body.map { path.isEmpty ? $0 : "\(path)\n\n\($0)" } ?? path,
                               note: nil, risk: .medium)
        }
        if ["webfetch", "web_fetch", "fetch"].contains(lower) {
            let url = i.firstString("url") ?? ""
            return ToolSummary(headline: L10n.t("웹페이지 열어봐도 돼?"), subject: "\(name) · \(url)", body: url, note: i.firstString("prompt"), risk: .low)
        }
        if ["websearch", "web_search", "google_web_search"].contains(lower) {
            let q = i.firstString("query") ?? ""
            return ToolSummary(headline: L10n.t("검색해봐도 돼?"), subject: "\(name) · \(q)", body: nil, note: nil, risk: .low)
        }
        if lower.hasPrefix("mcp__") || lower.contains("mcp") {
            let parts = name.components(separatedBy: "__")
            let pretty = parts.count >= 3 ? "\(parts[1]) · \(parts[2...].joined(separator: "__"))" : name
            return ToolSummary(headline: L10n.t("외부 도구 써도 돼?"), subject: "MCP · \(pretty)", body: clip(i.encoded(pretty: true), lines: 30), note: nil, risk: .medium)
        }
        if ["read", "read_file", "view", "glob", "grep", "ls", "list_directory", "search_file_content"].contains(lower) {
            let path = i.firstString("file_path", "path", "pattern") ?? ""
            return ToolSummary(headline: L10n.t("읽어봐도 돼?"), subject: "\(name) · \(path)", body: nil, note: nil, risk: .low)
        }
        let json = i.object?.isEmpty == false ? clip(i.encoded(pretty: true), lines: 30) : nil
        return ToolSummary(headline: L10n.format("%@ 써도 돼?", name), subject: name, body: json, note: i.firstString("description"), risk: .medium)
    }

    /// 읽기 전용이라 Pawmit이 끼어들 필요 없는 도구 (Copilot·Droid처럼 모든 도구 호출에 hook이 오는 에이전트용)
    public static func isReadOnly(toolName: String?) -> Bool {
        guard let lower = toolName?.lowercased() else { return false }
        return ["read", "read_file", "view", "glob", "grep", "ls", "list_directory", "search_file_content", "todowrite",
                "todoread", "web_search", "websearch", "fetch_docs", "think", "report_intent"].contains(lower)
    }

    static func shellRisk(_ cmd: String) -> Risk {
        let c = cmd.lowercased()
        let high = ["rm -rf", "rm -fr", "sudo ", "mkfs", "dd if=", "chmod -r 777", "> /dev/", "git push --force", "git push -f",
                    "git reset --hard", "drop table", "truncate ", "curl | sh", "| sh", "| bash", "shutdown", "killall", ":(){"]
        if high.contains(where: { c.contains($0) }) { return .high }
        let medium = ["rm ", "mv ", "git push", "git commit", "npm publish", "docker ", "kubectl ", "brew ", "pip install", "npm install"]
        if medium.contains(where: { c.contains($0) }) { return .medium }
        return .low
    }

    static func firstLine(_ s: String, max: Int) -> String {
        let line = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    static func clip(_ s: String, lines: Int) -> String {
        let all = s.components(separatedBy: "\n")
        guard all.count > lines else { return s }
        return all.prefix(lines).joined(separator: "\n") + "\n" + L10n.format("… (%lld줄 더)", all.count - lines)
    }

    static func diffish(old: String, new: String) -> String {
        let o = clip(old, lines: 12).split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }
        let n = clip(new, lines: 12).split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }
        return (o + n).joined(separator: "\n")
    }
}
