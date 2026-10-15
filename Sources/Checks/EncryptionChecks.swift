import CryptoKit
import Foundation
import Store

private func hex(_ text: String) -> Data {
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        out.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return out
}

private func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private func rawBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

private func kind(_ name: String) -> NotebookCrypto.Kind {
    switch name {
    case "manifest": return .manifest
    case "page": return .page
    default: return .asset
    }
}

/// Checks the Swift code against docs/encryption-vectors.json (made by tools/make-vectors.py), then exercises the API.
func encryptionChecks() {
    let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/encryption-vectors.json")
    guard let data = try? Data(contentsOf: vectorsURL),
          let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        check(false, "the encryption test vectors could not be read at \(vectorsURL.path)")
        return
    }

    let notebookID = UUID(uuidString: v["notebookId"] as! String)!
    let notebookKeyBytes = hex(v["notebookKeyHex"] as! String)
    let notebookKey = SymmetricKey(data: notebookKeyBytes)

    // passphrase slot
    let ps = v["passphraseSlot"] as! [String: Any]
    let kdf = ps["kdf"] as! [String: Any]
    let salt = Data(base64Encoded: kdf["salt"] as! String)!
    let iterations = kdf["iterations"] as! Int
    let kek = try! NotebookCrypto.passphraseKEK(passphrase: ps["passphrase"] as! String, salt: salt, iterations: iterations)
    checkEqual(hexString(rawBytes(kek)), ps["kekHex"] as! String, "the passphrase KEK matches the vector")
    let passphraseSlot = KeySlot(
        type: "passphrase", id: ps["slotId"] as! String,
        kdf: .init(alg: kdf["alg"] as! String, iterations: iterations, salt: salt),
        nonce: Data(base64Encoded: ps["nonce"] as! String)!, wrappedKey: Data(base64Encoded: ps["wrappedKey"] as! String)!)

    // recovery slot
    let rs = v["recoverySlot"] as! [String: Any]
    let recoveryBytes = hex(rs["recoveryKeyHex"] as! String)
    checkEqual(NotebookCrypto.recoveryDisplay(recoveryBytes), rs["display"] as! String, "the recovery key text matches the vector")
    checkEqual(try? NotebookCrypto.recoveryParse((rs["display"] as! String).lowercased()), recoveryBytes,
               "a recovery key parses back from lower case")
    checkEqual(hexString(rawBytes(NotebookCrypto.recoveryKEK(recoveryBytes, notebookID: notebookID))), rs["kekHex"] as! String,
               "the recovery KEK matches the vector")
    let recoverySlot = KeySlot(
        type: "recovery", id: rs["slotId"] as! String, kdf: nil,
        nonce: Data(base64Encoded: rs["nonce"] as! String)!, wrappedKey: Data(base64Encoded: rs["wrappedKey"] as! String)!)

    let keys = KeysFile(notebookId: v["notebookId"] as! String, slots: [passphraseSlot, recoverySlot])
    checkEqual((try? NotebookCrypto.unlock(keys, passphrase: ps["passphrase"] as! String)).map(rawBytes), notebookKeyBytes,
               "the vector passphrase unlocks the vector notebook key")
    checkEqual((try? NotebookCrypto.unlock(keys, recoveryKey: rs["display"] as! String)).map(rawBytes), notebookKeyBytes,
               "the vector recovery key unlocks the vector notebook key")
    checkEqual(checkThrows("wrong passphrase") { try NotebookCrypto.unlock(keys, passphrase: "not the right passphrase") } as? CryptoError,
               .noMatchingSlot, "a wrong passphrase is refused")

    // objects: decrypt, and re-encrypt with the vector's own salt and nonce to get the same bytes
    var firstPage: (blob: Data, path: String, plain: Data)?
    for object in v["objects"] as! [[String: Any]] {
        let name = object["kind"] as! String
        let path = object["logicalPath"] as! String
        let blob = hex(object["objectHex"] as! String)
        let plain = (object["plaintextUtf8"] as? String).map { Data($0.utf8) } ?? hex(object["plaintextHex"] as! String)
        checkEqual(try? NotebookCrypto.open(blob, kind: kind(name), logicalPath: path, notebookID: notebookID, notebookKey: notebookKey),
                   plain, "\(name) vector decrypts")
        let again = try? NotebookCrypto.seal(plain, kind: kind(name), logicalPath: path, notebookID: notebookID, notebookKey: notebookKey,
                                             salt: blob.subdata(in: 7..<23), nonce: blob.subdata(in: 23..<35))
        checkEqual(again, blob, "\(name) vector re-encrypts to the same bytes")
        if name == "page" { firstPage = (blob, path, plain) }
    }

    // the cases a reader must refuse
    if let page = firstPage {
        var flipped = page.blob
        flipped[flipped.count - 1] ^= 1
        var otherKind = page.blob
        otherKind[6] = NotebookCrypto.Kind.asset.rawValue
        let refused: [(String, () throws -> Data)] = [
            ("another logical path", { try NotebookCrypto.open(page.blob, kind: .page, logicalPath: "pages/other.json", notebookID: notebookID, notebookKey: notebookKey) }),
            ("another notebook", { try NotebookCrypto.open(page.blob, kind: .page, logicalPath: page.path, notebookID: UUID(), notebookKey: notebookKey) }),
            ("a flipped ciphertext bit", { try NotebookCrypto.open(flipped, kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey) }),
            ("a changed kind byte", { try NotebookCrypto.open(otherKind, kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey) }),
            ("a truncated object", { try NotebookCrypto.open(page.blob.prefix(40), kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey) }),
            ("the wrong expected kind", { try NotebookCrypto.open(page.blob, kind: .asset, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey) }),
        ]
        for (label, attempt) in refused { checkThrows("an object under \(label)", { try attempt() }) }
        checkEqual((v["mustReject"] as! [String]).count, 4, "the vectors list four cases to refuse")

        // a blob that is a slice of a bigger buffer still opens
        let padded = Data([9, 9]) + page.blob
        checkEqual(try? NotebookCrypto.open(padded.dropFirst(2), kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey),
                   page.plain, "a slice with a non-zero start index decrypts")
    }

    // API round trips (a low iteration count keeps this quick; the vectors cover the default)
    let passphrase = "a perfectly long passphrase"
    let fresh = try! NotebookCrypto.createKeys(passphrase: passphrase, iterations: 100_000)
    checkEqual(fresh.keysFile.slots.map(\.type), ["passphrase", "recovery"], "a new notebook has a passphrase slot and a recovery slot")
    checkEqual(fresh.recoveryKey.count, 14 * 4 + 13, "the recovery key is 14 groups of four")
    checkEqual((try? NotebookCrypto.unlock(fresh.keysFile, passphrase: passphrase)).map(rawBytes), rawBytes(fresh.notebookKey),
               "a new notebook unlocks with its passphrase")
    checkEqual((try? NotebookCrypto.unlock(fresh.keysFile, recoveryKey: fresh.recoveryKey)).map(rawBytes), rawBytes(fresh.notebookKey),
               "a new notebook unlocks with its recovery key")
    let reread = try! KeysFile.decode(try! fresh.keysFile.encoded())
    checkEqual(reread, fresh.keysFile, "keys.json survives a write and read")
    check(fresh.keysFile.notebookId == fresh.keysFile.notebookId.lowercased(), "keys.json ids are lower case")
    checkEqual(checkThrows("short passphrase") { try NotebookCrypto.createKeys(passphrase: "short") } as? CryptoError,
               .passphraseTooShort, "a short passphrase is refused")
    var typo = fresh.recoveryKey
    let lastCharacter = typo.removeLast()
    typo.append(lastCharacter == "A" ? "B" : "A")
    checkEqual(checkThrows("mistyped recovery key") { try NotebookCrypto.unlock(fresh.keysFile, recoveryKey: typo) } as? CryptoError,
               .badRecoveryKey, "a mistyped recovery key is refused by its check value")

    let changed = try! NotebookCrypto.changePassphrase(fresh.keysFile, notebookKey: fresh.notebookKey,
                                                      newPassphrase: "another long passphrase", iterations: 100_000)
    checkEqual((try? NotebookCrypto.unlock(changed, passphrase: "another long passphrase")).map(rawBytes), rawBytes(fresh.notebookKey),
               "the new passphrase unlocks the same notebook key")
    checkEqual(checkThrows("old passphrase") { try NotebookCrypto.unlock(changed, passphrase: passphrase) } as? CryptoError,
               .noMatchingSlot, "the old passphrase stops working")
    checkEqual((try? NotebookCrypto.unlock(changed, recoveryKey: fresh.recoveryKey)).map(rawBytes), rawBytes(fresh.notebookKey),
               "the recovery key still works after a passphrase change")

    var tooCheap = fresh.keysFile
    tooCheap.slots[0].kdf?.iterations = 10
    checkEqual(checkThrows("weak kdf") { try NotebookCrypto.unlock(tooCheap, passphrase: passphrase) } as? CryptoError,
               .badKDF, "a slot with too few iterations is refused")

    let id = fresh.keysFile.notebookUUID!
    let one = try! NotebookCrypto.seal(Data("hello".utf8), kind: .page, logicalPath: "pages/x.json", notebookID: id, notebookKey: fresh.notebookKey)
    let two = try! NotebookCrypto.seal(Data("hello".utf8), kind: .page, logicalPath: "pages/x.json", notebookID: id, notebookKey: fresh.notebookKey)
    check(one != two, "two saves of the same page differ (fresh salt and nonce)")
    checkEqual(try? NotebookCrypto.open(one, kind: .page, logicalPath: "pages/x.json", notebookID: id, notebookKey: fresh.notebookKey),
               Data("hello".utf8), "a saved page opens")
    check(one.range(of: Data("hello".utf8)) == nil, "the plaintext is not visible in the object")
}

private func diskContains(_ needle: String, in root: URL) -> Bool {
    let bytes = Data(needle.utf8)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return true }
    for case let file as URL in walker {
        if let data = try? Data(contentsOf: file), data.range(of: bytes) != nil { return true }
    }
    return false
}

private func storedNames(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// Encrypted notebooks on disk: creating, reopening, tampering, converting and changing the passphrase.
func encryptedNotebookChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-enc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let passphrase = "a long passphrase here"
    let rounds = 100_000

    // create
    let url = root.appendingPathComponent("E.notebook")
    let created = try! NotebookPackage.createEncrypted(at: url, name: "E", passphrase: passphrase, iterations: rounds)
    var pkg = created.package
    let recovery = created.recoveryKey
    check(pkg.isEncrypted, "a new encrypted notebook reports itself encrypted")
    checkEqual(storedNames(url), ["keys.json", "notebook.nce", "pages"], "a new encrypted notebook has only keys.json, notebook.nce and pages")
    check(NotebookPackage.isEncrypted(at: url), "keys.json marks the folder as encrypted")
    checkEqual(checkThrows("create over existing") { try NotebookPackage.createEncrypted(at: url, name: "x", passphrase: passphrase, iterations: rounds) } as? StoreError,
               .alreadyExists, "creating over an existing folder is refused")

    // pages, assets and the manifest never reach disk in the clear
    var page = try! pkg.addPage(title: "Secret Title")
    page.title = "Renamed Secret"
    try! pkg.savePage(page)
    checkEqual(try! pkg.loadPage(page.id), page, "an encrypted page loads back identically")
    let assetName = try! pkg.addAsset(data: Data("PNGBYTES-secret-picture".utf8), ext: "png")
    checkEqual(pkg.loadAsset(assetName), Data("PNGBYTES-secret-picture".utf8), "an encrypted asset loads back")
    check(!diskContains("Secret", in: url), "no title appears in clear on disk")
    check(!diskContains("secret-picture", in: url), "no asset bytes appear in clear on disk")
    check(!diskContains("Section 1", in: url), "no section name appears in clear on disk")
    check(storedNames(url.appendingPathComponent("assets")).allSatisfy { $0.hasSuffix(".nce") && !$0.contains(".png") },
          "an encrypted asset hides its file type in the stored name")
    check(storedNames(url.appendingPathComponent("pages")).allSatisfy { $0.hasSuffix(".nce") }, "encrypted pages are stored as .nce")
    check(pkg.notebook.revision >= 2, "every manifest write counts in revision")

    // reopen
    checkEqual(checkThrows("open without key") { try NotebookPackage.open(at: url) } as? StoreError,
               .encrypted, "an encrypted notebook cannot be opened without a key")
    let keys = try! NotebookPackage.keysFile(at: url)
    let key = try! NotebookCrypto.unlock(keys, passphrase: passphrase)
    let reopened = try! NotebookPackage.open(at: url, notebookKey: key)
    checkEqual(reopened.notebook, pkg.notebook, "an encrypted notebook reopens with its key")
    checkEqual(try! reopened.loadPage(page.id), page, "a page loads after reopening")
    let viaRecovery = try! NotebookCrypto.unlock(keys, recoveryKey: recovery)
    check((try? NotebookPackage.open(at: url, notebookKey: viaRecovery)) != nil, "the recovery key opens the notebook")
    checkEqual(checkThrows("wrong key") { try NotebookPackage.open(at: url, notebookKey: SymmetricKey(size: .bits256)) } as? StoreError,
               .wrongKey, "a wrong key is refused")

    // tampering
    let pageFile = url.appendingPathComponent("pages/\(page.id.uuidString.lowercased()).nce")
    var bytes = try! Data(contentsOf: pageFile)
    let good = bytes
    bytes[bytes.count - 1] ^= 1
    try! bytes.write(to: pageFile)
    checkEqual(checkThrows("tampered page") { try reopened.loadPage(page.id) } as? StoreError,
               .corruptPage(page.id), "a changed page file is refused")
    try! good.write(to: pageFile)
    let moved = url.appendingPathComponent("pages/\(UUID().uuidString.lowercased()).nce")
    try! good.write(to: moved)
    let stolen = UUID(uuidString: moved.deletingPathExtension().lastPathComponent)!
    checkEqual(checkThrows("copied page") { try reopened.loadPage(stolen) } as? StoreError,
               .corruptPage(stolen), "a page file copied under another name is refused")
    try! FileManager.default.removeItem(at: pageFile)
    checkEqual(checkThrows("missing page") { try reopened.loadPage(page.id) } as? StoreError,
               .missingPage(page.id), "a deleted page file reports missingPage")

    // change the passphrase
    try! pkg.changePassphrase(to: "a different long passphrase", iterations: rounds)
    let changedKeys = try! NotebookPackage.keysFile(at: url)
    check((try? NotebookCrypto.unlock(changedKeys, passphrase: "a different long passphrase")) != nil, "the new passphrase unlocks the notebook")
    check((try? NotebookCrypto.unlock(changedKeys, passphrase: passphrase)) == nil, "the old passphrase no longer unlocks it")
    check((try? NotebookCrypto.unlock(changedKeys, recoveryKey: recovery)) != nil, "the recovery key still unlocks it")

    // convert an unencrypted notebook
    let plainURL = root.appendingPathComponent("P.notebook")
    var plain = try! NotebookPackage.create(at: plainURL, name: "P")
    let folder = try! plain.addFolder(named: "Private Folder", section: 0, inFolder: nil)
    var one = try! plain.addPage(title: "Confidential One", section: 0, inFolder: folder)
    one.title = "Confidential One"
    try! plain.savePage(one)
    let two = try! plain.addPage(title: "Confidential Two")
    let plainAsset = try! plain.addAsset(data: Data("ASSET-confidential".utf8), ext: "jpg")
    let before = plain.notebook
    check(diskContains("Confidential", in: plainURL), "the unencrypted notebook is readable on disk")

    let recoveryKey = try! plain.encrypt(passphrase: passphrase, iterations: rounds)
    check(plain.isEncrypted, "a converted notebook reports itself encrypted")
    checkEqual(recoveryKey.count, 69, "conversion returns a recovery key")
    checkEqual(plain.notebook.sections, before.sections, "conversion keeps every section, folder and page")
    checkEqual(try! plain.loadPage(one.id), one, "a converted page loads")
    checkEqual(try! plain.loadPage(two.id), two, "a second converted page loads")
    checkEqual(plain.loadAsset(plainAsset), Data("ASSET-confidential".utf8), "a converted asset loads")
    check(!plain.plaintextLeftovers().isEmpty, "the unencrypted copies are still there until they are removed")
    let reopenedPlain = try! NotebookPackage.open(at: plainURL, notebookKey: try! NotebookCrypto.unlock(try! NotebookPackage.keysFile(at: plainURL), passphrase: passphrase))
    checkEqual(reopenedPlain.notebook, plain.notebook, "a converted notebook reopens")
    if (try? plain.trashPlaintextLeftovers()) != nil {
        check(plain.plaintextLeftovers().isEmpty, "removing the unencrypted copies leaves none")
        check(!diskContains("Confidential", in: plainURL), "nothing readable is left once the unencrypted copies are gone")
        checkEqual(try! plain.loadPage(one.id), one, "the converted notebook still reads after cleanup")
    }
    checkEqual(checkThrows("convert twice") { try plain.encrypt(passphrase: passphrase, iterations: rounds) } as? StoreError,
               .alreadyEncrypted, "an encrypted notebook cannot be converted again")
}

/// A notebook folder that is moved while open can be followed with `relocate(to:)`.
func relocationChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-move-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let from = root.appendingPathComponent("A.notebook")
    let to = root.appendingPathComponent("Nextcloud-B.notebook")
    var pkg = try! NotebookPackage.create(at: from, name: "A")
    var page = try! pkg.addPage(title: "Before")
    try! FileManager.default.moveItem(at: from, to: to)
    check(checkThrows("save into a moved folder") { try pkg.savePage(page) } != nil, "saving into a folder that has moved fails")
    pkg.relocate(to: to)
    page.title = "After"
    try! pkg.savePage(page)
    checkEqual(try! NotebookPackage.open(at: to).notebook.sections[0].pages.map(\.title), ["After"], "saving works again after relocating")
}

/// Checks the locked-section code against docs/encryption-section-vectors.json (made by tools/make-section-vectors.py).
func sectionVectorChecks() {
    let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/encryption-section-vectors.json")
    guard let data = try? Data(contentsOf: vectorsURL),
          let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        check(false, "the section test vectors could not be read at \(vectorsURL.path)")
        return
    }
    let notebookText = v["notebookId"] as! String
    let sectionText = v["sectionId"] as! String
    let notebookID = UUID(uuidString: notebookText)!
    let sectionID = UUID(uuidString: sectionText)!
    let otherSection = UUID(uuidString: v["otherSectionId"] as! String)!
    let notebookKey = SymmetricKey(data: hex(v["notebookKeyHex"] as! String))
    let sectionKeyBytes = hex(v["sectionKeyHex"] as! String)
    let sectionKey = SymmetricKey(data: sectionKeyBytes)

    // slots
    let ps = v["passphraseSlot"] as! [String: Any]
    let kdf = ps["kdf"] as! [String: Any]
    let salt = Data(base64Encoded: kdf["salt"] as! String)!
    let kek = try! NotebookCrypto.passphraseKEK(passphrase: ps["passphrase"] as! String, salt: salt, iterations: kdf["iterations"] as! Int)
    checkEqual(hexString(rawBytes(kek)), ps["kekHex"] as! String, "the section passphrase KEK matches the vector")
    let passphraseSlot = KeySlot(type: "passphrase", id: ps["slotId"] as! String,
                                 kdf: .init(alg: kdf["alg"] as! String, iterations: kdf["iterations"] as! Int, salt: salt),
                                 nonce: Data(base64Encoded: ps["nonce"] as! String)!,
                                 wrappedKey: Data(base64Encoded: ps["wrappedKey"] as! String)!)
    let rs = v["recoverySlot"] as! [String: Any]
    let recoveryBytes = hex(rs["recoveryKeyHex"] as! String)
    let recoverySlot = KeySlot(type: "recovery", id: rs["slotId"] as! String, kdf: nil,
                               nonce: Data(base64Encoded: rs["nonce"] as! String)!,
                               wrappedKey: Data(base64Encoded: rs["wrappedKey"] as! String)!)
    let kekRecovery = SectionCrypto.recoveryKEK(recoveryBytes, notebookID: notebookID, sectionID: sectionID)
    checkEqual(hexString(rawBytes(kekRecovery)), rs["kekHex"] as! String, "the section recovery KEK matches the vector")
    let file = SectionKeysFile(notebookId: notebookText, sectionId: sectionText, slots: [passphraseSlot, recoverySlot])
    checkEqual((try? SectionCrypto.unlock(file, passphrase: ps["passphrase"] as! String)).map(rawBytes), sectionKeyBytes,
               "the vector passphrase unlocks the Section Key")
    checkEqual((try? SectionCrypto.unlock(file, recoveryKey: (rs["display"] as! String).lowercased())).map(rawBytes), sectionKeyBytes,
               "the vector recovery key unlocks the Section Key")
    checkEqual(checkThrows("a notebook recovery parser given a section recovery key") {
        try NotebookCrypto.recoveryParse(rs["display"] as! String)
    } as? CryptoError, .badRecoveryKey, "a section recovery key is refused as a notebook recovery key")
    checkEqual(checkThrows("wrong section passphrase") { try SectionCrypto.unlock(file, passphrase: "not the right passphrase") } as? CryptoError,
               .noMatchingSlot, "a wrong section passphrase is refused")
    let reread = try! SectionKeysFile.decode(try! file.encoded())
    checkEqual(reread, file, "a section keys file survives a write and read")

    // objects
    func sectionKind(_ name: String) -> SectionCrypto.Kind {
        switch name {
        case "section": return .section
        case "page": return .page
        default: return .asset
        }
    }
    var page: (path: String, blob: Data, plain: Data)?
    for o in v["objects"] as! [[String: Any]] {
        let kind = sectionKind(o["kind"] as! String)
        let path = o["logicalPath"] as! String
        let blob = hex(o["objectHex"] as! String)
        let expected = (o["plaintextUtf8"] as? String).map { Data($0.utf8) } ?? hex(o["plaintextHex"] as! String)
        let opened = try? SectionCrypto.open(blob, kind: kind, logicalPath: path, notebookID: notebookID, sectionID: sectionID, sectionKey: sectionKey)
        checkEqual(opened, expected, "the \(o["kind"] as! String) vector decrypts")
        let sealed = try? SectionCrypto.seal(expected, kind: kind, logicalPath: path, notebookID: notebookID, sectionID: sectionID,
                                             sectionKey: sectionKey, salt: blob.subdata(in: 7..<23), nonce: blob.subdata(in: 23..<35))
        checkEqual(sealed, blob, "sealing the \(o["kind"] as! String) with the vector salt and nonce reproduces it")
        check(SectionCrypto.isSectionObject(blob), "the \(o["kind"] as! String) vector is recognised as a section object")
        if kind == .page { page = (path, blob, expected) }
    }
    guard let page else { check(false, "the section vectors hold a page"); return }

    // objects that must be refused
    var flipped = page.blob
    flipped[flipped.count - 1] ^= 1
    var otherKind = page.blob
    otherKind[6] = SectionCrypto.Kind.asset.rawValue
    let scoped = v["notebookScopePage"] as! [String: Any]
    let notebookScopeBlob = hex(scoped["objectHex"] as! String)
    var versionOne = page.blob
    versionOne[4] = 1
    func openSection(_ blob: Data, id: UUID = sectionID, path: String? = nil, notebook: UUID = notebookID,
                     key: SymmetricKey = sectionKey) throws -> Data {
        try SectionCrypto.open(blob, kind: .page, logicalPath: path ?? page.path, notebookID: notebook, sectionID: id, sectionKey: key)
    }
    let refused: [(String, () throws -> Data)] = [
        ("another section id", { try openSection(page.blob, id: otherSection) }),
        ("another logical path", { try openSection(page.blob, path: "pages/aaaaaaaa-0000-4000-8000-000000000012.json") }),
        ("another notebook", { try openSection(page.blob, notebook: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) }),
        ("a flipped ciphertext bit", { try openSection(flipped) }),
        ("a changed kind byte", { try openSection(otherKind) }),
        ("the Notebook Key", { try openSection(page.blob, key: notebookKey) }),
        ("a notebook scope object read as a section object", { try openSection(notebookScopeBlob) }),
        ("a section object read as a notebook scope object", {
            try NotebookCrypto.open(page.blob, kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: notebookKey)
        }),
        ("a version byte changed from 2 to 1", {
            try NotebookCrypto.open(versionOne, kind: .page, logicalPath: page.path, notebookID: notebookID, notebookKey: sectionKey)
        }),
    ]
    for (label, attempt) in refused { checkThrows("a section object under \(label)", { try attempt() }) }
    checkEqual((v["mustReject"] as! [String]).count, refused.count, "the section vectors list every case the checks refuse")
    check(!SectionCrypto.isSectionObject(notebookScopeBlob), "a notebook scope object is not a section object")

    // API round trips (a low iteration count keeps this quick)
    let made = try! SectionCrypto.createKeys(notebookID: notebookID, sectionID: sectionID, passphrase: "a perfectly long passphrase", iterations: 100_000)
    checkEqual(made.keysFile.slots.map(\.type), ["passphrase", "recovery"], "a locked section has a passphrase slot and a recovery slot")
    checkEqual(made.recoveryKey.count, 14 * 4 + 13, "the section recovery key is 14 groups of four")
    checkEqual((try? SectionCrypto.unlock(made.keysFile, passphrase: "a perfectly long passphrase")).map(rawBytes), rawBytes(made.sectionKey),
               "a new section unlocks with its passphrase")
    checkEqual((try? SectionCrypto.unlock(made.keysFile, recoveryKey: made.recoveryKey)).map(rawBytes), rawBytes(made.sectionKey),
               "a new section unlocks with its recovery key")
    checkEqual(checkThrows("short section passphrase") {
        try SectionCrypto.createKeys(notebookID: notebookID, sectionID: sectionID, passphrase: "short")
    } as? CryptoError, .passphraseTooShort, "a short section passphrase is refused")
    let notebookKeys = try! NotebookCrypto.createKeys(passphrase: "a perfectly long passphrase", iterations: 100_000)
    checkEqual(checkThrows("section recovery key on a notebook") {
        try NotebookCrypto.unlock(notebookKeys.keysFile, recoveryKey: made.recoveryKey)
    } as? CryptoError, .badRecoveryKey, "a section recovery key does not open a notebook")
    checkEqual(checkThrows("notebook recovery key on a section") {
        try SectionCrypto.unlock(made.keysFile, recoveryKey: notebookKeys.recoveryKey)
    } as? CryptoError, .badRecoveryKey, "a notebook recovery key does not open a section")
    let changed = try! SectionCrypto.changePassphrase(made.keysFile, sectionKey: made.sectionKey, newPassphrase: "another long passphrase", iterations: 100_000)
    checkEqual((try? SectionCrypto.unlock(changed, passphrase: "another long passphrase")).map(rawBytes), rawBytes(made.sectionKey),
               "the new section passphrase unlocks the same key")
    check((try? SectionCrypto.unlock(changed, passphrase: "a perfectly long passphrase")) == nil, "the old section passphrase stops working")
    checkEqual((try? SectionCrypto.unlock(changed, recoveryKey: made.recoveryKey)).map(rawBytes), rawBytes(made.sectionKey),
               "the recovery key still works after a passphrase change")
}
