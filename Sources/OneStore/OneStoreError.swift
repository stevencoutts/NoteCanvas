import Foundation

public enum OneStoreError: Error, Equatable {
    case notAOneFile
    case unsupportedFileType
    case unsupportedVersion(UInt32)
    case truncated(offset: Int)
    case corrupt(offset: Int, reason: String)
}
