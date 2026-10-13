import AppKit
import PageModel

enum Metrics {
    static let handleHeight: Double = 14
    static let inset: Double = 6
    static let gripWidth: Double = 8
}

public struct TextKitMeasurer: TextMeasuring {
    public init() {}

    /// Height of the text alone laid out at exactly `width` (no container chrome); at least one base-font line,
    /// and it includes the extra fragment after a trailing newline.
    public func textHeight(of paragraphs: [Paragraph], width: Double) -> Double {
        let storage = NSTextStorage(attributedString: AttributedBridge.attributed(from: paragraphs))
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let line = Double(layout.defaultLineHeight(for: NSFont.systemFont(ofSize: AttributedBridge.baseSize)))
        let extra = Double(layout.extraLineFragmentRect.height)
        return max(Double(layout.usedRect(for: container).height), line, extra)
    }

    /// A text container: the handle strip, the insets and the grip around text laid out in the remaining width.
    public func height(of paragraphs: [Paragraph], width: Double) -> Double {
        Metrics.handleHeight + Metrics.inset * 2
            + textHeight(of: paragraphs, width: max(width - Metrics.inset - Metrics.gripWidth, 1))
    }
}
