import Foundation
import OneImport
import CanvasKit

func backupScanChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nc-backups-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func touch(_ path: String, in base: URL, _ text: String = "x") {
        let url = base.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }
    touch("Main Notebook/Ideas.one (On 11-13-24).one", in: root)
    touch("Main Notebook/Ideas.one (On 12-02-24).one", in: root)
    touch("Main Notebook/Ideas.one (On 01-05-24).one", in: root)
    touch("Main Notebook/Projects/Plan.one (On 03-04-25).one", in: root)
    touch("Main Notebook/Ideas.onebackupconstruction", in: root)
    touch("Main Notebook/.hidden.one", in: root)
    touch("Personal/Diary.one", in: root)
    touch("Loose.one (On 06-07-25).one", in: root)
    touch("Notes.txt", in: root)

    let scan = BackupScanner.scan(root)
    checkEqual(scan.notebooks.map(\.name), ["Main Notebook", "OneNote Backups", "Personal"], "one notebook per top-level folder, loose files together")
    checkEqual(scan.sectionCount, 4, "newest copy of each section only")
    checkEqual(scan.olderCopiesSkipped, 2, "older dated copies are counted")
    let main = scan.notebooks.first { $0.name == "Main Notebook" }
    checkEqual(main?.sections.map(\.displayName) ?? [], ["Ideas", "Projects / Plan"], "section groups become Group / Section")
    check(main?.sections.first?.url.lastPathComponent.contains("12-02-24") == true, "the newest dated copy wins")
    checkEqual(scan.notebooks.first { $0.name == "Personal" }?.sections.map(\.name) ?? [], ["Diary"], "an undated file is still a section")

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let parsed = BackupScanner.parse(fileName: "Name.one (On 11-13-24).one")
    checkEqual(parsed?.name, "Name", "the date suffix is removed from the section name")
    let day = parsed?.date.map { utc.dateComponents([.year, .month, .day], from: $0) }
    checkEqual(day?.year, 2024, "year is read from yy")
    checkEqual(day?.month, 11, "month is read first")
    checkEqual(day?.day, 13, "day is read second")
    let swapped = BackupScanner.parse(fileName: "Name.one (On 13-11-24).one")?.date.map { utc.dateComponents([.month, .day], from: $0) }
    checkEqual(swapped?.month, 11, "a first number above 12 is read as the day")
    let dotted = BackupScanner.parse(fileName: "A.b.one (On 1-2-2024).one")
    checkEqual(dotted?.name, "A.b", "dots in a section name survive")
    check(BackupScanner.parse(fileName: "Plain.one")?.date == nil && BackupScanner.parse(fileName: "Plain.one")?.name == "Plain", "plain .one name")
    check(BackupScanner.parse(fileName: "notes.txt") == nil, "other extensions are ignored")
    check(BackupScanner.parse(fileName: "Ideas.onebackupconstruction") == nil, "backup construction files are ignored")

    // A batch made only of unreadable files creates nothing and says which ones failed.
    let broken = fm.temporaryDirectory.appendingPathComponent("nc-broken-\(UUID().uuidString)")
    let dest = fm.temporaryDirectory.appendingPathComponent("nc-dest-\(UUID().uuidString)")
    try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: broken); try? fm.removeItem(at: dest) }
    touch("Broken/Bad.one", in: broken, "not a OneNote file")
    var outcome: BackupImportOutcome?
    BackupImportRunner.run(BackupScanner.scan(broken), into: dest, cancel: ImportCancelFlag(),
                           progress: { _ in }, completion: { outcome = $0 })
    let deadline = Date().addingTimeInterval(20)
    while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(outcome != nil, "the batch import finished")
    checkEqual(outcome?.failed ?? [], ["Broken / Bad"], "an unreadable file is reported by name")
    checkEqual(outcome?.notebooks.count ?? -1, 0, "no notebook is kept when nothing could be read")
    checkEqual((try? fm.contentsOfDirectory(atPath: dest.path))?.count ?? -1, 0, "no empty notebook is left in the destination")
}
