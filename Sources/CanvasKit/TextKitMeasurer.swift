import AppKit
import PageModel

enum Metrics {
    static let handleHeight: Double = 14
    static let inset: Double = 6
    static let gripWidth: Double = 8
}

public struct TextKitMeasurer: TextMeasuring {
    public init() {}

    public func height(of paragraphs: [Paragraph], width: Double) -> Double {
        let storage = NSTextStorage(attributedString: AttributedBridge.attributed(from: paragraphs))
        let textWidth = max(width - Metrics.inset - Metrics.gripWidth, 1)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let text = Double(layout.usedRect(for: container).height)
        return Metrics.handleHeight + Metrics.inset * 2 + text
    }
}
