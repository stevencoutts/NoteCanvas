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

struct FixedLineMeasurer: TextMeasuring {
    func height(of paragraphs: [Paragraph], width: Double) -> Double { Double(paragraphs.count) * 20 }
}

func pageOpChecks() {
    var page = Page(id: UUID(), title: "t", objects: [])
    let a = box(10, 20, 200, lines: 3)
    let b = box(50, 60, 100)
    page.add(.text(a)); page.add(.text(b))
    checkEqual(page.objects.map(\.id), [a.id, b.id], "add keeps insertion order as z-order")

    page.bringToFront(a.id)
    checkEqual(page.objects.map(\.id), [b.id, a.id], "bringToFront moves to end")
    page.sendToBack(a.id)
    checkEqual(page.objects.map(\.id), [a.id, b.id], "sendToBack moves to start")

    page.move(a.id, dx: -100, dy: -100)
    guard case .text(let moved) = page.objects[0] else { check(false, "first object is text"); return }
    checkEqual(moved.frame.x, -90, "move allows negative x")
    checkEqual(moved.frame.y, -80, "move allows negative y")

    page.resize(a.id, width: 5)
    page.updateText(a.id) { _ in }
    guard case .text(let narrow) = page.objects[0] else { return }
    checkEqual(narrow.frame.width, Page.minContainerWidth, "resize below minimum clamps")
    page.resize(a.id, width: -30)
    guard case .text(let neg) = page.objects[0] else { return }
    checkEqual(neg.frame.width, Page.minContainerWidth, "negative width clamps")
    page.resize(a.id, width: 300)
    guard case .text(let wide) = page.objects[0] else { return }
    checkEqual(wide.frame.width, 300, "resize accepts a normal width")

    let before = page
    page.move(UUID(), dx: 1, dy: 1)
    page.resize(UUID(), width: 10)
    page.bringToFront(UUID())
    page.delete(UUID())
    checkEqual(page, before, "operations on an unknown id are no-ops")

    page.relayout(using: FixedLineMeasurer())
    guard case .text(let laid) = page.objects[0] else { return }
    checkEqual(laid.frame.height, 60, "height derives from content (3 lines x 20)")

    let empty = TextContainer(id: UUID(), frame: Frame(x: 0, y: 0, width: 100, height: 0), paragraphs: [])
    page.add(.text(empty))
    page.relayout(using: FixedLineMeasurer())
    guard case .text(let e) = page.objects[2] else { return }
    checkEqual(e.frame.height, Page.minContainerHeight, "empty container keeps a minimum height")

    page.editParagraphs(a.id, in: 0...1) { $0.indent = 99; $0.heading = 9 }
    guard case .text(let edited) = page.objects[0] else { return }
    checkEqual(edited.paragraphs[0].indent, Paragraph.maxIndent, "editParagraphs clamps indent")
    checkEqual(edited.paragraphs[1].heading, 3, "editParagraphs clamps heading")
    checkEqual(edited.paragraphs[2].indent, 0, "paragraph outside range untouched")
    page.editParagraphs(a.id, in: 5...9) { $0.indent = 1 }      // out of range: no crash
    page.editParagraphs(empty.id, in: 0...0) { $0.indent = 1 }  // no paragraphs: no crash

    page.delete(a.id)
    checkEqual(page.objects.count, 2, "delete removes the object")
}

func historyChecks() {
    var h = History<Int>()
    checkEqual(h.undo(current: 5), nil, "undo with nothing recorded is a no-op")
    check(!h.canUndo && !h.canRedo, "fresh history cannot undo or redo")

    h.record(1); h.record(2)                       // states 1, 2 existed before current 3
    checkEqual(h.undo(current: 3), 2, "undo returns most recent snapshot")
    checkEqual(h.undo(current: 2), 1, "undo again")
    checkEqual(h.undo(current: 1), nil, "undo past the start is a no-op")
    checkEqual(h.redo(current: 1), 2, "redo returns what was undone")
    checkEqual(h.redo(current: 2), 3, "redo again")
    checkEqual(h.redo(current: 3), nil, "redo past the end is a no-op")

    _ = h.undo(current: 3)
    h.record(9)
    check(!h.canRedo, "a new edit clears redo")

    var capped = History<Int>(limit: 3)
    for i in 0..<10 { capped.record(i) }
    var seen: [Int] = []
    var cur = 10
    while let prev = capped.undo(current: cur) { seen.append(prev); cur = prev }
    checkEqual(seen, [9, 8, 7], "history keeps only the newest `limit` snapshots")
}

func modelChecks() {
    textTypeChecks()
    pageOpChecks()
    historyChecks()
}
