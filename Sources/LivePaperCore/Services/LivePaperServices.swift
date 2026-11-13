// LivePaperServices — the one place concrete services are wired. Owner: WS-core.
import Foundation

public final class LivePaperServices: @unchecked Sendable {
    public let library: LibraryServicing
    public let publish: PublishServicing
    public let ai: AIServicing
    public let install: InstallServicing
    public let render: RenderClienting
    public let checker: SceneChecking
    public let compiler: SceneCompiling

    public init(library: LibraryServicing, publish: PublishServicing, ai: AIServicing, install: InstallServicing,
                render: RenderClienting, checker: SceneChecking, compiler: SceneCompiling) {
        self.library = library; self.publish = publish; self.ai = ai; self.install = install
        self.render = render; self.checker = checker; self.compiler = compiler
    }
}
