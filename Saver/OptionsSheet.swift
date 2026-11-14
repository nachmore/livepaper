// OptionsSheet — the saver's "Options…" sheet: a read-only summary of what is published and a way
// to open the app. All settings live in the LivePaper app; the sandboxed saver can neither write
// them anywhere the app could read nor launch the app, so "Open LivePaper…" posts a distributed
// notification that the LivePaper helper turns into an app launch.
import AppKit

final class OptionsSheetController: NSObject {
    let window: NSWindow
    private let summary: SaverSummary

    init(summary: SaverSummary) {
        self.summary = summary
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        // The host keeps a reference and may present the sheet again; never let AppKit free it on close.
        window.isReleasedWhenClosed = false
        window.title = "LivePaper"
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "LivePaper")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Animated screen saver and lock screen")
        subtitle.textColor = .secondaryLabelColor

        var rows: [[NSView]] = [
            [label("Playlist:"), value(summary.playlist)],
            [label("Clock:"), value(summary.clock)],
            [label("Performance:"), value(summary.performance)],
        ]
        if let scenes = summary.scenes { rows.insert([label("Scenes:"), value(scenes)], at: 1) }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let footnote = NSTextField(wrappingLabelWithString: summary.footnote)
        footnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.textColor = .tertiaryLabelColor
        footnote.preferredMaxLayoutWidth = 416

        let open = NSButton(title: "Open LivePaper…", target: self, action: #selector(openApp))
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [open, NSView(), done])
        buttons.distribution = .fill

        let stack = NSStackView(views: [title, subtitle, grid, footnote, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: grid)
        stack.setCustomSpacing(18, after: footnote)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        window.contentView = content
        window.defaultButtonCell = done.cell as? NSButtonCell
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func value(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = 300
        field.isSelectable = false
        return field
    }

    @objc private func openApp() {
        // Sandboxed processes may post distributed notifications as long as there is no userInfo.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(LPNotification.openApp), object: nil, userInfo: nil, deliverImmediately: true)
        SaverLog.saver.info("asked the LivePaper helper to open the app")
        dismiss()
    }

    @objc private func dismiss() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
    }
}
