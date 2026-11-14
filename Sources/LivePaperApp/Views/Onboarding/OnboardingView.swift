// OnboardingView — first-launch setup (re-runnable from Settings). Every page shows live status from
// InstallServicing and only offers what is still needed, so running it again is always safe.
import LivePaperCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: OnboardingStep
    @State private var visited: Set<OnboardingStep> = [.welcome]
    @State private var needsGuidedSelection = false
    /// nil = shuffle all scenes.
    @State private var firstSceneID: String?
    @State private var finishing = false
    private let startsAtFirstIncomplete: Bool

    /// - Parameters:
    ///   - initialStep: a specific page (snapshots); nil starts at Welcome on first launch and at
    ///     the first page that still needs something on a re-run.
    ///   - showGuidedSelection: start with the guided "select it yourself" step visible (snapshots).
    init(initialStep: OnboardingStep? = nil, showGuidedSelection: Bool = false) {
        _step = State(initialValue: initialStep ?? .welcome)
        _needsGuidedSelection = State(initialValue: showGuidedSelection)
        startsAtFirstIncomplete = initialStep == nil
    }

    var body: some View {
        HStack(spacing: 0) {
            StepRail(current: step, visited: visited, status: model.installStatus) { go(to: $0) }
                .frame(width: 210)
                .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    page
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 800, height: 580)
        .task {
            await model.refreshInstallStatus()
            if startsAtFirstIncomplete && model.hasCompletedOnboarding {
                go(to: SetupChecklist.firstIncompleteStep(status: model.installStatus))
            }
        }
        .refreshesInstallStatusOnActivation()
    }

    private func go(to next: OnboardingStep) {
        withAnimation(.snappy) { step = next }
        visited.insert(next)
    }

    // MARK: pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .screenSaver: ScreenSaverPage(needsGuidedSelection: $needsGuidedSelection)
        case .lock: LockPage()
        case .lockKeys: LockKeysPage()
        case .firstScene: FirstScenePage(selection: $firstSceneID)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { if let prev = OnboardingStep(rawValue: step.rawValue - 1) { go(to: prev) } }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            Spacer()
            if step == .welcome {
                Button("Set Up Later") { model.showOnboarding = false }
                    .keyboardShortcut(.cancelAction)
            }
            if step == .firstScene {
                if finishing { ProgressView().controlSize(.small) }
                Button("Finish", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(finishing)
            } else {
                let complete = SetupChecklist.isComplete(step, status: model.installStatus)
                let next = { if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(to: n) } }
                if step == .welcome {
                    Button("Get Started", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if complete {
                    Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .lockKeys ? "Skip" : "Skip for Now", action: next)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func finish() {
        finishing = true
        Task {
            if let id = firstSceneID {
                await model.useAsScreenSaver(id)
            } else if model.installStatus.saverInstalled {
                var all = model.playlist
                all.mode = .shuffle
                all.sceneIDs = []
                await model.savePlaylist(all, announce: false)
            }
            finishing = false
            model.completeOnboarding()
        }
    }
}

// MARK: - Rail

private struct StepRail: View {
    let current: OnboardingStep
    let visited: Set<OnboardingStep>
    let status: InstallStatus
    let select: (OnboardingStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set Up LivePaper")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ForEach(OnboardingStep.allCases) { s in
                Button { select(s) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: s))
                            .foregroundStyle(iconTint(for: s))
                            .frame(width: 18)
                        Text(s.title)
                            .foregroundStyle(s == current ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(s == current ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.title)
                .accessibilityValue(isDone(s) ? "Done" : (s == current ? "Current step" : ""))
            }
            Spacer()
        }
        .padding(14)
    }

    private func isDone(_ s: OnboardingStep) -> Bool {
        switch s {
        case .welcome, .firstScene, .lockKeys: return visited.contains(s) && s != current && SetupChecklist.isComplete(s, status: status)
        case .screenSaver, .lock: return SetupChecklist.isComplete(s, status: status)
        }
    }

    private func icon(for s: OnboardingStep) -> String { isDone(s) ? "checkmark.circle.fill" : s.symbolName }
    private func iconTint(for s: OnboardingStep) -> Color { isDone(s) ? .green : (s == current ? .accentColor : .secondary) }
}

// MARK: - Page scaffolding

private struct PageHeader: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(text).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A check row with an optional action on the right.
private struct CheckWithAction<Action: View>: View {
    let check: SetupCheck
    @ViewBuilder var action: Action
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SetupCheckRow(check: check)
            Spacer(minLength: 8)
            action
        }
        .padding(14)
        .card(cornerRadius: 10)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            WelcomeArt()
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            PageHeader(title: "Welcome to LivePaper",
                       text: "Your screen saver and lock screen, alive \u{2014} with scenes you make from videos or simply describe.")
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "lock.display", title: "Animated lock screen",
                        text: "Scenes play as your screen saver and stay behind the lock screen when your Mac locks.")
                Feature(symbol: "sparkles", title: "Describe it, get a scene",
                        text: "An AI agent you already use writes the scene; LivePaper checks it before you keep it.")
                Feature(symbol: "leaf", title: "Easy on the battery",
                        text: "Every scene is measured, and LivePaper slows scenes down on battery and pauses them when no one is looking.")
            }
            Text("Setup takes about a minute. Nothing changes until you click a button, and Uninstall in Settings puts everything back.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Procedural aurora-over-water art for the welcome page (original; no images).
struct WelcomeArt: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(red: 0.02, green: 0.05, blue: 0.14), Color(red: 0.05, green: 0.16, blue: 0.24)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var stars = SeededRandom(seed: 7)
            for _ in 0..<90 {
                let p = CGPoint(x: stars.next() * size.width, y: stars.next() * size.height * 0.55)
                let r = 0.4 + stars.next() * 1.2
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.3 + stars.next() * 0.5)))
            }
            let bands: [(Color, CGFloat, CGFloat)] = [(Color(red: 0.24, green: 0.96, blue: 0.65), 0.30, 0.0),
                                                     (Color(red: 0.61, green: 0.48, blue: 1.0), 0.40, 1.7),
                                                     (Color(red: 0.24, green: 0.86, blue: 0.9), 0.22, 3.1)]
            context.blendMode = .screen
            for (color, top, phase) in bands {
                for k in 0..<12 {
                    var path = Path()
                    let base = size.height * top + CGFloat(k) * 3
                    path.move(to: CGPoint(x: 0, y: base + 12))
                    var x: CGFloat = 0
                    while x <= size.width + 6 {
                        let u = x / size.width
                        path.addLine(to: CGPoint(x: x, y: base + 16 * sin(u * 7 + phase) + 6 * sin(u * 17 + phase * 2)))
                        x += 6
                    }
                    path.addLine(to: CGPoint(x: size.width, y: base + 22))
                    path.addLine(to: CGPoint(x: 0, y: base + 22))
                    path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(0.09 * (1 - Double(k) / 12))))
                }
            }
            context.blendMode = .normal
            let water = CGRect(x: 0, y: size.height * 0.72, width: size.width, height: size.height * 0.28)
            context.fill(Path(water), with: .color(Color(red: 0.01, green: 0.03, blue: 0.07).opacity(0.9)))
            for i in 0..<10 {
                let y = water.minY + CGFloat(i) * 4 + 3
                let w = size.width * (0.2 + 0.05 * CGFloat(i % 4))
                context.fill(Path(CGRect(x: size.width * 0.35 - w / 2 + CGFloat(i * 13 % 40), y: y, width: w, height: 1.2)),
                             with: .color(Color(red: 0.24, green: 0.96, blue: 0.65).opacity(0.12 - Double(i) * 0.01)))
            }
        }
    }
}

/// Tiny deterministic generator (SwiftUI art must not change between renders).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}

// MARK: - Screen saver

private struct ScreenSaverPage: View {
    @Binding var needsGuidedSelection: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.installStatus
        let checks = SetupChecklist.checks(for: .screenSaver, status: status)
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Make LivePaper your screen saver",
                       text: "On macOS the lock screen shows the screen saver that is running, so LivePaper's scenes play as your screen saver. Your current choice is backed up first.")
            VStack(spacing: 10) {
                ForEach(checks) { check in
                    CheckWithAction(check: check) { EmptyView() }
                }
            }
            if !SetupChecklist.isComplete(.screenSaver, status: status) {
                HStack(spacing: 10) {
                    Button {
                        Task { needsGuidedSelection = !(await model.makeLivePaperScreenSaver()) }
                    } label: {
                        Text(status.saverInstalled && status.saverUpToDate ? "Select LivePaper" : "Install & Select")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isInstallBusy)
                    if model.isInstallBusy { ProgressView().controlSize(.small) }
                }
            }
            if needsGuidedSelection && status.saverInstalled && !status.saverSelected {
                GuidedSaverSelection()
            }
        }
    }
}

/// The one-click fallback when macOS didn't let LivePaper select its saver itself: a drawn,
/// screenshot-style illustration of where to click, plus the button that opens the right pane.
struct GuidedSaverSelection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("One more click", systemImage: "hand.point.up.left.fill")
                .font(.headline)
            HStack(alignment: .top, spacing: 18) {
                SettingsIllustration()
                    .frame(width: 260, height: 168)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    GuideStep(n: 1, text: "Click Open Screen Saver Settings.")
                    GuideStep(n: 2, text: "Under Other, click LivePaper.")
                    GuideStep(n: 3, text: "Come back here \u{2014} this page updates by itself.")
                    HStack {
                        Button("Open Screen Saver Settings") { model.openScreenSaverSettings() }
                            .buttonStyle(.borderedProminent)
                        Button("Check Again") { Task { await model.refreshInstallStatus() } }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 12)
    }

    private struct GuideStep: View {
        let n: Int
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A simplified drawing of a settings window with a grid of screen savers, LivePaper highlighted.
private struct SettingsIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 7, height: 7) }
                Spacer()
                Text("Screen Saver").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i == 3 ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25))
                            .frame(width: i == 3 ? 46 : CGFloat(30 + (i * 7) % 18), height: 6)
                    }
                    Spacer()
                }
                .padding(8)
                .frame(width: 64)
                .background(.quaternary.opacity(0.5))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(0..<6, id: \.self) { i in
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(i == 1 ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.3), Color(red: 0.2, green: 0.75, blue: 0.6)],
                                                                                 startPoint: .top, endPoint: .bottom))
                                                 : AnyShapeStyle(Color.secondary.opacity(0.22)))
                                if i == 1 {
                                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                                }
                            }
                            .aspectRatio(1.5, contentMode: .fit)
                            .overlay(alignment: .bottom) {
                                if i == 1 {
                                    Text("LivePaper").font(.system(size: 7, weight: .semibold)).foregroundStyle(.white).padding(.bottom, 2)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .overlay(alignment: .center) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 18))
                .foregroundStyle(.primary)
                .shadow(color: .white, radius: 1)
                .offset(x: 30, y: 12)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

// MARK: - Lock

private struct LockPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.installStatus
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Lock with your scene",
                       text: "macOS shows the screen saver on the lock screen only if it is already running when the Mac locks. LivePaper's helper gives you a shortcut that starts your scene first, then locks.")
            VStack(spacing: 10) {
                ForEach(SetupChecklist.checks(for: .lock, status: status)) { check in
                    CheckWithAction(check: check) {
                        switch (check.id, check.state) {
                        case (.helper, .needed):
                            Button("Start Helper") { Task { await model.registerHelper() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isInstallBusy)
                        case (.password, .needed):
                            Button("Open Lock Screen Settings") { SystemActions.openLockScreenSettings() }
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            if let hotkey = model.sharedState.lock.hotkey {
                HStack(spacing: 8) {
                    Text("Your lock shortcut:")
                    Text(HotkeyRecorder.display(hotkey))
                        .font(.body.monospaced().weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text("You can change it in Settings \u{203A} Lock.").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Lock keys (optional)

private struct LockKeysPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.installStatus
        let lock = model.sharedState.lock
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Use your usual lock keys",
                       text: "Optional. \u{2303}\u{2318}Q and the lock key lock instantly and show the plain wallpaper. LivePaper can catch them and lock with your scene instead.")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use \u{2303}\u{2318}Q for LivePaper lock", isOn: Binding(
                    get: { lock.takeOverSystemLock }, set: { v in model.updateLock { $0.takeOverSystemLock = v } }))
                Toggle("Use the lock key (Touch ID button)", isOn: Binding(
                    get: { lock.takeOverLockKey }, set: { v in model.updateLock { $0.takeOverLockKey = v } }))
            }
            .toggleStyle(.switch)
            .padding(14)
            .card(cornerRadius: 10)
            CheckWithAction(check: SetupChecklist.checks(for: .lockKeys, status: status)[0]) {
                if !status.accessibilityTrusted {
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                }
            }
            Text("Catching keys needs Accessibility access. If the helper ever stops, the keys simply work as they always did.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - First scene

private struct FirstScenePage: View {
    @Binding var selection: String?
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Pick your first scene",
                       text: "Choose one to start with, or let LivePaper shuffle through all of them. You can change this any time.")
            LazyVGrid(columns: columns, spacing: 12) {
                ShuffleTile(selected: selection == nil) { selection = nil }
                ForEach(model.entries.prefix(11)) { entry in
                    SceneTile(entry: entry, selected: selection == entry.id) { selection = entry.id }
                }
            }
        }
    }

    private struct ShuffleTile: View {
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Color.clear
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            Image(systemName: "shuffle")
                                .font(.title)
                                .foregroundStyle(.tint)
                        }
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(SelectionRing(selected: selected))
                    Text("Shuffle all").font(.callout.weight(selected ? .semibold : .regular))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle all scenes")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private struct SceneTile: View {
        let entry: LibraryEntry
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Color.black
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay { ThumbnailImage(url: entry.item.thumbnailURL, maxPixel: 400, placeholderSymbol: entry.badge.symbolName) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(SelectionRing(selected: selected))
                    Text(entry.manifest.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.manifest.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private struct SelectionRing: View {
        let selected: Bool
        var body: some View {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                            .padding(5)
                    }
                }
        }
    }
}
