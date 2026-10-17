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
                if let size = attrs[.size] as? Int, size > PetBundle.maxTotalBytes * 2 { throw PetBundle.BundleError.tooLarge }
                let data = try Data(contentsOf: url)
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

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
