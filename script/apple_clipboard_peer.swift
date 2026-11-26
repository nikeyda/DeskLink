import AppKit
import Foundation

struct MacReceipt: Codable {
    let run: UUID
    let urlString: Bool
    let urlNative: Bool
    let urlPropertyList: Bool
    let bold: Bool
    let png: Bool
}

// Run only when the user has authorized replacing the Mac's current clipboard.
let observingReply = CommandLine.arguments.count == 5 && CommandLine.arguments[4] == "--observe-reply"
guard CommandLine.arguments.count == 4 || observingReply, let run = UUID(uuidString: CommandLine.arguments[1]) else {
    fatalError("Pass the matching test UUID, fixture directory and receipt path.")
}
let folder = URL(filePath: CommandLine.arguments[2])
let receiptFile = URL(filePath: CommandLine.arguments[3])
let pixels = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: folder.appending(path: "clipboard-pixels.plist")))
guard let macPNG = pixels["mac"], let ipadPNG = pixels["ipad"], !macPNG.isEmpty, !ipadPNG.isEmpty, macPNG != ipadPNG else {
    fatalError("Two distinct PNG fixtures are required.")
}
let pasteboard = NSPasteboard.general
let token = run.uuidString
let styled = NSAttributedString(string: "MAC-" + token, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
func sourceItem() -> NSPasteboardItem {
    let source = NSPasteboardItem()
    source.setString("https://example.invalid/mac/" + token, forType: .URL)
    source.setData(rtf, forType: .rtf)
    source.setData(macPNG, forType: .png)
    return source
}

func publish(_ item: NSPasteboardItem) {
    pasteboard.prepareForNewContents(with: .currentHostOnly)
    precondition(pasteboard.writeObjects([item]))
}

if !observingReply { publish(sourceItem()) }
var initial = observingReply ? -1 : pasteboard.changeCount
var lastAnnouncement = Date()
print(observingReply ? "Waiting for the existing iPad reply" : "Mac fixture ready")
fflush(stdout)
let expectedURL = "https://example.invalid/ipad/" + token
let deadline = Date().addingTimeInterval(165)
var inspectedCount = initial
var verified = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    if !observingReply, pasteboard.changeCount == initial, Date().timeIntervalSince(lastAnnouncement) >= 10 {
        publish(sourceItem())
        initial = pasteboard.changeCount
        lastAnnouncement = Date()
    }
    let count = pasteboard.changeCount
    guard count != initial, count != inspectedCount else { continue }
    inspectedCount = count
    let items = pasteboard.pasteboardItems ?? []
    for item in items {
        let pngMatched = item.data(forType: .png) == ipadPNG
        let exactString = item.string(forType: .URL) == expectedURL
        let archived = item.data(forType: .URL).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String]
        } == [expectedURL, ""]
        guard pngMatched || exactString || archived else { continue }
        let native = items.count == 1 && (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?
            .contains { $0.absoluteString == expectedURL } == true
        var bold = false
        if let data = item.data(forType: .rtf),
           let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           let range = rich.string.range(of: "IPAD-" + token) {
            let font = rich.attribute(.font, at: NSRange(range, in: rich.string).location, effectiveRange: nil) as? NSFont
            bold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        print("iPad to Mac: urlString=\(exactString) urlNative=\(native) urlPropertyList=\(archived) bold=\(bold) png=\(pngMatched)")
        fflush(stdout)
        if (exactString || native) && bold && pngMatched {
            let receipt = MacReceipt(run: run, urlString: exactString, urlNative: native, urlPropertyList: archived, bold: bold, png: pngMatched)
            try JSONEncoder().encode(receipt).write(to: receiptFile, options: .atomic)
            verified = true
            break
        }
    }
    if verified { break }
}
guard verified else { print("No matching iPad URL, bold RTF and PNG receipt"); exit(1) }
print("Mac verified iPad URL, bold RTF and PNG")
let ack = NSPasteboardItem()
ack.setString("https://example.invalid/ack/" + token, forType: .URL)
publish(ack)
