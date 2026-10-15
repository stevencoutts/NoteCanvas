import Foundation

/// The folder of the notebook left open.
///
/// Stored as a file-URL bookmark so a rename or move on the same volume still resolves.
/// A path string is kept only when a bookmark cannot be created.
/// Page titles and note file names are not stored.
public enum LastNotebook {
    public static let defaultsKey = "lastOpenNotebook"

    public static func remember(_ url: URL, defaults: UserDefaults = .standard) {
        let folder = url.standardizedFileURL
        if let data = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.set(folder.path, forKey: defaultsKey)
        }
    }

    /// Drops the remembered folder. Used when the notebook is closed.
    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Opens the remembered notebook. The stored location is removed when nothing resolves or the folder will not open, so a later launch does not try it again.
    public static func reopen(defaults: UserDefaults = .standard) -> NotebookPackage? {
        guard defaults.object(forKey: defaultsKey) != nil else { return nil }
        guard let url = resolve(defaults: defaults) else {
            forget(defaults: defaults)
            return nil
        }
        do {
            return try NotebookPackage.open(at: url)
        } catch {
            forget(defaults: defaults)
            return nil
        }
    }

    private static func resolve(defaults: UserDefaults) -> URL? {
        if let data = defaults.data(forKey: defaultsKey) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return nil
            }
            if stale { remember(url, defaults: defaults) }
            return url
        }
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }
}
