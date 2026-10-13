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
