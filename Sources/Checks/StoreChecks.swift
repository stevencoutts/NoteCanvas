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

    // sections: add, rename, delete
    var sectioned = try! NotebookPackage.create(at: root.appendingPathComponent("Sections.notebook"), name: "S")
    let firstSection = sectioned.notebook.sections[0].id
    let extra = try! sectioned.addEmptySection(name: "Second")
    checkEqual(sectioned.notebook.sections.map(\.name), ["Section 1", "Second"], "an empty section is appended")
    checkEqual(sectioned.notebook.sections[1].pages.count, 0, "a new section has no pages")
    try! sectioned.renameSection(extra.id, to: "Renamed")
    checkEqual(try! NotebookPackage.open(at: sectioned.url).notebook.sections[1].name, "Renamed", "a section rename reaches disk")
    try! sectioned.renameSection(UUID(), to: "Nope")
    checkEqual(sectioned.notebook.sections.map(\.name), ["Section 1", "Renamed"], "renaming an unknown section changes nothing")
    let kept = try! sectioned.addPage(title: "Kept", section: 1)
    check(try! sectioned.deleteSection(extra.id), "a section can be deleted")
    checkEqual(sectioned.notebook.sections.map(\.id), [firstSection], "the deleted section is gone from the manifest")
    check(!(try! sectioned.deleteSection(firstSection)), "the last section is never deleted")
    check(!(try! sectioned.deleteSection(UUID())), "deleting an unknown section does nothing")
    _ = kept

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

    pageColorStoreChecks()
}

func pageColorStoreChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Colors.notebook")
    var pkg = try! NotebookPackage.create(at: url, name: "Colors")
    let page = try! pkg.addPage(title: "Kept")
    let fileURL = url.appendingPathComponent("pages/\(page.id.uuidString).json")
    let before = try! Data(contentsOf: fileURL)
    try! pkg.setPageColor(page.id, section: 0, to: "#34547E")
    checkEqual(try! Data(contentsOf: fileURL), before, "a page colour does not change the page file contents")
    checkEqual(pkg.notebook.sections[0].pages.first?.title, "Kept", "a page colour does not change its title")
    checkEqual(pkg.notebook.sections[0].pages.first?.colorHex, "#34547E", "a page colour is written to the manifest")
    let reopened = try! NotebookPackage.open(at: url)
    checkEqual(reopened.notebook.sections[0].pages.first?.colorHex, "#34547E", "a page colour round-trips from the manifest")
    checkEqual(try! pkg.loadPage(page.id), page, "colouring a page leaves the loaded page file unchanged")
    try! pkg.setPageColor(page.id, section: 0, to: nil)
    checkEqual(pkg.notebook.sections[0].pages.first?.colorHex, nil as String?, "default clears a saved page colour")
    checkEqual(pkg.notebook.sections[0].pages.first?.title, "Kept", "clearing a page colour leaves its title")
}

func assetAndSectionChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var pkg = try! NotebookPackage.create(at: root.appendingPathComponent("A.notebook"), name: "A")

    let name = try! pkg.addAsset(data: Data([1, 2, 3]), ext: "PNG")
    check(name.hasSuffix(".png"), "asset keeps a sanitised extension")
    checkEqual(pkg.loadAsset(name), Data([1, 2, 3]), "asset round-trips")
    try! pkg.writeAsset(name: "fixed.jpg", data: Data([7]))
    checkEqual(pkg.loadAsset("fixed.jpg"), Data([7]), "writeAsset stores under the given name")
    checkEqual(pkg.loadAsset("../notebook.json"), nil, "a path escape is not an asset")
    checkEqual(pkg.loadAsset("a/b.png"), nil, "a nested path is not an asset")
    checkEqual(pkg.loadAsset(""), nil, "an empty name is not an asset")
    checkEqual(pkg.loadAsset("missing.png"), nil, "a missing asset is nil")
    check(checkThrows("writeAsset with a path") { try pkg.writeAsset(name: "../x.png", data: Data()) } != nil,
          "writeAsset refuses a name that is not a plain file name")

    let p1 = Page(id: UUID(), title: "One",
                  objects: [.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 10, height: 10), asset: name))])
    let p2 = Page(id: UUID(), title: "Two", objects: [])
    let report = Data(#"{"pagesImported":2}"#.utf8)
    let section = try! pkg.addSection(name: "Imported", pages: [p1, p2], report: report)
    checkEqual(pkg.notebook.sections.count, 2, "section added")
    checkEqual(pkg.notebook.sections[1].name, "Imported", "section name kept")
    checkEqual(pkg.notebook.sections[1].pages.map(\.title), ["One", "Two"], "page refs keep their order")
    checkEqual(try! pkg.loadPage(p1.id), p1, "an imported page loads back identically")
    checkEqual(try! NotebookPackage.open(at: pkg.url).notebook, pkg.notebook, "the manifest on disk matches memory")
    check(FileManager.default.fileExists(atPath: pkg.url.appendingPathComponent("imports/\(section.id.uuidString).json").path),
          "the import report is written")

    let empty = try! pkg.addSection(name: "Empty", pages: [])
    checkEqual(pkg.notebook.sections.last?.id, empty.id, "an empty section can be added")

    // A failing page write must leave the manifest untouched (Review Focus 4).
    if getuid() != 0 {
        let pagesDir = pkg.url.appendingPathComponent("pages")
        chmod(pagesDir.path, 0o500)
        let before = pkg.notebook
        check(checkThrows("addSection into a read-only pages folder") {
            try pkg.addSection(name: "Bad", pages: [Page(id: UUID(), title: "x", objects: [])])
        } != nil, "addSection reports the write failure")
        chmod(pagesDir.path, 0o700)
        checkEqual(pkg.notebook, before, "a failed addSection leaves the in-memory manifest unchanged")
        checkEqual(try! NotebookPackage.open(at: pkg.url).notebook, before, "…and the manifest on disk")
    }
}

func sidebarCollapseChecks() {
    let section = UUID()
    let folder = UUID()
    let page = UUID()
    let gone = UUID()
    let neverFolded = UUID()
    checkEqual(SidebarCollapse.restored(saved: [folder, page, gone], collapsible: [section, folder, neverFolded]),
               [folder], "only a folded section or folder that still exists is restored")
    checkEqual(SidebarCollapse.restored(saved: [], collapsible: [section, folder]),
               [], "a row that was never folded stays expanded")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "NoteCanvas.checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = root.appendingPathComponent("A.notebook")
    let second = root.appendingPathComponent("B.notebook")
    try! FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    SidebarCollapse.setCollapsed(folder, true, folder: first, defaults: defaults)
    SidebarCollapse.setCollapsed(section, true, folder: second, defaults: defaults)
    checkEqual(SidebarCollapse.load(folder: first, defaults: defaults), [folder], "a notebook keeps its own folded rows")
    checkEqual(SidebarCollapse.load(folder: second, defaults: defaults), [section], "another notebook keeps different folded rows")

    let renamed = root.appendingPathComponent("A2.notebook")
    try! FileManager.default.moveItem(at: first, to: renamed)
    checkEqual(SidebarCollapse.load(folder: renamed, defaults: defaults), [folder], "renaming the notebook folder keeps its folded rows")
    checkEqual(SidebarCollapse.load(folder: second, defaults: defaults), [section], "renaming one notebook leaves the other alone")

    SidebarCollapse.setCollapsed(folder, false, folder: renamed, defaults: defaults)
    checkEqual(SidebarCollapse.load(folder: renamed, defaults: defaults), [], "expanding a row forgets that it was folded")
    checkEqual(SidebarCollapse.load(folder: second, defaults: defaults), [section], "expanding a row in one notebook leaves the other folded")

    SidebarCollapse.setCollapsed(folder, true, folder: renamed, defaults: defaults)
    check(SidebarCollapse.folderIdentity(of: renamed) != SidebarCollapse.folderIdentity(of: second),
          "two notebook folders do not share an identity")
    SidebarCollapse.relocate(from: renamed, to: second, defaults: defaults)
    checkEqual(SidebarCollapse.load(folder: second, defaults: defaults), [folder], "folded rows follow a folder identity when it changes")
    checkEqual(SidebarCollapse.load(folder: renamed, defaults: defaults), [], "the previous folder identity no longer has them")
}

func lastNotebookChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "NoteCanvas.checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    check(LastNotebook.reopen(defaults: defaults) == nil, "nothing is restored when no notebook was open")

    let first = root.appendingPathComponent("A.notebook")
    let second = root.appendingPathComponent("B.notebook")
    _ = try! NotebookPackage.create(at: first, name: "A")
    _ = try! NotebookPackage.create(at: second, name: "B")
    LastNotebook.remember(first, defaults: defaults)
    LastNotebook.remember(second, defaults: defaults)
    checkEqual(LastNotebook.reopen(defaults: defaults)?.url.resolvingSymlinksInPath().standardizedFileURL,
               second.resolvingSymlinksInPath().standardizedFileURL,
               "the notebook left open is the one restored")

    let moved = root.appendingPathComponent("B2.notebook")
    try! FileManager.default.moveItem(at: second, to: moved)
    checkEqual(LastNotebook.reopen(defaults: defaults)?.url.resolvingSymlinksInPath().standardizedFileURL,
               moved.resolvingSymlinksInPath().standardizedFileURL,
               "a renamed notebook folder still opens")
    check(defaults.object(forKey: LastNotebook.defaultsKey) != nil, "a notebook that opens stays remembered")

    LastNotebook.forget(defaults: defaults)
    check(LastNotebook.reopen(defaults: defaults) == nil, "a closed notebook is not restored")

    LastNotebook.remember(moved, defaults: defaults)
    try! FileManager.default.removeItem(at: moved)
    check(LastNotebook.reopen(defaults: defaults) == nil, "a missing folder is not restored")
    check(defaults.object(forKey: LastNotebook.defaultsKey) == nil, "a missing folder clears the remembered location")
    check(LastNotebook.reopen(defaults: defaults) == nil, "a cleared location is not tried again")

    let future = root.appendingPathComponent("future.notebook")
    try! FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
    try! Data(#"{"version":99}"#.utf8).write(to: future.appendingPathComponent("notebook.json"))
    LastNotebook.remember(future, defaults: defaults)
    check(LastNotebook.reopen(defaults: defaults) == nil, "a wrong version is not restored")
    check(defaults.object(forKey: LastNotebook.defaultsKey) == nil, "a wrong version clears the remembered location")

    let plain = root.appendingPathComponent("plain")
    try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    LastNotebook.remember(plain, defaults: defaults)
    check(LastNotebook.reopen(defaults: defaults) == nil, "a folder that will not open is not restored")
    check(defaults.object(forKey: LastNotebook.defaultsKey) == nil, "a folder that will not open clears the remembered location")

    if getuid() != 0 {
        let locked = root.appendingPathComponent("locked.notebook")
        _ = try! NotebookPackage.create(at: locked, name: "L")
        LastNotebook.remember(locked, defaults: defaults)
        chmod(locked.path, 0)
        let restored = LastNotebook.reopen(defaults: defaults)
        chmod(locked.path, 0o755)
        check(restored == nil, "an unreadable folder is not restored")
        check(defaults.object(forKey: LastNotebook.defaultsKey) == nil, "an unreadable folder clears the remembered location")
    }
}
