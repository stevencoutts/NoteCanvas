import Foundation
import PageModel

/// A notebook on disk: `notebook.json` plus `pages/<uuid>.json`.
public struct NotebookPackage {
    public let url: URL
    public private(set) var notebook: Notebook

    private var manifestURL: URL { url.appendingPathComponent("notebook.json") }
    private func pageURL(_ id: UUID) -> URL {
        url.appendingPathComponent("pages", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(value)
    }

    public static func create(at url: URL, name: String) throws -> NotebookPackage {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw StoreError.alreadyExists }
        try fm.createDirectory(at: url.appendingPathComponent("pages", isDirectory: true),
                               withIntermediateDirectories: true)
        let pkg = NotebookPackage(url: url, notebook: Notebook(name: name))
        try pkg.writeManifest()
        return pkg
    }

    public static func open(at url: URL) throws -> NotebookPackage {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("notebook.json")) else {
            throw StoreError.notAPackage
        }
        // Read the version alone first so a newer format reports unsupportedVersion, not corrupt.
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw StoreError.corruptManifest
        }
        guard probe.version == Notebook.currentVersion else { throw StoreError.unsupportedVersion(probe.version) }
        guard let notebook = try? JSONDecoder().decode(Notebook.self, from: data) else {
            throw StoreError.corruptManifest
        }
        return NotebookPackage(url: url, notebook: notebook)
    }

    private func writeManifest() throws {
        try Self.encode(notebook).write(to: manifestURL, options: .atomic)
    }

    /// Writes `updated` as the manifest and only then adopts it, so a failed write leaves memory matching disk.
    private mutating func commitManifest(_ updated: Notebook) throws {
        try Self.encode(updated).write(to: manifestURL, options: .atomic)
        notebook = updated
    }

    private func write(_ page: Page) throws {
        try Self.encode(page).write(to: pageURL(page.id), options: .atomic)
    }

    /// Page file is written before the manifest references it, so the manifest never points at nothing.
    public mutating func addPage(title: String, section: Int = 0) throws -> Page {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        let page = Page(id: UUID(), title: title, objects: [])
        try write(page)
        var updated = notebook
        updated.sections[section].pages.append(PageRef(id: page.id, title: title))
        try commitManifest(updated)
        return page
    }

    public func loadPage(_ id: UUID) throws -> Page {
        guard let data = try? Data(contentsOf: pageURL(id)) else { throw StoreError.missingPage(id) }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw StoreError.corruptPage(id) }
        return page
    }

    public mutating func savePage(_ page: Page) throws {
        guard let s = notebook.sections.firstIndex(where: { $0.pages.contains { $0.id == page.id } }),
              let p = notebook.sections[s].pages.firstIndex(where: { $0.id == page.id }) else {
            throw StoreError.missingPage(page.id)
        }
        try write(page)
        if notebook.sections[s].pages[p].title != page.title {
            var updated = notebook
            updated.sections[s].pages[p].title = page.title
            try commitManifest(updated)
        }
    }

    /// Manifest first, then the file: a crash in between leaves an orphan file, never a dangling reference.
    /// The file goes to the Trash so a mistaken delete can be recovered; if trashing fails the file is left
    /// in place as an orphan (the manifest no longer lists it, so this is not an error).
    /// Returns where the file went in the Trash, or nil if it was left in place.
    @discardableResult
    public mutating func deletePage(id: UUID) throws -> URL? {
        var updated = notebook
        for s in updated.sections.indices { updated.sections[s].pages.removeAll { $0.id == id } }
        try commitManifest(updated)
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: pageURL(id), resultingItemURL: &trashed)) != nil else { return nil }
        return trashed as URL?
    }
}
