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

// ---- Full-file fixtures: object spaces, revisions, global ID tables and objects ----

struct FxProp { var pid: UInt32; var data: [UInt8] = [] }

/// An object declaration. `oids` are the CompactIDs consumed (in property order) by the object's object-ID
/// properties; `osids` likewise for object-space-ID properties.
struct FxObject {
    var oid: UInt32
    var jcid: UInt32
    var props: [FxProp] = []
    var oids: [UInt32] = []
    var osids: [UInt32] = []
}

struct FxRevision {
    var rid: (guid: String, n: UInt32)
    var dependent: (guid: String, n: UInt32)? = nil
    var role: UInt32 = 1
    var idTable: [(index: UInt32, guid: String)]
    var roots: [(role: UInt32, guid: String, n: UInt32)]
    var objects: [FxObject]
    var extraNodes: [FNode] = []     // appended inside the revision's node list (e.g. file data declarations)
}

/// A CompactID: the global-ID-table index in the high 24 bits, `n` in the low 8.
func compact(_ index: UInt32, _ n: UInt8) -> UInt32 { index << 8 | UInt32(n) }

func extGUID(_ guid: String, _ n: UInt32) -> [UInt8] { guidBytes(guid) + le32(n) }

/// A PropertySet body: count, PropertyIDs, then the data of each property in order.
func setBytes(_ props: [FxProp]) -> [UInt8] {
    var b = ByteBuilder()
    b.u16(UInt16(props.count))
    for p in props { b.u32(p.pid) }
    for p in props { b.append(p.data) }
    return b.bytes
}

/// An ObjectSpaceObjectPropSet: object stream, optional object-space stream, the property set, padded to 8 bytes.
func objectBlob(_ o: FxObject) -> [UInt8] {
    var b = ByteBuilder()
    b.u32(UInt32(o.oids.count) | (o.osids.isEmpty ? UInt32(1) << 31 : 0))
    for id in o.oids { b.u32(id) }
    if !o.osids.isEmpty {
        b.u32(UInt32(o.osids.count))
        for id in o.osids { b.u32(id) }
    }
    b.append(setBytes(o.props))
    while b.count % 8 != 0 { b.u8(0) }
    return b.bytes
}

/// Lays out a whole file: a reserved header and transaction log, then lists and blobs appended leaf-first.
final class FxFile {
    var b = ByteBuilder()
    var commits: [(UInt32, UInt32)] = []
    var nextListID: UInt32 = 0x10
    init() { b.zeros(1024 + 4096) }

    func list(_ nodes: [FNode]) -> (stp: UInt64, cb: UInt32) {
        let id = nextListID; nextListID += 1
        let need = nodes.reduce(0) { $0 + $1.encoded.count } + 4 + 40
        let size = (max(need, 256) + 7) / 8 * 8
        let stp = b.count
        b.append(fragment(listID: id, nodes: nodes, size: size, terminator: true))
        commits.append((id, UInt32(nodes.count)))
        return (UInt64(stp), UInt32(size))
    }

    func blob(_ bytes: [UInt8]) -> (stp: UInt64, cb: UInt32) {
        let s = b.count
        b.append(bytes)
        return (UInt64(s), UInt32(bytes.count))
    }

    func finish(root: (stp: UInt64, cb: UInt32)) -> Data {
        var out = b.bytes
        let log = transactionLog(entries: commits.map { (src: $0.0, sw: $0.1) } + [(src: 1, sw: 0)], size: 4096)
        out.replaceSubrange(1024..<(1024 + 4096), with: log)
        out.replaceSubrange(0..<1024, with: oneHeader(transactions: 1, log: (1024, 4096), root: root))
        return Data(out)
    }
}

/// A node holding a FileNodeChunkReference (8-byte stp, 4-byte cb) followed by `extra` bytes.
func refNode(_ id: UInt16, base: Int, ref: (stp: UInt64, cb: UInt32), extra: [UInt8] = []) -> FNode {
    var b = ByteBuilder(); b.u64(ref.stp); b.u32(ref.cb); b.append(extra)
    return FNode(id: id, fnd: b.bytes, base: base, stpFormat: 0, cbFormat: 0)
}

/// ObjectDeclaration2RefCountFND: reference to the property data, then oid, jcid, flags, reference count.
func declNode(blob: (stp: UInt64, cb: UInt32), oid: UInt32, jcid: UInt32) -> FNode {
    refNode(0xA4, base: 1, ref: blob, extra: le32(oid) + le32(jcid) + [0, 1])
}

/// A StringInStorageBuffer: character count then UTF-16 characters.
func storageString(_ s: String) -> [UInt8] { le32(UInt32(s.utf16.count)) + utf16le(s) }

/// ObjectDeclarationFileData3RefCountFND (a file data object): oid, jcid, count, reference string, extension string.
func fileDataDeclNode(oid: UInt32, jcid: UInt32, target: String, ext: String) -> FNode {
    FNode(id: 0x72, fnd: le32(oid) + le32(jcid) + [1] + storageString(target) + storageString(ext))
}

let fileDataHeaderGUID = "{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}"
let fileDataFooterGUID = "{71FBA722-0F79-4A0B-BB13-899256426B24}"

/// A FileDataStoreObject: header GUID, length, 4+8 reserved bytes, the data, padding to 8, footer GUID.
func fileDataObject(_ data: [UInt8]) -> [UInt8] {
    var b = ByteBuilder()
    b.append(guidBytes(fileDataHeaderGUID)); b.u64(UInt64(data.count)); b.u32(0); b.u64(0)
    b.append(data)
    while b.count % 8 != 0 { b.u8(0) }
    b.append(guidBytes(fileDataFooterGUID))
    return b.bytes
}

/// Builds one object space with the given revisions. `rootExtra` nodes (for example a file data store reference)
/// are appended to the root list.
func buildStore(_ file: FxFile, space: (guid: String, n: UInt32), revisions: [FxRevision], rootExtra: [FNode] = []) -> Data {
    var revisionNodes: [FNode] = [FNode(id: 0x14, fnd: [UInt8](repeating: 0, count: 24))]
    for (i, rev) in revisions.enumerated() {
        let groupID = "{99999999-9999-9999-9999-99999999999\(i)}"
        var groupNodes: [FNode] = [FNode(id: 0xB4, fnd: extGUID(groupID, 1))]
        for obj in rev.objects { groupNodes.append(declNode(blob: file.blob(objectBlob(obj)), oid: obj.oid, jcid: obj.jcid)) }
        groupNodes += rev.extraNodes
        groupNodes.append(FNode(id: 0xB8))
        let groupList = file.list(groupNodes)

        let dep = rev.dependent.map { extGUID($0.guid, $0.n) } ?? [UInt8](repeating: 0, count: 20)
        revisionNodes.append(FNode(id: 0x1F, fnd: extGUID(rev.rid.guid, rev.rid.n) + dep + le32(rev.role) + le16(0)
                                   + [UInt8](repeating: 0, count: 20)))
        revisionNodes.append(FNode(id: 0x22))
        for e in rev.idTable { revisionNodes.append(FNode(id: 0x24, fnd: le32(e.index) + guidBytes(e.guid))) }
        revisionNodes.append(FNode(id: 0x28))
        for r in rev.roots { revisionNodes.append(FNode(id: 0x5A, fnd: extGUID(r.guid, r.n) + le32(r.role))) }
        revisionNodes.append(refNode(0xB0, base: 2, ref: groupList, extra: extGUID(groupID, 1)))
        revisionNodes.append(FNode(id: 0x1C))
    }
    let revisionList = file.list(revisionNodes)
    let spaceList = file.list([FNode(id: 0x0C, fnd: extGUID(space.guid, space.n)),
                               refNode(0x10, base: 2, ref: revisionList)])
    let rootList = file.list([FNode(id: 0x04, fnd: extGUID(space.guid, space.n)),
                              refNode(0x08, base: 2, ref: spaceList, extra: extGUID(space.guid, space.n))] + rootExtra)
    return file.finish(root: rootList)
}
