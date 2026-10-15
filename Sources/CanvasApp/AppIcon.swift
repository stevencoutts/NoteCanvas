import AppKit

/// Dock icon drawn at launch. `swift run` has no app bundle, so an .icns never reaches the Dock.
enum AppIcon {
    /// Same stationery colours as `AppShell.Palette`.
    private static let stone = NSColor(srgbRed: 0.90, green: 0.87, blue: 0.82, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.99, green: 0.975, blue: 0.955, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.24, green: 0.21, blue: 0.18, alpha: 1)
    private static let edge = NSColor(srgbRed: 0.62, green: 0.55, blue: 0.46, alpha: 0.55)

    static func image() -> NSImage {
        let pixels = 1024
        let size = NSSize(width: pixels, height: pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cgImage = raster(in: context, size: size) else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = false
        return image
    }

    private static func raster(in context: CGContext, size: NSSize) -> CGImage? {
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func draw(in rect: NSRect) {
        stone.setFill()
        squircle(in: rect).fill()

        let page = NSRect(x: rect.midX - 300, y: rect.midY - 364, width: 600, height: 728)
        let pagePath = NSBezierPath(roundedRect: page, xRadius: 36, yRadius: 36)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = ink.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        shadow.shadowBlurRadius = 40
        shadow.set()
        paper.setFill()
        pagePath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        edge.setStroke()
        pagePath.lineWidth = 14
        pagePath.stroke()

        // One thick pen mark, high on the page, so it stays a blot of ink rather than lines of writing.
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: page.midX - 150, y: page.maxY - 290))
        mark.curve(to: NSPoint(x: page.midX + 155, y: page.maxY - 240),
                   controlPoint1: NSPoint(x: page.midX - 40, y: page.maxY - 360),
                   controlPoint2: NSPoint(x: page.midX + 70, y: page.maxY - 168))
        mark.lineWidth = 100
        mark.lineCapStyle = .round
        ink.setStroke()
        mark.stroke()
    }

    /// macOS icon superellipse (n = 5). The Dock does not mask `applicationIconImage` itself.
    private static func squircle(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = 180
        let exponent = 2 / CGFloat(5)
        let a = rect.width / 2
        let b = rect.height / 2
        for i in 0...steps {
            let t = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
            let ct = cos(t)
            let st = sin(t)
            let point = NSPoint(
                x: rect.midX + a * pow(abs(ct), exponent) * (ct < 0 ? -1 : 1),
                y: rect.midY + b * pow(abs(st), exponent) * (st < 0 ? -1 : 1)
            )
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
