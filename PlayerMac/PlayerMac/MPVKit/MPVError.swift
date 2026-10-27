import Foundation

struct MPVError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }

    init(code: Int32, operation: String) {
        message = "\(operation): \(String(cString: mpv_error_string(code)))"
    }

    static func check(_ code: Int32, _ operation: String) throws {
        if code < 0 { throw MPVError(code: code, operation: operation) }
    }
}
