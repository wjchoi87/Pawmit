import CoreGraphics
import Foundation
import PawmitCore

/// 펫 포즈(동작·걸음 위상·모션) → 뼈마다 회전·이동·크기.
///
/// 각도는 화면에서 보이는 방향 기준(반시계 +), 이동은 캔버스 단위(위로 +). 그리는 쪽(RigRenderer)이 캔버스(y 아래) 변환으로 바꾼다.
/// 뼈대마다 걷는 법이 다르다: 두 발(다리 교차), 네 발(대각 보행), 다리 없음(통통 튀기), 날개(파닥이며 떠다니기).
/// 쉬기·앉기·잠은 3초·4초 루프, 걷기는 걸음 위상만 써서 몸통 프레임 캐시(FrameQuantizer)가 그대로 먹힌다.
struct RigPose {
    struct Bone {
        var rot: CGFloat = 0
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var sx: CGFloat = 1
        var sy: CGFloat = 1
    }

    var root = Bone()
    var bones: [String: Bone] = [:]
    var eyes: EyeExpr = .open
    var mouth: MouthExpr = .smile
    var sweat = false
    var heat: CGFloat = 0

    subscript(_ id: String) -> Bone {
        get { bones[id] ?? Bone() }
        set { bones[id] = newValue }
    }
}

enum RigPoser {
    /// 팔 각도(0 아래, π/2 바깥, π 위 — 치비와 같은 의미) → 팔 뼈 회전. 그린 팔은 살짝 벌린(0.35) 상태가 기준.
    static func arm(_ pose: inout RigPose, left: CGFloat? = nil, right: CGFloat? = nil) {
        if let left { pose["armL"].rot = -(left - 0.35) }
        if let right { pose["armR"].rot = right - 0.35 }
    }

    static func make(_ p: PetPose, skeleton: String) -> RigPose {
        var r = RigPose()
        let t = p.clock, at = p.animTime
        let omega = 2 * Double.pi / FrameQuantizer.idlePeriod
        let omegaSleep = 2 * Double.pi / FrameQuantizer.sleepPeriod
        let walking = p.anim == .walk || p.anim == .run || p.anim == .draw
        let running = p.anim == .run
        let breath = walking ? 0 : CGFloat(sin(t * (p.anim == .sleep ? omegaSleep : omega)))
        let s = sin(p.walkPhase)

        // 공통 표정
        switch p.anim {
        case .sleep: r.eyes = .closed; r.mouth = .o
        case .happy, .wave: r.eyes = .happy; r.mouth = .open
        case .eat: r.eyes = .happy; r.mouth = abs(sin(at * 8.5)) > 0.6 ? .chomp : .smile
        case .alert, .drag, .fall: r.eyes = .wide; r.mouth = .o
        case .sad: r.eyes = .teary; r.mouth = .wobbly
        case .think: r.mouth = .flat
        case .groom: r.eyes = .closed
        case .dig: r.eyes = .squeeze; r.mouth = .open; r.sweat = true
        case .play, .pounce: r.eyes = .wide; r.mouth = .open
        case .run: r.mouth = .open; r.sweat = true
        case .draw: r.mouth = .tongue
        default: break
        }

        switch skeleton {
        case "quadruped": quadruped(&r, p, walking: walking, running: running, breath: breath, s: s, t: t, at: at, omega: omega)
        case "blob": blob(&r, p, walking: walking, running: running, breath: breath, t: t, at: at, omega: omega)
        default: biped(&r, p, walking: walking, running: running, breath: breath, s: s, t: t, at: at, omega: omega,
                       winged: skeleton == "winged")
        }

        if let m = p.motion { applyMotion(m, t: p.motionTime, to: &r) }
        // 시스템 상태: 디스크 → 통통(몸 가로), CPU → 더위
        if p.chubby > 0.01 { r["body"].sx *= 1 + 0.35 * p.chubby }
        if p.heat > 0.01 {
            r.heat = p.heat
            if p.heat > 0.35 { r.sweat = true }
            if p.heat > 0.6, r.mouth == .smile || r.mouth == .flat { r.mouth = .tongue }
            if p.heat > 0.85, r.eyes == .open { r.eyes = .half }
        }
        if p.blink > 0.5, r.eyes == .open || r.eyes == .wide || r.eyes == .dot { r.eyes = .closed }
        if p.stretch != 1 { r.root.sy *= p.stretch }
        return r
    }

    // MARK: - 두 발 (+ 날개)

    private static func biped(_ r: inout RigPose, _ p: PetPose, walking: Bool, running: Bool, breath: CGFloat, s: CGFloat,
                              t: TimeInterval, at: TimeInterval, omega: Double, winged: Bool) {
        arm(&r, left: 0.35, right: 0.35)
        r["body"].sy = 1 + breath * 0.02
        r["head"].dy = breath * 0.6
        r["tail"].rot = walking ? s * 0.25 : CGFloat(sin(t * omega)) * 0.15

        // 날개: 날 때는 걸음 위상으로 빠르게, 쉴 때는 3초 루프로 살랑
        if winged {
            let flap: CGFloat = walking ? 0.25 + sin(p.walkPhase * 2) * 0.55 : 0.08 + CGFloat(sin(t * omega * 2)) * 0.08
            r["wingL"].rot = -flap
            r["wingR"].rot = flap
        }

        switch p.anim {
        case .idle:
            r.root.rot = CGFloat(sin(t * omega)) * 0.015
        case .walk, .run, .draw:
            if winged, p.anim != .draw {
                // 둥실 떠서 이동: 다리는 대롱대롱
                r.root.dy = 7 + s * 1.6
                r["legL"].rot = s * 0.12
                r["legR"].rot = -s * 0.12
                r.root.rot = running ? -0.1 : -0.04
                arm(&r, left: 0.6 + s * 0.2, right: 0.6 - s * 0.2)
            } else {
                let bob = abs(s) * (running ? 2.8 : 1.8)
                r.root.rot = (running ? -0.12 : (p.anim == .draw ? -0.08 : 0)) + s * (running ? 0.05 : 0.07)
                r["body"].dy = bob
                r["head"].dy += bob * 0.3
                r["legL"].rot = s * 0.32
                r["legR"].rot = -s * 0.32
                r["legL"].dy = max(0, s) * (running ? 4 : 3)
                r["legR"].dy = max(0, -s) * (running ? 4 : 3)
                if running { arm(&r, left: 0.95 + s * 0.55, right: 0.95 - s * 0.55) } else { arm(&r, left: 0.35 + s * 0.45, right: 0.35 - s * 0.45) }
                if p.anim == .draw { arm(&r, right: 1.3) }
            }
        case .sit, .think, .groom, .eat, .sad:
            r["body"].dy = -2.5
            r["head"].dy += -3
            r["legL"].rot = -0.55
            r["legR"].rot = 0.55
            r["legL"].dy = 1.5
            r["legR"].dy = 1.5
            arm(&r, left: 0.15, right: 0.15)
            switch p.anim {
            case .think: arm(&r, right: 3.0); r["head"].rot = 0.1
            case .groom:
                let a = CGFloat(sin(at * 9)) * 0.25
                arm(&r, left: 2.9 + a, right: 2.9 - a)
                r["head"].rot = CGFloat(sin(at * 4.5)) * 0.06
            case .eat:
                let chomp = abs(sin(at * 8.5))
                arm(&r, left: 2.5, right: 2.5)
                r["head"].dy += CGFloat(chomp) * 1.1
            case .sad:
                let wipe = CGFloat(sin(at * 6)) * 0.12
                arm(&r, left: 2.9 + wipe, right: 2.9 - wipe)
                r["head"].dy -= 1.5
                r["head"].rot = -0.06
                r["earL"].rot = 0.3
                r["earR"].rot = -0.3
            default: break
            }
            if winged { r["wingL"].rot = -0.05; r["wingR"].rot = 0.05 }
        case .sleep:
            r["body"].dy = -3
            r["body"].sy = 0.97 + breath * 0.03
            r["head"].dy = -6 + breath * 0.8
            r["head"].rot = -0.15
            r["legL"].rot = -0.55
            r["legR"].rot = 0.55
            arm(&r, left: 0.05, right: 0.05)
            r["earL"].rot = 0.2
            r["earR"].rot = 0.2
            r["tail"].rot = 0
            if winged { r["wingL"].rot = 0.05; r["wingR"].rot = -0.05 }
        case .dig:
            let a = CGFloat(sin(at * 22))
            r.root.rot = -0.3
            arm(&r, left: 1.05 + a * 0.55, right: 1.05 - a * 0.55)
        case .pounce:
            if p.hop > 1 {
                arm(&r, left: 2.4, right: 2.4)
                r["legL"].rot = -0.35
                r["legR"].rot = 0.35
            } else {
                r["body"].sy = 0.9
                arm(&r, left: 0.9, right: 0.9)
                r.root.rot = -0.1 + CGFloat(sin(at * 18)) * 0.03
            }
        case .alert:
            let wob = CGFloat(sin(at * 14)) * 0.08
            arm(&r, left: 2.65 + wob, right: 2.65 - wob)
            r["earL"].rot = -0.15
            r["earR"].rot = 0.15
        case .happy:
            let wob = CGFloat(sin(at * 12)) * 0.25
            arm(&r, left: 2.7 + wob, right: 2.7 - wob)
            r["tail"].rot = CGFloat(sin(t * 10)) * 0.4
            if winged { let f = 0.3 + CGFloat(sin(at * 16)) * 0.5; r["wingL"].rot = -f; r["wingR"].rot = f }
        case .wave:
            arm(&r, left: 0.3, right: 2.75 + CGFloat(sin(at * 12)) * 0.4)
        case .play:
            arm(&r, left: 0.4, right: 1.55 + CGFloat(sin(at * 10)) * 0.65)
            r.root.rot = CGFloat(sin(at * 5)) * 0.06
        case .drag, .fall:
            let flail = p.anim == .fall
            let sw = CGFloat(sin(t * (flail ? 15 : 5)))
            r["legL"].rot = sw * 0.3
            r["legR"].rot = -sw * 0.3
            if flail { arm(&r, left: 2.3 + sw * 0.5, right: 2.3 - sw * 0.5) } else { arm(&r, left: 0.12 + sw * 0.15, right: 0.12 - sw * 0.15) }
            if winged { let f = 0.3 + sw * 0.5; r["wingL"].rot = -f; r["wingR"].rot = f }
        }
    }

    // MARK: - 네 발

    private static func quadruped(_ r: inout RigPose, _ p: PetPose, walking: Bool, running: Bool, breath: CGFloat, s: CGFloat,
                                  t: TimeInterval, at: TimeInterval, omega: Double) {
        r["body"].sy = 1 + breath * 0.025
        r["head"].dy = breath * 0.8
        r["tail"].rot = walking ? s * 0.2 : CGFloat(sin(t * omega)) * 0.12
        let legs: [(String, CGFloat)] = [("legBF", 0), ("legBN", .pi), ("legFF", .pi), ("legFN", 0)]

        switch p.anim {
        case .walk, .run, .draw, .dig, .pounce:
            let amp: CGFloat = running ? 0.75 : (p.anim == .dig || p.anim == .pounce ? 0 : 0.45)
            let bob = amp > 0 ? abs(s) * (running ? 2.4 : 1.4) : 0
            r["body"].dy = bob
            for (id, off) in legs {
                r[id].rot = amp > 0 ? sin(p.walkPhase + off) * amp : 0
                r[id].dy = amp > 0 ? max(0, sin(p.walkPhase + off + .pi / 2)) * (running ? 4 : 2.6) : 0
            }
            if running { r.root.rot = -0.04 }
            if p.anim == .dig {
                let a = CGFloat(sin(at * 22))
                r.root.rot = -0.2
                r["legFN"].rot = -0.6 + a * 0.6
                r["legFF"].rot = -0.6 - a * 0.6
            }
            if p.anim == .pounce {
                if p.hop > 1 { r["legFN"].rot = -0.9; r["legFF"].rot = -0.9; r["legBN"].rot = 0.6; r["legBF"].rot = 0.6 } else { r.root.sy = 0.92; r["head"].dy -= 2 }
            }
        case .sleep:
            // 엎드려 웅크리기: 다리를 접고 몸을 낮춘다
            r["body"].dy = -6
            r["body"].sy = 0.95 + breath * 0.03
            for (id, _) in legs { r[id].sy = 0.25; r[id].dy = -2 }
            r["head"].dy = -9 + breath * 0.6
            r["head"].rot = -0.2
            r["tail"].rot = 0.6
        case .eat:
            let chomp = abs(sin(at * 9))
            r["head"].rot = -0.35
            r["head"].dy = -4 + CGFloat(chomp) * 1.5
        default:
            // 앉기 계열: 뒷다리를 접고 상체를 세운다
            r["body"].rot = 0.28
            for id in ["legBN", "legBF"] { r[id].sy = 0.5; r[id].rot = -0.28 }
            for id in ["legFN", "legFF"] { r[id].rot = -0.28 }
            r["head"].rot = -0.22
            r["head"].dy = 2
            switch p.anim {
            case .wave: r["legFN"].rot = -2.0 + CGFloat(sin(at * 11)) * 0.45
            case .play: r["legFN"].rot = -1.2 + CGFloat(sin(at * 10)) * 0.55
            case .groom: r["legFN"].rot = -2.2 + CGFloat(sin(at * 7)) * 0.15; r["head"].rot = -0.35 + CGFloat(sin(at * 7)) * 0.1
            case .happy, .alert: r["tail"].rot = CGFloat(sin(t * 9)) * 0.5; r["earL"].rot = 0.1; r["earR"].rot = -0.1
            case .sad: r["head"].dy -= 3; r["earL"].rot = 0.4; r["earR"].rot = 0.4; r["tail"].rot = -0.4
            case .think: r["head"].rot = -0.1
            case .drag, .fall:
                let sw = CGFloat(sin(t * 12))
                r["body"].rot = 0
                for (id, off) in legs { r[id].rot = sw * 0.4 * (off == 0 ? 1 : -1); r[id].sy = 1 }
            default: break
            }
        }
    }

    // MARK: - 다리 없음 (통통 튀기)

    private static func blob(_ r: inout RigPose, _ p: PetPose, walking: Bool, running: Bool, breath: CGFloat,
                             t: TimeInterval, at: TimeInterval, omega: Double) {
        arm(&r, left: 0.35, right: 0.35)
        r["body"].sy = 1 + breath * 0.035
        r["body"].sx = 1 - breath * 0.02
        r["tail"].rot = CGFloat(sin(t * omega)) * 0.15
        switch p.anim {
        case .walk, .run, .draw:
            // 한 걸음 = 한 번 통 튀기: 바닥에서 납작, 공중에서 길쭉
            let h = abs(sin(p.walkPhase))
            r.root.dy = h * (running ? 10 : 6.5)
            r["body"].sy = 0.86 + 0.2 * h
            r["body"].sx = 1.1 - 0.12 * h
            arm(&r, left: 0.6 + h * 0.8, right: 0.6 + h * 0.8)
        case .sit:
            r["body"].sy = 0.93 + breath * 0.03
            r["body"].sx = 1.05
        case .sleep:
            r["body"].sy = 0.86 + breath * 0.04
            r["body"].sx = 1.1
            arm(&r, left: 0.05, right: 0.05)
        case .eat:
            let chomp = CGFloat(abs(sin(at * 8.5)))
            r["body"].sy = 0.95 + chomp * 0.06
            arm(&r, left: 2.3, right: 2.3)
        case .happy, .alert, .pounce:
            let wob = CGFloat(sin(at * 12)) * 0.3
            arm(&r, left: 2.6 + wob, right: 2.6 - wob)
            r["body"].sy = 1.05
        case .wave:
            arm(&r, left: 0.3, right: 2.6 + CGFloat(sin(at * 12)) * 0.4)
        case .sad:
            r["body"].sy = 0.9
            arm(&r, left: 2.8, right: 2.8)
        case .dig:
            let a = CGFloat(sin(at * 22))
            r.root.rot = -0.15
            arm(&r, left: 1.1 + a * 0.6, right: 1.1 - a * 0.6)
        case .drag, .fall:
            let sw = CGFloat(sin(t * 12))
            r["body"].sy = 1.12
            r["body"].sx = 0.92
            arm(&r, left: 2.2 + sw * 0.5, right: 2.2 - sw * 0.5)
        case .play:
            arm(&r, left: 0.4, right: 1.5 + CGFloat(sin(at * 10)) * 0.6)
        default:
            break
        }
    }

    // MARK: - 모션 층

    private static func applyMotion(_ m: MotionSpec, t: TimeInterval, to r: inout RigPose) {
        if let la = m.leftArm { arm(&r, left: CGFloat(la.value(at: t))) }
        if let ra = m.rightArm { arm(&r, right: CGFloat(ra.value(at: t))) }
        if let h = m.headTilt { r["head"].rot += CGFloat(h.value(at: t)) }
        if let sq = m.squash { r.root.sy *= CGFloat(sq.value(at: t)) }
        if let l = m.lean { r.root.rot += CGFloat(l.value(at: t)) }
        if let b = m.bounce { r.root.dy += CGFloat(b.base + abs(b.amp * sin(2 * .pi * b.freq * t + b.phase))) * 1.25 }
        if let sw = m.sway { r.root.dx += CGFloat(sw.value(at: t)) * 1.25 }
        if let e = m.eyes { r.eyes = e }
        if let mo = m.mouth { r.mouth = mo }
        if let ep = m.earPerk {
            r["earL"].rot -= CGFloat(ep) * 0.3
            r["earR"].rot += CGFloat(ep) * 0.3
        }
    }
}
