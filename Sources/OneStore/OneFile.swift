import Foundation

public struct FileDataReference: Equatable {
    public let target: String           // "<ifndf>{GUID}" for data inside this file; "<file>…" and "<invfdo>" are not read
    public let extensionText: String    // for example ".png"
    public init(target: String, extensionText: String) { self.target = target; self.extensionText = extensionText }
}

public struct OneObject {
    public let id: ExtendedGUID
    public let jcid: JCID
    public let properties: PropertySet
    public let fileData: FileDataReference?
    public init(id: ExtendedGUID, jcid: JCID, properties: PropertySet, fileData: FileDataReference?) {
        self.id = id; self.jcid = jcid; self.properties = properties; self.fileData = fileData
    }
}

public struct Revision {
    public let id: ExtendedGUID
    public let dependent: ExtendedGUID?
    public let role: UInt32
    public let roots: [UInt32: ExtendedGUID]        // root role -> root object
    public let declared: [ExtendedGUID: OneObject]  // objects declared by this revision (not its dependencies)
    public init(id: ExtendedGUID, dependent: ExtendedGUID?, role: UInt32, roots: [UInt32: ExtendedGUID],
                declared: [ExtendedGUID: OneObject]) {
        self.id = id; self.dependent = dependent; self.role = role; self.roots = roots; self.declared = declared
    }
}

public struct ObjectSpace {
    public let id: ExtendedGUID
    public let revisions: [Revision]
    public init(id: ExtendedGUID, revisions: [Revision]) { self.id = id; self.revisions = revisions }

    /// The objects visible at `revision`: its own declarations laid over those of the revisions it depends on.
    public func objects(at revision: Revision) -> [ExtendedGUID: OneObject] {
        var byID: [ExtendedGUID: Revision] = [:]
        for r in revisions { byID[r.id] = r }
        var chain: [Revision] = []
        var seen = Set<ExtendedGUID>()
        var current: Revision? = revision
        while let r = current, seen.insert(r.id).inserted {
            chain.append(r)
            current = r.dependent.flatMap { byID[$0] }
        }
        var result: [ExtendedGUID: OneObject] = [:]
        for r in chain.reversed() { result.merge(r.declared) { _, newer in newer } }
        return result
    }

    /// The root object of `revision` for `role` (1 is the default root), or nil.
    public func rootObject(of revision: Revision, role: UInt32 = 1) -> OneObject? {
        guard let id = revision.roots[role] else { return nil }
        return revision.declared[id] ?? objects(at: revision)[id]
    }
}

/// What the importer needs from a file; lets tests supply an in-memory graph instead of bytes.
public protocol OneSource {
    var objectSpaces: [ObjectSpace] { get }
    var warnings: [String] { get }
    func fileData(for object: OneObject) -> (data: Data, ext: String)?
}

public struct OneFile: OneSource {
    public let objectSpaces: [ObjectSpace]
    public let warnings: [String]
    private let reader: ByteReader
    private let fileDataStore: [GUID: ChunkRef]
    private static let fileDataHeader = GUID(string: "{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}")!

    /// Parses a `.one` file. Throws `OneStoreError` for a damaged or unsupported file; anything inside the file
    /// that cannot be read (a bad object, an unresolvable ID) is skipped and reported in `warnings` instead.
    public init(data: Data) throws {
        let store = try OpenedStore(data)
        let builder = StoreBuilder(store: store)
        try builder.run()
        self.objectSpaces = builder.finish()
        self.warnings = builder.warnings
        self.reader = store.reader
        self.fileDataStore = builder.fileDataStore
    }

    /// The bytes of a file data object (an image or attachment) and its lower-case extension, or nil.
    public func fileData(for object: OneObject) -> (data: Data, ext: String)? {
        guard let ref = object.fileData, ref.target.hasPrefix("<ifndf>"),
              let guid = GUID(string: String(ref.target.dropFirst(7))),
              let chunk = fileDataStore[guid], chunk.stp <= UInt64(reader.count) else { return nil }
        let o = Int(chunk.stp)
        do {
            guard try GUID(reader, at: o) == Self.fileDataHeader else { return nil }
            let length = try reader.u64(o + 16)
            guard length <= UInt64(reader.count) else { return nil }
            let bytes = try reader.slice(o + 36, Int(length))       // header 16 + length 8 + unused 4 + reserved 8
            let ext = ref.extensionText.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (bytes, ext)
        } catch {
            return nil
        }
    }
}

/// Walks the node lists once, in order, building object spaces, revisions, global ID tables and objects.
final class StoreBuilder {
    final class RevisionBuilder {
        let id: ExtendedGUID
        let dependent: ExtendedGUID?
        let role: UInt32
        var idTable: [UInt32: GUID] = [:]
        var roots: [UInt32: ExtendedGUID] = [:]
        var declared: [ExtendedGUID: OneObject] = [:]
        var unresolved = 0
        init(id: ExtendedGUID, dependent: ExtendedGUID?, role: UInt32) { self.id = id; self.dependent = dependent; self.role = role }

        /// A CompactID is an index into the global ID table (high 24 bits) and a counter n (low 8 bits).
        func resolve(_ compact: UInt32) -> ExtendedGUID {
            let n = compact & 0xFF, index = compact >> 8
            if let g = idTable[index] { return ExtendedGUID(guid: g, n: n) }
            unresolved += 1
            return ExtendedGUID(guid: .zero, n: n)
        }
    }

    static let maxWarnings = 100
    let store: OpenedStore
    var r: ByteReader { store.reader }
    var warnings: [String]
    var spaceOrder: [ExtendedGUID] = []
    var spaces: [ExtendedGUID: [RevisionBuilder]] = [:]
    var fileDataStore: [GUID: ChunkRef] = [:]
    var currentSpace: ExtendedGUID?
    var currentRevision: RevisionBuilder?
    var visited = Set<UInt64>()

    init(store: OpenedStore) { self.store = store; self.warnings = store.warnings }

    func warn(_ message: String) { if warnings.count < Self.maxWarnings { warnings.append(message) } }

    func run() throws {
        var w: [String] = []
        let root = try store.rootNodes(warnings: &w)
        w.forEach(warn)
        process(root, depth: 0)
        let unresolved = spaces.values.joined().reduce(0) { $0 + $1.unresolved }
        if unresolved > 0 { warn("\(unresolved) object references could not be resolved through their global ID table") }
    }

    func finish() -> [ObjectSpace] {
        spaceOrder.map { id in
            ObjectSpace(id: id, revisions: (spaces[id] ?? []).map { b in
                Revision(id: b.id, dependent: b.dependent, role: b.role, roots: b.roots, declared: b.declared)
            })
        }
    }

    /// Errors inside one node are reported and skipped so one bad object never loses the rest of the file.
    func process(_ nodes: [FileNode], depth: Int) {
        for node in nodes {
            do { try handle(node, depth: depth) }
            catch { warn("node 0x\(String(node.id, radix: 16)) at offset \(node.offset): \(error)") }
        }
    }

    private func handle(_ node: FileNode, depth: Int) throws {
        guard depth < 32 else { throw OneStoreError.corrupt(offset: node.offset, reason: "file node lists are nested too deeply") }
        switch node.id {
        case 0x0C:                                           // ObjectSpaceManifestListStartFND
            let id = try ExtendedGUID(r, at: node.fnd)
            currentSpace = id; currentRevision = nil
            if spaces[id] == nil { spaces[id] = []; spaceOrder.append(id) }
        case 0x1E, 0x1F:                                     // RevisionManifestStart6/7FND
            guard let space = currentSpace else { throw OneStoreError.corrupt(offset: node.offset, reason: "revision outside an object space") }
            let rid = try ExtendedGUID(r, at: node.fnd)
            let dep = try ExtendedGUID(r, at: node.fnd + 20)
            let role = try r.u32(node.fnd + 40)
            let rev = RevisionBuilder(id: rid, dependent: dep.guid.isZero ? nil : dep, role: role)
            spaces[space, default: []].append(rev)
            currentRevision = rev
        case 0x22:                                           // GlobalIdTableStart2FND
            currentRevision?.idTable = [:]
        case 0x24:                                           // GlobalIdTableEntryFNDX
            guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "ID table entry outside a revision") }
            let index = try r.u32(node.fnd)
            rev.idTable[index] = try GUID(r, at: node.fnd + 4)
        case 0x5A:                                           // RootObjectReference3FND
            guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "root reference outside a revision") }
            let role = try r.u32(node.fnd + 20)
            rev.roots[role] = try ExtendedGUID(r, at: node.fnd)
        case 0xA4, 0xA5, 0xC4, 0xC5:                         // object declarations
            try declareObject(node)
        case 0x72, 0x73:                                     // ObjectDeclarationFileData3(Large)RefCountFND
            try declareFileData(node)
        case 0x94:                                           // FileDataStoreObjectReferenceFND
            let (ref, next) = try node.chunkRef(r)
            fileDataStore[try GUID(r, at: next)] = ref
        default:
            break
        }
        if node.baseType == 2 {                              // a reference to another node list
            let (ref, _) = try node.chunkRef(r)
            guard !ref.isNil, visited.insert(ref.stp).inserted else { return }
            var w: [String] = []
            let nested = try store.lists.nodes(from: ref, warnings: &w)
            w.forEach(warn)
            process(nested, depth: depth + 1)
        }
    }

    private func declareObject(_ node: FileNode) throws {
        guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "object declared outside a revision") }
        let (blob, after) = try node.chunkRef(r)
        let oidRaw = try r.u32(after)
        let jcidRaw = try r.u32(after + 4)
        guard !blob.isNil, !blob.isZero, blob.stp < UInt64(r.count) else {
            throw OneStoreError.corrupt(offset: node.offset, reason: "object has no property data")
        }
        let props = try ObjectBlob.read(r, at: Int(blob.stp)) { rev.resolve($0) }
        let id = rev.resolve(oidRaw)
        rev.declared[id] = OneObject(id: id, jcid: JCID(jcidRaw), properties: props, fileData: nil)
    }

    private func declareFileData(_ node: FileNode) throws {
        guard let rev = currentRevision else { throw OneStoreError.corrupt(offset: node.offset, reason: "file data declared outside a revision") }
        let oidRaw = try r.u32(node.fnd)
        let jcidRaw = try r.u32(node.fnd + 4)
        let afterCount = node.fnd + 8 + (node.id == 0x73 ? 4 : 1)    // the reference count is 1 byte, or 4 for the Large form
        let (target, afterTarget) = try readString(at: afterCount, within: node)
        let (ext, _) = try readString(at: afterTarget, within: node)
        let id = rev.resolve(oidRaw)
        rev.declared[id] = OneObject(id: id, jcid: JCID(jcidRaw), properties: PropertySet(),
                                     fileData: FileDataReference(target: target, extensionText: ext))
    }

    /// A StringInStorageBuffer: a 4-byte character count followed by UTF-16 characters.
    private func readString(at o: Int, within node: FileNode) throws -> (String, Int) {
        guard o + 4 <= node.end else { throw OneStoreError.corrupt(offset: o, reason: "string runs past its file node") }
        let cch = Int(try r.u32(o))
        guard cch <= (node.end - o - 4) / 2 else { throw OneStoreError.corrupt(offset: o, reason: "string runs past its file node") }
        return (OneText.utf16String(try r.slice(o + 4, cch * 2)), o + 4 + cch * 2)
    }
}
