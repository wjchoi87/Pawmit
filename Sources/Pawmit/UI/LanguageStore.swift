import SwiftUI
import PawmitCore

/// 현재 표시 언어를 SwiftUI 화면에 알려 준다. 바뀌면 창을 닫지 않고 내용만 새 언어로 다시 그린다.
@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published var language: AppLanguage = L10n.current
}

/// 창·말풍선의 SwiftUI 루트에 붙인다. locale 환경값으로 Text("한국어 원문") 같은 정적 문구를 현재 언어로 조회하고,
/// 언어가 바뀌면 id를 바꿔 L10n.t로 만든 문구까지 전부 다시 계산한다.
private struct PawmitLocalized: ViewModifier {
    @ObservedObject private var store = LanguageStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: store.language.rawValue))
            .id(store.language)
    }
}

extension View {
    func pawmitLocalized() -> some View { modifier(PawmitLocalized()) }
}
