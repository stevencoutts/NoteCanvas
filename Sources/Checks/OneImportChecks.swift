import Foundation
@testable import OneImport
import OneStore
import PageModel

/// An in-memory object graph for mapping checks (no file bytes involved).
struct Gx {
    var objects: [ExtendedGUID: OneObject] = [:]
    private var next: UInt32 = 1
    mutating func add(_ jcid: JCID, _ props: [OneProperty] = [], fileData: FileDataReference? = nil) -> ExtendedGUID {
        let id = ExtendedGUID(guid: GUID(hi: 7, lo: 7), n: next)
        next += 1
        objects[id] = OneObject(id: id, jcid: jcid, properties: PropertySet(props), fileData: fileData)
        return id
    }
    var graph: ObjectGraph { ObjectGraph(objects: objects) }
    func object(_ id: ExtendedGUID) -> OneObject { objects[id]! }
}

func P(_ id: PropertyID, _ v: OneValue) -> OneProperty { OneProperty(id, v) }
func wz(_ s: String) -> OneValue { .bytes(Data(utf16le(s) + [0, 0])) }          // UTF-16 text with a trailing NUL
func asciiValue(_ b: [UInt8]) -> OneValue { .bytes(Data(b + [0])) }
func u32List(_ xs: [UInt32]) -> OneValue { .bytes(Data(xs.flatMap { le32($0) })) }
func floatValue(_ f: Float) -> OneValue { .u32(f.bitPattern) }

extension RunStyle {
    static func sized(_ points: Double) -> RunStyle { var s = RunStyle(); s.fontSize = points; return s }
}

func oneImportTextChecks() {
    // ---- COLORREF ----
    checkEqual(ColorRef.hex(0x0000FF), "#FF0000", "COLORREF is 0x00BBGGRR: low byte is red")
    checkEqual(ColorRef.hex(0xFF0000), "#0000FF", "…high byte is blue")
    checkEqual(ColorRef.hex(0x00FF00), "#00FF00", "…middle byte is green")
    checkEqual(ColorRef.hex(0xFF00_0000), nil, "0xFF000000 is automatic")
    checkEqual(ColorRef.hex(0x0100_0000), nil, "an out-of-range COLORREF is ignored")

    // ---- charsets ----
    func dec(_ b: [UInt8], _ c: UInt8?) -> (text: String, fallback: Bool) {
        let r = CharsetDecoder.decode(Data(b), charset: c); return (r.text, r.usedFallback)
    }
    checkEqual(dec([0x80, 0x41], 0).text, "€A", "ANSI is Windows-1252")
    checkEqual(dec([0x80], nil).text, "€", "no charset means ANSI")
    checkEqual(dec([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], 204).text, "Привет", "Russian is Windows-1251")
    checkEqual(dec([0xC1], 161).text, "Α", "Greek is Windows-1253")
    checkEqual(dec([0xE0], 177).text, "א", "Hebrew is Windows-1255")
    checkEqual(dec([0x82, 0xA0], 128).text, "あ", "Shift-JIS is code page 932")
    checkEqual(dec([0x41, 0x00, 0x00], 0).text, "A", "trailing NULs are removed")
    checkEqual(dec([0x41], 0).fallback, false, "a known charset is not a fallback")
    let unknown = dec([0x41, 0xE9], 99)
    checkEqual(unknown.text, "Aé", "an unknown charset falls back to Windows-1252")
    checkEqual(unknown.fallback, true, "…and says so")

    // ---- run styles ----
    var g = Gx()
    let full = g.add(.paragraphStyle, [P(PID.bold, .bool(true)), P(PID.italic, .bool(false)), P(PID.underline, .bool(true)),
                                       P(PID.strikethrough, .bool(true)), P(PID.font, wz("Calibri")), P(PID.fontSize, .u16(22)),
                                       P(PID.fontColor, .u32(0x0000FF)), P(PID.highlight, .u32(0xFF00_0000))])
    var rs = RunStyle()
    StyleMapper.apply(g.object(full), to: &rs)
    checkEqual(rs.bold, true, "bold"); checkEqual(rs.italic, false, "italic false"); checkEqual(rs.underline, true, "underline")
    checkEqual(rs.strike, true, "strikethrough"); checkEqual(rs.fontName, "Calibri", "font name")
    checkEqual(rs.fontSize, 11, "FontSize is half-points"); checkEqual(rs.colorHex, "#FF0000", "font colour")
    checkEqual(rs.highlightHex, nil, "automatic highlight is none")
    let boldOff = g.add(.paragraphStyle, [P(PID.bold, .bool(false))])
    StyleMapper.apply(g.object(boldOff), to: &rs)
    checkEqual(rs.bold, false, "a later style overrides what it sets")
    checkEqual(rs.fontName, "Calibri", "…and leaves the rest alone")
    let sup = g.add(.paragraphStyle, [P(PID.superscript, .bool(true))]), sub = g.add(.paragraphStyle, [P(PID.subscriptText, .bool(true))])
    var s2 = RunStyle(); StyleMapper.apply(g.object(sup), to: &s2); checkEqual(s2.script, .sup, "superscript")
    s2 = RunStyle(); StyleMapper.apply(g.object(sub), to: &s2); checkEqual(s2.script, .sub, "subscript")
    let clear = g.add(.paragraphStyle, [P(PID.superscript, .bool(false)), P(PID.subscriptText, .bool(false))])
    StyleMapper.apply(g.object(clear), to: &s2); checkEqual(s2.script, .normal, "both false resets the script")
    let link = g.add(.paragraphStyle, [P(PID.hyperlink, .bool(true)), P(PID.hyperlinkURL, wz("https://example.com"))])
    var s3 = RunStyle(); StyleMapper.apply(g.object(link), to: &s3); checkEqual(s3.link, "https://example.com", "hyperlink with URL")
    let noURL = g.add(.paragraphStyle, [P(PID.hyperlink, .bool(true))])
    var s4 = RunStyle(); StyleMapper.apply(g.object(noURL), to: &s4); checkEqual(s4.link, nil, "hyperlink without a URL is not a link")
    let unlink = g.add(.paragraphStyle, [P(PID.hyperlink, .bool(false))])
    StyleMapper.apply(g.object(unlink), to: &s3); checkEqual(s3.link, nil, "hyperlink false clears the link")
    checkEqual(StyleMapper.headingLevel(named: "h1"), 1, "h1"); checkEqual(StyleMapper.headingLevel(named: "h2"), 2, "h2")
    checkEqual(StyleMapper.headingLevel(named: "h3"), 3, "h3"); checkEqual(StyleMapper.headingLevel(named: "h4"), nil, "h4 is not a heading")
    checkEqual(StyleMapper.headingLevel(named: "p"), nil, "p is body text")

    // ---- list kind ----
    func fmt(_ units: [UInt16]) -> OneObject {
        var gg = Gx(); let id = gg.add(.numberList, [P(PID.numberListFormat, .bytes(Data(units.flatMap { le16($0) })))]); return gg.object(id)
    }
    checkEqual(ParagraphMapper.listStyle(of: fmt([4, 0xFFFD, 0x30, 0x2E, 0x20])), .numbered, "a format with U+FFFD is numbered")
    checkEqual(ParagraphMapper.listStyle(of: fmt([1, 0x2022])), .bullet, "a format without U+FFFD is a bullet")
    var gl = Gx(); let noFmt = gl.add(.numberList)
    checkEqual(ParagraphMapper.listStyle(of: gl.object(noFmt)), .bullet, "a missing format is a bullet")

    // ---- paragraphs ----
    var pg = Gx()
    let body = pg.add(.paragraphStyle, [P(PID.paragraphStyleId, wz("p")), P(PID.fontSize, .u16(22))])
    let boldFmt = pg.add(.paragraphStyle, [P(PID.bold, .bool(true))])
    let italicFmt = pg.add(.paragraphStyle, [P(PID.italic, .bool(true))])
    func map(_ props: [OneProperty], indent: Int = 0, list: ListStyle = .none, more: ((inout Gx) -> Void)? = nil)
        -> (paragraph: Paragraph, report: ImportReport) {
        var gx = pg
        more?(&gx)
        let rt = gx.add(.richText, props)
        var report = ImportReport()
        let p = ParagraphMapper(graph: gx.graph).paragraph(richText: gx.object(rt), indent: indent, list: list, report: &report)
        return (p, report)
    }
    let base = RunStyle.sized(11)

    let plain = map([P(PID.richUnicode, wz("Hello")), P(PID.paragraphStyle, .objectIDs([body]))])
    checkEqual(plain.paragraph.runs, [Run(text: "Hello", style: base)], "a single run takes the paragraph style")
    checkEqual(plain.report.approximations, [:], "a clean paragraph records no approximations")

    let twoRuns = map([P(PID.richUnicode, wz("Hello world")), P(PID.runIndex, u32List([5])),
                       P(PID.runFormatting, .objectIDs([boldFmt, italicFmt])), P(PID.paragraphStyle, .objectIDs([body]))])
    checkEqual(twoRuns.paragraph.runs.map(\.text), ["Hello", " world"], "TextRunIndex splits the text")
    checkEqual(twoRuns.paragraph.runs.map(\.style.bold), [true, false], "each run gets its own formatting")
    checkEqual(twoRuns.paragraph.runs.map(\.style.italic), [false, true], "…including italic")
    checkEqual(twoRuns.paragraph.runs.map(\.style.fontSize), [11, 11], "…on top of the paragraph style")

    let merged = map([P(PID.richUnicode, wz("abcdef")), P(PID.runIndex, u32List([3])),
                      P(PID.runFormatting, .objectIDs([boldFmt, boldFmt]))])
    checkEqual(merged.paragraph.runs.count, 1, "adjacent runs with identical style merge")
    checkEqual(merged.paragraph.runs[0].text, "abcdef", "…and keep all the text")

    let emoji = "a😀b"                                                            // UTF-16: a, D83D, DE00, b
    let split = map([P(PID.richUnicode, wz(emoji)), P(PID.runIndex, u32List([2])), P(PID.runFormatting, .objectIDs([boldFmt, italicFmt]))])
    checkEqual(split.paragraph.runs.map(\.text).joined(), emoji, "a run boundary inside a surrogate pair does not damage the text")
    checkEqual(split.report.approximations["invalidRunIndex"], 1, "…and the bad index is counted")
    let backwards = map([P(PID.richUnicode, wz("abcdef")), P(PID.runIndex, u32List([4, 2])), P(PID.runFormatting, .objectIDs([boldFmt, italicFmt, boldFmt]))])
    checkEqual(backwards.report.approximations["invalidRunIndex"], 1, "decreasing run indexes are invalid")
    let beyond = map([P(PID.richUnicode, wz("abc")), P(PID.runIndex, u32List([10])), P(PID.runFormatting, .objectIDs([boldFmt, italicFmt]))])
    checkEqual(beyond.paragraph.runs.map(\.text).joined(), "abc", "an index past the end is invalid, the text survives")
    checkEqual(beyond.report.approximations["invalidRunIndex"], 1, "…and is counted")

    var cyr = pg
    let cyrStyle = cyr.add(.paragraphStyle, [P(PID.charset, .u8(204))])
    let cyrRT = cyr.add(.richText, [P(PID.richAscii, asciiValue([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])), P(PID.paragraphStyle, .objectIDs([cyrStyle]))])
    var cyrReport = ImportReport()
    let cyrP = ParagraphMapper(graph: cyr.graph).paragraph(richText: cyr.object(cyrRT), indent: 0, list: .none, report: &cyrReport)
    checkEqual(cyrP.runs.map(\.text).joined(), "Привет", "the style's Charset decodes 8-bit text")
    let weird = map([P(PID.richAscii, asciiValue([0x41, 0xE9])), P(PID.paragraphStyle, .objectIDs([body]))])
    checkEqual(weird.report.approximations["charsetFallback"], nil, "no charset is ANSI, not a fallback")
    var odd = pg
    let oddStyle = odd.add(.paragraphStyle, [P(PID.charset, .u8(99))])
    let oddRT = odd.add(.richText, [P(PID.richAscii, asciiValue([0x41, 0xE9])), P(PID.paragraphStyle, .objectIDs([oddStyle]))])
    var oddReport = ImportReport()
    _ = ParagraphMapper(graph: odd.graph).paragraph(richText: odd.object(oddRT), indent: 0, list: .none, report: &oddReport)
    checkEqual(oddReport.approximations["charsetFallback"], 1, "an unknown charset is counted")

    let both = map([P(PID.richUnicode, wz("Uni")), P(PID.richAscii, asciiValue([0x41, 0x73, 0x63]))])
    checkEqual(both.paragraph.runs.map(\.text).joined(), "Uni", "Unicode text wins when both encodings are present")

    // headings: stored size = displayed size / heading scale, rounded to half points (Paragraph.headingScales)
    func heading(_ name: String, halfPoints: UInt16) -> Paragraph {
        var hx = pg
        let st = hx.add(.paragraphStyle, [P(PID.paragraphStyleId, wz(name)), P(PID.fontSize, .u16(halfPoints))])
        let rt = hx.add(.richText, [P(PID.richUnicode, wz("T")), P(PID.paragraphStyle, .objectIDs([st]))])
        var r = ImportReport()
        return ParagraphMapper(graph: hx.graph).paragraph(richText: hx.object(rt), indent: 0, list: .none, report: &r)
    }
    let h1 = heading("h1", halfPoints: 32), h2 = heading("h2", halfPoints: 28), h3 = heading("h3", halfPoints: 22)
    checkEqual(h1.heading, 1, "h1 is heading 1"); checkEqual(h1.runs[0].style.fontSize, 9, "16pt at scale 1.8 stores 9")
    checkEqual(h2.heading, 2, "h2 is heading 2"); checkEqual(h2.runs[0].style.fontSize, 10, "14pt at scale 1.4 stores 10")
    checkEqual(h3.heading, 3, "h3 is heading 3"); checkEqual(h3.runs[0].style.fontSize, 9, "11pt at scale 1.2 stores 9")
    var cx = pg
    let citeStyle = cx.add(.paragraphStyle, [P(PID.paragraphStyleId, wz("cite")), P(PID.italic, .bool(true))])
    let citeRT = cx.add(.richText, [P(PID.richUnicode, wz("Q")), P(PID.paragraphStyle, .objectIDs([citeStyle]))])
    var citeReport = ImportReport()
    let citeP = ParagraphMapper(graph: cx.graph).paragraph(richText: cx.object(citeRT), indent: 0, list: .none, report: &citeReport)
    checkEqual(citeP.heading, 0, "other named styles are not headings")
    checkEqual(citeP.runs[0].style.italic, true, "…but their explicit properties apply")
    checkEqual(citeReport.approximations["namedStyleFlattened"], 1, "…and the flattening is counted")
    checkEqual(plain.report.approximations["namedStyleFlattened"], nil, "the body style p is not counted")

    // alignment, indent, empty paragraphs
    func aligned(_ v: UInt8?) -> (Alignment, Int?) {
        let r = map([P(PID.richUnicode, wz("x"))] + (v.map { [P(PID.paragraphAlignment, .u8($0))] } ?? []))
        return (r.paragraph.alignment, r.report.approximations["unknownAlignment"])
    }
    checkEqual(aligned(nil).0, .left, "no alignment is left"); checkEqual(aligned(0).0, .left, "0 is left")
    checkEqual(aligned(1).0, .center, "1 is center"); checkEqual(aligned(2).0, .right, "2 is right")
    checkEqual(aligned(3).0, .left, "an unknown value is left"); checkEqual(aligned(3).1, 1, "…and counted")
    var ax = pg
    let rightStyle = ax.add(.paragraphStyle, [P(PID.paragraphAlignment, .u8(2))])
    let axRT = ax.add(.richText, [P(PID.richUnicode, wz("x")), P(PID.paragraphStyle, .objectIDs([rightStyle]))])
    var axReport = ImportReport()
    checkEqual(ParagraphMapper(graph: ax.graph).paragraph(richText: ax.object(axRT), indent: 0, list: .none, report: &axReport).alignment,
               .right, "alignment can come from the paragraph style")
    checkEqual(map([P(PID.richUnicode, wz("x"))], indent: 99).paragraph.indent, Paragraph.maxIndent, "indent is clamped")
    checkEqual(map([P(PID.richUnicode, wz("x"))], indent: 2, list: .numbered).paragraph.list, .numbered, "the list style is passed through")
    checkEqual(map([]).paragraph.runs, [], "a rich text node with no text is an empty paragraph")
    checkEqual(map([P(PID.richUnicode, wz(""))]).paragraph.runs, [], "empty text is an empty paragraph")
    let missingFormat = map([P(PID.richUnicode, wz("ab")), P(PID.runFormatting, .objectIDs([ExtendedGUID(guid: GUID(hi: 1, lo: 1), n: 1)]))])
    checkEqual(missingFormat.paragraph.runs.map(\.text), ["ab"], "a missing run-format object does not lose the text")

    // ignored properties are counted by ID, read ones are not
    let extra = map([P(PID.richUnicode, wz("x")), P(0x1400348B, .u32(1))])
    checkEqual(extra.report.ignoredProperties, ["0x1400348b": 1], "an unread property is counted by ID")
}
