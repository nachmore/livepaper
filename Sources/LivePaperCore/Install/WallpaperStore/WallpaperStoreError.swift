// WallpaperStoreError — why LivePaper didn't (or couldn't fully) change the screen-saver selection.
import Foundation

public enum WallpaperStoreError: Error, LocalizedError, Sendable, Equatable {
    // Refusals: checked before anything is written; the store is untouched.

    /// The live sequence can't run against this store at all (e.g. tests redirect the store, or
    /// system commands are only recorded).
    case unavailable(String)
    case sessionLocked
    /// No login session on the console (e.g. a remote shell, or another user is switched in).
    case sessionUnknown
    /// A process that keeps its own copy of the wallpaper settings (System Settings, its Wallpaper
    /// pane extension) or is showing a screen saver right now.
    case conflictingProcess(String)
    case moduleForcedByMDM
    case wallpaperChangesDisabledByMDM
    /// `com.apple.wallpaper StoreIndexMigrationVersion` isn't the version this code understands.
    case unsupportedStoreVersion(Int?)
    case storeMissing(String)
    /// The store (or a store LivePaper built) wouldn't decode with WallpaperAgent's model.
    case undecodable(String)
    /// A structure LivePaper doesn't edit (e.g. a `linked` record).
    case unsupportedShape(String)
    /// An edited store failed the invariants (only the intended Idle slots may change).
    case verificationFailed(String)
    /// WallpaperAgent kept writing the store; it never stayed unchanged long enough.
    case storeBusy
    /// The `.saver` must exist before the store points at it.
    case saverMissing(String)
    /// Undoing the selection would leave this root Idle slot (SystemDefault / AllSpacesAndDisplays)
    /// pointing at LivePaper: there is no recorded original, no usable pre-LivePaper copy and no
    /// built-in screen saver to put there instead.
    case noPreviousChoice(String)
    /// The caller's reason to stop, found again while holding the store lock (e.g. LivePaper was
    /// uninstalled meanwhile): nothing written.
    case stopped(String)

    // After the store was written.

    case agentRestartFailed(String)
    /// The change didn't survive WallpaperAgent's restart, even after retrying.
    case notConfirmed(String)
    /// The restarted agent's store had different Desktop choices; LivePaper put the previous store
    /// back and confirmed that the restarted agent kept it.
    case rolledBack(String)
    /// As `rolledBack`, but putting the previous store back couldn't be confirmed: the Desktop
    /// choices may have been reset. The message names the saved copy of the previous store.
    case rollbackFailed(String)

    /// True when the store on disk may differ from before the call.
    public var wroteStore: Bool {
        switch self {
        case .agentRestartFailed, .notConfirmed, .rolledBack, .rollbackFailed: return true
        default: return false
        }
    }

    /// True when trying again later can succeed without the user changing anything else on the Mac
    /// (as opposed to a store format, policy or setup LivePaper can't work with).
    public var isTransient: Bool {
        switch self {
        case .sessionLocked, .sessionUnknown, .conflictingProcess, .storeBusy, .agentRestartFailed, .notConfirmed, .rolledBack:
            return true
        case .unavailable, .moduleForcedByMDM, .wallpaperChangesDisabledByMDM, .unsupportedStoreVersion, .storeMissing,
             .undecodable, .unsupportedShape, .verificationFailed, .saverMissing, .noPreviousChoice, .stopped, .rollbackFailed:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "the wallpaper settings can't be changed here (\(why))"
        case .sessionLocked: return "the Mac is locked"
        case .sessionUnknown: return "this isn't the active login session"
        case .conflictingProcess(let name): return "\(name) is open — quit it and try again"
        case .moduleForcedByMDM: return "your organisation sets the screen saver (configuration profile)"
        case .wallpaperChangesDisabledByMDM: return "your organisation doesn't allow changing the wallpaper"
        case .unsupportedStoreVersion(let v): return "this macOS version stores wallpaper settings differently (version \(v.map(String.init) ?? "unknown"))"
        case .storeMissing(let path): return "the wallpaper settings file doesn't exist (\(path))"
        case .undecodable(let why): return "the wallpaper settings file isn't in the expected format (\(why))"
        case .unsupportedShape(let why): return "the wallpaper settings use a layout LivePaper doesn't change (\(why))"
        case .verificationFailed(let why): return "the edited wallpaper settings failed verification (\(why))"
        case .storeBusy: return "macOS kept updating the wallpaper settings; try again in a moment"
        case .saverMissing(let path): return "the LivePaper screen saver isn't installed (\(path))"
        case .noPreviousChoice(let path): return "LivePaper has no earlier screen saver to put back for \(path)"
        case .stopped(let why): return "LivePaper stopped before changing the wallpaper settings (\(why))"
        case .agentRestartFailed(let why): return "couldn't restart WallpaperAgent (\(why))"
        case .notConfirmed(let why): return "macOS didn't keep the change (\(why))"
        case .rolledBack(let why): return "macOS changed other wallpaper settings, so LivePaper put the previous settings back (\(why))"
        case .rollbackFailed(let why): return "macOS changed other wallpaper settings and LivePaper couldn't confirm that the previous settings are back (\(why))"
        }
    }
}
