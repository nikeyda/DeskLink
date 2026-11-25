import AppKit
import Foundation

let files = FileManager.default
let work = URL(filePath: files.currentDirectoryPath)
let source = work.appending(path: ".build/Xcode/Build/Products/Release-maccatalyst/DeskLink.app")
let destination = files.homeDirectoryForCurrentUser.appending(path: "Applications/DeskLink.app")
let expectedID = "local.nikey.desklink"

func verify(_ bundle: URL) throws {
    guard Bundle(url: bundle)?.bundleIdentifier == expectedID else { throw CocoaError(.executableLoad) }
    let verify = Process()
    verify.executableURL = URL(filePath: "/usr/bin/codesign")
    verify.arguments = ["--verify", "--deep", "--strict", bundle.path]
    try verify.run()
    verify.waitUntilExit()
    guard verify.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

try verify(source)
let parent = destination.deletingLastPathComponent()
try files.createDirectory(at: parent, withIntermediateDirectories: true)
let staging = parent.appending(path: ".DeskLink-\(UUID().uuidString).app")
try files.copyItem(at: source, to: staging)
defer { if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) } }
try verify(staging)
if files.fileExists(atPath: destination.path) {
    try verify(destination)
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: expectedID)
        where app.bundleURL?.standardizedFileURL.path == destination.standardizedFileURL.path {
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard app.isTerminated else { throw CocoaError(.userCancelled) }
    }
    _ = try files.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
} else {
    try files.moveItem(at: staging, to: destination)
}
try verify(destination)
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
print("\(destination.path)   \(plist?["CFBundleDisplayName"] ?? "")  \(plist?["CFBundleShortVersionString"] ?? "") (\(plist?["CFBundleVersion"] ?? ""))")
