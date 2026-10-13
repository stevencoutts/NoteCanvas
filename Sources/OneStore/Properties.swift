import Foundation

/// A PropertyID as MS-ONE lists it: the 31-bit value including its type bits (the bool bit is not part of it).
public typealias PropertyID = UInt32

public struct JCID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public var description: String { "0x" + String(rawValue, radix: 16) }

    public static let section = JCID(0x0006_0007)
    public static let pageSeries = JCID(0x0006_0008)
    public static let page = JCID(0x0006_000B)
    public static let outline = JCID(0x0006_000C)
    public static let outlineElement = JCID(0x0006_000D)
    public static let richText = JCID(0x0006_000E)
    public static let image = JCID(0x0006_0011)
    public static let numberList = JCID(0x0006_0012)
    public static let outlineGroup = JCID(0x0006_0019)
    public static let table = JCID(0x0006_0022)
    public static let tableRow = JCID(0x0006_0023)
    public static let tableCell = JCID(0x0006_0024)
    public static let title = JCID(0x0006_002C)
    public static let embeddedFile = JCID(0x0006_0035)
    public static let pageManifest = JCID(0x0006_0037)
    public static let paragraphStyle = JCID(0x0012_004D)
}

public enum OneValue: Equatable {
    case none
    case bool(Bool)
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)                    // 4-byte data, also used for floats (see PropertySet.float)
    case u64(UInt64)
    case bytes(Data)                    // length-prefixed data, without the length
    case objectIDs([ExtendedGUID])      // one object ID or an array of them
    case objectSpaceIDs([ExtendedGUID])
    case propertySets([PropertySet])    // an array of property sets, or a single nested one
    case other                          // context IDs; not used
}

public struct OneProperty: Equatable {
    public let id: PropertyID
    public let value: OneValue
    public init(_ id: PropertyID, _ value: OneValue) { self.id = id; self.value = value }
}

public enum OneText {
    /// Decodes UTF-16LE bytes (a trailing odd byte is ignored) and removes trailing NUL characters.
    public static func utf16String(_ data: Data) -> String {
        let n = data.count - data.count % 2
        var units: [UInt16] = []
        units.reserveCapacity(n / 2)
        var i = 0
        while i < n {
            units.append(UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8)
            i += 2
        }
        var s = String(decoding: units, as: UTF16.self)
        while s.last == "\0" { s.removeLast() }
        return s
    }
}

public struct PropertySet: Equatable {
    public let properties: [OneProperty]
    public init(_ properties: [OneProperty] = []) { self.properties = properties }

    public subscript(id: PropertyID) -> OneValue? { properties.first { $0.id == id }?.value }

    public func bool(_ id: PropertyID) -> Bool? { if case .bool(let v)? = self[id] { return v }; return nil }
    public func u8(_ id: PropertyID) -> UInt8? { if case .u8(let v)? = self[id] { return v }; return nil }
    public func u16(_ id: PropertyID) -> UInt16? { if case .u16(let v)? = self[id] { return v }; return nil }
    public func u32(_ id: PropertyID) -> UInt32? { if case .u32(let v)? = self[id] { return v }; return nil }
    public func float(_ id: PropertyID) -> Float? { u32(id).map { Float(bitPattern: $0) } }
    public func data(_ id: PropertyID) -> Data? { if case .bytes(let v)? = self[id] { return v }; return nil }
    public func string(_ id: PropertyID) -> String? { data(id).map(OneText.utf16String) }

    /// An array of little-endian UInt32 stored as length-prefixed bytes (for example TextRunIndex).
    public func u32Array(_ id: PropertyID) -> [UInt32]? {
        guard let d = data(id), d.count % 4 == 0 else { return nil }
        var result: [UInt32] = []
        var i = 0
        while i < d.count {
            let b = d.startIndex + i
            result.append(UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24)
            i += 4
        }
        return result
    }

    public func objectIDs(_ id: PropertyID) -> [ExtendedGUID] { if case .objectIDs(let v)? = self[id] { return v }; return [] }
    public func objectSpaceIDs(_ id: PropertyID) -> [ExtendedGUID] { if case .objectSpaceIDs(let v)? = self[id] { return v }; return [] }
    public func propertySets(_ id: PropertyID) -> [PropertySet] { if case .propertySets(let v)? = self[id] { return v }; return [] }
}
