import Foundation

/// Hands out the CompactIDs of an object stream in the order property values consume them.
struct IDStream {
    var items: [UInt32]
    var next = 0
    mutating func take(_ n: Int, at offset: Int) throws -> [UInt32] {
        guard n >= 0, n <= items.count - next else {
            throw OneStoreError.corrupt(offset: offset, reason: "property set refers to more objects than its object stream holds")
        }
        defer { next += n }
        return Array(items[next..<next + n])
    }
}

/// Reads an ObjectSpaceObjectPropSet: the object-ID streams followed by a PropertySet.
enum ObjectBlob {
    static func read(_ r: ByteReader, at start: Int, resolve: (UInt32) -> ExtendedGUID) throws -> PropertySet {
        var o = start
        let oids = try readStream(r, &o)
        var osids: [UInt32] = []
        if !oids.osidAbsent {
            let s = try readStream(r, &o)
            osids = s.ids
            if s.extended { _ = try readStream(r, &o) }       // context IDs are not used
        }
        var oidStream = IDStream(items: oids.ids)
        var osidStream = IDStream(items: osids)
        return try readSet(r, &o, &oidStream, &osidStream, resolve, depth: 0)
    }

    private static func readStream(_ r: ByteReader, _ o: inout Int) throws -> (ids: [UInt32], extended: Bool, osidAbsent: Bool) {
        let h = try r.u32(o)
        let count = Int(h & 0xFF_FFFF)
        guard count <= (r.count - o - 4) / 4 else { throw OneStoreError.corrupt(offset: o, reason: "object stream is longer than the file") }
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        for i in 0..<count { ids.append(try r.u32(o + 4 + 4 * i)) }
        o += 4 + 4 * count
        return (ids, (h >> 30) & 1 == 1, (h >> 31) & 1 == 1)
    }

    private static func readSet(_ r: ByteReader, _ o: inout Int, _ oids: inout IDStream, _ osids: inout IDStream,
                                _ resolve: (UInt32) -> ExtendedGUID, depth: Int) throws -> PropertySet {
        guard depth < 16 else { throw OneStoreError.corrupt(offset: o, reason: "property sets are nested too deeply") }
        let n = Int(try r.u16(o))
        o += 2
        guard n <= (r.count - o) / 4 else { throw OneStoreError.truncated(offset: o) }
        var pids: [UInt32] = []
        pids.reserveCapacity(n)
        for i in 0..<n { pids.append(try r.u32(o + 4 * i)) }
        o += 4 * n
        var props: [OneProperty] = []
        props.reserveCapacity(n)
        for pid in pids {
            let type = Int((pid >> 26) & 0x1F)
            let key = pid & 0x7FFF_FFFF
            let value: OneValue
            switch type {
            case 1:
                value = .none
            case 2:
                value = .bool(pid >> 31 == 1)
            case 3:
                value = .u8(try r.u8(o)); o += 1
            case 4:
                value = .u16(try r.u16(o)); o += 2
            case 5:
                value = .u32(try r.u32(o)); o += 4
            case 6:
                value = .u64(try r.u64(o)); o += 8
            case 7:
                let cb = Int(try r.u32(o))
                guard cb < 0x4000_0000 else { throw OneStoreError.corrupt(offset: o, reason: "property data length is out of range") }
                value = .bytes(try r.slice(o + 4, cb)); o += 4 + cb
            case 8:
                value = .objectIDs(try oids.take(1, at: o).map(resolve))
            case 9:
                let count = Int(try r.u32(o)); o += 4
                value = .objectIDs(try oids.take(count, at: o).map(resolve))
            case 0xA:
                value = .objectSpaceIDs(try osids.take(1, at: o).map(resolve))
            case 0xB:
                let count = Int(try r.u32(o)); o += 4
                value = .objectSpaceIDs(try osids.take(count, at: o).map(resolve))
            case 0xC:
                value = .other
            case 0xD:
                _ = try r.u32(o); o += 4
                value = .other
            case 0x10:
                let count = Int(try r.u32(o)); o += 4
                var sets: [PropertySet] = []
                if count > 0 {
                    guard count <= (r.count - o) / 2 else { throw OneStoreError.truncated(offset: o) }
                    _ = try r.u32(o); o += 4                       // the element PropertyID (type 0x11)
                    for _ in 0..<count { sets.append(try readSet(r, &o, &oids, &osids, resolve, depth: depth + 1)) }
                }
                value = .propertySets(sets)
            case 0x11:
                value = .propertySets([try readSet(r, &o, &oids, &osids, resolve, depth: depth + 1)])
            default:
                throw OneStoreError.corrupt(offset: o, reason: "unknown property type \(type)")
            }
            props.append(OneProperty(key, value))
        }
        return PropertySet(props)
    }
}
