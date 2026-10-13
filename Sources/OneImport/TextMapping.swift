import Foundation
import OneStore
import PageModel

enum StyleMapper {
    /// Applies the formatting properties present on `style` (a ParagraphStyleObject) on top of `run`.
    static func apply(_ style: OneObject, to run: inout RunStyle) {
        let p = style.properties
        if let v = p.bool(PID.bold) { run.bold = v }
        if let v = p.bool(PID.italic) { run.italic = v }
        if let v = p.bool(PID.underline) { run.underline = v }
        if let v = p.bool(PID.strikethrough) { run.strike = v }
        let sup = p.bool(PID.superscript), sub = p.bool(PID.subscriptText)
        if sup == true { run.script = .sup }
        else if sub == true { run.script = .sub }
        else if sup == false || sub == false { run.script = .normal }
        if let name = p.string(PID.font), !name.isEmpty { run.fontName = name }
        if let halfPoints = p.u16(PID.fontSize), halfPoints > 0 { run.fontSize = Double(halfPoints) / 2 }
        if let c = p.u32(PID.fontColor) { run.colorHex = ColorRef.hex(c) }
        if let c = p.u32(PID.highlight) { run.highlightHex = ColorRef.hex(c) }
        if let isLink = p.bool(PID.hyperlink) {
            let url = p.string(PID.hyperlinkURL) ?? ""
            run.link = isLink && !url.isEmpty ? url : nil
        }
    }

    static func headingLevel(named name: String) -> Int? {
        switch name {
        case "h1": return 1
        case "h2": return 2
        case "h3": return 3
        default: return nil
        }
    }
}

/// Remembers which style objects have already had their unread properties counted (one ledger per page).
final class StyleLedger {
    var seen = Set<ExtendedGUID>()
}

struct ParagraphMapper {
    let graph: ObjectGraph
    private let ledger = StyleLedger()

    init(graph: ObjectGraph) { self.graph = graph }

    /// Counts the unread properties of a style object, at most once per object per ledger.
    private func noteStyle(_ style: OneObject, _ report: inout ImportReport) {
        if ledger.seen.insert(style.id).inserted { report.noteIgnoredProperties(of: style, consumed: PID.consumedByStyle) }
    }

    /// Numbered when the NumberListFormat string contains U+FFFD (the numbering character), else a bullet.
    static func listStyle(of numberList: OneObject) -> ListStyle {
        guard let d = numberList.properties.data(PID.numberListFormat) else { return .bullet }
        var units: [UInt16] = []
        var i = 0
        while i + 1 < d.count {
            units.append(UInt16(d[d.startIndex + i]) | UInt16(d[d.startIndex + i + 1]) << 8)
            i += 2
        }
        return units.dropFirst().contains(0xFFFD) ? .numbered : .bullet     // the first unit is the string length
    }

    /// True when `bounds` (0, the run-end indexes, then the text length) is non-decreasing, within the text,
    /// and does not cut a surrogate pair in two.
    private func boundsValid(_ bounds: [Int], _ units: [UInt16]) -> Bool {
        guard bounds.last == units.count else { return false }
        for i in 1..<bounds.count where bounds[i] < bounds[i - 1] { return false }
        for b in bounds.dropFirst().dropLast() {
            guard b >= 0, b <= units.count else { return false }
            if b > 0, b < units.count, (0xD800...0xDBFF).contains(units[b - 1]), (0xDC00...0xDFFF).contains(units[b]) { return false }
        }
        return true
    }

    func paragraph(richText rt: OneObject, indent: Int, list: ListStyle, report: inout ImportReport) -> Paragraph {
        let p = rt.properties
        report.noteIgnoredProperties(of: rt, consumed: PID.consumedByRichText)

        // Paragraph-level (named) style: heading, base run style, charset and alignment defaults.
        var base = RunStyle()
        var heading = 0
        var styleCharset: UInt8?
        var styleAlignment: UInt8?
        if let styleID = p.objectIDs(PID.paragraphStyle).first, let styleObj = graph.object(styleID) {
            noteStyle(styleObj, &report)
            StyleMapper.apply(styleObj, to: &base)
            styleCharset = styleObj.properties.u8(PID.charset)
            styleAlignment = styleObj.properties.u8(PID.paragraphAlignment)
            if let name = styleObj.properties.string(PID.paragraphStyleId) {
                if let h = StyleMapper.headingLevel(named: name) { heading = h }
                else if name != "p" { report.approximated("namedStyleFlattened") }
            }
        }
        let formats: [OneObject?] = p.objectIDs(PID.runFormatting).map { graph.object($0) }

        // Text: Unicode wins when both encodings are present.
        let text: String
        if let d = p.data(PID.richUnicode) {
            text = OneText.utf16String(d)
        } else if let d = p.data(PID.richAscii) {
            let charset = styleCharset ?? formats.compactMap { $0?.properties.u8(PID.charset) }.first
            let decoded = CharsetDecoder.decode(d, charset: charset)
            if decoded.usedFallback { report.approximated("charsetFallback") }
            text = decoded.text
        } else {
            text = ""
        }
        let units = Array(text.utf16)

        // Runs: TextRunIndex lists where runs end (run count = indexes + 1).
        var bounds = [0] + (p.u32Array(PID.runIndex) ?? []).map { Int(clamping: $0) } + [units.count]
        if !boundsValid(bounds, units) {
            bounds = [0, units.count]
            if p.data(PID.runIndex) != nil { report.approximated("invalidRunIndex") }
        }
        var runs: [Run] = []
        for i in 0..<(bounds.count - 1) {
            let slice = units[bounds[i]..<bounds[i + 1]]
            if slice.isEmpty { continue }
            var style = base
            if i < formats.count, let f = formats[i] {
                noteStyle(f, &report)
                StyleMapper.apply(f, to: &style)
                if f.properties.bool(PID.hyperlink) == true, style.link == nil { report.approximated("hyperlinkWithoutURL") }
            }
            // The editor multiplies the stored size by the heading scale, so store size / scale to keep the look.
            if heading > 0, let size = style.fontSize { style.fontSize = (size / Paragraph.headingScales[heading] * 2).rounded() / 2 }
            let chunk = String(decoding: slice, as: UTF16.self)
            if let last = runs.last, last.style == style { runs[runs.count - 1].text += chunk }
            else { runs.append(Run(text: chunk, style: style)) }
        }

        var alignment: Alignment = .left
        if let v = p.u8(PID.paragraphAlignment) ?? styleAlignment {
            switch v {
            case 0: alignment = .left
            case 1: alignment = .center
            case 2: alignment = .right
            default: report.approximated("unknownAlignment")
            }
        }
        return Paragraph(runs: runs, indent: min(max(indent, 0), Paragraph.maxIndent), heading: heading,
                         list: list, alignment: alignment)
    }
}
