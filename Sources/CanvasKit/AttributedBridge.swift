import AppKit
import PageModel

extension NSAttributedString.Key {
    static let pmHeading = NSAttributedString.Key("pm.heading")
    static let pmList = NSAttributedString.Key("pm.list")
    static let pmIndent = NSAttributedString.Key("pm.indent")
}

/// Converts between the model's paragraphs/runs and the attributed text shown in an NSTextView.
public enum AttributedBridge {
    public static let baseSize: CGFloat = 14
    static let headingScale: [CGFloat] = [1, 1.8, 1.4, 1.2]
    static let indentStep: CGFloat = 24
    static let listGap: CGFloat = 18

    // MARK: model -> attributed

    public static func attributed(from paragraphs: [Paragraph]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var counters: [Int: Int] = [:]
        for (i, p) in paragraphs.enumerated() {
            counters = updatedCounters(counters, for: p)
            let seg = NSMutableAttributedString()
            if p.list != .none {
                let marker = p.list == .bullet ? "•\t" : "\(counters[p.indent] ?? 1).\t"
                let markerStyle = p.runs.first?.style ?? RunStyle()
                seg.append(NSAttributedString(string: marker, attributes: attributes(for: markerStyle, heading: p.heading)))
            }
            for r in p.runs {
                seg.append(NSAttributedString(string: r.text, attributes: attributes(for: r.style, heading: p.heading)))
            }
            if i < paragraphs.count - 1 {
                seg.append(NSAttributedString(string: "\n", attributes: attributes(for: RunStyle(), heading: p.heading)))
            }
            if seg.length > 0 { seg.addAttributes(paragraphAttributes(p), range: NSRange(location: 0, length: seg.length)) }
            out.append(seg)
        }
        return out
    }

    private static func updatedCounters(_ c: [Int: Int], for p: Paragraph) -> [Int: Int] {
        var c = c
        for key in c.keys where key > p.indent { c[key] = nil }          // leaving a nested block resets it
        if p.list == .numbered { c[p.indent, default: 0] += 1 } else { c[p.indent] = nil }
        return c
    }

    static func font(for style: RunStyle, heading: Int) -> NSFont {
        let size = CGFloat(style.fontSize ?? Double(baseSize)) * headingScale[min(max(heading, 0), 3)]
        var f = style.fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        let fm = NSFontManager.shared
        if style.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if style.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func attributes(for style: RunStyle, heading: Int) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(for: style, heading: heading)]
        if style.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = style.colorHex, let c = color(hex: h) { a[.foregroundColor] = c }
        if let h = style.highlightHex, let c = color(hex: h) { a[.backgroundColor] = c }
        switch style.script {
        case .sup: a[.baselineOffset] = baseSize * 0.35
        case .sub: a[.baselineOffset] = -baseSize * 0.35
        case .normal: break
        }
        if let l = style.link { a[.link] = l }
        return a
    }

    static func paragraphAttributes(_ p: Paragraph) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        switch p.alignment {
        case .left: ps.alignment = .left
        case .center: ps.alignment = .center
        case .right: ps.alignment = .right
        }
        let indent = CGFloat(p.indent) * indentStep
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent + (p.list == .none ? 0 : listGap)
        ps.tabStops = p.list == .none ? [] : [NSTextTab(textAlignment: .left, location: indent + listGap)]
        return [.paragraphStyle: ps, .pmHeading: p.heading, .pmList: p.list.rawValue, .pmIndent: p.indent]
    }

    // MARK: attributed -> model

    public static func paragraphs(from attributed: NSAttributedString) -> [Paragraph] {
        let ns = attributed.string as NSString
        var result: [Paragraph] = []
        var location = 0
        for line in attributed.string.components(separatedBy: "\n") {
            let len = (line as NSString).length
            var p = Paragraph(runs: [])
            if location < ns.length {                       // an empty last line has no character to read from
                let a = attributed.attributes(at: location, effectiveRange: nil)
                p.heading = (a[.pmHeading] as? Int) ?? 0
                p.indent = (a[.pmIndent] as? Int) ?? 0
                p.list = ListStyle(rawValue: (a[.pmList] as? String) ?? "") ?? .none
                if let ps = a[.paragraphStyle] as? NSParagraphStyle {
                    p.alignment = ps.alignment == .center ? .center : ps.alignment == .right ? .right : .left
                }
            }
            let marker = p.list == .none ? 0 : markerLength(of: line)
            let body = NSRange(location: location + marker, length: len - marker)
            if body.length > 0 {
                attributed.enumerateAttributes(in: body, options: []) { attrs, r, _ in
                    let style = self.style(from: attrs, heading: p.heading)
                    if let last = p.runs.last, last.style == style {
                        p.runs[p.runs.count - 1].text += ns.substring(with: r)
                    } else {
                        p.runs.append(Run(text: ns.substring(with: r), style: style))
                    }
                }
            }
            result.append(p)
            location += len + 1
        }
        return result
    }

    /// UTF-16 length of a leading "•\t" or "N.\t", or 0 if the line has no marker (user deleted it).
    private static func markerLength(of line: String) -> Int {
        guard let tab = line.firstIndex(of: "\t") else { return 0 }
        let head = line[line.startIndex..<tab]
        let isMarker = head == "•" || (head.hasSuffix(".") && head.dropLast().allSatisfy(\.isNumber) && head.count > 1)
        return isMarker ? line[line.startIndex...tab].utf16.count : 0
    }

    static func style(from attrs: [NSAttributedString.Key: Any], heading: Int) -> RunStyle {
        var s = RunStyle()
        if let f = attrs[.font] as? NSFont {
            let traits = f.fontDescriptor.symbolicTraits
            s.bold = traits.contains(.bold)
            s.italic = traits.contains(.italic)
            let size = ((f.pointSize / headingScale[min(max(heading, 0), 3)]) * 2).rounded() / 2
            if abs(size - baseSize) > 0.01 { s.fontSize = Double(size) }
            if !f.fontName.hasPrefix(".") { s.fontName = f.fontName }
        }
        if let c = attrs[.foregroundColor] as? NSColor, c.type != .catalog { s.colorHex = hex(of: c) }
        if let c = attrs[.backgroundColor] as? NSColor, c.type != .catalog { s.highlightHex = hex(of: c) }
        if let u = attrs[.underlineStyle] as? NSNumber, u.intValue != 0 { s.underline = true }
        if let u = attrs[.strikethroughStyle] as? NSNumber, u.intValue != 0 { s.strike = true }
        if let b = (attrs[.baselineOffset] as? NSNumber)?.doubleValue {
            s.script = b > 0 ? .sup : b < 0 ? .sub : .normal
        }
        if let l = attrs[.link] { s.link = (l as? URL)?.absoluteString ?? (l as? String) }
        return s
    }

    // MARK: selection

    public static func paragraphRange(forSelection sel: NSRange, in string: String) -> ClosedRange<Int> {
        let ns = string as NSString
        func lineIndex(at loc: Int) -> Int {
            let clamped = min(max(loc, 0), ns.length)
            return ns.substring(to: clamped).components(separatedBy: "\n").count - 1
        }
        let start = lineIndex(at: sel.location)
        let end = sel.length > 0 ? lineIndex(at: sel.location + sel.length - 1) : start
        return start...max(start, end)
    }

    // MARK: colour helpers

    static func color(hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(of c: NSColor) -> String? {
        guard let rgb = c.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
