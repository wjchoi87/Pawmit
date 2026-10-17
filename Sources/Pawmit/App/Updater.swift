import AppKit
import Foundation
import PawmitCore

/// 자동 업데이트: 설정의 updateURL에서 update.json(버전·zip 주소)을 읽어 새 버전이 있으면
/// zip을 내려받아 현재 Pawmit.app을 교체하고 다시 띄운다. 외부 의존성 없이 URLSession + ditto로 처리한다.
///
/// update.json 형식:
///     { "version": "0.3.0", "url": "https://…/Pawmit-0.3.0.zip", "notes": "바뀐 점" }
/// zip 안에는 Pawmit.app이 들어 있다. 개인 배포(ad-hoc 서명)를 전제로 한다.
@MainActor
final class Updater {
    struct Info: Codable {
        var version: String
        var url: String
        var notes: String?
    }

    enum UpdateError: LocalizedError {
        case noServer, badJSON, badVersion, download(String)
        var errorDescription: String? {
            switch self {
            case .noServer: return L10n.t("업데이트 서버 주소가 설정돼 있지 않아요 (설정 → 일반 → 업데이트).")
            case .badJSON: return L10n.t("update.json을 읽을 수 없어요.")
            case .badVersion: return L10n.t("버전 표기를 이해할 수 없어요 (예: 0.3.0).")
            case .download(let m): return L10n.format("내려받기 실패: %@", m)
            }
        }
    }

    let config: PawmitConfig
    var onStateChange: ((String?) -> Void)?

    /// 진행 상태 문구 (nil = 대기 아님)
    private(set) var status: String? {
        didSet { onStateChange?(status) }
    }

    init(config: PawmitConfig) {
        self.config = config
        Self.cleanupLeftovers()
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// a가 b보다 큰지 (0.1 < 0.2 < 0.2.1 < 1.0)
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let clean = s.split(separator: "-").first.map(String.init) ?? s
            return clean.split(separator: ".").compactMap { Int($0) }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// update.json을 읽어 새 버전이면 Info를 돌려준다 (같거나 오래면 nil)
    func check() async throws -> Info? {
        guard let raw = config.updateURL?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw) else { throw UpdateError.noServer }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(from: url) }
        catch { throw UpdateError.badJSON }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badJSON }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard Self.isNewer(info.version, than: Self.currentVersion) else { return nil }
        return info
    }

    /// zip 내려받기 → 해제 → 현재 앱 교체 → 새 앱 실행. 성공하면 이 앱은 종료된다.
    func downloadAndInstall(_ info: Info) async throws {
        status = L10n.format("내려받는 중… %@", info.version)
        guard let zipURL = URL(string: info.url) else { throw UpdateError.badJSON }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zipPath = tmp.appendingPathComponent("update.zip")
        do {
            let (zipData, _) = try await URLSession.shared.data(from: zipURL)
            try zipData.write(to: zipPath)
        } catch { throw UpdateError.download(error.localizedDescription) }
        status = L10n.t("설치하는 중…")
        // ditto로 zip 해제 (앱 번들 권한·xattr 보존)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipPath.path, tmp.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw UpdateError.download(L10n.t("zip 해제 실패")) }
        guard FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Pawmit.app").path) else {
            throw UpdateError.download(L10n.t("zip 안에 Pawmit.app이 없어요"))
        }
        // 교체: 새 앱을 잠깐 옆으로 옮기고, 실행 중인 앱 이름을 바꾼 뒤 새 앱을 제자리에
        let fm = FileManager.default
        let cur = Bundle.main.bundleURL                          // …/Pawmit.app
        let newApp = tmp.appendingPathComponent("Pawmit.app")
        let staging = cur.deletingLastPathComponent().appendingPathComponent("Pawmit.new.app")
        let oldApp = cur.deletingLastPathComponent().appendingPathComponent("Pawmit.old.app")
        try? fm.removeItem(at: staging)
        try fm.moveItem(at: newApp, to: staging)
        try? fm.removeItem(at: oldApp)
        try fm.moveItem(at: cur, to: oldApp)
        try fm.moveItem(at: staging, to: cur)
        status = L10n.t("다시 시작하는 중…")
        // 새 앱 실행 후 종료 (실행 실패 대비 1초 대기)
        NSWorkspace.shared.openApplication(at: cur, configuration: .init()) { _, _ in }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        NSApp.terminate(nil)
    }

    /// 지난 업데이트가 남긴 Pawmit.old.app 정리
    static func cleanupLeftovers() {
        let fm = FileManager.default
        let dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for name in ["Pawmit.old.app", "Pawmit.new.app"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
