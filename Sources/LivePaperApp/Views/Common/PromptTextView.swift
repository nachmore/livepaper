// PromptTextView — the text view inside PromptEditor: plain text with undo, where ⌘V of an image
// (a screenshot, Safari's Copy Image, a Finder copy of image files or folders) and image drops go
// to the reference tray instead of doing nothing (ARCHITECTURE §11). Everything else — typing, IME,
// text paste, text drops, undo, ⌘↩ for the card's button — is the stock NSTextView's.
import AppKit
import LivePaperCore
import SwiftUI

struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    /// VoiceOver help (the placeholder).
    var hint: String = ""
    /// Images pasted or dropped onto the text, with notes about what couldn't be read; nil = images
    /// paste and drop as a plain text view would take them.
    var onImages: (([ReferenceInput], [String]) -> Void)?
    /// An image drag is over the text (the card highlights its drop area).
    var onDropTargeted: ((Bool) -> Void)?
    /// VoiceOver label of the text view.
    var label: String = "Prompt"
    /// Set: Return sends (ReturnKeyRule — the closure returns false when there is nothing to send);
    /// ⇧Return and ⌥Return add a new line. nil: Return adds a new line, as in any text view.
    var onReturn: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = PromptNSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.typingAttributes = [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.textColor]
        textView.insertionPointColor = .textColor
        // Prompts carry paths and code for an agent: keep quotes and dashes as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(label)
        context.coordinator.onReturn = onReturn
        textView.setAccessibilityHelp(hint.isEmpty ? nil : hint)
        textView.onImages = onImages
        textView.onDropTargeted = onDropTargeted
        textView.updateDragTypeRegistration()

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onReturn = onReturn
        guard let textView = scroll.documentView as? PromptNSTextView else { return }
        // Programmatic changes (an idea chip, clearing after Generate), never while IME composes.
        // Made like an edit, so undo stays consistent (and can bring a cleared prompt back).
        if textView.string != text && !textView.hasMarkedText() {
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            context.coordinator.applying = true   // the binding already holds `text`
            defer { context.coordinator.applying = false }
            if textView.shouldChangeText(in: all, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
                textView.didChangeText()
            } else {
                textView.string = text
            }
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        textView.setAccessibilityHelp(hint.isEmpty ? nil : hint)
        let wantedImages = onImages != nil
        textView.onImages = onImages
        textView.onDropTargeted = onDropTargeted
        if wantedImages != textView.registeredForImages { textView.updateDragTypeRegistration() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onReturn: (() -> Bool)?
        /// Set while updateNSView applies the binding's value (no echo back into it).
        var applying = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        /// Tab and ⇧Tab move to the next control (a prompt never needs a tab character), so the
        /// tray and the buttons below stay reachable from the keyboard.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), let onReturn {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                switch ReturnKeyRule.action(shift: flags.contains(.shift), option: flags.contains(.option),
                                            composing: textView.hasMarkedText(), canSend: true) {
                case .send: _ = onReturn(); return true          // nothing to send: Return does nothing
                case .asUsual: return false
                case .nothing: return true
                }
            }
            switch selector {
            case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil); return true
            case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil); return true
            default: return false
            }
        }
    }
}

/// The NSTextView subclass: paste and drops of images go to `onImages`.
final class PromptNSTextView: NSTextView {
    var onImages: (([ReferenceInput], [String]) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?
    private(set) var registeredForImages = false
    /// The current drag is images (decided once, when it enters).
    private var imageDrag = false

    // MARK: Paste

    override func paste(_ sender: Any?) { if !pasteImages() { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { if !pasteImages() { super.pasteAsPlainText(sender) } }
    override func pasteAsRichText(_ sender: Any?) { if !pasteImages() { super.pasteAsRichText(sender) } }

    /// Hands images on the general pasteboard to `onImages`; false = paste text as usual.
    private func pasteImages() -> Bool {
        guard let onImages, ReferencePasteboard.holdsImages(.general) else { return false }
        let read = ReferencePasteboard.read(.general, dataName: ReferenceTray.pastedName)
        onImages(read.inputs, read.notes)
        return true
    }

    /// A plain-text view disables Paste for a pasteboard that holds only an image (a screenshot);
    /// here it is enabled whenever there are images to attach.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        pastesImages(item.action) || super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        pastesImages(item.action) || super.validateMenuItem(item)
    }

    private func pastesImages(_ action: Selector?) -> Bool {
        let pastes: [Selector] = [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:))]
        guard let action, pastes.contains(action), onImages != nil, isEditable else { return false }
        return ReferencePasteboard.holdsImages(.general)
    }

    // MARK: Drops

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        guard onImages != nil else { return super.acceptableDragTypes }
        // Text, plus file URLs and image data, which are handled below. File promises (Photos) aren't
        // registered here, so they reach the card's SwiftUI drop target behind the text.
        return [.string, .fileURL] + ReferencePasteboard.imageTypes
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        registeredForImages = onImages != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageDrag = onImages != nil && ReferencePasteboard.holdsImages(sender.draggingPasteboard)
        guard imageDrag else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard imageDrag else { super.draggingExited(sender); return }
        imageDrag = false
        onDropTargeted?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        imageDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard imageDrag, let onImages else { return super.performDragOperation(sender) }
        let read = ReferencePasteboard.read(sender.draggingPasteboard, dataName: ReferenceTray.droppedName)
        onImages(read.inputs, read.notes)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard imageDrag else { super.concludeDragOperation(sender); return }
        imageDrag = false
        onDropTargeted?(false)
    }
}

/// Reads a pasteboard (⌘V or a drop onto the prompt) into reference inputs, by the rules in
/// ReferencePasteRules. Data stays in memory; nothing is written to disk.
@MainActor
enum ReferencePasteboard {
    /// Image data types a text view registers for drops (what browsers and apps put on a drag).
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                            NSPasteboard.PasteboardType("public.heic"),
                                                            NSPasteboard.PasteboardType("org.webmproject.webp"),
                                                            NSPasteboard.PasteboardType("com.compuserve.gif")]

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func itemTypes(_ pb: NSPasteboard) -> [[String]] {
        (pb.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    static func holdsImages(_ pb: NSPasteboard) -> Bool {
        ReferencePasteRules.classify(itemTypes: itemTypes(pb), fileURLs: fileURLs(pb)) == .images
    }

    static func read(_ pb: NSPasteboard, dataName: String) -> (inputs: [ReferenceInput], notes: [String]) {
        let items = pb.pasteboardItems ?? []
        return ReferencePasteRules.inputs(itemTypes: items.map { $0.types.map(\.rawValue) }, fileURLs: fileURLs(pb),
                                          data: { i, type in items.indices.contains(i) ? items[i].data(forType: NSPasteboard.PasteboardType(type)) : nil },
                                          dataName: dataName)
    }
}
