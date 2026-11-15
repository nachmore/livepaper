// RenderSpool — render requests passed as files, for AI agents whose sandbox blocks the socket.
//
// Codex runs its commands in a sandbox that may write only its workspace and has no network —
// Unix sockets included — so the `livepaper` it runs can't reach the render server. Rather than
// opening the sandbox to the whole network, the session runner (AISession, outside the sandbox)
// watches the session's spool folder (LIVEPAPER_RENDER_SPOOL = <workspace>/.livepaper/render-spool)
// and relays what it finds there (RenderRelay, which checks every request first):
//
//   client:  <id>.request.json            written atomically (temp file + rename)
//   relay:   <id>.request.json → <id>.working          claimed
//   relay:   <id>.response.json            written atomically; the client reads it and removes both
//
// The client only uses the spool when the socket can't be reached, and never starts a render
// daemon itself in an AI session (that would put it inside the agent's sandbox). Foundation/Darwin
// only (the CLI uses it).
import Darwin
import Foundation

public enum RenderSpool {
    static let requestSuffix = ".request.json"
    static let claimedSuffix = ".working"
    static let responseSuffix = ".response.json"
    /// Largest request/response file read (requests are small; this only guards against garbage).
    static let maxFileBytes = 1 << 20
    /// How long a request may wait for the relay to pick it up before the client gives up.
    static let claimTimeout: TimeInterval = 20

    /// The spool of the AI session this process runs in, if any.
    public static var environmentSpool: URL? {
        let env = ProcessInfo.processInfo.environment
        guard AISessionPolicy.isActive(env), let path = env[AISessionPolicy.renderSpoolVariable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Client side: drops `request` into `directory` and waits for the relay's answer.
    static func send(_ request: RenderRequest, directory: URL, timeout: TimeInterval, deadline: Date,
                     claimTimeout: TimeInterval = RenderSpool.claimTimeout, isCancelled: () -> Bool) throws -> RenderResponse {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let requestFile = directory.appendingPathComponent(id + requestSuffix)
        let claimed = directory.appendingPathComponent(id + claimedSuffix)
        let responseFile = directory.appendingPathComponent(id + responseSuffix)
        let tmp = directory.appendingPathComponent(".\(id).tmp")
        try JSONEncoder().encode(request).write(to: tmp)
        guard rename(tmp.path, requestFile.path) == 0 else {
            let e = errno
            try? fm.removeItem(at: tmp)
            throw RenderClientError.serverUnavailable("cannot write \(requestFile.path): \(String(cString: strerror(e)))")
        }
        defer { for f in [requestFile, claimed, responseFile] { try? fm.removeItem(at: f) } }
        let claimDeadline = min(deadline, Date().addingTimeInterval(claimTimeout))
        while true {
            if isCancelled() { throw RenderClientError.cancelled }
            if let data = try? Data(contentsOf: responseFile), !data.isEmpty {
                do { return try JSONDecoder().decode(RenderResponse.self, from: data) }
                catch { throw RenderClientError.badResponse(String(decoding: data.prefix(300), as: UTF8.self)) }
            }
            if Date() > deadline {
                throw RenderClientError.timedOut(op: request.op.rawValue, seconds: timeout)
            }
            if Date() > claimDeadline, FileOps.entryExists(requestFile) {
                throw RenderClientError.serverUnavailable("the render socket can't be reached from here and LivePaper didn't pick up the " +
                                                          "request in \(directory.path) (is the AI session still running?)")
            }
            usleep(50_000)
        }
    }
}
