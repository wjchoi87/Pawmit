import Foundation

/// 말풍선에 그릴 만큼만 다루는 가벼운 마크다운 블록 나누기.
/// 줄 안 꾸밈(굵게·기울임·`코드`·링크)은 그리는 쪽에서 `AttributedString(markdown:)`으로 처리하고,
/// 여기서는 제목·목록·코드 블록·인용·구분선·표·문단만 나눈다. 문단 안 줄바꿈은 그대로 둔다(대화체 메시지라서).
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// marker: "•" 또는 "1." 같은 번호, indent: 들여쓰기 단계(0부터)
    case listItem(indent: Int, marker: String, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case rule
    /// 첫 행이 머리글
    case table(rows: [[String]])

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 코드 블록 ``` 또는 ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            // 구분선
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let ch = trimmed.first, "-*_".contains(ch) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            // 제목
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.first == " " {
                    flush()
                    blocks.append(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }
            // 표: | a | b | 다음 줄이 |---|---|
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                var rows = [cells(trimmed)]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(cells(t))
                    i += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }
            // 인용
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            // 목록
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                i += 1
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let indent = min(4, spaces / 2)
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            var text = String(rest.dropFirst(2))
            var marker = "•"
            // 체크박스
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return .listItem(indent: indent, marker: marker, text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(indent: indent, marker: String(digits) + ".", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
