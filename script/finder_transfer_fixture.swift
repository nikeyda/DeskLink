import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// The test owns this directory. A resumed run must have the exact same sample.
guard CommandLine.arguments.count == 3 else { exit(2) }
let run = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let tag = CommandLine.arguments[2]
guard tag.range(of: #"^[A-F0-9]{8}$"#, options: .regularExpression) != nil else { exit(2) }
let folder = run.appendingPathComponent("Telescope-" + tag, isDirectory: true)
let source = folder.appendingPathComponent("Mac-" + tag + "-样本.txt")
let contents = "Mac-" + tag + "-样本\nTelescope 拖放验收 Ω\n"
let bytes = Data(contents.utf8)
if FileManager.default.fileExists(atPath: folder.path) {
    let metadata = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard metadata.isRegularFile == true, metadata.isSymbolicLink == false,
          try Data(contentsOf: source) == bytes else { exit(2) }
} else {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try bytes.write(to: source, options: .withoutOverwriting)
}

let context = CIContext()
func marker(_ value: String) -> NSImage {
    let code = CIFilter.qrCodeGenerator()
    code.message = Data(value.utf8)
    code.correctionLevel = "L"
    let pixels = code.outputImage!
    let white = CIImage(color: .white).cropped(to: pixels.extent.insetBy(dx: -4, dy: -4))
    let scaled = pixels.composited(over: white).transformed(by: .init(scaleX: 12, y: 12))
    let bitmap = context.createCGImage(scaled, from: scaled.extent)!
    return NSImage(cgImage: bitmap, size: NSSize(width: 128, height: 128))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.main?.frame,
      NSWorkspace.shared.setIcon(marker("F" + tag), forFile: source.path, options: []) else { exit(3) }
NSWorkspace.shared.activateFileViewerSelecting([source])
var panels: [NSPanel] = []
for (prefix, x) in [("L", 0.15), ("R", 0.85)] {
    let rect = CGRect(x: screen.minX + x * screen.width - 55,
                      y: screen.maxY - 0.10 * screen.height - 55, width: 110, height: 110)
    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let view = NSImageView(frame: CGRect(origin: .zero, size: rect.size))
    view.image = marker(prefix + tag)
    view.imageScaling = .scaleAxesIndependently
    panel.contentView = view
    panel.orderFrontRegardless()
    panels.append(panel)
}
let geometry = ["width": screen.width, "height": screen.height]
try JSONEncoder().encode(geometry).write(to: run.appendingPathComponent("geometry.json"), options: .atomic)

// Return control to Swift on SIGTERM so the host script also cleans up after a failed test.
signal(SIGTERM, SIG_IGN)
let stopped = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let stop: @Sendable () -> Void = {
    DispatchQueue.main.async {
        NSWorkspace.shared.setIcon(nil, forFile: source.path, options: [])
        app.terminate(nil)
    }
}
stopped.setEventHandler { stop() }
stopped.resume()
Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { _ in stop() }
app.run()
