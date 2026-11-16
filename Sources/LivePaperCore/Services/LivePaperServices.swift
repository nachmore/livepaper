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
    public let collections: CollectionServicing

    /// - Parameter collections: nil: collections.json in the support directory (LPPaths), over `library`.
    public init(library: LibraryServicing, publish: PublishServicing, ai: AIServicing, install: InstallServicing,
                render: RenderClienting, checker: SceneChecking, compiler: SceneCompiling, collections: CollectionServicing? = nil) {
        self.library = library; self.publish = publish; self.ai = ai; self.install = install
        self.render = render; self.checker = checker; self.compiler = compiler
        self.collections = collections ?? CollectionService(library: library)
    }

    /// The real services, using LPPaths (and therefore the LIVEPAPER_* environment overrides).
    /// Cheap: nothing is written and no process is started until a service is used.
    public static func live() -> LivePaperServices {
        let compiler = SceneCompiler()
        let render = RenderClient()
        let checker = SceneChecker(compiler: compiler, render: render)
        let library = LibraryService()
        let collectionStore = CollectionStore()
        let collections = CollectionService(library: library, store: collectionStore)
        let publish = PublishService(library: library, compiler: compiler, collections: collectionStore)
        let ai = AIService(library: library, checker: checker)
        let install = InstallService(publisher: publish)
        return LivePaperServices(library: library, publish: publish, ai: ai, install: install,
                                 render: render, checker: checker, compiler: compiler, collections: collections)
    }
}
