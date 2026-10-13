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
