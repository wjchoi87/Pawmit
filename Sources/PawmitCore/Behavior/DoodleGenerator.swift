import Foundation
import CoreGraphics

/// seed로 그리는 낙서 도안 생성기.
/// 도안 가족(장미곡선·리사주·스피로그래프·별·꽃·해·집·나무·글씨 …) × 가족별 매개변수 × 꾸미기(회전·비율·색 섞기·반짝이·밑줄)를
/// 조합해서 펫이 매번 다른 그림을 그린다. 좌표는 중심 (0,0), 반지름 약 1 기준이다.
public struct DoodleArt: Equatable, Sendable {
    public struct Stroke: Equatable, Sendable {
        public var points: [CGPoint]
        /// 팔레트 안의 색 번호 (0 = 주 색)
        public var color: Int
        /// true면 펫이 외곽선을 긋고 난 뒤 그 안이 색으로 차오른다 (명화·풍경·만화 도안)
        public var fill: Bool
        /// 선 굵기 배율 (0.5…2)
        public var width: Double

        public init(points: [CGPoint], color: Int, fill: Bool = false, width: Double = 1) {
            self.points = points
            self.color = color
            self.fill = fill
            self.width = width
        }
    }

    public var name: String
    public var strokes: [Stroke]

    public var totalLength: CGFloat {
        strokes.reduce(0) { sum, s in
            zip(s.points, s.points.dropFirst()).reduce(sum) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }
}

public enum DoodleGenerator {
    typealias P = CGPoint

    struct Family {
        var name: String
        var variants: Int
        var make: (inout SplitMix64) -> [[P]]
    }

    // MARK: - 기본 도형

    static func circle(_ c: P = .zero, _ r: CGFloat, from a0: Double = 0, to a1: Double = 2 * .pi, n: Int = 36, sy: CGFloat = 1) -> [P] {
        (0...n).map { i in
            let a = a0 + (a1 - a0) * Double(i) / Double(n)
            return P(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r * sy)
        }
    }

    static func polar(_ n: Int = 120, range: Double = 2 * .pi, _ f: (Double) -> Double) -> [P] {
        (0...n).map { i in
            let t = range * Double(i) / Double(n)
            let r = f(t)
            return P(x: CGFloat(cos(t) * r), y: CGFloat(sin(t) * r))
        }
    }

    static func wavy(from x0: Double, to x1: Double, y: Double, amp: Double, n: Int) -> [P] {
        var out: [P] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            let x: Double = x0 + (x1 - x0) * t
            let yy: Double = y + amp * sin(Double(i))
            out.append(P(x: CGFloat(x), y: CGFloat(yy)))
        }
        return out
    }

    static func line(_ pts: [(Double, Double)], dx: Double = 0, dy: Double = 0, s: Double = 1) -> [P] {
        pts.map { P(x: CGFloat($0.0 * s + dx), y: CGFloat($0.1 * s + dy)) }
    }

    // MARK: - 곡선 계산 (타입 추론 부담을 줄이려고 분리)

    static func lissajous(a: Double, b: Double, delta: Double) -> [P] {
        var out: [P] = []
        for i in 0...200 {
            let t: Double = 2 * .pi * Double(i) / 200
            let x: Double = sin(a * t + delta)
            let y: Double = sin(b * t) * 0.85
            out.append(P(x: CGFloat(x), y: CGFloat(y)))
        }
        return out
    }

    static func spirograph(rr: Double, d: Double, epi: Bool) -> [P] {
        var out: [P] = []
        let k: Double = epi ? 1 / (1 + rr + d) : 1 / (1 - rr + d)
        for i in 0...360 {
            let t: Double = 12 * .pi * Double(i) / 360
            let x: Double
            let y: Double
            if epi {
                let q: Double = (1 + rr) / rr * t
                x = (1 + rr) * cos(t) - d * cos(q)
                y = (1 + rr) * sin(t) - d * sin(q)
            } else {
                let q: Double = (1 - rr) / rr * t
                x = (1 - rr) * cos(t) + d * cos(q)
                y = (1 - rr) * sin(t) - d * sin(q)
            }
            out.append(P(x: CGFloat(x * k), y: CGFloat(y * k)))
        }
        return out
    }

    static func starPoints(n: Int, inner: Double) -> [P] {
        var out: [P] = []
        for i in 0...(2 * n) {
            let a: Double = Double.pi / 2 + Double(i) * .pi / Double(n)
            let rad: Double = i % 2 == 0 ? 1 : inner
            out.append(P(x: CGFloat(cos(a) * rad), y: CGFloat(sin(a) * rad)))
        }
        return out
    }

    static func polygonPoints(n: Int, wobble: Double) -> [P] {
        var out: [P] = []
        for i in 0...n {
            let a: Double = Double.pi / 2 + Double(i % n) * 2 * .pi / Double(n)
            let rad: Double = 1 + (i % 2 == 0 ? wobble : -wobble)
            out.append(P(x: CGFloat(cos(a) * rad), y: CGFloat(sin(a) * rad)))
        }
        return out
    }

    static func heartPoints(fat: Double) -> [P] {
        var out: [P] = []
        for i in 0...60 {
            let t: Double = Double(i) / 60 * 2 * .pi
            let x: Double = 16 * pow(sin(t), 3) * fat
            let y: Double = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            out.append(P(x: CGFloat(x / 17), y: CGFloat(y / 17)))
        }
        return out
    }

    static func spiralPoints(turns: Double, log: Bool) -> [P] {
        var out: [P] = []
        let e: Double = exp(2.2) - 1
        for i in 0...160 {
            let t: Double = Double(i) / 160
            let a: Double = t * turns * 2 * .pi
            let rad: Double = log ? (exp(t * 2.2) - 1) / e : t
            out.append(P(x: CGFloat(cos(a) * rad), y: CGFloat(sin(a) * rad)))
        }
        return out
    }

    static func waveRow(y0: Double, freq: Double, kind: Int) -> [P] {
        var out: [P] = []
        for i in 0...80 {
            let t: Double = Double(i) / 80
            let x: Double = -1 + 2 * t
            switch kind {
            case 0:
                out.append(P(x: CGFloat(x), y: CGFloat(y0 + sin(t * freq * 2 * .pi) * 0.2)))
            case 1:
                let saw: Double = abs((t * freq * 2).truncatingRemainder(dividingBy: 2) - 1) - 0.5
                out.append(P(x: CGFloat(x), y: CGFloat(y0 + saw * 0.4)))
            default:
                let a: Double = t * freq * 4 * .pi
                out.append(P(x: CGFloat(x + cos(a) * 0.08), y: CGFloat(y0 + sin(a) * 0.18)))
            }
        }
        return out
    }

    static func infinityPoints(w: Double) -> [P] {
        var out: [P] = []
        for i in 0...80 {
            let t: Double = 2 * .pi * Double(i) / 80
            let d: Double = 1 + pow(sin(t), 2)
            out.append(P(x: CGFloat(cos(t) / d * w), y: CGFloat(sin(t) * cos(t) / d)))
        }
        return out
    }

    static func ringPoints(tilt: Double) -> [P] {
        var out: [P] = []
        for i in 0...40 {
            let a: Double = 2 * .pi * Double(i) / 40
            let x: Double = cos(a), y: Double = sin(a) * 0.25
            out.append(P(x: CGFloat(x * cos(tilt) - y * sin(tilt)), y: CGFloat(x * sin(tilt) + y * cos(tilt))))
        }
        return out
    }

    // MARK: - 가족들

    static let families: [Family] = [
        Family(name: "장미", variants: 21) { r in
            let k = Double(r.int(2, 8)), d = Double(r.int(1, 3))
            return [polar(220, range: 2 * .pi * d) { cos(k / d * $0) }]
        },
        Family(name: "리사주", variants: 75) { r in
            let a = Double(r.int(1, 5)), b = Double(r.int(1, 5)), delta = r.pick([0, 0.7854, 1.5708] as [Double])
            return [lissajous(a: a, b: b, delta: delta)]
        },
        Family(name: "스피로그래프", variants: 36) { r in
            let ratios: [Double] = [0.3333, 0.4, 0.4286, 0.2857, 0.375, 0.4167]
            let rr = r.pick(ratios)
            let dk: [Double] = [0.3, 0.5, 0.8]
            let d = r.pick(dk) * rr
            return [spirograph(rr: rr, d: d, epi: r.chance(0.5))]
        },
        Family(name: "별", variants: 18) { r in
            let n = r.int(4, 9), inner = r.pick([0.38, 0.5, 0.62])
            return [starPoints(n: n, inner: inner)]
        },
        Family(name: "다각형", variants: 18) { r in
            let n = r.int(3, 8), wob = r.pick([0.0, 0.08, 0.15])
            return [polygonPoints(n: n, wobble: wob)]
        },
        Family(name: "하트", variants: 3) { r in
            return [heartPoints(fat: r.pick([1.0, 1.25, 0.8]))]
        },
        Family(name: "달팽이", variants: 8) { r in
            return [spiralPoints(turns: r.pick([1.5, 2.5, 3.5, 4.5]), log: r.chance(0.5))]
        },
        Family(name: "꽃", variants: 48) { r in
            let petals = Double(r.int(4, 9))
            var s: [[P]] = [polar(160) { 0.45 + 0.55 * abs(cos(petals / 2 * $0)) }.map { P(x: $0.x * 0.75, y: $0.y * 0.75 + 0.25) }]
            if r.chance(0.5) { s.append(circle(P(x: 0, y: 0.25), 0.18, n: 16)) }
            if r.chance(0.5) {
                s.append(line([(0, -0.5), (0.05, -0.8), (0, -1)]))
                if r.chance(0.5) { s.append(circle(P(x: 0.18, y: -0.75), 0.13, n: 12, sy: 0.6)) }
            }
            return s
        },
        Family(name: "해님", variants: 36) { r in
            let rays = r.int(6, 14), tri = r.chance(0.5)
            var s: [[P]] = [circle(.zero, 0.45)]
            for k in 0..<rays {
                let a = Double(k) / Double(rays) * 2 * .pi
                if tri {
                    let a1 = a - 0.12, a2 = a + 0.12
                    s.append([P(x: CGFloat(cos(a1) * 0.58), y: CGFloat(sin(a1) * 0.58)), P(x: CGFloat(cos(a)), y: CGFloat(sin(a))),
                              P(x: CGFloat(cos(a2) * 0.58), y: CGFloat(sin(a2) * 0.58))])
                } else {
                    s.append([P(x: CGFloat(cos(a) * 0.6), y: CGFloat(sin(a) * 0.6)), P(x: CGFloat(cos(a)), y: CGFloat(sin(a)))])
                }
            }
            if r.chance(0.5) {
                s.append(circle(P(x: -0.15, y: 0.1), 0.04, n: 6))
                s.append(circle(P(x: 0.15, y: 0.1), 0.04, n: 6))
                s.append(circle(.zero, 0.22, from: 1.15 * .pi, to: 1.85 * .pi, n: 10))
            }
            return s
        },
        Family(name: "웃는 얼굴", variants: 40) { r in
            var s: [[P]] = [circle(.zero, 1)]
            switch r.int(0, 3) {
            case 0: s += [circle(P(x: -0.35, y: 0.3), 0.07, n: 8), circle(P(x: 0.35, y: 0.3), 0.07, n: 8)]
            case 1: s += [line([(-0.45, 0.3), (-0.25, 0.3)]), line([(0.25, 0.3), (0.45, 0.3)])]
            case 2: s += [line([(-0.5, 0.22), (-0.35, 0.38), (-0.2, 0.22)]), line([(0.2, 0.22), (0.35, 0.38), (0.5, 0.22)])]
            default: s += [line([(-0.45, 0.4), (-0.25, 0.2)]), line([(-0.45, 0.2), (-0.25, 0.4)]), line([(0.25, 0.4), (0.45, 0.2)]), line([(0.25, 0.2), (0.45, 0.4)])]
            }
            switch r.int(0, 4) {
            case 0: s.append(circle(.zero, 0.55, from: 1.15 * .pi, to: 1.85 * .pi, n: 14))
            case 1: s.append(circle(P(x: 0, y: -0.3), 0.25, from: .pi, to: 2 * .pi, n: 12) + [P(x: 0.25, y: -0.3), P(x: -0.25, y: -0.3)])
            case 2: s.append(line([(-0.3, -0.35), (0.3, -0.35)]))
            case 3: s.append(wavy(from: -0.35, to: 0.35, y: -0.35, amp: 0.06, n: 16))
            default: s.append(circle(P(x: 0, y: -0.35), 0.12, n: 12))
            }
            if r.chance(0.5) { s += [circle(P(x: -0.6, y: -0.05), 0.12, n: 10, sy: 0.6), circle(P(x: 0.6, y: -0.05), 0.12, n: 10, sy: 0.6)] }
            return s
        },
        Family(name: "고양이", variants: 8) { r in
            var s: [[P]] = [circle(.zero, 0.8)]
            if r.chance(0.5) {
                s += [line([(-0.6, 0.5), (-0.5, 1.05), (-0.15, 0.78)]), line([(0.15, 0.78), (0.5, 1.05), (0.6, 0.5)])]
            } else {
                s += [circle(P(x: -0.5, y: 0.7), 0.22, from: 0.1, to: .pi + 0.6, n: 10), circle(P(x: 0.5, y: 0.7), 0.22, from: -0.6, to: .pi - 0.1, n: 10)]
            }
            s += [circle(P(x: -0.3, y: 0.15), 0.06, n: 6), circle(P(x: 0.3, y: 0.15), 0.06, n: 6)]
            s.append(r.chance(0.5) ? line([(-0.2, -0.2), (-0.1, -0.3), (0, -0.2), (0.1, -0.3), (0.2, -0.2)]) : circle(.zero, 0.3, from: 1.2 * .pi, to: 1.8 * .pi, n: 10))
            if r.chance(0.5) {
                s += [line([(-0.45, -0.1), (-1.1, 0)]), line([(-0.45, -0.2), (-1.1, -0.3)]), line([(0.45, -0.1), (1.1, 0)]), line([(0.45, -0.2), (1.1, -0.3)])]
            }
            return s
        },
        Family(name: "구름", variants: 15) { r in
            let bumps = r.int(4, 8)
            var top: [P] = []
            for k in 0..<bumps {
                let cx = -0.9 + 1.8 * (Double(k) + 0.5) / Double(bumps)
                top += circle(P(x: CGFloat(cx), y: 0.15), CGFloat(1.0 / Double(bumps) + 0.08), from: .pi, to: 0, n: 8)
            }
            var s: [[P]] = [top + [P(x: 0.95, y: -0.15), P(x: -0.95, y: -0.15), top[0]]]
            switch r.int(0, 2) {
            case 1: for k in 0..<4 { let x = -0.6 + Double(k) * 0.4; s.append(line([(x, -0.35), (x - 0.08, -0.6)])) }
            case 2: s.append(line([(0.1, -0.25), (-0.1, -0.55), (0.1, -0.55), (-0.1, -0.9)]))
            default: break
            }
            return s
        },
        Family(name: "물결", variants: 36) { r in
            let rows = r.int(1, 3), freq = Double(r.int(2, 5)), kind = r.int(0, 2)
            return (0..<rows).map { row -> [P] in
                waveRow(y0: Double(row) * 0.45 - Double(rows - 1) * 0.22, freq: freq, kind: kind)
            }
        },
        Family(name: "끄적끄적", variants: 9) { r in
            let steps = r.pick([20, 35, 50]), curl = r.pick([0.3, 0.6, 0.9])
            var p = P.zero, a = r.range(0, 2 * .pi)
            var pts = [p]
            for _ in 0..<steps {
                a += r.range(-curl, curl) * 1.6
                p = P(x: p.x + CGFloat(cos(a)) * 0.12, y: p.y + CGFloat(sin(a)) * 0.12)
                p = P(x: min(max(p.x, -1), 1), y: min(max(p.y, -1), 1))
                pts.append(p)
            }
            return [pts]
        },
        Family(name: "집", variants: 36) { r in
            var s: [[P]] = [line([(-0.7, -0.9), (-0.7, 0.1), (0.7, 0.1), (0.7, -0.9), (-0.7, -0.9)])]
            switch r.int(0, 2) {
            case 0: s.append(line([(-0.85, 0.1), (0, 0.9), (0.85, 0.1)]))
            case 1: s.append(circle(P(x: 0, y: 0.1), 0.8, from: 0, to: .pi, n: 18, sy: 0.85))
            default: s.append(line([(-0.85, 0.1), (-0.85, 0.35), (0.85, 0.35), (0.85, 0.1)]))
            }
            if r.chance(0.5) { s.append(line([(-0.15, -0.9), (-0.15, -0.4), (0.15, -0.4), (0.15, -0.9)])) }
            for k in 0..<r.int(0, 2) { let x = k == 0 ? -0.45 : 0.45; s.append(line([(x - 0.12, -0.15), (x + 0.12, -0.15), (x + 0.12, -0.35), (x - 0.12, -0.35), (x - 0.12, -0.15)])) }
            if r.chance(0.5) { s.append(line([(0.45, 0.5), (0.45, 0.8), (0.6, 0.8), (0.6, 0.35)])); s.append(circle(P(x: 0.6, y: 1.0), 0.1, n: 10)) }
            return s
        },
        Family(name: "나무", variants: 8) { r in
            var s: [[P]] = [line([(-0.1, -1), (-0.1, -0.3)]), line([(0.1, -1), (0.1, -0.3)])]
            switch r.int(0, 3) {
            case 0: s.append(circle(P(x: 0, y: 0.25), 0.6, n: 30))
            case 1: s.append(line([(-0.7, -0.3), (0, 0.4), (-0.5, 0.2), (0, 0.95), (0.5, 0.2), (0, 0.4), (0.7, -0.3), (-0.7, -0.3)]))
            case 2: s.append(polar(120) { 0.55 + 0.1 * sin(7 * $0) }.map { P(x: $0.x, y: $0.y + 0.25) })
            default: s.append(circle(P(x: 0, y: 0.4), 0.5, n: 24)); s.append(circle(P(x: 0, y: 0.4), 0.25, n: 14))
            }
            if r.chance(0.5) { for k in 0..<3 { s.append(circle(P(x: CGFloat(-0.3 + 0.3 * Double(k)), y: CGFloat(0.2 + 0.15 * Double(k % 2))), 0.06, n: 6)) } }
            return s
        },
        Family(name: "물고기", variants: 8) { r in
            var s: [[P]] = [circle(P(x: 0.1, y: 0), 0.65, n: 30, sy: 0.55)]
            s.append(r.chance(0.5) ? line([(-0.55, 0), (-1, 0.35), (-0.85, 0), (-1, -0.35), (-0.55, 0)]) : circle(P(x: -0.75, y: 0), 0.22, n: 14))
            s.append(circle(P(x: 0.45, y: 0.1), 0.06, n: 6))
            for k in 0..<r.int(0, 3) { s.append(circle(P(x: CGFloat(0.85 + 0.1 * Double(k)), y: CGFloat(0.3 + 0.25 * Double(k))), CGFloat(0.06 + 0.03 * Double(k)), n: 8)) }
            return s
        },
        Family(name: "음표", variants: 2) { r in
            if r.chance(0.5) {
                return [circle(P(x: -0.2, y: -0.6), 0.22, n: 14, sy: 0.75), line([(0.02, -0.6), (0.02, 0.8), (0.4, 0.5)])]
            }
            return [circle(P(x: -0.5, y: -0.6), 0.2, n: 14, sy: 0.75), circle(P(x: 0.4, y: -0.45), 0.2, n: 14, sy: 0.75),
                    line([(-0.3, -0.6), (-0.3, 0.7), (0.6, 0.85), (0.6, -0.45)])]
        },
        Family(name: "번개", variants: 3) { r in
            let z = r.int(2, 4)
            var pts: [(Double, Double)] = [(0.2, 1)]
            for k in 0..<z {
                let y = 1 - 2 * Double(k + 1) / Double(z + 1)
                pts.append((k % 2 == 0 ? -0.35 : 0.35, y))
            }
            pts.append((-0.1, -1))
            return [line(pts)]
        },
        Family(name: "무한", variants: 2) { r in
            return [infinityPoints(w: r.pick([1.0, 0.8]))]
        },
        Family(name: "동그라미들", variants: 3) { r in
            (1...r.int(2, 4)).map { k in circle(.zero, CGFloat(Double(k) / 4.0 + 0.2), n: 28) }
        },
        Family(name: "왕관", variants: 6) { r in
            let n = r.int(3, 5)
            var pts: [(Double, Double)] = [(-0.9, -0.5)]
            for k in 0...n * 2 { pts.append((-0.9 + 1.8 * Double(k) / Double(n * 2), k % 2 == 0 ? 0.6 : 0.0)) }
            pts += [(0.9, -0.5), (-0.9, -0.5)]
            var s = [line(pts)]
            if r.chance(0.5) { s.append(circle(P(x: 0, y: -0.25), 0.1, n: 8)) }
            return s
        },
        Family(name: "발자국", variants: 3) { r in
            var s: [[P]] = []
            let n = r.int(3, 5)
            for k in 0..<n {
                let cx = -0.8 + 1.6 * Double(k) / Double(max(1, n - 1)), cy = k % 2 == 0 ? -0.2 : 0.25
                s.append(circle(P(x: CGFloat(cx), y: CGFloat(cy)), 0.11, n: 10))
                for (dx, dy) in [(-0.12, 0.14), (0.0, 0.19), (0.12, 0.14)] { s.append(circle(P(x: CGFloat(cx + dx), y: CGFloat(cy + dy)), 0.035, n: 6)) }
            }
            return s
        },
        Family(name: "산", variants: 12) { r in
            let peaks = r.int(2, 4)
            var pts: [(Double, Double)] = [(-1, -0.7)]
            for k in 0..<peaks {
                let x = -1 + 2 * (Double(k) + 0.5) / Double(peaks)
                pts += [(x, r.range(0.1, 0.7)), (x + 1.0 / Double(peaks), -0.4)]
            }
            pts[pts.count - 1] = (1, -0.7)
            var s = [line(pts)]
            if r.chance(0.5) { s.append(circle(P(x: 0.65, y: 0.75), 0.18, n: 14)) }
            if r.chance(0.5) { s.append(line([(pts[1].0 - 0.15, pts[1].1 - 0.2), (pts[1].0, pts[1].1 - 0.08), (pts[1].0 + 0.15, pts[1].1 - 0.2)])) }
            return s
        },
        Family(name: "무지개", variants: 6) { r in
            let arcs = r.int(3, 5)
            var s = (0..<arcs).map { k in circle(P(x: 0, y: -0.6), CGFloat(1 - Double(k) * 0.15), from: 0, to: .pi, n: 26) }
            if r.chance(0.5) { s += [circle(P(x: -0.85, y: -0.6), 0.2, n: 12), circle(P(x: 0.85, y: -0.6), 0.2, n: 12)] }
            return s
        },
        Family(name: "나비", variants: 4) { r in
            var s: [[P]] = r.chance(0.5)
                ? [polar(120) { abs(sin(2 * $0)) * 0.9 + 0.1 }]
                : [circle(P(x: -0.45, y: 0.25), 0.4, n: 18), circle(P(x: 0.45, y: 0.25), 0.4, n: 18),
                   circle(P(x: -0.35, y: -0.35), 0.28, n: 14), circle(P(x: 0.35, y: -0.35), 0.28, n: 14)]
            s.append(line([(0, -0.6), (0, 0.5)]))
            if r.chance(0.5) { s += [line([(0, 0.5), (-0.2, 0.85)]), line([(0, 0.5), (0.2, 0.85)])] }
            return s
        },
        Family(name: "풍선", variants: 3) { r in
            var s: [[P]] = []
            let n = r.int(1, 3)
            for k in 0..<n {
                let cx = n == 1 ? 0 : -0.45 + 0.9 * Double(k) / Double(n - 1)
                s.append(circle(P(x: CGFloat(cx), y: 0.4), 0.32, n: 20, sy: 1.25))
                s.append((0...10).map { i in P(x: CGFloat(cx + sin(Double(i)) * 0.04), y: CGFloat(0 - Double(i) * 0.09)) })
            }
            return s
        },
        Family(name: "유령", variants: 6) { r in
            let bumps = r.int(3, 5)
            var pts = circle(P(x: 0, y: 0.2), 0.6, from: 0, to: .pi, n: 16)
            for k in 0...bumps * 2 {
                let x = -0.6 + 1.2 * Double(k) / Double(bumps * 2)
                pts.append(P(x: CGFloat(x), y: CGFloat(k % 2 == 0 ? -0.8 : -0.6)))
            }
            pts.append(pts[0])
            var s = [pts]
            if r.chance(0.5) { s += [circle(P(x: -0.2, y: 0.25), 0.07, n: 8), circle(P(x: 0.2, y: 0.25), 0.07, n: 8)] }
            return s
        },
        Family(name: "달", variants: 12) { r in
            var s: [[P]] = r.chance(0.6)
                ? [circle(.zero, 0.8, from: 0.4 * .pi, to: 1.6 * .pi, n: 24) + circle(P(x: -0.35, y: 0), 0.6, from: 1.45 * .pi, to: 0.55 * .pi, n: 18)]
                : [circle(.zero, 0.75, n: 28)]
            for _ in 0..<r.int(0, 3) {
                let cx = r.range(0.5, 1), cy = r.range(-0.8, 0.8)
                s.append(line([(cx - 0.08, cy), (cx + 0.08, cy)]))
                s.append(line([(cx, cy - 0.08), (cx, cy + 0.08)]))
            }
            return s
        },
        Family(name: "행성", variants: 3) { r in
            return [circle(.zero, 0.5, n: 28), ringPoints(tilt: r.pick([0.0, 0.3, -0.3]))]
        },
        Family(name: "주먹밥", variants: 2) { r in
            let s = r.pick([1.0, 0.8])
            return [line([(0, 0.9), (0.85, -0.6), (-0.85, -0.6), (0, 0.9)], s: s), line([(-0.3, -0.6), (-0.3, -0.15), (0.3, -0.15), (0.3, -0.6)], s: s)]
        },
        Family(name: "글씨", variants: words.count) { r in
            letters(r.pick(words))
        },
    ]

    static let words = ["HI", "OK", "LOL", "WOW", "YAY", "LGTM", "SHIP", "YES", "OMG", "MEOW", "PAW", "NEAT", "GG"]

    // MARK: - 그림(채색) 도안 — 명화·풍경·만화. 외곽선을 긋고 나면 색이 차오른다.

    struct ArtStroke {
        var points: [P]
        var fill: Bool = false
        /// 팔레트 색 번호 (팔레트는 Brain이 시드로 고른다)
        var color: Int = 0
        var width: Double = 1
    }

    struct ArtFamily {
        var name: String
        var variants: Int
        var make: (inout SplitMix64) -> [ArtStroke]
    }

    static let artFamilies: [ArtFamily] = [
        // 명화풍
        ArtFamily(name: "별이 빛나는 밤", variants: 24) { r in
            var s: [ArtStroke] = []
            // 소용돌이 하늘
            for _ in 0..<r.int(2, 4) {
                let cx = r.range(-0.55, 0.55), cy = r.range(0.25, 0.75)
                s.append(ArtStroke(points: spirograph(rr: r.pick([0.3333, 0.4, 0.2857]), d: 0.45, epi: true)
                    .map { P(x: $0.x * 0.42 + CGFloat(cx), y: $0.y * 0.42 + CGFloat(cy)) }, color: 4, width: 0.8))
            }
            // 별
            for _ in 0..<r.int(4, 8) {
                let a = r.range(0, 2 * .pi), d = r.range(0.45, 1.05)
                let c = P(x: CGFloat(cos(a) * d), y: CGFloat(sin(a) * d * 0.75 + 0.45))
                s.append(ArtStroke(points: starPoints(n: 4, inner: 0.45).map { P(x: $0.x * 0.09 + c.x, y: $0.y * 0.09 + c.y) }, fill: true, color: 2))
            }
            // 초승달
            s.append(ArtStroke(points: circle(P(x: 0.62, y: 0.72), 0.2, n: 20) + circle(P(x: 0.52, y: 0.72), 0.17, from: 1.4 * .pi, to: 0.6 * .pi, n: 16), fill: true, color: 2))
            // 언덕과 마을 실루엣
            let hills = line([(-1, -0.25), (-0.6, -0.05), (-0.2, -0.3), (0.3, -0.1), (0.7, -0.35), (1, -0.2), (1, -1), (-1, -1), (-1, -0.25)], s: 0.95)
            s.append(ArtStroke(points: hills, fill: true, color: 3))
            s.append(ArtStroke(points: line([(-0.75, -0.3), (-0.75, -0.05), (-0.55, -0.05), (-0.55, -0.3)], s: 0.95), color: 0, width: 1.2))
            s.append(ArtStroke(points: line([(0.45, -0.45), (0.45, -0.25), (0.62, -0.25), (0.62, -0.45)], s: 0.95), color: 0, width: 1.2))
            return s
        },
        ArtFamily(name: "해바라기", variants: 16) { r in
            var s: [ArtStroke] = []
            s.append(ArtStroke(points: line([(-0.3, -1), (-0.18, -0.1)], s: 0.95), color: 3, width: 1.6))
            s.append(ArtStroke(points: [(0, -1), (0.12, -0.1)].map { P(x: $0.0 * 0.95, y: $0.1 * 0.95) }, color: 3, width: 1.6))
            if r.chance(0.6) { s.append(ArtStroke(points: circle(P(x: -0.42, y: -0.55), 0.16, n: 12, sy: 0.5), fill: true, color: 3)) }
            // 화분
            s.append(ArtStroke(points: line([(-0.34, -0.55), (-0.42, -1), (0.42, -1), (0.34, -0.55), (-0.34, -0.55)], s: 0.95), fill: true, color: 5))
            // 꽃 몇 송이
            let flowers = r.int(2, 4)
            for k in 0..<flowers {
                let cx = -0.5 + Double(k) * (1.0 / Double(max(1, flowers - 1))) + r.range(-0.06, 0.06)
                let cy = 0.45 + 0.2 * Double(k % 2) + r.range(-0.05, 0.05)
                let petals = r.int(6, 9)
                for p in 0..<petals {
                    let a = Double(p) / Double(petals) * 2 * .pi
                    let e = P(x: CGFloat(cx + cos(a) * 0.16), y: CGFloat(cy + sin(a) * 0.16))
                    s.append(ArtStroke(points: circle(e, 0.09, n: 10).map { P(x: ($0.x + e.x) / 2 + (e.x - ($0.x + e.x) / 2) * 0, y: ($0.y + e.y) / 2) }, fill: true, color: 2))
                }
                s.append(ArtStroke(points: circle(P(x: CGFloat(cx), y: CGFloat(cy)), 0.085, n: 12), fill: true, color: 5))
            }
            return s
        },
        ArtFamily(name: "몬드리안", variants: 60) { r in
            var s: [ArtStroke] = [ArtStroke(points: line([(-0.95, -0.95), (0.95, -0.95), (0.95, 0.95), (-0.95, 0.95), (-0.95, -0.95)]), color: 0, width: 1.8)]
            var xs = [-0.95, r.range(-0.5, -0.1), r.range(0.1, 0.95)]
            var ys = [0.95, r.range(0.2, 0.5), r.range(-0.5, -0.1), -0.95]
            for x in xs.dropFirst() { s.append(ArtStroke(points: [P(x: CGFloat(x), y: 0.95), P(x: CGFloat(x), y: -0.95)], color: 0, width: 1.8)) }
            for y in ys.dropFirst() { s.append(ArtStroke(points: [P(x: -0.95, y: CGFloat(y)), P(x: 0.95, y: CGFloat(y))], color: 0, width: 1.8)) }
            // 빈 칸 중 몇 개를 원색으로
            for k in 0..<r.int(2, 5) {
                let i = r.int(0, xs.count - 2), j = r.int(0, ys.count - 2)
                let x0 = xs[i], x1 = xs[i + 1], y0 = ys[j + 1], y1 = ys[j]
                let rect = line([(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)])
                s.append(ArtStroke(points: rect, fill: true, color: r.pick([0, 1, 2])))
            }
            return s
        },
        ArtFamily(name: "수련", variants: 18) { r in
            var s: [ArtStroke] = [ArtStroke(points: circle(.zero, 0.95, n: 40, sy: 0.6), fill: true, color: 1)]
            // 수련 잎
            for _ in 0..<r.int(5, 9) {
                let cx = r.range(-0.7, 0.7), cy = r.range(-0.45, 0.45), w = r.range(0.1, 0.2)
                let notch = P(x: CGFloat(cx + w), y: CGFloat(cy))
                s.append(ArtStroke(points: circle(P(x: CGFloat(cx), y: CGFloat(cy)), CGFloat(w), n: 18, sy: 0.55) + [notch], fill: true, color: 3))
            }
            // 꽃
            for _ in 0..<r.int(1, 3) {
                let cx = r.range(-0.6, 0.6), cy = r.range(-0.4, 0.4)
                for k in 0..<r.int(5, 7) {
                    let a = Double(k) / 6.0 * 2 * .pi
                    s.append(ArtStroke(points: circle(P(x: CGFloat(cx + cos(a) * 0.05), y: CGFloat(cy + sin(a) * 0.05)), 0.06, n: 8), fill: true, color: 4))
                }
                s.append(ArtStroke(points: circle(P(x: CGFloat(cx), y: CGFloat(cy)), 0.035, n: 8), fill: true, color: 2))
            }
            return s
        },
        ArtFamily(name: "인상파 강가", variants: 12) { r in
            var s: [ArtStroke] = []
            // 하늘과 물 밴드
            s.append(ArtStroke(points: line([(-1, 1), (1, 1), (1, 0.15), (-1, 0.15), (-1, 1)]), fill: true, color: 2))
            s.append(ArtStroke(points: line([(-1, 0.15), (1, 0.15), (1, -1), (-1, -1), (-1, 0.15)]), fill: true, color: 1))
            // 강가 나무
            s.append(ArtStroke(points: line([(0.55, 0.1), (0.55, 0.6)], s: 0.9), color: 5, width: 1.4))
            s.append(ArtStroke(points: circle(P(x: 0.55, y: 0.75), 0.3, n: 22), fill: true, color: 3))
            // 물 반짝 (짧은 가로 획)
            for _ in 0..<r.int(6, 12) {
                let y = r.range(-0.85, 0.05), x = r.range(-0.9, 0.3), w = r.range(0.06, 0.16)
                s.append(ArtStroke(points: [P(x: CGFloat(x), y: CGFloat(y)), P(x: CGFloat(x + w), y: CGFloat(y))], color: 2, width: 1.8))
            }
            return s
        },
        // 풍경
        ArtFamily(name: "노을 바다", variants: 30) { r in
            var s: [ArtStroke] = []
            // 하늘 밴드 2개
            s.append(ArtStroke(points: line([(-1, 1), (1, 1), (1, 0.45), (-1, 0.45), (-1, 1)]), fill: true, color: 5))
            s.append(ArtStroke(points: line([(-1, 0.45), (1, 0.45), (1, 0.05), (-1, 0.05), (-1, 0.45)]), fill: true, color: 0))
            // 바다
            s.append(ArtStroke(points: line([(-1, 0.05), (1, 0.05), (1, -1), (-1, -1), (-1, 0.05)]), fill: true, color: 1))
            // 지는 해
            s.append(ArtStroke(points: circle(P(x: 0, y: 0.05), 0.32, n: 24), fill: true, color: 2))
            // 해 반사
            for k in 0..<r.int(3, 6) {
                let y = -0.12 - Double(k) * 0.16, w = 0.3 - Double(k) * 0.04
                s.append(ArtStroke(points: [P(x: CGFloat(-w / 2), y: CGFloat(y)), P(x: CGFloat(w / 2), y: CGFloat(y))], color: 2, width: 2.2))
            }
            if r.chance(0.6) { s.append(ArtStroke(points: line([(r.range(-0.9, -0.5), 0.2), (r.range(-0.6, -0.2), 0.55)], s: 0.9), color: 0, width: 1.6)) } // 갈매기
            return s
        },
        ArtFamily(name: "산과 호수", variants: 24) { r in
            var s: [ArtStroke] = []
            let peaks = r.int(2, 3)
            var pts: [(Double, Double)] = [(-1, 0)]
            for k in 0..<peaks {
                let x = -1 + 2 * (Double(k) + 0.5) / Double(peaks)
                pts += [(x, r.range(0.4, 0.95)), (x + 1.0 / Double(peaks), 0)]
            }
            pts += [(1, 0), (-1, 0)]
            s.append(ArtStroke(points: line(pts), fill: true, color: 3))
            // 눈 덮인 봉우리
            let p1 = pts[1]
            s.append(ArtStroke(points: line([(p1.0 - 0.16, p1.1 - 0.22), (p1.0, p1.1 - 0.1), (p1.0 + 0.16, p1.1 - 0.22)], s: 0.9), color: 0, width: 1.4))
            // 호수
            s.append(ArtStroke(points: line([(-1, 0), (1, 0), (0.85, -0.85), (-0.85, -0.85), (-1, 0)]), fill: true, color: 1))
            for k in 0..<r.int(2, 5) {
                let y = -0.25 - Double(k) * 0.16
                s.append(ArtStroke(points: wavy(from: -0.6, to: 0.6, y: y, amp: 0.02, n: 20), color: 0, width: 1.2))
            }
            s.append(ArtStroke(points: circle(P(x: r.range(-0.8, -0.4), y: 0.78), 0.14, n: 14), fill: true, color: 2))
            return s
        },
        ArtFamily(name: "벚꽃 나무", variants: 20) { r in
            var s: [ArtStroke] = []
            s.append(ArtStroke(points: line([(0, -1), (0.02, -0.3), (-0.3, 0.15), (-0.45, 0.4)], s: 0.9), color: 5, width: 1.5))
            s.append(ArtStroke(points: line([(0.02, -0.3), (0.35, 0.05), (0.5, 0.3)], s: 0.9), color: 5, width: 1.3))
            // 꽃 클러스터 (겹친 분홍 원)
            for _ in 0..<r.int(16, 26) {
                let a = r.range(0, 2 * .pi), d = r.range(0, 0.45)
                let cx = -0.1 + cos(a) * d * 1.2, cy = 0.55 + sin(a) * d * 0.7
                s.append(ArtStroke(points: circle(P(x: CGFloat(cx), y: CGFloat(cy)), CGFloat(r.range(0.06, 0.12)), n: 12), fill: true, color: r.pick([4, 0])))
            }
            // 낙화
            for _ in 0..<r.int(3, 6) {
                let cx = r.range(-0.9, 0.9), cy = r.range(-0.9, 0.0)
                s.append(ArtStroke(points: circle(P(x: CGFloat(cx), y: CGFloat(cy)), 0.035, n: 8), fill: true, color: 4))
            }
            return s
        },
        ArtFamily(name: "등대", variants: 16) { r in
            var s: [ArtStroke] = []
            // 몸통 줄무늬
            let bands = r.int(3, 4)
            for k in 0..<bands {
                let y0 = -0.7 + Double(k) * 0.42, y1 = y0 + 0.42
                let w0 = 0.32 - Double(k) * 0.05, w1 = 0.32 - Double(k + 1) * 0.05
                s.append(ArtStroke(points: line([(-w0, y0), (-w1, y1), (w1, y1), (w0, y0), (-w0, y0)]), fill: true, color: k % 2 == 0 ? 0 : 2))
            }
            s.append(ArtStroke(points: line([(-0.22, 0.98), (-0.34, 0.9), (0.34, 0.9), (0.22, 0.98), (-0.22, 0.98)]), fill: true, color: 0))
            // 빛
            s.append(ArtStroke(points: line([(0.28, 0.86), (0.95, 0.55), (0.95, 0.95), (0.28, 0.9)], s: 0.9), fill: true, color: 2))
            // 바위와 파도
            s.append(ArtStroke(points: line([(-0.8, -0.7), (-0.4, -0.95), (0.4, -0.95), (0.8, -0.7), (-0.8, -0.7)]), fill: true, color: 5))
            for k in 0..<r.int(2, 4) { s.append(ArtStroke(points: wavy(from: -1, to: 0, y: -0.8 - Double(k) * 0.1, amp: 0.04, n: 16), color: 1, width: 1.4)) }
            return s
        },
        // 만화
        ArtFamily(name: "폭발 코멘트", variants: 20) { r in
            var s: [ArtStroke] = []
            let burst = starPoints(n: r.int(9, 13), inner: r.pick([0.62, 0.72])).map { P(x: $0.x * 0.98, y: $0.y * 0.98) }
            s.append(ArtStroke(points: burst, fill: true, color: 2))
            let word = r.pick(["WOW", "BANG", "OMG", "YAY"])
            for st in letters(word) { s.append(ArtStroke(points: st.map { P(x: $0.x * 0.55, y: $0.y * 0.5 + 0.02) }, color: 0, width: 1.6)) }
            return s
        },
        ArtFamily(name: "집중선", variants: 12) { r in
            var s: [ArtStroke] = []
            let rays = r.int(14, 22)
            for k in 0..<rays {
                let a = Double(k) / Double(rays) * 2 * .pi + r.range(-0.05, 0.05)
                let inner = r.range(0.5, 0.62)
                s.append(ArtStroke(points: [P(x: CGFloat(cos(a) * inner), y: CGFloat(sin(a) * inner)), P(x: CGFloat(cos(a)), y: CGFloat(sin(a)))], color: r.pick([0, 5]), width: r.range(1, 2)))
            }
            s.append(ArtStroke(points: circle(P(x: 0, y: 0), 0.4, n: 28), fill: true, color: 2))
            // 중앙 놀란 얼굴
            s.append(ArtStroke(points: [P(x: -0.14, y: 0.1), P(x: -0.04, y: 0.1)], color: 0, width: 1.8))
            s.append(ArtStroke(points: [P(x: 0.04, y: 0.1), P(x: 0.14, y: 0.1)], color: 0, width: 1.8))
            s.append(ArtStroke(points: circle(P(x: 0, y: -0.12), 0.08, n: 12), fill: true, color: 0))
            return s
        },
        ArtFamily(name: "만화 장면", variants: 40) { r in
            var s: [ArtStroke] = [ArtStroke(points: line([(-1, 0.95), (1, 0.95), (1, -0.95), (-1, -0.95), (-1, 0.95)]), color: 0, width: 1.8)]
            // 배경 효과선
            for k in 0..<r.int(6, 10) { s.append(ArtStroke(points: wavy(from: -0.9, to: 0.9, y: 0.85 - Double(k) * 0.09, amp: 0.03, n: 24), color: 1, width: 0.9)) }
            // 주인공 (작은 웃는 얼굴)
            s.append(ArtStroke(points: circle(P(x: -0.35, y: -0.1), 0.3, n: 24), fill: true, color: 2))
            s.append(ArtStroke(points: [P(x: -0.45, y: 0), P(x: -0.37, y: 0)], color: 0, width: 1.5))
            s.append(ArtStroke(points: [P(x: -0.29, y: 0), P(x: -0.21, y: 0)], color: 0, width: 1.5))
            s.append(ArtStroke(points: circle(P(x: -0.35, y: -0.2), 0.12, from: 1.15 * .pi, to: 1.85 * .pi, n: 10), color: 0, width: 1.2))
            // 이펙트
            switch r.int(0, 3) {
            case 0: s.append(ArtStroke(points: starPoints(n: 8, inner: 0.5).map { P(x: $0.x * 0.25 + 0.45, y: $0.y * 0.25 + 0.25) }, fill: true, color: 2))
            case 1: s.append(ArtStroke(points: [P(x: 0.3, y: 0.45), P(x: 0.42, y: 0.25), P(x: 0.54, y: 0.45), P(x: 0.42, y: 0.42), P(x: 0.3, y: 0.45)], color: 1, width: 1.5)) // 느낌표
                    s.append(ArtStroke(points: circle(P(x: 0.45, y: 0.12), 0.05, n: 8), fill: true, color: 1))
            case 2: for k in 0..<3 { s.append(ArtStroke(points: [P(x: 0.25 + Double(k) * 0.12, y: 0.5), P(x: 0.35 + Double(k) * 0.12, y: 0.2)], color: 1, width: 1.2)) } // 속도선
            default: s.append(ArtStroke(points: heartPoints(fat: 1).map { P(x: $0.x * 0.3 + 0.45, y: $0.y * 0.3 + 0.25) }, fill: true, color: 0))
            }
            return s
        },
    ]

    static let glyphs: [Character: [[(Double, Double)]]] = [
        "H": [[(0, 0), (0, 1)], [(1, 0), (1, 1)], [(0, 0.5), (1, 0.5)]],
        "I": [[(0.5, 0), (0.5, 1)], [(0.2, 1), (0.8, 1)], [(0.2, 0), (0.8, 0)]],
        "O": [(0...20).map { i in let a = 2 * Double.pi * Double(i) / 20; return (0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a)) }],
        "K": [[(0, 0), (0, 1)], [(1, 1), (0, 0.45), (1, 0)]],
        "L": [[(0, 1), (0, 0), (0.9, 0)]],
        "W": [[(0, 1), (0.25, 0), (0.5, 0.6), (0.75, 0), (1, 1)]],
        "Y": [[(0, 1), (0.5, 0.5), (1, 1)], [(0.5, 0.5), (0.5, 0)]],
        "A": [[(0, 0), (0.5, 1), (1, 0)], [(0.22, 0.42), (0.78, 0.42)]],
        "G": [[(1, 0.85), (0.7, 1), (0.3, 1), (0, 0.7), (0, 0.3), (0.3, 0), (0.7, 0), (1, 0.25), (1, 0.45), (0.55, 0.45)]],
        "T": [[(0, 1), (1, 1)], [(0.5, 1), (0.5, 0)]],
        "M": [[(0, 0), (0, 1), (0.5, 0.4), (1, 1), (1, 0)]],
        "S": [[(1, 0.85), (0.8, 1), (0.2, 1), (0, 0.8), (0.1, 0.6), (0.9, 0.4), (1, 0.2), (0.8, 0), (0.2, 0), (0, 0.15)]],
        "P": [[(0, 0), (0, 1), (0.8, 1), (1, 0.85), (1, 0.65), (0.8, 0.5), (0, 0.5)]],
        "E": [[(1, 1), (0, 1), (0, 0), (1, 0)], [(0, 0.5), (0.75, 0.5)]],
        "N": [[(0, 0), (0, 1), (1, 0), (1, 1)]],
    ]

    static func letters(_ word: String) -> [[P]] {
        let chars = Array(word)
        let w = 2.0 / Double(chars.count) * 0.82
        let h = min(1.2, w * 1.5)
        var strokes: [[P]] = []
        for (i, ch) in chars.enumerated() {
            let x0 = -1 + 2.0 * Double(i) / Double(chars.count) + 0.05
            for g in glyphs[ch] ?? [] {
                strokes.append(g.map { P(x: CGFloat(x0 + $0.0 * w), y: CGFloat(-h / 2 + $0.1 * h)) })
            }
        }
        return strokes
    }

    // MARK: - 조합

    /// 회전 5 × 비율 3 × 색 3 × 반짝이 3 × 밑줄 3
    static let decorationVariants = 5 * 3 * 3 * 3 * 3
    /// 그림(채색) 도안용 꾸미기 — 회전 5 × 팔레트 5 (Brain이 고른다)
    static let artDecorationVariants = 5 * 5

    /// 만들 수 있는 낙서 수 (연속값 변화 제외)
    public static var variantCount: Int {
        families.reduce(0) { $0 + $1.variants } * decorationVariants
            + artFamilies.reduce(0) { $0 + $1.variants } * artDecorationVariants
    }

    /// seed → 도안. 45%는 그림(채색) 도안, 나머지는 선 도안.
    public static func generate(seed: UInt64) -> DoodleArt {
        var r = SplitMix64(seed: seed)
        if r.chance(0.45) {
            return generateArt(seed: seed)
        }
        let family = r.pick(families)
        var strokes = family.make(&r)

        // 꾸미기
        let rot = r.pick([0.0, 0.26, -0.26, 0.52, -0.52]) * (family.name == "글씨" ? 0.3 : 1)
        let aspect = r.pick([1.0, 0.8, 1.2])
        strokes = strokes.map { s in
            s.map { p in
                let x = Double(p.x) * aspect, y = Double(p.y)
                return P(x: CGFloat(x * cos(rot) - y * sin(rot)), y: CGFloat(x * sin(rot) + y * cos(rot)))
            }
        }
        let sparkles = r.pick([0, 3, 6])
        for _ in 0..<sparkles {
            let a = r.range(0, 2 * .pi), d = r.range(1.15, 1.45)
            let c = P(x: CGFloat(cos(a) * d), y: CGFloat(sin(a) * d))
            strokes.append([P(x: c.x - 0.07, y: c.y), P(x: c.x + 0.07, y: c.y)])
            strokes.append([P(x: c.x, y: c.y - 0.07), P(x: c.x, y: c.y + 0.07)])
        }
        switch r.int(0, 2) {
        case 1: strokes.append([P(x: -0.9, y: -1.25), P(x: 0.9, y: -1.25)])
        case 2: strokes.append((0...24).map { i in P(x: CGFloat(-0.9 + 1.8 * Double(i) / 24), y: CGFloat(-1.25 + 0.06 * sin(Double(i) * 1.6))) })
        default: break
        }

        // 색: 한 가지 / 획마다 / 무지개 조각
        let colorMode = r.int(0, 2)
        var out: [DoodleArt.Stroke] = []
        for (i, s) in strokes.enumerated() where s.count > 1 {
            switch colorMode {
            case 1:
                out.append(.init(points: s, color: i % 4))
            case 2 where s.count > 24:
                let chunk = max(6, s.count / 5)
                var k = 0
                var start = 0
                while start < s.count - 1 {
                    let end = min(s.count, start + chunk + 1)
                    out.append(.init(points: Array(s[start..<end]), color: k % 5))
                    start = end - 1
                    k += 1
                }
            default:
                out.append(.init(points: s, color: 0))
            }
        }
        return DoodleArt(name: family.name, strokes: out)
    }

    /// 그림(채색) 도안 — 색은 도안 뜻대로(하늘은 파랑, 해는 노랑) 쓰고 회전으로만 변형한다.
    static func generateArt(seed: UInt64) -> DoodleArt {
        var r = SplitMix64(seed: SplitMix64.mix(seed, 0xA27F))
        let family = r.pick(artFamilies)
        let arts = family.make(&r)
        let rot = r.pick([0.0, 0.12, -0.12, 0.26, -0.26])
        let out = arts.compactMap { a -> DoodleArt.Stroke? in
            guard a.points.count > 1 else { return nil }
            let pts = a.points.map { p in
                let x = Double(p.x), y = Double(p.y)
                return P(x: CGFloat(x * cos(rot) - y * sin(rot)), y: CGFloat(x * sin(rot) + y * cos(rot)))
            }
            return DoodleArt.Stroke(points: pts, color: a.color, fill: a.fill, width: a.width)
        }
        return DoodleArt(name: family.name, strokes: out)
    }
}
