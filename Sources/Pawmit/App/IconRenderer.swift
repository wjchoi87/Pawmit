import AppKit

/// 개발용: `Pawmit --render-icon <폴더>` 로 앱 아이콘 iconset을 만든다 (scripts/build-app.sh 가 사용)
enum IconRenderer {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                                      ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                                      ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let img = render(px), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    static func render(_ px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(px) / 1024
        ctx.scaleBy(x: s, y: s)
        // macOS 아이콘 격자: 824 사각형, 모서리 185
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
        let colors = [CGColor(srgbRed: 1, green: 0.86, blue: 0.9, alpha: 1), CGColor(srgbRed: 0.84, green: 0.9, blue: 1, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        var p = PetPose()
        p.anim = .wave
        p.clock = 1.2
        p.animTime = 0.45
        ctx.translateBy(x: 512, y: 215)
        ctx.scaleBy(x: 11.2, y: 11.2)
        ChibiRenderer(species: ChibiSpecies.named("mongle")!).draw(p, in: ctx)
        return ctx.makeImage()
    }
}
