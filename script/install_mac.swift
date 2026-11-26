import AppKit
import Foundation

let files = FileManager.default
let work = URL(filePath: files.currentDirectoryPath)
let source = work.appending(path: ".build/Xcode/Build/Products/Release-maccatalyst/Telescope.app")
let applications = files.homeDirectoryForCurrentUser.appending(path: "Applications")
let destination = applications.appending(path: "Telescope.app")
let legacyDestination = applications.appending(path: "DeskLink.app")
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
try files.createDirectory(at: applications, withIntermediateDirectories: true)
let staging = applications.appending(path: ".DeskLink-\(UUID().uuidString).app")
try files.copyItem(at: source, to: staging)
defer { if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) } }
try verify(staging)
let installed = files.fileExists(atPath: destination.path) ? destination : legacyDestination
if files.fileExists(atPath: installed.path) {
    try verify(installed)
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: expectedID)
        where app.bundleURL?.standardizedFileURL.path == installed.standardizedFileURL.path {
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard app.isTerminated else { throw CocoaError(.userCancelled) }
    }
    _ = try files.replaceItemAt(installed, withItemAt: staging, options: .usingNewMetadataOnly)
    if installed == legacyDestination { try files.moveItem(at: legacyDestination, to: destination) }
} else {
    try files.moveItem(at: staging, to: destination)
}
try verify(destination)
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
print("\(destination.path)   \(plist?["CFBundleDisplayName"] ?? "")  \(plist?["CFBundleShortVersionString"] ?? "") (\(plist?["CFBundleVersion"] ?? ""))")
