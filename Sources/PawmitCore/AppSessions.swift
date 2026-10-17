import Foundation

/// 데스크탑 앱 안에서 도는 에이전트 세션을 그 앱의 해당 대화로 여는 주소 만들기.
///
/// - Claude 데스크탑(Code 탭): hook의 `session_id`는 CLI 세션 id라서, 앱이 쓰는 `local_…` id로 바꿔야 한다.
///   앱은 `~/Library/Application Support/Claude/claude-code-sessions/<계정>/<조직>/local_*.json`에
///   `sessionId`(local_…)와 `cliSessionId`를 같이 저장하고, `claude://code/continue?session=local_…`로 그 대화를 연다.
/// - Codex 앱: `codex://threads/<id>` (스레드 id = hook의 session_id).
public enum AppSessions {
    public static let claudeDesktopBundle = "com.anthropic.claudefordesktop"
    public static let codexAppBundle = "com.openai.codex"

    public static var claudeSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// CLI 세션 id → Claude 데스크탑의 local_ 세션 id (보관된 세션은 앱이 열지 않으므로 뺀다)
    public static func claudeLocalSessionID(cliSessionID: String, root: URL = claudeSessionsRoot) -> String? {
        guard isSafeID(cliSessionID) else { return nil }
        let fm = FileManager.default
        let needle = Data(cliSessionID.utf8)
        // 계정/조직 두 단계 아래에 local_*.json
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    // 대부분은 id 문자열이 없으니 JSON을 풀기 전에 바이트로 먼저 거른다
                    guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                          let v = JSONValue.parse(data), v["cliSessionId"]?.string == cliSessionID,
                          v["isArchived"]?.bool != true,
                          let local = v["sessionId"]?.string, isLocalID(local) else { continue }
                    return local
                }
            }
        }
        return nil
    }

    public static func claudeDesktopURL(localSessionID: String) -> URL? {
        guard isLocalID(localSessionID) else { return nil }
        return URL(string: "claude://code/continue?session=\(localSessionID)")
    }

    public static func codexThreadURL(sessionID: String) -> URL? {
        guard isSafeID(sessionID) else { return nil }
        return URL(string: "codex://threads/\(sessionID)")
    }

    /// 앱이 받아들이는 local_ id 형식 (Claude 데스크탑의 검사와 같은 규칙)
    static func isLocalID(_ s: String) -> Bool {
        guard s.hasPrefix("local_") else { return false }
        let rest = s.dropFirst(6)
        return (1...64).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 주소에 그대로 넣어도 되는 id (영문·숫자·-·_ 만)
    static func isSafeID(_ s: String) -> Bool {
        (1...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
