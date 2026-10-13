import Foundation
import OneStore

/// What an import did, in counts only: nothing here is note content.
public struct ImportReport: Codable, Equatable {
    public var pagesTotal = 0
    public var pagesImported = 0
    public var pagesFailed = 0
    public var cancelled = false
    public var objectsImported: [String: Int] = [:]        // "text", "paragraph", "image", "table", "attachment"
    public var skippedObjectTypes: [String: Int] = [:]     // JCID in hex -> count
    public var ignoredProperties: [String: Int] = [:]      // PropertyID in hex -> count
    public var approximations: [String: Int] = [:]         // named approximations -> count
    public var warnings: [String] = []

    public init() {}

    mutating func imported(_ kind: String, _ n: Int = 1) { objectsImported[kind, default: 0] += n }
    mutating func skipped(_ jcid: JCID) { skippedObjectTypes[jcid.description, default: 0] += 1 }
    mutating func ignored(_ id: PropertyID) { ignoredProperties["0x" + String(id, radix: 16), default: 0] += 1 }
    mutating func approximated(_ key: String, _ n: Int = 1) { approximations[key, default: 0] += n }

    /// Counts every property of `object` that the importer does not read.
    mutating func noteIgnoredProperties(of object: OneObject, consumed: Set<PropertyID>) {
        for p in object.properties.properties where !consumed.contains(p.id) { ignored(p.id) }
    }

    mutating func merge(_ other: ImportReport) {
        pagesTotal += other.pagesTotal; pagesImported += other.pagesImported; pagesFailed += other.pagesFailed
        cancelled = cancelled || other.cancelled
        for (k, v) in other.objectsImported { objectsImported[k, default: 0] += v }
        for (k, v) in other.skippedObjectTypes { skippedObjectTypes[k, default: 0] += v }
        for (k, v) in other.ignoredProperties { ignoredProperties[k, default: 0] += v }
        for (k, v) in other.approximations { approximations[k, default: 0] += v }
        warnings += other.warnings
    }
}
