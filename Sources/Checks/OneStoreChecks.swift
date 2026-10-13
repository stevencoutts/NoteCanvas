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

func oneStoreObjectChecks() {
    let space = (guid: "{AAAAAAAA-0000-0000-0000-000000000001}", n: UInt32(1))
    let g1 = "{11111111-1111-1111-1111-111111111111}", g2 = "{22222222-2222-2222-2222-222222222222}"
    let g3 = "{33333333-3333-3333-3333-333333333333}"
    func id(_ g: String, _ n: UInt32) -> ExtendedGUID { ExtendedGUID(guid: GUID(string: g)!, n: n) }
    let float15 = le32(Float(1.5).bitPattern)
    let text = "Hi 😀"
    let textBlob = le32(UInt32(utf16le(text).count + 2)) + utf16le(text) + [0, 0]           // UTF-16LE with a trailing NUL

    let A = FxObject(oid: compact(1, 1), jcid: 0x60037,
                     props: [FxProp(pid: 0x24001C1F, data: le32(2)),                         // array of 2 object IDs
                             FxProp(pid: 0x2C001D63, data: le32(2))],                        // array of 2 object-space IDs
                     oids: [compact(1, 2), compact(2, 3)], osids: [compact(1, 7), compact(2, 8)])
    let B = FxObject(oid: compact(1, 2), jcid: 0x6000C,
                     props: [FxProp(pid: 0x08001C04 | 0x8000_0000),                          // Bold = true (bool bit set)
                             FxProp(pid: 0x0C001C03, data: [3]),                             // u8
                             FxProp(pid: 0x10001C0B, data: le16(22)),                        // u16
                             FxProp(pid: 0x14001C14, data: float15),                         // 4 bytes (a float)
                             FxProp(pid: 0x1C001C22, data: textBlob),                        // length-prefixed bytes
                             FxProp(pid: 0x1400348B, data: le32(7)),                         // an undocumented property
                             FxProp(pid: 0x20001C3F)],                                       // one object ID
                     oids: [compact(2, 9)])
    let E = FxObject(oid: compact(1, 4), jcid: 0x00AB_CDEF,                                  // a JCID MS-ONE does not list
                     props: [FxProp(pid: 0x40003489,                                         // array of property sets
                                    data: le32(2) + le32(0x44000000)
                                        + setBytes([FxProp(pid: 0x08001C04 | 0x8000_0000)])
                                        + setBytes([FxProp(pid: 0x0C001C03, data: [5])])),
                             FxProp(pid: 0x44001235, data: setBytes([FxProp(pid: 0x10001C0B, data: le16(9))]))])  // nested set
    let rev1 = FxRevision(rid: (g1, 100), idTable: [(1, g1), (2, g2)],
                          roots: [(1, g1, 1)], objects: [A, B, E])
    var B2 = B
    B2.props[0] = FxProp(pid: 0x08001C04)                                                    // Bold = false in the later revision
    B2.props[2] = FxProp(pid: 0x10001C0B, data: le16(30))
    let D = FxObject(oid: compact(3, 1), jcid: 0x6000D, props: [])
    let rev2 = FxRevision(rid: (g2, 101), dependent: (g1, 100), idTable: [(1, g1), (2, g2), (3, g3)],
                          roots: [(1, g1, 1)], objects: [B2, D])

    let data = buildStore(FxFile(), space: space, revisions: [rev1, rev2])
    let file = try! OneFile(data: data)
    checkEqual(file.objectSpaces.count, 1, "one object space")
    guard let sp = file.objectSpaces.first, sp.revisions.count == 2 else { check(false, "two revisions"); return }
    checkEqual(sp.id, id(space.guid, space.n), "object space id")
    checkEqual(sp.revisions[1].dependent, id(g1, 100), "the second revision depends on the first")
    checkEqual(sp.revisions[0].dependent, nil, "the first revision has no dependency")
    checkEqual(sp.revisions[0].roots[1], id(g1, 1), "root references are read")

    let at1 = sp.objects(at: sp.revisions[0]), at2 = sp.objects(at: sp.revisions[1])
    checkEqual(at1.count, 3, "first revision shows its three objects")
    checkEqual(at2.count, 4, "second revision overlays: A, E from the first; B2, D from the second")
    let b1 = at1[id(g1, 2)]!, b2 = at2[id(g1, 2)]!
    checkEqual(b1.properties.bool(0x08001C04), true, "Bold true in revision 1")
    checkEqual(b2.properties.bool(0x08001C04), false, "Bold false overrides in revision 2")
    checkEqual(b1.properties.u16(0x10001C0B), 22, "u16 property")
    checkEqual(b2.properties.u16(0x10001C0B), 30, "overridden u16 property")
    checkEqual(b1.properties.u8(0x0C001C03), 3, "u8 property")
    checkEqual(b1.properties.float(0x14001C14), 1.5, "4-byte property reads as a float")
    checkEqual(b1.properties.string(0x1C001C22), text, "UTF-16 text with surrogates; the trailing NUL is dropped")
    checkEqual(b1.properties.u32(0x1400348B), 7, "an undocumented property is kept")
    checkEqual(b1.properties.objectIDs(0x20001C3F), [id(g2, 9)], "a single object ID resolves through the global ID table")
    checkEqual(sp.rootObject(of: sp.revisions[1])?.jcid, .pageManifest, "rootObject follows the dependency chain")

    let a = at1[id(g1, 1)]!
    checkEqual(a.jcid, .pageManifest, "jcid is read")
    checkEqual(a.properties.objectIDs(0x24001C1F), [id(g1, 2), id(g2, 3)], "an array of object IDs resolves in order")
    checkEqual(a.properties.objectSpaceIDs(0x2C001D63), [id(g1, 7), id(g2, 8)], "object-space IDs resolve through the table")
    let e = at1[id(g1, 4)]!
    checkEqual(e.jcid, JCID(0x00AB_CDEF), "an unknown JCID is kept")
    let sets = e.properties.propertySets(0x40003489)
    checkEqual(sets.count, 2, "an array of property sets")
    checkEqual(sets[0].bool(0x08001C04), true, "first element")
    checkEqual(sets[1].u8(0x0C001C03), 5, "second element")
    checkEqual(e.properties.propertySets(0x44001235).first?.u16(0x10001C0B), 9, "a nested property set")
    check(file.warnings.isEmpty, "a well-formed file produces no warnings: \(file.warnings)")

    // An unresolvable reference does not abort the read; it is reported.
    let dangling = FxObject(oid: compact(1, 1), jcid: 0x6000B, props: [FxProp(pid: 0x20001C3F)], oids: [compact(9, 1)])
    let danglingData = buildStore(FxFile(), space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1)], roots: [(1, g1, 1)], objects: [dangling])])
    let df = try! OneFile(data: danglingData)
    check(df.warnings.contains { $0.contains("could not be resolved") }, "an unresolved ID is reported as a warning")

    // A property set that refers to more objects than its stream holds is skipped, not fatal.
    var tooMany = A; tooMany.oids = [compact(1, 2)]
    let tooManyData = buildStore(FxFile(), space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1), (2, g2)], roots: [(1, g1, 1)], objects: [tooMany, B])])
    let tm = try! OneFile(data: tooManyData)
    check(tm.warnings.contains { $0.contains("more objects") }, "an object with a short object stream is reported")
    checkEqual(tm.objectSpaces[0].objects(at: tm.objectSpaces[0].revisions[0]).count, 1, "…and the other object is still read")

    // File data: reference string, store entry and payload.
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5]
    let fdFile = FxFile()
    let payload = fdFile.blob(fileDataObject(png))
    let storeList = fdFile.list([refNode(0x94, base: 1, ref: payload, extra: guidBytes("{CCCCCCCC-1111-2222-3333-444444444444}"))])
    let pic = fileDataDeclNode(oid: compact(1, 5), jcid: 0x80039, target: "<ifndf>{CCCCCCCC-1111-2222-3333-444444444444}", ext: ".PNG")
    let missing = fileDataDeclNode(oid: compact(1, 6), jcid: 0x80039, target: "<ifndf>{DDDDDDDD-1111-2222-3333-444444444444}", ext: ".png")
    let external = fileDataDeclNode(oid: compact(1, 7), jcid: 0x80039, target: "<file>C:\\x.png", ext: ".png")
    let fdData = buildStore(fdFile, space: space, revisions: [
        FxRevision(rid: (g1, 1), idTable: [(1, g1)], roots: [(1, g1, 1)], objects: [], extraNodes: [pic, missing, external])],
        rootExtra: [refNode(0x90, base: 2, ref: storeList)])
    let ff = try! OneFile(data: fdData)
    let fobjs = ff.objectSpaces[0].objects(at: ff.objectSpaces[0].revisions[0])
    let got = ff.fileData(for: fobjs[id(g1, 5)]!)
    checkEqual(got.map { Array($0.data) }, png, "file data payload is found through its store entry")
    checkEqual(got?.ext, "png", "the extension is lower-cased and loses its dot")
    check(ff.fileData(for: fobjs[id(g1, 6)]!) == nil, "a reference with no store entry has no data")
    check(ff.fileData(for: fobjs[id(g1, 7)]!) == nil, "an external file reference is not read")
    check(ff.fileData(for: OneObject(id: id(g1, 99), jcid: .richText, properties: PropertySet(), fileData: nil)) == nil,
          "an object that is not file data has no data")

    // GUID(string:) accepts ASCII hex digits only and never traps.
    let fullwidth = String(repeating: "\u{FF11}", count: 32)
    check(GUID(string: fullwidth) == nil, "fullwidth hex digits are not a GUID")
    check(GUID(string: "{" + fullwidth + "}") == nil, "braced fullwidth hex digits are not a GUID")
    check(GUID(string: String(repeating: "1", count: 31)) == nil, "31 digits are not a GUID")
    check(GUID(string: String(repeating: "1", count: 33)) == nil, "33 digits are not a GUID")
    check(GUID(string: "") == nil, "an empty string is not a GUID")
    check(GUID(string: String(repeating: "1", count: 31) + "G") == nil, "a non-hex letter is not a GUID")
    check(GUID(string: String(repeating: "a", count: 31) + "F") != nil, "mixed-case ASCII digits parse")
    let hostile = OneObject(id: id(g1, 98), jcid: .embeddedFile, properties: PropertySet(),
                            fileData: FileDataReference(target: "<ifndf>{" + fullwidth + "}", extensionText: ".png"))
    check(ff.fileData(for: hostile) == nil, "a file data target with non-ASCII digits has no data and does not trap")

    // Hostile input (Review Focus 1): every truncation and byte corruption either parses or throws OneStoreError.
    fuzz("object file", data, step: 3) { d in _ = try OneFile(data: d) }
    fuzz("file data file", fdData, step: 3) { d in
        let f = try OneFile(data: d)
        for s in f.objectSpaces { for r in s.revisions { for o in r.declared.values { _ = f.fileData(for: o) } } }
    }
}

/// Opt-in check against real files: set ONE_CORPUS_DIR to a folder of .one files. Prints aggregate counts only.
func corpusChecks() {
    guard let dir = ProcessInfo.processInfo.environment["ONE_CORPUS_DIR"] else { return }
    guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.fileSizeKey]) else {
        check(false, "ONE_CORPUS_DIR is not readable"); return
    }
    var files = 0, parsed = 0, failed = 0, withPages = 0, pages = 0, withWarnings = 0
    var errorKinds: [String: Int] = [:]
    for case let url as URL in walker where url.pathExtension == "one" {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else { continue }
        files += 1
        do {
            let file = try OneFile(data: Data(contentsOf: url, options: .mappedIfSafe))
            parsed += 1
            if !file.warnings.isEmpty { withWarnings += 1 }
            let n = file.objectSpaces.filter { s in s.revisions.contains { s.rootObject(of: $0)?.jcid == .pageManifest } }.count
            pages += n
            if n > 0 { withPages += 1 }
        } catch {
            failed += 1
            errorKinds["\(error)".prefix(40).description, default: 0] += 1
        }
    }
    print("corpus: files=\(files) parsed=\(parsed) failed=\(failed) withPages=\(withPages) pageSpaces=\(pages) filesWithWarnings=\(withWarnings) errors=\(errorKinds)")
    check(failed == 0, "every corpus file parses")
}
