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
