import Foundation

public enum StoreError: Error, Equatable {
    case alreadyExists
    case notAPackage
    case corruptManifest
    case unsupportedVersion(Int)
    case noSuchSection
    case missingPage(UUID)
    case corruptPage(UUID)
}
