import CryptoKit
import Foundation
import PageModel

/// What an encrypted notebook needs to read and write its files.
public struct NotebookCipher {
    public let notebookID: UUID
    public let key: SymmetricKey
    public init(notebookID: UUID, key: SymmetricKey) { self.notebookID = notebookID; self.key = key }
}

/// Where an object's key comes from: the Notebook Key, or the Section Key of a locked section.
enum ObjectScope {
    case notebook
    case section(id: UUID, key: SymmetricKey)
}

/// What the package remembers about a locked section. `key` is nil while the section is locked.
struct SectionLockState {
    var label: String
    var key: SymmetricKey?
    var revision: Int
}

/// A notebook on disk: `notebook.json` plus `pages/<uuid>.json`.
public struct NotebookPackage {
    public private(set) var url: URL
    public private(set) var notebook: Notebook
    /// Nil for an unencrypted notebook. See docs/encryption-spec.md.
    public private(set) var cipher: NotebookCipher? = nil
    /// Locked sections by id. Empty unless the notebook is encrypted and has locked sections.
    var locks: [UUID: SectionLockState] = [:]
    /// Sections whose locking was interrupted: their keys file exists but the manifest does not mark them locked.
    public private(set) var interruptedLocks: [UUID] = []

    public var isEncrypted: Bool { cipher != nil }

    /// Points the package at the folder it was moved to. The caller has already checked that the folder is this notebook.
    public mutating func relocate(to newURL: URL) { url = newURL }

    private var manifestURL: URL { url.appendingPathComponent(cipher == nil ? "notebook.json" : "notebook.nce") }
    private var keysURL: URL { url.appendingPathComponent("keys.json") }

    private var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    private var sectionsURL: URL { url.appendingPathComponent("sections", isDirectory: true) }
    private func sectionKeysURL(_ id: UUID) -> URL { sectionsURL.appendingPathComponent("\(id.uuidString.lowercased()).keys.json") }
    private func sectionManifestURL(_ id: UUID) -> URL { sectionsURL.appendingPathComponent("\(id.uuidString.lowercased()).nce") }
    private static func sectionLogicalPath(_ id: UUID) -> String { "sections/\(id.uuidString.lowercased()).json" }
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
    private func writeObject(_ plain: Data, kind: NotebookCrypto.Kind, logicalPath: String, to target: URL,
                             scope: ObjectScope = .notebook) throws {
        guard let cipher else { try plain.write(to: target, options: .atomic); return }
        let sealed: Data
        switch scope {
        case .notebook:
            sealed = try NotebookCrypto.seal(plain, kind: kind, logicalPath: logicalPath,
                                             notebookID: cipher.notebookID, notebookKey: cipher.key)
        case .section(let sectionID, let sectionKey):
            sealed = try SectionCrypto.seal(plain, kind: kind == .asset ? .asset : .page, logicalPath: logicalPath,
                                            notebookID: cipher.notebookID, sectionID: sectionID, sectionKey: sectionKey)
        }
        try sealed.write(to: target, options: .atomic)
    }

    /// Nil when the file is missing, or when it is encrypted and does not authenticate.
    private func readObject(kind: NotebookCrypto.Kind, logicalPath: String, from source: URL,
                            scope: ObjectScope = .notebook) -> Data? {
        guard let raw = try? Data(contentsOf: source) else { return nil }
        guard let cipher else { return raw }
        switch scope {
        case .notebook:
            return try? NotebookCrypto.open(raw, kind: kind, logicalPath: logicalPath,
                                            notebookID: cipher.notebookID, notebookKey: cipher.key)
        case .section(let sectionID, let sectionKey):
            return try? SectionCrypto.open(raw, kind: kind == .asset ? .asset : .page, logicalPath: logicalPath,
                                           notebookID: cipher.notebookID, sectionID: sectionID, sectionKey: sectionKey)
        }
    }

    // MARK: key scopes

    private func scope(ofSectionID id: UUID?) throws -> ObjectScope {
        guard let id, let state = locks[id] else { return .notebook }
        guard let key = state.key else { throw StoreError.sectionLocked(id) }
        return .section(id: id, key: key)
    }

    private func scope(ofSection index: Int) throws -> ObjectScope { try scope(ofSectionID: notebook.sections[index].id) }

    private func sectionID(ofPage pageID: UUID) -> UUID? {
        notebook.sections.first { $0.pages.contains { $0.id == pageID } }?.id
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
        var opened = NotebookPackage(url: url, notebook: notebook, cipher: NotebookCipher(notebookID: id, key: notebookKey))
        for section in notebook.sections {
            if section.locked {
                opened.locks[section.id] = SectionLockState(label: section.name, key: nil, revision: 0)
            } else if FileManager.default.fileExists(atPath: opened.sectionKeysURL(section.id).path) {
                opened.interruptedLocks.append(section.id)
            }
        }
        return opened
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
        var nextLocks = locks
        // An open locked section keeps its real content in its own manifest, so a change to it goes there first.
        for (id, state) in locks {
            guard let key = state.key, let new = updated.sections.first(where: { $0.id == id }),
                  new != notebook.sections.first(where: { $0.id == id }) else { continue }
            let revision = state.revision + 1
            try writeSectionManifest(new, revision: revision, key: key)
            nextLocks[id]?.revision = revision
        }
        // The notebook manifest only sees stand-ins for locked sections, so it is left alone when only they changed.
        let changed = diskView(updated, locks: nextLocks) != diskView(notebook, locks: locks)
        var next = updated
        if cipher != nil, changed || locks.isEmpty { next.revision = notebook.revision + 1 }
        if changed || locks.isEmpty {
            try writeObject(try Self.encode(diskView(next, locks: nextLocks)), kind: .manifest,
                            logicalPath: "notebook.json", to: manifestURL)
        }
        notebook = next
        locks = nextLocks
    }

    /// The notebook as `notebook.json` holds it: locked sections appear only as stand-ins carrying their label.
    private func diskView(_ source: Notebook, locks: [UUID: SectionLockState]) -> Notebook {
        var view = source
        view.sections = source.sections.map { section in
            guard let state = locks[section.id] else { return section }
            return Section.placeholder(id: section.id, label: state.label)
        }
        return view
    }

    private static func encodeSectionManifest(_ section: Section, revision: Int) throws -> Data {
        let plain = try encode(section)
        guard revision != 0, var object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return plain }
        object["revision"] = revision
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func writeSectionManifest(_ section: Section, revision: Int, key: SymmetricKey) throws {
        guard let cipher else { throw StoreError.notEncrypted }
        try FileManager.default.createDirectory(at: sectionsURL, withIntermediateDirectories: true)
        var real = section
        real.locked = false
        let sealed = try SectionCrypto.seal(try Self.encodeSectionManifest(real, revision: revision), kind: .section,
                                            logicalPath: Self.sectionLogicalPath(section.id),
                                            notebookID: cipher.notebookID, sectionID: section.id, sectionKey: key)
        try sealed.write(to: sectionManifestURL(section.id), options: .atomic)
    }

    private func readSectionManifest(_ id: UUID, key: SymmetricKey) -> (section: Section, revision: Int)? {
        guard let cipher, let raw = try? Data(contentsOf: sectionManifestURL(id)),
              let data = try? SectionCrypto.open(raw, kind: .section, logicalPath: Self.sectionLogicalPath(id),
                                                 notebookID: cipher.notebookID, sectionID: id, sectionKey: key),
              let section = try? JSONDecoder().decode(Section.self, from: data), section.id == id else { return nil }
        struct RevisionProbe: Decodable { var revision: Int? }
        let revision = (try? JSONDecoder().decode(RevisionProbe.self, from: data))?.revision ?? 0
        return (section, revision)
    }

    private func write(_ page: Page, scope: ObjectScope = .notebook) throws {
        try writeObject(try Self.encode(page), kind: .page, logicalPath: Self.pageLogicalPath(page.id), to: pageURL(page.id), scope: scope)
    }

    /// Page file is written before the manifest references it, so the manifest never points at nothing.
    public mutating func addPage(title: String, section: Int = 0, inFolder folder: UUID? = nil) throws -> Page {
        guard notebook.sections.indices.contains(section) else { throw StoreError.noSuchSection }
        let page = Page(id: UUID(), title: title, objects: [])
        try write(page, scope: try scope(ofSection: section))
        var updated = notebook
        updated.sections[section].addPage(PageRef(id: page.id, title: title), inFolder: folder)
        try commitManifest(updated)
        return page
    }

    public func loadPage(_ id: UUID) throws -> Page {
        guard FileManager.default.fileExists(atPath: pageURL(id).path) else { throw StoreError.missingPage(id) }
        let objectScope = try scope(ofSectionID: sectionID(ofPage: id))
        guard let data = readObject(kind: .page, logicalPath: Self.pageLogicalPath(id), from: pageURL(id), scope: objectScope),
              let page = try? JSONDecoder().decode(Page.self, from: data) else {
            // A page under a Section Key in a section the manifest does not mark locked: locking was interrupted.
            if case .notebook = objectScope, let owner = sectionID(ofPage: id),
               let raw = try? Data(contentsOf: pageURL(id)), SectionCrypto.isSectionObject(raw) {
                throw StoreError.sectionLocked(owner)
            }
            throw StoreError.corruptPage(id)
        }
        return page
    }

    public mutating func savePage(_ page: Page) throws {
        guard let s = notebook.sections.firstIndex(where: { $0.pages.contains { $0.id == page.id } }) else {
            throw StoreError.missingPage(page.id)
        }
        try write(page, scope: try scope(ofSection: s))
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
    /// Pass the page that will use it, so an asset for a page in a locked section goes under that section's key.
    public func addAsset(data: Data, ext: String, forPage pageID: UUID? = nil) throws -> String {
        let name = AssetName.make(ext: ext)
        try writeAsset(name: name, data: data, forSection: pageID.flatMap { sectionID(ofPage: $0) })
        return name
    }

    /// Stores `data` as `assets/<name>` (atomic). `name` must be a plain file name.
    public func writeAsset(name: String, data: Data, forSection sectionID: UUID? = nil) throws {
        guard Self.isPlainFileName(name) else { throw StoreError.invalidAssetName }
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try writeObject(data, kind: .asset, logicalPath: "assets/\(name)", to: assetURL(name), scope: try scope(ofSectionID: sectionID))
    }

    /// The asset's data, or nil when the name is not a plain file name or the file is missing.
    public func loadAsset(_ name: String) -> Data? {
        guard Self.isPlainFileName(name) else { return nil }
        guard let cipher, let raw = try? Data(contentsOf: assetURL(name)) else {
            return readObject(kind: .asset, logicalPath: "assets/\(name)", from: assetURL(name))
        }
        // The header says which key scope the file is in. A section's assets open with that section's key, if it is unlocked.
        guard SectionCrypto.isSectionObject(raw) else {
            return try? NotebookCrypto.open(raw, kind: .asset, logicalPath: "assets/\(name)",
                                            notebookID: cipher.notebookID, notebookKey: cipher.key)
        }
        for (id, state) in locks {
            guard let key = state.key else { continue }
            if let plain = try? SectionCrypto.open(raw, kind: .asset, logicalPath: "assets/\(name)",
                                                   notebookID: cipher.notebookID, sectionID: id, sectionKey: key) { return plain }
        }
        return nil
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
        if var state = locks[id], state.key == nil {
            // A closed locked section only has its label to rename. The real name stays inside the section.
            state.label = name
            var nextLocks = locks
            nextLocks[id] = state
            var next = updated
            next.revision = notebook.revision + 1
            try writeObject(try Self.encode(diskView(next, locks: nextLocks)), kind: .manifest,
                            logicalPath: "notebook.json", to: manifestURL)
            notebook = next
            locks = nextLocks
            return
        }
        try commitManifest(updated)
    }

    /// Removes the section and moves its page files to the Trash, manifest first so nothing dangles.
    /// The last remaining section is never removed. Returns false when nothing was removed.
    @discardableResult
    public mutating func deleteSection(_ id: UUID) throws -> Bool {
        if let state = locks[id], state.key == nil { throw StoreError.sectionLocked(id) }
        guard notebook.sections.count > 1, let index = notebook.sections.firstIndex(where: { $0.id == id }) else { return false }
        let doomed = notebook.sections[index].pages.map(\.id)
        var updated = notebook
        updated.sections.remove(at: index)
        try commitManifest(updated)
        if locks[id] != nil {
            locks[id] = nil
            for file in [sectionKeysURL(id), sectionManifestURL(id)] { _ = try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        }
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

    // MARK: locked sections (docs/encryption-locked-sections.md)

    /// True for a section that has its own key, whether or not it is open right now.
    public func isSectionLocked(_ id: UUID) -> Bool { locks[id] != nil }

    /// True for a locked section whose key is held in memory, so its pages can be read.
    public func isSectionUnlocked(_ id: UUID) -> Bool { locks[id]?.key != nil }

    /// The Section Key of an open locked section, for the caller to cache in the Keychain.
    public func sectionKey(_ id: UUID) -> SymmetricKey? { locks[id]?.key }

    public var hasLockedSections: Bool { !locks.isEmpty }

    /// The cleartext key slots of a locked section.
    public func sectionKeysFile(_ id: UUID) throws -> SectionKeysFile {
        guard let data = try? Data(contentsOf: sectionKeysURL(id)) else { throw StoreError.corruptManifest }
        return try SectionKeysFile.decode(data)
    }

    public mutating func unlockSection(_ id: UUID, passphrase: String) throws {
        guard locks[id] != nil else { throw StoreError.noSuchSection }
        try adopt(try SectionCrypto.unlock(try sectionKeysFile(id), passphrase: passphrase), forSection: id)
    }

    public mutating func unlockSection(_ id: UUID, recoveryKey: String) throws {
        guard locks[id] != nil else { throw StoreError.noSuchSection }
        try adopt(try SectionCrypto.unlock(try sectionKeysFile(id), recoveryKey: recoveryKey), forSection: id)
    }

    /// Opens the section with a key the caller already holds, for example from the Keychain.
    public mutating func unlockSection(_ id: UUID, key: SymmetricKey) throws {
        guard locks[id] != nil else { throw StoreError.noSuchSection }
        try adopt(key, forSection: id)
    }

    /// Loads the section's real content from its manifest and puts it in place of the stand-in. Nothing is written.
    private mutating func adopt(_ key: SymmetricKey, forSection id: UUID) throws {
        guard let index = notebook.sections.firstIndex(where: { $0.id == id }), var state = locks[id] else { throw StoreError.noSuchSection }
        guard let loaded = readSectionManifest(id, key: key) else { throw StoreError.wrongKey }
        state.key = key
        state.revision = loaded.revision
        notebook.sections[index] = loaded.section
        locks[id] = state
    }

    /// Forgets the Section Key and the section's content. Nothing is written.
    public mutating func lockSectionAgain(_ id: UUID) {
        guard var state = locks[id], state.key != nil,
              let index = notebook.sections.firstIndex(where: { $0.id == id }) else { return }
        state.key = nil
        locks[id] = state
        notebook.sections[index] = Section.placeholder(id: id, label: state.label)
    }

    /// Locks a section of an encrypted notebook with its own passphrase and returns its recovery key, to be shown once.
    /// The section stays open afterwards (call `lockSectionAgain` to close it). Pages and assets are re-encrypted one file
    /// at a time, so if the app stops half way the section shows up in `interruptedLocks` and must be finished or undone.
    public mutating func lockSection(_ id: UUID, passphrase: String, label: String = "Locked section",
                                     iterations: Int = NotebookCrypto.defaultIterations) throws -> String {
        guard let cipher else { throw StoreError.notEncrypted }
        guard locks[id] == nil, let index = notebook.sections.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSection }
        guard !interruptedLocks.contains(id) else { throw StoreError.lockInterrupted }
        let made = try SectionCrypto.createKeys(notebookID: cipher.notebookID, sectionID: id, passphrase: passphrase, iterations: iterations)
        let fm = FileManager.default
        try fm.createDirectory(at: sectionsURL, withIntermediateDirectories: true)
        try made.keysFile.encoded().write(to: sectionKeysURL(id), options: .atomic)
        do {
            try raiseKeysVersion()
            try writeSectionManifest(notebook.sections[index], revision: 0, key: made.sectionKey)
        } catch {
            try? fm.removeItem(at: sectionKeysURL(id))      // nothing has been re-encrypted yet, so this undoes it cleanly
            throw error
        }
        interruptedLocks.append(id)
        try finishLock(id, key: made.sectionKey, label: label)
        return made.recoveryKey
    }

    /// `keys.json` becomes version 2 before any object is encrypted under a Section Key, so an app that only knows
    /// version 1 refuses the notebook instead of saving a manifest that loses the lock.
    private func raiseKeysVersion() throws {
        var keys = try Self.keysFile(at: url)
        guard keys.version < 2 else { return }
        keys.version = 2
        try keys.encoded().write(to: keysURL, options: .atomic)
    }

    /// Re-encrypts what is not yet under the Section Key, then marks the section locked. Safe to repeat.
    private mutating func finishLock(_ id: UUID, key: SymmetricKey, label: String) throws {
        guard cipher != nil, let index = notebook.sections.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSection }
        let superseded = try migrate(notebook.sections[index], key: key, intoSection: true)
        var nextLocks = locks
        nextLocks[id] = SectionLockState(label: label, key: key, revision: readSectionManifest(id, key: key)?.revision ?? 0)
        var next = notebook
        next.revision = notebook.revision + 1
        try writeObject(try Self.encode(diskView(next, locks: nextLocks)), kind: .manifest,
                        logicalPath: "notebook.json", to: manifestURL)
        notebook = next
        locks = nextLocks
        interruptedLocks.removeAll { $0 == id }
        // The copies of the section's assets that still sit under the Notebook Key would hand its images to anyone holding
        // that key. Remove the ones no other readable page uses.
        if let used = assetNamesUsedOutside(id) {
            for name in superseded where !used.contains(name) {
                _ = try? FileManager.default.trashItem(at: assetURL(name), resultingItemURL: nil)
            }
        }
    }

    /// Every asset name used by readable pages outside this section, or nil when one of those pages cannot be read.
    private func assetNamesUsedOutside(_ sectionID: UUID) -> Set<String>? {
        var names = Set<String>()
        for section in notebook.sections where section.id != sectionID {
            for ref in section.pages {
                guard let page = try? loadPage(ref.id) else { return nil }
                names.formUnion(page.assetNames)
            }
        }
        return names
    }

    /// Moves a section's pages between the Notebook Key and the Section Key, one file at a time. Each asset a page uses is
    /// copied to a fresh name in the target scope and the page is rewritten to point at the copy, so assets are never shared
    /// between scopes. A page already in the target scope is left alone, so the call can be repeated after an interruption.
    /// Returns the names of the assets that were copied; the originals are still in place.
    private func migrate(_ section: Section, key: SymmetricKey, intoSection: Bool) throws -> [String] {
        guard let cipher else { throw StoreError.notEncrypted }
        let target: ObjectScope = intoSection ? .section(id: section.id, key: key) : .notebook
        func openEither(_ raw: Data, _ kind: NotebookCrypto.Kind, _ path: String) throws -> (plain: Data, inSection: Bool) {
            if SectionCrypto.isSectionObject(raw) {
                let plain = try SectionCrypto.open(raw, kind: kind == .asset ? .asset : .page, logicalPath: path,
                                                   notebookID: cipher.notebookID, sectionID: section.id, sectionKey: key)
                return (plain, true)
            }
            let plain = try NotebookCrypto.open(raw, kind: kind, logicalPath: path,
                                                notebookID: cipher.notebookID, notebookKey: cipher.key)
            return (plain, false)
        }
        var copied: [String] = []
        for ref in section.pages {
            let file = pageURL(ref.id)
            guard let raw = try? Data(contentsOf: file) else { continue }       // a missing page file stays missing
            let path = Self.pageLogicalPath(ref.id)
            let opened = try openEither(raw, .page, path)
            if opened.inSection == intoSection { continue }
            var page = try JSONDecoder().decode(Page.self, from: opened.plain)
            var renamed: [String: String] = [:]
            for name in page.assetNames where Self.isPlainFileName(name) {
                guard let rawAsset = try? Data(contentsOf: assetURL(name)) else { continue }
                let data = try openEither(rawAsset, .asset, "assets/\(name)").plain
                let fresh = AssetName.make(ext: (name as NSString).pathExtension)
                try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
                try writeObject(data, kind: .asset, logicalPath: "assets/\(fresh)", to: assetURL(fresh), scope: target)
                renamed[name] = fresh
                copied.append(name)
            }
            page = page.renamingAssets(renamed)
            try writeObject(try Self.encode(page), kind: .page, logicalPath: path, to: file, scope: target)
        }
        return copied
    }

    /// Removes a section's lock for good. The section must be open. Order: every page back under the Notebook Key, then the
    /// notebook manifest with the full section, then the section's own files go to the Trash.
    public mutating func removeLock(from id: UUID) throws {
        guard cipher != nil, let key = locks[id]?.key,
              notebook.sections.contains(where: { $0.id == id }) else { throw StoreError.sectionLocked(id) }
        try finishUnlock(id, key: key)
    }

    private mutating func finishUnlock(_ id: UUID, key: SymmetricKey) throws {
        guard let index = notebook.sections.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSection }
        let superseded = try migrate(notebook.sections[index], key: key, intoSection: false)
        var nextLocks = locks
        nextLocks[id] = nil
        var next = notebook
        next.revision = notebook.revision + 1
        try writeObject(try Self.encode(diskView(next, locks: nextLocks)), kind: .manifest,
                        logicalPath: "notebook.json", to: manifestURL)
        notebook = next
        locks = nextLocks
        interruptedLocks.removeAll { $0 == id }
        let fm = FileManager.default
        for name in superseded { _ = try? fm.trashItem(at: assetURL(name), resultingItemURL: nil) }
        for file in [sectionKeysURL(id), sectionManifestURL(id)] { _ = try? fm.trashItem(at: file, resultingItemURL: nil) }
    }

    /// Finishes a lock that was interrupted, using the section passphrase.
    public mutating func finishInterruptedLock(_ id: UUID, passphrase: String, label: String = "Locked section") throws {
        guard interruptedLocks.contains(id) else { throw StoreError.noSuchSection }
        let key = try SectionCrypto.unlock(try sectionKeysFile(id), passphrase: passphrase)
        guard readSectionManifest(id, key: key) != nil else { throw StoreError.wrongKey }
        try finishLock(id, key: key, label: label)
    }

    /// Undoes a lock that was interrupted: everything goes back under the Notebook Key and the section's files are removed.
    public mutating func rollBackInterruptedLock(_ id: UUID, passphrase: String) throws {
        guard interruptedLocks.contains(id) else { throw StoreError.noSuchSection }
        let key = try SectionCrypto.unlock(try sectionKeysFile(id), passphrase: passphrase)
        guard readSectionManifest(id, key: key) != nil else { throw StoreError.wrongKey }
        try finishUnlock(id, key: key)
    }

    /// Replaces a locked section's passphrase. Nothing else is rewritten. The section must be open.
    public func changeSectionPassphrase(_ id: UUID, to passphrase: String,
                                        iterations: Int = NotebookCrypto.defaultIterations) throws {
        guard let key = locks[id]?.key else { throw StoreError.sectionLocked(id) }
        let updated = try SectionCrypto.changePassphrase(try sectionKeysFile(id), sectionKey: key,
                                                         newPassphrase: passphrase, iterations: iterations)
        try updated.encoded().write(to: sectionKeysURL(id), options: .atomic)
    }
}
