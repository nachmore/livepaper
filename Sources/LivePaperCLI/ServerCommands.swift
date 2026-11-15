// ServerCommands — `livepaper server status|start|stop`: inspect or control the render server.
import Foundation
import LivePaperCore

enum ServerCommands {
    static var all: [CLICommand] {
        [CLICommand(name: "server", synopsis: "status|start|stop",
                    summary: "show, start or stop the render server (LivePaper.app or LivePaperRenderd)", run: server)]
    }

    static func server(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv)
        let action = try args.single("action (status, start or stop)")
        let client = RenderClient()
        switch action {
        case "status":
            guard client.isServerRunning() else {
                print("not running (socket \(client.socket.path)); it starts on demand")
                return ExitCode.failed
            }
            let r = try await client.send(RenderRequest(op: .ping), timeout: 10)
            print("running: \(r.note ?? "ok")")
            return ExitCode.ok
        case "start":
            try client.ensureServer(timeout: 40)
            let r = try await client.send(RenderRequest(op: .ping), timeout: 10)
            print("running: \(r.note ?? "ok")")
            return ExitCode.ok
        case "stop":
            guard client.isServerRunning() else { print("not running"); return ExitCode.ok }
            let r = try await client.send(RenderRequest(op: .shutdown), timeout: 10)
            print(r.ok ? "stopping: \(r.note ?? "ok")" : "not stopped: \(r.note ?? "refused")")
            return r.ok ? ExitCode.ok : ExitCode.failed
        default:
            throw UsageError("unknown action '\(action)'")
        }
    }
}
