import Foundation

public struct GUID: Hashable, Sendable {
    public let hi: UInt64        // the 16 bytes as stored in the file, as two big-endian words (used for identity only)
    public let lo: UInt64
    public static let zero = GUID(hi: 0, lo: 0)
    public init(hi: UInt64, lo: UInt64) { self.hi = hi; self.lo = lo }
    public var isZero: Bool { hi == 0 && lo == 0 }

    init(_ r: ByteReader, at o: Int) throws {
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<8 { let byte = try r.u8(o + i); h = h << 8 | UInt64(byte) }
        for i in 8..<16 { let byte = try r.u8(o + i); l = l << 8 | UInt64(byte) }
        self.hi = h; self.lo = l
    }

    /// Parses "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" (braces and dashes optional) into file byte order.
    public init?(string: String) {
        let s = string.filter { $0 != "{" && $0 != "}" && $0 != "-" }
        guard s.count == 32, s.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(s)
        var b: [UInt8] = []
        for i in 0..<16 { b.append(UInt8(String(chars[2 * i...2 * i + 1]), radix: 16)!) }
        let f = Array(b[0..<4].reversed()) + Array(b[4..<6].reversed()) + Array(b[6..<8].reversed()) + Array(b[8..<16])
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<8 { h = h << 8 | UInt64(f[i]) }
        for i in 8..<16 { l = l << 8 | UInt64(f[i]) }
        self.hi = h; self.lo = l
    }
}

public struct ExtendedGUID: Hashable, Sendable {
    public let guid: GUID
    public let n: UInt32
    public init(guid: GUID, n: UInt32) { self.guid = guid; self.n = n }
    init(_ r: ByteReader, at o: Int) throws {
        guid = try GUID(r, at: o)
        n = try r.u32(o + 16)
    }
}
