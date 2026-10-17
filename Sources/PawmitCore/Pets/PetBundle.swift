import Foundation
import ImageIO

/// 펫을 주고받는 파일(.pawmitpet).
///
/// 압축 파일 대신 JSON 한 개다. pet.json은 그대로 읽히는 객체로 넣고, 그림 파일만 base64로 넣는다.
/// 그래서 코드로 그리는 펫(chibi·cat)은 내보낸 파일 자체가 사람·에이전트가 읽고 고칠 수 있는 JSON이다.
///
///     { "pawmitPet": 1, "name": "몽글이", "pet": { "kind": "chibi", ... },
///       "files": { "idle.gif": "<base64>", "spritesheet.webp": "<base64>" } }
///
/// 가져오기는 남이 만든 파일을 여는 것이므로 데이터만 받는다: 파일 이름·확장자·크기를 제한하고,
/// 그림은 ImageIO로 실제로 읽히는지 확인하며, 실행 파일·경로(../)는 거부한다.
public enum PetBundle {
    public static let fileExtension = "pawmitpet"
    public static let maxTotalBytes = 25 * 1024 * 1024
    public static let maxFiles = 64
    public static let imageExtensions: Set<String> = ["png", "gif", "webp", "apng", "jpg", "jpeg", "heic"]

    public enum BundleError: LocalizedError, Equatable {
        case notABundle
        case unsupportedVersion(Int)
        case tooLarge
        case tooManyFiles
        case badFileName(String)
        case badFileType(String)
        case unreadableImage(String)
        case invalidPet([String])
        case empty

        public var errorDescription: String? {
            switch self {
            case .notABundle: return L10n.t("Pawmit 펫 파일(.pawmitpet)이 아닙니다")
            case .unsupportedVersion(let v): return L10n.format("더 새로운 버전(%lld)의 펫 파일입니다. Pawmit을 업데이트해 주세요", v)
            case .tooLarge: return L10n.format("파일이 너무 큽니다 (최대 %lldMB)", maxTotalBytes / 1024 / 1024)
            case .tooManyFiles: return L10n.format("파일이 너무 많습니다 (최대 %lld개)", maxFiles)
            case .badFileName(let n): return L10n.format("허용하지 않는 파일 이름: %@", n)
            case .badFileType(let n): return L10n.format("그림·pet.json 외의 파일은 넣을 수 없습니다: %@", n)
            case .unreadableImage(let n): return L10n.format("그림을 읽을 수 없습니다: %@", n)
            case .invalidPet(let issues): return L10n.t("pet.json 문제: ") + issues.joined(separator: "; ")
            case .empty: return L10n.t("펫 정의(pet)도 그림도 없습니다")
            }
        }
    }

    /// 가져오기 전에 보여줄 요약
    public struct Summary: Equatable {
        public var name: String
        public var kind: String
        public var fileNames: [String]
        public var warnings: [String]
    }

    // MARK: - 내보내기

    /// 펫 폴더(pet.json + 그림들)를 .pawmitpet 데이터로
    public static func export(folder: URL) throws -> Data {
        let fm = FileManager.default
        var pet: JSONValue = .object([:])
        var files: [String: JSONValue] = [:]
        var total = 0
        let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !name.hasPrefix(".") else { continue }
            if name == "pet.json" {
                pet = JSONValue.parse(try Data(contentsOf: url)) ?? .object([:])
                continue
            }
            guard imageExtensions.contains(url.pathExtension.lowercased()), isSafeName(name) else { continue }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= maxTotalBytes else { throw BundleError.tooLarge }
            files[name] = .string(data.base64EncodedString())
        }
        guard files.count <= maxFiles else { throw BundleError.tooManyFiles }
        if pet.object?.isEmpty != false, files.isEmpty { throw BundleError.empty }
        let name = pet["name"]?.string ?? pet["displayName"]?.string ?? folder.lastPathComponent
        return Data(make(name: name, pet: pet, files: files).encoded(pretty: true).utf8)
    }

    /// 그림 없는 정의만으로 (기본 펫 내보내기 등)
    public static func export(pet: JSONValue, name: String) -> Data {
        Data(make(name: name, pet: pet, files: [:]).encoded(pretty: true).utf8)
    }

    private static func make(name: String, pet: JSONValue, files: [String: JSONValue]) -> JSONValue {
        var o: [String: JSONValue] = ["pawmitPet": .number(Double(PetCatalog.formatVersion)), "name": .string(name), "pet": pet]
        if !files.isEmpty { o["files"] = .object(files) }
        return .object(o)
    }

    // MARK: - 가져오기

    /// 내용을 검사하고 요약을 돌려준다 (아무것도 쓰지 않음)
    public static func inspect(_ data: Data) throws -> Summary {
        let (summary, _, _) = try decode(data)
        return summary
    }

    /// `petsDir` 아래 새 폴더에 풀고 그 폴더를 돌려준다. 같은 이름 폴더가 있으면 뒤에 번호를 붙인다(덮어쓰지 않음).
    @discardableResult
    public static func install(_ data: Data, into petsDir: URL, folderName: String? = nil) throws -> URL {
        let (summary, pet, files) = try decode(data)
        let fm = FileManager.default
        try fm.createDirectory(at: petsDir, withIntermediateDirectories: true)
        let base = slug(folderName ?? summary.name)
        var dest = petsDir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = petsDir.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        // 임시 폴더에 다 쓴 뒤 옮겨서 반쯤 풀린 폴더가 펫 목록에 나타나지 않게 한다
        let tmp = petsDir.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            if let pet, pet.object?.isEmpty == false {
                try Data(pet.encoded(pretty: true).utf8).write(to: tmp.appendingPathComponent("pet.json"))
            } else {
                // 그림만 있는 펫: 이름만 담은 pet.json
                let meta: JSONValue = ["name": .string(summary.name)]
                try Data(meta.encoded(pretty: true).utf8).write(to: tmp.appendingPathComponent("pet.json"))
            }
            for (name, bytes) in files {
                try bytes.write(to: tmp.appendingPathComponent(name))
            }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return dest
    }

    private static func decode(_ data: Data) throws -> (Summary, JSONValue?, [String: Data]) {
        guard data.count <= maxTotalBytes * 4 / 3 + 1024 * 1024 else { throw BundleError.tooLarge }
        guard let root = JSONValue.parse(data), let version = root["pawmitPet"]?.number else { throw BundleError.notABundle }
        guard Int(version) <= PetCatalog.formatVersion else { throw BundleError.unsupportedVersion(Int(version)) }
        let pet = root["pet"]
        if let pet, pet.object == nil { throw BundleError.invalidPet([L10n.t("pet이 객체가 아닙니다")]) }
        var warnings: [String] = []
        if let pet {
            let issues = PetCatalog.validate(pet)
            // 코드로 그리는 펫은 정의가 틀리면 그릴 수 없으니 거부, 이미지 펫의 메타 정보 문제는 경고만
            if pet["kind"] != nil || pet["base"] != nil {
                if !issues.isEmpty { throw BundleError.invalidPet(issues) }
            } else {
                warnings += issues
            }
        }
        var files: [String: Data] = [:]
        var total = 0
        let entries = root["files"]?.object ?? [:]
        guard entries.count <= maxFiles else { throw BundleError.tooManyFiles }
        for (name, value) in entries {
            guard isSafeName(name), name != "pet.json" else { throw BundleError.badFileName(name) }
            let ext = (name as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { throw BundleError.badFileType(name) }
            guard let b64 = value.string, let bytes = Data(base64Encoded: b64) else { throw BundleError.unreadableImage(name) }
            total += bytes.count
            guard total <= maxTotalBytes else { throw BundleError.tooLarge }
            guard let src = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(src) > 0,
                  CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { throw BundleError.unreadableImage(name) }
            files[name] = bytes
        }
        let kind = PetCatalog.resolve(pet ?? .null)["kind"]?.string ?? (files.isEmpty ? "?" : "image")
        // 메이커 펫이 쓰는 그림 파일은 꼭 들어 있어야 한다
        if kind == "rig", let spec = pet.flatMap(RigSpec.decode) {
            let missing = spec.parts.values.compactMap(\.image).filter { files[$0] == nil }
            if !missing.isEmpty { throw BundleError.invalidPet(missing.map { L10n.format("그림 '%@'이 파일에 없습니다", $0) }) }
        }
        if pet?.object?.isEmpty != false, files.isEmpty { throw BundleError.empty }
        if kind == "image", files.keys.contains(where: { $0.hasPrefix("idle.") || $0.hasPrefix("spritesheet.") }) == false {
            warnings.append(L10n.t("idle 그림이나 spritesheet가 없습니다"))
        }
        let name = (root["name"]?.string ?? pet?["name"]?.string ?? L10n.t("펫")).trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = Summary(name: String(name.prefix(40)), kind: kind, fileNames: files.keys.sorted(), warnings: warnings)
        return (summary, pet, files)
    }

    /// 파일 이름: 영문·숫자·.-_ 만, 숨김 파일·경로 금지
    public static func isSafeName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    /// 폴더 이름: 영문 소문자·숫자·- (한글 이름이면 pet)
    public static func slug(_ name: String) -> String {
        let s = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let trimmed = s.split(separator: "-").joined(separator: "-")
        return trimmed.isEmpty ? "pet" : String(trimmed.prefix(32))
    }
}
