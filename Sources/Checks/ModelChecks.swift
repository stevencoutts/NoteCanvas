import Foundation
import PageModel

func box(_ x: Double, _ y: Double, _ w: Double, lines: Int = 1) -> TextContainer {
    let paragraphs = (0..<lines).map { _ in Paragraph(runs: [Run(text: "line", style: RunStyle())]) }
    return TextContainer(id: UUID(), frame: Frame(x: x, y: y, width: w, height: 0), paragraphs: paragraphs)
}

func textTypeChecks() {
    var style = RunStyle()
    style.bold = true
    style.colorHex = "#FF0000"
    style.script = .sup
    style.link = "https://example.com"
    // emoji ZWJ sequence, combining accent, right-to-left script
    let unicode = "👩‍👩‍👧 e\u{301} العربية"
    let p = Paragraph(
        runs: [Run(text: unicode, style: style), Run(text: " plain", style: RunStyle())],
        indent: 2, heading: 1, list: .numbered, alignment: .center)
    let c = TextContainer(id: UUID(), frame: Frame(x: -50, y: 10, width: 300, height: 0), paragraphs: [p])
    let back = try! JSONDecoder().decode(TextContainer.self, from: JSONEncoder().encode(c))
    checkEqual(back, c, "container with unicode and negative x round-trips through JSON")
    checkEqual(back.paragraphs[0].runs[0].text, unicode, "unicode text unchanged")

    let empty = TextContainer(id: UUID(), frame: Frame(x: 0, y: 0, width: 100, height: 0), paragraphs: [])
    let emptyBack = try! JSONDecoder().decode(TextContainer.self, from: JSONEncoder().encode(empty))
    checkEqual(emptyBack, empty, "empty container round-trips")

    var q = Paragraph(runs: [], indent: 99, heading: 7)
    q.clamp()
    checkEqual(q.indent, Paragraph.maxIndent, "indent clamps high")
    checkEqual(q.heading, 3, "heading clamps high")
    var r = Paragraph(runs: [], indent: -4, heading: -1)
    r.clamp()
    checkEqual(r.indent, 0, "indent clamps low")
    checkEqual(r.heading, 0, "heading clamps low")
}

func modelChecks() {
    textTypeChecks()
}
