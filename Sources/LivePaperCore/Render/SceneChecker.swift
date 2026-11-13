// SceneChecker — `livepaper check`: compile, render stills, bench, budgets, report. Owner: WS-runtime.
import Foundation

public final class SceneChecker: SceneChecking, @unchecked Sendable {
    public init(compiler: SceneCompiling = SceneCompiler(), render: RenderClienting = RenderClient()) { self.compiler = compiler; self.render = render }
    public let compiler: SceneCompiling
    public let render: RenderClienting
    public func check(package: URL, options: CheckOptions) async throws -> CheckReport { throw NotImplemented("SceneChecker.check") }
}
