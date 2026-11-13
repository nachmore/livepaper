// RenderClient — talks to the RenderService socket; starts LivePaperRenderd when nothing listens. Owner: WS-runtime.
import Foundation

public final class RenderClient: RenderClienting, @unchecked Sendable {
    public init(socket: URL = LPPaths.renderSocket) { self.socket = socket }
    public let socket: URL
    public func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse { throw NotImplemented("RenderClient.send") }
}
