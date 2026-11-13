// SceneCompiler — web scene package → single self-contained HTML (runtime inlined). Owner: WS-runtime.
import Foundation

public struct NotImplemented: Error, LocalizedError { public let what: String; public init(_ w: String) { what = w }
    public var errorDescription: String? { "\(what) is not implemented yet" } }

public final class SceneCompiler: SceneCompiling, @unchecked Sendable {
    public init(runtimeDir: URL = LPPaths.runtimeDir) { self.runtimeDir = runtimeDir }
    public let runtimeDir: URL
    public func compile(package: URL, to output: URL) throws { throw NotImplemented("SceneCompiler.compile") }
}
