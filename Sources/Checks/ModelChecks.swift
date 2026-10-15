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

    var d = History<Int>()
    d.discardLast()
    check(!d.canUndo, "discardLast on empty history is a no-op")
    d.record(1); d.record(2)
    d.discardLast()
    checkEqual(d.undo(current: 3), 1, "discardLast drops the newest snapshot")
    var d2 = History<Int>()
    d2.record(1); d2.record(2)
    _ = d2.undo(current: 3)                        // redo stack now non-empty
    d2.discardLast()
    check(d2.canRedo, "discardLast does not clear redo")

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
    objectChecks()
    folderChecks()
    pageColorChecks()
}

func objectChecks() {
    let img = ImageObject(id: UUID(), frame: Frame(x: 5, y: 6, width: 100, height: 50), asset: "a.png", altText: "alt")
    let cellP = [Paragraph(runs: [Run(text: "cell", style: RunStyle())])]
    let tbl = TableObject(id: UUID(), frame: Frame(x: 1, y: 2, width: 0, height: 0), columnWidths: [100, 50],
                          rows: [[TableCell(paragraphs: cellP), TableCell(paragraphs: [])],
                                 [TableCell(paragraphs: cellP), TableCell(paragraphs: cellP)]],
                          bordersVisible: true)
    let att = AttachmentObject(id: UUID(), frame: Frame(x: 9, y: 9, width: 60, height: 60), asset: "b.pdf", displayName: "Doc.pdf")
    let txt = box(0, 0, 100)
    var page = Page(id: UUID(), title: "t", objects: [.image(img), .table(tbl), .attachment(att), .text(txt)])

    let back = try! JSONDecoder().decode(Page.self, from: JSONEncoder().encode(page))
    checkEqual(back, page, "a page with every object kind round-trips through JSON")

    page.move(img.id, dx: 10, dy: -5)
    page.move(tbl.id, dx: 1, dy: 1)
    page.move(att.id, dx: -9, dy: -9)
    checkEqual(page.objects[0].frame, Frame(x: 15, y: 1, width: 100, height: 50), "move works on images")
    checkEqual(page.objects[1].frame.x, 2, "move works on tables")
    checkEqual(page.objects[2].frame, Frame(x: 0, y: 0, width: 60, height: 60), "move works on attachments")

    page.bringToFront(img.id)
    checkEqual(page.objects.last?.id, img.id, "bringToFront works on images")
    page.sendToBack(img.id)
    checkEqual(page.objects.first?.id, img.id, "sendToBack works on images")

    let beforeResize = page
    page.resize(img.id, width: 500)
    checkEqual(page, beforeResize, "resize still applies to text containers only")

    let start = Frame(x: 10, y: 20, width: 200, height: 100)
    checkEqual(Page.scaledImageFrame(start, corner: .bottomRight, dx: 100, dy: 10),
               Frame(x: 10, y: 20, width: 300, height: 150), "the corner that moves farther sets the scale")
    checkEqual(Page.scaledImageFrame(start, corner: .topLeft, dx: -100, dy: -10),
               Frame(x: -90, y: -30, width: 300, height: 150), "the opposite corner stays put")
    let tiny = Page.scaledImageFrame(start, corner: .bottomRight, dx: -190, dy: 0)
    checkEqual(tiny.width, 64, "an image cannot shrink below 32 on its short side")
    checkEqual(tiny.height, 32, "the short side is the minimum")
    page.setImageFrame(img.id, tiny)
    guard case .image(let resized)? = page.objects.first(where: { $0.id == img.id }) else { return }
    checkEqual(resized.frame, tiny, "setImageFrame updates an image")
    let beforeFrame = page
    page.setImageFrame(tbl.id, tiny)
    checkEqual(page, beforeFrame, "setImageFrame leaves a table alone")
    page.setImageFrame(img.id, Frame(x: 15, y: 1, width: 100, height: 50))

    var crowded = Page(id: UUID(), title: "t", objects: [
        .text(TextContainer(id: UUID(), frame: Frame(x: 40, y: 40, width: 200, height: 100), paragraphs: [])),
    ])
    let blocked = crowded.clearOrigin(width: 80, height: 60, nearX: 48, nearY: 48)
    checkEqual(blocked.x, 48, "a pasted image keeps its horizontal place")
    checkEqual(blocked.y, 156, "a pasted image drops below the box it would cover")
    let open = crowded.clearOrigin(width: 40, height: 40, nearX: 400, nearY: 400)
    checkEqual(open.x, 400, "a clear spot is used as-is")
    checkEqual(open.y, 400, "a clear spot keeps its vertical place")
    crowded.add(.text(TextContainer(id: UUID(), frame: Frame(x: 40, y: 156, width: 80, height: 40), paragraphs: [])))
    let lower = crowded.clearOrigin(width: 80, height: 60, nearX: 48, nearY: 48)
    checkEqual(lower.y, 212, "it steps past every box it would cover")

    // Table height and width are derived: FixedLineMeasurer gives 20 per paragraph, padding is 4 each side.
    checkEqual(tbl.rowHeights(using: FixedLineMeasurer()), [28, 28], "row height = max(minimum, tallest cell + padding)")
    page.relayout(using: FixedLineMeasurer())
    guard case .table(let laid)? = page.objects.first(where: { $0.id == tbl.id }) else { check(false, "table present"); return }
    checkEqual(laid.frame.width, 150, "table width is the sum of its column widths")
    checkEqual(laid.frame.height, 56, "table height is the sum of its row heights")
    guard case .image(let untouched)? = page.objects.first(where: { $0.id == img.id }) else { return }
    checkEqual(untouched.frame.height, 50, "relayout leaves image height alone")

    let dup = PageObject.image(img).duplicated(dx: 20, dy: 30)
    check(dup.id != img.id, "duplicate has a fresh id")
    checkEqual(dup.frame.x, 25, "duplicate is offset in x")
    checkEqual(dup.frame.y, 36, "duplicate is offset in y")

    let n1 = AssetName.make(ext: "PNG"), n2 = AssetName.make(ext: "../x")
    check(n1.hasSuffix(".png"), "extension is lower-cased: \(n1)")
    check(n2.hasSuffix(".x"), "path characters are stripped from the extension: \(n2)")
    check(AssetName.make(ext: "").hasSuffix(".bin"), "empty extension becomes bin")
    check(AssetName.make(ext: "!!!").hasSuffix(".bin"), "an extension with no letters or digits becomes bin")
    check(AssetName.make(ext: "abcdefghijkl").hasSuffix(".abcdefgh"), "extension is capped at 8 characters")
    check(n1 != AssetName.make(ext: "PNG"), "names are unique")

    checkEqual(Paragraph.headingScales, [1, 1.8, 1.4, 1.2], "heading scales live in PageModel")
}

func folderChecks() {
    let pageID = UUID(), sectionID = UUID()
    let old = """
    {"version":1,"name":"n","sections":[{"id":"\(sectionID.uuidString)","name":"S","pages":[{"id":"\(pageID.uuidString)","title":"Kept"}]}]}
    """
    let decoded = try! JSONDecoder().decode(Notebook.self, from: Data(old.utf8))
    checkEqual(decoded.sections[0].pages.map(\.title), ["Kept"], "a notebook saved before folders still lists its pages")

    var section = Section(id: UUID(), name: "S", pages: [PageRef(id: pageID, title: "Kept")])
    let work = section.addFolder(named: "Work", inFolder: nil)
    let nested = section.addFolder(named: "Later", inFolder: work)
    let moved = UUID()
    section.addPage(PageRef(id: moved, title: "Inside"), inFolder: work)
    checkEqual(section.pages.map(\.title), ["Kept", "Inside"], "pages inside folders stay in the flat list")
    check(section.move(id: moved, into: nested, at: 0), "a page can move into a subfolder")
    checkEqual(section.folder(nested)?.children.map(\.id), [moved], "the page landed in the subfolder")
    check(!section.move(id: work, into: nested, at: 0), "a folder cannot move into its own subfolder")
    check(section.folder(work)?.children.contains { $0.id == nested } == true, "the rejected move leaves the tree alone")
    check(section.move(id: nested, into: nil, at: 0), "a subfolder can move to the top of the section")
    checkEqual(section.items.first?.id, nested, "it is now the first item")
    check(section.dissolveFolder(work), "removing a folder keeps what was inside it")
    check(section.pages.contains { $0.id == moved }, "the page is still in the section")
    check(section.folder(work) == nil, "the folder itself is gone")

    let again = try! JSONDecoder().decode(Section.self, from: JSONEncoder().encode(section))
    checkEqual(again, section, "folders round-trip through JSON")
    checkEqual(again.pages.map(\.id), section.pages.map(\.id), "the flat page list is written beside the tree")

    let kept = PageRef(id: UUID(), title: "Kept")
    let plain = Folder(id: UUID(), name: "Work", children: [.page(kept)])
    var stripped = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
    stripped.removeValue(forKey: "colorHex")
    let uncolored = try! JSONDecoder().decode(Folder.self, from: JSONSerialization.data(withJSONObject: stripped))
    checkEqual(uncolored.colorHex, nil as String?, "a folder saved without a colour decodes")
    checkEqual(uncolored.children, [.page(kept)], "a missing colour leaves the page title")

    var colored = Section(id: UUID(), name: "S", items: [.folder(uncolored)])
    let titles = colored.pages.map(\.title)
    check(colored.setFolderColor(uncolored.id, to: "#A33B32"), "a folder can take a colour")
    let saved = try! JSONDecoder().decode(Section.self, from: JSONEncoder().encode(colored))
    checkEqual(saved.folder(uncolored.id)?.colorHex, "#A33B32", "a folder colour round-trips")
    checkEqual(saved.pages.map(\.title), titles, "a folder colour does not change page titles")
    checkEqual(titles, ["Kept"], "the page title is still Kept")
}

func pageColorChecks() {
    let pageID = UUID()
    let bare = """
    {"id":"\(pageID.uuidString)","title":"Kept"}
    """
    let decoded = try! JSONDecoder().decode(PageRef.self, from: Data(bare.utf8))
    checkEqual(decoded.colorHex, nil as String?, "a page saved without a colour decodes")
    checkEqual(decoded.title, "Kept", "a missing colour leaves the page title")

    let page = Page(id: pageID, title: "Kept", objects: [.text(box(0, 0, 120))])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let pageFile = try! encoder.encode(page)

    var section = Section(id: UUID(), name: "S", pages: [])
    let folder = section.addFolder(named: "Personal", inFolder: nil)
    section.addPage(decoded, inFolder: folder)
    check(section.setPageColor(pageID, to: "#3D7048"), "a page can take a colour")
    let saved = try! JSONDecoder().decode(Section.self, from: JSONEncoder().encode(section))
    checkEqual(saved.pages.first { $0.id == pageID }?.colorHex, "#3D7048", "a page colour round-trips")
    checkEqual(saved.pages.first { $0.id == pageID }?.title, "Kept", "a page colour does not change its title")
    checkEqual(try! encoder.encode(page), pageFile, "a page colour does not change the page file contents")

    check(section.setPageColor(pageID, to: nil), "default clears a page colour")
    let cleared = try! JSONDecoder().decode(Section.self, from: JSONEncoder().encode(section))
    checkEqual(cleared.pages.first { $0.id == pageID }?.colorHex, nil as String?, "a cleared page colour is absent")
    checkEqual(cleared.pages.first { $0.id == pageID }?.title, "Kept", "clearing a page colour leaves its title")
}
