import OneStore

/// A snapshot of the objects visible at one revision, with child lookup.
struct ObjectGraph {
    let objects: [ExtendedGUID: OneObject]

    func object(_ id: ExtendedGUID) -> OneObject? { objects[id] }

    /// The objects an object-ID property refers to; IDs with no object are counted in the report and skipped.
    func children(of parent: OneObject, _ id: PropertyID, report: inout ImportReport) -> [OneObject] {
        var result: [OneObject] = []
        for oid in parent.properties.objectIDs(id) {
            if let o = objects[oid] { result.append(o) } else { report.approximated("unresolvedReference") }
        }
        return result
    }
}
