import Foundation
import OneStore
import PageModel

public struct ImportedAsset {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public struct ImportResult {
    public var sectionName: String
    public var pages: [Page]
    public var assets: [ImportedAsset]
    public var report: ImportReport
}

public struct OneImporter {
    public let measurer: TextMeasuring
    public init(measurer: TextMeasuring) { self.measurer = measurer }

    /// Maps every page of `source` into one section's worth of pages. A page that cannot be resolved is counted and
    /// skipped. `isCancelled` is asked before each page; when it says yes the result is partial and flagged.
    public func importSection(from source: OneSource, name: String, isCancelled: () -> Bool = { false }) -> ImportResult {
        var report = ImportReport()
        report.warnings = Array(source.warnings.prefix(20))
        let sink = AssetSink()

        // Pick, per object space, the newest revision whose default root is a PageManifest (a page) or a Section.
        struct PageSpace { let id: ExtendedGUID; let revision: Revision; let objects: [ExtendedGUID: OneObject] }
        var pageSpaces: [PageSpace] = []
        var section: (revision: Revision, objects: [ExtendedGUID: OneObject])?
        for space in source.objectSpaces {
            var newestPage: Revision?
            var newestSection: Revision?
            for rev in space.revisions {
                let kind = space.rootObject(of: rev)?.jcid
                if kind == .pageManifest { newestPage = rev } else if kind == .section { newestSection = rev }
            }
            if let rev = newestPage { pageSpaces.append(PageSpace(id: space.id, revision: rev, objects: space.objects(at: rev))) }
            if let rev = newestSection { section = (rev, space.objects(at: rev)) }
        }

        // Display order comes from the section's page series.
        var order: [ExtendedGUID] = []
        if let section, let rootID = section.revision.roots[1], let root = section.objects[rootID] {
            var scratch = ImportReport()
            let graph = ObjectGraph(objects: section.objects)
            for series in graph.children(of: root, PID.elementChildren, report: &scratch) where series.jcid == .pageSeries {
                order += series.properties.objectSpaceIDs(PID.childGraphSpaces)
            }
        }
        var rank: [ExtendedGUID: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        let ordered = pageSpaces.enumerated().sorted { l, r in
            let lr = rank[l.element.id] ?? Int.max, rr = rank[r.element.id] ?? Int.max
            return lr != rr ? lr < rr : l.offset < r.offset
        }.map(\.element)
        let unranked = pageSpaces.filter { rank[$0.id] == nil }.count
        if unranked > 0 && (pageSpaces.count > 1 || !order.isEmpty) { report.approximated("pageOrderUnknown", unranked) }

        var pages: [Page] = []
        for entry in ordered {
            if isCancelled() { report.cancelled = true; break }
            report.pagesTotal += 1
            let graph = ObjectGraph(objects: entry.objects)
            var scratch = ImportReport()
            guard let manifestID = entry.revision.roots[1], let manifest = entry.objects[manifestID],
                  let pageObject = graph.children(of: manifest, PID.contentChildren, report: &scratch).first(where: { $0.jcid == .page }) else {
                report.pagesFailed += 1
                continue
            }
            let mapper = PageMapper(graph: graph, measurer: measurer, assets: { source.fileData(for: $0) }, sink: sink)
            pages.append(mapper.mapPage(pageObject))
            report.merge(mapper.report)
            report.pagesImported += 1
            if (pageObject.properties.u32(PID.pageLevel) ?? 0) > 0 { report.approximated("subpageLevelIgnored") }
        }
        return ImportResult(sectionName: name, pages: pages, assets: sink.items, report: report)
    }
}
