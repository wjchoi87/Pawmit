import Foundation

/// 펫 채팅 답변 끝의 행동 태그 `[[home]]` 등을 뽑아낸다.
public enum ChatActions {
    public static let known: Set<String> = ["home", "out", "eat", "sleep", "play", "doodle", "trash", "chase", "happy", "sad", "wave"]

    public static func extract(_ text: String) -> (clean: String, actions: [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[\s*([a-zA-Z]+)\s*\]\]"#) else { return (text, []) }
        let ns = text as NSString
        var actions: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if known.contains(name), !actions.contains(name) { actions.append(name) }
        }
        let clean = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, actions)
    }

    /// 사용자 문장에서 바로 알아들을 수 있는 명령 (AI 호출 없이 즉시 실행)
    public static func directCommand(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: " ", with: "")
        let ko = L10n.isKorean
        let homeWords = ko ? ["집에가", "집으로가", "들어가", "집에들어가", "가서자"] : ["gohome", "home", "gotobed"]
        let outWords = ko ? ["나와", "나와라", "나와봐"] : ["comeout", "getout", "outside"]
        if homeWords.contains(where: { t.contains($0) }) { return "home" }
        if outWords.contains(where: { t.hasPrefix($0) || t == $0 }) { return "out" }
        return nil
    }

    /// stream-json 한 줄에서 텍스트 조각·최종 결과·세션 id를 꺼낸다 (Claude Code `-p --output-format stream-json`)
    public struct StreamPiece: Equatable {
        public var delta: String?
        public var result: String?
        public var sessionID: String?
        public var isError = false
    }

    public static func parseStreamLine(_ line: String) -> StreamPiece? {
        guard let v = JSONValue.parse(line), let type = v["type"]?.string else { return nil }
        var piece = StreamPiece()
        piece.sessionID = v["session_id"]?.string
        switch type {
        case "stream_event":
            if v["event"]?["type"]?.string == "content_block_delta", v["event"]?["delta"]?["type"]?.string == "text_delta" {
                piece.delta = v["event"]?["delta"]?["text"]?.string
            }
        case "result":
            piece.result = v["result"]?.string
            piece.isError = v["is_error"]?.bool ?? (v["subtype"]?.string != "success")
        default:
            break
        }
        return piece
    }
}
