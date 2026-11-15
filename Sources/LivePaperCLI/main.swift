// livepaper — the LivePaper command-line tool (ARCHITECTURE §9). Foundation only: it runs inside AI
// agents' shells and must never register with the window server; rendering is delegated to the
// render server over its socket (see RenderClient).
import Foundation

// Before anything reads LPPaths: resolve resources, the render daemon and this CLI from the real
// executable path (argv[0] is a bare name when run from PATH).
CLIEnvironment.pinLocations()
exit(await CLI.main(CommandLine.arguments))
