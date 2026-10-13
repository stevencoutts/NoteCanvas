import AppKit
import PageModel
import UniformTypeIdentifiers

public final class PageController {
    public private(set) var page: Page
    /// Writes the page; returns false when the write failed.
    public var onPersist: ((Page) -> Bool)?
    /// Stores pasted bytes in the notebook and returns the asset file name.
    public var storeAsset: ((Data, String) -> String?)?
    public var view: NSView { pageView }
    public var hasSelectedObject: Bool { selected != nil }

    static let pasteboardType = NSPasteboard.PasteboardType("com.notecanvas.object")

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

    public init(page: Page, assets: @escaping (String) -> Data? = { _ in nil }) {
        self.page = page
        pageView.assets = assets
        pageView.configure = { [weak self] v in self?.wire(v) }
        pageView.configureObject = { [weak self] v in self?.wireObject(v) }
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

    /// Images, tables and attachments move, select, copy, delete and reorder like text boxes; their content is read-only.
    private func wireObject(_ v: ObjectView) {
        let id = v.id
        v.onDragBegin = { [weak self] in self?.beginDrag(id) }
        v.onMove = { [weak self] dx, dy in self?.drag { $0.move(id, dx: dx, dy: dy) } }
        v.onDragEnd = { [weak self] in self?.endDrag() }
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
            _ = self.onPersist?(self.page)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write immediately (page switch, quit). Returns false when the write failed.
    @discardableResult
    public func flush() -> Bool {
        persistWork?.cancel()
        persistWork = nil
        return onPersist?(page) ?? true
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
        guard let id = selected, let object = page.objects.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(object) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.pasteboardType)
    }

    /// Image types only. A text copy can also offer a TIFF snapshot, and that must stay text.
    private static let imagePasteTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.bmp.identifier),
    ]

    /// True when the clipboard holds something this canvas should place as an object (not text to type).
    public static func clipboardHasCanvasContent(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: pasteboardType) != nil { return true }
        if pasteboard.availableType(from: imagePasteTypes) != nil { return true }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    public func paste() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let object = try? JSONDecoder().decode(PageObject.self, from: data) {
            let copy = object.duplicated(dx: 20, dy: 20)
            selected = copy.id
            commit { $0.add(copy) }
            return
        }
        var objects: [PageObject] = []
        let origin = pasteOrigin()
        var y = origin.y
        func place(_ object: PageObject) {
            var placed = object
            placed.frame.x = origin.x
            placed.frame.y = y
            y += placed.frame.height + 16
            objects.append(placed)
        }
        for image in pastedImages(pasteboard) {
            guard let data = pngData(image), let name = storeAsset?(data, "png") else { continue }
            let size = fitted(image.size)
            place(.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: size.width, height: size.height), asset: name)))
        }
        if objects.isEmpty {
            for url in pastedFileURLs(pasteboard) {
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      let name = storeAsset?(data, url.pathExtension) else { continue }
                let isImage = (UTType(filenameExtension: url.pathExtension) ?? .data).conforms(to: .image)
                if isImage, let image = NSImage(data: data) {
                    let size = fitted(image.size)
                    place(.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: size.width, height: size.height), asset: name)))
                } else {
                    let display = url.lastPathComponent.isEmpty ? "Attachment" : url.lastPathComponent
                    place(.attachment(AttachmentObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 160, height: 64),
                                                        asset: name, displayName: display)))
                }
            }
        }
        if objects.isEmpty, pageView.focused() == nil,
           let text = pasteboard.string(forType: .string)?.replacingOccurrences(of: "\r\n", with: "\n"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map {
                Paragraph(runs: [Run(text: String($0), style: RunStyle())])
            }
            objects = [.text(TextContainer(id: UUID(), frame: Frame(x: origin.x, y: origin.y, width: 360, height: 0),
                                            paragraphs: paragraphs))]
        }
        guard !objects.isEmpty else { return }
        selected = objects.last?.id
        commit { page in for object in objects { page.add(object) } }
    }

    private func pasteOrigin() -> (x: Double, y: Double) {
        let visible = pageView.visibleRect
        guard !visible.isEmpty else { return (48, 72) }
        return (Double(visible.minX) + 32, Double(visible.minY) + 32)
    }

    private func pastedImages(_ pasteboard: NSPasteboard) -> [NSImage] {
        guard pasteboard.availableType(from: Self.imagePasteTypes) != nil else { return [] }
        return pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
    }

    private func pastedFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Longest side at most 480 points, keeping the image's aspect ratio.
    private func fitted(_ size: NSSize) -> NSSize {
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return NSSize(width: 240, height: 180) }
        let scale = min(1, 480 / max(w, h))
        return NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}
