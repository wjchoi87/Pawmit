import AppKit
import PawmitCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var director: Director?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try PawmitPaths.ensureHome()
        } catch {
            fatalAlert(L10n.format("~/.pawmit 폴더를 만들 수 없어요: %@", error.localizedDescription))
            return
        }
        // 이미 다른 Pawmit이 떠 있으면 종료 (socket 하나를 두 앱이 나눠 쓰면 응답이 꼬인다)
        if UnixSocketServer.isServing(path: PawmitPaths.socket.path) {
            let a = NSAlert()
            a.messageText = L10n.t("Pawmit이 이미 실행 중이에요")
            a.informativeText = L10n.t("메뉴바의 집 아이콘을 확인해 주세요.")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        installCLI()
        let config = PawmitConfig.load()
        if !FileManager.default.fileExists(atPath: PawmitPaths.config.path) { try? config.save() }
        let d = Director(config: config)
        director = d
        d.start()
        Log.info("Pawmit started (pet=\(config.pet))")
        #if DEBUG
        let mismatch = ChibiParts.catalogMismatches()
        if !mismatch.isEmpty { Log.info("부위 레지스트리와 PetCatalog 목록이 다릅니다: \(mismatch)") }
        #endif
        if !pendingImports.isEmpty {
            let urls = pendingImports
            pendingImports = []
            DispatchQueue.main.async { d.importPets(urls) }
        }
    }

    /// Finder에서 .pawmitpet 파일을 열면 펫 가져오기 (확인 창을 거친다)
    func application(_ application: NSApplication, open urls: [URL]) {
        let pets = urls.filter { $0.pathExtension.lowercased() == PetBundle.fileExtension }
        guard !pets.isEmpty else { return }
        if let director {
            director.importPets(pets)
        } else {
            pendingImports += pets
        }
    }

    private var pendingImports: [URL] = []

    func applicationWillTerminate(_ notification: Notification) {
        director?.shutdown()
    }

    /// 앱에 들어 있는 `pawmit-cli`를 `~/.pawmit/bin/pawmit`으로 복사한다.
    /// hook 설정은 이 고정 경로를 가리키므로 앱을 옮겨도 hook이 깨지지 않는다.
    private func installCLI() {
        let fm = FileManager.default
        guard let exe = Bundle.main.executableURL else { return }
        let candidates = [exe.deletingLastPathComponent().appendingPathComponent("pawmit-cli"),
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pawmit-cli")]
        guard let source = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            Log.info("pawmit-cli 를 찾지 못함 (개발 빌드면 swift build --product pawmit-cli)")
            return
        }
        let dest = PawmitPaths.cliLink
        installCLIStrings(next: dest)
        if let a = fm.contents(atPath: source.path), let b = fm.contents(atPath: dest.path), a == b { return }
        do {
            let tmp = dest.appendingPathExtension("tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: dest) }
            Log.info("pawmit CLI 설치: \(dest.path)")
        } catch {
            Log.info("pawmit CLI 설치 실패: \(error)")
        }
    }

    /// CLI도 앱과 같은 언어 설정을 따르도록 영어 문구 표를 CLI 옆(~/.pawmit/bin/en.lproj)에 둔다.
    /// `pawmit version`이 앱 버전을 알 수 있게 VERSION 파일도 함께 둔다.
    private func installCLIStrings(next cli: URL) {
        let fm = FileManager.default
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let file = cli.deletingLastPathComponent().appendingPathComponent("VERSION")
            if (try? String(contentsOf: file, encoding: .utf8)) != version {
                try? version.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        guard let src = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
              let data = fm.contents(atPath: src.path) else { return }
        let dir = cli.deletingLastPathComponent().appendingPathComponent("en.lproj", isDirectory: true)
        let dest = dir.appendingPathComponent("Localizable.strings")
        if fm.contents(atPath: dest.path) == data { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
    }

    private func fatalAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = L10n.t("Pawmit을 시작할 수 없어요")
        a.informativeText = text
        a.runModal()
        NSApp.terminate(nil)
    }
}
