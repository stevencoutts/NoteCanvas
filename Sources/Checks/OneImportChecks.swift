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

// ---- helpers that build page graphs ----

func richText(_ g: inout Gx, _ s: String, extra: [OneProperty] = []) -> ExtendedGUID {
    g.add(.richText, [P(PID.richUnicode, wz(s))] + extra)
}

func element(_ g: inout Gx, content: [ExtendedGUID], children: [ExtendedGUID] = [], list: ExtendedGUID? = nil) -> ExtendedGUID {
    var props = [P(PID.contentChildren, .objectIDs(content))]
    if !children.isEmpty { props.append(P(PID.elementChildren, .objectIDs(children))) }
    if let list { props.append(P(PID.listNodes, .objectIDs([list]))) }
    return g.add(.outlineElement, props)
}

func outline(_ g: inout Gx, x: Float?, y: Float?, width: Float? = nil, reserved: Float? = nil, elements: [ExtendedGUID]) -> ExtendedGUID {
    var props = [P(PID.elementChildren, .objectIDs(elements))]
    if let x { props.append(P(PID.offsetH, floatValue(x))) }
    if let y { props.append(P(PID.offsetV, floatValue(y))) }
    if let width { props.append(P(PID.maxWidth, floatValue(width))) }
    if let reserved { props.append(P(PID.reservedWidth, floatValue(reserved))) }
    return g.add(.outline, props)
}

func pageNode(_ g: inout Gx, _ children: [ExtendedGUID]) -> ExtendedGUID {
    g.add(.page, [P(PID.elementChildren, .objectIDs(children))])
}

func imageNode(_ g: inout Gx, container: ExtendedGUID?, width: Float? = 5, height: Float? = 1.5,
               x: Float? = nil, y: Float? = nil, alt: String? = nil) -> ExtendedGUID {
    var props: [OneProperty] = []
    if let container { props.append(P(PID.pictureContainer, .objectIDs([container]))) }
    if let width { props.append(P(PID.maxWidth, floatValue(width))) }
    if let height { props.append(P(PID.maxHeight, floatValue(height))) }
    if let x { props.append(P(PID.offsetH, floatValue(x))) }
    if let y { props.append(P(PID.offsetV, floatValue(y))) }
    if let alt { props.append(P(PID.imageAltText, wz(alt))) }
    return g.add(.image, props)
}

func pictureContainer(_ g: inout Gx) -> ExtendedGUID {
    g.add(JCID(0x0008_0039), [], fileData: FileDataReference(target: "<ifndf>{CCCCCCCC-1111-2222-3333-444444444444}", extensionText: ".png"))
}

/// A OneSource backed by an in-memory graph.
struct FakeSource: OneSource {
    var objectSpaces: [ObjectSpace]
    var warnings: [String] = []
    var files: [ExtendedGUID: Data] = [:]
    func fileData(for object: OneObject) -> (data: Data, ext: String)? {
        files[object.id].map { (data: $0, ext: fakeExtension(of: object)) }
    }
}

/// The lower-case extension a fake file object declares (".PNG" -> "png").
func fakeExtension(of object: OneObject) -> String {
    (object.fileData?.extensionText ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
}

func mapPageForTest(_ g: Gx, page: ExtendedGUID, files: [ExtendedGUID: Data] = [:]) -> (page: Page, report: ImportReport, assets: [ImportedAsset]) {
    let sink = AssetSink()
    let mapper = PageMapper(graph: g.graph, measurer: FixedLineMeasurer(),
                            assets: { obj in files[obj.id].map { (data: $0, ext: fakeExtension(of: obj)) } }, sink: sink)
    let result = mapper.mapPage(g.object(page))
    return (result, mapper.report, sink.items)
}

func columnWidths(_ units: [Float]) -> OneValue { .bytes(Data([UInt8(units.count)] + units.flatMap { le32($0.bitPattern) })) }

func oneImportLayoutChecks() {
    // ---- an outline is split around an image and stacked (flattening) ----
    do {
        var g = Gx()
        let t1 = richText(&g, "a"), t2 = richText(&g, "b"), t3 = richText(&g, "c")
        let pic = pictureContainer(&g)
        let img = imageNode(&g, container: pic, width: 5, height: 1.5, alt: "A picture")
        let e1 = element(&g, content: [t1]), e2 = element(&g, content: [t2]), e3 = element(&g, content: [img]), e4 = element(&g, content: [t3])
        let o = outline(&g, x: 1, y: 2, width: 10, elements: [e1, e2, e3, e4])
        let pg = pageNode(&g, [o])
        let r = mapPageForTest(g, page: pg, files: [pic: Data([1, 2, 3])])
        checkEqual(r.page.objects.count, 3, "an outline with an image becomes text, image, text")
        guard r.page.objects.count == 3, case .text(let first) = r.page.objects[0], case .image(let image) = r.page.objects[1],
              case .text(let last) = r.page.objects[2] else { check(false, "object kinds"); return }
        checkEqual(first.frame, Frame(x: 36, y: 72, width: 360, height: 40), "first text box at the outline's position (1 unit = 36 pt)")
        checkEqual(first.paragraphs.count, 2, "consecutive paragraphs share a box")
        checkEqual(image.frame, Frame(x: 36, y: 112, width: 180, height: 54), "the image is stacked below the first box")
        checkEqual(image.altText, "A picture", "alt text is kept")
        checkEqual(last.frame, Frame(x: 36, y: 166, width: 360, height: 20), "the next text box is stacked below the image")
        checkEqual(r.assets.count, 1, "one asset for the picture")
        checkEqual(r.assets.first?.data, Data([1, 2, 3]), "the asset holds the picture bytes")
        check(r.assets[0].name == image.asset && image.asset.hasSuffix(".png"), "the image refers to its asset by name")
        checkEqual(r.report.objectsImported["text"], 2, "two text boxes counted")
        checkEqual(r.report.objectsImported["image"], 1, "one image counted")
        checkEqual(r.report.objectsImported["paragraph"], 3, "three paragraphs counted")
    }

    // ---- nesting, lists, indentation ----
    do {
        var g = Gx()
        let t1 = richText(&g, "parent"), t2 = richText(&g, "child")
        let numbered = g.add(.numberList, [P(PID.numberListFormat, .bytes(Data([3, 0, 0xFD, 0xFF, 0x30, 0x00])))])
        let child = element(&g, content: [t2])
        let parent = element(&g, content: [t1], children: [child], list: numbered)
        let o = outline(&g, x: 0, y: 0, width: 10, elements: [parent])
        let pg = pageNode(&g, [o])
        let r = mapPageForTest(g, page: pg)
        guard case .text(let box)? = r.page.objects.first else { check(false, "one text box"); return }
        checkEqual(box.paragraphs.map(\.indent), [0, 1], "child elements are indented one level, after their parent")
        checkEqual(box.paragraphs.map(\.list), [.numbered, .none], "a NumberListNode makes its element a list item")
    }

    // ---- title, date lines, default title ----
    do {
        var g = Gx()
        let title = richText(&g, "My Title", extra: [P(PID.isTitleText, .bool(true))])
        let date = richText(&g, "Monday", extra: [P(PID.isTitleDate, .bool(true))])
        let time = richText(&g, "10:00", extra: [P(PID.isTitleTime, .bool(true))])
        let te = element(&g, content: [title, date, time])
        let titleOutline = outline(&g, x: nil, y: nil, elements: [te])
        let titleNode = g.add(.title, [P(PID.elementChildren, .objectIDs([titleOutline]))])
        let pg = pageNode(&g, [titleNode])
        let r = mapPageForTest(g, page: pg)
        checkEqual(r.page.title, "My Title", "the title text becomes the page title")
        checkEqual(r.page.objects.count, 0, "the title is not a text box")
        checkEqual(r.report.approximations["titleDateDropped"], 2, "date and time lines are dropped and counted")
        var g2 = Gx()
        let pg2 = pageNode(&g2, [])
        checkEqual(mapPageForTest(g2, page: pg2).page.title, "Untitled Page", "a page with no title is Untitled Page")
    }

    // ---- objects directly on the page: image, table, attachment ----
    do {
        var g = Gx()
        let pic = pictureContainer(&g), file = g.add(JCID(0x0008_0036), [], fileData: FileDataReference(target: "<ifndf>{DDDDDDDD-1111-2222-3333-444444444444}", extensionText: ".pdf"))
        let img = imageNode(&g, container: pic, width: 2, height: 1, x: 3, y: 4)
        let cellText = richText(&g, "cell")
        let cellEl = element(&g, content: [cellText])
        let cell1 = g.add(.tableCell, [P(PID.elementChildren, .objectIDs([cellEl]))])
        let cell2 = g.add(.tableCell, [])
        let row1 = g.add(.tableRow, [P(PID.elementChildren, .objectIDs([cell1, cell2]))])
        let row2 = g.add(.tableRow, [P(PID.elementChildren, .objectIDs([cell2, cell1]))])
        let tbl = g.add(.table, [P(PID.elementChildren, .objectIDs([row1, row2])), P(PID.tableColumnWidths, columnWidths([2, 1])),
                                 P(PID.tableBordersVisible, .bool(false)), P(PID.offsetH, floatValue(1)), P(PID.offsetV, floatValue(10))])
        let att = g.add(.embeddedFile, [P(PID.embeddedFileContainer, .objectIDs([file])), P(PID.embeddedFileName, wz("Doc.pdf")),
                                        P(PID.offsetH, floatValue(0.5)), P(PID.offsetV, floatValue(20))])
        let pg = pageNode(&g, [img, tbl, att])
        let r = mapPageForTest(g, page: pg, files: [pic: Data([9]), file: Data([8, 8])])
        checkEqual(r.page.objects.count, 3, "image, table and attachment all import")
        guard case .image(let i) = r.page.objects[0], case .table(let t) = r.page.objects[1], case .attachment(let a) = r.page.objects[2] else {
            check(false, "object kinds"); return
        }
        checkEqual(i.frame, Frame(x: 108, y: 144, width: 72, height: 36), "a page-level image uses its own offsets and size")
        checkEqual(t.columnWidths, [72, 36], "table column widths are in layout units (x 36 pt)")
        checkEqual(t.bordersVisible, false, "TableBordersVisible is kept")
        checkEqual(t.rows.count, 2, "two rows"); checkEqual(t.rows.map(\.count), [2, 2], "two cells per row")
        checkEqual(t.rows[0][0].paragraphs.first?.runs.first?.text, "cell", "cell text is mapped")
        checkEqual(t.rows[0][1].paragraphs, [], "an empty cell has no paragraphs")
        checkEqual(t.frame.x, 36, "table x from its offset"); checkEqual(t.frame.y, 360, "table y from its offset")
        checkEqual(t.frame.width, 108, "table width is the sum of its columns")
        checkEqual(t.frame.height, 56, "table height is derived from its rows (28 + 28)")
        checkEqual(a.displayName, "Doc.pdf", "the attachment keeps its file name"); checkEqual(a.asset.hasSuffix(".pdf"), true, "…and its extension")
        checkEqual(a.frame.x, 18, "attachment x from its offset")
        checkEqual(r.assets.count, 2, "picture and attachment data are both stored")
    }

    // ---- missing or odd things never abort the page ----
    do {
        var g = Gx()
        let noData = pictureContainer(&g)                              // no bytes for it in `files`
        let img = imageNode(&g, container: noData)
        let unknownInElement = g.add(JCID(0x0006_0014), [P(0x1400348B, .u32(1))])
        let e = element(&g, content: [img, unknownInElement])
        let o = outline(&g, x: 0, y: 0, width: 4, elements: [e])
        let unknownChild = g.add(JCID(0x0006_0014), [])
        let pg = pageNode(&g, [o, unknownChild])
        let r = mapPageForTest(g, page: pg)
        checkEqual(r.report.approximations["imageDataMissing"], 1, "an image with no data is skipped and counted")
        checkEqual(r.report.skippedObjectTypes["0x60014"], 2, "unknown object types are counted by JCID (once on the page, once in an element)")
        checkEqual(r.page.objects.count, 0, "nothing else was produced")
        let noImage = imageNode(&g, container: nil)
        let pg2 = pageNode(&g, [noImage])
        let r2 = mapPageForTest(g, page: pg2)
        checkEqual(r2.report.approximations["imageDataMissing"], 1, "an image with no picture container is counted too")
    }

    // ---- a reference loop terminates ----
    do {
        var g = Gx()
        let t = richText(&g, "x")
        let id = ExtendedGUID(guid: GUID(hi: 7, lo: 7), n: 99)
        g.objects[id] = OneObject(id: id, jcid: .outlineElement, properties: PropertySet([
            P(PID.contentChildren, .objectIDs([t])), P(PID.elementChildren, .objectIDs([id]))]), fileData: nil)    // lists itself
        let o = outline(&g, x: 0, y: 0, width: 4, elements: [id])
        let pg = pageNode(&g, [o])
        let r = mapPageForTest(g, page: pg)
        check((r.report.approximations["elementLoopOrTooDeep"] ?? 0) >= 1, "an element that lists itself is detected")
        checkEqual(r.page.objects.count, 1, "the rest of the page still maps")
    }

    // ---- outline width and position fallbacks ----
    do {
        var g = Gx()
        let x1 = richText(&g, "x"), x2 = richText(&g, "x")
        let e1 = element(&g, content: [x1]), e2 = element(&g, content: [x2])
        let o1 = outline(&g, x: nil, y: nil, elements: [e1])
        let o2 = outline(&g, x: 0, y: 0, reserved: 5, elements: [e2])
        let pg = pageNode(&g, [o1, o2])
        let r = mapPageForTest(g, page: pg)
        guard case .text(let a) = r.page.objects[0], case .text(let b) = r.page.objects[1] else { check(false, "two boxes"); return }
        checkEqual(a.frame.width, 432, "no width at all falls back to 432 pt")
        checkEqual(a.frame.x, 0, "a missing offset falls back to 0")
        checkEqual(r.report.approximations["outlineWithoutPosition"], 1, "…and is counted")
        checkEqual(b.frame.width, 180, "the reserved width is used when there is no maximum width")
    }

    // ---- the importer: revisions, page order, failures, cancel ----
    do {
        func space(_ n: UInt32, _ revisions: [Revision]) -> ObjectSpace {
            ObjectSpace(id: ExtendedGUID(guid: GUID(hi: 1, lo: 1), n: n), revisions: revisions)
        }
        func rev(_ n: UInt32, role: UInt32 = 1, root: ExtendedGUID, _ objects: [ExtendedGUID: OneObject]) -> Revision {
            Revision(id: ExtendedGUID(guid: GUID(hi: 2, lo: 2), n: n), dependent: nil, role: role, roots: [1: root], declared: objects)
        }
        /// A page whose only content is a title with the given text, wrapped in a PageManifest.
        func titledPage(_ title: String) -> (root: ExtendedGUID, objects: [ExtendedGUID: OneObject]) {
            var g = Gx()
            let t = richText(&g, title, extra: [P(PID.isTitleText, .bool(true))])
            let te = element(&g, content: [t])
            let to = outline(&g, x: nil, y: nil, elements: [te])
            let tn = g.add(.title, [P(PID.elementChildren, .objectIDs([to]))])
            let pg = pageNode(&g, [tn])
            let manifest = g.add(.pageManifest, [P(PID.contentChildren, .objectIDs([pg]))])
            return (manifest, g.objects)
        }
        // Each page needs distinct object IDs, so offset them per space.
        func shifted(_ page: (root: ExtendedGUID, objects: [ExtendedGUID: OneObject]), by k: UInt32)
            -> (root: ExtendedGUID, objects: [ExtendedGUID: OneObject]) {
            func s(_ id: ExtendedGUID) -> ExtendedGUID { ExtendedGUID(guid: id.guid, n: id.n + k) }
            func mapValue(_ v: OneValue) -> OneValue {
                switch v {
                case .objectIDs(let ids): return .objectIDs(ids.map(s))
                case .objectSpaceIDs(let ids): return .objectSpaceIDs(ids.map(s))
                default: return v
                }
            }
            var out: [ExtendedGUID: OneObject] = [:]
            for (id, o) in page.objects {
                out[s(id)] = OneObject(id: s(id), jcid: o.jcid,
                                       properties: PropertySet(o.properties.properties.map { OneProperty($0.id, mapValue($0.value)) }),
                                       fileData: o.fileData)
            }
            return (s(page.root), out)
        }
        let a = shifted(titledPage("Alpha"), by: 1000), b = shifted(titledPage("Beta"), by: 2000)
        let old = shifted(titledPage("Old"), by: 3000), new = shifted(titledPage("New"), by: 4000)
        let sA = space(1, [rev(1, root: a.root, a.objects)])
        let sB = space(2, [rev(2, root: b.root, b.objects)])
        // A space whose revisions are an old page, a newer page, and a later non-page revision.
        let versionRoot = ExtendedGUID(guid: GUID(hi: 5, lo: 5), n: 1)
        let versionObj = OneObject(id: versionRoot, jcid: JCID(0x0006_003C), properties: PropertySet(), fileData: nil)
        let sC = space(3, [rev(3, root: old.root, old.objects), rev(4, root: new.root, new.objects),
                           rev(5, role: 4, root: versionRoot, [versionRoot: versionObj])])
        let importer = OneImporter(measurer: FixedLineMeasurer())

        // No section object: pages keep file order; the missing order is counted.
        let plain = importer.importSection(from: FakeSource(objectSpaces: [sA, sB, sC]), name: "Sec")
        checkEqual(plain.pages.map(\.title), ["Alpha", "Beta", "New"], "the newest page revision wins; version revisions are ignored")
        checkEqual(plain.sectionName, "Sec", "the section name is passed through")
        checkEqual(plain.report.pagesTotal, 3, "pages counted"); checkEqual(plain.report.pagesImported, 3, "pages imported")
        checkEqual(plain.report.approximations["pageOrderUnknown"], 3, "with no section order, the page order is counted as unknown")

        // A section object lists the page spaces in display order.
        var sg = Gx()
        let series = sg.add(.pageSeries, [P(PID.childGraphSpaces, .objectSpaceIDs([sC.id, sA.id, sB.id]))])
        let secObj = sg.add(.section, [P(PID.elementChildren, .objectIDs([series]))])
        let sSection = space(0, [rev(0, root: secObj, sg.objects)])
        let ordered = importer.importSection(from: FakeSource(objectSpaces: [sSection, sA, sB, sC]), name: "Sec")
        checkEqual(ordered.pages.map(\.title), ["New", "Alpha", "Beta"], "the section's page series gives the display order")
        checkEqual(ordered.report.approximations["pageOrderUnknown"], nil, "a known order is not counted as unknown")

        // A page space with no PageNode fails alone.
        var bg = Gx()
        let emptyManifest = bg.add(.pageManifest, [P(PID.contentChildren, .objectIDs([]))])
        let sBad = space(6, [rev(6, root: emptyManifest, bg.objects)])
        let failing = importer.importSection(from: FakeSource(objectSpaces: [sA, sBad, sB]), name: "Sec")
        checkEqual(failing.pages.map(\.title), ["Alpha", "Beta"], "a page that cannot be resolved is skipped; the others import")
        checkEqual(failing.report.pagesFailed, 1, "…and counted as failed")
        checkEqual(failing.report.pagesTotal, 3, "…within the page total")

        // Section-only file.
        let only = importer.importSection(from: FakeSource(objectSpaces: [sSection]), name: "Empty")
        checkEqual(only.pages.count, 0, "a section with no pages imports no pages")
        checkEqual(only.report.pagesTotal, 0, "…and reports none")

        // Cancel: stops after the first page, flags it, and returns what it has.
        var calls = 0
        let cancelled = importer.importSection(from: FakeSource(objectSpaces: [sA, sB, sC]), name: "Sec", isCancelled: { calls += 1; return calls > 1 })
        checkEqual(cancelled.report.cancelled, true, "a cancelled import says so")
        checkEqual(cancelled.pages.count, 1, "…and stops after the page in progress")

        // Source warnings are carried (capped) into the report.
        let warned = importer.importSection(from: FakeSource(objectSpaces: [sA], warnings: ["w1", "w2"]), name: "Sec")
        checkEqual(warned.report.warnings, ["w1", "w2"], "source warnings reach the report")

        // The report is plain JSON and round-trips.
        let enc = try! JSONEncoder().encode(plain.report)
        checkEqual(try! JSONDecoder().decode(ImportReport.self, from: enc), plain.report, "the report round-trips through JSON")
    }

    // ---- the same picture used twice is stored once ----
    do {
        var g = Gx()
        let pic = pictureContainer(&g)
        let i1 = imageNode(&g, container: pic), i2 = imageNode(&g, container: pic, x: 1, y: 1)
        let e = element(&g, content: [i1])
        let o = outline(&g, x: 0, y: 0, width: 4, elements: [e])
        let pg = pageNode(&g, [o, i2])
        let r = mapPageForTest(g, page: pg, files: [pic: Data([5])])
        checkEqual(r.assets.count, 1, "a picture container used by two images is stored once")
        let names = r.page.objects.compactMap { obj -> String? in if case .image(let i) = obj { return i.asset }; return nil }
        checkEqual(names.count, 2, "both images import"); checkEqual(Set(names).count, 1, "…and share one asset")
    }
}

func corpusImportChecks() {
    guard let dir = ProcessInfo.processInfo.environment["ONE_CORPUS_DIR"],
          let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { return }
    var files = 0, imported = 0, pages = 0, failedPages = 0, images = 0, tables = 0, attachments = 0, textBoxes = 0
    var unknownOrder = 0
    let importer = OneImporter(measurer: FixedLineMeasurer())
    for case let url as URL in walker where url.pathExtension == "one" {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let file = try? OneFile(data: data) else { continue }
        files += 1
        let r = importer.importSection(from: file, name: "x")
        imported += 1
        pages += r.report.pagesImported; failedPages += r.report.pagesFailed
        images += r.report.objectsImported["image"] ?? 0
        tables += r.report.objectsImported["table"] ?? 0
        attachments += r.report.objectsImported["attachment"] ?? 0
        textBoxes += r.report.objectsImported["text"] ?? 0
        if r.report.approximations["pageOrderUnknown"] != nil { unknownOrder += 1 }
    }
    print("corpus import: files=\(files) pagesImported=\(pages) pagesFailed=\(failedPages) textBoxes=\(textBoxes) images=\(images) tables=\(tables) attachments=\(attachments) filesWithUnknownPageOrder=\(unknownOrder)")
    check(failedPages == 0, "no corpus page fails to resolve")
}

func oneImportStyleLossChecks() {
    let unknownID: PropertyID = 0x1400AAAA
    var g = Gx()
    let style = g.add(.paragraphStyle, [P(PID.bold, .bool(true)), P(unknownID, .u32(1))])
    let fmt = g.add(.paragraphStyle, [P(PID.italic, .bool(true)), P(0x1400BBBB, .u32(2))])
    let t1 = richText(&g, "a", extra: [P(PID.paragraphStyle, .objectIDs([style])), P(PID.runFormatting, .objectIDs([fmt]))])
    let t2 = richText(&g, "b", extra: [P(PID.paragraphStyle, .objectIDs([style]))])
    let e = element(&g, content: [t1, t2])
    let o = outline(&g, x: 0, y: 0, width: 4, elements: [e])
    let pg = pageNode(&g, [o])
    let r = mapPageForTest(g, page: pg)
    checkEqual(r.report.ignoredProperties["0x1400aaaa"], 1, "an unread paragraph-style property is counted once per style object per page")
    checkEqual(r.report.ignoredProperties["0x1400bbbb"], 1, "an unread run-format property is counted")
    check(r.report.ignoredProperties["0x" + String(PID.bold, radix: 16)] == nil, "a read style property is not counted")

    var g2 = Gx()
    let tstyle = g2.add(.paragraphStyle, [P(unknownID, .u32(1))])
    let title = richText(&g2, "T", extra: [P(PID.isTitleText, .bool(true)), P(PID.paragraphStyle, .objectIDs([tstyle]))])
    let te = element(&g2, content: [title])
    let to = outline(&g2, x: nil, y: nil, elements: [te])
    let tn = g2.add(.title, [P(PID.elementChildren, .objectIDs([to]))])
    let pg2 = pageNode(&g2, [tn])
    let r2 = mapPageForTest(g2, page: pg2)
    checkEqual(r2.report.ignoredProperties.count, 0, "unread properties noted while mapping the title do not reach the report")
}

func oneImportHostileLayoutChecks() {
    func inRange(_ f: Frame) -> Bool {
        [f.x, f.y, f.width, f.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
    }
    for bad in [Float.nan, .infinity, -.infinity, 1e30] {
        var g = Gx()
        // outline with hostile position and width
        let t = richText(&g, "x")
        let el = element(&g, content: [t])
        let o = outline(&g, x: bad, y: bad, width: bad, reserved: bad, elements: [el])
        // inline image with hostile size and position
        let pic = pictureContainer(&g)
        let img = imageNode(&g, container: pic, width: bad, height: bad, x: bad, y: bad)
        // table with hostile column widths and offsets
        let cell = g.add(.tableCell, [])
        let row = g.add(.tableRow, [P(PID.elementChildren, .objectIDs([cell, cell]))])
        let tbl = g.add(.table, [P(PID.elementChildren, .objectIDs([row])),
                                 P(PID.tableColumnWidths, columnWidths([bad, bad])),
                                 P(PID.offsetH, floatValue(bad)), P(PID.offsetV, floatValue(bad))])
        // attachment with hostile offsets
        let file = g.add(JCID(0x0008_0036), [], fileData: FileDataReference(target: "<ifndf>{DDDDDDDD-1111-2222-3333-444444444444}", extensionText: ".pdf"))
        let att = g.add(.embeddedFile, [P(PID.embeddedFileContainer, .objectIDs([file])), P(PID.embeddedFileName, wz("A.pdf")),
                                        P(PID.offsetH, floatValue(bad)), P(PID.offsetV, floatValue(bad))])
        let pg = pageNode(&g, [o, img, tbl, att])
        let r = mapPageForTest(g, page: pg, files: [pic: Data([1]), file: Data([2])])
        let label = "(\(bad))"
        checkEqual(r.page.objects.count, 4, "hostile layout floats never drop objects \(label)")
        check(r.page.objects.allSatisfy { inRange($0.frame) }, "every frame is finite and in range \(label)")
        check((r.report.approximations["invalidLayoutValue"] ?? 0) >= 4, "invalid layout values are counted \(label)")
        if case .text(let box) = r.page.objects[0] {
            checkEqual(box.frame.width, 432, "an outline with an invalid width falls back to 432 \(label)")
            checkEqual(box.frame.x, 0, "an invalid offset falls back to 0 \(label)")
        } else { check(false, "first object is text \(label)") }
        if case .image(let i) = r.page.objects[1] { checkEqual(i.frame.width, 100, "an invalid image size falls back to 100 \(label)") }
        if case .table(let t) = r.page.objects[2] { checkEqual(t.columnWidths, [100, 100], "invalid column widths fall back to 100 \(label)") }
        check((try? JSONEncoder().encode(r.page)) != nil, "the page encodes as JSON \(label)")
    }

    // A style object shared by the title and the body is counted once, in the real report.
    var g = Gx()
    let style = g.add(.paragraphStyle, [P(PID.bold, .bool(true)), P(0x1400CCCC, .u32(1))])
    let title = richText(&g, "T", extra: [P(PID.isTitleText, .bool(true)), P(PID.paragraphStyle, .objectIDs([style]))])
    let te = element(&g, content: [title])
    let to = outline(&g, x: nil, y: nil, elements: [te])
    let tn = g.add(.title, [P(PID.elementChildren, .objectIDs([to]))])
    let body = richText(&g, "b", extra: [P(PID.paragraphStyle, .objectIDs([style]))])
    let be = element(&g, content: [body])
    let bo = outline(&g, x: 0, y: 0, width: 4, elements: [be])
    let pg = pageNode(&g, [tn, bo])
    let r = mapPageForTest(g, page: pg)
    checkEqual(r.report.ignoredProperties["0x1400cccc"], 1, "a style shared by title and body is counted once")
}
