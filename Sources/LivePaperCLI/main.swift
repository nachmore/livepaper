// livepaper — the LivePaper command-line tool (ARCHITECTURE §9). Foundation only: it runs inside AI
// agents' shells and must never register with the window server; rendering is delegated to the
// render server over its socket (see RenderClient).
import Foundation

exit(await CLI.main(CommandLine.arguments))
