import AppKit
import OneImport
import OneStore
import PageModel
import Store

public struct BackupImportProgress {
    public var done: Int
    public var total: Int
    public var notebook: String
    public var section: String
}

public struct ImportedNotebook {
    public var name: String
    public var url: URL
    public var sections: Int
    public var pages: Int
}

public struct BackupImportOutcome {
    public var notebooks: [ImportedNotebook] = []
    /// "Notebook / Section" of every file that could not be read.
    public var failed: [String] = []
    public var pagesImported = 0
    public var pagesTotal = 0
    public var pagesFailed = 0
    public var cancelled = false
    /// An error that stopped the whole run, such as a destination that cannot be written to.
    public var error: Error?
    public init() {}
}

public enum BackupImportRunner {
    /// Imports the scanned sections into one new notebook per OneNote notebook, inside `destination`. A section that
    /// cannot be read is counted and skipped. Cancelling keeps the notebooks made so far. A notebook that ends up with no
    /// sections is moved to the Trash again. The backup files are only ever read. `progress` and `completion` run on the
    /// main queue.
    public static func run(_ scan: BackupScan, into destination: URL, cancel: ImportCancelFlag,
                           progress: @escaping (BackupImportProgress) -> Void,
                           completion: @escaping (BackupImportOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = BackupImportOutcome()
            let total = scan.sectionCount
            var done = 0
            let importer = OneImporter(measurer: MainThreadMeasurer(inner: TextKitMeasurer()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            for notebook in scan.notebooks {
                if cancel.isCancelled { outcome.cancelled = true; break }
                var pkg: NotebookPackage
                do {
                    pkg = try NotebookPackage.create(at: uniqueURL(for: notebook.name, in: destination), name: notebook.name)
                } catch {
                    outcome.error = error
                    break
                }
                let placeholder = pkg.notebook.sections.first?.id
                var made = ImportedNotebook(name: notebook.name, url: pkg.url, sections: 0, pages: 0)

                for source in notebook.sections {
                    if cancel.isCancelled { outcome.cancelled = true; break }
                    let step = BackupImportProgress(done: done, total: total, notebook: notebook.name, section: source.displayName)
                    DispatchQueue.main.async { progress(step) }
                    do {
                        let data = try Data(contentsOf: source.url, options: .mappedIfSafe)
                        let file = try OneFile(data: data)
                        let result = importer.importSection(from: file, name: source.displayName,
                                                            isCancelled: { cancel.isCancelled })
                        if cancel.isCancelled || result.report.cancelled { outcome.cancelled = true; break }
                        for asset in result.assets { try pkg.writeAsset(name: asset.name, data: asset.data) }
                        let report = try encoder.encode(result.report)
                        _ = try pkg.addSection(name: result.sectionName, pages: result.pages, report: report)
                        made.sections += 1
                        made.pages += result.report.pagesImported
                        outcome.pagesImported += result.report.pagesImported
                        outcome.pagesTotal += result.report.pagesTotal
                        outcome.pagesFailed += result.report.pagesFailed
                    } catch {
                        outcome.failed.append("\(notebook.name) / \(source.displayName)")
                    }
                    done += 1
                }

                if made.sections > 0 {
                    // The new notebook starts with an empty "Section 1". Drop it now that real sections exist.
                    if let placeholder { _ = try? pkg.deleteSection(placeholder) }
                    outcome.notebooks.append(made)
                } else {
                    // Nothing was readable: take back the scaffold this run created so no empty notebook is left behind.
                    _ = try? FileManager.default.trashItem(at: pkg.url, resultingItemURL: nil)
                }
                if outcome.cancelled { break }
            }
            let finished = outcome
            DispatchQueue.main.async { completion(finished) }
        }
    }

    /// "<destination>/<name>.notebook", with " 2", " 3"... added when that name is taken.
    static func uniqueURL(for name: String, in destination: URL) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Notebook" : cleaned
        var candidate = destination.appendingPathComponent("\(base).notebook", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(base) \(n).notebook", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
