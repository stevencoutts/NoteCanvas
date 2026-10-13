import Foundation

public struct PageRef: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
}

public struct Section: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var pages: [PageRef]
    public init(id: UUID, name: String, pages: [PageRef]) { self.id = id; self.name = name; self.pages = pages }
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
