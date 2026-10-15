import CryptoKit
import Foundation
import PageModel

/// What an encrypted notebook needs to read and write its files.
public struct NotebookCipher {
    public let notebookID: UUID
    public let key: SymmetricKey
    public init(notebookID: UUID, key: SymmetricKey) { self.notebookID = notebookID; self.key = key }
}

/// A notebook on disk: `notebook.json` plus `pages/<uuid>.json`.
public struct NotebookPackage {
    public let url: URL
    public private(set) var notebook: Notebook
    /// Nil for an unencrypted notebook. See docs/encryption-spec.md.
    public private(set) var cipher: NotebookCipher? = nil

    public var isEncrypted: Bool { cipher != nil }

    private var manifestURL: URL { url.appendingPathComponent(cipher == nil ? "notebook.json" : "notebook.nce") }
    private var keysURL: URL { url.appendingPathComponent("keys.json") }

    private var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    private var importsURL: URL { url.appendingPathComponent("imports", isDirectory: true) }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    private func pageURL(_ id: UUID) -> URL {
        let pages = url.appendingPathComponent("pages", isDirectory: true)
        if cipher != nil { return pages.appendingPathComponent("\(id.uuidString.lowercased()).nce") }
        return pages.appendingPathComponent("\(id.uuidString).json")
    }

    private static func pageLogicalPath(_ id: UUID) -> String { "pages/\(id.uuidString.lowercased()).json" }

    /// Encrypted assets drop their extension from the stored name so a provider cannot tell the file type.
    private func assetURL(_ name: String) -> URL {
        guard cipher != nil else { return assetsURL.appendingPathComponent(name) }
        let stem = (name as NSString).deletingPathExtension
        return assetsURL.appendingPathComponent("\(stem).nce")
    }

    /// Writes `plain` to `target`, encrypted when the notebook is. Atomic either way.
    private func writeObject(_ plain: Data, kind: NotebookCrypto.Kind, logicalPath: String, to target: URL) throws {
        guard let cipher else { try plain.write(to: target, options: .atomic); return }
        let sealed = try NotebookCrypto.seal(plain, kind: kind, logicalPath: logicalPath,
                                             notebookID: cipher.notebookID, notebookKey: cipher.key)
        try sealed.write(to: target, options: .atomic)
    }

    /// Nil when the file is missing, or when it is encrypted and does not authenticate.
    private func readObject(kind: NotebookCrypto.Kind, logicalPath: String, from source: URL) -> Data? {
        guard let raw = try? Data(contentsOf: source) else { return nil }
        guard let cipher else { return raw }
        return try? NotebookCrypto.open(raw, kind: kind, logicalPath: logicalPath,
                                        notebookID: cipher.notebookID, notebookKey: cipher.key)
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

    /// True when the folder holds an encrypted notebook (it has a `keys.json`).
    public static func isEncrypted(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("keys.json").path)
    }

    /// The cleartext key slots of an encrypted notebook.
    public static func keysFile(at url: URL) throws -> KeysFile {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("keys.json")) else { throw StoreError.notAPackage }
        return try KeysFile.decode(data)
    }

    /// Opens an encrypted notebook with its unwrapped notebook key.
    public static func open(at url: URL, notebookKey: SymmetricKey) throws -> NotebookPackage {
        let keys = try keysFile(at: url)
        guard let id = keys.notebookUUID else { throw StoreError.corruptManifest }
        guard let raw = try? Data(contentsOf: url.appendingPathComponent("notebook.nce")) else { throw StoreError.notAPackage }
        guard let data = try? NotebookCrypto.open(raw, kind: .manifest, logicalPath: "notebook.json",
                                                  notebookID: id, notebookKey: notebookKey) else { throw StoreError.wrongKey }
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { throw StoreError.corruptManifest }
        guard probe.version == Notebook.currentVersion else { throw StoreError.unsupportedVersion(probe.version) }
        guard let notebook = try? JSONDecoder().decode(Notebook.self, from: data) else { throw StoreError.corruptManifest }
        return NotebookPackage(url: url, notebook: notebook, cipher: NotebookCipher(notebookID: id, key: notebookKey))
    }

    /// Opens an unencrypted notebook. An encrypted one throws `StoreError.encrypted`: unlock it and use `open(at:notebookKey:)`.
    public static func open(at url: URL) throws -> NotebookPackage {
        if isEncrypted(at: url) { throw StoreError.encrypted }
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
        try writeObject(try Self.encode(notebook), kind: .manifest, logicalPath: "notebook.json", to: manifestURL)
    }

    /// Writes `updated` as the manifest and only then adopts it, so a failed write leaves memory matching disk.
    /// An encrypted notebook also counts the write in `revision`.
    private mutating func commitManifest(_ updated: Notebook) throws {
        var next = updated
        if cipher != nil { next.revision = notebook.revision + 1 }
        try writeObject(try Self.encode(next), kind: .manifest, logicalPath: "notebook.json", to: manifestURL)
        notebook = next
    }

    private func write(_ page: Page) throws {
        try writeObject(try Self.encode(page), kind: .page, logicalPath: Self.pageLogicalPath(page.id), to: pageURL(page.id))
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
        guard FileManager.default.fileExists(atPath: pageURL(id).path) else { throw StoreError.missingPage(id) }
        guard let data = readObject(kind: .page, logicalPath: Self.pageLogicalPath(id), from: pageURL(id)),
              let page = try? JSONDecoder().decode(Page.self, from: data) else { throw StoreError.corruptPage(id) }
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
        try writeObject(data, kind: .asset, logicalPath: "assets/\(name)", to: assetURL(name))
    }

    /// The asset's data, or nil when the name is not a plain file name or the file is missing.
    public func loadAsset(_ name: String) -> Data? {
        guard Self.isPlainFileName(name) else { return nil }
        return readObject(kind: .asset, logicalPath: "assets/\(name)", from: assetURL(name))
    }

    /// Adds a section holding `pages`. Assets must already be stored. Order: page files, then the optional
    /// report, then the manifest entry last, so a failure leaves at most orphan files, never a dangling section.
    public mutating func addSection(name: String, pages: [Page], report: Data? = nil) throws -> Section {
        let section = Section(id: UUID(), name: name, pages: pages.map { PageRef(id: $0.id, title: $0.title) })
        for page in pages { try write(page) }
        // An encrypted notebook keeps no import report: version 1 of the format has no object kind for it.
        if let report, cipher == nil {
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

    // MARK: encryption

    /// Makes a new encrypted notebook. Returns it and the recovery key, which is shown to the user once.
    public static func createEncrypted(at url: URL, name: String, passphrase: String,
                                       iterations: Int = NotebookCrypto.defaultIterations) throws -> (package: NotebookPackage, recoveryKey: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw StoreError.alreadyExists }
        let keys = try NotebookCrypto.createKeys(passphrase: passphrase, iterations: iterations)
        guard let id = keys.keysFile.notebookUUID else { throw StoreError.corruptManifest }
        try fm.createDirectory(at: url.appendingPathComponent("pages", isDirectory: true), withIntermediateDirectories: true)
        let pkg = NotebookPackage(url: url, notebook: Notebook(name: name),
                                  cipher: NotebookCipher(notebookID: id, key: keys.notebookKey))
        try pkg.writeManifest()
        try keys.keysFile.encoded().write(to: pkg.keysURL, options: .atomic)    // last: the notebook only counts as encrypted once this exists
        return (pkg, keys.recoveryKey)
    }

    /// Encrypts an unencrypted notebook in place and returns the recovery key. Order: every encrypted file, the manifest,
    /// then `keys.json` last, then a read-back of everything. If the read-back differs, `keys.json` is removed and the
    /// notebook stays as it was. The unencrypted files are left alone: see `plaintextLeftovers()`.
    public mutating func encrypt(passphrase: String, iterations: Int = NotebookCrypto.defaultIterations) throws -> String {
        guard cipher == nil else { throw StoreError.alreadyEncrypted }
        let keys = try NotebookCrypto.createKeys(passphrase: passphrase, iterations: iterations)
        guard let id = keys.keysFile.notebookUUID else { throw StoreError.corruptManifest }
        var target = self
        target.cipher = NotebookCipher(notebookID: id, key: keys.notebookKey)
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("pages", isDirectory: true), withIntermediateDirectories: true)

        var pageIDs: [UUID] = []
        for section in notebook.sections {
            for ref in section.pages {
                try target.write(try loadPage(ref.id))
                pageIDs.append(ref.id)
            }
        }
        var assetNames: [String] = []
        if let names = try? fm.contentsOfDirectory(atPath: assetsURL.path) {
            for name in names where !name.hasPrefix(".") && !name.hasSuffix(".nce") {
                guard let data = loadAsset(name) else { continue }
                try target.writeAsset(name: name, data: data)
                assetNames.append(name)
            }
        }
        try target.commitManifest(notebook)
        try keys.keysFile.encoded().write(to: target.keysURL, options: .atomic)

        do {
            let reread = try NotebookPackage.open(at: url, notebookKey: keys.notebookKey)
            guard reread.notebook == target.notebook else { throw StoreError.verifyFailed }
            for id in pageIDs {
                let copy = try reread.loadPage(id)
                let original = try loadPage(id)
                guard copy == original else { throw StoreError.verifyFailed }
            }
            for name in assetNames { guard reread.loadAsset(name) == loadAsset(name) else { throw StoreError.verifyFailed } }
        } catch {
            try? fm.removeItem(at: target.keysURL)
            throw error
        }
        self = target
        return keys.recoveryKey
    }

    /// The unencrypted copies still on disk in an encrypted notebook: the old manifest, pages, assets and import reports.
    public func plaintextLeftovers() -> [URL] {
        guard cipher != nil else { return [] }
        let fm = FileManager.default
        var found: [URL] = []
        let manifest = url.appendingPathComponent("notebook.json")
        if fm.fileExists(atPath: manifest.path) { found.append(manifest) }
        let pagesDir = url.appendingPathComponent("pages", isDirectory: true)
        for file in (try? fm.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            found.append(file)
        }
        for file in (try? fm.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension != "nce" && !file.lastPathComponent.hasPrefix(".") {
            found.append(file)
        }
        if fm.fileExists(atPath: importsURL.path) { found.append(importsURL) }
        return found
    }

    /// Moves the unencrypted copies to the Trash. Returns how many items moved. Never touches `.nce` files or `keys.json`.
    @discardableResult
    public func trashPlaintextLeftovers() throws -> Int {
        let leftovers = plaintextLeftovers()
        for item in leftovers { try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
        return leftovers.count
    }

    /// Replaces the passphrase. Nothing else in the notebook is rewritten.
    public func changePassphrase(to passphrase: String, iterations: Int = NotebookCrypto.defaultIterations) throws {
        guard let cipher else { throw StoreError.notAPackage }
        let updated = try NotebookCrypto.changePassphrase(try Self.keysFile(at: url), notebookKey: cipher.key,
                                                          newPassphrase: passphrase, iterations: iterations)
        try updated.encoded().write(to: keysURL, options: .atomic)
    }
}
