// A minimal XCTest stand-in so PortwayCore's tests run where XCTest cannot load (Command Line
// Tools only, or an Xcode whose licence is not yet accepted). Same test file, same assertions;
// `swift test` or Xcode run the real thing when available.
import Foundation

open class XCTestCase { public required init() {} }

nonisolated(unsafe) var shimFailures: [String] = []

public func XCTAssert(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let ok = (try? condition()) ?? false
    if !ok { shimFailures.append("\(("\(file)" as NSString).lastPathComponent):\(line) \(message)") }
}

public struct ShimUnwrapError: Error {}
public func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try value() else {
        shimFailures.append("\(("\(file)" as NSString).lastPathComponent):\(line) XCTUnwrap nil")
        throw ShimUnwrapError()
    }
    return v
}

/// Filled by tools/run-core-tests.sh from the test file: (name, body).
@main struct ShimMain {
    static func main() {
        var run = 0
        for (name, body) in shimRegistry {
            let before = shimFailures.count
            do { try body() } catch { XCTAssert(false, "\(name) threw \(error)") }
            run += 1
            print(shimFailures.count == before ? "✓ \(name)" : "✗ \(name)")
        }
        print("\n\(run) tests, \(shimFailures.count) failures")
        shimFailures.forEach { print("  FAIL \($0)") }
        exit(shimFailures.isEmpty ? 0 : 1)
    }
}
