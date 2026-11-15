// FullScreenPreviewOverlay — what the full-screen preview draws over the scene: the translucent hint
// bar at the bottom ("← → scenes · C clock · L lock-screen preview · Esc close", with the scene's
// name), which fades out after a few seconds and returns when the pointer moves, and a message when
// a scene can't be shown. It never takes clicks (the window closes on a click).
import LivePaperCore
import SwiftUI

/// The overlay's state, driven by FullScreenPreviewSession.
@MainActor
@Observable
final class FullScreenPreviewState {
    var sceneName = ""
    /// "2 of 5" (nil for a single scene).
    var position: String?
    var hintItems: [FullScreenHint.Item] = []
    var hintVisible = false
    /// Why the current scene can't be shown (it failed to compile, its video is missing).
    var message: String?
}

struct FullScreenPreviewOverlay: View {
    let state: FullScreenPreviewState

    var body: some View {
        ZStack {
            if let message = state.message {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .light))
                    Text(message)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityElement(children: .combine)
            }
            VStack {
                Spacer()
                FullScreenHintBar(sceneName: state.sceneName, position: state.position, items: state.hintItems)
                    .opacity(state.hintVisible ? 1 : 0)
                    .offset(y: state.hintVisible ? 0 : 6)
                    .animation(.easeInOut(duration: 0.35), value: state.hintVisible)
                    .padding(.bottom, 40)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

/// "Aurora Lake  2 of 5 | ←→ scenes · C clock · L lock-screen preview · Esc close"
struct FullScreenHintBar: View {
    let sceneName: String
    let position: String?
    let items: [FullScreenHint.Item]

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sceneName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                if let position {
                    Text(position)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
            }
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 16)
            HStack(spacing: 14) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(item.keys, id: \.self) { KeyCap(key: $0, active: item.isActive) }
                        }
                        Text(item.label)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(item.isActive ? 0.95 : 0.72))
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.52), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([sceneName, position].compactMap { $0 }.joined(separator: ", ") + ". " + FullScreenHint.text(items))
    }
}

/// One key of the hint bar, drawn like a key cap (filled when its toggle is on).
private struct KeyCap: View {
    let key: String
    var active = false

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.92))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 19)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(active ? Color.white.opacity(0.9) : Color.white.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(active ? 0 : 0.22)))
    }
}
