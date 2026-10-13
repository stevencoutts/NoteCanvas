import Foundation
import OneStore
import PageModel

/// Collects asset files during an import, storing each source object's bytes once.
final class AssetSink {
    private(set) var items: [ImportedAsset] = []
    private var byObject: [ExtendedGUID: String] = [:]

    func add(object id: ExtendedGUID, data: Data, ext: String) -> String {
        if let name = byObject[id] { return name }
        let name = AssetName.make(ext: ext)
        items.append(ImportedAsset(name: name, data: data))
        byObject[id] = name
        return name
    }
}

/// Maps one page's object graph to a `Page`, flattening outlines around inline images, tables and attachments.
final class PageMapper {
    static let unit = 36.0                       // points per half-inch layout unit
    static let defaultOutlineWidth = 432.0
    static let indentStep = 24.0
    static let attachmentSize = (width: 120.0, height: 60.0)
    static let maxDepth = 64
    static let maxLayoutUnits: Float = 10_000

    let graph: ObjectGraph
    let measurer: TextMeasuring
    let assets: (OneObject) -> (data: Data, ext: String)?
    let sink: AssetSink
    var report = ImportReport()
    private let paragraphs: ParagraphMapper

    init(graph: ObjectGraph, measurer: TextMeasuring, assets: @escaping (OneObject) -> (data: Data, ext: String)?, sink: AssetSink) {
        self.graph = graph; self.measurer = measurer; self.assets = assets; self.sink = sink
        self.paragraphs = ParagraphMapper(graph: graph)
    }

    /// A layout float from the file (half-inch units) when it is finite and sane; otherwise nil, counted as invalid.
    private func layoutValue(_ f: Float?) -> Double? {
        guard let f else { return nil }
        guard f.isFinite, abs(f) <= Self.maxLayoutUnits else { report.approximated("invalidLayoutValue"); return nil }
        return Double(f)
    }

    func mapPage(_ page: OneObject) -> Page {
        report.noteIgnoredProperties(of: page, consumed: PID.consumedByPage)
        var title = ""
        var objects: [PageObject] = []
        for child in graph.children(of: page, PID.elementChildren, report: &report) {
            switch child.jcid {
            case .title:
                title = mapTitle(child)
            case .outline:
                objects += mapOutline(child)
            case .image, .table, .embeddedFile:
                let x = (layoutValue(child.properties.float(PID.offsetH)) ?? 0) * Self.unit
                let y = (layoutValue(child.properties.float(PID.offsetV)) ?? 0) * Self.unit
                if let object = mapBlock(child, x: x, y: y) { objects.append(object) }
            default:
                report.skipped(child.jcid)
            }
        }
        var result = Page(id: UUID(), title: title.isEmpty ? "Untitled Page" : title, objects: objects)
        result.relayout(using: measurer)
        return result
    }

    // MARK: title

    /// The title text; date and time lines are dropped (and counted). Style counters from the title are not kept.
    private func mapTitle(_ title: OneObject) -> String {
        var scratch = ImportReport()
        var lines: [String] = []
        let titleParagraphs = ParagraphMapper(graph: graph)    // its own style ledger, so body text still counts shared styles
        for outline in graph.children(of: title, PID.elementChildren, report: &scratch) where outline.jcid == .outline {
            for element in graph.children(of: outline, PID.elementChildren, report: &scratch) {
                for content in graph.children(of: element, PID.contentChildren, report: &scratch) where content.jcid == .richText {
                    if content.properties.bool(PID.isTitleDate) == true || content.properties.bool(PID.isTitleTime) == true {
                        report.approximated("titleDateDropped")
                        continue
                    }
                    let p = titleParagraphs.paragraph(richText: content, indent: 0, list: .none, report: &scratch)
                    let text = p.runs.map(\.text).joined()
                    if !text.isEmpty { lines.append(text) }
                }
            }
        }
        if let n = scratch.approximations["charsetFallback"], n > 0 { report.approximated("charsetFallback", n) }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: outlines

    private func mapOutline(_ outline: OneObject) -> [PageObject] {
        report.noteIgnoredProperties(of: outline, consumed: PID.consumedByOutline)
        let p = outline.properties
        let ox = layoutValue(p.float(PID.offsetH)), oy = layoutValue(p.float(PID.offsetV))
        if ox == nil || oy == nil { report.approximated("outlineWithoutPosition") }
        let x = (ox ?? 0) * Self.unit
        var y = (oy ?? 0) * Self.unit
        var width = (layoutValue(p.float(PID.maxWidth)) ?? layoutValue(p.float(PID.reservedWidth))).map { $0 * Self.unit } ?? Self.defaultOutlineWidth
        if width <= 0 { width = Self.defaultOutlineWidth }
        var out: [PageObject] = []
        var pending: [Paragraph] = []
        var visited = Set<ExtendedGUID>()

        func flush() {
            guard !pending.isEmpty else { return }
            let h = max(measurer.height(of: pending, width: width), Page.minContainerHeight)
            out.append(.text(TextContainer(id: UUID(), frame: Frame(x: x, y: y, width: width, height: h), paragraphs: pending)))
            report.imported("text")
            report.imported("paragraph", pending.count)
            y += h
            pending = []
        }

        func walk(_ element: OneObject, depth: Int) {
            guard depth < Self.maxDepth, visited.insert(element.id).inserted else {
                report.approximated("elementLoopOrTooDeep")
                return
            }
            report.noteIgnoredProperties(of: element, consumed: PID.consumedByElement)
            var list: ListStyle = .none
            if let node = graph.children(of: element, PID.listNodes, report: &report).first {
                report.noteIgnoredProperties(of: node, consumed: PID.consumedByNumberList)
                list = ParagraphMapper.listStyle(of: node)
            }
            let indent = min(depth, Paragraph.maxIndent)
            for content in graph.children(of: element, PID.contentChildren, report: &report) {
                switch content.jcid {
                case .richText:
                    pending.append(paragraphs.paragraph(richText: content, indent: indent, list: list, report: &report))
                case .image, .table, .embeddedFile:
                    flush()
                    if let object = mapBlock(content, x: x + Double(indent) * Self.indentStep, y: y) {
                        out.append(object)
                        y += object.frame.height
                    }
                default:
                    report.skipped(content.jcid)
                }
            }
            for child in graph.children(of: element, PID.elementChildren, report: &report) {
                if child.jcid == .outlineElement { walk(child, depth: depth + 1) } else { report.skipped(child.jcid) }
            }
        }

        for element in graph.children(of: outline, PID.elementChildren, report: &report) {
            switch element.jcid {
            case .outlineElement:
                walk(element, depth: 0)
            case .outlineGroup:
                for inner in graph.children(of: element, PID.elementChildren, report: &report) {
                    if inner.jcid == .outlineElement { walk(inner, depth: 0) } else { report.skipped(inner.jcid) }
                }
            default:
                report.skipped(element.jcid)
            }
        }
        flush()
        return out
    }

    // MARK: images, tables, attachments

    private func mapBlock(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        switch node.jcid {
        case .image: return mapImage(node, x: x, y: y)
        case .table: return mapTable(node, x: x, y: y)
        default: return mapAttachment(node, x: x, y: y)
        }
    }

    private func mapImage(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByImage)
        let p = node.properties
        var container = graph.children(of: node, PID.pictureContainer, report: &report).first
        if container == nil { container = graph.children(of: node, PID.webPictureContainer, report: &report).first }
        guard let container, let file = assets(container) else {
            report.approximated("imageDataMissing")
            return nil
        }
        var width = layoutValue(p.float(PID.maxWidth)).map { $0 * Self.unit } ?? 100
        if width <= 0 { width = 100 }
        var height = layoutValue(p.float(PID.maxHeight)).map { $0 * Self.unit } ?? width
        if height <= 0 { height = width }
        let name = sink.add(object: container.id, data: file.data, ext: file.ext)
        let alt = p.string(PID.imageAltText).flatMap { $0.isEmpty ? nil : $0 }
        report.imported("image")
        return .image(ImageObject(id: UUID(), frame: Frame(x: x, y: y, width: width, height: height), asset: name, altText: alt))
    }

    private func mapTable(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByTable)
        var rows: [[TableCell]] = []
        for rowNode in graph.children(of: node, PID.elementChildren, report: &report) {
            guard rowNode.jcid == .tableRow else { report.skipped(rowNode.jcid); continue }
            var cells: [TableCell] = []
            for cellNode in graph.children(of: rowNode, PID.elementChildren, report: &report) {
                guard cellNode.jcid == .tableCell else { report.skipped(cellNode.jcid); continue }
                cells.append(TableCell(paragraphs: mapCellParagraphs(cellNode)))
            }
            rows.append(cells)
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { report.approximated("emptyTableSkipped"); return nil }
        var widths = columnWidths(node.properties.data(PID.tableColumnWidths))
        if widths.count != columns {
            report.approximated("tableColumnWidthsAdjusted")
            widths = Array(widths.prefix(columns)) + [Double](repeating: 100, count: max(0, columns - widths.count))
        }
        var table = TableObject(id: UUID(), frame: Frame(x: x, y: y, width: 0, height: 0), columnWidths: widths, rows: rows,
                                bordersVisible: node.properties.bool(PID.tableBordersVisible) ?? true)
        table.frame.width = widths.reduce(0, +)
        table.frame.height = table.rowHeights(using: measurer).reduce(0, +)
        report.imported("table")
        return .table(table)
    }

    /// TableColumnWidths: one byte with the column count, then that many 4-byte floats (half-inch units).
    private func columnWidths(_ data: Data?) -> [Double] {
        guard let d = data, let count = d.first.map(Int.init), d.count >= 1 + 4 * count else { return [] }
        return (0..<count).map { i in
            let b = d.startIndex + 1 + 4 * i
            let bits = UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
            return max((layoutValue(Float(bitPattern: bits)) ?? 100 / Self.unit) * Self.unit, 1)
        }
    }

    private func mapCellParagraphs(_ cell: OneObject) -> [Paragraph] {
        var result: [Paragraph] = []
        var visited = Set<ExtendedGUID>()
        func walk(_ element: OneObject, depth: Int) {
            guard depth < Self.maxDepth, visited.insert(element.id).inserted else {
                report.approximated("elementLoopOrTooDeep")
                return
            }
            var list: ListStyle = .none
            if let node = graph.children(of: element, PID.listNodes, report: &report).first { list = ParagraphMapper.listStyle(of: node) }
            for content in graph.children(of: element, PID.contentChildren, report: &report) {
                switch content.jcid {
                case .richText:
                    result.append(paragraphs.paragraph(richText: content, indent: min(depth, Paragraph.maxIndent), list: list, report: &report))
                case .image, .table, .embeddedFile:
                    report.approximated("cellContentDropped")
                default:
                    report.skipped(content.jcid)
                }
            }
            for child in graph.children(of: element, PID.elementChildren, report: &report) {
                if child.jcid == .outlineElement { walk(child, depth: depth + 1) } else { report.skipped(child.jcid) }
            }
        }
        for element in graph.children(of: cell, PID.elementChildren, report: &report) {
            if element.jcid == .outlineElement { walk(element, depth: 0) } else { report.skipped(element.jcid) }
        }
        return result
    }

    private func mapAttachment(_ node: OneObject, x: Double, y: Double) -> PageObject? {
        report.noteIgnoredProperties(of: node, consumed: PID.consumedByAttachment)
        guard let container = graph.children(of: node, PID.embeddedFileContainer, report: &report).first,
              let file = assets(container) else {
            report.approximated("attachmentDataMissing")
            return nil
        }
        let name = sink.add(object: container.id, data: file.data, ext: file.ext)
        let display = node.properties.string(PID.embeddedFileName).flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment"
        report.imported("attachment")
        return .attachment(AttachmentObject(id: UUID(), frame: Frame(x: x, y: y, width: Self.attachmentSize.width,
                                                                      height: Self.attachmentSize.height),
                                            asset: name, displayName: display))
    }
}
