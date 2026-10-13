import Foundation
@testable import OneStore

private func open(_ data: Data) throws -> (store: OpenedStore, nodes: [FileNode], warnings: [String]) {
    let store = try OpenedStore(data)
    var warnings = store.warnings
    let nodes = try store.rootNodes(warnings: &warnings)
    return (store, nodes, warnings)
}

private func errorOf(_ data: Data) -> OneStoreError? {
    do { _ = try open(data) } catch let e as OneStoreError { return e } catch { return nil }
    return nil
}

private func thrownError(_ body: () throws -> Void) -> OneStoreError? {
    do { try body() } catch let e as OneStoreError { return e } catch { return nil }
    return nil
}

private func isCorrupt(_ e: OneStoreError?) -> Bool { if case .corrupt? = e { return true }; return false }
private func isTruncated(_ e: OneStoreError?) -> Bool { if case .truncated? = e { return true }; return false }

/// Two fragments of list 0x10 (3 nodes then 2), root at the first; the log commits `committed` nodes.
func twoFragmentFile(committed: UInt32 = 5, secondListID: UInt32 = 0x10, loop: Bool = false) -> Data {
    let logStp = 1024, logSize = 64, f1 = logStp + logSize, size = 256, f2 = f1 + size
    var b = ByteBuilder()
    b.append(oneHeader(transactions: 1, log: (UInt64(logStp), UInt32(logSize)), root: (UInt64(f1), UInt32(size))))
    b.append(transactionLog(entries: [(0x10, committed), (1, 0)], size: logSize))
    b.append(fragment(listID: 0x10, seq: 0, nodes: [FNode(id: 0x40), FNode(id: 0x41), FNode(id: 0x42)],
                      size: size, terminator: true, next: (UInt64(loop ? f1 : f2), UInt32(size))))
    b.append(fragment(listID: secondListID, seq: 1, nodes: [FNode(id: 0x43), FNode(id: 0x44)], size: size, terminator: true))
    return Data(b.bytes)
}

func oneStorePrimitiveChecks() {
    let five = (0..<5).map { FNode(id: UInt16(0x30 + $0)) }
    let ok = simpleFile(nodes: [FNode(id: 0x04, fnd: [UInt8](repeating: 0, count: 20))])
    checkEqual(try! open(ok).nodes.map(\.id), [0x04], "a minimal file opens")

    // --- header ---
    checkEqual(errorOf(Data()), .notAOneFile, "empty data is not a .one file")
    checkEqual(errorOf(Data(repeating: 0, count: 2000)), .notAOneFile, "zeros are not a .one file")
    checkEqual(errorOf(ok.prefix(1000)), .notAOneFile, "a header cut short is not a .one file")
    var toc = ok; toc.replaceSubrange(0..<16, with: guidBytes(onetoc2FileTypeGUID))
    checkEqual(errorOf(toc), .unsupportedFileType, ".onetoc2 is recognised and refused")
    var badFormat = ok; badFormat[48] ^= 0xFF
    checkEqual(errorOf(badFormat), .notAOneFile, "a wrong format GUID is not a revision store")
    var newer = ok; newer.replaceSubrange(76..<80, with: le32(0x2B))
    checkEqual(errorOf(newer), .unsupportedVersion(0x2B), "a file that needs a newer reader is refused")

    // --- file node header packing ---
    let packed = FNode(id: 0x1F7, fnd: [1, 2, 3, 4, 5, 6, 7, 8], base: 2, stpFormat: 3, cbFormat: 1)
    let n0 = try! open(simpleFile(nodes: [packed])).nodes[0]
    checkEqual(n0.id, 0x1F7, "node id is the low 10 bits")
    checkEqual(n0.size, 12, "node size is header + fnd")
    checkEqual(n0.stpFormat, 3, "stp format bits")
    checkEqual(n0.cbFormat, 1, "cb format bits")
    checkEqual(n0.baseType, 2, "base type bits")
    checkEqual(n0.fnd, n0.offset + 4, "fnd follows the 4-byte header")

    // --- every stp/cb format ---
    let stpRaw: [(UInt64, Int)] = [(0x1122_3344_5566, 8), (0x0102_0304, 4), (0x0102, 2), (0x0102_0304, 4)]
    let stpExpect: [UInt64] = [0x1122_3344_5566, 0x0102_0304, 0x0102 * 8, 0x0102_0304 * 8]
    let cbRaw: [(UInt64, Int)] = [(0x0A0B, 4), (0x0A0B_0C0D, 8), (0x7F, 1), (0x0A0B, 2)]
    let cbExpect: [UInt64] = [0x0A0B, 0x0A0B_0C0D, 0x7F * 8, 0x0A0B * 8]
    for s in 0..<4 {
        for c in 0..<4 {
            var f = ByteBuilder()
            for i in 0..<stpRaw[s].1 { f.u8(UInt8((stpRaw[s].0 >> (8 * UInt64(i))) & 0xFF)) }
            for i in 0..<cbRaw[c].1 { f.u8(UInt8((cbRaw[c].0 >> (8 * UInt64(i))) & 0xFF)) }
            f.u8(0xAA)
            let node = FNode(id: 0x08, fnd: f.bytes, base: 1, stpFormat: s, cbFormat: c)
            let opened = try! open(simpleFile(nodes: [node]))
            let (ref, next) = try! opened.nodes[0].chunkRef(opened.store.reader)
            checkEqual(ref.stp, stpExpect[s], "stp format \(s)")
            checkEqual(ref.cb, cbExpect[c], "cb format \(c)")
            checkEqual(next, opened.nodes[0].fnd + stpRaw[s].1 + cbRaw[c].1, "offset after the reference (\(s),\(c))")
        }
    }
    let nilNode = FNode(id: 0x08, fnd: [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0], base: 1, stpFormat: 1, cbFormat: 0)
    let nilOpened = try! open(simpleFile(nodes: [nilNode]))
    check(try! nilOpened.nodes[0].chunkRef(nilOpened.store.reader).ref.isNil, "an all-ones 4-byte stp is fcrNil")
    let shortNode = FNode(id: 0x08, fnd: [0, 0, 0, 0], base: 1, stpFormat: 0, cbFormat: 1)   // needs 16 bytes, has 4
    let shortOpened = try! open(simpleFile(nodes: [shortNode]))
    check(isCorrupt(thrownError { _ = try shortOpened.nodes[0].chunkRef(shortOpened.store.reader) }),
          "a reference that runs past its node is corrupt, not a trap")

    // --- node lists ---
    let three = (0..<3).map { FNode(id: UInt16(0x20 + $0), fnd: [UInt8](repeating: UInt8($0), count: 4)) }
    checkEqual(try! open(simpleFile(nodes: three)).nodes.map(\.id), [0x20, 0x21, 0x22], "nodes read in order up to the terminator")
    checkEqual(try! open(simpleFile(nodes: three, terminator: false)).nodes.count, 3, "zero padding after the last node ends the list")

    // --- transaction log ---
    checkEqual(try! open(simpleFile(nodes: five, committed: 3)).nodes.count, 3, "only committed nodes are read")
    checkEqual(try! open(simpleFile(nodes: five, committed: 5)).nodes.count, 5, "all nodes when all are committed")
    checkEqual(try! open(simpleFile(nodes: five, committed: 0)).nodes.count, 0, "a list committed with zero nodes is empty")
    let beyond = try! open(simpleFile(nodes: five, committed: 9))
    checkEqual(beyond.nodes.count, 5, "a committed count above what exists reads what exists")
    check(beyond.warnings.contains { $0.contains("were committed") }, "…and warns about it")
    let noEntry = try! open(simpleFile(nodes: five))
    checkEqual(noEntry.nodes.count, 5, "a list with no log entry is read to its end")
    check(noEntry.warnings.contains { $0.contains("no committed count") }, "…and warns about it")
    var noLog = simpleFile(nodes: five, committed: 3)
    noLog.replaceSubrange(96..<100, with: le32(0))
    let noLogOpened = try! open(noLog)
    checkEqual(noLogOpened.nodes.count, 5, "an empty transaction log falls back to reading to the end")
    check(noLogOpened.warnings.contains { $0.contains("transaction log is empty") }, "…and warns")
    var badLog = simpleFile(nodes: five, committed: 3)
    badLog.replaceSubrange(160..<168, with: [0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])     // log pointer far past the end
    let badLogOpened = try! open(badLog)
    checkEqual(badLogOpened.nodes.count, 5, "an unreadable transaction log falls back to reading to the end")
    check(badLogOpened.warnings.contains { $0.contains("transaction log unreadable") }, "…and warns")

    // --- fragments ---
    checkEqual(try! open(twoFragmentFile()).nodes.map(\.id), [0x40, 0x41, 0x42, 0x43, 0x44], "fragments are chained in order")
    checkEqual(try! open(twoFragmentFile(committed: 4)).nodes.map(\.id), [0x40, 0x41, 0x42, 0x43], "the committed count spans fragments")
    check(isCorrupt(errorOf(twoFragmentFile(secondListID: 0x11))), "a fragment of another list is corrupt")
    check(isCorrupt(errorOf(twoFragmentFile(loop: true))), "fragments that loop are corrupt, not an endless read")
    var badMagic = simpleFile(nodes: five)
    badMagic[1024 + 64] ^= 0xFF
    check(isCorrupt(errorOf(badMagic)), "a bad fragment magic is corrupt")
    var farRoot = simpleFile(nodes: five)
    farRoot.replaceSubrange(172..<180, with: le32(0x00FF_FFFF) + le32(0))
    check(isTruncated(errorOf(farRoot)), "a root list outside the file is truncated")

    // --- hostile input (Review Focus 1) ---
    fuzz("simple file", simpleFile(nodes: five, committed: 5)) { d in _ = try open(d) }
    fuzz("two fragments", twoFragmentFile()) { d in _ = try open(d) }
}
