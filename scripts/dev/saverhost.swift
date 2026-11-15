// saverhost — loads a .saver bundle the way the screen-saver host does (NSBundle principal
// class -> ScreenSaverView(frame:isPreview:)), runs it in an off-screen window and snapshots the
// web view. Also renders the Options sheet to a PNG. A minimal smoke test for any saver; for
// LivePaper.saver use saverhost-lp.swift, which drives the full scenario (lock gate, clock hand-off,
// video, fallback) in the same single launch.
//
//   saverhost <bundle.saver> <out-dir> [--size 1512x982] [--wait 4] [--preview]
import AppKit
import ScreenSaver
import WebKit

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: saverhost <bundle.saver> <out-dir> [--size WxH] [--wait s] [--preview]"); exit(2) }
let bundlePath = args.removeFirst(), outDir = args.removeFirst()
var size = NSSize(width: 1512, height: 982), wait = 4.0, preview = false
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--size", let v = args.first { args.removeFirst(); let p = v.split(separator: "x").compactMap { Double($0) }; if p.count == 2 { size = NSSize(width: p[0], height: p[1]) } }
    else if a == "--wait", let v = args.first { args.removeFirst(); wait = Double(v) ?? wait }
    else if a == "--preview" { preview = true }
}

func fail(_ s: String) -> Never { print("FAIL: \(s)"); exit(1) }
func writePNG(_ rep: NSBitmapImageRep, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
}
func findWebViews(_ v: NSView) -> [WKWebView] { (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(findWebViews) }

let app = NSApplication.shared
// .prohibited: the process can never become active, so it cannot steal focus.
app.setActivationPolicy(.prohibited)
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

DispatchQueue.main.async {
    guard let bundle = Bundle(path: bundlePath) else { fail("cannot open bundle") }
    guard bundle.load() else { fail("bundle.load() failed") }
    guard let cls = bundle.principalClass as? ScreenSaverView.Type else { fail("principal class is not a ScreenSaverView: \(String(describing: bundle.principalClass))") }
    print("principal class: \(NSStringFromClass(cls))")
    guard let view = cls.init(frame: NSRect(origin: .zero, size: size), isPreview: preview) else { fail("init returned nil") }
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = view
    win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    win.orderFrontRegardless()
    view.startAnimation()
    print("hasConfigureSheet: \(view.hasConfigureSheet)")

    // Options sheet -> PNG
    if let sheet = view.configureSheet, let content = sheet.contentView {
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.setFrameOrigin(NSPoint(x: -30000, y: -29000))
        sheet.orderFrontRegardless()
        sheet.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        print("sheet size: \(content.bounds.size), subviews: \(content.subviews.count)")
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            writePNG(rep, "options-sheet.png")
        }
    } else { print("WARN: no configure sheet") }

    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        let webs = findWebViews(view)
        print("web views: \(webs.count), alpha: \(webs.map { $0.alphaValue })")
        guard let wv = webs.last else { fail("no WKWebView was created") }
        wv.evaluateJavaScript("[document.documentElement.getAttribute('data-livepaper'), document.title, (document.getElementById('livepaper-errors')||{}).textContent||'', JSON.stringify(window.LIVEPAPER_CONFIG||null)]") { res, err in
            print("page state: \(String(describing: res)) \(err.map { "\($0)" } ?? "")")
            let sc = WKSnapshotConfiguration()
            wv.takeSnapshot(with: sc) { img, err in
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fail("snapshot failed \(String(describing: err))") }
                writePNG(rep, "saver-\(Int(size.width))x\(Int(size.height))\(preview ? "-preview" : "").png")
                exit(0)
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + wait + 20) { fail("timeout") }
app.run()
