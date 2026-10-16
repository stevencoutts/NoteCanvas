import AppKit
import PageModel

final class PageView: NSView {
    var configure: ((ContainerView) -> Void)?
    var configureObject: ((ObjectView) -> Void)?
    var onBackgroundClick: ((NSPoint) -> Void)?
    /// File URLs dropped on the paper, in page coordinates. Text boxes forward here too, so a drop never types into a box.
    var onDropFiles: (([URL], NSPoint) -> Void)?
    var assets: (String) -> Data? = { _ in nil }
    private var views: [UUID: ContainerView] = [:]
    private var objectViews: [UUID: ObjectView] = [:]
    private var contentExtent = NSSize.zero
    private var clipObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }   // holds keyboard focus while a box is selected as an object

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)     // the page is always light; text defaults to black
        registerForDraggedTypes([.fileURL])         // empty paper accepts a Finder drop, not only the objects on it
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver); self.clipObserver = nil }
        guard let clip = superview else { return }
        clip.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.fitVisibleCanvas()
        }
        fitVisibleCanvas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.99, green: 0.975, blue: 0.955, alpha: 1).setFill()
        dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?(convert(event.locationInWindow, from: nil)) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrag.isFile(sender) ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDrag.urls(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, convert(sender.draggingLocation, from: nil))
        return true
    }

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

        contentExtent = NSSize(width: extentX + 400, height: extentY + 400)
        fitVisibleCanvas()
        needsDisplay = true
    }

    /// The page is at least as large as the visible sheet, and it grows when the window does.
    private func fitVisibleCanvas() {
        let visible = enclosingScrollView?.contentSize ?? .zero
        let size = NSSize(width: max(visible.width, contentExtent.width),
                          height: max(visible.height, contentExtent.height))
        guard abs(bounds.width - size.width) > 0.5 || abs(bounds.height - size.height) > 0.5 else { return }
        setFrameSize(size)
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

/// File URLs only. A string, picture, or web link on the pasteboard is not a drop this page accepts.
enum FileDrag {
    private static let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func isFile(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    static func urls(_ sender: NSDraggingInfo) -> [URL] {
        guard isFile(sender) else { return [] }
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
