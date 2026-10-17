import Foundation

/// 펫 전체 백업. 확장자는 `.pawmitpet` 그대로 쓰고, 안에 펫 여러 마리와 펫 설정을 담는다.
///
///     { "pawmitPets": 1,
///       "pets": { "<폴더 이름>": <PetBundle 객체>, ... },
///       "settings": { "pet": "mongle", "friends": [...], "petName": …, "catCoat": …, "behaviorSeed": …, "petStyles": {...} } }
///
/// pets는 `~/.pawmit/pets`의 커스텀 펫 전부다(기본 펫은 앱에 들어 있어 담지 않는다).
/// 기본 펫을 꾸민 내용(스타일·고양이 털색·메인 펫·친구)은 settings에 들어간다.
/// 가져올 때는 펫마다 PetBundle 검사를 그대로 거치고, 이미 같은 펫이 있으면 건너뛰며 덮어쓰지 않는다.
public enum PetBackup {
    public static let formatVersion = 1
    public static let maxTotalBytes = 400 * 1024 * 1024
    public static let maxPets = 200

    public enum BackupError: LocalizedError, Equatable {
        case tooLarge
        case tooManyPets
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return L10n.format("백업 파일이 너무 큽니다 (최대 %lldMB)", maxTotalBytes / 1024 / 1024)
            case .tooManyPets: return L10n.format("펫이 너무 많습니다 (최대 %lld마리)", maxPets)
            case .unsupportedVersion(let v): return L10n.format("더 새로운 버전(%lld)의 백업 파일입니다. Pawmit을 업데이트해 주세요", v)
            }
        }
    }

    /// 백업에 담는 펫 설정 (config의 펫 관련 항목만)
    public struct Settings: Codable, Equatable, Sendable {
        public var pet: String
        public var friends: [String]
        public var petName: String?
        public var catCoat: String
        public var behaviorSeed: UInt64?
        public var petStyles: [String: PetStyle]

        private enum CodingKeys: String, CodingKey { case pet, friends, petName, catCoat, behaviorSeed, petStyles }

        public init(_ c: PawmitConfig) {
            pet = c.pet
            friends = c.friends
            petName = c.petName
            catCoat = c.catCoat
            behaviorSeed = c.behaviorSeed
            petStyles = c.petStyles
        }

        // behaviorSeed는 UInt64 전체 범위라 JSON 숫자(Double)로는 값이 깨진다. 문자열로 담는다.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pet = try c.decode(String.self, forKey: .pet)
            friends = (try? c.decode([String].self, forKey: .friends)) ?? []
            petName = try? c.decodeIfPresent(String.self, forKey: .petName)
            catCoat = (try? c.decode(String.self, forKey: .catCoat)) ?? PawmitConfig().catCoat
            behaviorSeed = (try? c.decodeIfPresent(String.self, forKey: .behaviorSeed)).flatMap { $0.flatMap(UInt64.init) }
            petStyles = (try? c.decode([String: PetStyle].self, forKey: .petStyles)) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pet, forKey: .pet)
            try c.encode(friends, forKey: .friends)
            try c.encodeIfPresent(petName, forKey: .petName)
            try c.encode(catCoat, forKey: .catCoat)
            try c.encodeIfPresent(behaviorSeed.map(String.init), forKey: .behaviorSeed)
            try c.encode(petStyles, forKey: .petStyles)
        }

        /// 폴더 이름이 바뀐 펫(`folder:옛이름` → `folder:새이름`)을 고치고, 없는 펫은 빼고 config에 얹는다.
        /// 스타일은 백업에 있는 펫만 덮고 나머지는 그대로 둔다.
        public func apply(to c: inout PawmitConfig, renamed: [String: String], exists: (String) -> Bool) {
            func map(_ id: String) -> String {
                guard id.hasPrefix("folder:"), let new = renamed[String(id.dropFirst("folder:".count))] else { return id }
                return "folder:\(new)"
            }
            let main = map(pet)
            if exists(main) {
                c.pet = main
                c.petName = petName
                c.behaviorSeed = behaviorSeed
            }
            var seen = Set([c.pet])
            c.friends = friends.map(map).filter { exists($0) && seen.insert($0).inserted }.prefix(4).map { $0 }
            c.catCoat = catCoat
            for (id, style) in petStyles { c.petStyles[map(id)] = style }
        }
    }

    /// 가져오기 전에 보여줄 요약
    public struct Summary: Equatable {
        public var petNames: [String]
        public var settings: Settings?
    }

    /// 가져온 결과: 새로 만든 폴더, 이미 있어서 건너뛴 펫, 폴더 이름이 바뀐 펫(옛 → 새)
    public struct RestoreResult: Equatable {
        public var installed: [String] = []
        public var skipped: [String] = []
        public var renamed: [String: String] = [:]
    }

    // MARK: - 내보내기

    /// petsDir의 커스텀 펫 전부 + 펫 설정. 그림이 없거나 너무 큰 펫은 빼고 그 폴더 이름을 함께 돌려준다.
    public static func export(petsDir: URL, config: PawmitConfig) throws -> (data: Data, left: [String]) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: petsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard folders.count <= maxPets else { throw BackupError.tooManyPets }
        var pets: [String: JSONValue] = [:]
        var left: [String] = []
        var total = 0
        for folder in folders {
            guard let data = try? PetBundle.export(folder: folder), let bundle = JSONValue.parse(data) else {
                left.append(folder.lastPathComponent)
                continue
            }
            total += data.count
            guard total <= maxTotalBytes else { throw BackupError.tooLarge }
            pets[folder.lastPathComponent] = bundle
        }
        let settings = JSONValue.parse(try JSONEncoder().encode(Settings(config))) ?? .null
        let root: JSONValue = ["pawmitPets": .number(Double(formatVersion)), "pets": .object(pets), "settings": settings]
        return (Data(root.encoded(pretty: true).utf8), left)
    }

    // MARK: - 가져오기

    /// 펫 한 마리 파일이 아니라 백업 파일인지
    public static func isBackup(_ data: Data) -> Bool {
        JSONValue.parse(data)?["pawmitPets"] != nil
    }

    /// 모든 펫을 PetBundle로 검사하고 요약을 돌려준다 (아무것도 쓰지 않음)
    public static func inspect(_ data: Data) throws -> Summary {
        let (pets, settings) = try decode(data)
        var names: [String] = []
        for (_, bundle) in pets { names.append(try PetBundle.inspect(bundle).name) }
        return Summary(petNames: names, settings: settings)
    }

    /// 펫을 petsDir에 푼다. 같은 이름 폴더에 똑같은 펫이 있으면 건너뛰고, 다른 펫이면 번호를 붙인 새 폴더로.
    /// 하나라도 검사에 걸리면 아무것도 쓰기 전에 실패한다.
    public static func restore(_ data: Data, into petsDir: URL) throws -> RestoreResult {
        let (pets, _) = try decode(data)
        for (_, bundle) in pets { _ = try PetBundle.inspect(bundle) }
        var result = RestoreResult()
        for (name, bundle) in pets {
            let existing = petsDir.appendingPathComponent(name, isDirectory: true)
            if let mine = try? PetBundle.export(folder: existing), JSONValue.parse(mine) == JSONValue.parse(bundle) {
                result.skipped.append(name)
                continue
            }
            let folder = try PetBundle.install(bundle, into: petsDir, folderName: name).lastPathComponent
            result.installed.append(folder)
            if folder != name { result.renamed[name] = folder }
        }
        return result
    }

    /// (폴더 이름 순 펫 데이터, 설정)
    private static func decode(_ data: Data) throws -> ([(String, Data)], Settings?) {
        guard data.count <= maxTotalBytes * 4 / 3 + 1024 * 1024 else { throw BackupError.tooLarge }
        guard let root = JSONValue.parse(data), let version = root["pawmitPets"]?.number else { throw PetBundle.BundleError.notABundle }
        guard Int(version) <= formatVersion else { throw BackupError.unsupportedVersion(Int(version)) }
        let entries = root["pets"]?.object ?? [:]
        guard entries.count <= maxPets else { throw BackupError.tooManyPets }
        var pets: [(String, Data)] = []
        for (name, bundle) in entries.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("..") else { throw PetBundle.BundleError.badFileName(name) }
            pets.append((name, Data(bundle.encoded().utf8)))
        }
        let settings = root["settings"].flatMap { $0.encoded().data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        return (pets, settings)
    }
}
