import Foundation
import PageModel
import Store

/// Moving and copying sections, folders and pages, inside a notebook and between notebooks.
func transferChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nc-transfer-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func titles(_ section: Section) -> [String] { section.pages.map(\.title) }

    var source = try! NotebookPackage.create(at: root.appendingPathComponent("S.notebook"), name: "S")
    let sectionA = source.notebook.sections[0].id
    let folder = try! source.addFolder(named: "Folder", section: 0, inFolder: nil)
    try! source.setFolderColor(folder, section: 0, to: "#3D7048")
    var first = try! source.addPage(title: "P1", section: 0, inFolder: folder)
    let imageBytes = Data("transfer image".utf8)
    let imageName = try! source.addAsset(data: imageBytes, ext: "png", forPage: first.id)
    first.objects = [.image(ImageObject(id: UUID(), frame: Frame(x: 0, y: 0, width: 10, height: 10), asset: imageName))]
    try! source.savePage(first)
    let second = try! source.addPage(title: "P2", section: 0, inFolder: nil)
    let sectionB = try! source.addEmptySection(name: "B")

    // copy a section into another notebook
    var dest = try! NotebookPackage.create(at: root.appendingPathComponent("D.notebook"), name: "D")
    let copied = try! NotebookPackage.copySection(sectionA, of: source, into: &dest)
    checkEqual(copied.pages, 2, "a copied section reports its pages")
    checkEqual(copied.folders, 1, "a copied section reports its folders")
    checkEqual(dest.notebook.sections.count, 2, "the copy is a new section in the destination")
    let newSection = dest.notebook.sections[1]
    checkEqual(newSection.name, source.notebook.sections[0].name, "the copied section keeps its name")
    checkEqual(Set(titles(newSection)), Set(["P1", "P2"]), "the copied section has the same pages")
    check(newSection.pages.allSatisfy { $0.id != first.id && $0.id != second.id }, "copied pages get fresh ids")
    checkEqual(newSection.folder(newSection.items.compactMap { item -> UUID? in
        if case .folder(let f) = item { return f.id } else { return nil } }.first ?? UUID())?.colorHex, "#3D7048",
               "a copied folder keeps its colour")
    let copiedFirst = try! dest.loadPage(newSection.pages.first { $0.title == "P1" }!.id)
    checkEqual(copiedFirst.assetNames.count, 1, "the copied page still has its image")
    check(copiedFirst.assetNames.first != imageName, "the image is stored under a new name")
    checkEqual(dest.loadAsset(copiedFirst.assetNames.first ?? ""), imageBytes, "the image bytes arrive unchanged")
    checkEqual(source.notebook.sections.count, 2, "copying leaves the source alone")
    check(source.loadAsset(imageName) != nil, "the source image is still there after a copy")

    // copy a folder into a section of another notebook, encrypted
    var locked = try! NotebookPackage.createEncrypted(at: root.appendingPathComponent("E.notebook"), name: "E",
                                                      passphrase: "a passphrase long enough", iterations: 100_000).package
    let into = try! NotebookPackage.copyItems([folder], fromSection: 0, of: source, into: &locked, section: 0, inFolder: nil)
    checkEqual(into.pages, 1, "a folder copy counts its pages")
    let lockedPage = locked.notebook.sections[0].pages.first { $0.title == "P1" }
    check(lockedPage != nil, "the page arrived in the encrypted notebook")
    check(!fm.fileExists(atPath: root.appendingPathComponent("E.notebook/pages/\(lockedPage!.id.uuidString.lowercased()).json").path),
          "the copy is not stored as plain text")
    checkEqual(locked.loadAsset(try! locked.loadPage(lockedPage!.id).assetNames.first ?? ""), imageBytes,
               "the image in the encrypted notebook reads back")

    // reorder sections
    check(try! source.moveSection(sectionA, to: 2), "a section can be dropped after the last one")
    checkEqual(source.notebook.sections.map(\.id), [sectionB.id, sectionA], "the order changes")
    check(!(try! source.moveSection(sectionB.id, to: 0)), "dropping a section where it already is changes nothing")
    _ = try! source.moveSection(sectionA, to: 0)

    // move between sections of one notebook
    let moved = try! source.relocate(second.id, fromSection: 0, toSection: 1, inFolder: nil)
    checkEqual(moved.pages, 1, "a relocated page is counted")
    checkEqual(titles(source.notebook.sections[0]), ["P1"], "the page leaves its old section")
    checkEqual(titles(source.notebook.sections[1]), ["P2"], "the page arrives in the new section")
    check((try? source.loadPage(moved.topLevelIDs[0])) != nil, "the moved page can be opened")

    // fold one section into another
    let before = source.notebook.sections.first { $0.id == sectionA }!.items.count
    let folded = try! source.mergeSection(sectionB.id, into: sectionA)
    checkEqual(source.notebook.sections.count, 1, "the folded section is gone")
    let host = source.notebook.sections[0]
    checkEqual(host.items.count, before + 1, "the section arrives as one folder")
    checkEqual(host.folder(folded.topLevelIDs[0])?.name, sectionB.name, "the folder carries the section's name")
    check(host.pages.contains { $0.title == "P2" }, "its pages arrive inside")
    check((try? source.loadPage(host.pages.first { $0.title == "P2" }!.id)) != nil, "a folded page can be opened")
    check((try? source.mergeSection(sectionA, into: sectionA)) == nil, "a section cannot be folded into itself")

    // delete a folder with its pages
    try! source.deleteItem(folder, section: 0)
    checkEqual(source.notebook.sections[0].items.count, 0, "deleting a folder removes it and its pages")
}
