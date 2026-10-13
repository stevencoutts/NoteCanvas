import Foundation

public enum Script: String, Codable, Sendable { case normal, sup, sub }

public struct RunStyle: Codable, Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var fontName: String?
    public var fontSize: Double?
    public var colorHex: String?
    public var highlightHex: String?
    public var script: Script = .normal
    public var link: String?
    public init() {}
}

public struct Run: Codable, Equatable, Sendable {
    public var text: String
    public var style: RunStyle
    public init(text: String, style: RunStyle) { self.text = text; self.style = style }
}

public enum ListStyle: String, Codable, Sendable { case none, bullet, numbered }
public enum Alignment: String, Codable, Sendable { case left, center, right }

public struct Paragraph: Codable, Equatable, Sendable {
    public static let maxIndent = 8
    public var runs: [Run]
    public var indent: Int
    public var heading: Int          // 0 = body, 1...3 = heading level
    public var list: ListStyle
    public var alignment: Alignment

    public init(runs: [Run], indent: Int = 0, heading: Int = 0,
                list: ListStyle = .none, alignment: Alignment = .left) {
        self.runs = runs; self.indent = indent; self.heading = heading
        self.list = list; self.alignment = alignment
    }

    public mutating func clamp() {
        indent = min(max(indent, 0), Paragraph.maxIndent)
        heading = min(max(heading, 0), 3)
    }
}

public struct TextContainer: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var paragraphs: [Paragraph]
    public init(id: UUID, frame: Frame, paragraphs: [Paragraph]) {
        self.id = id; self.frame = frame; self.paragraphs = paragraphs
    }
}
