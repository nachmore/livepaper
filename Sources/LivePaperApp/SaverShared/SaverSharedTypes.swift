// SaverShared — saver sources compiled into the app as well, so the full-screen preview renders
// scenes exactly like LivePaper.saver: SaverLogic.swift (web config, performance resolution, host
// calls, clock geometry) and ClockOverlay.swift (the native clock of video scenes). Both are
// symlinks into Saver/; edit them there.
//
// In the saver bundle those files sit in one module with PlaylistModel.swift and ClockOverlay.swift
// doesn't import LivePaperCore. This alias gives it the same type under the same name here.
import LivePaperCore

typealias LPClockPosition = LivePaperCore.LPClockPosition
