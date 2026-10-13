# Milestone 1: PageModel, Store and text-container canvas: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Mac app where you open or create a notebook package, add pages, click anywhere to create a free-positioned text container, format its text, move and resize it, undo/redo, and have everything autosave to disk.

**Architecture:** Four SwiftPM targets with one-way dependencies. `PageModel` (pure value types and operations), `Store` (JSON notebook package on disk), `CanvasKit` (AppKit views, controller, text bridge), `CanvasApp` (thin `main`). `.one` is not touched in this milestone. Text editing is done by `NSTextView` inside each container, and a bridge converts it to and from the model's paragraph/run types.

**Tech Stack:** Swift 6.4 toolchain in Swift 5 language mode, AppKit, SwiftPM, macOS 14+. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-13-onenote-clone-design.md` (this plan covers its milestone 1 only: `PageModel`, `Store`, text-container canvas).

## Global Constraints

- Swift + AppKit, macOS 14 or later, built with SwiftPM only. This machine has the Command Line Tools and no Xcode.
- **`swift test` is unusable here:** Swift Testing needs the `TestingMacros` plugin and XCTest is absent, both verified. Tests are an executable target `Checks` run with `swift run Checks`, using the `check`/`checkEqual` helpers from Task 1. If Xcode is installed later, these can move to XCTest.
- Package layout: Package.swift sets `swiftLanguageModes: [.v5]` to avoid Swift 6 actor-isolation friction in AppKit code.
- Page model: a page is an unbounded canvas; objects have x/y/width/height in points; negative coordinates are valid.
- Text container: the user resizes **width only**; **height is derived** from content; containers never reflow around each other; overlap is allowed; z-order is position in the page's `objects` array.
- Working format: a package folder containing `notebook.json` and `pages/<uuid>.json`, human-readable (pretty-printed, sorted keys). Writes are atomic.
- No network, accounts, sync, or `.one` reading/writing in this milestone.
- No private note content in tests, logs, fixtures or commits. The user's backups are not used in this milestone.
- Commit messages end with the trailer line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (add it as a second `-m` argument).
- Do not commit `findings.md` or `.build/`.

## Review Focus

Inputs and conditions the spec implies but does not spell out. Each has a check in the task that owns the code.

1. **Empty container** (no paragraphs, or only empty paragraphs): saves, loads, keeps a minimum height, and is removed automatically when it loses focus empty. (Tasks 3, 5, 8)
2. **Resize below the minimum width**, or to zero or negative: clamps to 40 pt and never produces an invalid frame. (Task 3)
3. **Undo and redo at the boundaries**: undo with nothing to undo is a no-op, redo is cleared by a new edit, and history is capped. (Task 4)
4. **Damaged or foreign files on disk**: a truncated page, a missing page file, a non-package folder, garbage or future-version manifest each give a typed error. Other pages still load and nothing is overwritten. (Task 5)
5. **Unicode text** (emoji ZWJ sequences, combining marks, right-to-left script) survives the model → `NSAttributedString` → model round trip and the JSON round trip unchanged. (Tasks 2, 6)

---

## File Structure

```
Package.swift
.gitignore
Sources/PageModel/Geometry.swift      Frame
Sources/PageModel/Text.swift          RunStyle, Run, Paragraph, TextContainer
Sources/PageModel/Page.swift          PageObject, Page and its operations, TextMeasuring
Sources/PageModel/History.swift       generic undo/redo stack
Sources/PageModel/Notebook.swift      PageRef, Section, Notebook manifest types
Sources/Store/StoreError.swift        typed errors
Sources/Store/NotebookPackage.swift   create/open/add/save/load/delete pages on disk
Sources/CanvasKit/AttributedBridge.swift   Paragraph[] <-> NSAttributedString
Sources/CanvasKit/TextKitMeasurer.swift    TextMeasuring using TextKit
Sources/CanvasKit/ContainerView.swift      one text container on screen + drag strips
Sources/CanvasKit/PageView.swift           the canvas; syncs views from a Page
Sources/CanvasKit/FormatApplier.swift      run-level formatting on an NSTextView
Sources/CanvasKit/PageController.swift     owns Page, History, autosave; all user actions
Sources/CanvasKit/AppShell.swift           window, sidebar, format bar, menus
Sources/CanvasApp/main.swift          starts NSApplication
Sources/Checks/Check.swift            check helpers
Sources/Checks/main.swift             runs all check groups
Sources/Checks/ModelChecks.swift      PageModel checks
Sources/Checks/StoreChecks.swift      Store checks
Sources/Checks/BridgeChecks.swift     bridge and measurer checks
```

---

### Task 1: Package scaffold and check harness

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/PageModel/Geometry.swift`, `Sources/Checks/Check.swift`, `Sources/Checks/main.swift`

**Interfaces:**
- Produces: `Frame`; global `check`, `checkEqual`, `checkThrows`; `failures` counter.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .executableTarget(name: "Checks", dependencies: ["PageModel"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Create `.gitignore`**

```
.build/
.swiftpm/
findings.md
```

- [ ] **Step 3: Create `Sources/PageModel/Geometry.swift`**

```swift
public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
```

- [ ] **Step 4: Create `Sources/Checks/Check.swift`**

```swift
import Foundation

var failures = 0

func check(_ ok: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !ok { failures += 1; print("FAIL \(file):\(line): \(msg)") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    if actual != expected {
        failures += 1
        print("FAIL \(file):\(line): \(msg) expected \(expected), got \(actual)")
    }
}

/// Returns the thrown error, or nil (recording a failure) when `body` did not throw.
@discardableResult
func checkThrows<T>(_ msg: String, file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        failures += 1
        print("FAIL \(file):\(line): \(msg) did not throw")
        return nil
    } catch {
        return error
    }
}
```

- [ ] **Step 5: Create `Sources/Checks/main.swift`**

```swift
import Foundation
import PageModel

checkEqual(Frame(x: 1, y: 2, width: 3, height: 4).width, 3, "harness sanity")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 6: Run to verify the harness passes, then fails when it should**

Run: `swift run Checks`
Expected: `ALL PASSED`, exit code 0.

Temporarily change the expected `3` to `4`, run again, expect a `FAIL` line, `1 FAILED` and exit code 1, then change it back.

- [ ] **Step 7: Initialise the working tree and commit**

```bash
git add Package.swift .gitignore Sources
git commit -m "chore: SwiftPM scaffold and check harness" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Text types

**Files:**
- Create: `Sources/PageModel/Text.swift`, `Sources/Checks/ModelChecks.swift`
- Modify: `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `Frame`.
- Produces (all `public`, `Codable`, `Equatable`, `Sendable`):
  - `enum Script: String { normal, sup, sub }`
  - `struct RunStyle { bold, italic, underline, strike: Bool; fontName: String?; fontSize: Double?; colorHex: String?; highlightHex: String?; script: Script; link: String? }` with an `init()` of defaults
  - `struct Run { text: String; style: RunStyle }`
  - `enum ListStyle: String { none, bullet, numbered }`, `enum Alignment: String { left, center, right }`
  - `struct Paragraph { runs: [Run]; indent: Int; heading: Int; list: ListStyle; alignment: Alignment }`, `static let maxIndent = 8`, `mutating func clamp()`
  - `struct TextContainer { id: UUID; frame: Frame; paragraphs: [Paragraph] }`

- [ ] **Step 1: Write the failing check in `Sources/Checks/ModelChecks.swift`**

```swift
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
```

- [ ] **Step 2: Call it from `main.swift`** (add `modelChecks()` before the summary print) and run

Run: `swift run Checks`
Expected: build FAILS: `cannot find 'RunStyle' in scope` (types do not exist yet).

- [ ] **Step 3: Create `Sources/PageModel/Text.swift`**

```swift
import Foundation

public enum Script: String, Codable, Sendable { case normal, sup, sub }

public struct RunStyle: Codable, Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var fontName: String?
    public var fontSize: Double?
    public var colorHex: String?
    public var highlightHex: String?
    public var script: Script = .normal
    public var link: String?
    public init() {}
}

public struct Run: Codable, Equatable, Sendable {
    public var text: String
    public var style: RunStyle
    public init(text: String, style: RunStyle) { self.text = text; self.style = style }
}

public enum ListStyle: String, Codable, Sendable { case none, bullet, numbered }
public enum Alignment: String, Codable, Sendable { case left, center, right }

public struct Paragraph: Codable, Equatable, Sendable {
    public static let maxIndent = 8
    public var runs: [Run]
    public var indent: Int
    public var heading: Int          // 0 = body, 1...3 = heading level
    public var list: ListStyle
    public var alignment: Alignment

    public init(runs: [Run], indent: Int = 0, heading: Int = 0,
                list: ListStyle = .none, alignment: Alignment = .left) {
        self.runs = runs; self.indent = indent; self.heading = heading
        self.list = list; self.alignment = alignment
    }

    public mutating func clamp() {
        indent = min(max(indent, 0), Paragraph.maxIndent)
        heading = min(max(heading, 0), 3)
    }
}

public struct TextContainer: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var paragraphs: [Paragraph]
    public init(id: UUID, frame: Frame, paragraphs: [Paragraph]) {
        self.id = id; self.frame = frame; self.paragraphs = paragraphs
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat(model): text container, paragraph and run types" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Page operations and layout

**Files:**
- Create: `Sources/PageModel/Page.swift`
- Modify: `Sources/Checks/ModelChecks.swift`

**Interfaces:**
- Consumes: `TextContainer`, `Paragraph`, `box(...)` helper from Task 2's checks.
- Produces:
  - `protocol TextMeasuring { func height(of paragraphs: [Paragraph], width: Double) -> Double }`
  - `enum PageObject { case text(TextContainer); var id: UUID }`
  - `struct Page { id: UUID; title: String; objects: [PageObject] }`, `static let minContainerWidth = 40.0`, `static let minContainerHeight = 20.0`
  - mutating: `add(_:)`, `delete(_:)`, `bringToFront(_:)`, `sendToBack(_:)`, `updateText(_:_:)`, `move(_:dx:dy:)`, `resize(_:width:)`, `setParagraphs(_:_:)`, `editParagraphs(_:in:_:)`, `relayout(using:)`

- [ ] **Step 1: Add the failing checks to `ModelChecks.swift`** (and call `pageOpChecks()` from `modelChecks()`)

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run Checks`
Expected: build FAILS, `cannot find 'Page' in scope`.

- [ ] **Step 3: Create `Sources/PageModel/Page.swift`**

```swift
import Foundation

public protocol TextMeasuring {
    func height(of paragraphs: [Paragraph], width: Double) -> Double
}

public enum PageObject: Codable, Equatable, Sendable {
    case text(TextContainer)

    public var id: UUID {
        switch self { case .text(let t): return t.id }
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

    public mutating func updateText(_ id: UUID, _ body: (inout TextContainer) -> Void) {
        guard let i = index(of: id), case .text(var t) = objects[i] else { return }
        body(&t)
        objects[i] = .text(t)
    }

    public mutating func move(_ id: UUID, dx: Double, dy: Double) {
        updateText(id) { $0.frame.x += dx; $0.frame.y += dy }
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

    /// Recomputes every container's derived height.
    public mutating func relayout(using measurer: TextMeasuring) {
        for i in objects.indices {
            guard case .text(var t) = objects[i] else { continue }
            let h = measurer.height(of: t.paragraphs, width: t.frame.width)
            t.frame.height = max(h, Page.minContainerHeight)
            objects[i] = .text(t)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat(model): page operations, z-order, derived height" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: History (undo/redo)

**Files:**
- Create: `Sources/PageModel/History.swift`
- Modify: `Sources/Checks/ModelChecks.swift`

**Interfaces:**
- Produces: `struct History<State>` with `init(limit: Int = 200)`, `canUndo`, `canRedo`, `mutating record(_ before: State)`, `mutating undo(current:) -> State?`, `mutating redo(current:) -> State?`.

- [ ] **Step 1: Add the failing checks** (call `historyChecks()` from `modelChecks()`)

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run Checks`
Expected: build FAILS, `cannot find 'History' in scope`.

- [ ] **Step 3: Create `Sources/PageModel/History.swift`**

```swift
/// Snapshot-based undo/redo. `State` is a value type, so a snapshot is just a copy.
public struct History<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call with the state as it was *before* a change.
    public mutating func record(_ before: State) {
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat(model): snapshot undo/redo history" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Notebook manifest and on-disk package

**Files:**
- Create: `Sources/PageModel/Notebook.swift`, `Sources/Store/StoreError.swift`, `Sources/Store/NotebookPackage.swift`, `Sources/Checks/StoreChecks.swift`
- Modify: `Package.swift` (add `Store` target and make `Checks` depend on it), `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `Page`.
- Produces:
  - `PageRef { id: UUID; title: String }`, `Section { id: UUID; name: String; pages: [PageRef] }`, `Notebook { version: Int; name: String; sections: [Section] }`, `Notebook.currentVersion = 1`, `Notebook.init(name:)` (one empty section named "Section 1")
  - `enum StoreError: Error, Equatable { alreadyExists, notAPackage, corruptManifest, unsupportedVersion(Int), noSuchSection, missingPage(UUID), corruptPage(UUID) }`
  - `struct NotebookPackage` with `url`, `notebook`, `static create(at:name:)`, `static open(at:)`, `mutating addPage(title:section:) -> Page`, `loadPage(_:) -> Page`, `mutating savePage(_:)`, `mutating deletePage(id:)`

- [ ] **Step 1: Edit `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Write the failing checks in `Sources/Checks/StoreChecks.swift`** and call `storeChecks()` from `main.swift` (also add `import Store` to `main.swift`)

```swift
import Foundation
import PageModel
import Store

func storeChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Test.notebook")

    // create / open
    var pkg = try! NotebookPackage.create(at: url, name: "Test")
    checkEqual(pkg.notebook.name, "Test", "create sets the name")
    checkEqual(pkg.notebook.sections.count, 1, "new notebook has one section")
    checkEqual(checkThrows("create over existing") { try NotebookPackage.create(at: url, name: "x") } as? StoreError,
               .alreadyExists, "create never clobbers an existing path")
    let reopened = try! NotebookPackage.open(at: url)
    checkEqual(reopened.notebook, pkg.notebook, "open reads back what create wrote")

    // add / save / load
    var page = try! pkg.addPage(title: "First")
    let other = try! pkg.addPage(title: "Second")
    page.objects = [.text(box(-5, 7, 220, lines: 2))]
    page.title = "Renamed"
    try! pkg.savePage(page)
    checkEqual(try! pkg.loadPage(page.id), page, "saved page loads back identically")
    checkEqual(try! NotebookPackage.open(at: url).notebook.sections[0].pages.map(\.title),
               ["Renamed", "Second"], "title change reaches the manifest on disk")

    // empty page round-trips (Review Focus 1)
    checkEqual(try! pkg.loadPage(other.id).objects.count, 0, "empty page loads")

    // stray temp file next to a page does not matter
    try! Data("junk".utf8).write(to: url.appendingPathComponent("pages/\(page.id.uuidString).json.tmp"))
    checkEqual(try! pkg.loadPage(page.id), page, "stray .tmp file is ignored")

    // corrupt page: typed error, other pages unaffected (Review Focus 4)
    try! Data("{".utf8).write(to: url.appendingPathComponent("pages/\(other.id.uuidString).json"))
    checkEqual(checkThrows("corrupt page") { try pkg.loadPage(other.id) } as? StoreError,
               .corruptPage(other.id), "truncated page gives corruptPage")
    checkEqual(try! pkg.loadPage(page.id), page, "other pages still load")

    // missing page file
    try! FileManager.default.removeItem(at: url.appendingPathComponent("pages/\(other.id.uuidString).json"))
    checkEqual(checkThrows("missing page") { try pkg.loadPage(other.id) } as? StoreError,
               .missingPage(other.id), "missing page file gives missingPage")

    // bad section index, unknown page save
    checkEqual(checkThrows("bad section") { try pkg.addPage(title: "x", section: 5) } as? StoreError,
               .noSuchSection, "addPage with a bad section index throws")
    checkEqual(checkThrows("save unknown") { try pkg.savePage(Page(id: UUID(), title: "x", objects: [])) } != nil,
               true, "saving a page the manifest does not list throws")

    // delete
    try! pkg.deletePage(id: page.id)
    checkEqual(pkg.notebook.sections[0].pages.map(\.id), [other.id], "delete removes the reference")
    check(!FileManager.default.fileExists(atPath: url.appendingPathComponent("pages/\(page.id.uuidString).json").path),
          "delete removes the file")

    // foreign / future / garbage (Review Focus 4)
    let plain = root.appendingPathComponent("plain")
    try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    checkEqual(checkThrows("not a package") { try NotebookPackage.open(at: plain) } as? StoreError,
               .notAPackage, "folder without notebook.json is not a package")

    let future = root.appendingPathComponent("future.notebook")
    try! FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
    try! Data(#"{"version":99,"name":"x","sections":[]}"#.utf8).write(to: future.appendingPathComponent("notebook.json"))
    checkEqual(checkThrows("future version") { try NotebookPackage.open(at: future) } as? StoreError,
               .unsupportedVersion(99), "newer manifest version is refused, not misread")

    let garbage = root.appendingPathComponent("garbage.notebook")
    try! FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
    try! Data("not json".utf8).write(to: garbage.appendingPathComponent("notebook.json"))
    checkEqual(checkThrows("garbage manifest") { try NotebookPackage.open(at: garbage) } as? StoreError,
               .corruptManifest, "garbage manifest gives corruptManifest")
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks`
Expected: build FAILS, `cannot find 'NotebookPackage' in scope`.

- [ ] **Step 4: Create `Sources/PageModel/Notebook.swift`**

```swift
import Foundation

public struct PageRef: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
}

public struct Section: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var pages: [PageRef]
    public init(id: UUID, name: String, pages: [PageRef]) { self.id = id; self.name = name; self.pages = pages }
}

public struct Notebook: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var name: String
    public var sections: [Section]

    public init(name: String) {
        self.version = Notebook.currentVersion
        self.name = name
        self.sections = [Section(id: UUID(), name: "Section 1", pages: [])]
    }
}
```

- [ ] **Step 5: Create `Sources/Store/StoreError.swift`**

```swift
import Foundation

public enum StoreError: Error, Equatable {
    case alreadyExists
    case notAPackage
    case corruptManifest
    case unsupportedVersion(Int)
    case noSuchSection
    case missingPage(UUID)
    case corruptPage(UUID)
}
```

- [ ] **Step 6: Create `Sources/Store/NotebookPackage.swift`**

```swift
import Foundation
import PageModel

/// A notebook on disk: `notebook.json` plus `pages/<uuid>.json`.
public struct NotebookPackage {
    public let url: URL
    public private(set) var notebook: Notebook

    private var manifestURL: URL { url.appendingPathComponent("notebook.json") }
    private func pageURL(_ id: UUID) -> URL {
        url.appendingPathComponent("pages", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(value)
    }

    public static func create(at url: URL, name: String) throws -> NotebookPackage {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw StoreError.alreadyExists }
        try fm.createDirectory(at: url.appendingPathComponent("pages", isDirectory: true),
                               withIntermediateDirectories: true)
        let pkg = NotebookPackage(url: url, notebook: Notebook(name: name))
        try pkg.writeManifest()
        return pkg
    }

    public static func open(at url: URL) throws -> NotebookPackage {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("notebook.json")) else {
            throw StoreError.notAPackage
        }
        // Read the version alone first so a newer format reports unsupportedVersion, not corrupt.
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw StoreError.corruptManifest
        }
        guard probe.version == Notebook.currentVersion else { throw StoreError.unsupportedVersion(probe.version) }
        guard let notebook = try? JSONDecoder().decode(Notebook.self, from: data) else {
            throw StoreError.corruptManifest
        }
        return NotebookPackage(url: url, notebook: notebook)
    }

    private func writeManifest() throws {
        try Self.encode(notebook).write(to: manifestURL, options: .atomic)
    }

    private func write(_ page: Page) throws {
        try Self.encode(page).write(to: pageURL(page.id), options: .atomic)
    }

    /// Page file is written before the manifest references it, so the manifest never points at nothing.
    public mutating func addPage(title: String, section: Int = 0) throws -> Page {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        let page = Page(id: UUID(), title: title, objects: [])
        try write(page)
        notebook.sections[section].pages.append(PageRef(id: page.id, title: title))
        try writeManifest()
        return page
    }

    public func loadPage(_ id: UUID) throws -> Page {
        guard let data = try? Data(contentsOf: pageURL(id)) else { throw StoreError.missingPage(id) }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw StoreError.corruptPage(id) }
        return page
    }

    public mutating func savePage(_ page: Page) throws {
        guard let s = notebook.sections.firstIndex(where: { $0.pages.contains { $0.id == page.id } }),
              let p = notebook.sections[s].pages.firstIndex(where: { $0.id == page.id }) else {
            throw StoreError.missingPage(page.id)
        }
        try write(page)
        if notebook.sections[s].pages[p].title != page.title {
            notebook.sections[s].pages[p].title = page.title
            try writeManifest()
        }
    }

    /// Manifest first, then the file: a crash in between leaves an orphan file, never a dangling reference.
    public mutating func deletePage(id: UUID) throws {
        for s in notebook.sections.indices { notebook.sections[s].pages.removeAll { $0.id == id } }
        try writeManifest()
        try? FileManager.default.removeItem(at: pageURL(id))
    }
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources
git commit -m "feat(store): notebook package on disk with typed errors" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Attributed-string bridge

**Files:**
- Create: `Sources/CanvasKit/AttributedBridge.swift`, `Sources/Checks/BridgeChecks.swift`
- Modify: `Package.swift` (add `CanvasKit` target; `Checks` depends on it), `Sources/Checks/main.swift`

**Interfaces:**
- Consumes: `Paragraph`, `Run`, `RunStyle`, `ListStyle`, `Alignment`.
- Produces (`public`):
  - `AttributedBridge.attributed(from: [Paragraph]) -> NSAttributedString`: list markers (`•\t`, `1.\t`) are inserted as literal text, numbering restarts per consecutive list block per indent level.
  - `AttributedBridge.paragraphs(from: NSAttributedString) -> [Paragraph]`: strips list markers, merges adjacent equal-style runs.
  - `AttributedBridge.paragraphRange(forSelection: NSRange, in string: String) -> ClosedRange<Int>`
  - `AttributedBridge.baseSize: CGFloat = 14`
- Known normalisation: a non-system `fontName` plus bold/italic reads back as the concrete face name (e.g. `Helvetica` + bold → `Helvetica-Bold`); system fonts round-trip exactly. A trailing empty paragraph carries no paragraph attributes (nothing to hold them) and reads back with defaults.

- [ ] **Step 1: Edit `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .target(name: "CanvasKit", dependencies: ["PageModel", "Store"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store", "CanvasKit"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Write the failing checks in `Sources/Checks/BridgeChecks.swift`**, call `bridgeChecks()` from `main.swift` (add `import CanvasKit`)

```swift
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
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks`
Expected: build FAILS, `cannot find 'AttributedBridge' in scope`.

- [ ] **Step 4: Create `Sources/CanvasKit/AttributedBridge.swift`**

```swift
import AppKit
import PageModel

extension NSAttributedString.Key {
    static let pmHeading = NSAttributedString.Key("pm.heading")
    static let pmList = NSAttributedString.Key("pm.list")
    static let pmIndent = NSAttributedString.Key("pm.indent")
}

/// Converts between the model's paragraphs/runs and the attributed text shown in an NSTextView.
public enum AttributedBridge {
    public static let baseSize: CGFloat = 14
    static let headingScale: [CGFloat] = [1, 1.8, 1.4, 1.2]
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
                seg.append(NSAttributedString(string: marker, attributes: attributes(for: markerStyle, heading: p.heading)))
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
        var location = 0
        for line in attributed.string.components(separatedBy: "\n") {
            let len = (line as NSString).length
            var p = Paragraph(runs: [])
            if location < ns.length {                       // an empty last line has no character to read from
                let a = attributed.attributes(at: location, effectiveRange: nil)
                p.heading = (a[.pmHeading] as? Int) ?? 0
                p.indent = (a[.pmIndent] as? Int) ?? 0
                p.list = ListStyle(rawValue: (a[.pmList] as? String) ?? "") ?? .none
                if let ps = a[.paragraphStyle] as? NSParagraphStyle {
                    p.alignment = ps.alignment == .center ? .center : ps.alignment == .right ? .right : .left
                }
            }
            let marker = p.list == .none ? 0 : markerLength(of: line)
            let body = NSRange(location: location + marker, length: len - marker)
            if body.length > 0 {
                attributed.enumerateAttributes(in: body, options: []) { attrs, r, _ in
                    let style = self.style(from: attrs, heading: p.heading)
                    if let last = p.runs.last, last.style == style {
                        p.runs[p.runs.count - 1].text += ns.substring(with: r)
                    } else {
                        p.runs.append(Run(text: ns.substring(with: r), style: style))
                    }
                }
            }
            result.append(p)
            location += len + 1
        }
        return result
    }

    /// UTF-16 length of a leading "•\t" or "N.\t", or 0 if the line has no marker (user deleted it).
    private static func markerLength(of line: String) -> Int {
        guard let tab = line.firstIndex(of: "\t") else { return 0 }
        let head = line[line.startIndex..<tab]
        let isMarker = head == "•" || (head.hasSuffix(".") && head.dropLast().allSatisfy(\.isNumber) && head.count > 1)
        return isMarker ? line[line.startIndex...tab].utf16.count : 0
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`. If the round-trip check fails, print `AttributedBridge.paragraphs(from: attributed)` next to `paragraphs` and fix the specific field that differs (most likely candidates: the font size rounding for `fontSize = 20` under heading 1, or the numbered counters).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources
git commit -m "feat(canvas): attributed-string bridge with list markers" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Text measurer and container/page views

**Files:**
- Create: `Sources/CanvasKit/TextKitMeasurer.swift`, `Sources/CanvasKit/ContainerView.swift`, `Sources/CanvasKit/PageView.swift`
- Modify: `Sources/Checks/BridgeChecks.swift`

**Interfaces:**
- Consumes: `AttributedBridge`, `TextMeasuring`, `Page`.
- Produces:
  - `public struct TextKitMeasurer: TextMeasuring` (`init()`); height includes the handle strip and padding.
  - `enum Metrics { handleHeight, inset, gripWidth }`
  - `final class ContainerView: NSView` with closures `onDragBegin`, `onMove(dx,dy)`, `onResizeBegin`, `onResize(dx)`, `onDragEnd`, `onTextChange(NSAttributedString)`, `onEndEditing`; `textView`; `isEditing`; `isSelectedObject`; `setParagraphs(_:)`
  - `final class PageView: NSView` with `configure: ((ContainerView) -> Void)?`, `onBackgroundClick: ((NSPoint) -> Void)?`, `sync(_:forceText:selected:)`, `focused() -> (id: UUID, textView: NSTextView)?`, `focus(_ id: UUID)`

- [ ] **Step 1: Add the failing measurer checks to `bridgeChecks()`**

```swift
    let m = TextKitMeasurer()
    let long = [Paragraph(runs: [run(String(repeating: "word ", count: 60))])]
    let narrowH = m.height(of: long, width: 120)
    let wideH = m.height(of: long, width: 600)
    check(narrowH > wideH * 2, "narrow container wraps to a much greater height (\(narrowH) vs \(wideH))")
    let single = [Paragraph(runs: [run("one line")])]
    let twoLines = [Paragraph(runs: [run("a")]), Paragraph(runs: [run("b")])]
    check(m.height(of: twoLines, width: 300) > m.height(of: single, width: 300), "more paragraphs are taller")
    check(m.height(of: [], width: 300) >= 0, "empty content measures without crashing")
    let tall = [Paragraph(runs: [run("Title", { $0.fontSize = 14 })], heading: 1)]
    check(m.height(of: tall, width: 300) > m.height(of: single, width: 300), "headings are taller than body text")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run Checks`
Expected: build FAILS, `cannot find 'TextKitMeasurer' in scope`.

- [ ] **Step 3: Create `Sources/CanvasKit/TextKitMeasurer.swift`**

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

    public func height(of paragraphs: [Paragraph], width: Double) -> Double {
        let storage = NSTextStorage(attributedString: AttributedBridge.attributed(from: paragraphs))
        let textWidth = max(width - Metrics.inset - Metrics.gripWidth, 1)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let text = Double(layout.usedRect(for: container).height)
        return Metrics.handleHeight + Metrics.inset * 2 + text
    }
}
```

- [ ] **Step 4: Create `Sources/CanvasKit/ContainerView.swift`**

```swift
import AppKit
import PageModel

/// A thin strip that reports total mouse movement since mouse-down.
final class DragStrip: NSView {
    var cursor: NSCursor = .openHand
    var fill: NSColor = NSColor.black.withAlphaComponent(0.06)
    var onBegin: (() -> Void)?
    var onDelta: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    private var total = NSPoint.zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) { total = .zero; onBegin?() }
    override func mouseDragged(with event: NSEvent) {
        total.x += event.deltaX; total.y += event.deltaY
        onDelta?(Double(total.x), Double(total.y))
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

final class ContainerView: NSView, NSTextViewDelegate {
    let id: UUID
    let handle = DragStrip()
    let grip = DragStrip()
    let textView = NSTextView()

    var onDragBegin: (() -> Void)?
    var onMove: ((Double, Double) -> Void)?
    var onResizeBegin: (() -> Void)?
    var onResize: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onTextChange: ((NSAttributedString) -> Void)?
    var onEndEditing: (() -> Void)?

    var isSelectedObject = false { didSet { needsDisplay = true } }
    var isEditing: Bool { window?.firstResponder === textView }
    override var isFlipped: Bool { true }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = false                 // undo is handled by PageController
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: AttributedBridge.baseSize),
                                     .foregroundColor: NSColor.black]
        textView.delegate = self
        grip.cursor = .resizeLeftRight
        grip.fill = .clear
        handle.onBegin = { [weak self] in self?.onDragBegin?() }
        handle.onDelta = { [weak self] dx, dy in self?.onMove?(dx, dy) }
        handle.onEnd = { [weak self] in self?.onDragEnd?() }
        grip.onBegin = { [weak self] in self?.onResizeBegin?() }
        grip.onDelta = { [weak self] dx, _ in self?.onResize?(dx) }
        grip.onEnd = { [weak self] in self?.onDragEnd?() }
        addSubview(handle); addSubview(grip); addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        handle.frame = NSRect(x: 0, y: 0, width: w, height: Metrics.handleHeight)
        grip.frame = NSRect(x: w - Metrics.gripWidth, y: Metrics.handleHeight, width: Metrics.gripWidth,
                            height: max(h - Metrics.handleHeight, 0))
        textView.frame = NSRect(x: Metrics.inset, y: Metrics.handleHeight + Metrics.inset,
                                width: max(w - Metrics.inset - Metrics.gripWidth, 1),
                                height: max(h - Metrics.handleHeight - Metrics.inset * 2, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedObject || isEditing {
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    func setParagraphs(_ paragraphs: [Paragraph]) {
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(AttributedBridge.attributed(from: paragraphs))
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    // MARK: NSTextViewDelegate
    func textDidChange(_ notification: Notification) { onTextChange?(textView.attributedString()) }
    func textDidEndEditing(_ notification: Notification) { needsDisplay = true; onEndEditing?() }
    func textDidBeginEditing(_ notification: Notification) { needsDisplay = true }
}
```

- [ ] **Step 5: Create `Sources/CanvasKit/PageView.swift`**

```swift
import AppKit
import PageModel

final class PageView: NSView {
    var configure: ((ContainerView) -> Void)?
    var onBackgroundClick: ((NSPoint) -> Void)?
    private var views: [UUID: ContainerView] = [:]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)     // the page is always light; text defaults to black
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); dirtyRect.fill() }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?(convert(event.locationInWindow, from: nil)) }

    func sync(_ page: Page, forceText: Bool, selected: UUID?) {
        let ids = Set(page.objects.map(\.id))
        for (id, v) in views where !ids.contains(id) { v.removeFromSuperview(); views[id] = nil }

        var extentX = 0.0, extentY = 0.0
        var order: [ContainerView] = []
        for obj in page.objects {
            guard case .text(let t) = obj else { continue }
            let v: ContainerView
            if let existing = views[t.id] { v = existing } else {
                v = ContainerView(id: t.id); views[t.id] = v; addSubview(v); configure?(v)
            }
            v.frame = NSRect(x: t.frame.x, y: t.frame.y, width: t.frame.width, height: t.frame.height)
            if forceText || !v.isEditing { v.setParagraphs(t.paragraphs) }
            v.isSelectedObject = (t.id == selected)
            order.append(v)
            extentX = max(extentX, t.frame.x + t.frame.width)
            extentY = max(extentY, t.frame.y + t.frame.height)
        }

        // Only reorder when z-order actually changed: re-adding a view resigns its first responder.
        let current = subviews.compactMap { $0 as? ContainerView }
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

- [ ] **Step 6: Run to verify it passes**

Run: `swift run Checks`
Expected: `ALL PASSED`. (The view classes are compile-checked here and exercised manually in Task 9.)

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(canvas): TextKit measurer, container and page views" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Formatting and the page controller

**Files:**
- Create: `Sources/CanvasKit/FormatApplier.swift`, `Sources/CanvasKit/PageController.swift`

**Interfaces:**
- Consumes: `Page`, `History`, `TextKitMeasurer`, `PageView`, `ContainerView`, `AttributedBridge`.
- Produces:
  - `public enum RunFormat { bold, italic, underline, strike, size(Double), color(NSColor) }`
  - `public final class PageController` with: `init(page: Page)`, `view: NSView` (the canvas), `page`, `onPersist: ((Page) -> Void)?`, `undo()`, `redo()`, `applyRun(_: RunFormat)`, `applyParagraph(_: (inout Paragraph) -> Void)`, `bringToFront()`, `sendToBack()`, `deleteSelected()`, `copySelected()`, `paste()`, `flush()`, `hasSelectedObject`, `setTitle(_:)`

- [ ] **Step 1: Create `Sources/CanvasKit/FormatApplier.swift`**

```swift
import AppKit

public enum RunFormat {
    case bold, italic, underline, strike
    case size(Double)
    case color(NSColor)
}

enum FormatApplier {
    /// Applies a run-level format to the selection (or the typing attributes when nothing is selected).
    static func apply(_ f: RunFormat, to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var t = tv.typingAttributes
            mutate(&t, f, turnOn: !isOn(f, t))
            tv.typingAttributes = t
            return
        }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        var allOn = true
        storage.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            runs.append((r, attrs))
            if !isOn(f, attrs) { allOn = false }
        }
        storage.beginEditing()
        for (r, attrs) in runs {
            var a = attrs
            mutate(&a, f, turnOn: !allOn)
            storage.setAttributes(a, range: r)
        }
        storage.endEditing()
        tv.didChangeText()                         // fires textDidChange -> controller -> model
    }

    private static func isOn(_ f: RunFormat, _ a: [NSAttributedString.Key: Any]) -> Bool {
        switch f {
        case .bold: return ((a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold)) ?? false
        case .italic: return ((a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic)) ?? false
        case .underline: return ((a[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        case .strike: return ((a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        case .size, .color: return false           // always "apply", never "toggle off"
        }
    }

    private static func mutate(_ a: inout [NSAttributedString.Key: Any], _ f: RunFormat, turnOn: Bool) {
        let fm = NSFontManager.shared
        let font = (a[.font] as? NSFont) ?? NSFont.systemFont(ofSize: AttributedBridge.baseSize)
        switch f {
        case .bold:
            a[.font] = turnOn ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask)
        case .italic:
            a[.font] = turnOn ? fm.convert(font, toHaveTrait: .italicFontMask) : fm.convert(font, toNotHaveTrait: .italicFontMask)
        case .underline:
            a[.underlineStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .strike:
            a[.strikethroughStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .size(let s):
            let heading = (a[.pmHeading] as? Int) ?? 0
            a[.font] = fm.convert(font, toSize: CGFloat(s) * AttributedBridge.headingScale[min(max(heading, 0), 3)])
        case .color(let c):
            a[.foregroundColor] = c
        }
    }
}
```

- [ ] **Step 2: Create `Sources/CanvasKit/PageController.swift`**

```swift
import AppKit
import PageModel

public final class PageController {
    public private(set) var page: Page
    public var onPersist: ((Page) -> Void)?
    public var view: NSView { pageView }
    public var hasSelectedObject: Bool { selected != nil }

    static let pasteboardType = NSPasteboard.PasteboardType("com.notecanvas.container")

    private let pageView = PageView(frame: .zero)
    private let measurer = TextKitMeasurer()
    private var history = History<Page>()
    private var selected: UUID?
    private var typingOpen = false                  // one undo step per typing session
    private var dragStart: Page?
    private var dragRecorded = false
    private var persistWork: DispatchWorkItem?

    public init(page: Page) {
        self.page = page
        pageView.configure = { [weak self] v in self?.wire(v) }
        pageView.onBackgroundClick = { [weak self] point in self?.backgroundClicked(at: point) }
        self.page.relayout(using: measurer)
        refresh(force: true)
    }

    // MARK: wiring

    private func wire(_ v: ContainerView) {
        let id = v.id
        v.onDragBegin = { [weak self] in self?.beginDrag(id) }
        v.onMove = { [weak self] dx, dy in self?.drag { $0.move(id, dx: dx, dy: dy) } }
        v.onResizeBegin = { [weak self] in self?.beginDrag(id) }
        v.onResize = { [weak self] dx in
            guard let self, let start = self.dragStart, case .text(let t)? = start.objects.first(where: { $0.id == id })
            else { return }
            self.drag { $0.resize(id, width: t.frame.width + dx) }
        }
        v.onDragEnd = { [weak self] in self?.endDrag() }
        v.onTextChange = { [weak self] text in self?.textEdited(id, text) }
        v.onEndEditing = { [weak self] in self?.endEditing(id) }
    }

    private func refresh(force: Bool) { pageView.sync(page, forceText: force, selected: selected) }

    private func persist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onPersist?(self.page)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write immediately (page switch, quit).
    public func flush() {
        persistWork?.cancel()
        persistWork = nil
        onPersist?(page)
    }

    /// Applies an undoable change and re-renders every container's text.
    private func commit(_ change: (inout Page) -> Void) {
        history.record(page)
        typingOpen = false
        change(&page)
        page.relayout(using: measurer)
        refresh(force: true)
        persist()
    }

    // MARK: object actions

    private func backgroundClicked(at point: NSPoint) {
        pageView.window?.makeFirstResponder(nil)       // lets an empty container being edited remove itself
        let id = UUID()
        let c = TextContainer(id: id, frame: Frame(x: Double(point.x), y: Double(point.y), width: 240, height: 0), paragraphs: [])
        commit { $0.add(.text(c)) }
        selected = id
        refresh(force: false)
        pageView.focus(id)
    }

    private func select(_ id: UUID?) { selected = id; refresh(force: false) }

    private func beginDrag(_ id: UUID) {
        select(id)
        dragStart = page
        dragRecorded = false
    }

    private func drag(_ change: (inout Page) -> Void) {
        guard let start = dragStart else { return }
        if !dragRecorded { history.record(start); typingOpen = false; dragRecorded = true }
        var p = start
        change(&p)
        p.relayout(using: measurer)
        page = p
        refresh(force: false)
    }

    private func endDrag() {
        dragStart = nil
        if dragRecorded { persist() }
    }

    private func textEdited(_ id: UUID, _ text: NSAttributedString) {
        if !typingOpen { history.record(page); typingOpen = true }
        let paragraphs = AttributedBridge.paragraphs(from: text)
        page.setParagraphs(id, paragraphs)
        page.relayout(using: measurer)
        // If the model's text differs from the view's (e.g. a new list item needs its marker), re-render.
        let normalised = AttributedBridge.attributed(from: paragraphs).string != text.string
        refresh(force: normalised)
        persist()
    }

    /// An empty container is dropped when it loses focus, like clicking away from a fresh OneNote box.
    private func endEditing(_ id: UUID) {
        guard case .text(let t)? = page.objects.first(where: { $0.id == id }),
              t.paragraphs.allSatisfy({ $0.runs.isEmpty }) else { return }
        page.delete(id)
        if selected == id { selected = nil }
        refresh(force: false)
        persist()
    }

    public func setTitle(_ title: String) {
        guard title != page.title else { return }
        commit { $0.title = title }
    }

    // MARK: undo / redo

    public func undo() {
        guard let prev = history.undo(current: page) else { return }
        restore(prev)
    }

    public func redo() {
        guard let next = history.redo(current: page) else { return }
        restore(next)
    }

    private func restore(_ p: Page) {
        page = p
        typingOpen = false
        if let s = selected, !p.objects.contains(where: { $0.id == s }) { selected = nil }
        refresh(force: true)
        persist()
    }

    // MARK: formatting

    public func applyRun(_ f: RunFormat) {
        guard let focus = pageView.focused() else { return }
        FormatApplier.apply(f, to: focus.textView)
    }

    public func applyParagraph(_ body: (inout Paragraph) -> Void) {
        guard let focus = pageView.focused() else { return }
        let range = AttributedBridge.paragraphRange(forSelection: focus.textView.selectedRange(), in: focus.textView.string)
        commit { $0.editParagraphs(focus.id, in: range, body) }
    }

    // MARK: z-order, delete, copy, paste

    public func bringToFront() { if let id = selected { commit { $0.bringToFront(id) } } }
    public func sendToBack() { if let id = selected { commit { $0.sendToBack(id) } } }

    public func deleteSelected() {
        guard let id = selected else { return }
        selected = nil
        commit { $0.delete(id) }
    }

    public func copySelected() {
        guard let id = selected, case .text(let t)? = page.objects.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(t) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.pasteboardType)
    }

    public func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              var t = try? JSONDecoder().decode(TextContainer.self, from: data) else { return }
        t.id = UUID()
        t.frame.x += 20; t.frame.y += 20
        selected = t.id
        commit { $0.add(.text(t)) }
    }
}
```

- [ ] **Step 3: Build to verify everything compiles and earlier checks still pass**

Run: `swift run Checks`
Expected: `ALL PASSED`.

- [ ] **Step 4: Commit**

```bash
git add Sources
git commit -m "feat(canvas): formatting and page controller" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: App shell and manual acceptance

**Files:**
- Create: `Sources/CanvasKit/AppShell.swift`, `Sources/CanvasApp/main.swift`
- Modify: `Package.swift` (add `CanvasApp` executable target)

**Interfaces:**
- Consumes: `NotebookPackage`, `PageController`, `RunFormat`.
- Produces: `public final class AppShell: NSObject, NSApplicationDelegate`.

- [ ] **Step 1: Add the target to `Package.swift`**

Add this line inside `targets:` after the `Checks` target:

```swift
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasKit"]),
```

- [ ] **Step 2: Create `Sources/CanvasApp/main.swift`**

```swift
import AppKit
import CanvasKit

let app = NSApplication.shared
let shell = AppShell()
app.delegate = shell
app.setActivationPolicy(.regular)
app.run()
```

- [ ] **Step 3: Create `Sources/CanvasKit/AppShell.swift`**

```swift
import AppKit
import PageModel
import Store

public final class AppShell: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var package: NotebookPackage?
    private var controller: PageController?
    private var pages: [PageRef] = []

    private let table = NSTableView()
    private let canvasScroll = NSScrollView()
    private let titleField = NSTextField()
    private let headingPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let colorWell = NSColorWell()

    public override init() { super.init() }

    // MARK: lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        promptForNotebook()
    }

    public func applicationWillTerminate(_ notification: Notification) { controller?.flush() }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: notebook open / create

    private func promptForNotebook() {
        let alert = NSAlert()
        alert.messageText = "Open or create a notebook"
        alert.addButton(withTitle: "New Notebook…")
        alert.addButton(withTitle: "Open Notebook…")
        alert.addButton(withTitle: "Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn: newNotebook(nil)
        case .alertSecondButtonReturn: openNotebook(nil)
        default: NSApp.terminate(nil)
        }
    }

    @objc func newNotebook(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.notebook"
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        do {
            // NSSavePanel already asked about replacing; the store itself refuses to clobber, so clear first.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            var pkg = try NotebookPackage.create(at: url, name: url.deletingPathExtension().lastPathComponent)
            _ = try pkg.addPage(title: "Untitled Page")
            use(pkg)
        } catch { show(error); if package == nil { promptForNotebook() } }
    }

    @objc func openNotebook(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        do { use(try NotebookPackage.open(at: url)) } catch { show(error); if package == nil { promptForNotebook() } }
    }

    private func use(_ pkg: NotebookPackage) {
        controller?.flush()
        package = pkg
        window.title = pkg.notebook.name
        reloadPages()
        if pages.isEmpty, var p = package {
            _ = try? p.addPage(title: "Untitled Page"); package = p; reloadPages()
        }
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func reloadPages() {
        pages = package?.notebook.sections.first?.pages ?? []
        table.reloadData()
    }

    private func showPage(_ id: UUID) {
        controller?.flush()
        guard let pkg = package else { return }
        do {
            let page = try pkg.loadPage(id)
            let c = PageController(page: page)
            c.onPersist = { [weak self] page in self?.save(page) }
            controller = c
            canvasScroll.documentView = c.view
            c.view.frame.size = canvasScroll.contentSize
            titleField.stringValue = page.title
        } catch { show(error) }
    }

    private func save(_ page: Page) {
        do {
            try package?.savePage(page)
            window.title = package?.notebook.name ?? ""
            if let i = pages.firstIndex(where: { $0.id == page.id }), pages[i].title != page.title {
                pages[i].title = page.title; table.reloadData()
            }
        } catch { window.title = "⚠︎ SAVE FAILED: \(error)" }
    }

    private func show(_ error: Error) {
        let a = NSAlert(); a.messageText = "Something went wrong"; a.informativeText = "\(error)"; a.runModal()
    }

    // MARK: pages sidebar

    public func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: pages[row].title)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if pages.indices.contains(row) { showPage(pages[row].id) }
    }

    @objc func addPage(_ sender: Any?) {
        guard var pkg = package else { return }
        do { _ = try pkg.addPage(title: "Untitled Page"); package = pkg; reloadPages()
             table.selectRowIndexes([pages.count - 1], byExtendingSelection: false)
        } catch { show(error) }
    }

    @objc func removePage(_ sender: Any?) {
        guard var pkg = package, pages.indices.contains(table.selectedRow) else { return }
        let id = pages[table.selectedRow].id
        controller = nil
        do { try pkg.deletePage(id: id); package = pkg; reloadPages()
             if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) } else { canvasScroll.documentView = nil }
        } catch { show(error) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) { controller?.setTitle(titleField.stringValue) }

    // MARK: format bar actions

    @objc func bold(_ s: Any?) { controller?.applyRun(.bold) }
    @objc func italic(_ s: Any?) { controller?.applyRun(.italic) }
    @objc func underline(_ s: Any?) { controller?.applyRun(.underline) }
    @objc func strike(_ s: Any?) { controller?.applyRun(.strike) }
    @objc func pickSize(_ s: Any?) { if let v = Double(sizePopup.titleOfSelectedItem ?? "") { controller?.applyRun(.size(v)) } }
    @objc func pickColor(_ s: Any?) { controller?.applyRun(.color(colorWell.color)) }
    @objc func pickHeading(_ s: Any?) { let h = headingPopup.indexOfSelectedItem; controller?.applyParagraph { $0.heading = h } }
    @objc func bullet(_ s: Any?) { controller?.applyParagraph { $0.list = ($0.list == .bullet ? .none : .bullet) } }
    @objc func numbered(_ s: Any?) { controller?.applyParagraph { $0.list = ($0.list == .numbered ? .none : .numbered) } }
    @objc func alignLeft(_ s: Any?) { controller?.applyParagraph { $0.alignment = .left } }
    @objc func alignCenter(_ s: Any?) { controller?.applyParagraph { $0.alignment = .center } }
    @objc func alignRight(_ s: Any?) { controller?.applyParagraph { $0.alignment = .right } }
    @objc func indentMore(_ s: Any?) { controller?.applyParagraph { $0.indent += 1 } }
    @objc func indentLess(_ s: Any?) { controller?.applyParagraph { $0.indent -= 1 } }

    // MARK: menu actions (object-level when no text is being edited)

    private var editingText: Bool { window?.firstResponder is NSTextView }

    @objc func undoAction(_ s: Any?) { controller?.undo() }
    @objc func redoAction(_ s: Any?) { controller?.redo() }
    @objc func copyAction(_ s: Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: s) } else { controller?.copySelected() }
    }
    @objc func pasteAction(_ s: Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: s) } else { controller?.paste() }
    }
    @objc func deleteObject(_ s: Any?) { controller?.deleteSelected() }
    @objc func bringToFront(_ s: Any?) { controller?.bringToFront() }
    @objc func sendToBack(_ s: Any?) { controller?.sendToBack() }

    // MARK: UI construction

    private func button(_ title: String, _ action: Selector, tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.refusesFirstResponder = true         // clicking must not steal focus from the text view
        b.toolTip = tip
        return b
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NoteCanvas"
        window.center()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = table
        sideScroll.hasVerticalScroller = true
        let add = button("+", #selector(addPage(_:)), tip: "Add page")
        let remove = button("−", #selector(removePage(_:)), tip: "Delete page")
        let sideButtons = NSStackView(views: [add, remove])
        let side = NSStackView(views: [sideScroll, sideButtons])
        side.orientation = .vertical
        side.alignment = .leading
        side.widthAnchor.constraint(equalToConstant: 200).isActive = true

        headingPopup.addItems(withTitles: ["Body", "Heading 1", "Heading 2", "Heading 3"])
        headingPopup.target = self; headingPopup.action = #selector(pickHeading(_:)); headingPopup.refusesFirstResponder = true
        sizePopup.addItems(withTitles: ["10", "12", "14", "18", "24", "32"])
        sizePopup.selectItem(withTitle: "14")
        sizePopup.target = self; sizePopup.action = #selector(pickSize(_:)); sizePopup.refusesFirstResponder = true
        colorWell.color = .black
        colorWell.target = self; colorWell.action = #selector(pickColor(_:))

        let bar = NSStackView(views: [
            button("B", #selector(bold(_:)), tip: "Bold"), button("I", #selector(italic(_:)), tip: "Italic"),
            button("U", #selector(underline(_:)), tip: "Underline"), button("S", #selector(strike(_:)), tip: "Strikethrough"),
            sizePopup, colorWell, headingPopup,
            button("•", #selector(bullet(_:)), tip: "Bullets"), button("1.", #selector(numbered(_:)), tip: "Numbering"),
            button("⇤", #selector(alignLeft(_:)), tip: "Align left"), button("↔︎", #selector(alignCenter(_:)), tip: "Center"),
            button("⇥", #selector(alignRight(_:)), tip: "Align right"),
            button("→", #selector(indentMore(_:)), tip: "Indent"), button("←", #selector(indentLess(_:)), tip: "Outdent"),
        ])
        bar.spacing = 6

        titleField.placeholderString = "Page title"
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.delegate = self
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true

        let right = NSStackView(views: [bar, titleField, canvasScroll])
        right.orientation = .vertical
        right.alignment = .leading
        titleField.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        canvasScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        canvasScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let root = NSStackView(views: [side, right])
        root.orientation = .horizontal
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = .command, in menu: NSMenu) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if action != nil, action != #selector(NSApplication.terminate(_:)) { i.target = self }
            menu.addItem(i)
        }
        func submenu(_ title: String) -> NSMenu {
            let holder = NSMenuItem(); main.addItem(holder)
            let m = NSMenu(title: title); holder.submenu = m; return m
        }
        let app = submenu("NoteCanvas")
        item("Quit NoteCanvas", #selector(NSApplication.terminate(_:)), "q", in: app)
        let file = submenu("File")
        item("New Notebook…", #selector(newNotebook(_:)), "n", in: file)
        item("Open Notebook…", #selector(openNotebook(_:)), "o", in: file)
        item("New Page", #selector(addPage(_:)), "t", in: file)
        let edit = submenu("Edit")
        item("Undo", #selector(undoAction(_:)), "z", in: edit)
        item("Redo", #selector(redoAction(_:)), "z", mods: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Copy", #selector(copyAction(_:)), "c", in: edit)
        item("Paste", #selector(pasteAction(_:)), "v", in: edit)
        item("Delete Object", #selector(deleteObject(_:)), "\u{8}", mods: [], in: edit)
        let arrange = submenu("Arrange")
        item("Bring to Front", #selector(bringToFront(_:)), "]", in: arrange)
        item("Send to Back", #selector(sendToBack(_:)), "[", in: arrange)
        NSApp.mainMenu = main
    }
}
```

- [ ] **Step 4: Build the app and the checks**

Run: `swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build" | tail -20` then `swift run Checks`
Expected: builds without errors; `ALL PASSED`.

- [ ] **Step 5: Launch and run the manual acceptance script**

Run: `swift run CanvasApp`

Work through each item in the app and note any that fail:

1. Choose **New Notebook…**, save as `Scratch.notebook` in a throwaway location (not your Documents folder). A page "Untitled Page" appears in the sidebar.
2. Click empty canvas: a box with a blue border appears and has focus. Type `Hello`. Click elsewhere on empty canvas: a new box appears; click away again without typing, and it disappears (Review Focus 1).
3. Select text, press **B**, **I**, **U**, **S**: each toggles; pressing again toggles off. Change size to 24 and colour to red.
4. Set heading 1 on a paragraph: it becomes large. Set **•** and **1.**: markers appear; press Return in a numbered list and the next item gets `2.`. Indent and outdent with the arrow buttons. Align centre and right.
5. Drag the top strip of a box: it moves, including to negative canvas positions (drag past the top-left). Drag the right edge: width changes, text wraps and height follows. Dragging to a tiny width stops at a minimum (Review Focus 2).
6. Create two overlapping boxes, click a box's top strip to select it, use **Arrange → Bring to Front / Send to Back** and confirm z-order changes.
7. **Edit → Undo** repeatedly steps back through typing sessions, moves, resizes and formatting; **Redo** steps forward; undo past the start does nothing (Review Focus 3).
8. Select a box by its strip, **Copy**, **Paste**: a duplicate appears offset by 20 pt. With a box selected, **Delete Object** removes it, and Undo restores it.
9. Type `👩‍👩‍👧 e\u{301} العربية` into a box (paste the visible characters): it renders and survives quit and relaunch (Review Focus 5).
10. Quit and reopen via **Open Notebook…** on `Scratch.notebook`: all boxes, text and formatting are restored. Inspect `Scratch.notebook/pages/*.json` in a text editor: readable, pretty-printed.
11. Corrupt a page file (truncate it with `: > Scratch.notebook/pages/<uuid>.json`), reopen the notebook and select that page: an error alert appears, other pages still open (Review Focus 4).

Expected: every item behaves as described. Record any failures; fix each with a failing check first where the failure is in `PageModel`, `Store` or the bridge.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources
git commit -m "feat(app): window, sidebar, format bar and menus" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage (milestone 1):** `PageModel` (Tasks 2–4), `Store` (Task 5), text-container canvas with move, resize, format, undo (Tasks 6–9), z-order, copy/paste, delete (Tasks 3, 8, 9), autosave (Task 8). Deferred by the spec to later milestones: images, tables, ink (milestone 3), `.one` reader and writer (milestones 2 and 4), the `assets` folder (milestone 3).
- **Known v1 gaps inside this milestone, by design:** font-name, highlight, super/subscript and link are stored and round-trip through the model and bridge but have no toolbar buttons; multi-section UI is not built (the manifest supports sections, the sidebar shows the first); pasting rich text from other apps is not specially handled.
- **Known compromises:** undo of a clicked-in-then-abandoned empty box leaves one no-op undo step; list markers are literal text in the view and re-rendered when the model's text differs; custom (non-system) fonts normalise to their face name on round trip.
