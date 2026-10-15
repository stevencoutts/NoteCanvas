import CryptoKit
import Foundation
import PageModel
import Store

/// Locked sections inside an encrypted notebook: what is on disk, what a holder of the Notebook Key can see, and the
/// operations (lock, unlock, edit, change passphrase, remove the lock, interrupted lock).
func lockedSectionChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nc-locked-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let sectionPassphrase = "a perfectly long passphrase"
    let notebookPassphrase = "the notebook passphrase here"

    func pageFile(_ url: URL, _ id: UUID) -> URL { url.appendingPathComponent("pages/\(id.uuidString.lowercased()).nce") }
    func assetStem(_ name: String) -> String { (name as NSString).deletingPathExtension }
    func isSectionFile(_ url: URL) -> Bool { SectionCrypto.isSectionObject((try? Data(contentsOf: url)) ?? Data()) }

    let notebookURL = root.appendingPathComponent("L.notebook")
    var pkg = try! NotebookPackage.createEncrypted(at: notebookURL, name: "L", passphrase: notebookPassphrase, iterations: 100_000).package
    let notebookKey = pkg.cipher!.key
    let openPage = try! pkg.addPage(title: "Open page")
    let secret = try! pkg.addEmptySection(name: "Secret")
    var hidden = try! pkg.addPage(title: "Hidden page", section: 1)
    let uniqueBytes = Data("unique image".utf8)
    let sharedBytes = Data("shared image".utf8)
    let uniqueName = try! pkg.addAsset(data: uniqueBytes, ext: "png")
    let sharedName = try! pkg.addAsset(data: sharedBytes, ext: "png")
    let frame = Frame(x: 0, y: 0, width: 10, height: 10)
    hidden.objects = [.image(ImageObject(id: UUID(), frame: frame, asset: uniqueName)),
                      .image(ImageObject(id: UUID(), frame: frame, asset: sharedName))]
    try! pkg.savePage(hidden)
    var shown = openPage
    shown.objects = [.image(ImageObject(id: UUID(), frame: frame, asset: sharedName))]
    try! pkg.savePage(shown)

    // lock
    let recovery = try! pkg.lockSection(secret.id, passphrase: sectionPassphrase, iterations: 100_000)
    check(pkg.isSectionLocked(secret.id) && pkg.isSectionUnlocked(secret.id), "a section is open straight after it is locked")
    checkEqual(recovery.count, 14 * 4 + 13, "locking returns a recovery key")
    checkEqual(try! NotebookPackage.keysFile(at: notebookURL).version, 2, "keys.json becomes version 2 with the first locked section")
    check(isSectionFile(pageFile(notebookURL, hidden.id)), "a locked page is stored under the Section Key")
    check(!isSectionFile(pageFile(notebookURL, openPage.id)), "a page outside the locked section stays under the Notebook Key")
    check(fm.fileExists(atPath: notebookURL.appendingPathComponent("sections/\(secret.id.uuidString.lowercased()).keys.json").path), "the section has its own keys file")
    check(fm.fileExists(atPath: notebookURL.appendingPathComponent("sections/\(secret.id.uuidString.lowercased()).nce").path), "the section has its own encrypted manifest")
    check(!fm.fileExists(atPath: notebookURL.appendingPathComponent("assets/\(assetStem(uniqueName)).nce").path),
          "the Notebook Key copy of an asset only the locked section used is removed")
    checkEqual(try? pkg.loadPage(hidden.id).title, "Hidden page", "the open locked section reads normally")

    // what the holder of the Notebook Key sees
    var again = try! NotebookPackage.open(at: notebookURL, notebookKey: notebookKey)
    check(again.notebook.sections[1].locked, "a locked section appears as a stand-in")
    checkEqual(again.notebook.sections[1].name, "Locked section", "the stand-in shows the label, not the real name")
    checkEqual(again.notebook.sections.flatMap(\.pages).map(\.title), ["Open page"], "no title of a locked page is visible")
    check(!again.isSectionUnlocked(secret.id), "a reopened locked section is closed")
    checkEqual(checkThrows("page of a locked section") { try again.loadPage(hidden.id) } as? StoreError,
               .sectionLocked(secret.id), "a locked page cannot be read")
    checkEqual(checkThrows("deleting a closed locked section") { try again.deleteSection(secret.id) } as? StoreError,
               .sectionLocked(secret.id), "a closed locked section cannot be deleted")
    check(again.loadAsset(uniqueName) == nil, "a locked section's asset cannot be read")
    checkEqual(again.loadAsset(sharedName), sharedBytes, "an asset another page still uses stays readable")

    // unlock
    checkEqual(checkThrows("wrong passphrase") { try again.unlockSection(secret.id, passphrase: "not the right passphrase") } as? CryptoError,
               .noMatchingSlot, "a wrong section passphrase is refused")
    try! again.unlockSection(secret.id, passphrase: sectionPassphrase)
    checkEqual(again.notebook.sections[1].name, "Secret", "unlocking shows the real name")
    let loaded = try! again.loadPage(hidden.id)
    checkEqual(loaded.objects.count, 2, "the locked page loads after unlocking")
    if case .image(let firstImage) = loaded.objects[0], case .image(let secondImage) = loaded.objects[1] {
        check(firstImage.asset != uniqueName, "locking copied the asset to a new name")
        checkEqual(again.loadAsset(firstImage.asset), uniqueBytes, "the copied asset reads under the Section Key")
        checkEqual(again.loadAsset(secondImage.asset), sharedBytes, "a shared asset is copied into the section too")
        check(secondImage.asset != sharedName, "the shared asset has its own copy in the section")
    } else {
        check(false, "the locked page keeps its two images")
    }
    var byRecovery = try! NotebookPackage.open(at: notebookURL, notebookKey: notebookKey)
    try! byRecovery.unlockSection(secret.id, recoveryKey: recovery)
    checkEqual(byRecovery.notebook.sections[1].name, "Secret", "the recovery key unlocks the section")

    // editing a locked section does not touch the notebook manifest
    let manifestFile = notebookURL.appendingPathComponent("notebook.nce")
    let manifestBefore = try! Data(contentsOf: manifestFile)
    let second = try! again.addPage(title: "Second hidden", section: 1)
    try! again.renameSection(secret.id, to: "Secret 2")
    checkEqual(try! Data(contentsOf: manifestFile), manifestBefore, "editing a locked section leaves notebook.nce alone")
    check(isSectionFile(pageFile(notebookURL, second.id)), "a page added to an open locked section goes under its key")
    var edited = try! NotebookPackage.open(at: notebookURL, notebookKey: notebookKey)
    try! edited.unlockSection(secret.id, passphrase: sectionPassphrase)
    checkEqual(edited.notebook.sections[1].name, "Secret 2", "a rename inside a locked section is kept")
    checkEqual(edited.notebook.sections[1].pages.map(\.title), ["Hidden page", "Second hidden"], "pages added to a locked section are kept")

    // change the section passphrase
    try! again.changeSectionPassphrase(secret.id, to: "brand new long passphrase", iterations: 100_000)
    var oldTry = try! NotebookPackage.open(at: notebookURL, notebookKey: notebookKey)
    checkEqual(checkThrows("old passphrase") { try oldTry.unlockSection(secret.id, passphrase: sectionPassphrase) } as? CryptoError,
               .noMatchingSlot, "the old section passphrase stops working")
    try! oldTry.unlockSection(secret.id, passphrase: "brand new long passphrase")
    check(oldTry.isSectionUnlocked(secret.id), "the new section passphrase works")

    // close it again
    again.lockSectionAgain(secret.id)
    check(!again.isSectionUnlocked(secret.id) && again.notebook.sections[1].locked, "a locked section can be closed again")

    // remove the lock
    try! oldTry.removeLock(from: secret.id)
    let plain = try! NotebookPackage.open(at: notebookURL, notebookKey: notebookKey)
    check(!plain.isSectionLocked(secret.id) && !plain.notebook.sections[1].locked, "the lock is gone")
    checkEqual(plain.notebook.sections[1].name, "Secret 2", "the real name is back in the notebook manifest")
    checkEqual(try? plain.loadPage(hidden.id).title, "Hidden page", "pages read under the Notebook Key again")
    check(!isSectionFile(pageFile(notebookURL, hidden.id)), "pages are back under the Notebook Key")
    check(!fm.fileExists(atPath: notebookURL.appendingPathComponent("sections/\(secret.id.uuidString.lowercased()).keys.json").path),
          "the section keys file is removed")
    if case .image(let back) = try! plain.loadPage(hidden.id).objects[0] {
        checkEqual(plain.loadAsset(back.asset), uniqueBytes, "assets read under the Notebook Key again")
    } else {
        check(false, "the unlocked page keeps its image")
    }

    // an interrupted lock: keys file, section manifest and one page already under the Section Key, manifest not yet marked
    let halfURL = root.appendingPathComponent("H.notebook")
    var half = try! NotebookPackage.createEncrypted(at: halfURL, name: "H", passphrase: notebookPassphrase, iterations: 100_000).package
    let halfPage = try! half.addPage(title: "Half locked")
    let sid = half.notebook.sections[0].id
    let cipher = half.cipher!
    let made = try! SectionCrypto.createKeys(notebookID: cipher.notebookID, sectionID: sid, passphrase: sectionPassphrase, iterations: 100_000)
    let sectionsDir = halfURL.appendingPathComponent("sections")
    try! fm.createDirectory(at: sectionsDir, withIntermediateDirectories: true)
    let lower = sid.uuidString.lowercased()
    try! made.keysFile.encoded().write(to: sectionsDir.appendingPathComponent("\(lower).keys.json"))
    let manifestJSON = try! JSONEncoder().encode(half.notebook.sections[0])
    try! SectionCrypto.seal(manifestJSON, kind: .section, logicalPath: "sections/\(lower).json", notebookID: cipher.notebookID,
                            sectionID: sid, sectionKey: made.sectionKey).write(to: sectionsDir.appendingPathComponent("\(lower).nce"))
    let halfJSON = try! JSONEncoder().encode(try! half.loadPage(halfPage.id))
    try! SectionCrypto.seal(halfJSON, kind: .page, logicalPath: "pages/\(halfPage.id.uuidString.lowercased()).json",
                            notebookID: cipher.notebookID, sectionID: sid, sectionKey: made.sectionKey).write(to: pageFile(halfURL, halfPage.id))
    var halfKeys = try! NotebookPackage.keysFile(at: halfURL)
    halfKeys.version = 2
    try! halfKeys.encoded().write(to: halfURL.appendingPathComponent("keys.json"))
    let rollbackURL = root.appendingPathComponent("R.notebook")
    try! fm.copyItem(at: halfURL, to: rollbackURL)

    var finishing = try! NotebookPackage.open(at: halfURL, notebookKey: cipher.key)
    checkEqual(finishing.interruptedLocks, [sid], "an interrupted lock is noticed on opening")
    checkEqual(checkThrows("page of an interrupted lock") { try finishing.loadPage(halfPage.id) } as? StoreError,
               .sectionLocked(sid), "a page under a Section Key in an unmarked section asks for the section passphrase")
    try! finishing.finishInterruptedLock(sid, passphrase: sectionPassphrase)
    check(finishing.isSectionLocked(sid) && finishing.interruptedLocks.isEmpty, "finishing marks the section locked")
    var finished = try! NotebookPackage.open(at: halfURL, notebookKey: cipher.key)
    check(finished.notebook.sections[0].locked, "the finished lock is on disk")
    try! finished.unlockSection(sid, passphrase: sectionPassphrase)
    checkEqual(try? finished.loadPage(halfPage.id).title, "Half locked", "a finished lock reads back")

    var rolling = try! NotebookPackage.open(at: rollbackURL, notebookKey: cipher.key)
    try! rolling.rollBackInterruptedLock(sid, passphrase: sectionPassphrase)
    check(!rolling.isSectionLocked(sid) && rolling.interruptedLocks.isEmpty, "rolling back leaves the section unlocked")
    checkEqual(try? rolling.loadPage(halfPage.id).title, "Half locked", "a rolled back page reads under the Notebook Key")
    check(!isSectionFile(pageFile(rollbackURL, halfPage.id)), "a rolled back page is under the Notebook Key")
    check(!fm.fileExists(atPath: rollbackURL.appendingPathComponent("sections/\(lower).keys.json").path), "rolling back removes the section keys file")
}
