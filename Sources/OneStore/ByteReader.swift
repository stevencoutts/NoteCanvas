import Foundation

/// Bounds-checked little-endian reads over a Data buffer. Offsets are relative to the start of the data (so a
/// slice with a non-zero startIndex works), and every read throws `truncated` instead of trapping.
struct ByteReader {
    let data: Data
    init(_ data: Data) { self.data = data }
    var count: Int { data.count }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw OneStoreError.truncated(offset: offset)
        }
    }

    func u8(_ o: Int) throws -> UInt8 {
        try check(o, 1)
        return data[data.startIndex + o]
    }

    func u16(_ o: Int) throws -> UInt16 {
        try check(o, 2)
        let b = data.startIndex + o
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }

    func u32(_ o: Int) throws -> UInt32 {
        try check(o, 4)
        let b = data.startIndex + o
        let b0 = UInt32(data[b]), b1 = UInt32(data[b + 1]), b2 = UInt32(data[b + 2]), b3 = UInt32(data[b + 3])
        return b0 | b1 << 8 | b2 << 16 | b3 << 24
    }

    func u64(_ o: Int) throws -> UInt64 {
        try check(o, 8)
        let b = data.startIndex + o
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(data[b + i]) }
        return v
    }

    /// A slice that shares storage with the original data (no copy). Its indices start at `startIndex + o`.
    func slice(_ o: Int, _ n: Int) throws -> Data {
        try check(o, n)
        let s = data.startIndex + o
        return data[s..<s + n]
    }
}
