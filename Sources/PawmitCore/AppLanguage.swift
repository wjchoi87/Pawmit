import Foundation

/// 표시 언어 설정. 한국어·영어만 지원한다(예전 "system" 값은 시스템 언어로 정한다).
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case ko
    case en

    /// 설정 창에 보여줄 이름. 언어 이름 자체는 번역하지 않는다.
    public var displayName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        }
    }

    /// 설정에 값이 없을 때: 시스템 첫 언어가 한국어면 한국어, 아니면 영어
    public static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? .ko : .en
    }

    /// config.json 값 해석 (모르는 값·예전 "system"은 시스템 기본)
    public static func from(config value: String) -> AppLanguage {
        AppLanguage(rawValue: value) ?? systemDefault
    }

    /// 시스템이 그리는 열기·저장 패널 같은 문구는 다음 실행부터 이 언어를 따른다.
    public func applyToAppleLanguages() {
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }
}

/// 현재 언어는 설정의 language 값(L10n.current)이고 바꾸면 바로 반영된다. CLI도 같은 config.json 값을 따른다.
/// 문구 조회. 한국어 원문을 키로 쓰고 en.lproj에만 번역을 둔다 —
/// 한국어에서는 키가 그대로 돌아오므로 기존 문구가 바뀌지 않는다.
public enum L10n {
    private static let lock = NSLock()
    private static var _current: AppLanguage?
    private static var enTable: [String: String]?

    /// 현재 표시 언어. 처음 읽을 때 config.json의 language로 정한다.
    public static var current: AppLanguage {
        get {
            lock.lock()
            let cached = _current
            lock.unlock()
            if let cached { return cached }
            let lang = AppLanguage.from(config: PawmitConfig.load().language)
            lock.lock()
            if _current == nil { _current = lang }
            let result = _current ?? lang
            lock.unlock()
            return result
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
        }
    }

    public static var languageCode: String { current.rawValue }
    public static var isKorean: Bool { current == .ko }

    /// 정적 문구 조회 (키 = 한국어 원문)
    public static func t(_ key: String) -> String {
        guard current == .en else { return key }
        return englishTable()[key] ?? key
    }

    /// 자리표시자(%@, %lld …) 문구 조회
    public static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// en.lproj/Localizable.strings. 앱 번들 안, 또는 실행 파일 옆(~/.pawmit/bin/en.lproj — CLI)에서 찾는다.
    private static func englishTable() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let enTable { return enTable }
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") {
            candidates.append(u)
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("en.lproj/Localizable.strings"))
        }
        let table = candidates.lazy.compactMap { NSDictionary(contentsOf: $0) as? [String: String] }.first ?? [:]
        enTable = table
        return table
    }
}
