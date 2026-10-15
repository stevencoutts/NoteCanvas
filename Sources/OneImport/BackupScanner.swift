import Foundation

/// One OneNote section found in a backup folder: the newest dated copy of it.
public struct BackupSection: Equatable {
    public var url: URL
    /// The top-level folder under the scanned root. Files that sit directly in the root use `BackupScanner.rootNotebookName`.
    public var notebook: String
    /// Section-group folders between the notebook folder and the file, outermost first.
    public var groups: [String]
    /// The section name, with the ".one" extension and the "(On MM-DD-YY)" suffix removed.
    public var name: String
    /// The date in the file name, when it has one.
    public var date: Date?

    /// "Group / Section", or just the section name when it sits directly in the notebook.
    public var displayName: String { (groups + [name]).joined(separator: " / ") }
}

public struct BackupNotebook: Equatable {
    public var name: String
    public var sections: [BackupSection]
}

public struct BackupScan: Equatable {
    public var notebooks: [BackupNotebook]
    /// Dated copies that lost to a newer copy of the same section.
    public var olderCopiesSkipped: Int

    public var sectionCount: Int { notebooks.reduce(0) { $0 + $1.sections.count } }
}

public enum BackupScanner {
    public static let rootNotebookName = "OneNote Backups"

    /// Where OneNote for Mac keeps its backups. The path comes from the project's findings notes, so it is inferred.
    public static func defaultBackupFolder() -> URL {
        var url = FileManager.default.homeDirectoryForCurrentUser
        for part in ["Library", "Containers", "com.microsoft.onenote.mac", "Data", "Library", "Application Support",
                     "Microsoft User Data", "OneNote", "15.0", "Backup"] {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url
    }

    /// Splits "Name.one (On 11-13-24).one" into ("Name", date). A plain "Name.one" gives (name, nil). Anything else gives nil.
    /// The date is read as month-day-year. A first number above 12 is taken to be the day, because OneNote could have
    /// written either order (inferred; the one real example seen had a 13 in the middle).
    public static func parse(fileName: String) -> (name: String, date: Date?)? {
        guard fileName.lowercased().hasSuffix(".one") else { return nil }
        let pattern = #"^(.*)\.one \(On (\d{1,2})-(\d{1,2})-(\d{2}|\d{4})\)\.one$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)),
           m.numberOfRanges == 5,
           let nameRange = Range(m.range(at: 1), in: fileName),
           let aRange = Range(m.range(at: 2), in: fileName),
           let bRange = Range(m.range(at: 3), in: fileName),
           let yRange = Range(m.range(at: 4), in: fileName),
           let a = Int(fileName[aRange]), let b = Int(fileName[bRange]), let y = Int(fileName[yRange]) {
            let year = y < 100 ? y + 2000 : y
            var month = a, day = b
            if month > 12 && day <= 12 { month = b; day = a }
            var parts = DateComponents()
            parts.year = year; parts.month = month; parts.day = day
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let name = String(fileName[nameRange])
            guard !name.isEmpty else { return nil }
            return (name, calendar.date(from: parts))
        }
        let base = String(fileName.dropLast(4))
        return base.isEmpty ? nil : (base, nil)
    }

    /// Finds every ".one" file under `root` and keeps the newest copy of each section. Two files are the same section
    /// when they sit in the same folder and have the same name once the date suffix is removed. A file with no date in its
    /// name is ranked by its modification date. The files are never opened.
    public static func scan(_ root: URL) -> BackupScan {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return BackupScan(notebooks: [], olderCopiesSkipped: 0)
        }

        struct Candidate { var section: BackupSection; var rank: Date; var modified: Date }
        var best: [String: Candidate] = [:]
        var total = 0

        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let parsed = parse(fileName: file.lastPathComponent) else { continue }
            let all = file.resolvingSymlinksInPath().pathComponents
            guard all.count > rootPath.count, Array(all.prefix(rootPath.count)) == rootPath else { continue }
            total += 1
            var folders = Array(all.dropFirst(rootPath.count).dropLast())
            let notebook = folders.isEmpty ? rootNotebookName : folders.removeFirst()
            let modified = values.contentModificationDate ?? .distantPast
            let section = BackupSection(url: file, notebook: notebook, groups: folders, name: parsed.name, date: parsed.date)
            let candidate = Candidate(section: section, rank: parsed.date ?? modified, modified: modified)
            let key = ([notebook] + folders + [parsed.name]).joined(separator: "\u{0}")
            if let existing = best[key] {
                let newer = candidate.rank != existing.rank ? candidate.rank > existing.rank : candidate.modified > existing.modified
                if newer { best[key] = candidate }
            } else {
                best[key] = candidate
            }
        }

        var byNotebook: [String: [BackupSection]] = [:]
        for candidate in best.values { byNotebook[candidate.section.notebook, default: []].append(candidate.section) }
        let names = byNotebook.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let notebooks = names.map { name in
            BackupNotebook(name: name, sections: (byNotebook[name] ?? []).sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        }
        return BackupScan(notebooks: notebooks, olderCopiesSkipped: total - best.count)
    }
}
