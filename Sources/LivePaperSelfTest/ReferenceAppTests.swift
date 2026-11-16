// Self tests for the app side of reference images that the views rely on (ARCHITECTURE §11): what
// a paste or a drop onto the prompt becomes, the drop reader's size checks, the tray's failure
// hook and wording, thumbnails decoded from prepared images, and the check's "looks like the
// picture" line. The AppKit wrappers (PromptTextView, ReferencePasteboard) only gather pasteboard
// contents for these rules and are checked by hand; nothing here touches the user's clipboard.
import CoreGraphics
import Foundation
import ImageIO
import LivePaperCore
import UniformTypeIdentifiers

extension SelfTests {
    static var referenceAppUI: [TestCase] { [
        TestCase(name: "app.references.paste-inputs") { try ReferenceTests.pasteInputs() },
        TestCase(name: "app.references.drop-reader.limits") { try ReferenceTests.dropReaderLimits() },
        TestCase(name: "app.references.tray.failures") { try ReferenceTests.trayFailures() },
        TestCase(name: "app.references.wording") { try ReferenceTests.trayWording() },
        TestCase(name: "app.references.thumbnails") { try ReferenceTests.referenceThumbnails() },
        TestCase(name: "app.format.resemblance") { try ReferenceTests.resemblanceFormat() },
    ] }
}

extension ReferenceTests {
    static func pasteInputs() throws {
        typealias R = ReferencePasteRules
        let png = png(ReferenceFixtures.photo(.city, width: 30, height: 20))
        // A screenshot: one item, PNG then TIFF; the first image type is read.
        var asked: [(Int, String)] = []
        var read = R.inputs(itemTypes: [["public.png", "public.tiff"]], fileURLs: [], data: { i, t in asked.append((i, t)); return png })
        try expectEqual(read.inputs, [ReferenceInput(source: .data(png, typeIdentifier: "public.png"), role: .reference, displayName: ReferenceTray.pastedName)])
        try expect(read.notes.isEmpty && asked.count == 1 && asked[0] == (0, "public.png"), "\(asked)")
        // Several copied images (Photos): one input per item; an item without image data is skipped.
        read = R.inputs(itemTypes: [["public.jpeg"], ["public.utf8-plain-text"], ["public.heic", "public.tiff"]], fileURLs: [],
                        data: { _, _ in png }, dataName: ReferenceTray.droppedName)
        try expectEqual(read.inputs.map(\.displayName), [ReferenceTray.droppedName, ReferenceTray.droppedName])
        try expectEqual(read.inputs.map(\.source), [.data(png, typeIdentifier: "public.jpeg"), .data(png, typeIdentifier: "public.heic")])
        // A Finder copy: the images and folders (the tray expands folders); other files are left out
        // with one note instead of becoming failed tiles.
        let finder = [["public.file-url", "public.utf8-plain-text", "com.apple.icns", "public.tiff"]]
        let files = [URL(fileURLWithPath: "/tmp/a/heron.png"), URL(fileURLWithPath: "/tmp/a/notes.txt"), URL(fileURLWithPath: "/tmp/a/brief.docx"),
                     URL(fileURLWithPath: "/tmp/a/refs", isDirectory: true)]
        var reads = 0
        read = R.inputs(itemTypes: finder, fileURLs: files, data: { _, _ in reads += 1; return nil })
        try expectEqual(read.inputs, [files[0], files[3]].map { ReferenceInput.file($0) })
        try expectEqual(read.notes, ["Left out 2 files that aren't images."])
        // Text stays text: nothing to attach, nothing read.
        read = R.inputs(itemTypes: finder, fileURLs: [URL(fileURLWithPath: "/tmp/notes.txt")], data: { _, _ in reads += 1; return nil })
        try expect(read.inputs.isEmpty && read.notes.isEmpty)
        read = R.inputs(itemTypes: [["public.utf8-plain-text"]], fileURLs: [], data: { _, _ in reads += 1; return nil })
        try expect(read.inputs.isEmpty && read.notes.isEmpty)
        read = R.inputs(itemTypes: [["public.rtf", "public.tiff"]], fileURLs: [], data: { _, _ in reads += 1; return nil })
        try expect(read.inputs.isEmpty, "rich text with a picture in it pastes as text")
        try expectEqual(reads, 0)
        // Unreadable and oversized data: one actionable note each, nothing attached.
        read = R.inputs(itemTypes: [["public.png"]], fileURLs: [], data: { _, _ in nil })
        try expectEqual(read.notes, ["The pasted image couldn\u{2019}t be read."])
        read = R.inputs(itemTypes: [["public.png"]], fileURLs: [], data: { _, _ in png }, maxBytes: 64)
        try expect(read.inputs.isEmpty)
        try expectEqual(read.notes, [ReferenceError.tooLarge(name: "pasted image", bytes: png.count).localizedDescription])
        try expect(read.notes[0].contains("\u{201C}pasted image\u{201D} is"), read.notes[0])
    }

    static func dropReaderLimits() throws {
        let pngData = png(ReferenceFixtures.photo(.flowers, width: 40, height: 30))
        let dir = try tempDir("drop-limits").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = try write(pngData, dir.appendingPathComponent("promised.png"))
        // Data-backed (a browser), file-backed (Photos' promises arrive as files) and a named one.
        let dataProvider = NSItemProvider()
        dataProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in done(pngData, nil); return nil }
        let fileProvider = NSItemProvider()
        fileProvider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { done in
            done(backing, false, nil); return nil
        }
        fileProvider.suggestedName = "IMG_0042"
        var result: (inputs: [ReferenceInput], notes: [String])?
        try SelfTests.awaitMain { result = await ReferenceDropReader.inputs(from: [dataProvider, fileProvider]) }
        var r = try SelfTests.unwrap(result)
        try expectEqual(r.inputs.map(\.source), [.data(pngData, typeIdentifier: UTType.png.identifier), .data(pngData, typeIdentifier: UTType.png.identifier)])
        try expectEqual(r.inputs.map(\.displayName), [ReferenceTray.droppedName, "IMG_0042"])
        try expect(r.notes.isEmpty, "\(r.notes)")
        try expect(FileManager.default.fileExists(atPath: backing.path), "the provider's own file is left alone")
        // Over the limit: checked before the bytes are read, one note naming the image, no input.
        result = nil
        try SelfTests.awaitMain { result = await ReferenceDropReader.inputs(from: [dataProvider, fileProvider], dataName: ReferenceTray.pastedName, maxBytes: 64) }
        r = try SelfTests.unwrap(result)
        try expect(r.inputs.isEmpty)
        try expectEqual(r.notes, [ReferenceError.tooLarge(name: "pasted image", bytes: pngData.count).localizedDescription,
                                  ReferenceError.tooLarge(name: "IMG_0042", bytes: pngData.count).localizedDescription])
        // ⌘V outside the prompt box takes files and images, not web links (those paste as text).
        try expect(ReferenceDropReader.pasteTypes.contains(.image) && ReferenceDropReader.pasteTypes.contains(.fileURL))
        try expect(!ReferenceDropReader.pasteTypes.contains(.url))
    }

    static func trayFailures() throws {
        let dir = try tempDir("tray-failures").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakePrepare(template: try trayTemplate(dir))
        let dot = png(ReferenceFixtures.photo(.city, width: 30, height: 20))
        let good = try write(dot, dir.appendingPathComponent("good.png"))
        let bad1 = try write(Data("x".utf8), dir.appendingPathComponent("bad-one.png"))
        let bad2 = try write(Data("y".utf8), dir.appendingPathComponent("bad-two.png"))
        try MainActor.assumeIsolated {
            let tray = ReferenceTray(prepare: { try fake($0) })
            var batches: [[String]] = []
            tray.onFailures = { batches.append($0) }
            tray.addFiles([good, bad1, bad2])
            // Nothing shows until the files were looked at off the main thread, but the tray is busy
            // from the start, so Generate can't run with half of a folder.
            try expectEqual(tray.preparingCount, 0)
            try expect(tray.isBusy && tray.items.isEmpty)
            try SelfTests.awaitMain(until: { tray.items.count == 3 })
            try SelfTests.awaitMain { await tray.settled() }
            try SelfTests.awaitMain(until: { !tray.isBusy })
            try expectEqual(tray.preparingCount, 0)
            try expectEqual(batches.count, 1)
            try expectEqual(batches[0].count, 2)
            try expect(batches[0][0].contains("bad-one.png") && batches[0][1].contains("bad-two.png"), "\(batches)")
            try expectEqual(tray.failures.map(\.id), [tray.items[1].id, tray.items[2].id])
            try expectEqual(tray.failures.map(\.message), batches[0])
            tray.remove(tray.failures[0].id)
            try expectEqual(tray.failures.count, 1)
            // A batch without failures doesn't call the hook.
            tray.add([ReferenceInput(source: .data(dot, typeIdentifier: "public.png"), role: .reference, displayName: ReferenceTray.pastedName)])
            try SelfTests.awaitMain { await tray.settled() }
            try expectEqual(batches.count, 1)
            try expectEqual(tray.references.count, 2)
        }
    }

    static func trayWording() throws {
        let dir = try tempDir("tray-wording").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = try trayTemplate(dir)
        typealias T = ReferenceTrayText
        let ready = ReferenceTray.Item(id: UUID(), displayName: "sunset.heic", role: .animate, state: .ready(template), originPath: nil)
        try expectEqual(T.tileLabel(ready, index: 1, count: 4), "Reference image 2 of 4, sunset.heic, animate")
        var item = ready; item.role = .reference
        try expectEqual(T.tileLabel(item, index: 0, count: 1), "Reference image 1 of 1, sunset.heic, reference")
        item.state = .preparing
        try expectEqual(T.tileLabel(item, index: 0, count: 2), "Reference image 1 of 2, sunset.heic, preparing")
        item.state = .failed("It broke.")
        try expectEqual(T.tileLabel(item, index: 0, count: 2), "Reference image 1 of 2, sunset.heic, couldn\u{2019}t be added: It broke.")
        try expectEqual(T.preparing(0), nil)
        try expectEqual(T.preparing(1), "Preparing 1 image\u{2026}")
        try expectEqual(T.preparing(3), "Preparing 3 images\u{2026}")
        try expectEqual(T.preparing(2, busy: true), "Preparing 2 images\u{2026}")
        try expectEqual(T.preparing(0, busy: true), "Preparing images\u{2026}")

        let home = URL(fileURLWithPath: "/Users/someone")
        try expectEqual(T.location(of: home.appendingPathComponent("Desktop/refs"), home: home), " on your Desktop")
        try expectEqual(T.location(of: home.appendingPathComponent("Desktop/refs/a/b.png"), home: home), " on your Desktop")
        try expectEqual(T.location(of: home.appendingPathComponent("Downloads/x.jpg"), home: home), " in Downloads")
        try expectEqual(T.location(of: home.appendingPathComponent("Documents/x.jpg"), home: home), " in Documents")
        try expectEqual(T.location(of: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x.jpg"), home: home), " in iCloud Drive")
        try expectEqual(T.location(of: URL(fileURLWithPath: "/Volumes/Backup/photos/x.jpg"), home: home), " on \u{201C}Backup\u{201D}")
        try expectEqual(T.location(of: home.appendingPathComponent("Pictures/x.jpg"), home: home), "")
        try expectEqual(T.location(of: home.appendingPathComponent("Desktop"), home: home), "")   // the Desktop itself isn't on the Desktop

        let mentions = PromptPaths.mentions(in: "like ~/Desktop/refs/ and ~/Pictures/heron.png", home: home)
        try expectEqual(mentions.count, 2)
        try expectEqual(T.suggestion(mentions[0], home: home),
                        "The agent can\u{2019}t open \u{201C}refs\u{201D} on your Desktop. Attach copies of its images?")
        try expectEqual(T.suggestion(mentions[1], home: home), "The agent can\u{2019}t open \u{201C}heron.png\u{201D}. Attach a copy?")

        try expect(T.failureBanner([]) == nil)
        let one = try SelfTests.unwrap(T.failureBanner(["\u{201C}x.pdf\u{201D} isn't an image macOS can read (PDF document). Export it as PNG or JPEG."]))
        try expectEqual(one.title, "An image couldn\u{2019}t be added")
        try expect(one.message.hasPrefix("\u{201C}x.pdf\u{201D}"))
        let two = try SelfTests.unwrap(T.failureBanner(["First.", "Second."]))
        try expectEqual(two.title, "2 images couldn\u{2019}t be added")
        try expect(two.message.hasPrefix("First.") && !two.message.contains("Second."), two.message)
        try expect(T.referenceChoice.hasPrefix("Reference") && T.animateChoice.hasPrefix("Animate this image"))
        try expectEqual(T.sessionCaption(roles: [.animate]), "The scene shows this picture, brought to life. Trying again keeps it.")
        try expect(T.sessionCaption(roles: [.reference, .animate]).contains("the others are inspiration"))
        try expectEqual(T.sessionCaption(roles: [.reference]), "Inspiration for the scene. Trying again keeps it.")
        try expectEqual(T.sessionCaption(roles: [.reference, .reference]), "Inspiration for the scene. Trying again keeps them.")
    }

    static func referenceThumbnails() throws {
        let dir = try tempDir("ref-thumbs").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = try prepare(write(jpeg(ReferenceFixtures.photo(.lake, width: 900, height: 600)), dir.appendingPathComponent("lake.jpg")))
        let cache = ThumbnailCache()
        let id = reference.id.uuidString
        var first: CGImage?, again: CGImage?, larger: CGImage?
        try SelfTests.awaitMain { first = await cache.load(data: reference.vision.data, id: id, maxPixel: 176) }
        let image = try SelfTests.unwrap(first)
        try expectEqual(max(image.width, image.height), 176)
        try expect(abs(Double(image.width) / Double(image.height) - 1.5) < 0.02, "3:2 kept: \(image.width)x\(image.height)")
        try expect(cache.cached(ThumbnailCache.key(dataID: id, maxPixel: 176)) === image)
        try SelfTests.awaitMain { again = await cache.load(data: Data(), id: id, maxPixel: 176) }
        try expect(again === image, "cached by id: the bytes behind an id never change")
        try SelfTests.awaitMain { larger = await cache.load(data: reference.vision.data, id: id, maxPixel: 240) }
        try expectEqual(max(larger?.width ?? 0, larger?.height ?? 0), 240)
        try expect(ThumbnailCache.key(dataID: id, maxPixel: 176) != ThumbnailCache.key(URL(fileURLWithPath: "/\(id)"), revision: 0, maxPixel: 176))
        var broken: CGImage? = image
        try SelfTests.awaitMain { broken = await cache.load(data: Data("nope".utf8), id: UUID().uuidString, maxPixel: 176) }
        try expect(broken == nil)
    }

    static func resemblanceFormat() throws {
        func summary(referenced: Bool = true, median: Double?) -> ReferenceCheckSummary {
            ReferenceCheckSummary(asset: "assets/reference.jpg", assetIntact: true, referencedInScene: referenced,
                                  similarity: ["1512x982@2 t=12": median ?? 0], median: median)
        }
        try expectEqual(LPFormat.resemblance(summary(median: 0.9234)), "0.92")
        try expectEqual(LPFormat.resemblance(summary(median: 0.2)), "0.20")
        try expectEqual(LPFormat.resemblance(summary(median: nil)), "not compared")
        try expectEqual(LPFormat.resemblance(summary(referenced: false, median: 0.1)), "not shown (scene.js never loads it)")
    }
}
