import XCTest
@testable import PawmitCore

final class BehaviorTests: XCTestCase {
    let ctx = BehaviorContext(hunger: 30, energy: 70, fun: 50, affection: 60, hour: 14, hasFriends: true, agentBusy: false,
                              canDoodle: true, canTrash: true, interjection: "몽!")

    func testSameSeedSamePlan() {
        let p = Personality.make(seed: 42, species: "mongle")
        let a = BehaviorComposer.compose(personality: p, context: ctx, seed: 1234)
        let b = BehaviorComposer.compose(personality: p, context: ctx, seed: 1234)
        XCTAssertEqual(a, b)
    }

    func testVarietyIsHuge() {
        XCTAssertGreaterThan(BehaviorComposer.combinationCount, 100_000)
        XCTAssertGreaterThan(SpeechBank.lineCount, 5_000)
        XCTAssertGreaterThan(ActRecipes.totalVariants, 7_000)

        // 실제로 뽑아봐도 서로 다른 행동이 많이 나온다
        let p = Personality.make(seed: 7, species: "tokki")
        var signatures = Set<String>()
        var archetypes = Set<String>()
        for i in 0..<2000 {
            let plan = BehaviorComposer.compose(personality: p, context: ctx, seed: SplitMix64.mix(7, UInt64(i)))
            XCTAssertFalse(plan.steps.isEmpty)
            archetypes.insert(plan.archetype)
            signatures.insert("\(plan.steps)")
        }
        XCTAssertGreaterThan(signatures.count, 1900, "2000번 중 거의 다 달라야 한다")
        XCTAssertGreaterThan(archetypes.count, 12)
    }

    func testPersonalityDiffersBySeedAndSpecies() {
        XCTAssertNotEqual(Personality.make(seed: 1, species: "mongle"), Personality.make(seed: 2, species: "mongle"))
        XCTAssertFalse(Personality.make(seed: 1, species: "bamtol").summary.isEmpty)
    }

    func testUrgentNeeds() {
        var hungry = ctx
        hungry.hunger = 95
        let p = Personality.make(seed: 3, species: "mongle")
        let eats = (0..<50).filter { i in
            BehaviorComposer.compose(personality: p, context: hungry, seed: UInt64(i)).steps.contains {
                if case .macro(.eat, _) = $0 { return true }
                return false
            }
        }.count
        XCTAssertGreaterThan(eats, 30)

        var exhausted = ctx
        exhausted.energy = 5
        XCTAssertTrue(BehaviorComposer.compose(personality: p, context: exhausted, seed: 9).steps.contains {
            if case .macro(.home, _) = $0 { return true }
            return false
        })
    }

    func testWaypointsStayInBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        var r = SplitMix64(seed: 99)
        for pattern in MovePattern.allCases {
            let pts = PathPlanner.waypoints(pattern, from: CGPoint(x: 780, y: 20), size: 1.4, repeats: 2, bounds: bounds,
                                            cursor: CGPoint(x: 100, y: 100), rng: &r)
            XCTAssertFalse(pts.isEmpty, "\(pattern)")
            for p in pts { XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(p), "\(pattern) \(p)") }
        }
    }

    func testEveryActMakesValidSpec() {
        var r = SplitMix64(seed: 5)
        for act in Act.allCases {
            for _ in 0..<20 {
                let s = ActRecipes.make(act, rng: &r)
                XCTAssertGreaterThan(s.seconds, 0.5)
                XCTAssertLessThan(s.seconds, 16)
                XCTAssertFalse(s.motion.base.isEmpty)
            }
        }
    }

    func testDoodleGeneratorVariety() {
        XCTAssertGreaterThan(DoodleGenerator.variantCount, 100_000)
        XCTAssertEqual(DoodleGenerator.generate(seed: 77), DoodleGenerator.generate(seed: 77))
        var names = Set<String>()
        var shapes = Set<String>()
        var fillCount = 0
        for i in 0..<1500 {
            let art = DoodleGenerator.generate(seed: UInt64(i) &* 0x9E3779B97F4A7C15)
            XCTAssertFalse(art.strokes.isEmpty, art.name)
            for s in art.strokes {
                XCTAssertGreaterThan(s.points.count, 1)
                if s.fill { fillCount += 1 }
                for p in s.points { XCTAssertTrue(abs(p.x) < 2.2 && abs(p.y) < 2.2, "\(art.name) \(p)") }
            }
            names.insert(art.name)
            shapes.insert("\(art.strokes.map { "\($0.points.count):\($0.color)\($0.fill ? "f" : "")" })-\(art.strokes.first!.points[1])")
        }
        XCTAssertGreaterThan(names.count, 28)
        XCTAssertGreaterThan(shapes.count, 1350, "1500개 중 고유 형태 — 그림 도안 45% 포함 기준")
        XCTAssertGreaterThan(fillCount, 0, "채색 도안(명화·풍경·만화)이 하나도 안 나옴")
    }

    /// 성격대로 노는지: 정반대 성격 두 펫의 행동 분포 비교
    func testPersonalityShapesBehavior() {
        let lazyTidy = Personality(energy: 0.05, curiosity: 0.1, sociability: 0.1, artistry: 0.05, mischief: 0.05,
                                   appetite: 0.2, laziness: 0.95, tidiness: 0.95)
        let wildArtist = Personality(energy: 0.95, curiosity: 0.8, sociability: 0.5, artistry: 0.95, mischief: 0.95,
                                     appetite: 0.2, laziness: 0.05, tidiness: 0.05)
        var c = ctx
        c.doodleCount = 8
        func histogram(_ p: Personality) -> [String: Int] {
            var h: [String: Int] = [:]
            for i in 0..<3000 {
                h[BehaviorComposer.compose(personality: p, context: c, seed: SplitMix64.mix(11, UInt64(i))).archetype, default: 0] += 1
            }
            return h
        }
        let lazy = histogram(lazyTidy), wild = histogram(wildArtist)
        func sum(_ h: [String: Int], _ keys: [String]) -> Int { keys.reduce(0) { $0 + (h[$1] ?? 0) } }
        let restKeys = ["rest", "m:nap"], activeKeys = ["exercise", "mischief", "m:ball", "m:chaseCursor", "dance"]
        XCTAssertGreaterThan(sum(lazy, restKeys), sum(wild, restKeys) * 2, "느긋한 펫이 훨씬 많이 쉰다 \(lazy) vs \(wild)")
        XCTAssertGreaterThan(sum(wild, activeKeys), sum(lazy, activeKeys) * 2, "활발한 장난꾸러기가 훨씬 많이 뛰논다")
        XCTAssertGreaterThan(wild["m:doodle"] ?? 0, (lazy["m:doodle"] ?? 0) * 3, "예술가가 낙서를 더 많이 한다")
        XCTAssertGreaterThan(lazy["m:clean"] ?? 0, (wild["m:clean"] ?? 0) * 3, "깔끔쟁이가 청소를 더 많이 한다")
    }
}
