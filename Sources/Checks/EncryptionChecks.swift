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
