import AppKit
import PageModel

/// A thin strip that reports total mouse movement since mouse-down.
/// `followsPointer` reports the drag in the page's flipped coordinates, from the mouse-down point, and draws a knob.
final class DragStrip: NSView {
    var cursor: NSCursor = .openHand
    var fill: NSColor = NSColor.black.withAlphaComponent(0.06)
    var followsPointer = false
    var onBegin: (() -> Void)?
    var onDelta: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    private var total = NSPoint.zero
    private var anchor = NSPoint.zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func draw(_ dirtyRect: NSRect) {
        guard followsPointer else { fill.setFill(); bounds.fill(); return }
        let knob = bounds.insetBy(dx: 3, dy: 3)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor(srgbRed: 0.38, green: 0.46, blue: 0.52, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1.5
        ring.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        anchor = event.locationInWindow
        total = .zero
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        if followsPointer {
            let point = event.locationInWindow
            onDelta?(Double(point.x - anchor.x), Double(anchor.y - point.y))
        } else {
            total.x += event.deltaX; total.y += event.deltaY
            onDelta?(Double(total.x), Double(total.y))
        }
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// Reports when it takes keyboard focus (a click, Tab, or a programmatic focus).
final class BoxTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    /// Command-click opens a link. A plain click still places the caret, so the text stays editable.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func link(at event: NSEvent) -> URL? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let value = storage.attribute(.link, at: index, effectiveRange: nil) else { return nil }
        if let url = value as? URL { return url }
        return (value as? String).flatMap { URL(string: $0) }
    }

    /// Marks every web address, "www." address and email address that is not already a link.
    static func linkified(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        detector.enumerateMatches(in: result.string, options: [], range: NSRange(location: 0, length: result.length)) { match, _, _ in
            guard let match, let url = match.url else { return }
            var linked = false
            result.enumerateAttribute(.link, in: match.range) { value, _, stop in
                if value != nil { linked = true; stop.pointee = true }
            }
            if !linked { result.addAttribute(.link, value: url.absoluteString, range: match.range) }
        }
        return result
    }
}

final class ContainerView: NSView, NSTextViewDelegate {
    private static let strip = NSColor(srgbRed: 0.45, green: 0.38, blue: 0.30, alpha: 1)
    let id: UUID
    let handle = DragStrip()
    let grip = DragStrip()
    let textView = BoxTextView(usingTextLayoutManager: false)  // TextKit 1, matches TextKitMeasurer

    var onDragBegin: (() -> Void)?
    var onMove: ((Double, Double) -> Void)?
    var onResizeBegin: (() -> Void)?
    var onResize: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onTextChange: ((NSAttributedString) -> Void)?
    var onEndEditing: (() -> Void)?
    var onFocus: (() -> Void)? {
        get { textView.onFocus }
        set { textView.onFocus = newValue }
    }

    var isSelectedObject = false { didSet { updateChrome() } }
    var isEditing: Bool { window?.firstResponder === textView }
    override var isFlipped: Bool { true }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = true   // typed or pasted addresses become links
        textView.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.link.rawValue
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand]
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
        handle.fill = Self.strip.withAlphaComponent(0.05)
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

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(textView) }

    /// The drag strip stays almost invisible until the box is selected or being edited.
    private func updateChrome() {
        let active = isSelectedObject || isEditing
        handle.fill = Self.strip.withAlphaComponent(active ? 0.16 : 0.05)
        handle.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelectedObject || isEditing else { return }
        NSColor(srgbRed: 0.38, green: 0.46, blue: 0.52, alpha: 0.85).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        path.stroke()
    }

    /// Re-renders the text, carrying the selection over as (paragraph, body offset) so a marker that
    /// appears or disappears does not leave the caret inside or before it.
    func setParagraphs(_ paragraphs: [Paragraph]) {
        let selection = AttributedBridge.bodySelection(textView.selectedRange(), in: textView.attributedString())
        let text = BoxTextView.linkified(AttributedBridge.attributed(from: paragraphs))
        textView.textStorage?.setAttributedString(text)
        let range = AttributedBridge.range(of: selection, in: text)
        textView.setSelectedRange(range)
        // The empty line after a final "\n" has no character of its own, so NSTextView would type into it with the
        // previous paragraph's attributes (e.g. bring back a bullet the user just removed); use the model's instead.
        if let last = paragraphs.last, range.location == text.length, text.string.hasSuffix("\n") {
            textView.typingAttributes.merge(AttributedBridge.paragraphAttributes(last)) { $1 }
        }
    }

    // MARK: NSTextViewDelegate
    func textDidChange(_ notification: Notification) { onTextChange?(textView.attributedString()) }
    func textDidEndEditing(_ notification: Notification) { updateChrome(); onEndEditing?() }
    func textDidBeginEditing(_ notification: Notification) { updateChrome() }
    /// Text typed beside a list marker must never inherit the marker tag.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        AttributedBridge.typingAttributes(newTypingAttributes)
    }
}
