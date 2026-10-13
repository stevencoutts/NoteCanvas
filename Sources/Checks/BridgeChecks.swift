import AppKit
import PageModel
import CanvasKit

private func run(_ text: String, _ tweak: (inout RunStyle) -> Void = { _ in }) -> Run {
    var s = RunStyle(); tweak(&s); return Run(text: text, style: s)
}

/// Mimics NSTextView typing: inserted text takes the attributes of the character before the caret
/// (the first character when the caret is at 0), filtered the way ContainerView filters typing attributes.
private func type(_ s: String, at loc: Int, in text: NSMutableAttributedString) {
    var attrs: [NSAttributedString.Key: Any] = [:]
    if text.length > 0 { attrs = text.attributes(at: max(loc - 1, 0), effectiveRange: nil) }
    text.insert(NSAttributedString(string: s, attributes: AttributedBridge.typingAttributes(attrs)), at: loc)
}

/// One PageController.textEdited cycle: parse the edited view text, re-render the model, carry the caret over.
private func normalise(_ text: NSAttributedString, caret: Int) -> (text: NSMutableAttributedString, caret: Int, paragraphs: [Paragraph]) {
    let ps = AttributedBridge.paragraphs(from: text)
    let sel = AttributedBridge.bodySelection(NSRange(location: caret, length: 0), in: text)
    let out = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: ps))
    return (out, AttributedBridge.range(of: sel, in: out).location, ps)
}

private func texts(_ ps: [Paragraph]) -> [String] { ps.map { $0.runs.map(\.text).joined() } }

private func listEditingChecks() {
    let bullets = [Paragraph(runs: [run("one")], list: .bullet), Paragraph(runs: [run("two")], list: .bullet)]

    // Return in the middle of a list: the new item gets a marker and the caret lands after it.
    var t = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: bullets))
    type("\n", at: 5, in: t)                                         // "•\tone|" + Return
    var n = normalise(t, caret: 6)
    checkEqual(texts(n.paragraphs), ["one", "", "two"], "Return mid-list splits into three items")
    checkEqual(n.paragraphs.map(\.list), [.bullet, .bullet, .bullet], "Return mid-list: new item is a bullet")
    checkEqual(n.text.string, "•\tone\n•\t\n•\ttwo", "Return mid-list renders a marker on the new item")
    checkEqual(n.caret, 8, "Return mid-list: caret lands after the new item's marker")
    type("x", at: n.caret, in: n.text)
    n = normalise(n.text, caret: n.caret + 1)
    checkEqual(texts(n.paragraphs), ["one", "x", "two"], "typing into the new mid-list item keeps the marker out of the text")
    checkEqual(n.text.string, "•\tone\n•\tx\n•\ttwo", "typing into the new mid-list item renders cleanly")
    checkEqual(n.caret, 9, "caret stays after the typed character")

    // Return at the end of a list, then type two characters.
    t = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: [bullets[0]]))
    type("\n", at: 5, in: t)
    n = normalise(t, caret: 6)
    type("t", at: n.caret, in: n.text)
    n = normalise(n.text, caret: n.caret + 1)
    checkEqual(n.paragraphs.map(\.list), [.bullet, .bullet], "Return at the end of a list starts a new bullet")
    checkEqual(n.text.string, "•\tone\n•\tt", "new last item renders its marker before the typed text")
    checkEqual(n.caret, 9, "caret after the first typed character, not inside the marker")
    type("w", at: n.caret, in: n.text)
    n = normalise(n.text, caret: n.caret + 1)
    checkEqual(texts(n.paragraphs), ["one", "tw"], "second keystroke on the new last item does not corrupt the marker")
    checkEqual(n.text.string, "•\tone\n•\ttw", "new last item renders cleanly after two keystrokes")

    // Return in the middle of a numbered list renumbers and places the caret after "2.\t".
    let numbered = [Paragraph(runs: [run("one")], list: .numbered), Paragraph(runs: [run("two")], list: .numbered)]
    t = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: numbered))
    type("\n", at: 6, in: t)                                         // "1.\tone|"
    n = normalise(t, caret: 7)
    checkEqual(n.text.string, "1.\tone\n2.\t\n3.\ttwo", "Return mid numbered list renumbers")
    checkEqual(n.caret, 10, "caret lands after the new number marker")

    // Partial marker deletion turns the paragraph into plain text without marker characters.
    func afterDeleting(_ r: NSRange, from ps: [Paragraph]) -> [Paragraph] {
        let m = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: ps))
        m.deleteCharacters(in: r)
        return AttributedBridge.paragraphs(from: m)
    }
    let foo = [Paragraph(runs: [run("foo")], list: .bullet)]
    var ps = afterDeleting(NSRange(location: 1, length: 1), from: foo)
    checkEqual(texts(ps), ["foo"], "deleting just the tab keeps the text clean")
    checkEqual(ps[0].list, ListStyle.none, "deleting just the tab removes the bullet")
    ps = afterDeleting(NSRange(location: 0, length: 1), from: foo)
    checkEqual(texts(ps), ["foo"], "deleting just the bullet keeps the text clean")
    checkEqual(ps[0].list, ListStyle.none, "deleting just the bullet removes the list")
    ps = afterDeleting(NSRange(location: 0, length: 2), from: foo)
    checkEqual(texts(ps), ["foo"], "deleting bullet+tab keeps the text")
    checkEqual(ps[0].list, ListStyle.bullet, "a whole missing marker is a list item still awaiting its marker")
    let ab = [Paragraph(runs: [run("a")], list: .numbered), Paragraph(runs: [run("b")], list: .numbered)]
    ps = afterDeleting(NSRange(location: 5, length: 1), from: ab)    // the "2" of "2.\tb"
    checkEqual(texts(ps), ["a", "b"], "deleting the number keeps the text clean")
    checkEqual(ps.map(\.list), [.numbered, .none], "deleting the number ends that item's numbering")
    ps = afterDeleting(NSRange(location: 5, length: 2), from: ab)    // "2."
    checkEqual(texts(ps), ["a", "b"], "deleting the number and dot keeps the text clean")
    checkEqual(ps[1].list, ListStyle.none, "deleting the number and dot ends that item's numbering")

    // Backspace at the start of an item's text (deletes the tab): bullet goes, caret stays at the text start.
    t = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: foo))
    t.deleteCharacters(in: NSRange(location: 1, length: 1))
    n = normalise(t, caret: 1)
    checkEqual(n.text.string, "foo", "Backspace at an item's text start removes the whole marker")
    checkEqual(n.caret, 0, "caret stays at the text start after the marker goes")

    // Forward-delete joining a plain line with a list item drops the marker characters.
    let joined = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from:
        [Paragraph(runs: [run("aa")]), Paragraph(runs: [run("bb")], list: .bullet)]))
    joined.deleteCharacters(in: NSRange(location: 2, length: 1))
    checkEqual(texts(AttributedBridge.paragraphs(from: joined)), ["aabb"], "joined lines keep no marker characters")

    // Marker characters never pass their identity to typed text.
    let markerAttrs = AttributedBridge.attributed(from: foo).attributes(at: 0, effectiveRange: nil)
    check(markerAttrs[NSAttributedString.Key("pm.marker")] != nil, "marker characters are tagged")
    check(AttributedBridge.typingAttributes(markerAttrs)[NSAttributedString.Key("pm.marker")] == nil,
          "typing attributes never carry the marker tag")

    // Selection <-> (paragraph, body offset) mapping as a pure function.
    let mixed = AttributedBridge.attributed(from: [Paragraph(runs: [run("aa")]), Paragraph(runs: [run("bb")], list: .bullet),
                                                   Paragraph(runs: [run("cc")], list: .numbered)])
    // "aa\n•\tbb\n1.\tcc"
    checkEqual(AttributedBridge.bodySelection(NSRange(location: 6, length: 0), in: mixed),
               BodySelection(start: BodyPosition(paragraph: 1, offset: 1), end: BodyPosition(paragraph: 1, offset: 1)),
               "caret inside a bullet item maps to its body offset")
    checkEqual(AttributedBridge.range(of: BodySelection(start: BodyPosition(paragraph: 2, offset: 0),
                                                        end: BodyPosition(paragraph: 2, offset: 0)), in: mixed),
               NSRange(location: 11, length: 0), "body offset 0 maps to just after the marker")
    let all = AttributedBridge.bodySelection(NSRange(location: 0, length: mixed.length), in: mixed)
    checkEqual(all, BodySelection(start: BodyPosition(paragraph: 0, offset: 0), end: BodyPosition(paragraph: 2, offset: 2)),
               "a multi-paragraph selection maps to its body ends")
    let allBullets = AttributedBridge.attributed(from: [Paragraph(runs: [run("aa")], list: .bullet),
                                                        Paragraph(runs: [run("bb")], list: .bullet),
                                                        Paragraph(runs: [run("cc")], list: .bullet)])
    let mapped = AttributedBridge.range(of: all, in: allBullets)          // "•\taa\n•\tbb\n•\tcc"
    checkEqual(mapped, NSRange(location: 2, length: allBullets.length - 2), "a multi-paragraph selection survives a re-render")
    checkEqual(AttributedBridge.paragraphRange(forSelection: mapped, in: allBullets.string), 0...2,
               "the re-rendered selection still spans all three paragraphs")
    let firstLine = AttributedBridge.bodySelection(NSRange(location: 0, length: 3), in: mixed)    // "aa\n"
    checkEqual(AttributedBridge.paragraphRange(forSelection: AttributedBridge.range(of: firstLine, in: allBullets),
                                               in: allBullets.string), 0...0,
               "a selection ending at the next line's start still excludes that line after a re-render")
}

func bridgeChecks() {
    // Full round trip: styles, unicode, headings, lists, alignment, indent, empty middle paragraph.
    let unicode = "👩‍👩‍👧 e\u{301} العربية"
    let paragraphs: [Paragraph] = [
        Paragraph(runs: [run("Title", { $0.bold = true; $0.fontSize = 20 })], heading: 1, alignment: .center),
        Paragraph(runs: [run("plain "), run("italic", { $0.italic = true }),
                         run(" and "), run("both", { $0.bold = true; $0.underline = true; $0.strike = true })]),
        Paragraph(runs: [run(unicode, { $0.colorHex = "#FF0000"; $0.highlightHex = "#FFFF00" })]),
        Paragraph(runs: [run("x"), run("2", { $0.script = .sup }), run("link", { $0.link = "https://example.com" })]),
        Paragraph(runs: []),                                                        // empty middle paragraph
        Paragraph(runs: [run("one")], list: .numbered),
        Paragraph(runs: [run("two")], list: .numbered),
        Paragraph(runs: [run("nested")], indent: 1, list: .numbered),
        Paragraph(runs: [run("three")], list: .numbered),
        Paragraph(runs: [run("bullet")], indent: 2, list: .bullet),
        Paragraph(runs: [run("right")], alignment: .right),
    ]
    let attributed = AttributedBridge.attributed(from: paragraphs)
    checkEqual(AttributedBridge.paragraphs(from: attributed), paragraphs, "paragraphs survive the NSAttributedString round trip")

    // List markers are literal text in the view, but never leak into run text.
    let s = attributed.string
    check(s.contains("1.\tone"), "first numbered item shows 1.")
    check(s.contains("2.\ttwo"), "second numbered item shows 2.")
    check(s.contains("1.\tnested"), "nested numbered list restarts at 1.")
    check(s.contains("3.\tthree"), "numbering resumes after a nested block")
    check(s.contains("•\tbullet"), "bullet marker present")
    check(!AttributedBridge.paragraphs(from: attributed).flatMap(\.runs).contains { $0.text.contains("\t") },
          "no marker text in runs")

    // Empty input, and a trailing empty paragraph.
    checkEqual(AttributedBridge.paragraphs(from: AttributedBridge.attributed(from: [])).count, 1,
               "an empty text view reads as one empty paragraph")
    let trailing = [Paragraph(runs: [run("a")]), Paragraph(runs: [])]
    checkEqual(AttributedBridge.paragraphs(from: AttributedBridge.attributed(from: trailing)), trailing,
               "trailing empty paragraph survives")

    // A list paragraph whose marker the user deleted keeps its text.
    let broken = NSMutableAttributedString(attributedString: AttributedBridge.attributed(from: [
        Paragraph(runs: [run("keep me")], list: .bullet)]))
    broken.deleteCharacters(in: NSRange(location: 0, length: 2))
    checkEqual(AttributedBridge.paragraphs(from: broken)[0].runs.map(\.text), ["keep me"], "deleted marker does not eat text")

    listEditingChecks()

    // Selection -> paragraph indices.
    let text = "aa\nbb\ncc"
    checkEqual(AttributedBridge.paragraphRange(forSelection: NSRange(location: 4, length: 0), in: text), 1...1, "caret in 2nd line")
    checkEqual(AttributedBridge.paragraphRange(forSelection: NSRange(location: 0, length: 8), in: text), 0...2, "select all spans all lines")
    checkEqual(AttributedBridge.paragraphRange(forSelection: NSRange(location: 0, length: 3), in: text), 0...0,
               "selecting a whole line including its newline does not include the next line")

    // Unicode survival at scalar level (stricter than String ==, which ignores canonical equivalence).
    let uni = "👩‍👩‍👧 e\u{301} العربية"
    let uniBack = AttributedBridge.paragraphs(from: AttributedBridge.attributed(from: [Paragraph(runs: [run(uni)])]))
    checkEqual(Array(uniBack.map { $0.runs.map(\.text).joined() }.joined().unicodeScalars), Array(uni.unicodeScalars),
               "unicode scalars survive the round trip")

    // Measurer.
    let m = TextKitMeasurer()
    let long = [Paragraph(runs: [run(String(repeating: "word ", count: 60))])]
    let narrowH = m.height(of: long, width: 120)
    let wideH = m.height(of: long, width: 600)
    check(narrowH > wideH * 2, "narrow container wraps to a much greater height (\(narrowH) vs \(wideH))")
    let single = [Paragraph(runs: [run("one line")])]
    let twoLines = [Paragraph(runs: [run("a")]), Paragraph(runs: [run("b")])]
    check(m.height(of: twoLines, width: 300) > m.height(of: single, width: 300), "more paragraphs are taller")
    // Literal bound: handleHeight 14 + 2*inset 12 + a ~13pt base line (Metrics is internal to CanvasKit).
    check(m.height(of: [], width: 300) >= 14 + 12 + 13, "empty container has room for one line (\(m.height(of: [], width: 300)))")
    let oneA = [Paragraph(runs: [run("a")])]
    let aThenEmpty = [Paragraph(runs: [run("a")]), Paragraph(runs: [])]
    check(m.height(of: aThenEmpty, width: 300) > m.height(of: oneA, width: 300), "trailing empty paragraph adds height")
    let tall = [Paragraph(runs: [run("Title", { $0.fontSize = 14 })], heading: 1)]
    check(m.height(of: tall, width: 300) > m.height(of: single, width: 300), "headings are taller than body text")

    // textHeight is the text alone; height adds the container chrome (handle strip, insets, grip).
    let tk = TextKitMeasurer()
    let sample = [Paragraph(runs: [run("some words to measure")])]
    checkEqual(tk.height(of: sample, width: 314), 26 + tk.textHeight(of: sample, width: 300),
               "height = chrome (14 + 2*6) + text laid out at width - 6 - 8")
    check(tk.textHeight(of: sample, width: 300) >= 13, "text height is at least one line")
    let words = [Paragraph(runs: [run(String(repeating: "word ", count: 40))])]
    check(tk.textHeight(of: words, width: 60) > tk.textHeight(of: words, width: 600) * 2, "a narrow table cell wraps and grows")
    let cellTable = TableObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 0, height: 0), columnWidths: [60, 400],
                                rows: [[TableCell(paragraphs: words), TableCell(paragraphs: [])]], bordersVisible: true)
    let heights = cellTable.rowHeights(using: tk)
    check(heights[0] > TableObject.minRowHeight * 2, "a row grows to fit its tallest cell")
    var tablePage = Page(id: UUID(), title: "t", objects: [.table(cellTable)])
    tablePage.relayout(using: tk)
    checkEqual(tablePage.objects[0].frame.height, heights[0], "relayout gives a table the same height drawing uses")
    checkEqual(tablePage.objects[0].frame.width, 460, "…and the sum of its column widths")
}
