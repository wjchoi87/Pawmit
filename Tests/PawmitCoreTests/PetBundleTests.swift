import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PawmitCore

final class PetBundleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pawmit-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func png() -> Data {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testBuiltinsAreValid() {
        XCTAssertEqual(PetCatalog.builtins.count, 7)
        for b in PetCatalog.builtins {
            XCTAssertEqual(PetCatalog.validate(b), [], b["id"]?.string ?? "?")
        }
    }

    func testBaseInheritance() {
        let v: JSONValue = ["kind": "chibi", "base": "mongle", "body": "#FFE4EC", "name": "분홍 몽글이"]
        let r = PetCatalog.resolve(v)
        XCTAssertEqual(r["ears"]?.string, "round")
        XCTAssertEqual(r["body"]?.string, "#FFE4EC")
        XCTAssertEqual(r["name"]?.string, "분홍 몽글이")
        XCTAssertNil(r["base"])
        XCTAssertEqual(PetCatalog.validate(v), [])
        XCTAssertFalse(PetCatalog.validate(["kind": "chibi", "ears": "wings"]).isEmpty)
        XCTAssertFalse(PetCatalog.validate(["kind": "chibi", "body": "pink"]).isEmpty)
        XCTAssertFalse(PetCatalog.validate(["kind": "chibi", "base": "nobody"]).isEmpty)
    }

    func testRoundTripDefinitionOnly() throws {
        let pet: JSONValue = ["kind": "chibi", "base": "tokki", "name": "Mint Bunny", "body": "#D8F5E4"]
        let data = PetBundle.export(pet: pet, name: "Mint Bunny")
        let summary = try PetBundle.inspect(data)
        XCTAssertEqual(summary.name, "Mint Bunny")
        XCTAssertEqual(summary.kind, "chibi")
        let folder = try PetBundle.install(data, into: tmp)
        XCTAssertEqual(folder.lastPathComponent, "mint-bunny")
        let saved = JSONValue.parse(try Data(contentsOf: folder.appendingPathComponent("pet.json")))
        XCTAssertEqual(saved, pet)
        // 같은 이름을 또 가져오면 덮어쓰지 않고 새 폴더
        let second = try PetBundle.install(data, into: tmp)
        XCTAssertEqual(second.lastPathComponent, "mint-bunny-2")
    }

    func testRoundTripWithImages() throws {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try png().write(to: src.appendingPathComponent("idle.png"))
        try png().write(to: src.appendingPathComponent("walk.png"))
        try Data("echo hi".utf8).write(to: src.appendingPathComponent("evil.sh"))
        try Data(#"{"name":"Pixel","facing":"left"}"#.utf8).write(to: src.appendingPathComponent("pet.json"))
        let data = try PetBundle.export(folder: src)
        let summary = try PetBundle.inspect(data)
        XCTAssertEqual(summary.fileNames, ["idle.png", "walk.png"]) // 셸 스크립트는 빠진다
        XCTAssertEqual(summary.kind, "image")
        let out = try PetBundle.install(data, into: tmp.appendingPathComponent("pets"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("idle.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("evil.sh").path))
    }

    func testRejectsUnsafeContent() {
        func bundle(_ files: [String: String], pet: JSONValue = ["name": "x"]) -> Data {
            let v: JSONValue = ["pawmitPet": 1, "name": "x", "pet": pet, "files": .object(files.mapValues { .string($0) })]
            return Data(v.encoded().utf8)
        }
        let img = png().base64EncodedString()
        XCTAssertThrowsError(try PetBundle.inspect(bundle(["../escape.png": img]))) {
            XCTAssertEqual($0 as? PetBundle.BundleError, .badFileName("../escape.png"))
        }
        XCTAssertThrowsError(try PetBundle.inspect(bundle(["run.sh": img]))) {
            XCTAssertEqual($0 as? PetBundle.BundleError, .badFileType("run.sh"))
        }
        XCTAssertThrowsError(try PetBundle.inspect(bundle(["idle.png": Data("not an image".utf8).base64EncodedString()]))) {
            XCTAssertEqual($0 as? PetBundle.BundleError, .unreadableImage("idle.png"))
        }
        XCTAssertThrowsError(try PetBundle.inspect(bundle([:], pet: ["kind": "chibi", "ears": "wings"])))
        XCTAssertThrowsError(try PetBundle.inspect(Data(#"{"hello":1}"#.utf8))) {
            XCTAssertEqual($0 as? PetBundle.BundleError, .notABundle)
        }
        XCTAssertThrowsError(try PetBundle.inspect(Data(#"{"pawmitPet":99,"pet":{}}"#.utf8))) {
            XCTAssertEqual($0 as? PetBundle.BundleError, .unsupportedVersion(99))
        }
    }

    func testSlug() {
        XCTAssertEqual(PetBundle.slug("Mint Bunny!"), "mint-bunny")
        XCTAssertEqual(PetBundle.slug("몽글이"), "pet")
        XCTAssertTrue(PetBundle.isSafeName("idle.gif"))
        XCTAssertFalse(PetBundle.isSafeName(".hidden.png"))
        XCTAssertFalse(PetBundle.isSafeName("a/b.png"))
    }
}

final class RigSpecTests: XCTestCase {
    func testSVGPathParsing() throws {
        let p = try SVGPath.parse("M10 10 L20 10 l0 10 H10 v-10 Z")
        XCTAssertEqual(p.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 10, height: 10))
        // 호: 지름 20인 원
        let c = try SVGPath.parse("M40 50 A10 10 0 1 1 60 50 A10 10 0 1 1 40 50 Z")
        let b = c.boundingBoxOfPath
        XCTAssertEqual(b.minX, 40, accuracy: 0.05)
        XCTAssertEqual(b.maxX, 60, accuracy: 0.05)
        XCTAssertEqual(b.height, 20, accuracy: 0.2)
        // 붙어 쓴 숫자·지수·S·T·상대 좌표
        XCTAssertNoThrow(try SVGPath.parse("m1.5-2.5.5.5c1,1 2,2 3,3s1 1 2 2q1 1 2 2t3 3 1e1 1E-1z"))
        XCTAssertThrowsError(try SVGPath.parse(""))
        XCTAssertThrowsError(try SVGPath.parse("M10 10 L20"))
        XCTAssertThrowsError(try SVGPath.parse("10 10"))
        // 다시 문자열로 → 다시 읽어도 같은 영역
        let again = try SVGPath.parse(SVGPath.string(from: c))
        XCTAssertEqual(again.boundingBoxOfPath.width, b.width, accuracy: 0.05)
    }

    func testTemplatesAreValid() {
        for sk in Skeleton.all {
            guard let t = RigTemplates.template(sk.id) else { return XCTFail("템플릿 없음: \(sk.id)") }
            XCTAssertEqual(t.validate(), [], sk.id)
            XCTAssertEqual(PetCatalog.validate(t.json), [], sk.id)
            XCTAssertTrue(t.svg().contains("<svg"))
        }
    }

    func testRigValidationCatchesMistakes() {
        var t = RigTemplates.template("biped")!
        t.parts["wingL"] = RigPart(shapes: [RigShape(d: "M0 0 L10 0 L5 5 Z", fill: "#FFFFFF")])
        t.parts["armL"]?.shapes?[0].d = "M10 10 Q"
        t.parts["body"]?.shapes?[0].fill = "white"
        t.face.eyes = "laser"
        t.style = PetStyle(personality: ["energy": 2])
        let issues = t.validate()
        XCTAssertTrue(issues.contains { $0.contains("wingL") })
        XCTAssertTrue(issues.contains { $0.contains("armL.shapes[0].d") })
        XCTAssertTrue(issues.contains { $0.contains("fill 'white'") })
        XCTAssertTrue(issues.contains { $0.contains("laser") })
        XCTAssertTrue(issues.contains { $0.contains("energy") })
        // 그림 부위는 bundle에 파일이 있어야 한다
        var img = RigTemplates.template("blob")!
        img.parts["acc1"] = RigPart(image: "hat.png", imageRect: [40, 40, 20, 20], parent: "body")
        let data = PetBundle.export(pet: img.json, name: "hat")
        XCTAssertThrowsError(try PetBundle.inspect(data))
    }

    func testSpeechStyle() {
        let s = SpeechStyle(suffix: "냥", emoji: "none")
        XCTAssertEqual(s.apply(to: "배고파…", roll: 0.5), "배고파냥…")
        XCTAssertEqual(s.apply(to: "산책 최고! ✨", roll: 0.5), "산책 최고냥!")
        XCTAssertEqual(SpeechStyle(suffix: "다요").apply(to: "같이 놀자", roll: 0.9), "같이 놀자다요")
        let merged = PetStyle(speech: SpeechStyle(suffix: "냥")).merged(with: PetStyle(speech: SpeechStyle(emoji: "lots")))
        XCTAssertEqual(merged.speech?.suffix, "냥")
        XCTAssertEqual(merged.speech?.emoji, "lots")
    }
}

final class PetStyleTests: XCTestCase {
    func testPersonalityOverride() {
        let base = Personality.make(seed: 42, species: "mongle")
        let p = base.overridden(by: ["energy": 0.95, "laziness": 0.05, "nope": 1])
        XCTAssertEqual(p.energy, 0.95)
        XCTAssertEqual(p.laziness, 0.05)
        XCTAssertEqual(p.curiosity, base.curiosity)
        XCTAssertEqual(base.overridden(by: nil), base)
    }

    func testConfigStoresStyles() throws {
        var c = PawmitConfig()
        c.petStyles["mongle"] = PetStyle(personality: ["energy": 1], speech: SpeechStyle(suffix: "몽"), colors: ["body": "#FFE4EC"])
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(PawmitConfig.self, from: data)
        XCTAssertEqual(back.petStyles["mongle"]?.speech?.suffix, "몽")
        // 예전 config(스타일 없음)도 그대로 읽힌다
        let old = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"pet":"cat"}"#.utf8))
        XCTAssertEqual(old.petStyles, [:])
    }
}

final class DoodleConfigTests: XCTestCase {
    func testDoodleLifetimeDefaultsAndClamps() throws {
        XCTAssertEqual(PawmitConfig().doodleSeconds, 60)
        // 예전 설정(doodleFadeHours)은 무시하고 기본 60초
        let old = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"doodleFadeHours":24}"#.utf8))
        XCTAssertEqual(old.doodleSeconds, 60)
        let tooLong = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"doodleSeconds":600}"#.utf8))
        XCTAssertEqual(tooLong.doodleSeconds, 60, "최대 60초")
        let short = try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"doodleSeconds":3}"#.utf8))
        XCTAssertEqual(short.doodleSeconds, 10)
    }
}
