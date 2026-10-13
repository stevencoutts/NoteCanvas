# Milestone 2: `.one` reader and importer: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `File > Import .one…` copies a OneNote section file's pages (text, images, tables, attachments) into a new section of the open notebook, as editable content in our own page model, with a counts-only loss report.

**Architecture:** Two new pure-Swift targets. `OneStore` reads the MS-ONESTORE revision-store format faithfully (honouring the transaction log, keeping unknown objects and properties). `OneImport` maps an object graph into `PageModel` and produces an `ImportResult` plus loss report. `PageModel`/`Store`/`CanvasKit` are extended with image, table and attachment objects, assets, sections, and the Import menu.

**Tech Stack:** Swift 6.4 toolchain in Swift 5 language mode, Foundation, AppKit, SwiftPM, macOS 14+. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-13-onestore-reader-design.md` (parent: `2026-10-13-onenote-clone-design.md`). Evidence and format facts: `docs/superpowers/spikes/2026-10-13-onestore-reader-spike.md`.

## Global Constraints

- Swift + AppKit, macOS 14+, SwiftPM only; `swiftLanguageModes: [.v5]`. This machine has the Command Line Tools and no Xcode. `swift test` is unusable here: tests are the `Checks` executable run with `swift run Checks`, using `check`, `checkEqual`, `checkThrows` from `Sources/Checks/Check.swift`. (`ld: warning: search path … CommandLineTools … not found` lines are harmless noise.)
- Checks may use `@testable import OneStore` / `@testable import OneImport` (debug builds enable testing). If `@testable` fails to resolve internal symbols, make just those symbols `public` and say so in the report.
- Layout values in `.one` files are floats in **half-inch units: 1 unit = 36 pt**. `FontSize` is in half-points. Colours are `COLORREF` `0x00BBGGRR`; `0xFF000000` means automatic.
- Reading is **never** fatal on unknown object types (JCIDs) or unknown property IDs; they are kept (OneStore) or counted (OneImport). All reads are bounds-checked: malformed input yields `OneStoreError`, never a trap, hang or unbounded allocation.
- The source `.one` file is read-only: never opened for writing, never modified.
- **No private data in the repo:** no real `.one` files, note text, titles or file names in code, tests, fixtures, logs, reports or commit messages. The only real-file check is opt-in via the `ONE_CORPUS_DIR` environment variable and prints aggregate counts only.
- Page model: unbounded canvas, z-order = array order, text containers resize width only and derive height; images, tables and attachments are first-class objects (move, delete, copy/paste, z-order) whose contents are read-only until milestone 3.
- Notebook package: `notebook.json`, `pages/<uuid>.json`, `assets/<name>`, `imports/<section-id>.json`; all writes atomic; the notebook version stays 1; write order for an import is assets, pages, report, manifest last.
- Commit messages end with these two trailer lines (give each as its own `-m` argument): `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s`.
- Do not commit `findings.md`, `.build/` or `.superpowers/`.

## Review Focus

Conditions the spec implies but no single task obviously owns. Each has a check in the task that owns the code.

1. **Hostile or damaged input never traps or hangs:** every fixture truncated at every length, and with single-byte corruption at every position, returns a result or a typed `OneStoreError`. (Tasks 2, 3)
2. **One bad page does not abort the import:** an unresolvable page is counted and skipped; the others import. Loops in object references (an element that lists its own ancestor) terminate. (Task 5)
3. **Empty and missing things:** section-only file (no pages), page with no outlines, empty paragraphs, empty table cells, an image whose data is missing, a title with no text. (Tasks 4, 5)
4. **Cancel and failure write nothing to the notebook:** no section, no pages; a failed page write leaves the manifest unchanged. (Tasks 1, 6)
5. **Text correctness:** UTF-16 text with surrogate pairs, run boundaries that would split a surrogate pair, 8-bit text decoded with its charset or the documented fallback. (Task 4)

---

## File Structure

```
Package.swift                              (modify: add OneStore, OneImport targets)
Sources/PageModel/Objects.swift            ImageObject, TableCell, TableObject, AttachmentObject, AssetName
Sources/PageModel/Page.swift               (modify) PageObject cases, frame, duplicated, relayout for tables, TextMeasuring.textHeight
Sources/PageModel/Text.swift               (modify) Paragraph.headingScales
Sources/Store/NotebookPackage.swift        (modify) assets, addSection
Sources/OneStore/OneStoreError.swift       typed errors
Sources/OneStore/ByteReader.swift          bounds-checked little-endian reads
Sources/OneStore/Ids.swift                 GUID, ExtendedGUID
Sources/OneStore/FileStructure.swift       ChunkRef, header, file node, transaction log, node-list reader, OpenedStore
Sources/OneStore/Properties.swift          PropertyID, OneValue, OneProperty, PropertySet, JCID
Sources/OneStore/ObjectBlob.swift          reads an ObjectSpaceObjectPropSet
Sources/OneStore/OneFile.swift             OneObject, Revision, ObjectSpace, OneSource, OneFile, StoreBuilder
Sources/OneImport/ImportReport.swift       counts-only loss report
Sources/OneImport/PropertyIDs.swift        PID constants
Sources/OneImport/ObjectGraph.swift        id → object lookup, child resolution
Sources/OneImport/Charset.swift            8-bit text decoding, COLORREF
Sources/OneImport/TextMapping.swift        StyleMapper, ParagraphMapper
Sources/OneImport/PageMapper.swift         outlines, flattening, images, tables, attachments, title
Sources/OneImport/OneImporter.swift        page selection and ordering, ImportResult
Sources/CanvasKit/TextKitMeasurer.swift    (modify) textHeight
Sources/CanvasKit/ObjectView.swift         views for image, table, attachment objects
Sources/CanvasKit/PageView.swift           (modify) hosts ObjectViews
Sources/CanvasKit/PageController.swift     (modify) object wiring, generic copy/paste, asset provider
Sources/CanvasKit/ImportRunner.swift       background import, cancel flag, main-thread measurer
Sources/CanvasKit/AppShell.swift           (modify) Import menu, section picker, progress sheet, summary
Sources/CanvasKit/AttributedBridge.swift   (modify) use Paragraph.headingScales
Sources/Checks/…                           check files per task
```

---

### Task 1: Model and Store additions

**Files:**
- Create: `Sources/PageModel/Objects.swift`
- Modify: `Sources/PageModel/Page.swift`, `Sources/PageModel/Text.swift`, `Sources/Store/NotebookPackage.swift`, `Sources/CanvasKit/AttributedBridge.swift`, `Sources/Checks/ModelChecks.swift`, `Sources/Checks/StoreChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Produces:
  - `ImageObject(id:frame:asset:altText:)`, `TableCell(paragraphs:)`, `TableObject(id:frame:columnWidths:rows:bordersVisible:)` with `static cellPadding = 4.0`, `static minRowHeight = 20.0`, `func rowHeights(using: TextMeasuring) -> [Double]`; `AttachmentObject(id:frame:asset:displayName:)`; `AssetName.make(ext:) -> String`.
  - `PageObject` cases `.image`, `.table`, `.attachment`; `PageObject.frame { get set }`; `PageObject.duplicated(dx:dy:) -> PageObject`; `Page.updateObject(_:_:)`.
  - `TextMeasuring.textHeight(of:width:)` (default = `height(of:width:)`).
  - `Paragraph.headingScales: [Double] = [1, 1.8, 1.4, 1.2]`.
  - `NotebookPackage.addAsset(data:ext:) -> String`, `writeAsset(name:data:)`, `loadAsset(_:) -> Data?`, `addSection(name:pages:report:) -> Section`.

- [ ] **Step 1: Write the failing model checks.** In `Sources/Checks/ModelChecks.swift` add this function and call `objectChecks()` from `modelChecks()`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`cannot find 'ImageObject' in scope`).

- [ ] **Step 3: Create `Sources/PageModel/Objects.swift`.**

```swift
import Foundation

public struct ImageObject: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var asset: String            // file name inside the notebook's assets/ folder
    public var altText: String?
    public init(id: UUID, frame: Frame, asset: String, altText: String? = nil) {
        self.id = id; self.frame = frame; self.asset = asset; self.altText = altText
    }
}

public struct TableCell: Codable, Equatable, Sendable {
    public var paragraphs: [Paragraph]
    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }
}

public struct TableObject: Codable, Equatable, Sendable {
    public static let cellPadding = 4.0
    public static let minRowHeight = 20.0

    public var id: UUID
    public var frame: Frame             // width = sum of columnWidths and height = sum of row heights, both derived
    public var columnWidths: [Double]
    public var rows: [[TableCell]]
    public var bordersVisible: Bool

    public init(id: UUID, frame: Frame, columnWidths: [Double], rows: [[TableCell]], bordersVisible: Bool) {
        self.id = id; self.frame = frame; self.columnWidths = columnWidths; self.rows = rows
        self.bordersVisible = bordersVisible
    }

    /// Row heights derived from cell content; layout and drawing both use this so they agree.
    public func rowHeights(using measurer: TextMeasuring) -> [Double] {
        rows.map { row in
            var h = TableObject.minRowHeight
            for (c, cell) in row.enumerated() {
                let w = c < columnWidths.count ? columnWidths[c] : 0
                let text = measurer.textHeight(of: cell.paragraphs, width: max(w - 2 * TableObject.cellPadding, 1))
                h = max(h, text + 2 * TableObject.cellPadding)
            }
            return h
        }
    }
}

public struct AttachmentObject: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var asset: String
    public var displayName: String
    public init(id: UUID, frame: Frame, asset: String, displayName: String) {
        self.id = id; self.frame = frame; self.asset = asset; self.displayName = displayName
    }
}

public enum AssetName {
    /// A fresh unique asset file name. `ext` is reduced to at most 8 lower-case ASCII letters/digits, else "bin".
    public static func make(ext: String) -> String {
        let clean = String(ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return "\(UUID().uuidString).\(clean.isEmpty ? "bin" : clean)"
    }
}
```

- [ ] **Step 4: Replace `Sources/PageModel/Page.swift` with:**

```swift
import Foundation

public protocol TextMeasuring {
    /// Height of a text container (the text plus the container's own chrome) at `width`.
    func height(of paragraphs: [Paragraph], width: Double) -> Double
    /// Height of the text alone at `width`, without container chrome; used for table cells.
    func textHeight(of paragraphs: [Paragraph], width: Double) -> Double
}

public extension TextMeasuring {
    func textHeight(of paragraphs: [Paragraph], width: Double) -> Double { height(of: paragraphs, width: width) }
}

public enum PageObject: Codable, Equatable, Sendable {
    case text(TextContainer)
    case image(ImageObject)
    case table(TableObject)
    case attachment(AttachmentObject)

    public var id: UUID {
        switch self {
        case .text(let t): return t.id
        case .image(let i): return i.id
        case .table(let t): return t.id
        case .attachment(let a): return a.id
        }
    }

    public var frame: Frame {
        get {
            switch self {
            case .text(let t): return t.frame
            case .image(let i): return i.frame
            case .table(let t): return t.frame
            case .attachment(let a): return a.frame
            }
        }
        set {
            switch self {
            case .text(var t): t.frame = newValue; self = .text(t)
            case .image(var i): i.frame = newValue; self = .image(i)
            case .table(var t): t.frame = newValue; self = .table(t)
            case .attachment(var a): a.frame = newValue; self = .attachment(a)
            }
        }
    }

    /// A copy with a fresh id, moved by (dx, dy); used by paste.
    public func duplicated(dx: Double, dy: Double) -> PageObject {
        var copy: PageObject
        switch self {
        case .text(var t): t.id = UUID(); copy = .text(t)
        case .image(var i): i.id = UUID(); copy = .image(i)
        case .table(var t): t.id = UUID(); copy = .table(t)
        case .attachment(var a): a.id = UUID(); copy = .attachment(a)
        }
        copy.frame.x += dx
        copy.frame.y += dy
        return copy
    }
}

public struct Page: Codable, Equatable, Sendable {
    public static let minContainerWidth = 40.0
    public static let minContainerHeight = 20.0

    public var id: UUID
    public var title: String
    public var objects: [PageObject]   // array order is z-order, last is on top

    public init(id: UUID, title: String, objects: [PageObject]) {
        self.id = id; self.title = title; self.objects = objects
    }

    private func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }

    public mutating func add(_ object: PageObject) { objects.append(object) }
    public mutating func delete(_ id: UUID) { objects.removeAll { $0.id == id } }

    public mutating func bringToFront(_ id: UUID) {
        guard let i = index(of: id) else { return }
        objects.append(objects.remove(at: i))
    }

    public mutating func sendToBack(_ id: UUID) {
        guard let i = index(of: id) else { return }
        objects.insert(objects.remove(at: i), at: 0)
    }

    public mutating func updateObject(_ id: UUID, _ body: (inout PageObject) -> Void) {
        guard let i = index(of: id) else { return }
        body(&objects[i])
    }

    public mutating func updateText(_ id: UUID, _ body: (inout TextContainer) -> Void) {
        guard let i = index(of: id), case .text(var t) = objects[i] else { return }
        body(&t)
        objects[i] = .text(t)
    }

    public mutating func move(_ id: UUID, dx: Double, dy: Double) {
        updateObject(id) { $0.frame.x += dx; $0.frame.y += dy }
    }

    public mutating func resize(_ id: UUID, width: Double) {
        updateText(id) { $0.frame.width = max(width, Page.minContainerWidth) }
    }

    public mutating func setParagraphs(_ id: UUID, _ paragraphs: [Paragraph]) {
        updateText(id) { $0.paragraphs = paragraphs }
    }

    /// Applies `body` to paragraphs in `range` (clamped to what exists), then clamps their fields.
    public mutating func editParagraphs(_ id: UUID, in range: ClosedRange<Int>, _ body: (inout Paragraph) -> Void) {
        updateText(id) { t in
            guard !t.paragraphs.isEmpty else { return }
            let lo = max(range.lowerBound, 0)
            let hi = min(range.upperBound, t.paragraphs.count - 1)
            guard lo <= hi else { return }
            for i in lo...hi { body(&t.paragraphs[i]); t.paragraphs[i].clamp() }
        }
    }

    /// Recomputes every derived size: text container heights, table widths and heights.
    public mutating func relayout(using measurer: TextMeasuring) {
        for i in objects.indices {
            switch objects[i] {
            case .text(var t):
                let h = measurer.height(of: t.paragraphs, width: t.frame.width)
                t.frame.height = max(h, Page.minContainerHeight)
                objects[i] = .text(t)
            case .table(var t):
                t.frame.width = t.columnWidths.reduce(0, +)
                t.frame.height = t.rowHeights(using: measurer).reduce(0, +)
                objects[i] = .table(t)
            case .image, .attachment:
                break
            }
        }
    }
}
```

- [ ] **Step 5: Add heading scales to `Paragraph`.** In `Sources/PageModel/Text.swift`, inside `public struct Paragraph`, directly after `public static let maxIndent = 8` add:

```swift
    /// Display scale per heading level (index 0 = body). Shared by the editor and the importer.
    public static let headingScales: [Double] = [1, 1.8, 1.4, 1.2]
```

In `Sources/CanvasKit/AttributedBridge.swift` replace the line `static let headingScale: [CGFloat] = [1, 1.8, 1.4, 1.2]` with:

```swift
    static let headingScale: [CGFloat] = Paragraph.headingScales.map { CGFloat($0) }
```

- [ ] **Step 6: Run to verify the model checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED` (the existing checks still pass too).

- [ ] **Step 7: Write the failing Store checks.** Append to `Sources/Checks/StoreChecks.swift` (add `import Darwin` is not needed; `Foundation` provides `chmod`/`getuid`) and call `assetAndSectionChecks()` from `main.swift` after `storeChecks()`:

```swift
func assetAndSectionChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var pkg = try! NotebookPackage.create(at: root.appendingPathComponent("A.notebook"), name: "A")

    let name = try! pkg.addAsset(data: Data([1, 2, 3]), ext: "PNG")
    check(name.hasSuffix(".png"), "asset keeps a sanitised extension")
    checkEqual(pkg.loadAsset(name), Data([1, 2, 3]), "asset round-trips")
    try! pkg.writeAsset(name: "fixed.jpg", data: Data([7]))
    checkEqual(pkg.loadAsset("fixed.jpg"), Data([7]), "writeAsset stores under the given name")
    checkEqual(pkg.loadAsset("../notebook.json"), nil, "a path escape is not an asset")
    checkEqual(pkg.loadAsset("a/b.png"), nil, "a nested path is not an asset")
    checkEqual(pkg.loadAsset(""), nil, "an empty name is not an asset")
    checkEqual(pkg.loadAsset("missing.png"), nil, "a missing asset is nil")
    check(checkThrows("writeAsset with a path") { try pkg.writeAsset(name: "../x.png", data: Data()) } != nil,
          "writeAsset refuses a name that is not a plain file name")

    let p1 = Page(id: UUID(), title: "One",
                  objects: [.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 10, height: 10), asset: name))])
    let p2 = Page(id: UUID(), title: "Two", objects: [])
    let report = Data(#"{"pagesImported":2}"#.utf8)
    let section = try! pkg.addSection(name: "Imported", pages: [p1, p2], report: report)
    checkEqual(pkg.notebook.sections.count, 2, "section added")
    checkEqual(pkg.notebook.sections[1].name, "Imported", "section name kept")
    checkEqual(pkg.notebook.sections[1].pages.map(\.title), ["One", "Two"], "page refs keep their order")
    checkEqual(try! pkg.loadPage(p1.id), p1, "an imported page loads back identically")
    checkEqual(try! NotebookPackage.open(at: pkg.url).notebook, pkg.notebook, "the manifest on disk matches memory")
    check(FileManager.default.fileExists(atPath: pkg.url.appendingPathComponent("imports/\(section.id.uuidString).json").path),
          "the import report is written")

    let empty = try! pkg.addSection(name: "Empty", pages: [])
    checkEqual(pkg.notebook.sections.last?.id, empty.id, "an empty section can be added")

    // A failing page write must leave the manifest untouched (Review Focus 4).
    if getuid() != 0 {
        let pagesDir = pkg.url.appendingPathComponent("pages")
        chmod(pagesDir.path, 0o500)
        let before = pkg.notebook
        check(checkThrows("addSection into a read-only pages folder") {
            try pkg.addSection(name: "Bad", pages: [Page(id: UUID(), title: "x", objects: [])])
        } != nil, "addSection reports the write failure")
        chmod(pagesDir.path, 0o700)
        checkEqual(pkg.notebook, before, "a failed addSection leaves the in-memory manifest unchanged")
        checkEqual(try! NotebookPackage.open(at: pkg.url).notebook, before, "…and the manifest on disk")
    }
}
```

- [ ] **Step 8: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`value of type 'NotebookPackage' has no member 'addAsset'`).

- [ ] **Step 9: Implement the Store additions.** In `Sources/Store/NotebookPackage.swift` add these private helpers next to `manifestURL`:

```swift
    private var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    private var importsURL: URL { url.appendingPathComponent("imports", isDirectory: true) }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
```

and add these members at the end of the struct (before the closing brace):

```swift
    /// Stores `data` under a fresh `assets/<uuid>.<ext>` name and returns that name.
    public func addAsset(data: Data, ext: String) throws -> String {
        let name = AssetName.make(ext: ext)
        try writeAsset(name: name, data: data)
        return name
    }

    /// Stores `data` as `assets/<name>` (atomic). `name` must be a plain file name.
    public func writeAsset(name: String, data: Data) throws {
        guard Self.isPlainFileName(name) else { throw StoreError.invalidAssetName }
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try data.write(to: assetsURL.appendingPathComponent(name), options: .atomic)
    }

    /// The asset's data, or nil when the name is not a plain file name or the file is missing.
    public func loadAsset(_ name: String) -> Data? {
        guard Self.isPlainFileName(name) else { return nil }
        return try? Data(contentsOf: assetsURL.appendingPathComponent(name))
    }

    /// Adds a section holding `pages`. Assets must already be stored. Order: page files, then the optional
    /// report, then the manifest entry last, so a failure leaves at most orphan files, never a dangling section.
    public mutating func addSection(name: String, pages: [Page], report: Data? = nil) throws -> Section {
        let section = Section(id: UUID(), name: name, pages: pages.map { PageRef(id: $0.id, title: $0.title) })
        for page in pages { try write(page) }
        if let report {
            try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)
            try report.write(to: importsURL.appendingPathComponent("\(section.id.uuidString).json"), options: .atomic)
        }
        var updated = notebook
        updated.sections.append(section)
        try commitManifest(updated)
        return section
    }
```

and in `Sources/Store/StoreError.swift` add the case `case invalidAssetName` (keep the enum `Equatable`).

- [ ] **Step 10: Run to verify it passes.** Run: `swift run Checks`. Expected: `ALL PASSED`.

- [ ] **Step 11: Commit.**

```bash
git add Sources
git commit -m "feat(model,store): image/table/attachment objects, assets, sections" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

### Task 2: `OneStore` primitives (header, file nodes, node lists, transaction log)

**Files:**
- Create: `Sources/OneStore/OneStoreError.swift`, `Sources/OneStore/ByteReader.swift`, `Sources/OneStore/Ids.swift`, `Sources/OneStore/FileStructure.swift`, `Sources/Checks/OneFixtures.swift`, `Sources/Checks/OneStoreChecks.swift`
- Modify: `Package.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Produces (internal unless marked public):
  - `public enum OneStoreError: Error, Equatable { notAOneFile, unsupportedFileType, unsupportedVersion(UInt32), truncated(offset: Int), corrupt(offset: Int, reason: String) }`
  - `struct ByteReader` (`init(_ data: Data)`, `count`, `u8/u16/u32/u64(_ offset:)`, `slice(_:_:)`, `check(_:_:)`), all throwing `truncated`.
  - `public struct GUID: Hashable` (`init(string:)`, `zero`, `isZero`), `public struct ExtendedGUID: Hashable { guid, n }`, `ChunkRef { stp, cb, isNil, isZero }`.
  - `FileNode { id: UInt16, offset, size, stpFormat, cbFormat, baseType, fnd, end, parse(_:at:), chunkRef(_:) }`.
  - `OneHeader.parse(_:)`, `TransactionLog.committedCounts(_:header:)`, `NodeListReader.nodes(from:warnings:)`, `OpenedStore(_ data: Data)` with `rootNodes(warnings:)`.
- Test helpers (in `Checks`): `ByteBuilder`, `FNode`, `fragment(...)`, `oneHeader(...)`, `transactionLog(...)`, `simpleFile(...)`, `guidBytes(_:)`, `fuzz(_:_:)`.

- [ ] **Step 1: Edit `Package.swift`** to add the `OneStore` target and let `Checks` depend on it:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .target(name: "OneStore"),
        .target(name: "CanvasKit", dependencies: ["PageModel", "Store"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store", "OneStore", "CanvasKit"]),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasKit"]),
    ],
    swiftLanguageModes: [.v5]
)
```

(`OneStore` needs at least one source file to build; Step 3 creates them. Do not build until Step 3 is done.)

- [ ] **Step 2: Create the test fixture helpers** in `Sources/Checks/OneFixtures.swift`:

```swift
import Foundation
import OneStore

/// Little-endian byte builder for hand-made `.one` fixtures.
struct ByteBuilder {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func append(_ b: [UInt8]) { bytes += b }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
    mutating func pad(to n: Int) { if bytes.count < n { zeros(n - bytes.count) } }
}

func le32(_ v: UInt32) -> [UInt8] { var b = ByteBuilder(); b.u32(v); return b.bytes }
func le16(_ v: UInt16) -> [UInt8] { var b = ByteBuilder(); b.u16(v); return b.bytes }
func utf16le(_ s: String) -> [UInt8] { s.utf16.flatMap { le16($0) } }

/// "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" -> the 16 bytes as stored in a file (first three groups little-endian).
func guidBytes(_ s: String) -> [UInt8] {
    let hex = Array(s.filter { $0 != "{" && $0 != "}" && $0 != "-" })
    precondition(hex.count == 32, "bad GUID \(s)")
    let b = (0..<16).map { UInt8(String(hex[2 * $0...2 * $0 + 1]), radix: 16)! }
    return Array(b[0..<4].reversed()) + Array(b[4..<6].reversed()) + Array(b[6..<8].reversed()) + Array(b[8..<16])
}

let oneFileTypeGUID = "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}"
let onetoc2FileTypeGUID = "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}"
let revisionStoreFormatGUID = "{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}"

/// One encoded FileNode: a 4-byte header (id, size, formats, base type, reserved bit) followed by `fnd`.
struct FNode {
    var id: UInt16
    var fnd: [UInt8] = []
    var base: Int = 0
    var stpFormat: Int = 0
    var cbFormat: Int = 0
    var encoded: [UInt8] {
        let size = 4 + fnd.count
        let word: UInt32 = UInt32(id) | UInt32(size) << 10 | UInt32(stpFormat) << 23
            | UInt32(cbFormat) << 25 | UInt32(base) << 27 | UInt32(1) << 31
        return le32(word) + fnd
    }
}

/// A FileNodeListFragment of exactly `size` bytes: header, nodes, optional terminator, zero padding, nextFragment, footer.
func fragment(listID: UInt32, seq: UInt32 = 0, nodes: [FNode], size: Int, terminator: Bool = false,
              next: (stp: UInt64, cb: UInt32)? = nil) -> [UInt8] {
    var b = ByteBuilder()
    b.u64(0xA4567AB1F5F7F4C4); b.u32(listID); b.u32(seq)
    for n in nodes { b.append(n.encoded) }
    if terminator { b.append(FNode(id: 0xFF).encoded) }
    precondition(b.count <= size - 20, "fragment fixture too small for its nodes")
    b.pad(to: size - 20)
    if let next { b.u64(next.stp); b.u32(next.cb) } else { b.u64(UInt64.max); b.u32(0) }
    b.u64(0x8BC215C38233BA4B)
    return b.bytes
}

/// The 1024-byte file header.
func oneHeader(transactions: UInt32, log: (stp: UInt64, cb: UInt32), root: (stp: UInt64, cb: UInt32),
               fileType: String = oneFileTypeGUID, oldestMayRead: UInt32 = 0x2A) -> [UInt8] {
    var b = ByteBuilder()
    b.append(guidBytes(fileType))            // 0  guidFileType
    b.zeros(32)                              // 16 guidFile, 32 guidLegacyFileVersion
    b.append(guidBytes(revisionStoreFormatGUID))   // 48 guidFileFormat
    b.u32(0x2A); b.u32(0x2A); b.u32(0x2A); b.u32(oldestMayRead)   // 64..80 file format versions
    b.zeros(16)                              // 80 legacy free chunk list, 88 legacy transaction log
    b.u32(transactions)                      // 96 cTransactionsInLog
    b.zeros(60)                              // 100..160
    b.u64(log.stp); b.u32(log.cb)            // 160 fcrTransactionLog
    b.u64(root.stp); b.u32(root.cb)          // 172 fcrFileNodeListRoot
    b.pad(to: 1024)
    return b.bytes
}

/// A TransactionLogFragment of exactly `size` bytes: entries, zero padding, nextFragment.
func transactionLog(entries: [(src: UInt32, sw: UInt32)], size: Int, next: (stp: UInt64, cb: UInt32)? = nil) -> [UInt8] {
    var b = ByteBuilder()
    for e in entries { b.u32(e.src); b.u32(e.sw) }
    precondition(b.count <= size - 12, "transaction log fixture too small")
    b.pad(to: size - 12)
    if let next { b.u64(next.stp); b.u32(next.cb) } else { b.u64(UInt64.max); b.u32(0) }
    return b.bytes
}

/// Header + transaction log + one list fragment holding `nodes`, at fixed offsets.
/// `committed == nil` writes a log with no entry for the list; otherwise the log commits that many nodes.
func simpleFile(nodes: [FNode], listID: UInt32 = 0x10, committed: UInt32? = nil, fragSize: Int = 512,
                terminator: Bool = true) -> Data {
    let logStp = 1024, logSize = 64
    let listStp = logStp + logSize
    var entries: [(src: UInt32, sw: UInt32)] = []
    if let committed { entries.append((listID, committed)) }
    entries.append((1, 0))                    // sentinel ends the transaction
    var b = ByteBuilder()
    b.append(oneHeader(transactions: 1, log: (UInt64(logStp), UInt32(logSize)),
                       root: (UInt64(listStp), UInt32(fragSize))))
    b.append(transactionLog(entries: entries, size: logSize))
    b.append(fragment(listID: listID, nodes: nodes, size: fragSize, terminator: terminator))
    return Data(b.bytes)
}

/// Runs `body` on every truncation of `data` and on single-byte corruptions; it must either succeed or throw a
/// `OneStoreError`. Any other error is a failure, and a trap or hang fails the whole run (Review Focus 1).
func fuzz(_ label: String, _ data: Data, step: Int = 1, _ body: (Data) throws -> Void, file: String = #fileID, line: Int = #line) {
    func attempt(_ d: Data, _ what: String) {
        do { try body(d) }
        catch is OneStoreError {}
        catch { failures += 1; print("FAIL \(file):\(line): \(label) \(what) threw a non-OneStoreError: \(error)") }
    }
    var len = 0
    while len < data.count { attempt(data.prefix(len), "truncated to \(len)"); len += step }
    var pos = 0
    while pos < data.count {
        for v in [UInt8(0x00), 0xFF] {
            var d = data; d[d.startIndex + pos] = v
            attempt(d, "byte \(pos) set to \(v)")
        }
        pos += step
    }
}

- [ ] **Step 3: Write the failing checks** in `Sources/Checks/OneStoreChecks.swift`, and call `oneStorePrimitiveChecks()` from `main.swift` (add `@testable import OneStore` to `main.swift`'s imports is not needed; the call only needs the function):

```swift
import Foundation
@testable import OneStore

private func open(_ data: Data) throws -> (store: OpenedStore, nodes: [FileNode], warnings: [String]) {
    let store = try OpenedStore(data)
    var warnings = store.warnings
    let nodes = try store.rootNodes(warnings: &warnings)
    return (store, nodes, warnings)
}

private func errorOf(_ data: Data) -> OneStoreError? {
    do { _ = try open(data) } catch let e as OneStoreError { return e } catch { return nil }
    return nil
}

private func thrownError(_ body: () throws -> Void) -> OneStoreError? {
    do { try body() } catch let e as OneStoreError { return e } catch { return nil }
    return nil
}

private func isCorrupt(_ e: OneStoreError?) -> Bool { if case .corrupt? = e { return true }; return false }
private func isTruncated(_ e: OneStoreError?) -> Bool { if case .truncated? = e { return true }; return false }

/// Two fragments of list 0x10 (3 nodes then 2), root at the first; the log commits `committed` nodes.
func twoFragmentFile(committed: UInt32 = 5, secondListID: UInt32 = 0x10, loop: Bool = false) -> Data {
    let logStp = 1024, logSize = 64, f1 = logStp + logSize, size = 256, f2 = f1 + size
    var b = ByteBuilder()
    b.append(oneHeader(transactions: 1, log: (UInt64(logStp), UInt32(logSize)), root: (UInt64(f1), UInt32(size))))
    b.append(transactionLog(entries: [(0x10, committed), (1, 0)], size: logSize))
    b.append(fragment(listID: 0x10, seq: 0, nodes: [FNode(id: 0x40), FNode(id: 0x41), FNode(id: 0x42)],
                      size: size, terminator: true, next: (UInt64(loop ? f1 : f2), UInt32(size))))
    b.append(fragment(listID: secondListID, seq: 1, nodes: [FNode(id: 0x43), FNode(id: 0x44)], size: size, terminator: true))
    return Data(b.bytes)
}

func oneStorePrimitiveChecks() {
    let five = (0..<5).map { FNode(id: UInt16(0x30 + $0)) }
    let ok = simpleFile(nodes: [FNode(id: 0x04, fnd: [UInt8](repeating: 0, count: 20))])
    checkEqual(try! open(ok).nodes.map(\.id), [0x04], "a minimal file opens")

    // --- header ---
    checkEqual(errorOf(Data()), .notAOneFile, "empty data is not a .one file")
    checkEqual(errorOf(Data(repeating: 0, count: 2000)), .notAOneFile, "zeros are not a .one file")
    checkEqual(errorOf(ok.prefix(1000)), .notAOneFile, "a header cut short is not a .one file")
    var toc = ok; toc.replaceSubrange(0..<16, with: guidBytes(onetoc2FileTypeGUID))
    checkEqual(errorOf(toc), .unsupportedFileType, ".onetoc2 is recognised and refused")
    var badFormat = ok; badFormat[48] ^= 0xFF
    checkEqual(errorOf(badFormat), .notAOneFile, "a wrong format GUID is not a revision store")
    var newer = ok; newer.replaceSubrange(76..<80, with: le32(0x2B))
    checkEqual(errorOf(newer), .unsupportedVersion(0x2B), "a file that needs a newer reader is refused")

    // --- file node header packing ---
    let packed = FNode(id: 0x1F7, fnd: [1, 2, 3, 4, 5, 6, 7, 8], base: 2, stpFormat: 3, cbFormat: 1)
    let n0 = try! open(simpleFile(nodes: [packed])).nodes[0]
    checkEqual(n0.id, 0x1F7, "node id is the low 10 bits")
    checkEqual(n0.size, 12, "node size is header + fnd")
    checkEqual(n0.stpFormat, 3, "stp format bits")
    checkEqual(n0.cbFormat, 1, "cb format bits")
    checkEqual(n0.baseType, 2, "base type bits")
    checkEqual(n0.fnd, n0.offset + 4, "fnd follows the 4-byte header")

    // --- every stp/cb format ---
    let stpRaw: [(UInt64, Int)] = [(0x1122_3344_5566, 8), (0x0102_0304, 4), (0x0102, 2), (0x0102_0304, 4)]
    let stpExpect: [UInt64] = [0x1122_3344_5566, 0x0102_0304, 0x0102 * 8, 0x0102_0304 * 8]
    let cbRaw: [(UInt64, Int)] = [(0x0A0B, 4), (0x0A0B_0C0D, 8), (0x7F, 1), (0x0A0B, 2)]
    let cbExpect: [UInt64] = [0x0A0B, 0x0A0B_0C0D, 0x7F * 8, 0x0A0B * 8]
    for s in 0..<4 {
        for c in 0..<4 {
            var f = ByteBuilder()
            for i in 0..<stpRaw[s].1 { f.u8(UInt8((stpRaw[s].0 >> (8 * UInt64(i))) & 0xFF)) }
            for i in 0..<cbRaw[c].1 { f.u8(UInt8((cbRaw[c].0 >> (8 * UInt64(i))) & 0xFF)) }
            f.u8(0xAA)
            let node = FNode(id: 0x08, fnd: f.bytes, base: 1, stpFormat: s, cbFormat: c)
            let opened = try! open(simpleFile(nodes: [node]))
            let (ref, next) = try! opened.nodes[0].chunkRef(opened.store.reader)
            checkEqual(ref.stp, stpExpect[s], "stp format \(s)")
            checkEqual(ref.cb, cbExpect[c], "cb format \(c)")
            checkEqual(next, opened.nodes[0].fnd + stpRaw[s].1 + cbRaw[c].1, "offset after the reference (\(s),\(c))")
        }
    }
    let nilNode = FNode(id: 0x08, fnd: [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0], base: 1, stpFormat: 1, cbFormat: 0)
    let nilOpened = try! open(simpleFile(nodes: [nilNode]))
    check(try! nilOpened.nodes[0].chunkRef(nilOpened.store.reader).ref.isNil, "an all-ones 4-byte stp is fcrNil")
    let shortNode = FNode(id: 0x08, fnd: [0, 0, 0, 0], base: 1, stpFormat: 0, cbFormat: 1)   // needs 16 bytes, has 4
    let shortOpened = try! open(simpleFile(nodes: [shortNode]))
    check(isCorrupt(thrownError { _ = try shortOpened.nodes[0].chunkRef(shortOpened.store.reader) }),
          "a reference that runs past its node is corrupt, not a trap")

    // --- node lists ---
    let three = (0..<3).map { FNode(id: UInt16(0x20 + $0), fnd: [UInt8](repeating: UInt8($0), count: 4)) }
    checkEqual(try! open(simpleFile(nodes: three)).nodes.map(\.id), [0x20, 0x21, 0x22], "nodes read in order up to the terminator")
    checkEqual(try! open(simpleFile(nodes: three, terminator: false)).nodes.count, 3, "zero padding after the last node ends the list")

    // --- transaction log ---
    checkEqual(try! open(simpleFile(nodes: five, committed: 3)).nodes.count, 3, "only committed nodes are read")
    checkEqual(try! open(simpleFile(nodes: five, committed: 5)).nodes.count, 5, "all nodes when all are committed")
    checkEqual(try! open(simpleFile(nodes: five, committed: 0)).nodes.count, 0, "a list committed with zero nodes is empty")
    let beyond = try! open(simpleFile(nodes: five, committed: 9))
    checkEqual(beyond.nodes.count, 5, "a committed count above what exists reads what exists")
    check(beyond.warnings.contains { $0.contains("were committed") }, "…and warns about it")
    let noEntry = try! open(simpleFile(nodes: five))
    checkEqual(noEntry.nodes.count, 5, "a list with no log entry is read to its end")
    check(noEntry.warnings.contains { $0.contains("no committed count") }, "…and warns about it")
    var noLog = simpleFile(nodes: five, committed: 3)
    noLog.replaceSubrange(96..<100, with: le32(0))
    let noLogOpened = try! open(noLog)
    checkEqual(noLogOpened.nodes.count, 5, "an empty transaction log falls back to reading to the end")
    check(noLogOpened.warnings.contains { $0.contains("transaction log is empty") }, "…and warns")
    var badLog = simpleFile(nodes: five, committed: 3)
    badLog.replaceSubrange(160..<168, with: [0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])     // log pointer far past the end
    let badLogOpened = try! open(badLog)
    checkEqual(badLogOpened.nodes.count, 5, "an unreadable transaction log falls back to reading to the end")
    check(badLogOpened.warnings.contains { $0.contains("transaction log unreadable") }, "…and warns")

    // --- fragments ---
    checkEqual(try! open(twoFragmentFile()).nodes.map(\.id), [0x40, 0x41, 0x42, 0x43, 0x44], "fragments are chained in order")
    checkEqual(try! open(twoFragmentFile(committed: 4)).nodes.map(\.id), [0x40, 0x41, 0x42, 0x43], "the committed count spans fragments")
    check(isCorrupt(errorOf(twoFragmentFile(secondListID: 0x11))), "a fragment of another list is corrupt")
    check(isCorrupt(errorOf(twoFragmentFile(loop: true))), "fragments that loop are corrupt, not an endless read")
    var badMagic = simpleFile(nodes: five)
    badMagic[1024 + 64] ^= 0xFF
    check(isCorrupt(errorOf(badMagic)), "a bad fragment magic is corrupt")
    var farRoot = simpleFile(nodes: five)
    farRoot.replaceSubrange(172..<180, with: le32(0x00FF_FFFF) + le32(0))
    check(isTruncated(errorOf(farRoot)), "a root list outside the file is truncated")

    // --- hostile input (Review Focus 1) ---
    fuzz("simple file", simpleFile(nodes: five, committed: 5)) { d in _ = try open(d) }
    fuzz("two fragments", twoFragmentFile()) { d in _ = try open(d) }
}

- [ ] **Step 4: Create `Sources/OneStore/OneStoreError.swift` and `Sources/OneStore/ByteReader.swift`.**

```swift
import Foundation

public enum OneStoreError: Error, Equatable {
    case notAOneFile
    case unsupportedFileType
    case unsupportedVersion(UInt32)
    case truncated(offset: Int)
    case corrupt(offset: Int, reason: String)
}
```

```swift
import Foundation

/// Bounds-checked little-endian reads over a Data buffer. Offsets are relative to the start of the data (so a
/// slice with a non-zero startIndex works), and every read throws `truncated` instead of trapping.
struct ByteReader {
    let data: Data
    init(_ data: Data) { self.data = data }
    var count: Int { data.count }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw OneStoreError.truncated(offset: offset)
        }
    }

    func u8(_ o: Int) throws -> UInt8 {
        try check(o, 1)
        return data[data.startIndex + o]
    }

    func u16(_ o: Int) throws -> UInt16 {
        try check(o, 2)
        let b = data.startIndex + o
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }

    func u32(_ o: Int) throws -> UInt32 {
        try check(o, 4)
        let b = data.startIndex + o
        let b0 = UInt32(data[b]), b1 = UInt32(data[b + 1]), b2 = UInt32(data[b + 2]), b3 = UInt32(data[b + 3])
        return b0 | b1 << 8 | b2 << 16 | b3 << 24
    }

    func u64(_ o: Int) throws -> UInt64 {
        try check(o, 8)
        let b = data.startIndex + o
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(data[b + i]) }
        return v
    }

    /// A slice that shares storage with the original data (no copy). Its indices start at `startIndex + o`.
    func slice(_ o: Int, _ n: Int) throws -> Data {
        try check(o, n)
        let s = data.startIndex + o
        return data[s..<s + n]
    }
}
```

- [ ] **Step 5: Create `Sources/OneStore/Ids.swift`.**

```swift
import Foundation

public struct GUID: Hashable, Sendable {
    public let hi: UInt64        // the 16 bytes as stored in the file, as two big-endian words (used for identity only)
    public let lo: UInt64
    public static let zero = GUID(hi: 0, lo: 0)
    public init(hi: UInt64, lo: UInt64) { self.hi = hi; self.lo = lo }
    public var isZero: Bool { hi == 0 && lo == 0 }

    init(_ r: ByteReader, at o: Int) throws {
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<8 { let byte = try r.u8(o + i); h = h << 8 | UInt64(byte) }
        for i in 8..<16 { let byte = try r.u8(o + i); l = l << 8 | UInt64(byte) }
        self.hi = h; self.lo = l
    }

    /// Parses "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" (braces and dashes optional) into file byte order.
    public init?(string: String) {
        let s = string.filter { $0 != "{" && $0 != "}" && $0 != "-" }
        guard s.count == 32, s.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(s)
        var b: [UInt8] = []
        for i in 0..<16 { b.append(UInt8(String(chars[2 * i...2 * i + 1]), radix: 16)!) }
        let f = Array(b[0..<4].reversed()) + Array(b[4..<6].reversed()) + Array(b[6..<8].reversed()) + Array(b[8..<16])
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<8 { h = h << 8 | UInt64(f[i]) }
        for i in 8..<16 { l = l << 8 | UInt64(f[i]) }
        self.hi = h; self.lo = l
    }
}

public struct ExtendedGUID: Hashable, Sendable {
    public let guid: GUID
    public let n: UInt32
    public init(guid: GUID, n: UInt32) { self.guid = guid; self.n = n }
    init(_ r: ByteReader, at o: Int) throws {
        guid = try GUID(r, at: o)
        n = try r.u32(o + 16)
    }
}
```

- [ ] **Step 6: Create `Sources/OneStore/FileStructure.swift`.**

```swift
import Foundation

/// A file chunk reference: where data starts and how long it is.
struct ChunkRef: Equatable {
    var stp: UInt64
    var cb: UInt64
    var isNil: Bool { stp == UInt64.max }
    var isZero: Bool { stp == 0 && cb == 0 }

    /// A FileChunkReference64x32: an 8-byte stp followed by a 4-byte cb.
    static func read64x32(_ r: ByteReader, at o: Int) throws -> ChunkRef {
        let stp = try r.u64(o)
        let cb = try r.u32(o + 8)
        return ChunkRef(stp: stp, cb: UInt64(cb))
    }
}

struct FileNode: Equatable {
    let id: UInt16
    let offset: Int
    let size: Int
    let stpFormat: Int
    let cbFormat: Int
    let baseType: Int
    var fnd: Int { offset + 4 }
    var end: Int { offset + size }

    static func parse(_ r: ByteReader, at o: Int) throws -> FileNode {
        let v = try r.u32(o)
        let size = Int((v >> 10) & 0x1FFF)
        guard size >= 4 else { throw OneStoreError.corrupt(offset: o, reason: "file node size \(size) is below its 4-byte header") }
        return FileNode(id: UInt16(v & 0x3FF), offset: o, size: size, stpFormat: Int((v >> 23) & 3),
                        cbFormat: Int((v >> 25) & 3), baseType: Int((v >> 27) & 0xF))
    }

    /// The FileNodeChunkReference at the start of `fnd`, and the offset just after it.
    func chunkRef(_ r: ByteReader) throws -> (ref: ChunkRef, next: Int) {
        var o = fnd
        let stp: UInt64
        switch stpFormat {
        case 0:
            stp = try r.u64(o); o += 8
        case 1:
            let v = try r.u32(o); stp = v == UInt32.max ? UInt64.max : UInt64(v); o += 4
        case 2:
            let v = try r.u16(o); stp = UInt64(v) * 8; o += 2
        default:
            let v = try r.u32(o); stp = UInt64(v) * 8; o += 4
        }
        let cb: UInt64
        switch cbFormat {
        case 0:
            let v = try r.u32(o); cb = UInt64(v); o += 4
        case 1:
            cb = try r.u64(o); o += 8
        case 2:
            let v = try r.u8(o); cb = UInt64(v) * 8; o += 1
        default:
            let v = try r.u16(o); cb = UInt64(v) * 8; o += 2
        }
        guard o <= end else { throw OneStoreError.corrupt(offset: offset, reason: "chunk reference runs past its file node") }
        return (ChunkRef(stp: stp, cb: cb), o)
    }
}

struct OneHeader {
    static let oneFileType = GUID(string: "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}")!
    static let toc2FileType = GUID(string: "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}")!
    static let revisionStoreFormat = GUID(string: "{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}")!
    static let newestReadableVersion: UInt32 = 0x2A

    let transactions: UInt32
    let transactionLog: ChunkRef
    let rootList: ChunkRef

    static func parse(_ r: ByteReader) throws -> OneHeader {
        guard r.count >= 1024 else { throw OneStoreError.notAOneFile }
        let type = try GUID(r, at: 0)
        if type == toc2FileType { throw OneStoreError.unsupportedFileType }
        guard type == oneFileType, try GUID(r, at: 48) == revisionStoreFormat else { throw OneStoreError.notAOneFile }
        let mayRead = try r.u32(76)               // ffvOldestCodeThatMayReadThisFile
        guard mayRead <= newestReadableVersion else { throw OneStoreError.unsupportedVersion(mayRead) }
        return OneHeader(transactions: try r.u32(96),
                         transactionLog: try ChunkRef.read64x32(r, at: 160),
                         rootList: try ChunkRef.read64x32(r, at: 172))
    }
}

enum TransactionLog {
    /// FileNodeListID -> number of committed nodes, taken from the first `header.transactions` transactions.
    static func committedCounts(_ r: ByteReader, header: OneHeader) throws -> [UInt32: UInt32] {
        var counts: [UInt32: UInt32] = [:]
        var finished: UInt32 = 0
        var ref = header.transactionLog
        var seen = Set<UInt64>()
        while finished < header.transactions {
            guard !ref.isNil, !ref.isZero, ref.cb >= 12, ref.stp <= UInt64(r.count), ref.cb <= UInt64(r.count) - ref.stp else {
                throw OneStoreError.corrupt(offset: Int(clamping: ref.stp), reason: "transaction log fragment is outside the file")
            }
            guard seen.insert(ref.stp).inserted else {
                throw OneStoreError.corrupt(offset: Int(ref.stp), reason: "transaction log fragments form a loop")
            }
            let start = Int(ref.stp), size = Int(ref.cb)
            for i in 0..<((size - 12) / 8) {
                let src = try r.u32(start + 8 * i)
                let value = try r.u32(start + 8 * i + 4)
                if src == 1 {                         // sentinel: the transaction is complete
                    finished += 1
                    if finished == header.transactions { return counts }
                } else if src != 0 {
                    counts[src] = value               // the newest entry for a list wins
                }
            }
            ref = try ChunkRef.read64x32(r, at: start + size - 12)
        }
        return counts
    }
}

struct NodeListReader {
    let r: ByteReader
    /// FileNodeListID -> committed node count; nil when the file has no usable transaction log.
    let committed: [UInt32: UInt32]?

    /// Reads the nodes of the list whose first fragment is `first`, following nextFragment links and stopping at the
    /// committed count, a ChunkTerminator, or the end of the data.
    func nodes(from first: ChunkRef, warnings: inout [String]) throws -> [FileNode] {
        var result: [FileNode] = []
        var ref = first
        var listID: UInt32?
        var limit: Int?
        var seen = Set<UInt64>()
        while true {
            guard !ref.isNil, ref.cb >= 36, ref.stp <= UInt64(r.count), ref.cb <= UInt64(r.count) - ref.stp else {
                throw OneStoreError.truncated(offset: Int(clamping: ref.stp))
            }
            guard seen.insert(ref.stp).inserted else {
                throw OneStoreError.corrupt(offset: Int(ref.stp), reason: "file node list fragments form a loop")
            }
            let start = Int(ref.stp), size = Int(ref.cb)
            guard try r.u64(start) == 0xA4567AB1F5F7F4C4 else {
                throw OneStoreError.corrupt(offset: start, reason: "bad file node list fragment header")
            }
            let id = try r.u32(start + 8)
            if let known = listID {
                guard known == id else { throw OneStoreError.corrupt(offset: start, reason: "fragment belongs to a different list") }
            } else {
                listID = id
                if let committed {
                    if let n = committed[id] { limit = Int(n) }
                    else { warnings.append("file node list 0x\(String(id, radix: 16)) has no committed count; reading to its end") }
                }
            }
            let end = start + size - 20               // nextFragment (12 bytes) and footer (8 bytes) follow the nodes
            var o = start + 16
            while end - o >= 4 {
                if let limit, result.count >= limit { return result }
                let word = try r.u32(o)
                let fid = word & 0x3FF
                if fid == 0 || fid == 0xFF { break }  // zero padding, or a ChunkTerminator
                let node = try FileNode.parse(r, at: o)
                guard node.end <= end else { throw OneStoreError.corrupt(offset: o, reason: "file node runs past its fragment") }
                result.append(node)
                o = node.end
            }
            if let limit, result.count >= limit { return result }
            let next = try ChunkRef.read64x32(r, at: end)
            if next.isNil || next.cb == 0 { break }
            ref = next
        }
        if let limit, result.count < limit {
            warnings.append("file node list has \(result.count) nodes but \(limit) were committed")
        }
        return result
    }
}

/// A validated file header plus the machinery to read its node lists.
struct OpenedStore {
    let reader: ByteReader
    let header: OneHeader
    let lists: NodeListReader
    var warnings: [String]

    init(_ data: Data) throws {
        let r = ByteReader(data)
        let header = try OneHeader.parse(r)
        var warnings: [String] = []
        var counts: [UInt32: UInt32]?
        if header.transactions == 0 {
            warnings.append("transaction log is empty; reading every node list to its end")
        } else {
            do { counts = try TransactionLog.committedCounts(r, header: header) }
            catch { warnings.append("transaction log unreadable (\(error)); reading every node list to its end") }
        }
        self.reader = r
        self.header = header
        self.warnings = warnings
        self.lists = NodeListReader(r: r, committed: counts)
    }

    func rootNodes(warnings: inout [String]) throws -> [FileNode] {
        try lists.nodes(from: header.rootList, warnings: &warnings)
    }
}
```

- [ ] **Step 7: Run to verify the checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED`. If a hostile-input check fails with a `FAIL … threw a non-OneStoreError`, fix the reader so the error is a `OneStoreError`; if the run crashes (trap), the printed last line names the check, so add the missing bounds check in the reader, not in the check.

- [ ] **Step 8: Commit.**

```bash
git add Package.swift Sources
git commit -m "feat(onestore): header, file nodes, node lists, transaction log" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

### Task 3: `OneStore` objects (property sets, global IDs, revisions, `OneFile`)

**Files:**
- Create: `Sources/OneStore/Properties.swift`, `Sources/OneStore/ObjectBlob.swift`, `Sources/OneStore/OneFile.swift`
- Modify: `Sources/Checks/OneFixtures.swift` (add the full-file builder), `Sources/Checks/OneStoreChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: Task 2's `OpenedStore`, `FileNode`, `ChunkRef`, `ByteReader`, `GUID`, `ExtendedGUID`.
- Produces (all `public`):
  - `typealias PropertyID = UInt32` (the 31-bit PropertyID value as MS-ONE lists it, type bits included); `struct JCID: Hashable` with `rawValue` and constants `.section .pageSeries .page .outline .outlineElement .richText .image .numberList .outlineGroup .table .tableRow .tableCell .title .embeddedFile .pageManifest .paragraphStyle`.
  - `enum OneValue: Equatable { none, bool, u8, u16, u32, u64, bytes(Data), objectIDs([ExtendedGUID]), objectSpaceIDs([ExtendedGUID]), propertySets([PropertySet]), other }`, `struct OneProperty { id, value }`, `struct PropertySet` with `subscript(id)`, `bool u8 u16 u32 float data string u32Array objectIDs objectSpaceIDs propertySets(_:)`, and `public init(_ properties: [OneProperty] = [])`.
  - `OneText.utf16String(_ data: Data) -> String`.
  - `struct OneObject { id, jcid, properties, fileData: FileDataReference? }`, `struct FileDataReference { target, extensionText }`, `struct Revision { id, dependent, role, roots, declared }`, `struct ObjectSpace { id, revisions, objects(at:), rootObject(of:role:) }`, each with a public memberwise `init`.
  - `protocol OneSource { objectSpaces, warnings, fileData(for:) -> (data: Data, ext: String)? }` and `struct OneFile: OneSource` with `init(data: Data) throws`.
- Test helpers added to `Checks`: `FxProp`, `FxObject`, `FxRevision`, `FxFile`, `buildStore(...)`, `compact(_:_:)`.

- [ ] **Step 1: Extend the fixture helpers.** Append to `Sources/Checks/OneFixtures.swift`:

```swift
// ---- Full-file fixtures: object spaces, revisions, global ID tables and objects ----

struct FxProp { var pid: UInt32; var data: [UInt8] = [] }

/// An object declaration. `oids` are the CompactIDs consumed (in property order) by the object's object-ID
/// properties; `osids` likewise for object-space-ID properties.
struct FxObject {
    var oid: UInt32
    var jcid: UInt32
    var props: [FxProp] = []
    var oids: [UInt32] = []
    var osids: [UInt32] = []
}

struct FxRevision {
    var rid: (guid: String, n: UInt32)
    var dependent: (guid: String, n: UInt32)? = nil
    var role: UInt32 = 1
    var idTable: [(index: UInt32, guid: String)]
    var roots: [(role: UInt32, guid: String, n: UInt32)]
    var objects: [FxObject]
    var extraNodes: [FNode] = []     // appended inside the revision's node list (e.g. file data declarations)
}

/// A CompactID: the global-ID-table index in the high 24 bits, `n` in the low 8.
func compact(_ index: UInt32, _ n: UInt8) -> UInt32 { index << 8 | UInt32(n) }

func extGUID(_ guid: String, _ n: UInt32) -> [UInt8] { guidBytes(guid) + le32(n) }

/// A PropertySet body: count, PropertyIDs, then the data of each property in order.
func setBytes(_ props: [FxProp]) -> [UInt8] {
    var b = ByteBuilder()
    b.u16(UInt16(props.count))
    for p in props { b.u32(p.pid) }
    for p in props { b.append(p.data) }
    return b.bytes
}

/// An ObjectSpaceObjectPropSet: object stream, optional object-space stream, the property set, padded to 8 bytes.
func objectBlob(_ o: FxObject) -> [UInt8] {
    var b = ByteBuilder()
    b.u32(UInt32(o.oids.count) | (o.osids.isEmpty ? UInt32(1) << 31 : 0))
    for id in o.oids { b.u32(id) }
    if !o.osids.isEmpty {
        b.u32(UInt32(o.osids.count))
        for id in o.osids { b.u32(id) }
    }
    b.append(setBytes(o.props))
    while b.count % 8 != 0 { b.u8(0) }
    return b.bytes
}

/// Lays out a whole file: a reserved header and transaction log, then lists and blobs appended leaf-first.
final class FxFile {
    var b = ByteBuilder()
    var commits: [(UInt32, UInt32)] = []
    var nextListID: UInt32 = 0x10
    init() { b.zeros(1024 + 4096) }

    func list(_ nodes: [FNode]) -> (stp: UInt64, cb: UInt32) {
        let id = nextListID; nextListID += 1
        let need = nodes.reduce(0) { $0 + $1.encoded.count } + 4 + 40
        let size = (max(need, 256) + 7) / 8 * 8
        let stp = b.count
        b.append(fragment(listID: id, nodes: nodes, size: size, terminator: true))
        commits.append((id, UInt32(nodes.count)))
        return (UInt64(stp), UInt32(size))
    }

    func blob(_ bytes: [UInt8]) -> (stp: UInt64, cb: UInt32) {
        let s = b.count
        b.append(bytes)
        return (UInt64(s), UInt32(bytes.count))
    }

    func finish(root: (stp: UInt64, cb: UInt32)) -> Data {
        var out = b.bytes
        let log = transactionLog(entries: commits.map { (src: $0.0, sw: $0.1) } + [(src: 1, sw: 0)], size: 4096)
        out.replaceSubrange(1024..<(1024 + 4096), with: log)
        out.replaceSubrange(0..<1024, with: oneHeader(transactions: 1, log: (1024, 4096), root: root))
        return Data(out)
    }
}

/// A node holding a FileNodeChunkReference (8-byte stp, 4-byte cb) followed by `extra` bytes.
func refNode(_ id: UInt16, base: Int, ref: (stp: UInt64, cb: UInt32), extra: [UInt8] = []) -> FNode {
    var b = ByteBuilder(); b.u64(ref.stp); b.u32(ref.cb); b.append(extra)
    return FNode(id: id, fnd: b.bytes, base: base, stpFormat: 0, cbFormat: 0)
}

/// ObjectDeclaration2RefCountFND: reference to the property data, then oid, jcid, flags, reference count.
func declNode(blob: (stp: UInt64, cb: UInt32), oid: UInt32, jcid: UInt32) -> FNode {
    refNode(0xA4, base: 1, ref: blob, extra: le32(oid) + le32(jcid) + [0, 1])
}

/// A StringInStorageBuffer: character count then UTF-16 characters.
func storageString(_ s: String) -> [UInt8] { le32(UInt32(s.utf16.count)) + utf16le(s) }

/// ObjectDeclarationFileData3RefCountFND (a file data object): oid, jcid, count, reference string, extension string.
func fileDataDeclNode(oid: UInt32, jcid: UInt32, target: String, ext: String) -> FNode {
    FNode(id: 0x72, fnd: le32(oid) + le32(jcid) + [1] + storageString(target) + storageString(ext))
}

let fileDataHeaderGUID = "{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}"
let fileDataFooterGUID = "{71FBA722-0F79-4A0B-BB13-899256426B24}"

/// A FileDataStoreObject: header GUID, length, 4+8 reserved bytes, the data, padding to 8, footer GUID.
func fileDataObject(_ data: [UInt8]) -> [UInt8] {
    var b = ByteBuilder()
    b.append(guidBytes(fileDataHeaderGUID)); b.u64(UInt64(data.count)); b.u32(0); b.u64(0)
    b.append(data)
    while b.count % 8 != 0 { b.u8(0) }
    b.append(guidBytes(fileDataFooterGUID))
    return b.bytes
}

/// Builds one object space with the given revisions. `rootExtra` nodes (for example a file data store reference)
/// are appended to the root list.
func buildStore(_ file: FxFile, space: (guid: String, n: UInt32), revisions: [FxRevision], rootExtra: [FNode] = []) -> Data {
    var revisionNodes: [FNode] = [FNode(id: 0x14, fnd: [UInt8](repeating: 0, count: 24))]
    for (i, rev) in revisions.enumerated() {
        let groupID = "{99999999-9999-9999-9999-99999999999\(i)}"
        var groupNodes: [FNode] = [FNode(id: 0xB4, fnd: extGUID(groupID, 1))]
        for obj in rev.objects { groupNodes.append(declNode(blob: file.blob(objectBlob(obj)), oid: obj.oid, jcid: obj.jcid)) }
        groupNodes += rev.extraNodes
        groupNodes.append(FNode(id: 0xB8))
        let groupList = file.list(groupNodes)

        let dep = rev.dependent.map { extGUID($0.guid, $0.n) } ?? [UInt8](repeating: 0, count: 20)
        revisionNodes.append(FNode(id: 0x1F, fnd: extGUID(rev.rid.guid, rev.rid.n) + dep + le32(rev.role) + le16(0)
                                   + [UInt8](repeating: 0, count: 20)))
        revisionNodes.append(FNode(id: 0x22))
        for e in rev.idTable { revisionNodes.append(FNode(id: 0x24, fnd: le32(e.index) + guidBytes(e.guid))) }
        revisionNodes.append(FNode(id: 0x28))
        for r in rev.roots { revisionNodes.append(FNode(id: 0x5A, fnd: extGUID(r.guid, r.n) + le32(r.role))) }
        revisionNodes.append(refNode(0xB0, base: 2, ref: groupList, extra: extGUID(groupID, 1)))
        revisionNodes.append(FNode(id: 0x1C))
    }
    let revisionList = file.list(revisionNodes)
    let spaceList = file.list([FNode(id: 0x0C, fnd: extGUID(space.guid, space.n)),
                               refNode(0x10, base: 2, ref: revisionList)])
    let rootList = file.list([FNode(id: 0x04, fnd: extGUID(space.guid, space.n)),
                              refNode(0x08, base: 2, ref: spaceList, extra: extGUID(space.guid, space.n))] + rootExtra)
    return file.finish(root: rootList)
}
```

- [ ] **Step 2: Write the failing checks.** Append to `Sources/Checks/OneStoreChecks.swift` and call `oneStoreObjectChecks()` and `corpusChecks()` from `main.swift`:

```swift
func oneStoreObjectChecks() {
    let space = (guid: "{AAAAAAAA-0000-0000-0000-000000000001}", n: UInt32(1))
    let g1 = "{11111111-1111-1111-1111-111111111111}", g2 = "{22222222-2222-2222-2222-222222222222}"
    let g3 = "{33333333-3333-3333-3333-333333333333}"
    func id(_ g: String, _ n: UInt32) -> ExtendedGUID { ExtendedGUID(guid: GUID(string: g)!, n: n) }
    let float15 = le32(Float(1.5).bitPattern)
    let text = "Hi 😀"
    let textBlob = le32(UInt32(utf16le(text).count + 2)) + utf16le(text) + [0, 0]           // UTF-16LE with a trailing NUL

    let A = FxObject(oid: compact(1, 1), jcid: 0x60037,
                     props: [FxProp(pid: 0x24001C1F, data: le32(2)),                         // array of 2 object IDs
                             FxProp(pid: 0x2C001D63, data: le32(2))],                        // array of 2 object-space IDs
                     oids: [compact(1, 2), compact(2, 3)], osids: [compact(1, 7), compact(2, 8)])
    let B = FxObject(oid: compact(1, 2), jcid: 0x6000C,
                     props: [FxProp(pid: 0x08001C04 | 0x8000_0000),                          // Bold = true (bool bit set)
                             FxProp(pid: 0x0C001C03, data: [3]),                             // u8
                             FxProp(pid: 0x10001C0B, data: le16(22)),                        // u16
                             FxProp(pid: 0x14001C14, data: float15),                         // 4 bytes (a float)
                             FxProp(pid: 0x1C001C22, data: textBlob),                        // length-prefixed bytes
                             FxProp(pid: 0x1400348B, data: le32(7)),                         // an undocumented property
                             FxProp(pid: 0x20001C3F)],                                       // one object ID
                     oids: [compact(2, 9)])
    let E = FxObject(oid: compact(1, 4), jcid: 0x00AB_CDEF,                                  // a JCID MS-ONE does not list
                     props: [FxProp(pid: 0x40003489,                                         // array of property sets
                                    data: le32(2) + le32(0x44000000)
                                        + setBytes([FxProp(pid: 0x08001C04 | 0x8000_0000)])
                                        + setBytes([FxProp(pid: 0x0C001C03, data: [5])])),
                             FxProp(pid: 0x44001235, data: setBytes([FxProp(pid: 0x10001C0B, data: le16(9))]))])  // nested set
    let rev1 = FxRevision(rid: (g1, 100), idTable: [(1, g1), (2, g2)],
                          roots: [(1, g1, 1)], objects: [A, B, E])
    var B2 = B
    B2.props[0] = FxProp(pid: 0x08001C04)                                                    // Bold = false in the later revision
    B2.props[2] = FxProp(pid: 0x10001C0B, data: le16(30))
    let D = FxObject(oid: compact(3, 1), jcid: 0x6000D, props: [])
    let rev2 = FxRevision(rid: (g2, 101), dependent: (g1, 100), idTable: [(1, g1), (2, g2), (3, g3)],
                          roots: [(1, g1, 1)], objects: [B2, D])

    let data = buildStore(FxFile(), space: space, revisions: [rev1, rev2])
    let file = try! OneFile(data: data)
    checkEqual(file.objectSpaces.count, 1, "one object space")
    guard let sp = file.objectSpaces.first, sp.revisions.count == 2 else { check(false, "two revisions"); return }
    checkEqual(sp.id, id(space.guid, space.n), "object space id")
    checkEqual(sp.revisions[1].dependent, id(g1, 100), "the second revision depends on the first")
    checkEqual(sp.revisions[0].dependent, nil, "the first revision has no dependency")
    checkEqual(sp.revisions[0].roots[1], id(g1, 1), "root references are read")

    let at1 = sp.objects(at: sp.revisions[0]), at2 = sp.objects(at: sp.revisions[1])
    checkEqual(at1.count, 3, "first revision shows its three objects")
    checkEqual(at2.count, 4, "second revision overlays: A, E from the first; B2, D from the second")
    let b1 = at1[id(g1, 2)]!, b2 = at2[id(g1, 2)]!
    checkEqual(b1.properties.bool(0x08001C04), true, "Bold true in revision 1")
    checkEqual(b2.properties.bool(0x08001C04), false, "Bold false overrides in revision 2")
    checkEqual(b1.properties.u16(0x10001C0B), 22, "u16 property")
    checkEqual(b2.properties.u16(0x10001C0B), 30, "overridden u16 property")
    checkEqual(b1.properties.u8(0x0C001C03), 3, "u8 property")
    checkEqual(b1.properties.float(0x14001C14), 1.5, "4-byte property reads as a float")
    checkEqual(b1.properties.string(0x1C001C22), text, "UTF-16 text with surrogates; the trailing NUL is dropped")
    checkEqual(b1.properties.u32(0x1400348B), 7, "an undocumented property is kept")
    checkEqual(b1.properties.objectIDs(0x20001C3F), [id(g2, 9)], "a single object ID resolves through the global ID table")
    checkEqual(sp.rootObject(of: sp.revisions[1])?.jcid, .pageManifest, "rootObject follows the dependency chain")

    let a = at1[id(g1, 1)]!
    checkEqual(a.jcid, .pageManifest, "jcid is read")
    checkEqual(a.properties.objectIDs(0x24001C1F), [id(g1, 2), id(g2, 3)], "an array of object IDs resolves in order")
    checkEqual(a.properties.objectSpaceIDs(0x2C001D63), [id(g1, 7), id(g2, 8)], "object-space IDs resolve through the table")
    let e = at1[id(g1, 4)]!
    checkEqual(e.jcid, JCID(0x00AB_CDEF), "an unknown JCID is kept")
    let sets = e.properties.propertySets(0x40003489)
    checkEqual(sets.count, 2, "an array of property sets")
    checkEqual(sets[0].bool(0x08001C04), true, "first element")
    checkEqual(sets[1].u8(0x0C001C03), 5, "second element")
    checkEqual(e.properties.propertySets(0x44001235).first?.u16(0x10001C0B), 9, "a nested property set")
    check(file.warnings.isEmpty, "a well-formed file produces no warnings: \(file.warnings)")

    // An unresolvable reference does not abort the read; it is reported.
    let dangling = FxObject(oid: compact(1, 1), jcid: 0x6000B, props: [FxProp(pid: 0x20001C3F)], oids: [compact(9, 1)])
    let danglingData = buildStore(FxFile(), space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1)], roots: [(1, g1, 1)], objects: [dangling])])
    let df = try! OneFile(data: danglingData)
    check(df.warnings.contains { $0.contains("could not be resolved") }, "an unresolved ID is reported as a warning")

    // A property set that refers to more objects than its stream holds is skipped, not fatal.
    var tooMany = A; tooMany.oids = [compact(1, 2)]
    let tooManyData = buildStore(FxFile(), space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1), (2, g2)], roots: [(1, g1, 1)], objects: [tooMany, B])])
    let tm = try! OneFile(data: tooManyData)
    check(tm.warnings.contains { $0.contains("more objects") }, "an object with a short object stream is reported")
    checkEqual(tm.objectSpaces[0].objects(at: tm.objectSpaces[0].revisions[0]).count, 1, "…and the other object is still read")

    // File data: reference string, store entry and payload.
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5]
    let fdFile = FxFile()
    let payload = fdFile.blob(fileDataObject(png))
    let storeList = fdFile.list([refNode(0x94, base: 1, ref: payload, extra: guidBytes("{CCCCCCCC-1111-2222-3333-444444444444}"))])
    let pic = fileDataDeclNode(oid: compact(1, 5), jcid: 0x80039, target: "<ifndf>{CCCCCCCC-1111-2222-3333-444444444444}", ext: ".PNG")
    let missing = fileDataDeclNode(oid: compact(1, 6), jcid: 0x80039, target: "<ifndf>{DDDDDDDD-1111-2222-3333-444444444444}", ext: ".png")
    let external = fileDataDeclNode(oid: compact(1, 7), jcid: 0x80039, target: "<file>C:\\x.png", ext: ".png")
    let fdData = buildStore(fdFile, space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1)], roots: [(1, g1, 1)], objects: [], extraNodes: [pic, missing, external])],
        rootExtra: [refNode(0x90, base: 2, ref: storeList)])
    let ff = try! OneFile(data: fdData)
    let fobjs = ff.objectSpaces[0].objects(at: ff.objectSpaces[0].revisions[0])
    let got = ff.fileData(for: fobjs[id(g1, 5)]!)
    checkEqual(got.map { Array($0.data) }, png, "file data payload is found through its store entry")
    checkEqual(got?.ext, "png", "the extension is lower-cased and loses its dot")
    check(ff.fileData(for: fobjs[id(g1, 6)]!) == nil, "a reference with no store entry has no data")
    check(ff.fileData(for: fobjs[id(g1, 7)]!) == nil, "an external file reference is not read")
    check(ff.fileData(for: OneObject(id: id(g1, 99), jcid: .richText, properties: PropertySet(), fileData: nil)) == nil,
          "an object that is not file data has no data")

    // Hostile input (Review Focus 1): every truncation and byte corruption either parses or throws OneStoreError.
    fuzz("object file", data, step: 3) { d in _ = try OneFile(data: d) }
    fuzz("file data file", fdData, step: 3) { d in
        let f = try OneFile(data: d)
        for s in f.objectSpaces { for r in s.revisions { for o in r.declared.values { _ = f.fileData(for: o) } } }
    }
}

/// Opt-in check against real files: set ONE_CORPUS_DIR to a folder of .one files. Prints aggregate counts only.
func corpusChecks() {
    guard let dir = ProcessInfo.processInfo.environment["ONE_CORPUS_DIR"] else { return }
    guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.fileSizeKey]) else {
        check(false, "ONE_CORPUS_DIR is not readable"); return
    }
    var files = 0, parsed = 0, failed = 0, withPages = 0, pages = 0, withWarnings = 0
    var errorKinds: [String: Int] = [:]
    for case let url as URL in walker where url.pathExtension == "one" {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else { continue }
        files += 1
        do {
            let file = try OneFile(data: Data(contentsOf: url, options: .mappedIfSafe))
            parsed += 1
            if !file.warnings.isEmpty { withWarnings += 1 }
            let n = file.objectSpaces.filter { s in s.revisions.contains { s.rootObject(of: $0)?.jcid == .pageManifest } }.count
            pages += n
            if n > 0 { withPages += 1 }
        } catch {
            failed += 1
            errorKinds["\(error)".prefix(40).description, default: 0] += 1
        }
    }
    print("corpus: files=\(files) parsed=\(parsed) failed=\(failed) withPages=\(withPages) pageSpaces=\(pages) filesWithWarnings=\(withWarnings) errors=\(errorKinds)")
    check(failed == 0, "every corpus file parses")
}
```

- [ ] **Step 3: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`cannot find 'OneFile' in scope`).

- [ ] **Step 4: Create `Sources/OneStore/Properties.swift`.**

```swift
import Foundation

/// A PropertyID as MS-ONE lists it: the 31-bit value including its type bits (the bool bit is not part of it).
public typealias PropertyID = UInt32

public struct JCID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public var description: String { "0x" + String(rawValue, radix: 16) }

    public static let section = JCID(0x0006_0007)
    public static let pageSeries = JCID(0x0006_0008)
    public static let page = JCID(0x0006_000B)
    public static let outline = JCID(0x0006_000C)
    public static let outlineElement = JCID(0x0006_000D)
    public static let richText = JCID(0x0006_000E)
    public static let image = JCID(0x0006_0011)
    public static let numberList = JCID(0x0006_0012)
    public static let outlineGroup = JCID(0x0006_0019)
    public static let table = JCID(0x0006_0022)
    public static let tableRow = JCID(0x0006_0023)
    public static let tableCell = JCID(0x0006_0024)
    public static let title = JCID(0x0006_002C)
    public static let embeddedFile = JCID(0x0006_0035)
    public static let pageManifest = JCID(0x0006_0037)
    public static let paragraphStyle = JCID(0x0012_004D)
}

public enum OneValue: Equatable {
    case none
    case bool(Bool)
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)                    // 4-byte data, also used for floats (see PropertySet.float)
    case u64(UInt64)
    case bytes(Data)                    // length-prefixed data, without the length
    case objectIDs([ExtendedGUID])      // one object ID or an array of them
    case objectSpaceIDs([ExtendedGUID])
    case propertySets([PropertySet])    // an array of property sets, or a single nested one
    case other                          // context IDs; not used
}

public struct OneProperty: Equatable {
    public let id: PropertyID
    public let value: OneValue
    public init(_ id: PropertyID, _ value: OneValue) { self.id = id; self.value = value }
}

public enum OneText {
    /// Decodes UTF-16LE bytes (a trailing odd byte is ignored) and removes trailing NUL characters.
    public static func utf16String(_ data: Data) -> String {
        let n = data.count - data.count % 2
        var units: [UInt16] = []
        units.reserveCapacity(n / 2)
        var i = 0
        while i < n {
            units.append(UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8)
            i += 2
        }
        var s = String(decoding: units, as: UTF16.self)
        while s.last == "\0" { s.removeLast() }
        return s
    }
}

public struct PropertySet: Equatable {
    public let properties: [OneProperty]
    public init(_ properties: [OneProperty] = []) { self.properties = properties }

    public subscript(id: PropertyID) -> OneValue? { properties.first { $0.id == id }?.value }

    public func bool(_ id: PropertyID) -> Bool? { if case .bool(let v)? = self[id] { return v }; return nil }
    public func u8(_ id: PropertyID) -> UInt8? { if case .u8(let v)? = self[id] { return v }; return nil }
    public func u16(_ id: PropertyID) -> UInt16? { if case .u16(let v)? = self[id] { return v }; return nil }
    public func u32(_ id: PropertyID) -> UInt32? { if case .u32(let v)? = self[id] { return v }; return nil }
    public func float(_ id: PropertyID) -> Float? { u32(id).map { Float(bitPattern: $0) } }
    public func data(_ id: PropertyID) -> Data? { if case .bytes(let v)? = self[id] { return v }; return nil }
    public func string(_ id: PropertyID) -> String? { data(id).map(OneText.utf16String) }

    /// An array of little-endian UInt32 stored as length-prefixed bytes (for example TextRunIndex).
    public func u32Array(_ id: PropertyID) -> [UInt32]? {
        guard let d = data(id), d.count % 4 == 0 else { return nil }
        var result: [UInt32] = []
        var i = 0
        while i < d.count {
            let b = d.startIndex + i
            result.append(UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24)
            i += 4
        }
        return result
    }

    public func objectIDs(_ id: PropertyID) -> [ExtendedGUID] { if case .objectIDs(let v)? = self[id] { return v }; return [] }
    public func objectSpaceIDs(_ id: PropertyID) -> [ExtendedGUID] { if case .objectSpaceIDs(let v)? = self[id] { return v }; return [] }
    public func propertySets(_ id: PropertyID) -> [PropertySet] { if case .propertySets(let v)? = self[id] { return v }; return [] }
}
```

- [ ] **Step 5: Create `Sources/OneStore/ObjectBlob.swift`.**

```swift
import Foundation

/// Hands out the CompactIDs of an object stream in the order property values consume them.
struct IDStream {
    var items: [UInt32]
    var next = 0
    mutating func take(_ n: Int, at offset: Int) throws -> [UInt32] {
        guard n >= 0, n <= items.count - next else {
            throw OneStoreError.corrupt(offset: offset, reason: "property set refers to more objects than its object stream holds")
        }
        defer { next += n }
        return Array(items[next..<next + n])
    }
}

/// Reads an ObjectSpaceObjectPropSet: the object-ID streams followed by a PropertySet.
enum ObjectBlob {
    static func read(_ r: ByteReader, at start: Int, resolve: (UInt32) -> ExtendedGUID) throws -> PropertySet {
        var o = start
        let oids = try readStream(r, &o)
        var osids: [UInt32] = []
        if !oids.osidAbsent {
            let s = try readStream(r, &o)
            osids = s.ids
            if s.extended { _ = try readStream(r, &o) }       // context IDs are not used
        }
        var oidStream = IDStream(items: oids.ids)
        var osidStream = IDStream(items: osids)
        return try readSet(r, &o, &oidStream, &osidStream, resolve, depth: 0)
    }

    private static func readStream(_ r: ByteReader, _ o: inout Int) throws -> (ids: [UInt32], extended: Bool, osidAbsent: Bool) {
        let h = try r.u32(o)
        let count = Int(h & 0xFF_FFFF)
        guard count <= (r.count - o - 4) / 4 else { throw OneStoreError.corrupt(offset: o, reason: "object stream is longer than the file") }
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        for i in 0..<count { ids.append(try r.u32(o + 4 + 4 * i)) }
        o += 4 + 4 * count
        return (ids, (h >> 30) & 1 == 1, (h >> 31) & 1 == 1)
    }

    private static func readSet(_ r: ByteReader, _ o: inout Int, _ oids: inout IDStream, _ osids: inout IDStream,
                                _ resolve: (UInt32) -> ExtendedGUID, depth: Int) throws -> PropertySet {
        guard depth < 16 else { throw OneStoreError.corrupt(offset: o, reason: "property sets are nested too deeply") }
        let n = Int(try r.u16(o))
        o += 2
        guard n <= (r.count - o) / 4 else { throw OneStoreError.truncated(offset: o) }
        var pids: [UInt32] = []
        pids.reserveCapacity(n)
        for i in 0..<n { pids.append(try r.u32(o + 4 * i)) }
        o += 4 * n
        var props: [OneProperty] = []
        props.reserveCapacity(n)
        for pid in pids {
            let type = Int((pid >> 26) & 0x1F)
            let key = pid & 0x7FFF_FFFF
            let value: OneValue
            switch type {
            case 1:
                value = .none
            case 2:
                value = .bool(pid >> 31 == 1)
            case 3:
                value = .u8(try r.u8(o)); o += 1
            case 4:
                value = .u16(try r.u16(o)); o += 2
            case 5:
                value = .u32(try r.u32(o)); o += 4
            case 6:
                value = .u64(try r.u64(o)); o += 8
            case 7:
                let cb = Int(try r.u32(o))
                guard cb < 0x4000_0000 else { throw OneStoreError.corrupt(offset: o, reason: "property data length is out of range") }
                value = .bytes(try r.slice(o + 4, cb)); o += 4 + cb
            case 8:
                value = .objectIDs(try oids.take(1, at: o).map(resolve))
            case 9:
                let count = Int(try r.u32(o)); o += 4
                value = .objectIDs(try oids.take(count, at: o).map(resolve))
            case 0xA:
                value = .objectSpaceIDs(try osids.take(1, at: o).map(resolve))
            case 0xB:
                let count = Int(try r.u32(o)); o += 4
                value = .objectSpaceIDs(try osids.take(count, at: o).map(resolve))
            case 0xC:
                value = .other
            case 0xD:
                _ = try r.u32(o); o += 4
                value = .other
            case 0x10:
                let count = Int(try r.u32(o)); o += 4
                var sets: [PropertySet] = []
                if count > 0 {
                    guard count <= (r.count - o) / 2 else { throw OneStoreError.truncated(offset: o) }
                    _ = try r.u32(o); o += 4                       // the element PropertyID (type 0x11)
                    for _ in 0..<count { sets.append(try readSet(r, &o, &oids, &osids, resolve, depth: depth + 1)) }
                }
                value = .propertySets(sets)
            case 0x11:
                value = .propertySets([try readSet(r, &o, &oids, &osids, resolve, depth: depth + 1)])
            default:
                throw OneStoreError.corrupt(offset: o, reason: "unknown property type \(type)")
            }
            props.append(OneProperty(key, value))
        }
        return PropertySet(props)
    }
}
```

- [ ] **Step 6: Create `Sources/OneStore/OneFile.swift`.**

```swift
import Foundation

public struct FileDataReference: Equatable {
    public let target: String           // "<ifndf>{GUID}" for data inside this file; "<file>…" and "<invfdo>" are not read
    public let extensionText: String    // for example ".png"
    public init(target: String, extensionText: String) { self.target = target; self.extensionText = extensionText }
}

public struct OneObject {
    public let id: ExtendedGUID
    public let jcid: JCID
    public let properties: PropertySet
    public let fileData: FileDataReference?
    public init(id: ExtendedGUID, jcid: JCID, properties: PropertySet, fileData: FileDataReference?) {
        self.id = id; self.jcid = jcid; self.properties = properties; self.fileData = fileData
    }
}

public struct Revision {
    public let id: ExtendedGUID
    public let dependent: ExtendedGUID?
    public let role: UInt32
    public let roots: [UInt32: ExtendedGUID]        // root role -> root object
    public let declared: [ExtendedGUID: OneObject]  // objects declared by this revision (not its dependencies)
    public init(id: ExtendedGUID, dependent: ExtendedGUID?, role: UInt32, roots: [UInt32: ExtendedGUID],
                declared: [ExtendedGUID: OneObject]) {
        self.id = id; self.dependent = dependent; self.role = role; self.roots = roots; self.declared = declared
    }
}

public struct ObjectSpace {
    public let id: ExtendedGUID
    public let revisions: [Revision]
    public init(id: ExtendedGUID, revisions: [Revision]) { self.id = id; self.revisions = revisions }

    /// The objects visible at `revision`: its own declarations laid over those of the revisions it depends on.
    public func objects(at revision: Revision) -> [ExtendedGUID: OneObject] {
        var byID: [ExtendedGUID: Revision] = [:]
        for r in revisions { byID[r.id] = r }
        var chain: [Revision] = []
        var seen = Set<ExtendedGUID>()
        var current: Revision? = revision
        while let r = current, seen.insert(r.id).inserted {
            chain.append(r)
            current = r.dependent.flatMap { byID[$0] }
        }
        var result: [ExtendedGUID: OneObject] = [:]
        for r in chain.reversed() { result.merge(r.declared) { _, newer in newer } }
        return result
    }

    /// The root object of `revision` for `role` (1 is the default root), or nil.
    public func rootObject(of revision: Revision, role: UInt32 = 1) -> OneObject? {
        guard let id = revision.roots[role] else { return nil }
        return revision.declared[id] ?? objects(at: revision)[id]
    }
}

/// What the importer needs from a file; lets tests supply an in-memory graph instead of bytes.
public protocol OneSource {
    var objectSpaces: [ObjectSpace] { get }
    var warnings: [String] { get }
    func fileData(for object: OneObject) -> (data: Data, ext: String)?
}

public struct OneFile: OneSource {
    public let objectSpaces: [ObjectSpace]
    public let warnings: [String]
    private let reader: ByteReader
    private let fileDataStore: [GUID: ChunkRef]
    private static let fileDataHeader = GUID(string: "{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}")!

    /// Parses a `.one` file. Throws `OneStoreError` for a damaged or unsupported file; anything inside the file
    /// that cannot be read (a bad object, an unresolvable ID) is skipped and reported in `warnings` instead.
    public init(data: Data) throws {
        let store = try OpenedStore(data)
        let builder = StoreBuilder(store: store)
        try builder.run()
        self.objectSpaces = builder.finish()
        self.warnings = builder.warnings
        self.reader = store.reader
        self.fileDataStore = builder.fileDataStore
    }

    /// The bytes of a file data object (an image or attachment) and its lower-case extension, or nil.
    public func fileData(for object: OneObject) -> (data: Data, ext: String)? {
        guard let ref = object.fileData, ref.target.hasPrefix("<ifndf>"),
              let guid = GUID(string: String(ref.target.dropFirst(7))),
              let chunk = fileDataStore[guid], chunk.stp <= UInt64(reader.count) else { return nil }
        let o = Int(chunk.stp)
        do {
            guard try GUID(reader, at: o) == Self.fileDataHeader else { return nil }
            let length = try reader.u64(o + 16)
            guard length <= UInt64(reader.count) else { return nil }
            let bytes = try reader.slice(o + 36, Int(length))       // header 16 + length 8 + unused 4 + reserved 8
            let ext = ref.extensionText.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (bytes, ext)
        } catch {
            return nil
        }
    }
}

/// Walks the node lists once, in order, building object spaces, revisions, global ID tables and objects.
final class StoreBuilder {
    final class RevisionBuilder {
        let id: ExtendedGUID
        let dependent: ExtendedGUID?
        let role: UInt32
        var idTable: [UInt32: GUID] = [:]
        var roots: [UInt32: ExtendedGUID] = [:]
        var declared: [ExtendedGUID: OneObject] = [:]
        var unresolved = 0
        init(id: ExtendedGUID, dependent: ExtendedGUID?, role: UInt32) { self.id = id; self.dependent = dependent; self.role = role }

        /// A CompactID is an index into the global ID table (high 24 bits) and a counter n (low 8 bits).
        func resolve(_ compact: UInt32) -> ExtendedGUID {
            let n = compact & 0xFF, index = compact >> 8
            if let g = idTable[index] { return ExtendedGUID(guid: g, n: n) }
            unresolved += 1
            return ExtendedGUID(guid: .zero, n: n)
        }
    }

    static let maxWarnings = 100
    let store: OpenedStore
    var r: ByteReader { store.reader }
    var warnings: [String]
    var spaceOrder: [ExtendedGUID] = []
    var spaces: [ExtendedGUID: [RevisionBuilder]] = [:]
    var fileDataStore: [GUID: ChunkRef] = [:]
    var currentSpace: ExtendedGUID?
    var currentRevision: RevisionBuilder?
    var visited = Set<UInt64>()

    init(store: OpenedStore) { self.store = store; self.warnings = store.warnings }

    func warn(_ message: String) { if warnings.count < Self.maxWarnings { warnings.append(message) } }

    func run() throws {
        var w: [String] = []
        let root = try store.rootNodes(warnings: &w)
        w.forEach(warn)
        process(root, depth: 0)
        let unresolved = spaces.values.joined().reduce(0) { $0 + $1.unresolved }
        if unresolved > 0 { warn("\(unresolved) object references could not be resolved through their global ID table") }
    }

    func finish() -> [ObjectSpace] {
        spaceOrder.map { id in
            ObjectSpace(id: id, revisions: (spaces[id] ?? []).map { b in
                Revision(id: b.id, dependent: b.dependent, role: b.role, roots: b.roots, declared: b.declared)
            })
        }
    }

    /// Errors inside one node are reported and skipped so one bad object never loses the rest of the file.
    func process(_ nodes: [FileNode], depth: Int) {
        for node in nodes {
            do { try handle(node, depth: depth) }
            catch { warn("node 0x\(String(node.id, radix: 16)) at offset \(node.offset): \(error)") }
        }
    }

    private func handle(_ node: FileNode, depth: Int) throws {
        guard depth < 32 else { throw OneStoreError.corrupt(offset: node.offset, reason: "file node lists are nested too deeply") }
        switch node.id {
        case 0x0C:                                           // ObjectSpaceManifestListStartFND
            let id = try ExtendedGUID(r, at: node.fnd)
            currentSpace = id; currentRevision = nil
            if spaces[id] == nil { spaces[id] = []; spaceOrder.append(id) }
        case 0x1E, 0x1F:                                     // RevisionManifestStart6/7FND
            guard let space = currentSpace else { throw OneStoreError.corrupt(offset: node.offset, reason: "revision outside an object space") }
            let rid = try ExtendedGUID(r, at: node.fnd)
            let dep = try ExtendedGUID(r, at: node.fnd + 20)
            let role = try r.u32(node.fnd + 40)
            let rev = RevisionBuilder(id: rid, dependent: dep.guid.isZero ? nil : dep, role: role)
            spaces[space, default: []].append(rev)
            currentRevision = rev
        case 0x22:                                           // GlobalIdTableStart2FND
            currentRevision?.idTable = [:]
        case 0x24:                                           // GlobalIdTableEntryFNDX
            guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "ID table entry outside a revision") }
            let index = try r.u32(node.fnd)
            rev.idTable[index] = try GUID(r, at: node.fnd + 4)
        case 0x5A:                                           // RootObjectReference3FND
            guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "root reference outside a revision") }
            let role = try r.u32(node.fnd + 20)
            rev.roots[role] = try ExtendedGUID(r, at: node.fnd)
        case 0xA4, 0xA5, 0xC4, 0xC5:                         // object declarations
            try declareObject(node)
        case 0x72, 0x73:                                     // ObjectDeclarationFileData3(Large)RefCountFND
            try declareFileData(node)
        case 0x94:                                           // FileDataStoreObjectReferenceFND
            let (ref, next) = try node.chunkRef(r)
            fileDataStore[try GUID(r, at: next)] = ref
        default:
            break
        }
        if node.baseType == 2 {                              // a reference to another node list
            let (ref, _) = try node.chunkRef(r)
            guard !ref.isNil, visited.insert(ref.stp).inserted else { return }
            var w: [String] = []
            let nested = try store.lists.nodes(from: ref, warnings: &w)
            w.forEach(warn)
            process(nested, depth: depth + 1)
        }
    }

    private func declareObject(_ node: FileNode) throws {
        guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "object declared outside a revision") }
        let (blob, after) = try node.chunkRef(r)
        let oidRaw = try r.u32(after)
        let jcidRaw = try r.u32(after + 4)
        guard !blob.isNil, !blob.isZero, blob.stp < UInt64(r.count) else {
            throw OneStoreError.corrupt(offset: node.offset, reason: "object has no property data")
        }
        let props = try ObjectBlob.read(r, at: Int(blob.stp)) { rev.resolve($0) }
        let id = rev.resolve(oidRaw)
        rev.declared[id] = OneObject(id: id, jcid: JCID(jcidRaw), properties: props, fileData: nil)
    }

    private func declareFileData(_ node: FileNode) throws {
        guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "file data declared outside a revision") }
        let oidRaw = try r.u32(node.fnd)
        let jcidRaw = try r.u32(node.fnd + 4)
        let afterCount = node.fnd + 8 + (node.id == 0x73 ? 4 : 1)    // the reference count is 1 byte, or 4 for the Large form
        let (target, afterTarget) = try readString(at: afterCount, within: node)
        let (ext, _) = try readString(at: afterTarget, within: node)
        let id = rev.resolve(oidRaw)
        rev.declared[id] = OneObject(id: id, jcid: JCID(jcidRaw), properties: PropertySet(),
                                     fileData: FileDataReference(target: target, extensionText: ext))
    }

    /// A StringInStorageBuffer: a 4-byte character count followed by UTF-16 characters.
    private func readString(at o: Int, within node: FileNode) throws -> (String, Int) {
        guard o + 4 <= node.end else { throw OneStoreError.corrupt(offset: o, reason: "string runs past its file node") }
        let cch = Int(try r.u32(o))
        guard cch <= (node.end - o - 4) / 2 else { throw OneStoreError.corrupt(offset: o, reason: "string runs past its file node") }
        return (OneText.utf16String(try r.slice(o + 4, cch * 2)), o + 4 + cch * 2)
    }
}
```

- [ ] **Step 7: Run to verify the checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED`. Then run the opt-in corpus check against the user's backups, if they are available, and report only the printed aggregate line: `ONE_CORPUS_DIR="$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Application Support/Microsoft User Data/OneNote/15.0/Backup" swift run Checks`. Expected: `parsed` equals `files` and `failed=0`. Never paste file names, paths beyond the folder, or content into the report.

- [ ] **Step 8: Commit.**

```bash
git add Sources
git commit -m "feat(onestore): property sets, global IDs, revisions and OneFile" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

### Task 4: `OneImport` text mapping (report, charsets, styles, paragraphs)

**Files:**
- Create: `Sources/OneImport/ImportReport.swift`, `Sources/OneImport/PropertyIDs.swift`, `Sources/OneImport/ObjectGraph.swift`, `Sources/OneImport/Charset.swift`, `Sources/OneImport/TextMapping.swift`, `Sources/Checks/OneImportChecks.swift`
- Modify: `Package.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `OneStore` (`OneObject`, `PropertySet`, `PropertyID`, `JCID`, `ExtendedGUID`, `GUID`, `OneText`), `PageModel` (`Paragraph`, `Run`, `RunStyle`, `Alignment`, `ListStyle`).
- Produces (internal unless marked public):
  - `public struct ImportReport: Codable, Equatable` with counters and `mutating imported(_:_:)`, `skipped(_:)`, `ignored(_:)`, `approximated(_:_:)`, `noteIgnoredProperties(of:consumed:)`, `merge(_:)`.
  - `enum PID` (property ID constants and `consumedBy…` sets).
  - `struct ObjectGraph { objects; object(_:); children(of:_:report:) }`.
  - `enum CharsetDecoder { decode(_:charset:) -> (text, usedFallback) }`, `enum ColorRef { hex(_:) -> String? }`.
  - `enum StyleMapper { apply(_:to:), headingLevel(named:) }`, `struct ParagraphMapper { listStyle(of:), paragraph(richText:indent:list:report:) }`.

- [ ] **Step 1: Edit `Package.swift`.** Add the `OneImport` target and let `Checks` depend on it:

```swift
        .target(name: "OneImport", dependencies: ["PageModel", "OneStore"]),
```
(next to the other `.target` lines) and change the `Checks` line to:

```swift
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store", "OneStore", "OneImport", "CanvasKit"]),
```

- [ ] **Step 2: Write the failing checks** in `Sources/Checks/OneImportChecks.swift`, and call `oneImportTextChecks()` from `main.swift`:

```swift
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
```

- [ ] **Step 3: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`cannot find 'ImportReport' in scope`).

- [ ] **Step 4: Create `Sources/OneImport/ImportReport.swift`.**

```swift
import Foundation
import OneStore

/// What an import did, in counts only: nothing here is note content.
public struct ImportReport: Codable, Equatable {
    public var pagesTotal = 0
    public var pagesImported = 0
    public var pagesFailed = 0
    public var cancelled = false
    public var objectsImported: [String: Int] = [:]        // "text", "paragraph", "image", "table", "attachment"
    public var skippedObjectTypes: [String: Int] = [:]     // JCID in hex -> count
    public var ignoredProperties: [String: Int] = [:]      // PropertyID in hex -> count
    public var approximations: [String: Int] = [:]         // named approximations -> count
    public var warnings: [String] = []

    public init() {}

    mutating func imported(_ kind: String, _ n: Int = 1) { objectsImported[kind, default: 0] += n }
    mutating func skipped(_ jcid: JCID) { skippedObjectTypes[jcid.description, default: 0] += 1 }
    mutating func ignored(_ id: PropertyID) { ignoredProperties["0x" + String(id, radix: 16), default: 0] += 1 }
    mutating func approximated(_ key: String, _ n: Int = 1) { approximations[key, default: 0] += n }

    /// Counts every property of `object` that the importer does not read.
    mutating func noteIgnoredProperties(of object: OneObject, consumed: Set<PropertyID>) {
        for p in object.properties.properties where !consumed.contains(p.id) { ignored(p.id) }
    }

    mutating func merge(_ other: ImportReport) {
        pagesTotal += other.pagesTotal; pagesImported += other.pagesImported; pagesFailed += other.pagesFailed
        cancelled = cancelled || other.cancelled
        for (k, v) in other.objectsImported { objectsImported[k, default: 0] += v }
        for (k, v) in other.skippedObjectTypes { skippedObjectTypes[k, default: 0] += v }
        for (k, v) in other.ignoredProperties { ignoredProperties[k, default: 0] += v }
        for (k, v) in other.approximations { approximations[k, default: 0] += v }
        warnings += other.warnings
    }
}
```

- [ ] **Step 4b: Create `Sources/OneImport/PropertyIDs.swift`.** Every value comes from the MS-ONE property table.

```swift
import OneStore

/// PropertyID constants (MS-ONE section 2.1.12) and the sets of properties each mapper reads.
enum PID {
    // layout
    static let offsetH: PropertyID = 0x14001C14           // OffsetFromParentHoriz
    static let offsetV: PropertyID = 0x14001C15           // OffsetFromParentVert
    static let maxWidth: PropertyID = 0x14001C1B          // LayoutMaxWidth
    static let maxHeight: PropertyID = 0x14001C1C         // LayoutMaxHeight
    static let reservedWidth: PropertyID = 0x14001CDB     // LayoutOutlineReservedWidth
    // structure
    static let elementChildren: PropertyID = 0x24001C20
    static let contentChildren: PropertyID = 0x24001C1F
    static let listNodes: PropertyID = 0x24001C26
    static let childLevel: PropertyID = 0x0C001C03        // OutlineElementChildLevel
    static let childGraphSpaces: PropertyID = 0x2C001D63  // ChildGraphSpaceElementNodes (object-space IDs)
    // text
    static let richUnicode: PropertyID = 0x1C001C22
    static let richAscii: PropertyID = 0x1C003498
    static let runIndex: PropertyID = 0x1C001E12
    static let runFormatting: PropertyID = 0x24001E13
    static let paragraphStyle: PropertyID = 0x2000342C
    static let paragraphStyleId: PropertyID = 0x1C00345A
    static let paragraphAlignment: PropertyID = 0x0C003477
    static let isTitleText: PropertyID = 0x08001CB4
    static let isTitleDate: PropertyID = 0x08001CB5
    static let isTitleTime: PropertyID = 0x08001C87
    static let numberListFormat: PropertyID = 0x1C001C1A
    // run style
    static let bold: PropertyID = 0x08001C04
    static let italic: PropertyID = 0x08001C05
    static let underline: PropertyID = 0x08001C06
    static let strikethrough: PropertyID = 0x08001C07
    static let superscript: PropertyID = 0x08001C08
    static let subscriptText: PropertyID = 0x08001C09
    static let font: PropertyID = 0x1C001C0A
    static let fontSize: PropertyID = 0x10001C0B          // half-points
    static let fontColor: PropertyID = 0x14001C0C         // COLORREF
    static let highlight: PropertyID = 0x14001C0D         // COLORREF
    static let hyperlink: PropertyID = 0x08001E14
    static let hyperlinkURL: PropertyID = 0x1C001E20      // WzHyperlinkUrl
    static let charset: PropertyID = 0x0C001D01
    // objects
    static let pictureContainer: PropertyID = 0x20001C3F
    static let webPictureContainer: PropertyID = 0x200034C8
    static let imageAltText: PropertyID = 0x1C001E58
    static let tableColumnWidths: PropertyID = 0x1C001D66
    static let tableBordersVisible: PropertyID = 0x08001D5E
    static let embeddedFileContainer: PropertyID = 0x20001D9B
    static let embeddedFileName: PropertyID = 0x1C001D9C
    static let pageLevel: PropertyID = 0x14001DFF

    static let consumedByRichText: Set<PropertyID> = [richUnicode, richAscii, runIndex, runFormatting, paragraphStyle,
                                                      paragraphAlignment, isTitleText, isTitleDate, isTitleTime]
    static let consumedByStyle: Set<PropertyID> = [bold, italic, underline, strikethrough, superscript, subscriptText, font,
                                                   fontSize, fontColor, highlight, hyperlink, hyperlinkURL, charset,
                                                   paragraphStyleId, paragraphAlignment]
    static let consumedByOutline: Set<PropertyID> = [offsetH, offsetV, maxWidth, reservedWidth, elementChildren]
    static let consumedByElement: Set<PropertyID> = [contentChildren, elementChildren, listNodes]
    static let consumedByNumberList: Set<PropertyID> = [numberListFormat]
    static let consumedByImage: Set<PropertyID> = [offsetH, offsetV, maxWidth, maxHeight, pictureContainer, webPictureContainer, imageAltText]
    static let consumedByTable: Set<PropertyID> = [offsetH, offsetV, elementChildren, tableColumnWidths, tableBordersVisible]
    static let consumedByAttachment: Set<PropertyID> = [offsetH, offsetV, embeddedFileContainer, embeddedFileName]
    static let consumedByPage: Set<PropertyID> = [elementChildren]
}
```

- [ ] **Step 4c: Create `Sources/OneImport/ObjectGraph.swift`.**

```swift
import OneStore

/// A snapshot of the objects visible at one revision, with child lookup.
struct ObjectGraph {
    let objects: [ExtendedGUID: OneObject]

    func object(_ id: ExtendedGUID) -> OneObject? { objects[id] }

    /// The objects an object-ID property refers to; IDs with no object are counted in the report and skipped.
    func children(of parent: OneObject, _ id: PropertyID, report: inout ImportReport) -> [OneObject] {
        var result: [OneObject] = []
        for oid in parent.properties.objectIDs(id) {
            if let o = objects[oid] { result.append(o) } else { report.approximated("unresolvedReference") }
        }
        return result
    }
}
```

- [ ] **Step 4d: Create `Sources/OneImport/Charset.swift`.**

```swift
import Foundation
import CoreFoundation

enum CharsetDecoder {
    /// CFStringEncoding values for the character sets MS-ONE's Charset property can name (section 2.3).
    private static let cfEncodings: [UInt8: UInt32] = [
        0: 0x0500, 1: 0x0500, 2: 0x0500,     // ANSI, default and symbol: Windows Latin 1 (1252)
        128: 0x0420,                          // Shift-JIS (932)
        129: 0x0422,                          // Hangul (949)
        130: 0x0510,                          // Johab (1361)
        134: 0x0421,                          // GB2312 (936)
        136: 0x0423,                          // Big5 (950)
        161: 0x0503,                          // Greek (1253)
        162: 0x0504,                          // Turkish (1254)
        163: 0x0508,                          // Vietnamese (1258)
        177: 0x0505,                          // Hebrew (1255)
        178: 0x0506,                          // Arabic (1256)
        186: 0x0507,                          // Baltic (1257)
        204: 0x0502,                          // Russian (1251)
        222: 0x041D,                          // Thai (874)
        238: 0x0501,                          // Eastern European (1250)
        255: 0x0400,                          // OEM: DOS Latin US (437)
    ]

    private static func encoding(cf raw: UInt32) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(raw))
    }

    /// Decodes 8-bit text with the named charset (nil means ANSI). `usedFallback` is true when the charset is unknown
    /// or the bytes were not valid in it, in which case Windows-1252 (then ISO Latin 1) is used. Trailing NULs are removed.
    static func decode(_ data: Data, charset: UInt8?) -> (text: String, usedFallback: Bool) {
        let code = charset ?? 0
        var known = true
        var encoding: String.Encoding?
        if code == 77 { encoding = .macOSRoman }
        else if let raw = cfEncodings[code] { encoding = Self.encoding(cf: raw) }
        else { known = false }
        var result: String?
        var fallback = !known
        if let encoding, let s = String(data: data, encoding: encoding) { result = s }
        if result == nil {
            fallback = true
            result = String(data: data, encoding: Self.encoding(cf: 0x0500)) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        var text = result ?? ""
        while text.last == "\0" { text.removeLast() }
        return (text, fallback)
    }
}

enum ColorRef {
    /// A COLORREF (0x00BBGGRR) as "#RRGGBB"; nil for the automatic colour (0xFF000000) or an invalid value.
    static func hex(_ v: UInt32) -> String? {
        guard v <= 0x00FF_FFFF else { return nil }
        return String(format: "#%02X%02X%02X", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF)
    }
}
```

- [ ] **Step 4e: Create `Sources/OneImport/TextMapping.swift`.**

```swift
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

struct ParagraphMapper {
    let graph: ObjectGraph

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
```

- [ ] **Step 5: Run to verify the checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED`. If a charset check fails because `CFStringConvertEncodingToNSStringEncoding` rejects a value, check the value against the CoreFoundation `CFStringEncodings` enum (for example `CFStringEncodings.windowsLatin1.rawValue` is `0x0500`) and correct the table, not the check.

- [ ] **Step 6: Commit.**

```bash
git add Package.swift Sources
git commit -m "feat(import): charsets, run styles and paragraph mapping" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

### Task 5: `OneImport` layout (page mapper, flattening, importer)

**Files:**
- Create: `Sources/OneImport/PageMapper.swift`, `Sources/OneImport/OneImporter.swift`
- Modify: `Sources/Checks/OneImportChecks.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: Task 3's `OneSource`, `ObjectSpace`, `Revision`, `OneObject`; Task 4's `ObjectGraph`, `ParagraphMapper`, `PID`, `ImportReport`; `PageModel`'s `TextMeasuring`, `Page`, `PageObject`.
- Produces:
  - `public struct ImportedAsset { name: String; data: Data }`
  - `public struct ImportResult { sectionName: String; pages: [Page]; assets: [ImportedAsset]; report: ImportReport }`
  - `public struct OneImporter { init(measurer: TextMeasuring); importSection(from: OneSource, name: String, isCancelled: () -> Bool = { false }) -> ImportResult }`
  - internal `final class AssetSink`, `final class PageMapper` (`mapPage(_:) -> Page`, `report`).

- [ ] **Step 1: Write the failing checks.** Append to `Sources/Checks/OneImportChecks.swift` and call `oneImportLayoutChecks()` from `main.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`cannot find 'AssetSink' in scope`).

- [ ] **Step 3: Create `Sources/OneImport/PageMapper.swift`.**

```swift
import Foundation
import OneStore
import PageModel

/// Collects asset files during an import, storing each source object's bytes once.
final class AssetSink {
    private(set) var items: [ImportedAsset] = []
    private var byObject: [ExtendedGUID: String] = [:]

    func add(object id: ExtendedGUID, data: Data, ext: String) -> String {
        if let name = byObject[id] { return name }
        let name = AssetName.make(ext: ext)
        items.append(ImportedAsset(name: name, data: data))
        byObject[id] = name
        return name
    }
}

/// Maps one page's object graph to a `Page`, flattening outlines around inline images, tables and attachments.
final class PageMapper {
    static let unit = 36.0                       // points per half-inch layout unit
    static let defaultOutlineWidth = 432.0
    static let indentStep = 24.0
    static let attachmentSize = (width: 120.0, height: 60.0)
    static let maxDepth = 64

    let graph: ObjectGraph
    let measurer: TextMeasuring
    let assets: (OneObject) -> (data: Data, ext: String)?
    let sink: AssetSink
    var report = ImportReport()
    private let paragraphs: ParagraphMapper

    init(graph: ObjectGraph, measurer: TextMeasuring, assets: @escaping (OneObject) -> (data: Data, ext: String)?, sink: AssetSink) {
        self.graph = graph; self.measurer = measurer; self.assets = assets; self.sink = sink
        self.paragraphs = ParagraphMapper(graph: graph)
    }

    func mapPage(_ page: OneObject) -> Page {
        report.noteIgnoredProperties(of: page, consumed: PID.consumedByPage)
        var title = ""
        var objects: [PageObject] = []
        for child in graph.children(of: page, PID.elementChildren, report: &report) {
            switch child.jcid {
            case .title:
                title = mapTitle(child)
            case .outline:
                objects += mapOutline(child)
            case .image, .table, .embeddedFile:
                let x = Double(child.properties.float(PID.offsetH) ?? 0) * Self.unit
                let y = Double(child.properties.float(PID.offsetV) ?? 0) * Self.unit
                if let object = mapBlock(child, x: x, y: y) { objects.append(object) }
            default:
                report.skipped(child.jcid)
            }
        }
        var result = Page(id: UUID(), title: title.isEmpty ? "Untitled Page" : title, objects: objects)
        result.relayout(using: measurer)
        return result
    }

    // MARK: title

    /// The title text; date and time lines are dropped (and counted). Style counters from the title are not kept.
    private func mapTitle(_ title: OneObject) -> String {
        var scratch = ImportReport()
        var lines: [String] = []
        for outline in graph.children(of: title, PID.elementChildren, report: &scratch) where outline.jcid == .outline {
            for element in graph.children(of: outline, PID.elementChildren, report: &scratch) {
                for content in graph.children(of: element, PID.contentChildren, report: &scratch) where content.jcid == .richText {
                    if content.properties.bool(PID.isTitleDate) == true || content.properties.bool(PID.isTitleTime) == true {
                        report.approximated("titleDateDropped")
                        continue
                    }
                    let p = paragraphs.paragraph(richText: content, indent: 0, list: .none, report: &scratch)
                    let text = p.runs.map(\.text).joined()
                    if !text.isEmpty { lines.append(text) }
                }
            }
        }
        if let n = scratch.approximations["charsetFallback"], n > 0 { report.approximated("charsetFallback", n) }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: outlines

    private func mapOutline(_ outline: OneObject) -> [PageObject] {
        report.noteIgnoredProperties(of: outline, consumed: PID.consumedByOutline)
        let p = outline.properties
        if p.float(PID.offsetH) == nil || p.float(PID.offsetV) == nil { report.approximated("outlineWithoutPosition") }
        let x = Double(p.float(PID.offsetH) ?? 0) * Self.unit
        var y = Double(p.float(PID.offsetV) ?? 0) * Self.unit
        let width = (p.float(PID.maxWidth) ?? p.float(PID.reservedWidth)).map { Double($0) * Self.unit } ?? Self.defaultOutlineWidth
        var out: [PageObject] = []
        var pending: [Paragraph] = []
        var visited = Set<ExtendedGUID>()

        func flush() {
            guard !pending.isEmpty else { return }
            let h = max(measurer.height(of: pending, width: width), Page.minContainerHeight)
            out.append(.text(TextContainer(id: UUID(), frame: Frame(x: x, y: y, width: width, height: h), paragraphs: pending)))
            report.imported("text")
            report.imported("paragraph", pending.count)
            y += h
            pending = []
        }

        func walk(_ element: OneObject, depth: Int) {
            guard depth < Self.maxDepth, visited.insert(element.id).inserted else {
                report.approximated("elementLoopOrTooDeep")
                return
            }
            report.noteIgnoredProperties(of: element, consumed: PID.consumedByElement)
            var list: ListStyle = .none
            if let node = graph.children(of: element, PID.listNodes, report: &report).first {
                report.noteIgnoredProperties(of: node, consumed: PID.consumedByNumberList)
                list = ParagraphMapper.listStyle(of: node)
            }
            let indent = min(depth, Paragraph.maxIndent)
            for content in graph.children(of: element, PID.contentChildren, report: &report) {
                switch content.jcid {
                case .richText:
                    pending.append(paragraphs.paragraph(richText: content, indent: indent, list: list, report: &report))
                case .image, .table, .embeddedFile:
                    flush()
                    if let object = mapBlock(content, x: x + Double(indent) * Self.indentStep, y: y) {
                        out.append(object)
                        y += object.frame.height
                    }
                default:
                    report.skipped(content.jcid)
                }
            }
            for child in graph.children(of: element, PID.elementChildren, report: &report) {
                if child.jcid == .outlineElement { walk(child, depth: depth + 1) } else { report.skipped(child.jcid) }
            }
        }

        for element in graph.children(of: outline, PID.elementChildren, report: &report) {
            switch element.jcid {
            case .outlineElement:
                walk(element, depth: 0)
            case .outlineGroup:
                for inner in graph.children(of: element, PID.elementChildren, report: &report) {
                    if inner.jcid == .outlineElement { walk(inner, depth: 0) } else { report.skipped(inner.jcid) }
                }
            default:
                report.skipped(element.jcid)
            }
        }
        flush()
        return out
    }

    // MARK: images, tables, attachments

    private func mapBlock(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        switch node.jcid {
        case .image: return mapImage(node, x: x, y: y)
        case .table: return mapTable(node, x: x, y: y)
        default: return mapAttachment(node, x: x, y: y)
        }
    }

    private func mapImage(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByImage)
        let p = node.properties
        var container = graph.children(of: node, PID.pictureContainer, report: &report).first
        if container == nil { container = graph.children(of: node, PID.webPictureContainer, report: &report).first }
        guard let container, let file = assets(container) else {
            report.approximated("imageDataMissing")
            return nil
        }
        var width = p.float(PID.maxWidth).map { Double($0) * Self.unit } ?? 100
        if width <= 0 { width = 100 }
        var height = p.float(PID.maxHeight).map { Double($0) * Self.unit } ?? width
        if height <= 0 { height = width }
        let name = sink.add(object: container.id, data: file.data, ext: file.ext)
        let alt = p.string(PID.imageAltText).flatMap { $0.isEmpty ? nil : $0 }
        report.imported("image")
        return .image(ImageObject(id: UUID(), frame: Frame(x: x, y: y, width: width, height: height), asset: name, altText: alt))
    }

    private func mapTable(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByTable)
        var rows: [[TableCell]] = []
        for rowNode in graph.children(of: node, PID.elementChildren, report: &report) {
            guard rowNode.jcid == .tableRow else { report.skipped(rowNode.jcid); continue }
            var cells: [TableCell] = []
            for cellNode in graph.children(of: rowNode, PID.elementChildren, report: &report) {
                guard cellNode.jcid == .tableCell else { report.skipped(cellNode.jcid); continue }
                cells.append(TableCell(paragraphs: mapCellParagraphs(cellNode)))
            }
            rows.append(cells)
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { report.approximated("emptyTableSkipped"); return nil }
        var widths = Self.columnWidths(node.properties.data(PID.tableColumnWidths))
        if widths.count != columns {
            report.approximated("tableColumnWidthsAdjusted")
            widths = Array(widths.prefix(columns)) + [Double](repeating: 100, count: max(0, columns - widths.count))
        }
        var table = TableObject(id: UUID(), frame: Frame(x: x, y: y, width: 0, height: 0), columnWidths: widths, rows: rows,
                                bordersVisible: node.properties.bool(PID.tableBordersVisible) ?? true)
        table.frame.width = widths.reduce(0, +)
        table.frame.height = table.rowHeights(using: measurer).reduce(0, +)
        report.imported("table")
        return .table(table)
    }

    /// TableColumnWidths: one byte with the column count, then that many 4-byte floats (half-inch units).
    private static func columnWidths(_ data: Data?) -> [Double] {
        guard let d = data, let count = d.first.map(Int.init), d.count >= 1 + 4 * count else { return [] }
        return (0..<count).map { i in
            let b = d.startIndex + 1 + 4 * i
            let bits = UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
            return max(Double(Float(bitPattern: bits)) * unit, 1)
        }
    }

    private func mapCellParagraphs(_ cell: OneObject) -> [Paragraph] {
        var result: [Paragraph] = []
        var visited = Set<ExtendedGUID>()
        func walk(_ element: OneObject, depth: Int) {
            guard depth < Self.maxDepth, visited.insert(element.id).inserted else {
                report.approximated("elementLoopOrTooDeep")
                return
            }
            var list: ListStyle = .none
            if let node = graph.children(of: element, PID.listNodes, report: &report).first { list = ParagraphMapper.listStyle(of: node) }
            for content in graph.children(of: element, PID.contentChildren, report: &report) {
                switch content.jcid {
                case .richText:
                    result.append(paragraphs.paragraph(richText: content, indent: min(depth, Paragraph.maxIndent), list: list, report: &report))
                case .image, .table, .embeddedFile:
                    report.approximated("cellContentDropped")
                default:
                    report.skipped(content.jcid)
                }
            }
            for child in graph.children(of: element, PID.elementChildren, report: &report) {
                if child.jcid == .outlineElement { walk(child, depth: depth + 1) } else { report.skipped(child.jcid) }
            }
        }
        for element in graph.children(of: cell, PID.elementChildren, report: &report) {
            if element.jcid == .outlineElement { walk(element, depth: 0) } else { report.skipped(element.jcid) }
        }
        return result
    }

    private func mapAttachment(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByAttachment)
        guard let container = graph.children(of: node, PID.embeddedFileContainer, report: &report).first,
              let file = assets(container) else {
            report.approximated("attachmentDataMissing")
            return nil
        }
        let name = sink.add(object: container.id, data: file.data, ext: file.ext)
        let display = node.properties.string(PID.embeddedFileName).flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment"
        report.imported("attachment")
        return .attachment(AttachmentObject(id: UUID(), frame: Frame(x: x, y: y, width: Self.attachmentSize.width,
                                                                      height: Self.attachmentSize.height),
                                            asset: name, displayName: display))
    }
}
```

- [ ] **Step 4: Create `Sources/OneImport/OneImporter.swift`.**

```swift
import Foundation
import OneStore
import PageModel

public struct ImportedAsset {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public struct ImportResult {
    public var sectionName: String
    public var pages: [Page]
    public var assets: [ImportedAsset]
    public var report: ImportReport
}

public struct OneImporter {
    public let measurer: TextMeasuring
    public init(measurer: TextMeasuring) { self.measurer = measurer }

    /// Maps every page of `source` into one section's worth of pages. A page that cannot be resolved is counted and
    /// skipped. `isCancelled` is asked before each page; when it says yes the result is partial and flagged.
    public func importSection(from source: OneSource, name: String, isCancelled: () -> Bool = { false }) -> ImportResult {
        var report = ImportReport()
        report.warnings = Array(source.warnings.prefix(20))
        let sink = AssetSink()

        // Pick, per object space, the newest revision whose default root is a PageManifest (a page) or a Section.
        struct PageSpace { let id: ExtendedGUID; let revision: Revision; let objects: [ExtendedGUID: OneObject] }
        var pageSpaces: [PageSpace] = []
        var section: (revision: Revision, objects: [ExtendedGUID: OneObject])?
        for space in source.objectSpaces {
            var newestPage: Revision?
            var newestSection: Revision?
            for rev in space.revisions {
                let kind = space.rootObject(of: rev)?.jcid
                if kind == .pageManifest { newestPage = rev } else if kind == .section { newestSection = rev }
            }
            if let rev = newestPage { pageSpaces.append(PageSpace(id: space.id, revision: rev, objects: space.objects(at: rev))) }
            if let rev = newestSection { section = (rev, space.objects(at: rev)) }
        }

        // Display order comes from the section's page series.
        var order: [ExtendedGUID] = []
        if let section, let rootID = section.revision.roots[1], let root = section.objects[rootID] {
            var scratch = ImportReport()
            let graph = ObjectGraph(objects: section.objects)
            for series in graph.children(of: root, PID.elementChildren, report: &scratch) where series.jcid == .pageSeries {
                order += series.properties.objectSpaceIDs(PID.childGraphSpaces)
            }
        }
        var rank: [ExtendedGUID: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        let ordered = pageSpaces.enumerated().sorted { l, r in
            let lr = rank[l.element.id] ?? Int.max, rr = rank[r.element.id] ?? Int.max
            return lr != rr ? lr < rr : l.offset < r.offset
        }.map(\.element)
        let unranked = pageSpaces.filter { rank[$0.id] == nil }.count
        if unranked > 0 && (pageSpaces.count > 1 || !order.isEmpty) { report.approximated("pageOrderUnknown", unranked) }

        var pages: [Page] = []
        for entry in ordered {
            if isCancelled() { report.cancelled = true; break }
            report.pagesTotal += 1
            let graph = ObjectGraph(objects: entry.objects)
            var scratch = ImportReport()
            guard let manifestID = entry.revision.roots[1], let manifest = entry.objects[manifestID],
                  let pageObject = graph.children(of: manifest, PID.contentChildren, report: &scratch).first(where: { $0.jcid == .page }) else {
                report.pagesFailed += 1
                continue
            }
            let mapper = PageMapper(graph: graph, measurer: measurer, assets: { source.fileData(for: $0) }, sink: sink)
            pages.append(mapper.mapPage(pageObject))
            report.merge(mapper.report)
            report.pagesImported += 1
            if (pageObject.properties.u32(PID.pageLevel) ?? 0) > 0 { report.approximated("subpageLevelIgnored") }
        }
        return ImportResult(sectionName: name, pages: pages, assets: sink.items, report: report)
    }
}
```

- [ ] **Step 5: Run to verify the checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED`. Then, if the user's backups are available, run the opt-in importer check described in Step 6 and report only aggregate numbers.

- [ ] **Step 6: Add an opt-in real-file import check.** In `Sources/Checks/OneImportChecks.swift` add this function and call it from `main.swift` after `corpusChecks()`. It maps every corpus file with a fixed measurer and prints aggregate counts only:

```swift
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
```

Run it: `ONE_CORPUS_DIR="$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Application Support/Microsoft User Data/OneNote/15.0/Backup" swift run Checks`. Report the printed aggregate line only. If `filesWithUnknownPageOrder` is not close to zero, the page-series order lookup does not match the file, so say so in the report rather than hiding it (the section-order rule is the least verified rule in this task).

- [ ] **Step 7: Commit.**

```bash
git add Sources
git commit -m "feat(import): page mapper, flattening and the section importer" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

### Task 6: App: canvas objects, section picker, `File > Import .one…`

**Files:**
- Create: `Sources/CanvasKit/ObjectView.swift`, `Sources/CanvasKit/ImportRunner.swift`
- Modify: `Package.swift`, `Sources/CanvasKit/TextKitMeasurer.swift`, `Sources/CanvasKit/PageView.swift`, `Sources/CanvasKit/PageController.swift`, `Sources/CanvasKit/AppShell.swift`, `Sources/Checks/BridgeChecks.swift`

**Interfaces:**
- Consumes: Tasks 1–5 (`PageObject` cases, `NotebookPackage.writeAsset/addSection/loadAsset`, `OneFile`, `OneImporter`, `ImportResult`, `ImportReport`, `TextMeasuring.textHeight`).
- Produces:
  - `TextKitMeasurer.textHeight(of:width:)`.
  - `final class ObjectView: NSView` (move strip + read-only content), `class ObjectContentView` and `ImageContentView`, `TableContentView`, `AttachmentContentView`.
  - `PageController.init(page:assets:)`, object wiring, copy/paste of any `PageObject`.
  - `ImportRunner.run(file:into:cancel:completion:)`, `ImportCancelFlag`, `ImportOutcome`, `MainThreadMeasurer`.
  - AppShell: `importOne(_:)`, `pickSection(_:)`, progress sheet, summary alert.

- [ ] **Step 1: Write the failing measurer checks.** In `Sources/Checks/BridgeChecks.swift`, inside `bridgeChecks()` after the existing measurer checks, add:

```swift
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
```

(`run(_:)` is the private helper already defined at the top of `BridgeChecks.swift`.)

- [ ] **Step 2: Run to verify it fails.** Run: `swift run Checks`. Expected: build FAILS (`value of type 'TextKitMeasurer' has no member 'textHeight'`).

- [ ] **Step 3: Edit `Package.swift`:** CanvasKit now depends on the readers:

```swift
        .target(name: "CanvasKit", dependencies: ["PageModel", "Store", "OneStore", "OneImport"]),
```

- [ ] **Step 4: Replace `Sources/CanvasKit/TextKitMeasurer.swift`:**

```swift
import AppKit
import PageModel

enum Metrics {
    static let handleHeight: Double = 14
    static let inset: Double = 6
    static let gripWidth: Double = 8
}

public struct TextKitMeasurer: TextMeasuring {
    public init() {}

    /// Height of the text alone laid out at exactly `width` (no container chrome); at least one base-font line,
    /// and it includes the extra fragment after a trailing newline.
    public func textHeight(of paragraphs: [Paragraph], width: Double) -> Double {
        let storage = NSTextStorage(attributedString: AttributedBridge.attributed(from: paragraphs))
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let line = Double(layout.defaultLineHeight(for: NSFont.systemFont(ofSize: AttributedBridge.baseSize)))
        let extra = Double(layout.extraLineFragmentRect.height)
        return max(Double(layout.usedRect(for: container).height), line, extra)
    }

    /// A text container: the handle strip, the insets and the grip around text laid out in the remaining width.
    public func height(of paragraphs: [Paragraph], width: Double) -> Double {
        Metrics.handleHeight + Metrics.inset * 2
            + textHeight(of: paragraphs, width: max(width - Metrics.inset - Metrics.gripWidth, 1))
    }
}
```

- [ ] **Step 5: Run to verify the checks pass.** Run: `swift run Checks`. Expected: `ALL PASSED`.

- [ ] **Step 6: Create `Sources/CanvasKit/ObjectView.swift`.**

```swift
import AppKit
import PageModel
import UniformTypeIdentifiers

/// The content of an image, table or attachment: drawn read-only, and never takes the mouse itself.
class ObjectContentView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ object: PageObject, assets: (String) -> Data?) {}

    func drawCentered(_ text: String, in rect: NSRect, color: NSColor = .secondaryLabelColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

final class ImageContentView: ObjectContentView {
    private var image: NSImage?
    private var loadedAsset: String?

    override func update(_ object: PageObject, assets: (String) -> Data?) {
        guard case .image(let o) = object else { return }
        if o.asset != loadedAsset {
            loadedAsset = o.asset
            image = assets(o.asset).flatMap { NSImage(data: $0) }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            NSColor.systemGray.withAlphaComponent(0.15).setFill()
            bounds.fill()
            drawCentered("Image unavailable", in: bounds)
            return
        }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

final class TableContentView: ObjectContentView {
    private var table: TableObject?
    private let measurer = TextKitMeasurer()

    override func update(_ object: PageObject, assets: (String) -> Data?) {
        guard case .table(let t) = object else { return }
        table = t
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = table else { return }
        let heights = t.rowHeights(using: measurer)
        var y = 0.0
        for (r, row) in t.rows.enumerated() {
            var x = 0.0
            for c in 0..<t.columnWidths.count {
                let w = t.columnWidths[c]
                let cell = NSRect(x: x, y: y, width: w, height: heights[r])
                if t.bordersVisible {
                    NSColor.gray.setStroke()
                    NSBezierPath(rect: cell).stroke()
                }
                if c < row.count, !row[c].paragraphs.isEmpty {
                    let text = AttributedBridge.attributed(from: row[c].paragraphs)
                    text.draw(with: cell.insetBy(dx: TableObject.cellPadding, dy: TableObject.cellPadding),
                              options: [.usesLineFragmentOrigin])
                }
                x += w
            }
            y += heights[r]
        }
    }
}

final class AttachmentContentView: ObjectContentView {
    private var name = ""
    private var ext = ""

    override func update(_ object: PageObject, assets: (String) -> Data?) {
        guard case .attachment(let a) = object else { return }
        name = a.displayName
        ext = (a.asset as NSString).pathExtension
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGray.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.draw(in: NSRect(x: bounds.midX - 16, y: 8, width: 32, height: 32), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let label = NSRect(x: 4, y: 42, width: bounds.width - 8, height: max(bounds.height - 44, 12))
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
                                                      .paragraphStyle: style]).draw(in: label)
    }
}

/// One image, table or attachment on the page: read-only content under a faint move strip.
final class ObjectView: NSView {
    let id: UUID
    let content: ObjectContentView
    let handle = DragStrip()
    var onDragBegin: (() -> Void)?
    var onMove: ((Double, Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var isSelectedObject = false { didSet { updateBorder() } }
    override var isFlipped: Bool { true }

    init(id: UUID, content: ObjectContentView) {
        self.id = id
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.onDragBegin?() }
        handle.onDelta = { [weak self] dx, dy in self?.onMove?(dx, dy) }
        handle.onEnd = { [weak self] in self?.onDragEnd?() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateBorder() {
        layer?.borderWidth = isSelectedObject ? 1 : 0
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        handle.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(Metrics.handleHeight, bounds.height))
    }

    /// A click on the content selects the object, exactly like grabbing the strip without moving.
    override func mouseDown(with event: NSEvent) { onDragBegin?(); onDragEnd?() }
}
```

- [ ] **Step 7: Replace `Sources/CanvasKit/PageView.swift`:**

```swift
import AppKit
import PageModel

final class PageView: NSView {
    var configure: ((ContainerView) -> Void)?
    var configureObject: ((ObjectView) -> Void)?
    var onBackgroundClick: ((NSPoint) -> Void)?
    var assets: (String) -> Data? = { _ in nil }
    private var views: [UUID: ContainerView] = [:]
    private var objectViews: [UUID: ObjectView] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }   // holds keyboard focus while a box is selected as an object

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)     // the page is always light; text defaults to black
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); dirtyRect.fill() }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?(convert(event.locationInWindow, from: nil)) }

    private func makeContent(for object: PageObject) -> ObjectContentView {
        switch object {
        case .image: return ImageContentView()
        case .table: return TableContentView()
        case .attachment: return AttachmentContentView()
        case .text: return ObjectContentView()
        }
    }

    func sync(_ page: Page, forceText: Bool, selected: UUID?) {
        let ids = Set(page.objects.map(\.id))
        for (id, v) in views where !ids.contains(id) { v.removeFromSuperview(); views[id] = nil }
        for (id, v) in objectViews where !ids.contains(id) { v.removeFromSuperview(); objectViews[id] = nil }

        var extentX = 0.0, extentY = 0.0
        var order: [NSView] = []
        for obj in page.objects {
            let f = obj.frame
            extentX = max(extentX, f.x + f.width)
            extentY = max(extentY, f.y + f.height)
            switch obj {
            case .text(let t):
                let v: ContainerView
                if let existing = views[t.id] { v = existing } else {
                    v = ContainerView(id: t.id); views[t.id] = v; addSubview(v); configure?(v)
                }
                v.frame = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
                if forceText || !v.isEditing { v.setParagraphs(t.paragraphs) }
                v.isSelectedObject = (t.id == selected)
                order.append(v)
            case .image, .table, .attachment:
                let v: ObjectView
                if let existing = objectViews[obj.id] { v = existing } else {
                    v = ObjectView(id: obj.id, content: makeContent(for: obj))
                    objectViews[obj.id] = v; addSubview(v); configureObject?(v)
                }
                v.frame = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
                v.content.update(obj, assets: assets)
                v.isSelectedObject = (obj.id == selected)
                order.append(v)
            }
        }

        // Only reorder when z-order actually changed: re-adding a view resigns its first responder.
        let current = subviews.filter { $0 is ContainerView || $0 is ObjectView }
        if current != order {
            let responder = window?.firstResponder
            for v in order { v.removeFromSuperview(); addSubview(v) }
            if let r = responder as? NSView { window?.makeFirstResponder(r) }
        }

        let visible = enclosingScrollView?.contentSize ?? .zero
        setFrameSize(NSSize(width: max(visible.width, extentX + 400), height: max(visible.height, extentY + 400)))
        needsDisplay = true
    }

    /// The container whose text view currently has keyboard focus.
    func focused() -> (id: UUID, textView: NSTextView)? {
        guard let responder = window?.firstResponder as? NSTextView,
              let v = views.values.first(where: { $0.textView === responder }) else { return nil }
        return (v.id, v.textView)
    }

    func focus(_ id: UUID) {
        guard let v = views[id] else { return }
        window?.makeFirstResponder(v.textView)
        v.needsDisplay = true
    }
}
```

- [ ] **Step 8: Edit `Sources/CanvasKit/PageController.swift`.** Four changes:

(a) Change the pasteboard type:

```swift
    static let pasteboardType = NSPasteboard.PasteboardType("com.notecanvas.object")
```

(b) Replace the `init` with:

```swift
    public init(page: Page, assets: @escaping (String) -> Data? = { _ in nil }) {
        self.page = page
        pageView.assets = assets
        pageView.configure = { [weak self] v in self?.wire(v) }
        pageView.configureObject = { [weak self] v in self?.wireObject(v) }
        pageView.onBackgroundClick = { [weak self] point in self?.backgroundClicked(at: point) }
        self.page.relayout(using: measurer)
        refresh(force: true)
    }
```

(c) Add, after the existing `wire(_:)` method:

```swift
    /// Images, tables and attachments move, select, copy, delete and reorder like text boxes; their content is read-only.
    private func wireObject(_ v: ObjectView) {
        let id = v.id
        v.onDragBegin = { [weak self] in self?.beginDrag(id) }
        v.onMove = { [weak self] dx, dy in self?.drag { $0.move(id, dx: dx, dy: dy) } }
        v.onDragEnd = { [weak self] in self?.endDrag() }
    }
```

(d) Replace `copySelected()` and `paste()` with:

```swift
    public func copySelected() {
        guard let id = selected, let object = page.objects.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(object) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.pasteboardType)
    }

    public func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let object = try? JSONDecoder().decode(PageObject.self, from: data) else { return }
        let copy = object.duplicated(dx: 20, dy: 20)
        selected = copy.id
        commit { $0.add(copy) }
    }
```

(Pasted images and attachments keep pointing at the same asset file; assets are shared, which is fine because nothing deletes them yet.)

- [ ] **Step 9: Create `Sources/CanvasKit/ImportRunner.swift`.**

```swift
import AppKit
import OneImport
import OneStore
import PageModel
import Store

final class ImportCancelFlag {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// TextKit measurement belongs on the main thread; the importer calls this from its background queue.
struct MainThreadMeasurer: TextMeasuring {
    let inner: TextMeasuring
    func height(of paragraphs: [Paragraph], width: Double) -> Double { onMain { inner.height(of: paragraphs, width: width) } }
    func textHeight(of paragraphs: [Paragraph], width: Double) -> Double { onMain { inner.textHeight(of: paragraphs, width: width) } }
    private func onMain<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }
}

struct ImportOutcome {
    var package: NotebookPackage?
    var section: Section?
    var result: ImportResult?
    var cancelled = false
    var error: Error?
}

enum ImportRunner {
    /// Reads, maps and stores `url` into a copy of `package` on a background queue, then calls `completion` on the main
    /// queue. The notebook gains a section only when everything succeeded: failure or cancellation leaves the manifest
    /// untouched (already-written asset files may remain unused). The source file is only ever read.
    static func run(file url: URL, into package: NotebookPackage, cancel: ImportCancelFlag,
                    completion: @escaping (ImportOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = ImportOutcome()
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let file = try OneFile(data: data)
                let importer = OneImporter(measurer: MainThreadMeasurer(inner: TextKitMeasurer()))
                let result = importer.importSection(from: file, name: url.deletingPathExtension().lastPathComponent,
                                                    isCancelled: { cancel.isCancelled })
                outcome.result = result
                if cancel.isCancelled || result.report.cancelled {
                    outcome.cancelled = true
                } else {
                    var pkg = package
                    for asset in result.assets {
                        if cancel.isCancelled { outcome.cancelled = true; break }
                        try pkg.writeAsset(name: asset.name, data: asset.data)
                    }
                    if !outcome.cancelled {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let report = try encoder.encode(result.report)
                        let section = try pkg.addSection(name: result.sectionName, pages: result.pages, report: report)
                        outcome.package = pkg
                        outcome.section = section
                    }
                }
            } catch {
                outcome.error = error
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
```

- [ ] **Step 10: Edit `Sources/CanvasKit/AppShell.swift`.** Make these changes (all in that file):

(a) Imports and state. Replace the import block and add properties after `private var revertingSelection = false`:

```swift
import AppKit
import OneImport
import OneStore
import PageModel
import Store
import UniformTypeIdentifiers
```

```swift
    private var currentSection = 0
    private let sectionPopup = NSPopUpButton()
    private var importCancel: ImportCancelFlag?
    private var progressSheet: NSPanel?
```

(b) Replace `reloadPages()`:

```swift
    private func reloadPages() {
        let sections = package?.notebook.sections ?? []
        if !sections.indices.contains(currentSection) { currentSection = 0 }
        pages = sections.indices.contains(currentSection) ? sections[currentSection].pages : []
        table.reloadData()
    }

    /// The popup lists section names; duplicate names are allowed, so items are added to the menu directly.
    private func rebuildSectionPopup() {
        sectionPopup.removeAllItems()
        let names = package?.notebook.sections.map(\.name) ?? []
        for name in names { sectionPopup.menu?.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: "")) }
        if names.indices.contains(currentSection) { sectionPopup.selectItem(at: currentSection) }
        sectionPopup.isEnabled = !names.isEmpty
    }

    @objc func pickSection(_ sender: Any?) {
        let index = sectionPopup.indexOfSelectedItem
        guard index >= 0, index != currentSection, saveOrDiscard("Continue") else { rebuildSectionPopup(); return }
        currentSection = index
        dropPage()
        table.deselectAll(nil)
        reloadPages()
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }
```

(c) In `use(_:)`, directly after `package = pkg` add `currentSection = 0` and `rebuildSectionPopup()`. In `closeNotebook()`, directly after `package = nil` add `currentSection = 0` and `rebuildSectionPopup()`.

(d) In `showPage`, change the controller creation line to:

```swift
            let c = PageController(page: page, assets: { [weak self] name in self?.package?.loadAsset(name) })
```

(e) In `addPage`, change the call to `try pkg.addPage(title: "Untitled Page", section: currentSection)`.

(f) In `buildWindow`, replace the two lines creating `sideButtons` and `side` with:

```swift
        sectionPopup.target = self
        sectionPopup.action = #selector(pickSection(_:))
        sectionPopup.refusesFirstResponder = true
        let sideButtons = NSStackView(views: [add, remove])
        let side = NSStackView(views: [sectionPopup, sideScroll, sideButtons])
```

and after the `side.alignment = .leading` line add `sectionPopup.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true`.

(g) In `buildMenu`, after the `New Page` item in the File menu add:

```swift
        item("Import .one…", #selector(importOne(_:)), "i", in: file)
```

(h) Add the import flow (new members, anywhere in the class, for example before `// MARK: format bar actions`):

```swift
    // MARK: import

    @objc func importOne(_ sender: Any?) {
        guard let pkg = package else {
            inform("Open a notebook first", "Create or open a notebook, then choose File > Import .one…")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a OneNote section file (.one) to import as a new section"
        if let type = UTType(filenameExtension: "one") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard saveOrDiscard("Import") else { return }
        let cancel = ImportCancelFlag()
        importCancel = cancel
        beginProgressSheet(fileName: url.lastPathComponent)
        ImportRunner.run(file: url, into: pkg, cancel: cancel) { [weak self] outcome in
            self?.endProgressSheet()
            self?.finishImport(outcome)
        }
    }

    @objc func cancelImport(_ sender: Any?) { importCancel?.cancel() }

    private func beginProgressSheet(fileName: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Importing"
        let label = NSTextField(labelWithString: "Importing “\(fileName)”…")
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelImport(_:)))
        let stack = NSStackView(views: [label, bar, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 328).isActive = true
        panel.contentView = stack
        progressSheet = panel
        window.beginSheet(panel, completionHandler: nil)
    }

    private func endProgressSheet() {
        if let panel = progressSheet { window.endSheet(panel); panel.orderOut(nil) }
        progressSheet = nil
        importCancel = nil
    }

    private func finishImport(_ outcome: ImportOutcome) {
        if let error = outcome.error {
            inform("The file could not be imported", importMessage(error))
            return
        }
        if outcome.cancelled {
            inform("Import cancelled", "Nothing was added to the notebook.")
            return
        }
        guard let pkg = outcome.package, let section = outcome.section, let result = outcome.result else { return }
        package = pkg
        currentSection = pkg.notebook.sections.firstIndex { $0.id == section.id } ?? 0
        rebuildSectionPopup()
        dropPage()
        table.deselectAll(nil)
        reloadPages()
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        let a = NSAlert()
        a.messageText = "Imported “\(section.name)”"
        a.informativeText = importSummary(result.report)
        a.runModal()
    }

    private func importMessage(_ error: Error) -> String {
        switch error as? OneStoreError {
        case .some(.notAOneFile): return "This is not a OneNote section file (.one)."
        case .some(.unsupportedFileType): return "This kind of OneNote file (a notebook table of contents) is not supported."
        case .some(.unsupportedVersion): return "This file was written by a newer version of OneNote than this app can read."
        case .some(.truncated), .some(.corrupt): return "The file is damaged or incomplete, so nothing was imported.\n\n\(error)"
        case .none: return "\(error)"
        }
    }

    private func importSummary(_ r: ImportReport) -> String {
        var lines = ["Pages imported: \(r.pagesImported) of \(r.pagesTotal)" + (r.pagesFailed > 0 ? " (\(r.pagesFailed) could not be read)" : "")]
        for (key, label) in [("text", "text boxes"), ("image", "images"), ("table", "tables"), ("attachment", "attachments")] {
            if let n = r.objectsImported[key], n > 0 { lines.append("\(n) \(label)") }
        }
        let skipped = r.skippedObjectTypes.values.reduce(0, +)
        if skipped > 0 { lines.append("\(skipped) objects of types this version does not support were skipped.") }
        let simplified = r.approximations.values.reduce(0, +)
        if simplified > 0 { lines.append("\(simplified) details were simplified.") }
        lines.append("A report with these counts (no note content) is saved inside the notebook, in its imports folder.")
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 11: Build and run the checks.** Run: `swift build 2>&1 | grep -E "error|warning: .*Sources" ; swift run Checks`. Expected: no errors and no new warnings from the changed files; `ALL PASSED`. Do NOT launch the app yourself (a subagent cannot operate it and it would take the user's screen focus); the controller and the user run Step 12.

- [ ] **Step 12: Manual acceptance (run by the controller with the user).** Start with `swift run CanvasApp`, create a scratch notebook, then:

1. **Import:** `File > Import .one…` on a copy of a section file the user chooses. A progress sheet appears; afterwards a summary shows pages imported, counts of text boxes, images and tables, skipped and simplified counts. A new section appears in the sidebar popup and its first page opens.
2. **Layout:** compare a few pages with OneNote: text boxes sit where the originals do (within the stacking drift), paragraph indents, bullets and numbering, bold/italic/size/colour look right, headings look like headings, the page title matches.
3. **Images and tables:** images draw; a table draws as a grid with its cell text. A table without borders shows none.
4. **Edit and persistence:** edit text in an imported box; move an image and a table; copy and paste an image; delete a table and undo it. Quit and reopen the notebook: the section, pages, images and edits are all there.
5. **Sections:** switch sections in the popup; add a page to the imported section; the `+` button adds to the selected section.
6. **Cancel:** start another import of a large file and press Cancel: "Import cancelled"; no new section; the notebook is unchanged.
7. **Damaged file:** import a deliberately truncated copy of a `.one` file (for example `head -c 2000 copy.one > damaged.one`) and a text file renamed to `.one`: each gives a clear message, and nothing is added.
8. **Source untouched:** `shasum` the source file before and after importing: identical.
9. **Report privacy:** open `<notebook>/imports/<section-id>.json` in a text editor: only counts and hex IDs, no note text, titles or file names.
10. **Responsiveness:** while importing a large section the window shows the progress sheet and does not freeze (beach-ball).

Record each item as pass or fail in the task report, with the aggregate numbers from the summary sheet, and nothing from the notes' content.

- [ ] **Step 13: Commit.**

```bash
git add Package.swift Sources
git commit -m "feat(app): import .one sections, section picker, image/table/attachment objects" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_015YbCnbxyE5gzyRkhfrCG2s"
```

---

## Plan self-review notes

- **Spec coverage:** model additions and store (Task 1); `OneStore` header/log/lists (2) and objects/revisions/file data (3); text, style, charset, list, heading, alignment mapping (4); flattening, images, tables, attachments, title, page order, loss report, cancel (5); Import menu, background import, section picker, progress and summary, read-only drawing (6); opt-in corpus checks (3, 5); manual acceptance (6). Non-goals (writing, ink, folders, inline objects, asset cleanup) are not built.
- **Least-verified rules** (called out so reviewers look hard): the page-order lookup through the section's page series (Task 5, Step 6 prints how many real files fall back), the charset table beyond Windows-1252 (Task 4), the `@testable import` use in `Checks`, and the main-thread measurer used from the import's background queue (Task 6).
- **Known limits carried from the spec:** flattening drifts vertically; undocumented paragraph-style properties are ignored; unused assets are not cleaned up; asset names are not deduplicated across imports.
