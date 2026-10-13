import AppKit
import PageModel

extension NSAttributedString.Key {
    static let pmHeading = NSAttributedString.Key("pm.heading")
    static let pmList = NSAttributedString.Key("pm.list")
    static let pmIndent = NSAttributedString.Key("pm.indent")
    /// Tags the characters of a list marker ("•\t", "N.\t"); they are view-only and never reach the model.
    static let pmMarker = NSAttributedString.Key("pm.marker")
}

/// A caret position that survives a re-render: paragraph index plus UTF-16 offset into the paragraph's
/// body text (list marker characters excluded).
public struct BodyPosition: Equatable {
    public var paragraph: Int
    public var offset: Int
    public init(paragraph: Int, offset: Int) { self.paragraph = paragraph; self.offset = offset }
}

public struct BodySelection: Equatable {
    public var start: BodyPosition
    public var end: BodyPosition
    public init(start: BodyPosition, end: BodyPosition) { self.start = start; self.end = end }
}

/// Converts between the model's paragraphs/runs and the attributed text shown in an NSTextView.
public enum AttributedBridge {
    public static let baseSize: CGFloat = 14
    static let headingScale: [CGFloat] = Paragraph.headingScales.map { CGFloat($0) }
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
                var a = attributes(for: markerStyle, heading: p.heading)
                a[.pmMarker] = true
                seg.append(NSAttributedString(string: marker, attributes: a))
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
        for line in lineRanges(ns) {
            var p = Paragraph(runs: [])
            if line.location < ns.length {                  // an empty last line has no character to read from
                let a = attributed.attributes(at: line.location, effectiveRange: nil)
                p.heading = (a[.pmHeading] as? Int) ?? 0
                p.indent = (a[.pmIndent] as? Int) ?? 0
                p.list = ListStyle(rawValue: (a[.pmList] as? String) ?? "") ?? .none
                if let ps = a[.paragraphStyle] as? NSParagraphStyle {
                    p.alignment = ps.alignment == .center ? .center : ps.alignment == .right ? .right : .left
                }
            }
            // Marker characters are skipped wherever they are (e.g. joined into a line by a deletion).
            // Only the leading ones decide the list: none at all means a new item still awaiting its marker
            // (Return in a list); a damaged one means the user deleted part of it, which ends the item's list.
            var leading = "", atStart = true
            attributed.enumerateAttributes(in: line, options: []) { attrs, r, _ in
                let text = ns.substring(with: r)
                if attrs[.pmMarker] != nil {
                    if atStart { leading += text }
                    return
                }
                atStart = false
                let style = self.style(from: attrs, heading: p.heading)
                if let last = p.runs.last, last.style == style {
                    p.runs[p.runs.count - 1].text += text
                } else {
                    p.runs.append(Run(text: text, style: style))
                }
            }
            if !leading.isEmpty && !isCompleteMarker(leading) { p.list = .none }
            result.append(p)
        }
        return result
    }

    private static func isCompleteMarker(_ s: String) -> Bool {
        if s == "•\t" { return true }
        guard s.hasSuffix(".\t") else { return false }
        let digits = s.dropLast(2)
        return !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) }
    }

    /// UTF-16 ranges of the "\n"-separated lines (one per paragraph), newline excluded.
    private static func lineRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for i in 0..<ns.length where ns.character(at: i) == 10 {
            ranges.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        ranges.append(NSRange(location: start, length: ns.length - start))
        return ranges
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

    /// Typing attributes with the marker tag removed, so text typed next to a marker is never part of it.
    public static func typingAttributes(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = a
        a[.pmMarker] = nil
        return a
    }

    private static func isMarker(_ attributed: NSAttributedString, _ i: Int) -> Bool {
        attributed.attribute(.pmMarker, at: i, effectiveRange: nil) != nil
    }

    private static func position(at location: Int, in attributed: NSAttributedString) -> BodyPosition {
        let lines = lineRanges(attributed.string as NSString)
        let loc = min(max(location, 0), attributed.length)
        let index = lines.firstIndex { loc <= NSMaxRange($0) } ?? lines.count - 1
        let line = lines[index]
        var offset = 0
        for i in line.location..<max(loc, line.location) where !isMarker(attributed, i) { offset += 1 }
        return BodyPosition(paragraph: index, offset: offset)
    }

    /// Where a body position lies in `attributed`: after any leading marker, or at the line start when
    /// `lineStart` is set and the offset is 0 (the end of a selection that stops at a paragraph start).
    private static func location(of pos: BodyPosition, in attributed: NSAttributedString, lineStart: Bool) -> Int {
        let lines = lineRanges(attributed.string as NSString)
        let line = lines[min(max(pos.paragraph, 0), lines.count - 1)]
        if lineStart && pos.offset == 0 { return line.location }
        var i = line.location, count = 0
        while i < NSMaxRange(line) {
            if isMarker(attributed, i) { i += 1; continue }
            if count >= pos.offset { break }
            count += 1; i += 1
        }
        return i
    }

    /// The selection as body positions, so it can be carried across a re-render that adds or drops markers.
    public static func bodySelection(_ sel: NSRange, in attributed: NSAttributedString) -> BodySelection {
        BodySelection(start: position(at: sel.location, in: attributed),
                      end: position(at: sel.location + sel.length, in: attributed))
    }

    /// The text range of a body selection in (re-rendered) `attributed`.
    public static func range(of sel: BodySelection, in attributed: NSAttributedString) -> NSRange {
        let start = location(of: sel.start, in: attributed, lineStart: false)
        let end = max(start, location(of: sel.end, in: attributed, lineStart: sel.start != sel.end))
        return NSRange(location: start, length: end - start)
    }

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
