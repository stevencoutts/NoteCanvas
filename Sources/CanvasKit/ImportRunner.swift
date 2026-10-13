import AppKit
import OneImport
import OneStore
import PageModel
import Store

final class ImportCancelFlag {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// TextKit measurement belongs on the main thread; the importer calls this from its background queue.
struct MainThreadMeasurer: TextMeasuring {
    let inner: TextMeasuring
    func height(of paragraphs: [Paragraph], width: Double) -> Double { onMain { inner.height(of: paragraphs, width: width) } }
    func textHeight(of paragraphs: [Paragraph], width: Double) -> Double { onMain { inner.textHeight(of: paragraphs, width: width) } }
    private func onMain<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }
}

struct ImportOutcome {
    var package: NotebookPackage?
    var section: Section?
    var result: ImportResult?
    var cancelled = false
    var error: Error?
}

enum ImportRunner {
    /// Reads, maps and stores `url` into a copy of `package` on a background queue, then calls `completion` on the main
    /// queue. The notebook gains a section only when everything succeeded: failure or cancellation leaves the manifest
    /// untouched (already-written asset files may remain unused). The source file is only ever read.
    static func run(file url: URL, into package: NotebookPackage, cancel: ImportCancelFlag,
                    completion: @escaping (ImportOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = ImportOutcome()
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let file = try OneFile(data: data)
                let importer = OneImporter(measurer: MainThreadMeasurer(inner: TextKitMeasurer()))
                let result = importer.importSection(from: file, name: url.deletingPathExtension().lastPathComponent,
                                                    isCancelled: { cancel.isCancelled })
                outcome.result = result
                if cancel.isCancelled || result.report.cancelled {
                    outcome.cancelled = true
                } else {
                    var pkg = package
                    for asset in result.assets {
                        if cancel.isCancelled { outcome.cancelled = true; break }
                        try pkg.writeAsset(name: asset.name, data: asset.data)
                    }
                    if !outcome.cancelled {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let report = try encoder.encode(result.report)
                        let section = try pkg.addSection(name: result.sectionName, pages: result.pages, report: report)
                        outcome.package = pkg
                        outcome.section = section
                    }
                }
            } catch {
                outcome.error = error
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
