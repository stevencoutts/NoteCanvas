import AppKit
import PageModel
import CanvasKit

private func run(_ text: String, _ tweak: (inout RunStyle) -> Void = { _ in }) -> Run {
    var s = RunStyle(); tweak(&s); return Run(text: text, style: s)
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
}
