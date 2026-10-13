import Foundation
import CoreFoundation

enum CharsetDecoder {
    /// CFStringEncoding values for the character sets MS-ONE's Charset property can name (section 2.3).
    private static let cfEncodings: [UInt8: UInt32] = [
        0: 0x0500, 1: 0x0500, 2: 0x0500,     // ANSI, default and symbol: Windows Latin 1 (1252)
        128: 0x0420,                          // Shift-JIS (932)
        129: 0x0422,                          // Hangul (949)
        130: 0x0510,                          // Johab (1361)
        134: 0x0421,                          // GB2312 (936)
        136: 0x0423,                          // Big5 (950)
        161: 0x0503,                          // Greek (1253)
        162: 0x0504,                          // Turkish (1254)
        163: 0x0508,                          // Vietnamese (1258)
        177: 0x0505,                          // Hebrew (1255)
        178: 0x0506,                          // Arabic (1256)
        186: 0x0507,                          // Baltic (1257)
        204: 0x0502,                          // Russian (1251)
        222: 0x041D,                          // Thai (874)
        238: 0x0501,                          // Eastern European (1250)
        255: 0x0400,                          // OEM: DOS Latin US (437)
    ]

    private static func encoding(cf raw: UInt32) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(raw))
    }

    /// Decodes 8-bit text with the named charset (nil means ANSI). `usedFallback` is true when the charset is unknown
    /// or the bytes were not valid in it, in which case Windows-1252 (then ISO Latin 1) is used. Trailing NULs are removed.
    static func decode(_ data: Data, charset: UInt8?) -> (text: String, usedFallback: Bool) {
        let code = charset ?? 0
        var known = true
        var encoding: String.Encoding?
        if code == 77 { encoding = .macOSRoman }
        else if let raw = cfEncodings[code] { encoding = Self.encoding(cf: raw) }
        else { known = false }
        var result: String?
        var fallback = !known
        if let encoding, let s = String(data: data, encoding: encoding) { result = s }
        if result == nil {
            fallback = true
            result = String(data: data, encoding: Self.encoding(cf: 0x0500)) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        var text = result ?? ""
        while text.last == "\0" { text.removeLast() }
        return (text, fallback)
    }
}

enum ColorRef {
    /// A COLORREF (0x00BBGGRR) as "#RRGGBB"; nil for the automatic colour (0xFF000000) or an invalid value.
    static func hex(_ v: UInt32) -> String? {
        guard v <= 0x00FF_FFFF else { return nil }
        return String(format: "#%02X%02X%02X", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF)
    }
}
