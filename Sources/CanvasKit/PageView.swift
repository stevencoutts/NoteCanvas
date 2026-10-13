import AppKit
import PageModel

final class PageView: NSView {
    var configure: ((ContainerView) -> Void)?
    var onBackgroundClick: ((NSPoint) -> Void)?
    private var views: [UUID: ContainerView] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }   // holds keyboard focus while a box is selected as an object

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
