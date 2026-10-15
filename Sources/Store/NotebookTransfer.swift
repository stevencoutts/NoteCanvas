import Foundation
import PageModel

/// What a copy brought across.
public struct TransferResult: Equatable {
    /// Ids of the pages, folders or section made at the top of what was copied, in the destination.
    public var topLevelIDs: [UUID] = []
    public var pages = 0
    public var folders = 0
    /// Images or attachments the source no longer had, so the copied page points at a file that is not there.
    public var missingAssets = 0
    public init() {}
}

/// Copying and moving pages, folders and sections, inside a notebook or between notebooks.
/// A copy is made through the notebook's own calls, so a destination that is encrypted, or a locked section that is open,
/// stores the copy under its own key. Copies get fresh ids, so nothing clashes with what is already there.
public extension NotebookPackage {
    /// True when the section can be read now: it is not locked, or it is locked and has been opened.
    func isSectionReadable(_ id: UUID) -> Bool { !isSectionLocked(id) || isSectionUnlocked(id) }

    /// Moves a section to a new place in the list. `index` is counted as a drop position is.
    mutating func moveSection(_ id: UUID, to index: Int) throws -> Bool {
        var updated = notebook
        guard updated.moveSection(id, to: index), updated != notebook else { return false }
        try commitManifest(updated)
        return true
    }

    /// Copies pages and folders of `source`'s section into `dest`'s section.
    static func copyItems(_ ids: [UUID], fromSection sourceSection: Int, of source: NotebookPackage,
                          into dest: inout NotebookPackage, section destSection: Int,
                          inFolder parent: UUID?) throws -> TransferResult {
        guard source.notebook.sections.indices.contains(sourceSection),
              dest.notebook.sections.indices.contains(destSection) else { throw StoreError.noSuchSection }
        let section = source.notebook.sections[sourceSection]
        var result = TransferResult()
        for id in ids {
            guard let node = section.item(id) else { continue }
            let made = try copyNode(node, of: source, into: &dest, section: destSection, parent: parent, result: &result)
            result.topLevelIDs.append(made)
        }
        return result
    }

    /// Copies a whole section of `source` into `dest` as a new section at the end.
    static func copySection(_ id: UUID, of source: NotebookPackage, into dest: inout NotebookPackage,
                            named name: String? = nil) throws -> TransferResult {
        guard let section = source.notebook.sections.first(where: { $0.id == id }) else { throw StoreError.noSuchSection }
        if !source.isSectionReadable(id) { throw StoreError.sectionLocked(id) }
        let made = try dest.addSection(name: name ?? section.name, pages: [])
        let index = dest.notebook.sections.count - 1
        var result = TransferResult()
        result.topLevelIDs = [made.id]
        for node in section.items {
            _ = try copyNode(node, of: source, into: &dest, section: index, parent: nil, result: &result)
        }
        return result
    }

    /// Moves pages or folders to another section of this notebook. The pieces are copied first and removed from
    /// the old place only once the copy is complete, so a failure part way never loses a page.
    mutating func relocate(_ id: UUID, fromSection: Int, toSection: Int, inFolder parent: UUID?) throws -> TransferResult {
        let snapshot = self
        let result = try Self.copyItems([id], fromSection: fromSection, of: snapshot, into: &self,
                                        section: toSection, inFolder: parent)
        try deleteItem(id, section: fromSection)
        return result
    }

    /// Removes a page, or a folder with everything in it. Pages go to the Trash.
    mutating func deleteItem(_ id: UUID, section: Int) throws {
        guard notebook.sections.indices.contains(section), let node = notebook.sections[section].item(id) else { return }
        for pageID in Section.pageIDs(of: node) { try deletePage(id: pageID) }
        if case .folder = node { try dissolveFolder(id, section: section) }
    }

    private static func copyNode(_ node: NotebookItem, of source: NotebookPackage, into dest: inout NotebookPackage,
                                 section: Int, parent: UUID?, result: inout TransferResult) throws -> UUID {
        switch node {
        case .page(let ref):
            let page = try source.loadPage(ref.id)
            let made = try dest.addPage(title: ref.title, section: section, inFolder: parent)
            var renamed: [String: String] = [:]
            for name in page.assetNames {
                guard let data = source.loadAsset(name) else { result.missingAssets += 1; continue }
                let ext = URL(fileURLWithPath: name).pathExtension
                renamed[name] = try dest.addAsset(data: data, ext: ext, forPage: made.id)
            }
            var copy = page.renamingAssets(renamed)
            copy.id = made.id
            try dest.savePage(copy)
            if let colour = ref.colorHex { try dest.setPageColor(made.id, section: section, to: colour) }
            result.pages += 1
            return made.id
        case .folder(let folder):
            let made = try dest.addFolder(named: folder.name, section: section, inFolder: parent)
            if let colour = folder.colorHex { try dest.setFolderColor(made, section: section, to: colour) }
            result.folders += 1
            for child in folder.children {
                _ = try copyNode(child, of: source, into: &dest, section: section, parent: made, result: &result)
            }
            return made
        }
    }
}
