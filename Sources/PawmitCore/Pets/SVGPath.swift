import CoreGraphics
import Foundation

/// SVG path `d` 문자열 ↔ CGPath.
///
/// 메이커 펫(kind "rig")의 부위 모양은 SVG path로 저장한다. 그래서 pet.json의 모양을 아무 SVG 뷰어에 붙여 확인할 수 있고,
/// 에이전트도 익숙한 형식으로 펫을 그릴 수 있다. 지원: M L H V C S Q T A Z (대·소문자 모두).
public enum SVGPath {
    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unexpected(String)
        case tooComplex

        public var errorDescription: String? {
            switch self {
            case .empty: return L10n.t("빈 path")
            case .unexpected(let s): return L10n.format("path를 읽을 수 없음: %@", L10n.t(s))
            case .tooComplex: return L10n.format("path가 너무 복잡함 (명령 %lld개 초과)", maxCommands)
            }
        }
    }

    public static let maxCommands = 4000

    public static func parse(_ d: String) throws -> CGPath {
        var scanner = Tokens(d)
        let path = CGMutablePath()
        var cmd: Character = " "
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var count = 0
        var hasSubpath = false

        while let next = scanner.peek() {
            count += 1
            if count > maxCommands { throw ParseError.tooComplex }
            if case .command(let c) = next {
                cmd = c
                scanner.advance()
            } else if cmd == " " {
                throw ParseError.unexpected("명령 없이 숫자로 시작")
            } else if cmd == "M" || cmd == "m" {
                // M 뒤에 이어진 좌표는 L
                cmd = cmd == "M" ? "L" : "l"
            }
            let rel = cmd.isLowercase
            func pt() throws -> CGPoint {
                let x = try scanner.number(), y = try scanner.number()
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd {
            case "M", "m":
                cur = try pt()
                start = cur
                path.move(to: cur)
                hasSubpath = true
                lastCubic = nil; lastQuad = nil
            case "L", "l":
                cur = try pt()
                if !hasSubpath { path.move(to: .zero); hasSubpath = true }
                path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "H", "h":
                let x = try scanner.number()
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "V", "v":
                let y = try scanner.number()
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "C", "c":
                let c1 = try pt(), c2 = try pt(), p = try pt()
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil
                cur = p
            case "S", "s":
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = try pt(), p = try pt()
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil
                cur = p
            case "Q", "q":
                let c = try pt(), p = try pt()
                path.addQuadCurve(to: p, control: c)
                lastQuad = c; lastCubic = nil
                cur = p
            case "T", "t":
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let p = try pt()
                path.addQuadCurve(to: p, control: c)
                lastQuad = c; lastCubic = nil
                cur = p
            case "A", "a":
                let rx = abs(try scanner.number()), ry = abs(try scanner.number())
                let rot = try scanner.number()
                let large = try scanner.flag(), sweep = try scanner.flag()
                let p = try pt()
                addArc(to: path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                lastCubic = nil; lastQuad = nil
                cur = p
            case "Z", "z":
                path.closeSubpath()
                cur = start
                lastCubic = nil; lastQuad = nil
                // Z 뒤에는 새 명령이 와야 한다
                if let n = scanner.peek(), case .number = n { throw ParseError.unexpected("Z 뒤 숫자") }
            default:
                throw ParseError.unexpected(L10n.format("모르는 명령 %@", String(cmd)))
            }
        }
        if path.isEmpty { throw ParseError.empty }
        return path
    }

    /// CGPath → `d` (절대 좌표 M L Q C Z, 소수 둘째 자리)
    public static func string(from path: CGPath, precision: Int = 2) -> String {
        var out: [String] = []
        func f(_ v: CGFloat) -> String {
            let s = String(format: "%.\(precision)f", Double(v))
            var t = s
            while t.contains("."), t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t == "-0" ? "0" : t
        }
        func p(_ q: CGPoint) -> String { "\(f(q.x)) \(f(q.y))" }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint: out.append("M\(p(e.points[0]))")
            case .addLineToPoint: out.append("L\(p(e.points[0]))")
            case .addQuadCurveToPoint: out.append("Q\(p(e.points[0])) \(p(e.points[1]))")
            case .addCurveToPoint: out.append("C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2]))")
            case .closeSubpath: out.append("Z")
            @unknown default: break
            }
        }
        return out.joined(separator: " ")
    }

    // MARK: - 호 (SVG 끝점 표기 → 중심 표기 → 3차 곡선 조각)

    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = rxIn, ry = ryIn
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dTheta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, dTheta > 0 { dTheta -= 2 * .pi }
        if sweep, dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)
        var th = theta1
        func point(_ a: CGFloat) -> CGPoint {
            let ex = rx * cos(a), ey = ry * sin(a)
            return CGPoint(x: cx + cosP * ex - sinP * ey, y: cy + sinP * ex + cosP * ey)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            let ex = -rx * sin(a), ey = ry * cos(a)
            return CGPoint(x: cosP * ex - sinP * ey, y: sinP * ex + cosP * ey)
        }
        for _ in 0..<segments {
            let a0 = th, a1 = th + delta
            let s = point(a0), e = point(a1), d0 = deriv(a0), d1 = deriv(a1)
            path.addCurve(to: e, control1: CGPoint(x: s.x + t * d0.x, y: s.y + t * d0.y),
                          control2: CGPoint(x: e.x - t * d1.x, y: e.y - t * d1.y))
            th = a1
        }
    }

    // MARK: - 토큰

    private enum Token: Equatable { case command(Character), number(CGFloat) }

    private struct Tokens {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        }

        mutating func peek() -> Token? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter, c != "e", c != "E" { return .command(c) }
            return .number(0)
        }

        mutating func advance() { i += 1 }

        mutating func number() throws -> CGFloat {
            skipSeparators()
            let startIndex = i
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var sawDigit = false, sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isASCII, c.isNumber { sawDigit = true; i += 1 }
                else if c == ".", !sawDot { sawDot = true; i += 1 }
                else { break }
            }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    i = j
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                }
            }
            guard sawDigit, let v = Double(String(chars[startIndex..<i])), v.isFinite else {
                throw ParseError.unexpected(L10n.format("숫자 자리: '%@'", String(chars[startIndex..<min(chars.count, startIndex + 8)])))
            }
            return CGFloat(v)
        }

        /// 호의 플래그는 "0"/"1" 한 글자 (구분자 없이 붙을 수 있음)
        mutating func flag() throws -> Bool {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { throw ParseError.unexpected("호 플래그") }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }
}
