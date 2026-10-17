import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PawmitCore

/// 펫 전체 백업: 내보낸 그대로 복원되고, 다시 가져와도 중복·덮어쓰기가 없는지
final class PetBackupTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func png() -> Data {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// 조립 펫 하나 + 그림 펫 하나가 있는 펫 폴더
    private func makePets(in dir: URL) throws {
        let chibi = dir.appendingPathComponent("pink-mongle", isDirectory: true)
        try FileManager.default.createDirectory(at: chibi, withIntermediateDirectories: true)
        let def: JSONValue = ["kind": "chibi", "base": "mongle", "body": "#FFE4EC", "name": "분홍 몽글이"]
        try Data(def.encoded().utf8).write(to: chibi.appendingPathComponent("pet.json"))
        let image = dir.appendingPathComponent("blue-blob", isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try png().write(to: image.appendingPathComponent("idle.png"))
        try Data(#"{"name":"파랑이"}"#.utf8).write(to: image.appendingPathComponent("pet.json"))
    }

    private func config() -> PawmitConfig {
        var c = PawmitConfig()
        c.pet = "folder:pink-mongle"
        c.friends = ["banban", "folder:blue-blob", "folder:gone"]
        c.petName = "핑크"
        c.catCoat = "black"
        c.behaviorSeed = UInt64.max - 12345
        c.petStyles = ["mongle": PetStyle(colors: ["body": "#FFFFFF"]), "folder:pink-mongle": PetStyle(speech: SpeechStyle(suffix: "뿅"))]
        return c
    }

    func testRoundTripRestoresPetsAndSettings() throws {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try makePets(in: src)
        let (data, left) = try PetBackup.export(petsDir: src, config: config())
        XCTAssertEqual(left, [])
        XCTAssertTrue(PetBackup.isBackup(data))
        XCTAssertFalse(PetBackup.isBackup(PetBundle.export(pet: ["kind": "chibi", "base": "mongle"], name: "x")))

        let summary = try PetBackup.inspect(data)
        XCTAssertEqual(Set(summary.petNames), ["분홍 몽글이", "파랑이"])
        XCTAssertEqual(summary.settings?.behaviorSeed, UInt64.max - 12345)

        let dst = tmp.appendingPathComponent("dst", isDirectory: true)
        let result = try PetBackup.restore(data, into: dst)
        XCTAssertEqual(Set(result.installed), ["pink-mongle", "blue-blob"])
        XCTAssertEqual(result.renamed, [:])
        XCTAssertNotNil(FileManager.default.contents(atPath: dst.appendingPathComponent("blue-blob/idle.png").path))

        var restored = PawmitConfig()
        summary.settings!.apply(to: &restored, renamed: result.renamed) { id in
            id == "banban" || FileManager.default.fileExists(atPath: dst.appendingPathComponent(String(id.dropFirst(7))).path)
        }
        XCTAssertEqual(restored.pet, "folder:pink-mongle")
        XCTAssertEqual(restored.friends, ["banban", "folder:blue-blob"])
        XCTAssertEqual(restored.petName, "핑크")
        XCTAssertEqual(restored.catCoat, "black")
        XCTAssertEqual(restored.behaviorSeed, UInt64.max - 12345)
        XCTAssertEqual(restored.petStyles["folder:pink-mongle"]?.speech?.suffix, "뿅")
        XCTAssertEqual(restored.petStyles["mongle"]?.colors?["body"], "#FFFFFF")
    }

    func testRestoreTwiceSkipsAndNeverOverwrites() throws {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try makePets(in: src)
        let (data, _) = try PetBackup.export(petsDir: src, config: config())

        // 같은 곳에 다시 가져오면 전부 건너뜀
        let again = try PetBackup.restore(data, into: src)
        XCTAssertEqual(again.installed, [])
        XCTAssertEqual(Set(again.skipped), ["pink-mongle", "blue-blob"])

        // 같은 이름 폴더에 다른 펫이 있으면 새 폴더로, 설정의 id도 그 폴더를 가리킨다
        let dst = tmp.appendingPathComponent("dst", isDirectory: true)
        let other = dst.appendingPathComponent("pink-mongle", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let mine: JSONValue = ["kind": "chibi", "base": "tokki", "name": "내 토끼"]
        try Data(mine.encoded().utf8).write(to: other.appendingPathComponent("pet.json"))
        let result = try PetBackup.restore(data, into: dst)
        XCTAssertEqual(result.renamed["pink-mongle"], "pink-mongle-2")
        XCTAssertEqual(JSONValue.parse(try Data(contentsOf: other.appendingPathComponent("pet.json")))?["name"]?.string, "내 토끼")

        var c = PawmitConfig()
        try PetBackup.inspect(data).settings!.apply(to: &c, renamed: result.renamed) { _ in true }
        XCTAssertEqual(c.pet, "folder:pink-mongle-2")
        XCTAssertNotNil(c.petStyles["folder:pink-mongle-2"])
    }

    func testRejectsBadEntriesBeforeWriting() throws {
        let evil: JSONValue = ["pawmitPets": 1, "pets": ["../escape": ["pawmitPet": 1, "name": "x", "pet": ["kind": "chibi", "base": "mongle"]]]]
        XCTAssertThrowsError(try PetBackup.restore(Data(evil.encoded().utf8), into: tmp))
        let badPet: JSONValue = ["pawmitPets": 1, "pets": [
            "ok": ["pawmitPet": 1, "name": "ok", "pet": ["kind": "chibi", "base": "mongle"]],
            "broken": ["pawmitPet": 1, "name": "b", "files": ["run.sh": "ZWNobw=="]],
        ]]
        XCTAssertThrowsError(try PetBackup.restore(Data(badPet.encoded().utf8), into: tmp))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
        let newer: JSONValue = ["pawmitPets": 99, "pets": [:]]
        XCTAssertThrowsError(try PetBackup.inspect(Data(newer.encoded().utf8)))
    }
}
