#if DEBUG && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// A device-only acceptance run uses the usual connection form and session.
/// The named pasteboard stays inside the test library if the USB debugger drops.
@MainActor enum AppleClipboardPeer {
    struct Match: Codable, Equatable {
        let url: Bool
        let bold: Bool
        let png: Bool
        var complete: Bool { url && bold && png }
    }

    struct Receipt: Codable {
        let run: UUID
        var stage: String
        var macToIPad: Match?
    }

    private static var active: UUID?

    static func runIfRequested(library: ConnectionLibrary, board: UIPasteboard) async {
        let args = ProcessInfo.processInfo.arguments
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let input = option("--mac-clipboard-peer"), let host = try? Endpoint.hostOnly(input),
              let run = option("--test-library").flatMap(UUID.init(uuidString:)),
              board.name.rawValue == "local.nikey.desklink.tests." + run.uuidString, active == nil else { return }
        active = run
        defer { active = nil }
        let root = FileManager.default.temporaryDirectory.appending(path: "DeskLinkTests")
        let status = root.appending(path: run.uuidString + ".receipt.json")
        var report = Receipt(run: run, stage: "starting")
        func write(_ stage: String) throws {
            report.stage = stage
            try JSONEncoder().encode(report).write(to: status, options: .atomic)
        }
        do {
            let payload = try Data(contentsOf: root.appending(path: run.uuidString + ".pixels.plist"))
            let pixels = try PropertyListDecoder().decode([String: Data].self, from: payload)
            guard let macPNG = pixels["mac"], let ipadPNG = pixels["ipad"], !macPNG.isEmpty, !ipadPNG.isEmpty,
                  macPNG != ipadPNG else { throw CocoaError(.fileReadCorruptFile) }
            let selected = option("--mac-clipboard-saved").flatMap(UUID.init(uuidString:))
            func matches(_ item: Computer) -> Bool {
                let trim = CharacterSet(charactersIn: ".")
                return (selected == nil || selected == item.id) && item.ssh == nil && item.endpoint.port == 5900 &&
                    item.endpoint.host.trimmingCharacters(in: trim).lowercased() == host.trimmingCharacters(in: trim).lowercased()
            }
            let route: URL?
            if let selected {
                guard library.archive.computers.contains(where: matches) else { throw URLError(.badURL) }
                route = ConnectionRoute.savedURL(selected)
            } else {
                route = ConnectionRoute.sharing(try Endpoint(address: host), sshPort: nil)
            }
            let started = Date()
            guard let route, await UIApplication.shared.open(route) else { throw URLError(.cannotOpenFile) }
            try write("connection-form-requested")
            while !library.archive.computers.contains(where: { entry in
                guard matches(entry), (entry.lastConnected ?? .distantPast) >= started,
                      let sample = library.lastReport(for: entry.id) else { return false }
                return sample.startedAt >= started && !sample.usesVideo && sample.frames > 0 && sample.width > 0 && sample.height > 0
            }) {
                try await Task.sleep(for: .milliseconds(500))
            }
            try write("standard-session-connected")
            var incoming: Match?
            var inspected = -1
            while incoming == nil {
                if board.changeCount != inspected {
                    inspected = board.changeCount
                    incoming = match(board, role: "mac", run: run, png: macPNG)
                }
                if incoming == nil { try await Task.sleep(for: .milliseconds(250)) }
            }
            report.macToIPad = incoming
            try write("mac-to-ipad-received")
            try publish(board, role: "ipad", run: run, png: ipadPNG)
            try write("ipad-reply-published")
            let acknowledgment = "https://example.invalid/ack/" + run.uuidString
            let deadline = ContinuousClock.now + .seconds(90)
            while board.url?.absoluteString != acknowledgment && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            try write(board.url?.absoluteString == acknowledgment ? "both-directions-acknowledged" : "missing-mac-acknowledgment")
        } catch is CancellationError {
            try? write("window-closed")
        } catch {
            try? write("fixture-setup-failed")
        }
    }

    static func publish(_ board: UIPasteboard, role: String, run: UUID, png: Data) throws {
        let marker = role.uppercased() + "-" + run.uuidString
        let styled = NSAttributedString(string: marker, attributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = URL(string: "https://example.invalid/" + role + "/" + run.uuidString)!
        board.setItems([[UTType.url.identifier: url, UTType.rtf.identifier: rtf, UTType.png.identifier: png]], options: [.localOnly: true])
    }

    static func match(_ board: UIPasteboard, role: String, run: UUID, png: Data) -> Match? {
        let expectedURL = "https://example.invalid/" + role + "/" + run.uuidString
        let marker = role.uppercased() + "-" + run.uuidString
        var partial: Match?
        for index in 0..<board.numberOfItems {
            let item = IndexSet(integer: index)
            let url = board.values(forPasteboardType: UTType.url.identifier, inItemSet: item)?.first as? URL
            let pngMatched = board.data(forPasteboardType: UTType.png.identifier, inItemSet: item)?.first == png
            var bold = false, textMatched = false
            if let data = board.data(forPasteboardType: UTType.rtf.identifier, inItemSet: item)?.first,
               let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               let range = rich.string.range(of: marker) {
                textMatched = true
                let font = rich.attribute(.font, at: NSRange(range, in: rich.string).location, effectiveRange: nil) as? UIFont
                bold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true
            }
            let result = Match(url: url?.absoluteString == expectedURL, bold: bold, png: pngMatched)
            if result.complete { return result }
            if result.url || textMatched || pngMatched { partial = result }
        }
        return partial
    }
}
#endif
