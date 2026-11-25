import AppKit
import CoreImage
import Foundation

private final class FixtureButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A test window on the remote Mac. Only interactions with this window are recorded.
@MainActor final class SessionCheck: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let folder: URL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 465),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "等待操作")
    private let input = NSTextField()
    private let tapTarget = FixtureButton()
    private let keyboardTarget = FixtureButton()
    private let qrContext = CIContext()
    private let expected = ProcessInfo.processInfo.environment["DESKLINK_PANEL_CHALLENGE"] ?? "PAD-" + String(UUID().uuidString.prefix(4))
    private var acceptedText = false
    private var clicks = 0
    private var inputFocusCount = 0
    private var sound: NSSound?

    init(folder: URL) {
        self.folder = folder
        super.init()
        window.title = "屏幕连线 · 真机连接测试"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let heading = NSTextField(labelWithString: "iPad 与 Mac 连接测试")
        heading.font = .systemFont(ofSize: 32, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString: "在 iPad 的远程桌面里操作此窗口。点按后会显示次数，音频按钮会播放一段短音。")
        let tone = NSButton(title: "播放测试音", target: self, action: #selector(playTone))
        let file = NSButton(title: "在 Finder 显示测试文件", target: self, action: #selector(showFile))
        tapTarget.title = "测试点按"
        tapTarget.action = #selector(pointer)
        keyboardTarget.title = "选中键盘输入框"
        keyboardTarget.action = #selector(focusInput)
        for button in [tapTarget, keyboardTarget] {
            button.target = self
            button.imagePosition = .imageAbove
            button.isBordered = false
        }
        updateTargets()
        for button in [tapTarget, keyboardTarget, tone, file] {
            button.controlSize = .large
            button.font = .systemFont(ofSize: 18)
        }
        let buttons = NSStackView(views: [tapTarget, keyboardTarget, tone, file])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let prompt = NSTextField(labelWithString: "键盘测试：输入 " + expected)
        prompt.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        input.placeholderString = "只输入上方的测试字符"
        input.font = .systemFont(ofSize: 23)
        input.delegate = self
        status.font = .systemFont(ofSize: 23, weight: .semibold)
        status.textColor = .systemTeal
        let stack = NSStackView(views: [heading, instructions, buttons, prompt, input, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 738)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -52), width,
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func present() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("DeskLink 文件传输测试\nRemote desktop fixture\n".utf8).write(to: folder.appending(path: "DeskLink-测试.txt"))
        sound = NSSound(named: "Glass")
        if let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            if ProcessInfo.processInfo.environment["DESKLINK_PANEL_CHALLENGE"] != nil {
                window.setFrame(area.insetBy(dx: 12, dy: 12), display: false)
            } else {
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                              y: area.midY - window.frame.height / 2))
            }
        } else {
            window.center()
        }
        window.orderFrontRegardless()
        record("test_window_ready")
        window.contentView?.layoutSubtreeIfNeeded()
        recordGeometry()
        updateTargets()
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window {
                let point = self.window.convertPoint(toScreen: event.locationInWindow)
                let screen = self.window.screen?.frame ?? .zero
                self.record("test_window_mouse_down", details: [
                    "screenX": String(Int(point.x - screen.minX)), "screenY": String(Int(screen.maxY - point.y))
                ])
            }
            return event
        }
    }

    @objc private func pointer() {
        clicks += 1
        status.stringValue = "已收到点按（\(clicks)）"
        record("test_button_clicked")
        updateTargets()
    }

    @objc private func focusInput() {
        input.stringValue = ""
        acceptedText = false
        window.makeKeyAndOrderFront(nil)
        if window.makeFirstResponder(input) {
            inputFocusCount += 1
            record("keyboard_target_focused")
        }
        updateTargets()
    }

    /// Each barcode is the clickable control itself. The iPad reads only the two matching fixture codes.
    private func updateTargets() {
        for (button, action) in [(tapTarget, "T"), (keyboardTarget, "K")] {
            let focus = window.isKeyWindow && input.currentEditor() != nil ? inputFocusCount : 0
            let screen = window.screen?.frame ?? .zero
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let position = window.convertPoint(toScreen: center)
            let coordinates = [screen.width, screen.height, position.x - screen.minX, screen.maxY - position.y]
                .map { String(Int($0.rounded())) }.joined(separator: "/")
            let text = "DL-M4/\(expected)/\(action)/\(clicks)/\(acceptedText ? 1 : 0)/\(focus)/\(coordinates)"
            guard let code = CIFilter(name: "CIQRCodeGenerator", parameters: [
                "inputMessage": Data(text.utf8), "inputCorrectionLevel": "M"
            ])?.outputImage else { continue }
            let border = code.extent.insetBy(dx: -4, dy: -4)
            let padded = code.composited(over: CIImage(color: .white).cropped(to: border))
            let enlarged = padded.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
            guard let image = qrContext.createCGImage(enlarged, from: enlarged.extent) else { continue }
            button.image = NSImage(cgImage: image, size: NSSize(width: 132, height: 132))
        }
    }

    @objc private func playTone() {
        guard let sound else { status.stringValue = "未找到系统测试音"; return }
        sound.stop()
        sound.currentTime = 0
        if sound.play() {
            status.stringValue = "Mac 已开始播放测试音"
            record("tone_started_on_mac")
        } else { status.stringValue = "测试音未能播放" }
    }

    @objc private func showFile() {
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "DeskLink-测试.txt")])
    }

    func controlTextDidChange(_ notification: Notification) {
        if !acceptedText && input.stringValue == expected {
            acceptedText = true
            status.stringValue = "测试字符一致"
            record("keyboard_challenge_matched")
            updateTargets()
        }
    }

    private func record(_ event: String, details: [String: String] = [:]) {
        var result = details
        result["event"] = event
        result["time"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: result) else { return }
        data.append(10)
        let file = folder.appending(path: "events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) }
        catch { status.stringValue = "测试结果未能写入" }
    }

    private func recordGeometry() {
        guard window.isVisible, let screen = window.screen else { return }
        let center = tapTarget.convert(NSPoint(x: tapTarget.bounds.midX, y: tapTarget.bounds.midY), to: nil)
        let position = window.convertPoint(toScreen: center)
        record("fixture_geometry", details: [
            "screenWidth": String(Int(screen.frame.width)), "screenHeight": String(Int(screen.frame.height)),
            "buttonX": String(Int(position.x - screen.frame.minX)), "buttonY": String(Int(screen.frame.maxY - position.y))
        ])
    }

    func windowDidMove(_ notification: Notification) { recordGeometry(); updateTargets() }
    func windowDidResignKey(_ notification: Notification) { updateTargets() }
    func windowDidBecomeKey(_ notification: Notification) { updateTargets() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

@main enum SessionCheckMain {
    @MainActor static func main() throws {
        let folder: URL
        if CommandLine.arguments.count == 2 {
            folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        } else if let fixturePath = Bundle.main.object(forInfoDictionaryKey: "DeskLinkFixtureDirectory") as? String {
            folder = URL(fileURLWithPath: fixturePath, isDirectory: true)
        } else {
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let check = SessionCheck(folder: folder)
        try check.present()
        withExtendedLifetime(check) { application.run() }
    }
}
