import Foundation

/// Pawmit이 쓰는 파일 위치. 모든 런타임 데이터는 `~/.pawmit` 아래에 둔다.
/// `PAWMIT_HOME` 환경 변수로 바꿀 수 있다(테스트·다중 인스턴스용).
public enum PawmitPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["PAWMIT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pawmit", isDirectory: true)
    }

    /// Unix socket 경로. sockaddr_un.sun_path 한도(104 bytes) 때문에 짧게 유지한다.
    public static var socket: URL { home.appendingPathComponent("pawmit.sock") }
    public static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public static var cliLink: URL { binDir.appendingPathComponent("pawmit") }
    public static var petsDir: URL { home.appendingPathComponent("pets", isDirectory: true) }
    public static var config: URL { home.appendingPathComponent("config.json") }
    public static var state: URL { home.appendingPathComponent("state.json") }
    /// API 방식 대화 기록 (재시작 후 이어 보내려고) — CLI는 세션 resume으로 이어간다
    public static var chatHistory: URL { home.appendingPathComponent("chat-history.json") }
    public static var doodles: URL { home.appendingPathComponent("doodles.json") }
    public static var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }
    public static var log: URL { home.appendingPathComponent("pawmit.log") }

    /// `~/.pawmit`을 0700으로 만든다. socket·설정 백업이 다른 사용자에게 보이지 않게 하기 위함.
    public static func ensureHome() throws {
        let fm = FileManager.default
        for dir in [home, binDir, petsDir, backups] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}
