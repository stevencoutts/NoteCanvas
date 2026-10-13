import Foundation

public struct ImageObject: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var asset: String            // file name inside the notebook's assets/ folder
    public var altText: String?
    public init(id: UUID, frame: Frame, asset: String, altText: String? = nil) {
        self.id = id; self.frame = frame; self.asset = asset; self.altText = altText
    }
}

public struct TableCell: Codable, Equatable, Sendable {
    public var paragraphs: [Paragraph]
    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }
}

public struct TableObject: Codable, Equatable, Sendable {
    public static let cellPadding = 4.0
    public static let minRowHeight = 20.0

    public var id: UUID
    public var frame: Frame             // width = sum of columnWidths and height = sum of row heights, both derived
    public var columnWidths: [Double]
    public var rows: [[TableCell]]
    public var bordersVisible: Bool

    public init(id: UUID, frame: Frame, columnWidths: [Double], rows: [[TableCell]], bordersVisible: Bool) {
        self.id = id; self.frame = frame; self.columnWidths = columnWidths; self.rows = rows
        self.bordersVisible = bordersVisible
    }

    /// Row heights derived from cell content; layout and drawing both use this so they agree.
    public func rowHeights(using measurer: TextMeasuring) -> [Double] {
        rows.map { row in
            var h = TableObject.minRowHeight
            for (c, cell) in row.enumerated() {
                let w = c < columnWidths.count ? columnWidths[c] : 0
                let text = measurer.textHeight(of: cell.paragraphs, width: max(w - 2 * TableObject.cellPadding, 1))
                h = max(h, text + 2 * TableObject.cellPadding)
            }
            return h
        }
    }
}

public struct AttachmentObject: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: Frame
    public var asset: String
    public var displayName: String
    public init(id: UUID, frame: Frame, asset: String, displayName: String) {
        self.id = id; self.frame = frame; self.asset = asset; self.displayName = displayName
    }
}

public enum AssetName {
    /// A fresh unique asset file name. `ext` is reduced to at most 8 lower-case ASCII letters/digits, else "bin".
    public static func make(ext: String) -> String {
        let clean = String(ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return "\(UUID().uuidString).\(clean.isEmpty ? "bin" : clean)"
    }
}
