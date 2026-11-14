// LivePaperRenderd — headless render daemon (ARCHITECTURE §2, §8).
//
// Started on demand by RenderClient (the `livepaper` CLI, AI checks) when LivePaper.app isn't
// serving the render socket. One instance at most: it exits at once if another server holds the
// socket, after a `shutdown` request (e.g. the app taking over), on SIGTERM/SIGINT, or after
// 15 minutes without requests. It registers with the window server once (WebKit needs an
// NSApplication), with the `.prohibited` activation policy: no Dock icon, no menu bar, never active.
import AppKit
import Foundation
import LivePaperCore
import LivePaperRenderKit

let idleLimit: TimeInterval = 15 * 60
/// Keeps the signal sources alive for the process lifetime.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] LivePaperRenderd[\(getpid())]: \(message)\n".utf8))
}

// The daemon outlives whoever started it; never keep their working directory busy.
FileManager.default.changeCurrentDirectoryPath("/")
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
    let server: RenderServer
    do {
        server = try RenderServer.startDaemonServer()
    } catch RenderServerError.alreadyServing(let detail) {
        log("another render server is already running (\(detail)); exiting")
        exit(0)
    } catch {
        log(error.localizedDescription)
        exit(1)
    }
    let pidFile = server.files.pidFile
    try? "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
    log("serving \(server.files.socket.path)")

    func shutDown(_ reason: String) -> Never {
        log(reason)
        try? FileManager.default.removeItem(at: pidFile)
        exit(0)
    }
    server.onStop = { shutDown("stopped") }

    // Idle exit. One wake-up a minute is the only background activity of an idle daemon.
    let idleTimer = Timer(timeInterval: 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            if server.idleSeconds > idleLimit {
                server.onStop = nil
                server.stop()
                shutDown("idle for \(Int(idleLimit / 60)) minutes; exiting")
            }
        }
    }
    idleTimer.tolerance = 10
    RunLoop.main.add(idleTimer, forMode: .common)

    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                server.onStop = nil
                server.stop()
                shutDown("signal \(sig); exiting")
            }
        }
        source.resume()
        signalSources.append(source)
    }
}

app.run()
