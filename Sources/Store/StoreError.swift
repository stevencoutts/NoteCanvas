import Foundation

public enum StoreError: Error, Equatable {
    case alreadyExists
    case notAPackage
    case corruptManifest
    case unsupportedVersion(Int)
    case noSuchSection
    case missingPage(UUID)
    case corruptPage(UUID)
    case invalidAssetName
    /// The notebook is encrypted and was opened without a key.
    case encrypted
    /// The key does not open this notebook's manifest.
    case wrongKey
    case alreadyEncrypted
    /// Reading the encrypted copy back did not match the original, so the notebook was left as it was.
    case verifyFailed
    /// A locked section was used without its key. Unlock it first.
    case sectionLocked(UUID)
    /// The notebook has to be encrypted before a section can be locked.
    case notEncrypted
    /// Locking was interrupted earlier. Finish or undo it before locking again.
    case lockInterrupted
}
