import AppKit
import UniformTypeIdentifiers
import PawmitCore

/// 펫 내보내기·가져오기 (.pawmitpet). 형식과 검사는 PawmitCore `PetBundle`.
@MainActor
extension Director {
    static var petBundleType: UTType { UTType(filenameExtension: PetBundle.fileExtension, conformingTo: .json) ?? .json }

    /// 펫 하나를 .pawmitpet 데이터로. 기본 펫은 정의만, 커스텀·Codex 펫은 폴더 통째로.
    func petBundleData(for id: String) throws -> (Data, String) {
        if id.hasPrefix("folder:") {
            let folder = PawmitPaths.petsDir.appendingPathComponent(String(id.dropFirst("folder:".count)))
            return (try PetBundle.export(folder: folder), folder.lastPathComponent)
        }
        if id.hasPrefix("codex:") {
            let folder = URL(fileURLWithPath: String(id.dropFirst("codex:".count)))
            return (try PetBundle.export(folder: folder), folder.lastPathComponent)
        }
        guard var def = PetCatalog.builtin(id)?.object else { throw PetBundle.BundleError.empty }
        // 받는 사람에게는 커스텀 펫 한 마리가 된다 (기본 펫 id는 빼고, 고양이는 지금 털색으로)
        def.removeValue(forKey: "id")
        if def["kind"]?.string == "cat" { def["coat"] = .string(config.catCoat) }
        let name = def["name"]?.string ?? id
        return (PetBundle.export(pet: .object(def), name: name), id)
    }

    func exportPetWithPanel(id: String) {
        do {
            let (data, base) = try petBundleData(for: id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.petBundleType]
            panel.nameFieldStringValue = "\(base).\(PetBundle.fileExtension)"
            panel.message = L10n.t("이 파일을 다른 사람에게 주면 Pawmit에서 열어 같은 펫을 데려갈 수 있어요.")
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert(L10n.t("내보내지 못했어요"), error.localizedDescription)
        }
    }

    /// 커스텀 펫 전부와 펫 설정(기본 펫 스타일·메인 펫·친구)을 파일 하나로. 다른 Mac에서 가져오면 그대로 복원된다.
    func exportAllPetsWithPanel() {
        do {
            let (data, left) = try PetBackup.export(petsDir: PawmitPaths.petsDir, config: config)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.petBundleType]
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            panel.nameFieldStringValue = "Pawmit-pets-\(day).\(PetBundle.fileExtension)"
            panel.message = L10n.t("커스텀 펫 전부와 기본 펫 설정(스타일·메인 펫·친구)을 파일 하나로 저장해요. 가져오기로 그대로 복원할 수 있어요.")
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            if !left.isEmpty {
                alert(L10n.t("일부 펫은 빠졌어요"), L10n.format("그림이 없거나 너무 커서 담지 못했어요: %@", left.joined(separator: ", ")))
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert(L10n.t("내보내지 못했어요"), error.localizedDescription)
        }
    }

    func importPetWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.petBundleType]
        panel.allowsMultipleSelection = true
        panel.message = L10n.t("가져올 펫 파일(.pawmitpet)을 골라요.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importPets(panel.urls)
    }

    /// Finder에서 연 파일·패널에서 고른 파일. 남이 만든 파일이므로 내용을 보여주고 확인받은 뒤 새 폴더에 푼다.
    func importPets(_ urls: [URL]) {
        for url in urls {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attrs[.size] as? Int, size > PetBackup.maxTotalBytes * 2 { throw PetBackup.BackupError.tooLarge }
                let data = try Data(contentsOf: url)
                if PetBackup.isBackup(data) {
                    try importBackup(data)
                    continue
                }
                if data.count > PetBundle.maxTotalBytes * 2 { throw PetBundle.BundleError.tooLarge }
                let s = try PetBundle.inspect(data)
                let kind = ["chibi": L10n.t("조립 펫"), "cat": L10n.t("고양이"), "image": L10n.t("그림 펫")][s.kind] ?? s.kind
                var info = L10n.format("종류: %@", kind)
                if !s.fileNames.isEmpty { info += "\n" + L10n.format("그림 %lld장: %@", s.fileNames.count, s.fileNames.prefix(6).joined(separator: ", ")) }
                if !s.warnings.isEmpty { info += "\n\n" + L10n.t("주의: ") + s.warnings.joined(separator: "; ") }
                let ask = NSAlert()
                ask.messageText = L10n.format("'%@' 펫을 데려올까요?", s.name)
                ask.informativeText = info + "\n\n" + L10n.t("~/.pawmit/pets 에 새 폴더로 저장돼요. 기존 펫은 덮어쓰지 않아요.")
                ask.addButton(withTitle: L10n.t("가져오기"))
                ask.addButton(withTitle: L10n.t("취소"))
                NSApp.activate(ignoringOtherApps: true)
                guard ask.runModal() == .alertFirstButtonReturn else { continue }
                let folder = try PetBundle.install(data, into: PawmitPaths.petsDir)
                let id = "folder:\(folder.lastPathComponent)"
                Log.info("펫 가져옴: \(s.name) → \(folder.lastPathComponent)")
                let done = NSAlert()
                done.messageText = L10n.format("'%@'이(가) 왔어요!", s.name)
                if let img = previewImage(for: id) { done.icon = img }
                done.addButton(withTitle: L10n.t("메인 펫으로 쓰기"))
                done.addButton(withTitle: L10n.t("친구로 부르기"))
                done.addButton(withTitle: L10n.t("나중에"))
                switch done.runModal() {
                case .alertFirstButtonReturn: adoptPet(id, asFriend: false)
                case .alertSecondButtonReturn: adoptPet(id, asFriend: true)
                default: break
                }
            } catch {
                alert(L10n.format("'%@'을(를) 가져오지 못했어요", url.lastPathComponent), error.localizedDescription)
            }
        }
    }

    /// 백업 파일: 담긴 펫을 보여주고, 펫만 또는 펫과 설정까지 복원한다. 같은 펫은 건너뛰고 기존 펫은 덮어쓰지 않는다.
    private func importBackup(_ data: Data) throws {
        let s = try PetBackup.inspect(data)
        let ask = NSAlert()
        ask.messageText = L10n.format("백업에서 펫 %lld마리를 가져올까요?", s.petNames.count)
        var info = s.petNames.isEmpty ? L10n.t("커스텀 펫은 없고 펫 설정만 있어요.") : s.petNames.prefix(8).joined(separator: ", ")
        if s.petNames.count > 8 { info += " " + L10n.format("외 %lld마리", s.petNames.count - 8) }
        info += "\n\n" + L10n.t("~/.pawmit/pets 에 새 폴더로 저장돼요. 이미 있는 똑같은 펫은 건너뛰고, 기존 펫은 덮어쓰지 않아요.")
        if s.settings != nil { info += "\n" + L10n.t("펫 설정(기본 펫 스타일·메인 펫·친구)도 백업대로 되돌릴 수 있어요.") }
        ask.informativeText = info
        if s.settings != nil { ask.addButton(withTitle: L10n.t("펫과 설정 복원")) }
        ask.addButton(withTitle: L10n.t("펫만 가져오기"))
        ask.addButton(withTitle: L10n.t("취소"))
        NSApp.activate(ignoringOtherApps: true)
        let choice = ask.runModal()
        let withSettings = s.settings != nil && choice == .alertFirstButtonReturn
        let petsOnly = s.settings != nil ? choice == .alertSecondButtonReturn : choice == .alertFirstButtonReturn
        guard withSettings || petsOnly else { return }
        let result = try PetBackup.restore(data, into: PawmitPaths.petsDir)
        Log.info("백업 가져옴: 새 펫 \(result.installed.count), 건너뜀 \(result.skipped.count)")
        if withSettings, let settings = s.settings {
            var c = config
            settings.apply(to: &c, renamed: result.renamed) { id in
                if let folder = PetStyles.folder(id) { return FileManager.default.fileExists(atPath: folder.path) }
                if id.hasPrefix("codex:") { return FileManager.default.fileExists(atPath: String(id.dropFirst("codex:".count))) }
                return PetCatalog.builtin(id) != nil
            }
            applyConfig(c, save: true)
        }
        settingsWindow.refresh()
        let done = NSAlert()
        done.messageText = L10n.format("펫 %lld마리를 가져왔어요", result.installed.count)
        if !result.skipped.isEmpty { done.informativeText = L10n.format("이미 있는 펫 %lld마리는 건너뛰었어요.", result.skipped.count) }
        NSApp.activate(ignoringOtherApps: true)
        done.runModal()
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
