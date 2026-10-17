import AppKit

/// 메뉴바 집 아이콘 (템플릿 이미지라 다크/라이트 메뉴바에 자동으로 맞춰진다)
enum HouseIcon {
    enum State { case away, home, calling }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // 지붕
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: 2.5, y: 9.5))
            roof.line(to: NSPoint(x: 10, y: 16.2))
            roof.line(to: NSPoint(x: 17.5, y: 9.5))
            roof.lineWidth = 1.7
            roof.lineCapStyle = .round
            roof.lineJoinStyle = .round
            roof.stroke()
            // 굴뚝
            NSBezierPath(rect: NSRect(x: 13.6, y: 12.2, width: 1.8, height: 3)).fill()
            // 몸통
            let body = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 2, width: 10.8, height: 9), xRadius: 1.6, yRadius: 1.6)
            body.lineWidth = 1.6
            body.stroke()
            switch state {
            case .away:
                // 문이 열려 있음 (빈 집)
                let door = NSBezierPath(roundedRect: NSRect(x: 8.3, y: 2, width: 3.4, height: 5.2), xRadius: 1.7, yRadius: 1.7)
                door.lineWidth = 1.3
                door.stroke()
            case .home:
                // 불 켜진 창문 + 닫힌 문 (펫이 집에 있음)
                NSBezierPath(roundedRect: NSRect(x: 6.6, y: 5.6, width: 3.2, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
                NSBezierPath(roundedRect: NSRect(x: 11, y: 2, width: 2.8, height: 4.6), xRadius: 1.3, yRadius: 1.3).fill()
            case .calling:
                // 펫이 부름: 문 + 느낌표 점
                NSBezierPath(roundedRect: NSRect(x: 8.3, y: 2, width: 3.4, height: 5.2), xRadius: 1.7, yRadius: 1.7).fill()
                NSBezierPath(ovalIn: NSRect(x: 15.8, y: 12.6, width: 4, height: 4)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
