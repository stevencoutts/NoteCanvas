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
