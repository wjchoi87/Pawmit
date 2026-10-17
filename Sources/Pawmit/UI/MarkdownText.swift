import SwiftUI
import PawmitCore

/// 말풍선 본문. 설정에서 마크다운을 켜면 제목·목록·코드·인용·표·구분선과 줄 안 꾸밈(굵게·기울임·`코드`·링크)을 그리고,
/// 끄면 글자 그대로 보여준다. 글꼴·크기는 hook 알림 / 대화 설정을 따른다.
struct MarkdownText: View {
    var text: String
    var style: PawmitConfig.MessageText

    var body: some View {
        Group {
            if style.markdown {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
            } else {
                Text(text).font(PawTheme.text(style))
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.inline(s)).font(PawTheme.text(style))
        case .heading(let level, let s):
            Text(Self.inline(s)).font(PawTheme.text(style, .bold, scale: level == 1 ? 1.2 : level == 2 ? 1.12 : 1.04))
                .padding(.top, 2)
        case .listItem(let indent, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker).font(PawTheme.text(style, .semibold)).foregroundStyle(.secondary)
                Text(Self.inline(s)).font(PawTheme.text(style))
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .code(_, let s):
            Text(s)
                .font(PawTheme.text(style, mono: true))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        case .quote(let s):
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.22)).frame(width: 3)
                Text(Self.inline(s)).font(PawTheme.text(style)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let rows):
            let columns = rows.map(\.count).max() ?? 0
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(Self.inline(c < row.count ? row[c] : ""))
                                .font(PawTheme.text(style, r == 0 ? .semibold : .regular, scale: 0.95))
                        }
                    }
                    if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
        }
    }

    /// 줄 안 꾸밈만 (굵게·기울임·`코드`·링크·취소선). 해석이 안 되면 글자 그대로
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
