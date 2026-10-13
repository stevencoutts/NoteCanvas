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
    private var typingContainer: UUID?              // container whose typing session is the open undo step
    private var justCreated: UUID?                  // box made by a background click, not yet typed in
    private var dragStart: Page?
    private var dragRecorded = false
    private var persistWork: DispatchWorkItem?
    private var isRefreshing = false                // true while PageView.sync runs; focus changes then are programmatic
    private var sparing: UUID?                      // box whose own strip was grabbed: losing focus must not remove it

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
        v.onFocus = { [weak self] in self?.textFocused() }
    }

    private func refresh(force: Bool) {
        isRefreshing = true
        defer { isRefreshing = false }
        pageView.sync(page, forceText: force, selected: selected)
    }

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
        typingContainer = nil
        justCreated = nil
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
        justCreated = id
        refresh(force: false)
        pageView.focus(id)
    }

    private func select(_ id: UUID?) {
        if id != selected { typingContainer = nil }
        selected = id
        refresh(force: false)
    }

    /// Grabbing a strip selects the box as an object, so keyboard focus moves to the page: Copy, Paste and
    /// Backspace then act on the selected box, not on whichever text view had focus.
    private func beginDrag(_ id: UUID) {
        sparing = id
        pageView.window?.makeFirstResponder(pageView)   // ends text editing; other empty boxes remove themselves
        sparing = nil
        select(id)
        dragStart = page
        dragRecorded = false
    }

    private func drag(_ change: (inout Page) -> Void) {
        guard let start = dragStart else { return }
        if !dragRecorded { history.record(start); typingContainer = nil; justCreated = nil; dragRecorded = true }
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

    /// A text view took focus: the keyboard now edits text, so no box is selected as an object.
    private func textFocused() {
        guard !isRefreshing, selected != nil else { return }
        selected = nil
        refresh(force: false)
    }

    private func textEdited(_ id: UUID, _ text: NSAttributedString) {
        guard !isRefreshing else { return }
        if typingContainer != id { history.record(page); typingContainer = id }
        if justCreated != nil { justCreated = nil }
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
        guard !isRefreshing, id != sparing else { return }
        guard case .text(let t)? = page.objects.first(where: { $0.id == id }),
              t.paragraphs.allSatisfy({ $0.runs.isEmpty }) else { return }
        typingContainer = nil
        if justCreated == id { history.discardLast(); justCreated = nil }
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
        typingContainer = nil
        justCreated = nil
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
