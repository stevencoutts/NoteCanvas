import AppKit

/// Dock icon drawn at launch. `swift run` has no app bundle, so an .icns never reaches the Dock.
enum AppIcon {
    private static let navyTop = NSColor(srgbRed: 0.184, green: 0.290, blue: 0.478, alpha: 1)
    private static let navyBottom = NSColor(srgbRed: 0.102, green: 0.165, blue: 0.290, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.984, green: 0.969, blue: 0.941, alpha: 1)
    private static let fold = NSColor(srgbRed: 0.851, green: 0.816, blue: 0.753, alpha: 1)
    private static let amber = NSColor(srgbRed: 0.878, green: 0.565, blue: 0.227, alpha: 1)

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

    /// A cream page with a folded corner, a bold navy N and a short amber cursor line, on a navy tile.
    /// Coordinates are on a 1024 grid with the origin at the bottom left.
    private static func draw(in rect: NSRect) {
        NSGradient(starting: navyTop, ending: navyBottom)?.draw(in: squircle(in: rect), angle: -90)

        let page = NSBezierPath()
        page.move(to: NSPoint(x: 290, y: 190))
        page.line(to: NSPoint(x: 760, y: 190))
        page.line(to: NSPoint(x: 760, y: 714))
        page.line(to: NSPoint(x: 640, y: 834))
        page.line(to: NSPoint(x: 290, y: 834))
        page.close()

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.shadowBlurRadius = 44
        shadow.set()
        paper.setFill()
        page.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: 640, y: 834))
        corner.line(to: NSPoint(x: 640, y: 714))
        corner.line(to: NSPoint(x: 760, y: 714))
        corner.close()
        fold.setFill()
        corner.fill()

        let letter = NSBezierPath()
        letter.move(to: NSPoint(x: 380, y: 314))
        letter.line(to: NSPoint(x: 380, y: 584))
        letter.line(to: NSPoint(x: 530, y: 374))
        letter.line(to: NSPoint(x: 530, y: 584))
        letter.lineWidth = 56
        letter.lineCapStyle = .round
        letter.lineJoinStyle = .round
        navyTop.setStroke()
        letter.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: 600, y: 314))
        cursor.line(to: NSPoint(x: 680, y: 314))
        cursor.lineWidth = 30
        cursor.lineCapStyle = .round
        amber.setStroke()
        cursor.stroke()
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
