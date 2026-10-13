import Foundation

/// A file chunk reference: where data starts and how long it is.
struct ChunkRef: Equatable {
    var stp: UInt64
    var cb: UInt64
    var isNil: Bool { stp == UInt64.max }
    var isZero: Bool { stp == 0 && cb == 0 }

    /// A FileChunkReference64x32: an 8-byte stp followed by a 4-byte cb.
    static func read64x32(_ r: ByteReader, at o: Int) throws -> ChunkRef {
        let stp = try r.u64(o)
        let cb = try r.u32(o + 8)
        return ChunkRef(stp: stp, cb: UInt64(cb))
    }
}

struct FileNode: Equatable {
    let id: UInt16
    let offset: Int
    let size: Int
    let stpFormat: Int
    let cbFormat: Int
    let baseType: Int
    var fnd: Int { offset + 4 }
    var end: Int { offset + size }

    static func parse(_ r: ByteReader, at o: Int) throws -> FileNode {
        let v = try r.u32(o)
        let size = Int((v >> 10) & 0x1FFF)
        guard size >= 4 else { throw OneStoreError.corrupt(offset: o, reason: "file node size \(size) is below its 4-byte header") }
        return FileNode(id: UInt16(v & 0x3FF), offset: o, size: size, stpFormat: Int((v >> 23) & 3),
                        cbFormat: Int((v >> 25) & 3), baseType: Int((v >> 27) & 0xF))
    }

    /// The FileNodeChunkReference at the start of `fnd`, and the offset just after it.
    func chunkRef(_ r: ByteReader) throws -> (ref: ChunkRef, next: Int) {
        var o = fnd
        let stp: UInt64
        switch stpFormat {
        case 0:
            stp = try r.u64(o); o += 8
        case 1:
            let v = try r.u32(o); stp = v == UInt32.max ? UInt64.max : UInt64(v); o += 4
        case 2:
            let v = try r.u16(o); stp = UInt64(v) * 8; o += 2
        default:
            let v = try r.u32(o); stp = UInt64(v) * 8; o += 4
        }
        let cb: UInt64
        switch cbFormat {
        case 0:
            let v = try r.u32(o); cb = UInt64(v); o += 4
        case 1:
            cb = try r.u64(o); o += 8
        case 2:
            let v = try r.u8(o); cb = UInt64(v) * 8; o += 1
        default:
            let v = try r.u16(o); cb = UInt64(v) * 8; o += 2
        }
        guard o <= end else { throw OneStoreError.corrupt(offset: offset, reason: "chunk reference runs past its file node") }
        return (ChunkRef(stp: stp, cb: cb), o)
    }
}

struct OneHeader {
    static let oneFileType = GUID(string: "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}")!
    static let toc2FileType = GUID(string: "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}")!
    static let revisionStoreFormat = GUID(string: "{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}")!
    static let newestReadableVersion: UInt32 = 0x2A

    let transactions: UInt32
    let transactionLog: ChunkRef
    let rootList: ChunkRef

    static func parse(_ r: ByteReader) throws -> OneHeader {
        guard r.count >= 1024 else { throw OneStoreError.notAOneFile }
        let type = try GUID(r, at: 0)
        if type == toc2FileType { throw OneStoreError.unsupportedFileType }
        guard type == oneFileType, try GUID(r, at: 48) == revisionStoreFormat else { throw OneStoreError.notAOneFile }
        let mayRead = try r.u32(76)               // ffvOldestCodeThatMayReadThisFile
        guard mayRead <= newestReadableVersion else { throw OneStoreError.unsupportedVersion(mayRead) }
        return OneHeader(transactions: try r.u32(96),
                         transactionLog: try ChunkRef.read64x32(r, at: 160),
                         rootList: try ChunkRef.read64x32(r, at: 172))
    }
}

enum TransactionLog {
    /// FileNodeListID -> number of committed nodes, taken from the first `header.transactions` transactions.
    static func committedCounts(_ r: ByteReader, header: OneHeader) throws -> [UInt32: UInt32] {
        var counts: [UInt32: UInt32] = [:]
        var finished: UInt32 = 0
        var ref = header.transactionLog
        var seen = Set<UInt64>()
        while finished < header.transactions {
            guard !ref.isNil, !ref.isZero, ref.cb >= 12, ref.stp <= UInt64(r.count), ref.cb <= UInt64(r.count) - ref.stp else {
                throw OneStoreError.corrupt(offset: Int(clamping: ref.stp), reason: "transaction log fragment is outside the file")
            }
            guard seen.insert(ref.stp).inserted else {
                throw OneStoreError.corrupt(offset: Int(ref.stp), reason: "transaction log fragments form a loop")
            }
            let start = Int(ref.stp), size = Int(ref.cb)
            for i in 0..<((size - 12) / 8) {
                let src = try r.u32(start + 8 * i)
                let value = try r.u32(start + 8 * i + 4)
                if src == 1 {                         // sentinel: the transaction is complete
                    finished += 1
                    if finished == header.transactions { return counts }
                } else if src != 0 {
                    counts[src] = value               // the newest entry for a list wins
                }
            }
            ref = try ChunkRef.read64x32(r, at: start + size - 12)
        }
        return counts
    }
}

struct NodeListReader {
    let r: ByteReader
    /// FileNodeListID -> committed node count; nil when the file has no usable transaction log.
    let committed: [UInt32: UInt32]?

    /// Reads the nodes of the list whose first fragment is `first`, following nextFragment links and stopping at the
    /// committed count, a ChunkTerminator, or the end of the data.
    func nodes(from first: ChunkRef, warnings: inout [String]) throws -> [FileNode] {
        var result: [FileNode] = []
        var ref = first
        var listID: UInt32?
        var limit: Int?
        var seen = Set<UInt64>()
        while true {
            guard !ref.isNil, ref.cb >= 36, ref.stp <= UInt64(r.count), ref.cb <= UInt64(r.count) - ref.stp else {
                throw OneStoreError.truncated(offset: Int(clamping: ref.stp))
            }
            guard seen.insert(ref.stp).inserted else {
                throw OneStoreError.corrupt(offset: Int(ref.stp), reason: "file node list fragments form a loop")
            }
            let start = Int(ref.stp), size = Int(ref.cb)
            guard try r.u64(start) == 0xA4567AB1F5F7F4C4 else {
                throw OneStoreError.corrupt(offset: start, reason: "bad file node list fragment header")
            }
            let id = try r.u32(start + 8)
            if let known = listID {
                guard known == id else { throw OneStoreError.corrupt(offset: start, reason: "fragment belongs to a different list") }
            } else {
                listID = id
                if let committed {
                    if let n = committed[id] { limit = Int(n) }
                    else { warnings.append("file node list 0x\(String(id, radix: 16)) has no committed count; reading to its end") }
                }
            }
            let end = start + size - 20               // nextFragment (12 bytes) and footer (8 bytes) follow the nodes
            var o = start + 16
            while end - o >= 4 {
                if let limit, result.count >= limit { return result }
                let word = try r.u32(o)
                let fid = word & 0x3FF
                if fid == 0 || fid == 0xFF { break }  // zero padding, or a ChunkTerminator
                let node = try FileNode.parse(r, at: o)
                guard node.end <= end else { throw OneStoreError.corrupt(offset: o, reason: "file node runs past its fragment") }
                result.append(node)
                o = node.end
            }
            if let limit, result.count >= limit { return result }
            let next = try ChunkRef.read64x32(r, at: end)
            if next.isNil || next.cb == 0 { break }
            ref = next
        }
        if let limit, result.count < limit {
            warnings.append("file node list has \(result.count) nodes but \(limit) were committed")
        }
        return result
    }
}

/// A validated file header plus the machinery to read its node lists.
struct OpenedStore {
    let reader: ByteReader
    let header: OneHeader
    let lists: NodeListReader
    var warnings: [String]

    init(_ data: Data) throws {
        let r = ByteReader(data)
        let header = try OneHeader.parse(r)
        var warnings: [String] = []
        var counts: [UInt32: UInt32]?
        if header.transactions == 0 {
            warnings.append("transaction log is empty; reading every node list to its end")
        } else {
            do { counts = try TransactionLog.committedCounts(r, header: header) }
            catch { warnings.append("transaction log unreadable (\(error)); reading every node list to its end") }
        }
        self.reader = r
        self.header = header
        self.warnings = warnings
        self.lists = NodeListReader(r: r, committed: counts)
    }

    func rootNodes(warnings: inout [String]) throws -> [FileNode] {
        try lists.nodes(from: header.rootList, warnings: &warnings)
    }
}
