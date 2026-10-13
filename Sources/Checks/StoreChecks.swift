import Foundation
import PageModel
import Store

func storeChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Test.notebook")

    // create / open
    var pkg = try! NotebookPackage.create(at: url, name: "Test")
    checkEqual(pkg.notebook.name, "Test", "create sets the name")
    checkEqual(pkg.notebook.sections.count, 1, "new notebook has one section")
    checkEqual(checkThrows("create over existing") { try NotebookPackage.create(at: url, name: "x") } as? StoreError,
               .alreadyExists, "create never clobbers an existing path")
    let reopened = try! NotebookPackage.open(at: url)
    checkEqual(reopened.notebook, pkg.notebook, "open reads back what create wrote")

    // add / save / load
    var page = try! pkg.addPage(title: "First")
    let other = try! pkg.addPage(title: "Second")
    page.objects = [.text(box(-5, 7, 220, lines: 2))]
    page.title = "Renamed"
    try! pkg.savePage(page)
    checkEqual(try! pkg.loadPage(page.id), page, "saved page loads back identically")
    checkEqual(try! NotebookPackage.open(at: url).notebook.sections[0].pages.map(\.title),
               ["Renamed", "Second"], "title change reaches the manifest on disk")

    // empty page round-trips (Review Focus 1)
    checkEqual(try! pkg.loadPage(other.id).objects.count, 0, "empty page loads")

    // stray temp file next to a page does not matter
    try! Data("junk".utf8).write(to: url.appendingPathComponent("pages/\(page.id.uuidString).json.tmp"))
    checkEqual(try! pkg.loadPage(page.id), page, "stray .tmp file is ignored")

    // corrupt page: typed error, other pages unaffected (Review Focus 4)
    try! Data("{".utf8).write(to: url.appendingPathComponent("pages/\(other.id.uuidString).json"))
    checkEqual(checkThrows("corrupt page") { try pkg.loadPage(other.id) } as? StoreError,
               .corruptPage(other.id), "truncated page gives corruptPage")
    checkEqual(try! pkg.loadPage(page.id), page, "other pages still load")

    // missing page file
    try! FileManager.default.removeItem(at: url.appendingPathComponent("pages/\(other.id.uuidString).json"))
    checkEqual(checkThrows("missing page") { try pkg.loadPage(other.id) } as? StoreError,
               .missingPage(other.id), "missing page file gives missingPage")

    // bad section index, unknown page save
    checkEqual(checkThrows("bad section") { try pkg.addPage(title: "x", section: 5) } as? StoreError,
               .noSuchSection, "addPage with a bad section index throws")
    checkEqual(checkThrows("save unknown") { try pkg.savePage(Page(id: UUID(), title: "x", objects: [])) } != nil,
               true, "saving a page the manifest does not list throws")

    // A failed manifest write leaves the in-memory notebook as it is on disk (package folder made read-only;
    // pages/ stays writable, so only the manifest write fails).
    let fm = FileManager.default
    func setWritable(_ on: Bool) {
        try! fm.setAttributes([.posixPermissions: on ? 0o755 : 0o555], ofItemAtPath: url.path)
    }
    var retitled = page
    retitled.title = "Retitled"
    setWritable(false)
    check(checkThrows("save with read-only manifest") { try pkg.savePage(retitled) } != nil, "savePage reports a failed manifest write")
    checkEqual(pkg.notebook.sections[0].pages.map(\.title), ["Renamed", "Second"],
               "a failed manifest write does not change the in-memory titles")
    check(checkThrows("delete with read-only manifest") { try pkg.deletePage(id: page.id) } != nil,
          "deletePage reports a failed manifest write")
    checkEqual(pkg.notebook.sections[0].pages.map(\.id), [page.id, other.id], "a failed delete keeps the reference in memory")
    check(fm.fileExists(atPath: url.appendingPathComponent("pages/\(page.id.uuidString).json").path), "a failed delete keeps the file")
    check(checkThrows("add with read-only manifest") { try pkg.addPage(title: "Third") } != nil, "addPage reports a failed manifest write")
    checkEqual(pkg.notebook.sections[0].pages.map(\.id), [page.id, other.id], "a failed add does not list the page in memory")
    setWritable(true)
    check((try? pkg.savePage(retitled)) != nil, "retrying the save once the folder is writable succeeds")
    checkEqual(try! NotebookPackage.open(at: url).notebook.sections[0].pages.map(\.title), ["Retitled", "Second"],
               "retrying the save once the folder is writable writes the new title")

    // delete: manifest first, then the page file goes to the Trash (recoverable), not removed outright
    let trashed = try! pkg.deletePage(id: page.id)
    checkEqual(pkg.notebook.sections[0].pages.map(\.id), [other.id], "delete removes the reference")
    check(!fm.fileExists(atPath: url.appendingPathComponent("pages/\(page.id.uuidString).json").path),
          "delete removes the file from the package")
    if let trashed {
        check(fm.fileExists(atPath: trashed.path), "the deleted page file is in the Trash")
        try? fm.removeItem(at: trashed)                    // do not leave test files in the user's Trash
    } else {
        check(false, "deletePage reports where it trashed the page file")
    }

    // foreign / future / garbage (Review Focus 4)
    let plain = root.appendingPathComponent("plain")
    try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    checkEqual(checkThrows("not a package") { try NotebookPackage.open(at: plain) } as? StoreError,
               .notAPackage, "folder without notebook.json is not a package")

    let future = root.appendingPathComponent("future.notebook")
    try! FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
    try! Data(#"{"version":99,"name":"x","sections":[]}"#.utf8).write(to: future.appendingPathComponent("notebook.json"))
    checkEqual(checkThrows("future version") { try NotebookPackage.open(at: future) } as? StoreError,
               .unsupportedVersion(99), "newer manifest version is refused, not misread")

    let garbage = root.appendingPathComponent("garbage.notebook")
    try! FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
    try! Data("not json".utf8).write(to: garbage.appendingPathComponent("notebook.json"))
    checkEqual(checkThrows("garbage manifest") { try NotebookPackage.open(at: garbage) } as? StoreError,
               .corruptManifest, "garbage manifest gives corruptManifest")
}
