// LivePaperSelfTest — tiny test runner (XCTest/swift-testing aren't available with CLT only).
//   swift run LivePaperSelfTest [filter]
// Each workstream owns one file that extends SelfTests with a static list of cases.
// Tests must not launch GUI processes or touch the real user state: use LIVEPAPER_HOME etc.
import Foundation

struct TestCase { let name: String; let run: () throws -> Void }
struct TestFailure: Error, CustomStringConvertible { let description: String }

func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) throws {
    if !cond() { throw TestFailure(description: "\(file):\(line) expectation failed \(msg())") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: String = #fileID, line: Int = #line) throws {
    if a != b { throw TestFailure(description: "\(file):\(line) \(a) != \(b)") }
}
/// A fresh temporary directory (removed at process exit is not guaranteed; tests use /tmp).
func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("livepaper-selftest-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

enum SelfTests {
    static var all: [TestCase] { contracts + runtime + saver + core + app }
}

let filter = CommandLine.arguments.dropFirst().first
var failed = 0, passed = 0
for t in SelfTests.all where filter == nil || t.name.contains(filter!) {
    do { try t.run(); passed += 1; print("✓ \(t.name)") }
    catch { failed += 1; print("✗ \(t.name): \(error)") }
}
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
