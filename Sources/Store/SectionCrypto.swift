import CryptoKit
import Foundation

/// The cleartext `sections/<id>.keys.json` of a locked section. See docs/encryption-locked-sections.md.
public struct SectionKeysFile: Codable, Equatable {
    public static let formatName = "notecanvas-locked-section"
    public var format: String
    public var version: Int
    public var notebookId: String
    public var sectionId: String
    public var slots: [KeySlot]

    public init(format: String = SectionKeysFile.formatName, version: Int = 2, notebookId: String, sectionId: String, slots: [KeySlot]) {
        self.format = format; self.version = version; self.notebookId = notebookId; self.sectionId = sectionId; self.slots = slots
    }

    public var notebookUUID: UUID? { UUID(uuidString: notebookId) }
    public var sectionUUID: UUID? { UUID(uuidString: sectionId) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SectionKeysFile {
        guard let file = try? JSONDecoder().decode(SectionKeysFile.self, from: data), file.format == formatName else {
            throw CryptoError.badObject
        }
        guard file.version == 2 else { throw CryptoError.unsupportedVersion(file.version) }
        return file
    }
}

public struct NewSectionKeys {
    public var keysFile: SectionKeysFile
    public var sectionKey: SymmetricKey
    /// Shown to the user once, when the section is locked.
    public var recoveryKey: String
}

/// Locked sections, format version 2. Written from docs/encryption-locked-sections.md and checked against
/// docs/encryption-section-vectors.json.
public enum SectionCrypto {
    public enum Kind: UInt8 { case page = 2, asset = 3, section = 4 }

    private static let magic = Data("NCE1".utf8)
    private static let formatVersion: UInt8 = 2
    private static let headerSize = 35
    private static let tagSize = 16
    private static let infoObject = Data("notecanvas/v2/section-object".utf8)
    private static let infoRecovery = Data("notecanvas/v2/section-recovery-kek".utf8)
    private static let aadSlot = Data("notecanvas/v2/section-keyslot".utf8)
    private static let checkPrefix = Data("notecanvas/v2/section-recovery-check".utf8)

    /// True when the file is encrypted under a Section Key (header version 2), whoever it belongs to.
    public static func isSectionObject(_ blob: Data) -> Bool {
        let data = Data(blob)
        return data.count > 4 && data.prefix(4) == magic && data[4] == formatVersion
    }

    // MARK: objects

    public static func seal(_ plaintext: Data, kind: Kind, logicalPath: String, notebookID: UUID, sectionID: UUID,
                            sectionKey: SymmetricKey) throws -> Data {
        try seal(plaintext, kind: kind, logicalPath: logicalPath, notebookID: notebookID, sectionID: sectionID,
                 sectionKey: sectionKey, salt: NotebookCrypto.randomBytes(16), nonce: NotebookCrypto.randomBytes(12))
    }

    /// Fixed salt and nonce, for the published test vectors only.
    public static func seal(_ plaintext: Data, kind: Kind, logicalPath: String, notebookID: UUID, sectionID: UUID,
                            sectionKey: SymmetricKey, salt: Data, nonce: Data) throws -> Data {
        var header = Data(magic)
        header.append(formatVersion)
        header.append(0)
        header.append(kind.rawValue)
        header.append(salt)
        header.append(nonce)
        let box = try AES.GCM.seal(plaintext, using: objectKey(sectionKey, salt: salt), nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: objectAAD(header, notebookID, sectionID, logicalPath))
        return header + box.ciphertext + box.tag
    }

    public static func open(_ blob: Data, kind: Kind, logicalPath: String, notebookID: UUID, sectionID: UUID,
                            sectionKey: SymmetricKey) throws -> Data {
        let data = Data(blob)
        guard data.count >= headerSize + tagSize, data.prefix(4) == magic else { throw CryptoError.badObject }
        guard data[4] == formatVersion else { throw CryptoError.unsupportedVersion(Int(data[4])) }
        guard data[5] == 0, data[6] == kind.rawValue else { throw CryptoError.badObject }
        let header = data.subdata(in: 0..<headerSize)
        let salt = data.subdata(in: 7..<23)
        let nonce = data.subdata(in: 23..<35)
        let body = data.subdata(in: headerSize..<data.count)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: body.prefix(body.count - tagSize), tag: body.suffix(tagSize))
            return try AES.GCM.open(box, using: objectKey(sectionKey, salt: salt),
                                    authenticating: objectAAD(header, notebookID, sectionID, logicalPath))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    private static func objectKey(_ sectionKey: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: sectionKey, salt: salt, info: infoObject, outputByteCount: 32)
    }

    private static func objectAAD(_ header: Data, _ notebookID: UUID, _ sectionID: UUID, _ logicalPath: String) -> Data {
        header + NotebookCrypto.bytes(of: notebookID) + NotebookCrypto.bytes(of: sectionID) + Data(logicalPath.utf8)
    }

    // MARK: keys

    /// Makes the Section Key, a passphrase slot and a recovery slot.
    public static func createKeys(notebookID: UUID, sectionID: UUID, passphrase: String,
                                  iterations: Int = NotebookCrypto.defaultIterations) throws -> NewSectionKeys {
        let sectionKey = SymmetricKey(size: .bits256)
        let recovery = NotebookCrypto.randomBytes(32)
        let passphraseSlot = try makePassphraseSlot(passphrase: passphrase, iterations: iterations,
                                                    notebookID: notebookID, sectionID: sectionID, sectionKey: sectionKey)
        let slotID = UUID()
        let nonce = NotebookCrypto.randomBytes(12)
        let wrapped = try wrap(sectionKey, with: recoveryKEK(recovery, notebookID: notebookID, sectionID: sectionID),
                               nonce: nonce, notebookID: notebookID, sectionID: sectionID, slotID: slotID)
        let recoverySlot = KeySlot(type: "recovery", id: slotID.uuidString.lowercased(), kdf: nil, nonce: nonce, wrappedKey: wrapped)
        let file = SectionKeysFile(notebookId: notebookID.uuidString.lowercased(), sectionId: sectionID.uuidString.lowercased(),
                                   slots: [passphraseSlot, recoverySlot])
        return NewSectionKeys(keysFile: file, sectionKey: sectionKey,
                              recoveryKey: NotebookCrypto.recoveryDisplay(recovery, checkPrefix: checkPrefix))
    }

    public static func unlock(_ file: SectionKeysFile, passphrase: String) throws -> SymmetricKey {
        guard let notebookID = file.notebookUUID, let sectionID = file.sectionUUID else { throw CryptoError.badObject }
        var sawBadKDF = false
        var tried = false
        for slot in file.slots where slot.type == "passphrase" {
            guard let kdf = slot.kdf, kdf.alg == NotebookCrypto.pbkdf2Name, let slotID = UUID(uuidString: slot.id) else { continue }
            guard (NotebookCrypto.minimumIterations...NotebookCrypto.maximumIterations).contains(kdf.iterations) else {
                sawBadKDF = true
                continue
            }
            tried = true
            let kek = try NotebookCrypto.passphraseKEK(passphrase: passphrase, salt: kdf.salt, iterations: kdf.iterations)
            if let key = unwrap(slot, with: kek, notebookID: notebookID, sectionID: sectionID, slotID: slotID) { return key }
        }
        throw sawBadKDF && !tried ? CryptoError.badKDF : CryptoError.noMatchingSlot
    }

    public static func unlock(_ file: SectionKeysFile, recoveryKey text: String) throws -> SymmetricKey {
        guard let notebookID = file.notebookUUID, let sectionID = file.sectionUUID else { throw CryptoError.badObject }
        let recovery = try NotebookCrypto.recoveryParse(text, checkPrefix: checkPrefix)
        let kek = recoveryKEK(recovery, notebookID: notebookID, sectionID: sectionID)
        for slot in file.slots where slot.type == "recovery" {
            guard let slotID = UUID(uuidString: slot.id) else { continue }
            if let key = unwrap(slot, with: kek, notebookID: notebookID, sectionID: sectionID, slotID: slotID) { return key }
        }
        throw CryptoError.noMatchingSlot
    }

    /// Replaces the passphrase slot. Nothing else changes.
    public static func changePassphrase(_ file: SectionKeysFile, sectionKey: SymmetricKey, newPassphrase: String,
                                        iterations: Int = NotebookCrypto.defaultIterations) throws -> SectionKeysFile {
        guard let notebookID = file.notebookUUID, let sectionID = file.sectionUUID else { throw CryptoError.badObject }
        let slot = try makePassphraseSlot(passphrase: newPassphrase, iterations: iterations,
                                          notebookID: notebookID, sectionID: sectionID, sectionKey: sectionKey)
        var updated = file
        updated.slots = file.slots.filter { $0.type != "passphrase" } + [slot]
        return updated
    }

    public static func recoveryKEK(_ recoveryKey: Data, notebookID: UUID, sectionID: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey),
                               salt: NotebookCrypto.bytes(of: notebookID) + NotebookCrypto.bytes(of: sectionID),
                               info: infoRecovery, outputByteCount: 32)
    }

    private static func makePassphraseSlot(passphrase: String, iterations: Int, notebookID: UUID, sectionID: UUID,
                                           sectionKey: SymmetricKey) throws -> KeySlot {
        guard passphrase.count >= NotebookCrypto.minimumPassphraseLength else { throw CryptoError.passphraseTooShort }
        let salt = NotebookCrypto.randomBytes(16)
        let slotID = UUID()
        let nonce = NotebookCrypto.randomBytes(12)
        let kek = try NotebookCrypto.passphraseKEK(passphrase: passphrase, salt: salt, iterations: iterations)
        let wrapped = try wrap(sectionKey, with: kek, nonce: nonce, notebookID: notebookID, sectionID: sectionID, slotID: slotID)
        return KeySlot(type: "passphrase", id: slotID.uuidString.lowercased(),
                       kdf: .init(alg: NotebookCrypto.pbkdf2Name, iterations: iterations, salt: salt), nonce: nonce, wrappedKey: wrapped)
    }

    private static func slotAAD(_ notebookID: UUID, _ sectionID: UUID, _ slotID: UUID) -> Data {
        aadSlot + NotebookCrypto.bytes(of: notebookID) + NotebookCrypto.bytes(of: sectionID) + NotebookCrypto.bytes(of: slotID)
    }

    private static func wrap(_ sectionKey: SymmetricKey, with kek: SymmetricKey, nonce: Data, notebookID: UUID,
                             sectionID: UUID, slotID: UUID) throws -> Data {
        let plain = sectionKey.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(plain, using: kek, nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: slotAAD(notebookID, sectionID, slotID))
        return box.ciphertext + box.tag
    }

    private static func unwrap(_ slot: KeySlot, with kek: SymmetricKey, notebookID: UUID, sectionID: UUID, slotID: UUID) -> SymmetricKey? {
        let wrapped = Data(slot.wrappedKey)
        guard wrapped.count == 32 + tagSize, slot.nonce.count == 12,
              let nonce = try? AES.GCM.Nonce(data: slot.nonce),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: wrapped.prefix(32), tag: wrapped.suffix(tagSize)),
              let plain = try? AES.GCM.open(box, using: kek, authenticating: slotAAD(notebookID, sectionID, slotID)) else { return nil }
        return SymmetricKey(data: plain)
    }
}
