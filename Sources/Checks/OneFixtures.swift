import Foundation
import OneStore

/// Little-endian byte builder for hand-made `.one` fixtures.
struct ByteBuilder {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func append(_ b: [UInt8]) { bytes += b }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
    mutating func pad(to n: Int) { if bytes.count < n { zeros(n - bytes.count) } }
}

func le32(_ v: UInt32) -> [UInt8] { var b = ByteBuilder(); b.u32(v); return b.bytes }
func le16(_ v: UInt16) -> [UInt8] { var b = ByteBuilder(); b.u16(v); return b.bytes }
func utf16le(_ s: String) -> [UInt8] { s.utf16.flatMap { le16($0) } }

/// "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" -> the 16 bytes as stored in a file (first three groups little-endian).
func guidBytes(_ s: String) -> [UInt8] {
    let hex = Array(s.filter { $0 != "{" && $0 != "}" && $0 != "-" })
    precondition(hex.count == 32, "bad GUID \(s)")
    let b = (0..<16).map { UInt8(String(hex[2 * $0...2 * $0 + 1]), radix: 16)! }
    return Array(b[0..<4].reversed()) + Array(b[4..<6].reversed()) + Array(b[6..<8].reversed()) + Array(b[8..<16])
}

let oneFileTypeGUID = "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}"
let onetoc2FileTypeGUID = "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}"
let revisionStoreFormatGUID = "{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}"

/// One encoded FileNode: a 4-byte header (id, size, formats, base type, reserved bit) followed by `fnd`.
struct FNode {
    var id: UInt16
    var fnd: [UInt8] = []
    var base: Int = 0
    var stpFormat: Int = 0
    var cbFormat: Int = 0
    var encoded: [UInt8] {
        let size = 4 + fnd.count
        let word: UInt32 = UInt32(id) | UInt32(size) << 10 | UInt32(stpFormat) << 23
            | UInt32(cbFormat) << 25 | UInt32(base) << 27 | UInt32(1) << 31
        return le32(word) + fnd
    }
}

/// A FileNodeListFragment of exactly `size` bytes: header, nodes, optional terminator, zero padding, nextFragment, footer.
func fragment(listID: UInt32, seq: UInt32 = 0, nodes: [FNode], size: Int, terminator: Bool = false,
              next: (stp: UInt64, cb: UInt32)? = nil) -> [UInt8] {
    var b = ByteBuilder()
    b.u64(0xA4567AB1F5F7F4C4); b.u32(listID); b.u32(seq)
    for n in nodes { b.append(n.encoded) }
    if terminator { b.append(FNode(id: 0xFF).encoded) }
    precondition(b.count <= size - 20, "fragment fixture too small for its nodes")
    b.pad(to: size - 20)
    if let next { b.u64(next.stp); b.u32(next.cb) } else { b.u64(UInt64.max); b.u32(0) }
    b.u64(0x8BC215C38233BA4B)
    return b.bytes
}

/// The 1024-byte file header.
func oneHeader(transactions: UInt32, log: (stp: UInt64, cb: UInt32), root: (stp: UInt64, cb: UInt32),
               fileType: String = oneFileTypeGUID, oldestMayRead: UInt32 = 0x2A) -> [UInt8] {
    var b = ByteBuilder()
    b.append(guidBytes(fileType))            // 0  guidFileType
    b.zeros(32)                              // 16 guidFile, 32 guidLegacyFileVersion
    b.append(guidBytes(revisionStoreFormatGUID))   // 48 guidFileFormat
    b.u32(0x2A); b.u32(0x2A); b.u32(0x2A); b.u32(oldestMayRead)   // 64..80 file format versions
    b.zeros(16)                              // 80 legacy free chunk list, 88 legacy transaction log
    b.u32(transactions)                      // 96 cTransactionsInLog
    b.zeros(60)                              // 100..160
    b.u64(log.stp); b.u32(log.cb)            // 160 fcrTransactionLog
    b.u64(root.stp); b.u32(root.cb)          // 172 fcrFileNodeListRoot
    b.pad(to: 1024)
    return b.bytes
}

/// A TransactionLogFragment of exactly `size` bytes: entries, zero padding, nextFragment.
func transactionLog(entries: [(src: UInt32, sw: UInt32)], size: Int, next: (stp: UInt64, cb: UInt32)? = nil) -> [UInt8] {
    var b = ByteBuilder()
    for e in entries { b.u32(e.src); b.u32(e.sw) }
    precondition(b.count <= size - 12, "transaction log fixture too small")
    b.pad(to: size - 12)
    if let next { b.u64(next.stp); b.u32(next.cb) } else { b.u64(UInt64.max); b.u32(0) }
    return b.bytes
}

/// Header + transaction log + one list fragment holding `nodes`, at fixed offsets.
/// `committed == nil` writes a log with no entry for the list; otherwise the log commits that many nodes.
func simpleFile(nodes: [FNode], listID: UInt32 = 0x10, committed: UInt32? = nil, fragSize: Int = 512,
                terminator: Bool = true) -> Data {
    let logStp = 1024, logSize = 64
    let listStp = logStp + logSize
    var entries: [(src: UInt32, sw: UInt32)] = []
    if let committed { entries.append((listID, committed)) }
    entries.append((1, 0))                    // sentinel ends the transaction
    var b = ByteBuilder()
    b.append(oneHeader(transactions: 1, log: (UInt64(logStp), UInt32(logSize)),
                       root: (UInt64(listStp), UInt32(fragSize))))
    b.append(transactionLog(entries: entries, size: logSize))
    b.append(fragment(listID: listID, nodes: nodes, size: fragSize, terminator: terminator))
    return Data(b.bytes)
}

/// Runs `body` on every truncation of `data` and on single-byte corruptions; it must either succeed or throw a
/// `OneStoreError`. Any other error is a failure, and a trap or hang fails the whole run (Review Focus 1).
func fuzz(_ label: String, _ data: Data, step: Int = 1, _ body: (Data) throws -> Void, file: String = #fileID, line: Int = #line) {
    func attempt(_ d: Data, _ what: String) {
        do { try body(d) }
        catch is OneStoreError {}
        catch { failures += 1; print("FAIL \(file):\(line): \(label) \(what) threw a non-OneStoreError: \(error)") }
    }
    var len = 0
    while len < data.count { attempt(data.prefix(len), "truncated to \(len)"); len += step }
    var pos = 0
    while pos < data.count {
        for v in [UInt8(0x00), 0xFF] {
            var d = data; d[d.startIndex + pos] = v
            attempt(d, "byte \(pos) set to \(v)")
        }
        pos += step
    }
}
