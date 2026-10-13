import Foundation

var failures = 0

func check(_ ok: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !ok { failures += 1; print("FAIL \(file):\(line): \(msg)") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    if actual != expected {
        failures += 1
        print("FAIL \(file):\(line): \(msg) expected \(expected), got \(actual)")
    }
}

/// Returns the thrown error, or nil (recording a failure) when `body` did not throw.
@discardableResult
func checkThrows<T>(_ msg: String, file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        failures += 1
        print("FAIL \(file):\(line): \(msg) did not throw")
        return nil
    } catch {
        return error
    }
}
