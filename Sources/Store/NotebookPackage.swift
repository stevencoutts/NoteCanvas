import Foundation
import PageModel

/// A notebook on disk: `notebook.json` plus `pages/<uuid>.json`.
public struct NotebookPackage {
    public let url: URL
    public private(set) var notebook: Notebook

    private var manifestURL: URL { url.appendingPathComponent("notebook.json") }

    private var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    private var importsURL: URL { url.appendingPathComponent("imports", isDirectory: true) }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
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
    public mutating func addPage(title: String, section: Int = 0, inFolder folder: UUID? = nil) throws -> Page {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        let page = Page(id: UUID(), title: title, objects: [])
        try write(page)
        var updated = notebook
        updated.sections[section].addPage(PageRef(id: page.id, title: title), inFolder: folder)
        try commitManifest(updated)
        return page
    }

    public func loadPage(_ id: UUID) throws -> Page {
        guard let data = try? Data(contentsOf: pageURL(id)) else { throw StoreError.missingPage(id) }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw StoreError.corruptPage(id) }
        return page
    }

    public mutating func savePage(_ page: Page) throws {
        guard let s = notebook.sections.firstIndex(where: { $0.pages.contains { $0.id == page.id } }) else {
            throw StoreError.missingPage(page.id)
        }
        try write(page)
        let listed = notebook.sections[s].pages.first { $0.id == page.id }?.title
        if listed != page.title {
            var updated = notebook
            updated.sections[s].setTitle(page.title, for: page.id)
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
        for s in updated.sections.indices { updated.sections[s].removePage(id) }
        try commitManifest(updated)
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: pageURL(id), resultingItemURL: &trashed)) != nil else { return nil }
        return trashed as URL?
    }

    /// Stores `data` under a fresh `assets/<uuid>.<ext>` name and returns that name.
    public func addAsset(data: Data, ext: String) throws -> String {
        let name = AssetName.make(ext: ext)
        try writeAsset(name: name, data: data)
        return name
    }

    /// Stores `data` as `assets/<name>` (atomic). `name` must be a plain file name.
    public func writeAsset(name: String, data: Data) throws {
        guard Self.isPlainFileName(name) else { throw StoreError.invalidAssetName }
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try data.write(to: assetsURL.appendingPathComponent(name), options: .atomic)
    }

    /// The asset's data, or nil when the name is not a plain file name or the file is missing.
    public func loadAsset(_ name: String) -> Data? {
        guard Self.isPlainFileName(name) else { return nil }
        return try? Data(contentsOf: assetsURL.appendingPathComponent(name))
    }

    /// Adds a section holding `pages`. Assets must already be stored. Order: page files, then the optional
    /// report, then the manifest entry last, so a failure leaves at most orphan files, never a dangling section.
    public mutating func addSection(name: String, pages: [Page], report: Data? = nil) throws -> Section {
        let section = Section(id: UUID(), name: name, pages: pages.map { PageRef(id: $0.id, title: $0.title) })
        for page in pages { try write(page) }
        if let report {
            try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)
            try report.write(to: importsURL.appendingPathComponent("\(section.id.uuidString).json"), options: .atomic)
        }
        var updated = notebook
        updated.sections.append(section)
        try commitManifest(updated)
        return section
    }

    /// Adds an empty section at the end. Nothing but the manifest changes.
    public mutating func addEmptySection(name: String) throws -> Section {
        try addSection(name: name, pages: [])
    }

    /// Renames the section with this id. An unknown id changes nothing.
    public mutating func renameSection(_ id: UUID, to name: String) throws {
        var updated = notebook
        guard let index = updated.sections.firstIndex(where: { $0.id == id }) else { return }
        updated.sections[index].name = name
        try commitManifest(updated)
    }

    /// Removes the section and moves its page files to the Trash, manifest first so nothing dangles.
    /// The last remaining section is never removed. Returns false when nothing was removed.
    @discardableResult
    public mutating func deleteSection(_ id: UUID) throws -> Bool {
        guard notebook.sections.count > 1, let index = notebook.sections.firstIndex(where: { $0.id == id }) else { return false }
        let doomed = notebook.sections[index].pages.map(\.id)
        var updated = notebook
        updated.sections.remove(at: index)
        try commitManifest(updated)
        for pageID in doomed { _ = try? FileManager.default.trashItem(at: pageURL(pageID), resultingItemURL: nil) }
        return true
    }

    public mutating func addFolder(named name: String, section: Int, inFolder parent: UUID?) throws -> UUID {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        let id = updated.sections[section].addFolder(named: name, inFolder: parent)
        try commitManifest(updated)
        return id
    }

    public mutating func renameFolder(_ id: UUID, section: Int, to name: String) throws {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        guard updated.sections[section].renameFolder(id, to: name) else { return }
        try commitManifest(updated)
    }

    /// Writes the folder colour into notebook.json immediately. Nil clears it.
    public mutating func setFolderColor(_ id: UUID, section: Int, to colorHex: String?) throws {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        guard updated.sections[section].setFolderColor(id, to: colorHex) else { return }
        try commitManifest(updated)
    }

    /// Writes the page colour into notebook.json immediately. Nil clears it. The page file is not rewritten.
    public mutating func setPageColor(_ id: UUID, section: Int, to colorHex: String?) throws {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        guard updated.sections[section].setPageColor(id, to: colorHex) else { return }
        try commitManifest(updated)
    }

    /// The folder goes away; pages and folders that were inside it stay.
    public mutating func dissolveFolder(_ id: UUID, section: Int) throws {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        guard updated.sections[section].dissolveFolder(id) else { return }
        try commitManifest(updated)
    }

    public mutating func moveItem(_ id: UUID, section: Int, into parent: UUID?, at index: Int) throws -> Bool {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        var updated = notebook
        guard updated.sections[section].move(id: id, into: parent, at: index) else { return false }
        try commitManifest(updated)
        return true
    }
}
