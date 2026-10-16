import Foundation

/// Which sidebar sections and folders are folded, per notebook folder.
///
/// Kept in UserDefaults, keyed by the folder's identity and the row id.
/// A row that has never been toggled is absent, so it stays expanded.
/// Note text, titles, and file names are not stored, and nothing is written into the notebook.
public enum SidebarCollapse {
    public static let defaultsKey = "sidebarCollapsedRows"

    /// Identity of a notebook folder. The file-resource identifier survives a rename on the same volume.
    /// A path is used only when the volume has no such identifier.
    public static func folderIdentity(of url: URL) -> String {
        let folder = url.standardizedFileURL
        if let data = try? folder.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? Data,
           !data.isEmpty {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return folder.path
    }

    /// Folded rows to put back. A saved id is kept only when that row is still a section or folder.
    /// Anything else, including a row that was never folded, stays expanded.
    public static func restored(saved: Set<UUID>, collapsible: Set<UUID>) -> Set<UUID> {
        saved.intersection(collapsible)
    }

    public static func load(folder url: URL, defaults: UserDefaults = .standard) -> Set<UUID> {
        let ids = readAll(defaults)[folderIdentity(of: url)] ?? []
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    public static func store(_ ids: Set<UUID>, folder url: URL, defaults: UserDefaults = .standard) {
        var all = readAll(defaults)
        let key = folderIdentity(of: url)
        if ids.isEmpty { all.removeValue(forKey: key) }
        else { all[key] = ids.map { $0.uuidString.lowercased() }.sorted() }
        write(all, defaults: defaults)
    }

    public static func setCollapsed(_ id: UUID, _ collapsed: Bool, folder url: URL, defaults: UserDefaults = .standard) {
        var ids = load(folder: url, defaults: defaults)
        if collapsed { ids.insert(id) } else { ids.remove(id) }
        store(ids, folder: url, defaults: defaults)
    }

    /// Moves the folded rows when the folder's identity changes, such as a path used on a volume with no file id.
    public static func relocate(from old: URL, to new: URL, defaults: UserDefaults = .standard) {
        let from = folderIdentity(of: old)
        let to = folderIdentity(of: new)
        guard from != to else { return }
        var all = readAll(defaults)
        guard let ids = all.removeValue(forKey: from) else { return }
        all[to] = ids
        write(all, defaults: defaults)
    }

    private static func readAll(_ defaults: UserDefaults) -> [String: [String]] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) else { return [:] }
        var all: [String: [String]] = [:]
        for (key, value) in raw {
            if let ids = value as? [String] { all[key] = ids }
        }
        return all
    }

    private static func write(_ all: [String: [String]], defaults: UserDefaults) {
        if all.isEmpty { defaults.removeObject(forKey: defaultsKey) }
        else { defaults.set(all, forKey: defaultsKey) }
    }
}
