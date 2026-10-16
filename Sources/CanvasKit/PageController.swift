import AppKit
import PageModel
import UniformTypeIdentifiers

public final class PageController {
    public private(set) var page: Page
    /// Writes the page; returns false when the write failed.
    public var onPersist: ((Page) -> Bool)?
    /// Stores pasted or dropped bytes in the notebook and returns the asset file name.
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
    private let objectMenuTarget = ObjectMenuTarget()

    public init(page: Page, assets: @escaping (String) -> Data? = { _ in nil }) {
        self.page = page
        pageView.assets = assets
        pageView.configure = { [weak self] v in self?.wire(v) }
        pageView.configureObject = { [weak self] v in self?.wireObject(v) }
        pageView.onBackgroundClick = { [weak self] point in self?.backgroundClicked(at: point) }
        pageView.onDropFiles = { [weak self] urls, point in self?.dropFiles(urls, at: point) }
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
        v.onRequestMenu = { [weak self] in self?.objectMenu(selecting: id) }
    }

    /// Images, tables and attachments move, select, copy, delete and reorder like text boxes; their content is read-only.
    /// An image also resizes from any corner, keeping its proportions. Right-click offers those actions, plus Open when there is one.
    private func wireObject(_ v: ObjectView) {
        let id = v.id
        if case .image? = page.objects.first(where: { $0.id == id }) { v.cornersEnabled = true }
        v.onDragBegin = { [weak self] in self?.beginDrag(id) }
        v.onMove = { [weak self] dx, dy in self?.drag { $0.move(id, dx: dx, dy: dy) } }
        v.onResize = { [weak self] corner, dx, dy in
            guard let self, let start = self.dragStart, case .image(let image)? = start.objects.first(where: { $0.id == id }) else { return }
            let frame = Page.scaledImageFrame(image.frame, corner: corner, dx: dx, dy: dy)
            self.drag { $0.setImageFrame(id, frame) }
        }
        v.onDragEnd = { [weak self] in self?.endDrag() }
        v.onRequestMenu = { [weak self] in self?.objectMenu(selecting: id) }
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

    /// A click or a right-click selects the box as an object, so keyboard focus moves to the page: Copy, Paste and
    /// Backspace then act on the selected box, not on whichever text view had focus.
    private func selectAsObject(_ id: UUID) {
        sparing = id
        pageView.window?.makeFirstResponder(pageView)   // ends text editing; other empty boxes remove themselves
        sparing = nil
        select(id)
    }

    private func beginDrag(_ id: UUID) {
        selectAsObject(id)
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

    /// Toggles the list on the paragraph being edited, or starts a new list box when nothing is being typed.
    public func insertList(_ list: ListStyle) {
        if pageView.focused() != nil {
            applyParagraph { $0.list = ($0.list == list ? .none : list) }
            return
        }
        let origin = pasteOrigin()
        let box = TextContainer(id: UUID(), frame: Frame(x: origin.x, y: origin.y, width: 320, height: 0),
                                paragraphs: [Paragraph(runs: [], list: list)])
        selected = box.id
        commit { $0.add(.text(box)) }
        pageView.focus(box.id)
    }

    /// Places images on the page, stacked in open space. One undo removes them all.
    public func addImages(_ images: [(data: Data, ext: String, pointSize: NSSize)]) {
        var objects: [PageObject] = []
        for item in images {
            guard let name = storeAsset?(item.data, item.ext) else { continue }
            let size = fitted(item.pointSize)
            objects.append(placed(.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: size.width, height: size.height), asset: name)),
                                  reserved: objects.map(\.frame)))
        }
        commitAdded(objects)
    }

    public func bringToFront() { if let id = selected { commit { $0.bringToFront(id) } } }
    public func sendToBack() { if let id = selected { commit { $0.sendToBack(id) } } }

    /// Right-click selects the object, then offers the actions for its kind.
    private func objectMenu(selecting id: UUID) -> NSMenu? {
        guard page.objects.contains(where: { $0.id == id }) else { return nil }
        selectAsObject(id)
        guard let object = page.objects.first(where: { $0.id == id }) else { return nil }
        objectMenuTarget.open = { [weak self] in self?.openSelected() }
        objectMenuTarget.delete = { [weak self] in self?.deleteSelected() }
        objectMenuTarget.copy = { [weak self] in self?.copySelected() }
        objectMenuTarget.bringToFront = { [weak self] in self?.bringToFront() }
        objectMenuTarget.sendToBack = { [weak self] in self?.sendToBack() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        for item in object.contextMenuItems {
            let entry = NSMenuItem(title: Self.menuTitle(item), action: Self.menuSelector(item), keyEquivalent: "")
            entry.target = objectMenuTarget
            menu.addItem(entry)
        }
        return menu
    }

    /// Open a text box for editing. Open an image or attachment by handing its bytes to the default app.
    /// Assets are often encrypted, so the only readable copy is the one `loadAsset` returns; write that to a temp file.
    private func openSelected() {
        guard let id = selected, let object = page.objects.first(where: { $0.id == id }) else { return }
        switch object {
        case .text:
            pageView.focus(id)
        case .image(let image):
            openStoredFile(asset: image.asset, preferred: "Image")
        case .attachment(let file):
            openStoredFile(asset: file.asset, preferred: file.displayName)
        case .table:
            break
        }
    }

    private func openStoredFile(asset: String, preferred: String) {
        guard let data = pageView.assets(asset), !data.isEmpty else { NSSound.beep(); return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCanvas", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(Self.exportFileName(preferred: preferred, asset: asset))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if !NSWorkspace.shared.open(url) { NSSound.beep() }
        } catch {
            NSSound.beep()
        }
    }

    /// One path component, safe to give another app. Directory pieces are dropped. The asset's extension
    /// is added when the preferred name has none, so Word or Preview can tell the type.
    private static func exportFileName(preferred: String, asset: String) -> String {
        let slashed = preferred.replacingOccurrences(of: "\\", with: "/")
        var name = (slashed as NSString).lastPathComponent
        name = name.components(separatedBy: CharacterSet(charactersIn: ":").union(.controlCharacters)).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "File" }
        let ext = String((asset as NSString).pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        if (name as NSString).pathExtension.isEmpty, !ext.isEmpty { name += ".\(ext)" }
        if name.utf8.count > 200 { name = ext.isEmpty ? "File" : "File.\(ext)" }
        return name
    }

    private static func menuTitle(_ item: ObjectMenuItem) -> String {
        switch item {
        case .open: return "Open"
        case .delete: return "Delete"
        case .copy: return "Copy"
        case .bringToFront: return "Bring to Front"
        case .sendToBack: return "Send to Back"
        }
    }

    private static func menuSelector(_ item: ObjectMenuItem) -> Selector {
        switch item {
        case .open: return #selector(ObjectMenuTarget.openItem(_:))
        case .delete: return #selector(ObjectMenuTarget.deleteItem(_:))
        case .copy: return #selector(ObjectMenuTarget.copyItem(_:))
        case .bringToFront: return #selector(ObjectMenuTarget.frontItem(_:))
        case .sendToBack: return #selector(ObjectMenuTarget.backItem(_:))
        }
    }

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
            var copy = object.duplicated(dx: 20, dy: 20)
            if case .image = copy { copy = placed(copy, reserved: []) }
            commitAdded([copy])
            return
        }
        var objects: [PageObject] = []
        func place(_ object: PageObject) {
            objects.append(placed(object, reserved: objects.map(\.frame)))
        }
        for image in pastedImages(pasteboard) {
            guard let data = pngData(image), let name = storeAsset?(data, "png") else { continue }
            let size = fitted(image.size)
            place(.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: size.width, height: size.height), asset: name)))
        }
        if objects.isEmpty {
            for url in pastedFileURLs(pasteboard) {
                if let object = object(fromFile: url) { place(object) }
            }
        }
        if objects.isEmpty, pageView.focused() == nil,
           let text = pasteboard.string(forType: .string)?.replacingOccurrences(of: "\r\n", with: "\n"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map {
                Paragraph(runs: [Run(text: String($0), style: RunStyle())])
            }
            let origin = pasteOrigin()
            objects = [.text(TextContainer(id: UUID(), frame: Frame(x: origin.x, y: origin.y, width: 360, height: 0),
                                            paragraphs: paragraphs))]
        }
        commitAdded(objects)
    }

    /// Files dropped on the page, stacked down from the drop point. One undo removes the whole drop.
    private func dropFiles(_ urls: [URL], at point: NSPoint) {
        let origin = (x: Double(point.x), y: Double(point.y))
        var objects: [PageObject] = []
        for url in urls {
            guard var object = object(fromFile: url) else { continue }
            object.frame.x = origin.x
            object.frame.y = Page.stackedY(reserved: objects.map(\.frame), y: origin.y)
            objects.append(object)
        }
        commitAdded(objects)
    }

    /// Adds every object in one undo step and selects the last.
    private func commitAdded(_ objects: [PageObject]) {
        guard !objects.isEmpty else { return }
        selected = objects.last?.id
        commit { page in for object in objects { page.add(object) } }
    }

    /// The paste and drop storage path: copy the file into the notebook and make an image or an attachment.
    /// The frame origin is unset; the caller places it. A file that is not an image, including a document or PDF, is an attachment.
    private func object(fromFile url: URL) -> PageObject? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let name = storeAsset?(data, url.pathExtension) else { return nil }
        let isImage = (UTType(filenameExtension: url.pathExtension) ?? .data).conforms(to: .image)
        if isImage, let image = NSImage(data: data) {
            let size = fitted(image.size)
            return .image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: size.width, height: size.height), asset: name))
        }
        let display = url.lastPathComponent.isEmpty ? "Attachment" : url.lastPathComponent
        return .attachment(AttachmentObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 160, height: 64),
                                             asset: name, displayName: display))
    }

    /// An image lands where the user is looking, below anything it would cover. Anything else stacks from that spot.
    private func placed(_ object: PageObject, reserved: [Frame]) -> PageObject {
        let origin = pasteOrigin()
        var placed = object
        if case .image = object {
            let spot = Page.clearOrigin(width: object.frame.width, height: object.frame.height,
                                         nearX: origin.x, nearY: origin.y,
                                         avoiding: page.objects.map(\.frame) + reserved)
            placed.frame.x = spot.x
            placed.frame.y = spot.y
        } else {
            placed.frame.x = origin.x
            placed.frame.y = Page.stackedY(reserved: reserved, y: origin.y)
        }
        return placed
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

/// Target for an object's context menu. Actions run after menu tracking returns, so deleting
/// the clicked view does not free it while AppKit is still inside its right-click.
private final class ObjectMenuTarget: NSObject {
    var open: () -> Void = {}
    var delete: () -> Void = {}
    var copy: () -> Void = {}
    var bringToFront: () -> Void = {}
    var sendToBack: () -> Void = {}

    @objc func openItem(_ sender: Any?) { later(open) }
    @objc func deleteItem(_ sender: Any?) { later(delete) }
    @objc func copyItem(_ sender: Any?) { later(copy) }
    @objc func frontItem(_ sender: Any?) { later(bringToFront) }
    @objc func backItem(_ sender: Any?) { later(sendToBack) }

    private func later(_ action: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.default], block: action)
    }
}
