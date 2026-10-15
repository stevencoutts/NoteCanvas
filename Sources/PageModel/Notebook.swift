import Foundation

public struct PageRef: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
}

public struct Folder: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var children: [NotebookItem]
    public init(id: UUID, name: String, children: [NotebookItem] = []) {
        self.id = id; self.name = name; self.children = children
    }
}

public enum NotebookItem: Codable, Equatable, Sendable {
    case page(PageRef)
    case folder(Folder)

    public var id: UUID {
        switch self {
        case .page(let page): return page.id
        case .folder(let folder): return folder.id
        }
    }
}

public struct Section: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Folders and pages in display order. A folder's children can be folders too.
    public var items: [NotebookItem]

    /// Every page in the section, folders first in the order they appear.
    public var pages: [PageRef] { Self.flatten(items) }

    public init(id: UUID, name: String, pages: [PageRef]) {
        self.id = id
        self.name = name
        self.items = pages.map { .page($0) }
    }

    public init(id: UUID, name: String, items: [NotebookItem]) {
        self.id = id
        self.name = name
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case id, name, pages, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let items = try c.decodeIfPresent([NotebookItem].self, forKey: .items) {
            self.items = items
        } else {
            let pages = try c.decodeIfPresent([PageRef].self, forKey: .pages) ?? []
            self.items = pages.map { .page($0) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(items, forKey: .items)
        try c.encode(pages, forKey: .pages)
    }

    public func parent(of id: UUID) -> UUID? { Self.locate(id, in: items, parent: nil)?.parent }

    public func folder(_ id: UUID) -> Folder? { Self.findFolder(id, in: items) }

    /// Appends a page. A missing folder puts it at the section root.
    public mutating func addPage(_ ref: PageRef, inFolder folderID: UUID? = nil) {
        let item = NotebookItem.page(ref)
        if let folderID, Self.insert(item, into: folderID, in: &items, at: nil) { return }
        items.append(item)
    }

    @discardableResult
    public mutating func setTitle(_ title: String, for pageID: UUID) -> Bool {
        Self.setTitle(title, id: pageID, in: &items)
    }

    public mutating func removePage(_ id: UUID) { _ = Self.remove(id, from: &items) }

    @discardableResult
    public mutating func addFolder(named name: String, inFolder parent: UUID?) -> UUID {
        let folder = Folder(id: UUID(), name: name, children: [])
        if let parent, Self.insert(.folder(folder), into: parent, in: &items, at: nil) { return folder.id }
        items.append(.folder(folder))
        return folder.id
    }

    @discardableResult
    public mutating func renameFolder(_ id: UUID, to name: String) -> Bool {
        Self.rename(id, to: name, in: &items)
    }

    /// Removes the folder and leaves its contents where the folder was.
    @discardableResult
    public mutating func dissolveFolder(_ id: UUID) -> Bool { Self.dissolve(id, in: &items) }

    /// Moves a page or folder. Returns false when the item or parent is missing, or the move would put a folder inside itself.
    @discardableResult
    public mutating func move(id: UUID, into parent: UUID?, at index: Int) -> Bool {
        if let parent {
            if parent == id || Self.contains(parent, inside: id, items: items) { return false }
            guard Self.findFolder(parent, in: items) != nil else { return false }
        }
        guard let location = Self.locate(id, in: items, parent: nil) else { return false }
        var adjusted = index
        if location.parent == parent, location.index < index { adjusted -= 1 }
        guard let node = Self.remove(id, from: &items) else { return false }
        let limit = parent == nil ? items.count : (Self.findFolder(parent!, in: items)?.children.count ?? 0)
        let at = min(max(adjusted, 0), limit)
        if let parent {
            guard Self.insert(node, into: parent, in: &items, at: at) else { items.append(node); return false }
        } else {
            items.insert(node, at: at)
        }
        return true
    }

    private static func flatten(_ items: [NotebookItem]) -> [PageRef] {
        items.flatMap { item -> [PageRef] in
            switch item {
            case .page(let page): return [page]
            case .folder(let folder): return flatten(folder.children)
            }
        }
    }

    private struct Place { var parent: UUID?; var index: Int }

    private static func locate(_ id: UUID, in items: [NotebookItem], parent: UUID?) -> Place? {
        for (index, item) in items.enumerated() {
            if item.id == id { return Place(parent: parent, index: index) }
            if case .folder(let folder) = item, let found = locate(id, in: folder.children, parent: folder.id) { return found }
        }
        return nil
    }

    private static func findFolder(_ id: UUID, in items: [NotebookItem]) -> Folder? {
        for item in items {
            if case .folder(let folder) = item {
                if folder.id == id { return folder }
                if let nested = findFolder(id, in: folder.children) { return nested }
            }
        }
        return nil
    }

    private static func contains(_ id: UUID, inside folderID: UUID, items: [NotebookItem]) -> Bool {
        guard let folder = findFolder(folderID, in: items) else { return false }
        return locate(id, in: folder.children, parent: folderID) != nil
    }

    @discardableResult
    private static func insert(_ item: NotebookItem, into folderID: UUID, in items: inout [NotebookItem], at index: Int?) -> Bool {
        for i in items.indices {
            guard case .folder(var folder) = items[i] else { continue }
            if folder.id == folderID {
                let at = min(max(index ?? folder.children.count, 0), folder.children.count)
                folder.children.insert(item, at: at)
                items[i] = .folder(folder)
                return true
            }
            if insert(item, into: folderID, in: &folder.children, at: index) {
                items[i] = .folder(folder)
                return true
            }
        }
        return false
    }

    @discardableResult
    private static func remove(_ id: UUID, from items: inout [NotebookItem]) -> NotebookItem? {
        if let index = items.firstIndex(where: { $0.id == id }) { return items.remove(at: index) }
        for i in items.indices {
            guard case .folder(var folder) = items[i] else { continue }
            if let removed = remove(id, from: &folder.children) {
                items[i] = .folder(folder)
                return removed
            }
        }
        return nil
    }

    private static func setTitle(_ title: String, id: UUID, in items: inout [NotebookItem]) -> Bool {
        for i in items.indices {
            switch items[i] {
            case .page(var page) where page.id == id:
                page.title = title
                items[i] = .page(page)
                return true
            case .folder(var folder):
                if setTitle(title, id: id, in: &folder.children) {
                    items[i] = .folder(folder)
                    return true
                }
            default: break
            }
        }
        return false
    }

    private static func rename(_ id: UUID, to name: String, in items: inout [NotebookItem]) -> Bool {
        for i in items.indices {
            guard case .folder(var folder) = items[i] else { continue }
            if folder.id == id {
                folder.name = name
                items[i] = .folder(folder)
                return true
            }
            if rename(id, to: name, in: &folder.children) {
                items[i] = .folder(folder)
                return true
            }
        }
        return false
    }

    private static func dissolve(_ id: UUID, in items: inout [NotebookItem]) -> Bool {
        if let index = items.firstIndex(where: { $0.id == id }), case .folder(let folder) = items[index] {
            items.replaceSubrange(index...index, with: folder.children)
            return true
        }
        for i in items.indices {
            guard case .folder(var folder) = items[i] else { continue }
            if dissolve(id, in: &folder.children) {
                items[i] = .folder(folder)
                return true
            }
        }
        return false
    }
}

public struct Notebook: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var name: String
    public var sections: [Section]

    public init(name: String) {
        self.version = Notebook.currentVersion
        self.name = name
        self.sections = [Section(id: UUID(), name: "Section 1", pages: [])]
    }
}
