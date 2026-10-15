import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable {
    case unsupportedVersion(Int)
    case badObject
    case authenticationFailed
    case noMatchingSlot
    case badRecoveryKey
    case badKDF
    case passphraseTooShort
}

/// One wrapped copy of the Notebook Key. See docs/encryption-spec.md.
public struct KeySlot: Codable, Equatable {
    public struct KDF: Codable, Equatable {
        public var alg: String
        public var iterations: Int
        public var salt: Data
        public init(alg: String, iterations: Int, salt: Data) { self.alg = alg; self.iterations = iterations; self.salt = salt }
    }

    public var type: String
    public var id: String
    public var kdf: KDF?
    public var nonce: Data
    public var wrappedKey: Data

    public init(type: String, id: String, kdf: KDF?, nonce: Data, wrappedKey: Data) {
        self.type = type; self.id = id; self.kdf = kdf; self.nonce = nonce; self.wrappedKey = wrappedKey
    }
}

/// The cleartext `keys.json` of an encrypted notebook. Ids are lowercase hyphenated text, as the spec says.
public struct KeysFile: Codable, Equatable {
    public static let formatName = "notecanvas-encrypted-notebook"
    public var format: String
    public var version: Int
    public var notebookId: String
    public var slots: [KeySlot]

    public init(format: String = KeysFile.formatName, version: Int = 1, notebookId: String, slots: [KeySlot]) {
        self.format = format; self.version = version; self.notebookId = notebookId; self.slots = slots
    }

    public var notebookUUID: UUID? { UUID(uuidString: notebookId) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> KeysFile {
        guard let file = try? JSONDecoder().decode(KeysFile.self, from: data), file.format == formatName else {
            throw CryptoError.badObject
        }
        // Version 2 means the notebook has locked sections (docs/encryption-locked-sections.md). The notebook key works the same.
        guard (1...2).contains(file.version) else { throw CryptoError.unsupportedVersion(file.version) }
        return file
    }
}

public struct NewNotebookKeys {
    public var keysFile: KeysFile
    public var notebookKey: SymmetricKey
    /// Shown to the user once, at creation.
    public var recoveryKey: String
}

/// Encrypted notebook format, version 1. Written from docs/encryption-spec.md and checked against
/// docs/encryption-vectors.json. Not yet used by the app.
public enum NotebookCrypto {
    public static let minimumPassphraseLength = 12
    public static let defaultIterations = 600_000
    public static let minimumIterations = 100_000
    public static let maximumIterations = 10_000_000
    public static let pbkdf2Name = "pbkdf2-hmac-sha256"

    public enum Kind: UInt8 { case manifest = 1, page = 2, asset = 3 }

    private static let magic = Data("NCE1".utf8)
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 35
    private static let tagSize = 16
    private static let infoObject = Data("notecanvas/v1/object".utf8)
    private static let infoRecovery = Data("notecanvas/v1/recovery-kek".utf8)
    private static let aadSlot = Data("notecanvas/v1/keyslot".utf8)
    private static let checkPrefix = Data("notecanvas/v1/recovery-check".utf8)
    private static let base32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    // MARK: objects

    /// Encrypts one file. A fresh salt and nonce are drawn for every call.
    public static func seal(_ plaintext: Data, kind: Kind, logicalPath: String, notebookID: UUID, notebookKey: SymmetricKey) throws -> Data {
        try seal(plaintext, kind: kind, logicalPath: logicalPath, notebookID: notebookID, notebookKey: notebookKey,
                 salt: randomBytes(16), nonce: randomBytes(12))
    }

    /// Fixed salt and nonce, for the published test vectors only. Reusing a salt and nonce pair on real data is a defect.
    public static func seal(_ plaintext: Data, kind: Kind, logicalPath: String, notebookID: UUID, notebookKey: SymmetricKey,
                            salt: Data, nonce: Data) throws -> Data {
        var header = Data(magic)
        header.append(formatVersion)
        header.append(0)
        header.append(kind.rawValue)
        header.append(salt)
        header.append(nonce)
        let box = try AES.GCM.seal(plaintext, using: objectKey(notebookKey, salt: salt),
                                   nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: objectAAD(header, notebookID, logicalPath))
        return header + box.ciphertext + box.tag
    }

    /// Decrypts one file. Any problem, including a wrong name, notebook or kind, throws and returns nothing.
    public static func open(_ blob: Data, kind: Kind, logicalPath: String, notebookID: UUID, notebookKey: SymmetricKey) throws -> Data {
        let data = Data(blob)                       // zero-based indices whatever slice it came from
        guard data.count >= headerSize + tagSize, data.prefix(4) == magic else { throw CryptoError.badObject }
        guard data[4] == formatVersion else { throw CryptoError.unsupportedVersion(Int(data[4])) }
        guard data[5] == 0, data[6] == kind.rawValue else { throw CryptoError.badObject }
        let header = data.subdata(in: 0..<headerSize)
        let salt = data.subdata(in: 7..<23)
        let nonce = data.subdata(in: 23..<35)
        let body = data.subdata(in: headerSize..<data.count)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: body.prefix(body.count - tagSize),
                                            tag: body.suffix(tagSize))
            return try AES.GCM.open(box, using: objectKey(notebookKey, salt: salt),
                                    authenticating: objectAAD(header, notebookID, logicalPath))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    private static func objectKey(_ notebookKey: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: notebookKey, salt: salt, info: infoObject, outputByteCount: 32)
    }

    private static func objectAAD(_ header: Data, _ notebookID: UUID, _ logicalPath: String) -> Data {
        header + bytes(of: notebookID) + Data(logicalPath.utf8)
    }

    // MARK: keys

    /// Makes the Notebook Key, a passphrase slot and a recovery slot.
    public static func createKeys(passphrase: String, iterations: Int = defaultIterations) throws -> NewNotebookKeys {
        let notebookID = UUID()
        let notebookKey = SymmetricKey(size: .bits256)
        let recovery = randomBytes(32)
        let passphraseSlot = try makePassphraseSlot(passphrase: passphrase, iterations: iterations,
                                                    notebookID: notebookID, notebookKey: notebookKey)
        let slotID = UUID()
        let nonce = randomBytes(12)
        let wrapped = try wrap(notebookKey, with: recoveryKEK(recovery, notebookID: notebookID),
                               nonce: nonce, notebookID: notebookID, slotID: slotID)
        let recoverySlot = KeySlot(type: "recovery", id: slotID.uuidString.lowercased(), kdf: nil, nonce: nonce, wrappedKey: wrapped)
        let file = KeysFile(notebookId: notebookID.uuidString.lowercased(), slots: [passphraseSlot, recoverySlot])
        return NewNotebookKeys(keysFile: file, notebookKey: notebookKey, recoveryKey: recoveryDisplay(recovery))
    }

    public static func unlock(_ file: KeysFile, passphrase: String) throws -> SymmetricKey {
        guard let notebookID = file.notebookUUID else { throw CryptoError.badObject }
        var sawBadKDF = false
        var tried = false
        for slot in file.slots where slot.type == "passphrase" {
            guard let kdf = slot.kdf, kdf.alg == pbkdf2Name, let slotID = UUID(uuidString: slot.id) else { continue }
            guard (minimumIterations...maximumIterations).contains(kdf.iterations) else { sawBadKDF = true; continue }
            tried = true
            let kek = try passphraseKEK(passphrase: passphrase, salt: kdf.salt, iterations: kdf.iterations)
            if let key = unwrap(slot, with: kek, notebookID: notebookID, slotID: slotID) { return key }
        }
        throw sawBadKDF && !tried ? CryptoError.badKDF : CryptoError.noMatchingSlot
    }

    public static func unlock(_ file: KeysFile, recoveryKey text: String) throws -> SymmetricKey {
        guard let notebookID = file.notebookUUID else { throw CryptoError.badObject }
        let kek = recoveryKEK(try recoveryParse(text), notebookID: notebookID)
        for slot in file.slots where slot.type == "recovery" {
            guard let slotID = UUID(uuidString: slot.id) else { continue }
            if let key = unwrap(slot, with: kek, notebookID: notebookID, slotID: slotID) { return key }
        }
        throw CryptoError.noMatchingSlot
    }

    /// Replaces the passphrase slot. Nothing else in the notebook changes.
    public static func changePassphrase(_ file: KeysFile, notebookKey: SymmetricKey, newPassphrase: String,
                                        iterations: Int = defaultIterations) throws -> KeysFile {
        guard let notebookID = file.notebookUUID else { throw CryptoError.badObject }
        let slot = try makePassphraseSlot(passphrase: newPassphrase, iterations: iterations,
                                          notebookID: notebookID, notebookKey: notebookKey)
        var updated = file
        updated.slots = file.slots.filter { $0.type != "passphrase" } + [slot]
        return updated
    }

    public static func passphraseKEK(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (minimumIterations...maximumIterations).contains(iterations) else { throw CryptoError.badKDF }
        let secret = passphrase.precomposedStringWithCompatibilityMapping.utf8CString   // NFKC, then UTF-8 plus a NUL
        var out = [UInt8](repeating: 0, count: 32)
        let status: Int32 = secret.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { saltBytes in
                out.withUnsafeMutableBufferPointer { outBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress, secret.count - 1,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outBytes.baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.badKDF }
        return SymmetricKey(data: out)
    }

    public static func recoveryKEK(_ recoveryKey: Data, notebookID: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey), salt: bytes(of: notebookID),
                               info: infoRecovery, outputByteCount: 32)
    }

    private static func makePassphraseSlot(passphrase: String, iterations: Int, notebookID: UUID, notebookKey: SymmetricKey) throws -> KeySlot {
        guard passphrase.count >= minimumPassphraseLength else { throw CryptoError.passphraseTooShort }
        let salt = randomBytes(16)
        let slotID = UUID()
        let nonce = randomBytes(12)
        let kek = try passphraseKEK(passphrase: passphrase, salt: salt, iterations: iterations)
        let wrapped = try wrap(notebookKey, with: kek, nonce: nonce, notebookID: notebookID, slotID: slotID)
        return KeySlot(type: "passphrase", id: slotID.uuidString.lowercased(),
                       kdf: .init(alg: pbkdf2Name, iterations: iterations, salt: salt), nonce: nonce, wrappedKey: wrapped)
    }

    private static func slotAAD(_ notebookID: UUID, _ slotID: UUID) -> Data {
        aadSlot + bytes(of: notebookID) + bytes(of: slotID)
    }

    private static func wrap(_ notebookKey: SymmetricKey, with kek: SymmetricKey, nonce: Data, notebookID: UUID, slotID: UUID) throws -> Data {
        let plain = notebookKey.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(plain, using: kek, nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: slotAAD(notebookID, slotID))
        return box.ciphertext + box.tag
    }

    /// Nil when the slot is malformed or the key is wrong. A bad slot is skipped, not fatal.
    private static func unwrap(_ slot: KeySlot, with kek: SymmetricKey, notebookID: UUID, slotID: UUID) -> SymmetricKey? {
        let wrapped = Data(slot.wrappedKey)
        guard wrapped.count == 32 + tagSize, slot.nonce.count == 12,
              let nonce = try? AES.GCM.Nonce(data: slot.nonce),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: wrapped.prefix(32), tag: wrapped.suffix(tagSize)),
              let plain = try? AES.GCM.open(box, using: kek, authenticating: slotAAD(notebookID, slotID)) else { return nil }
        return SymmetricKey(data: plain)
    }

    // MARK: recovery key text

    /// 32 key bytes plus a 3 byte check, as 56 Base32 characters in groups of four.
    public static func recoveryDisplay(_ key: Data) -> String { recoveryDisplay(key, checkPrefix: checkPrefix) }

    static func recoveryDisplay(_ key: Data, checkPrefix: Data) -> String {
        let check = Data(SHA256.hash(data: checkPrefix + key).prefix(3))
        let raw = Array(key + check)
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in raw {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(base32[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        let text = String(decoding: out, as: UTF8.self)
        return stride(from: 0, to: text.count, by: 4).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            return String(text[from..<to])
        }.joined(separator: "-")
    }

    /// Accepts hyphens, spaces and lower case. Rejects a wrong check value as a typing mistake.
    public static func recoveryParse(_ text: String) throws -> Data { try recoveryParse(text, checkPrefix: checkPrefix) }

    static func recoveryParse(_ text: String, checkPrefix: Data) throws -> Data {
        let cleaned = text.uppercased().filter { $0 != "-" && $0 != " " }
        guard cleaned.utf8.count == 56 else { throw CryptoError.badRecoveryKey }
        var raw: [UInt8] = []
        var buffer = 0
        var bits = 0
        for ch in cleaned.utf8 {
            guard let value = base32.firstIndex(of: ch) else { throw CryptoError.badRecoveryKey }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                raw.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        guard raw.count == 35 else { throw CryptoError.badRecoveryKey }
        let key = Data(raw.prefix(32))
        guard Data(SHA256.hash(data: checkPrefix + key).prefix(3)) == Data(raw.suffix(3)) else {
            throw CryptoError.badRecoveryKey
        }
        return key
    }

    // MARK: helpers

    static func bytes(of id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
