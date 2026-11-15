// LPPaths — every on-disk location LivePaper uses. See ARCHITECTURE §4.1.
import Foundation

public enum LPPaths {
    public static let bundleID = "com.nachmore.livepaper"
    public static let helperLabel = "com.nachmore.livepaper.helper"
    public static let saverBundleID = "com.nachmore.livepaper.saver"
    public static let saverName = "LivePaper.saver"

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Overridable root for tests (LIVEPAPER_HOME=/tmp/x points everything under it).
    public static var supportRoot: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_HOME"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/Application Support/LivePaper")
    }
    public static var library: URL { supportRoot.appendingPathComponent("Library") }
    public static var workspaces: URL { supportRoot.appendingPathComponent("Workspaces") }
    public static var backups: URL { supportRoot.appendingPathComponent("backups") }
    public static var stateFile: URL { supportRoot.appendingPathComponent("state.json") }
    public static var renderSocket: URL { supportRoot.appendingPathComponent("render.sock") }
    public static var renderdPIDFile: URL { supportRoot.appendingPathComponent("renderd.pid") }
    public static var logs: URL { supportRoot.appendingPathComponent("Logs") }

    public static var screenSaversDir: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_SAVERS_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/Screen Savers")
    }
    /// Written by uninstall (outside supportRoot, which uninstall may delete). A helper that finds it
    /// exits cleanly at launch so a still-registered login item can't resurrect LivePaper.
    public static var uninstallMarker: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_HOME"], !o.isEmpty {
            return URL(fileURLWithPath: o).deletingLastPathComponent().appendingPathComponent("LivePaper.uninstalled")
        }
        return home.appendingPathComponent("Library/Application Support/LivePaper.uninstalled")
    }
    public static var launchAgentsDir: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_LAUNCH_AGENTS_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/LaunchAgents")
    }
    public static var installedSaver: URL { screenSaversDir.appendingPathComponent(saverName) }
    public static var installedPlaylist: URL {
        installedSaver.appendingPathComponent("Contents/Resources").appendingPathComponent(LPPlaylist.directoryName)
    }

    /// The wallpaper store that holds the screen-saver selection (read/modify only via WallpaperStore).
    public static var wallpaperStore: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_WALLPAPER_STORE"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Resources of the running app bundle (Runtime/, Scenes/, LivePaper.saver template, Helpers/).
    /// Falls back to the source tree for `swift run` during development (LIVEPAPER_SOURCE_ROOT).
    public static var appResources: URL {
        if let o = ProcessInfo.processInfo.environment["LIVEPAPER_RESOURCES"], !o.isEmpty { return URL(fileURLWithPath: o) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // …/LivePaper.app/Contents/{MacOS|Helpers}/<exe>  →  …/Contents/Resources
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        let res = contents.appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: res.appendingPathComponent("Runtime").path) { return res }
        if let src = ProcessInfo.processInfo.environment["LIVEPAPER_SOURCE_ROOT"] { return URL(fileURLWithPath: src) }
        return res
    }
    public static var runtimeDir: URL { appResources.appendingPathComponent("Runtime") }
    public static var builtinScenesDir: URL { appResources.appendingPathComponent("Scenes") }

    public static func ensureDirectories() throws {
        for d in [supportRoot, library, workspaces, backups, logs] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}
