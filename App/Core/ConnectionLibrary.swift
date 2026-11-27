import Foundation
import Observation
import RFBTransport
import rootshellVNC
#if !targetEnvironment(macCatalyst)
import UIKit
#endif

enum DesktopAuthentication: Int, Codable, CaseIterable, Sendable {
    case automatic = 0
    case vncPassword = 2
    case unauthenticated = 3
    case raspberryPiRSA = 5

    var usesPassword: Bool { self != .unauthenticated }
    var usesUsername: Bool { self == .automatic || self == .raspberryPiRSA }
}

enum PictureQuality: String, Codable, CaseIterable, Sendable { case standard, adaptive, lossless }
enum ColorDepth: Int, Codable, CaseIterable, Sendable { case low = 8, medium = 16, full = 32 }
enum DisplayLayout: String, Codable, CaseIterable, Sendable { case single, combined, virtualPair }

struct DesktopDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var isSupported: Bool { (1...1920).contains(width) && (1...1080).contains(height) }
    static let standard = DesktopDimensions(width: 1440, height: 900)
}

enum DisplayClient: String, Codable, CaseIterable, Sendable {
    case mac, iPad, iPhone, vision

    @MainActor static var current: Self {
        #if targetEnvironment(macCatalyst)
        .mac
        #elseif os(visionOS)
        .vision
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? .iPhone : .iPad
        #endif
    }
}

struct DesktopDisplayPreferences: Codable, Equatable, Sendable {
    var quality = PictureQuality.standard
    var colorDepth: ColorDepth?
    var layout = DisplayLayout.single
    var matchWindow = false
    var fixedDesktop: DesktopDimensions?
    var retinaResolution: Bool?
    var smoothVideo: Bool?
    var remoteAudio = true
    var rememberMonitor: Bool?
    var lastMonitor: VNCMonitorSelection?
    var windowedMonitors: [UInt32]?

    /// Older archives can contain a shared display layout from another client.
    /// Resolve it for this connection without changing the archived preferences.
    func resolved(for client: DisplayClient) -> Self {
        var result = self
        if layout == .virtualPair, (client != .mac && client != .vision) || quality != .adaptive {
            result.layout = .single
        }
        if result.layout == .combined {
            result.matchWindow = false
            result.fixedDesktop = nil
        } else if quality == .adaptive {
            if result.layout == .virtualPair, result.fixedDesktop == nil {
                result.fixedDesktop = .standard
            }
            if result.fixedDesktop != nil { result.matchWindow = true }
        } else {
            result.fixedDesktop = nil
        }
        return result
    }
}

enum LibraryFolderScope: CaseIterable, Sendable { case custom, links }

enum CursorTrackingSpeed {
    static let range = 0.5...2.0
    static let choices = Array(stride(from: range.lowerBound, through: range.upperBound, by: 0.25))

    static func validated(_ value: Double?) -> Double? {
        guard let value, range.contains(value) else { return nil }
        return value
    }
}

struct Computer: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var endpoint: Endpoint
    var username = ""
    var saved = true
    var favorite = false
    var folder: String?
    var linkFolder: String?
    var openedFromLink: Bool?
    var lastConnected: Date?
    var modifiedAt: Date?
    private(set) var connectionCounts: [String: UInt64]?
    var viewOnly = false
    var curtainsDisplayOnConnect: Bool?
    var curtainMessage: String?
    var quality = PictureQuality.standard
    var colorDepth: ColorDepth?
    var disconnectAction: VNCDisconnectAction?
    var savesDisconnectScreenshot: Bool?
    var layout = DisplayLayout.single
    var matchWindow = false
    var fixedDesktop: DesktopDimensions?
    var retinaResolution: Bool?
    var smoothVideo: Bool?
    var remoteAudio = true
    var deviceDisplays: [String: DesktopDisplayPreferences]?
    // Preserve the original Boolean so older versions can still read the connection.
    private var trackpad = false
    private var inheritsPointerMode: Bool?
    var cursorTrackingSpeed: Double?
    var allowsViewportZoom: Bool?
    var initialViewportSizing: RemoteViewportSizing?
    var showsLocalCursor: Bool?
    var usesFallbackCursor: Bool?
    var touchHoldDuration: TimeInterval?
    var preparesTigerVNCKeyboard: Bool?
    var usesMacHardwareKeyPositions: Bool?
    var swapsHardwareCommandAndControl: Bool?
    var framebufferQuality: FramebufferQuality?
    var disabledVNCCodecs: [Int32]?
    var screensOperatingSystem: Int?
    var screensAuthenticationMethod: Int?
    private var selectedDesktopAuthentication: DesktopAuthentication?

    var authentication: DesktopAuthentication {
        get {
            selectedDesktopAuthentication
                ?? (screensAuthenticationMethod == DesktopAuthentication.raspberryPiRSA.rawValue ? .raspberryPiRSA : .automatic)
        }
        set {
            guard newValue != authentication else { return }
            selectedDesktopAuthentication = newValue == .automatic || newValue == .raspberryPiRSA ? nil : newValue
            if !newValue.usesUsername { username = "" }
            screensAuthenticationMethod = newValue == .automatic ? nil : newValue.rawValue
            if newValue == .raspberryPiRSA {
                // The original Raspberry Pi profile uses 5 for both fields.
                screensOperatingSystem = 5
            } else if screensOperatingSystem == nil && newValue != .automatic {
                screensOperatingSystem = 6
            }
        }
    }
    var usesRaspberryPiRSAAES: Bool {
        get { authentication == .raspberryPiRSA }
        set {
            if newValue { authentication = .raspberryPiRSA }
            else if authentication == .raspberryPiRSA { authentication = .automatic }
        }
    }

    var automaticallySharesClipboard: Bool?
    var allowsRemoteBell: Bool?
    var momentumScrolling: Bool?
    var pcScrollSpeed: RemoteScrollSpeed?
    var ssh: SSHSettings?

    init(name: String = "", endpoint: Endpoint) {
        self.name = name
        self.endpoint = endpoint
        usesMacHardwareKeyPositions = true
        openedFromLink = false
        inheritsPointerMode = true
    }

    var displayName: String { name.isEmpty ? endpoint.host : name }
    var automaticCurtainMessage: String? { curtainsDisplayOnConnect == true ? (curtainMessage ?? "") : nil }
    var pointerModeOverride: RemotePointerMode? {
        get { inheritsPointerMode == true ? nil : (trackpad ? .trackpad : .direct) }
        set {
            trackpad = newValue == .trackpad
            inheritsPointerMode = newValue == nil ? true : nil
        }
    }

    func pointerMode(using preferences: UserDefaults) -> RemotePointerMode {
        pointerModeOverride ?? preferences.string(forKey: SyncedPreference.pointerMode.rawValue)
            .flatMap(RemotePointerMode.init(rawValue:)) ?? .direct
    }

    func scrollSpeed(forMac: Bool) -> RemoteScrollSpeed {
        forMac ? .standard : pcScrollSpeed ?? .standard
    }
    // Older libraries kept successful temporary connections without recording their source.
    var isLink: Bool { openedFromLink ?? (!saved && lastConnected != nil) }

    func folder(in scope: LibraryFolderScope) -> String? { scope == .links ? linkFolder : folder }

    mutating func setFolder(_ name: String?, in scope: LibraryFolderScope) {
        if scope == .links { linkFolder = name } else { folder = name }
    }

    private var observedCounts: [String: UInt64] {
        connectionCounts ?? (lastConnected == nil ? [:] : ["legacy": 1])
    }

    var totalConnections: UInt64 {
        observedCounts.values.reduce(0) { total, value in
            let sum = total.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    mutating func recordConnection(at date: Date, writer: UUID) {
        var counts = observedCounts
        let key = writer.uuidString
        let old = counts[key, default: 0]
        counts[key] = old == .max ? old : old + 1
        connectionCounts = counts
        lastConnected = max(date, lastConnected ?? date)
    }

    mutating func includeActivity(from other: Self) {
        if other.isLink { openedFromLink = true }
        if connectionCounts != nil || other.connectionCounts != nil {
            connectionCounts = observedCounts.merging(other.observedCounts, uniquingKeysWith: max)
        }
        if let date = other.lastConnected { lastConnected = max(date, lastConnected ?? date) }
    }

    var withoutConnectionActivity: Self {
        var copy = self
        copy.lastConnected = nil
        copy.connectionCounts = nil
        copy.openedFromLink = nil
        return copy
    }

    func hasSameDestination(as other: Self) -> Bool {
        guard endpoint == other.endpoint, username == other.username,
              authentication.usesPassword == other.authentication.usesPassword else { return false }
        if let ssh, let route = other.ssh { return ssh.sameDestination(as: route) }
        return ssh == nil && other.ssh == nil
    }

    fileprivate var withoutSessionHistory: Self {
        var copy = withoutConnectionActivity
        for client in DisplayClient.allCases {
            var profile = copy.display(for: client)
            profile.lastMonitor = nil
            profile.windowedMonitors = nil
            copy.setDisplay(profile, for: client)
        }
        return copy
    }

    func display(for client: DisplayClient) -> DesktopDisplayPreferences {
        deviceDisplays?[client.rawValue] ?? inheritedDisplay(for: client)
    }

    mutating func setDisplay(_ value: DesktopDisplayPreferences, for client: DisplayClient, explicit: Bool = false) {
        var profiles = deviceDisplays ?? [:]
        // An explicit phone profile must stay independent of later tablet edits.
        let keepsPhoneProfile = client == .iPhone && (explicit || profiles[client.rawValue] != nil)
        profiles[client.rawValue] = value == inheritedDisplay(for: client) && !keepsPhoneProfile ? nil : value
        deviceDisplays = profiles.isEmpty ? nil : profiles
    }

    private func inheritedDisplay(for client: DisplayClient) -> DesktopDisplayPreferences {
        if client == .iPhone, let tablet = deviceDisplays?[DisplayClient.iPad.rawValue] { return tablet }
        return legacyDisplay
    }

    private var legacyDisplay: DesktopDisplayPreferences {
        DesktopDisplayPreferences(quality: quality, colorDepth: colorDepth, layout: layout, matchWindow: matchWindow,
                                  fixedDesktop: fixedDesktop, retinaResolution: retinaResolution,
                                  smoothVideo: smoothVideo, remoteAudio: remoteAudio)
    }
}

enum ComputerOrder: String, CaseIterable {
    case manual, name, lastConnected, count, modified

    var title: String {
        switch self {
        case .manual: "自定顺序"
        case .name: "名称"
        case .lastConnected: "最近连接时间"
        case .count: "连接次数"
        case .modified: "最近修改时间"
        }
    }

    func arrange(_ entries: [Computer]) -> [Computer] {
        switch self {
        case .manual: entries
        case .name: entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .lastConnected: entries.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        case .count: entries.sorted { $0.totalConnections > $1.totalConnections }
        case .modified: entries.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }
    }
}

struct LibraryArchive: Codable, Equatable, Sendable {
    var version = 1
    var folders: [String] = []
    var computers: [Computer] = []
    private(set) var linkFolders: [String]?
    var screensDirectoryFolders: ScreensDirectoryFolders?

    var folderCount: Int { folders.count + (linkFolders?.count ?? 0) + (screensDirectoryFolders?.count ?? 0) }

    func folders(in scope: LibraryFolderScope) -> [String] { scope == .links ? linkFolders ?? [] : folders }

    mutating func setFolders(_ names: [String], in scope: LibraryFolderScope) {
        if scope == .links { linkFolders = names.isEmpty ? nil : names } else { folders = names }
    }

    var widgetComputers: [ComputerEntity] {
        computers.filter { $0.saved || $0.isLink }.map {
            ComputerEntity(id: $0.id, name: $0.displayName, address: $0.endpoint.address)
        }
    }

    func widgetComputers(including directory: [ComputerEntity]) -> [ComputerEntity] {
        let library = widgetComputers
        var ids = Set(library.map(\.id))
        return library + directory.filter { ids.insert($0.id).inserted }
    }

    func duplicate(of computer: Computer) -> Computer {
        var copy = computer.withoutSessionHistory
        copy.id = UUID()
        copy.modifiedAt = nil
        copy.favorite = false
        copy.saved = true
        copy.openedFromLink = false
        copy.linkFolder = nil
        let base = computer.displayName + " 副本"
        let names = Set(computers.filter(\.saved).map { $0.displayName.lowercased() })
        copy.name = base
        var suffix = 2
        while names.contains(copy.name.lowercased()) {
            copy.name = "\(base) \(suffix)"
            suffix += 1
        }
        return copy
    }

    static func read(_ data: Data) throws -> Self {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.version == 1,
              archive.screensDirectoryFolders?.isValid != false,
              Set(archive.computers.map(\.id)).count == archive.computers.count,
              LibraryFolderScope.allCases.allSatisfy({ scope in
                  let names = archive.folders(in: scope)
                  return Set(names).count == names.count && names.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }),
              archive.computers.allSatisfy({ entry in
                  entry.fixedDesktop?.isSupported != false &&
                      entry.deviceDisplays?.values.contains(where: { $0.fixedDesktop?.isSupported == false }) != true
              }),
              archive.computers.allSatisfy({ entry in
                  guard let ssh = entry.ssh else { return true }
                  return ssh.port > 0 && !ssh.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && (ssh.server == nil || ssh.server.flatMap { try? Endpoint.hostOnly($0) } == ssh.server)
              }),
              archive.computers.allSatisfy({ entry in
                  (entry.folder.map(archive.folders.contains) ?? true) &&
                      (entry.linkFolder.map { entry.isLink && archive.folders(in: .links).contains($0) } ?? true)
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct ArchiveImportResult: Equatable {
    var connections = 0
    var folders = 0
    var duplicates = 0
    var directoryFolders = 0
    var importedScreens = false
}

@MainActor @Observable
final class ConnectionLibrary {
    private(set) var archive = LibraryArchive()
    var errorMessage: String?
    private let file: URL
    private let reportDirectory: URL
    private let previewDirectory: URL
    private(set) var previews: [UUID: SavedDesktopPreview] = [:]
    @ObservationIgnored private var pendingPreviews: [UUID: Task<Void, Never>] = [:]
    private var videoRetryDates: [UUID: Date] = [:]
    private let activityWriter: UUID
    let backups: LibraryBackups
    private var loadFailed = false
    var canSync: Bool { !loadFailed }

    init(file customFile: URL? = nil, activityWriter: UUID? = nil) {
        let file = customFile ?? URL.applicationSupportDirectory.appending(path: "DeskLink/library.json")
        self.file = file
        if let activityWriter { self.activityWriter = activityWriter }
        else if customFile != nil { self.activityWriter = UUID() }
        else {
            let key = "library.activityWriter"
            let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
            self.activityWriter = stored ?? UUID()
            if stored == nil { UserDefaults.standard.set(self.activityWriter.uuidString, forKey: key) }
        }
        reportDirectory = customFile?.deletingPathExtension().appendingPathExtension("session-reports")
            ?? URL.cachesDirectory.appending(path: "DeskLink/SessionReports")
        previewDirectory = file.deletingPathExtension().appendingPathExtension("previews")
        backups = LibraryBackups(library: file)
        do {
            archive = try LibraryArchive.read(Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new library is written on the first edit.
        } catch {
            loadFailed = true
            errorMessage = error.localizedDescription
        }
        if let data = try? Data(contentsOf: videoRetryFile),
           let dates = try? PropertyListDecoder().decode([UUID: Date].self, from: data) {
            videoRetryDates = dates
        }
        for computer in archive.computers where computer.saved && computer.savesDisconnectScreenshot == true {
            let url = previewURL(for: computer.id)
            if FileManager.default.fileExists(atPath: url.path) {
                previews[computer.id] = SavedDesktopPreview(computerID: computer.id, url: url)
            }
        }
    }

    private func previewURL(for id: UUID) -> URL {
        previewDirectory.appending(path: id.uuidString).appendingPathExtension("png")
    }

    func saveDisconnectScreenshot(for computer: Computer, frame: VNCPresentedFrame, region: CGRect?) {
        guard computer.savesDisconnectScreenshot == true,
              let entry = archive.computers.first(where: { $0.id == computer.id }),
              entry.saved, entry.savesDisconnectScreenshot == true, entry.hasSameDestination(as: computer) else { return }
        do {
            let image = try RemoteScreenshot.image(from: frame, region: region)
            let id = entry.id
            pendingPreviews[id]?.cancel()
            pendingPreviews[id] = Task {
                let encoded = await Task.detached(priority: .utility) { Result { try RemoteScreenshot.pngData(for: image) } }.value
                guard !Task.isCancelled else { return }
                defer { pendingPreviews[id] = nil }
                do {
                    let data = try encoded.get()
                    var directory = previewDirectory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try directory.setResourceValues(values)
                    let url = previewURL(for: id)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    previews[id] = SavedDesktopPreview(computerID: id, url: url)
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func clearPreview(for id: UUID) {
        pendingPreviews.removeValue(forKey: id)?.cancel()
        do { try FileManager.default.removeItem(at: previewURL(for: id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { errorMessage = error.localizedDescription }
        previews[id] = nil
    }

    @discardableResult
    func save(_ computer: Computer, now: Date = .now) -> Bool {
        var entry = computer
        let previous = archive.computers.first { $0.id == entry.id }
        if let previous { entry.includeActivity(from: previous) }
        entry.modifiedAt = previous?.modifiedAt
        if entry.withoutSessionHistory != previous?.withoutSessionHistory { entry.modifiedAt = now }
        return store(entry, backup: true)
    }

    @discardableResult
    private func store(_ computer: Computer, backup: Bool) -> Bool {
        change(backup: backup) { value in
            for scope in LibraryFolderScope.allCases {
                let names = value.folders(in: scope)
                if let folder = computer.folder(in: scope), !names.contains(folder) {
                    value.setFolders(names + [folder], in: scope)
                }
            }
            if let i = value.computers.firstIndex(where: { $0.id == computer.id }) {
                value.computers[i] = computer
            } else {
                value.computers.append(computer)
            }
        }
    }

    func recordSuccess(_ computer: Computer, now: Date = .now) {
        var entry = existingComputer(matching: computer) ?? computer
        if computer.openedFromLink == true { entry.openedFromLink = true }
        entry.recordConnection(at: now, writer: activityWriter)
        store(entry, backup: false)
    }

    func existingComputer(matching computer: Computer) -> Computer? {
        archive.computers.first(where: { $0.id == computer.id }) ??
            archive.computers.first(where: { $0.hasSameDestination(as: computer) })
    }

    private var videoRetryFile: URL { reportDirectory.appending(path: "video-retry-dates.plist") }

    func videoRetryDate(for computer: Computer, now: Date = .now) -> Date? {
        guard let entry = existingComputer(matching: computer), entry.hasSameDestination(as: computer),
              let date = videoRetryDates[entry.id], date > now else { return nil }
        return date
    }

    @discardableResult
    func pauseStreaming(for computer: Computer, now: Date = .now) -> Bool {
        guard let entry = existingComputer(matching: computer), entry.hasSameDestination(as: computer) else { return false }
        guard videoRetryDate(for: entry, now: now) == nil else { return true }
        videoRetryDates = videoRetryDates.filter { $0.value > now }
        videoRetryDates[entry.id] = now.addingTimeInterval(24 * 60 * 60)
        persistVideoRetryDates()
        return true
    }

    func resumeStreaming(for computer: Computer) {
        guard let entry = existingComputer(matching: computer), entry.hasSameDestination(as: computer),
              videoRetryDates.removeValue(forKey: entry.id) != nil else { return }
        persistVideoRetryDates()
    }

    private func persistVideoRetryDates() {
        do {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            try PropertyListEncoder().encode(videoRetryDates).write(to: videoRetryFile, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    func lastReport(for id: UUID) -> ConnectionReport? {
        let file = reportDirectory.appending(path: id.uuidString).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ConnectionReport.self, from: data)
    }

    func keepReport(_ report: ConnectionReport, for computer: Computer) {
        guard let entry = existingComputer(matching: computer), entry.hasSameDestination(as: computer) else { return }
        if let previous = lastReport(for: entry.id) {
            guard report.startedAt > previous.startedAt ||
                (report.startedAt == previous.startedAt && report.capturedAt > previous.capturedAt) else { return }
            guard report.hasReceivedMedia || !previous.hasReceivedMedia else { return }
        }
        guard let data = try? JSONEncoder().encode(report) else { return }
        let file = reportDirectory.appending(path: entry.id.uuidString).appendingPathExtension("json")
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private var diagnosticFailuresFile: URL {
        reportDirectory.appending(path: "diagnostic-failures.json")
    }

    private func diagnosticFailures() -> [SupportDiagnostics.Failure] {
        guard let data = try? Data(contentsOf: diagnosticFailuresFile) else { return [] }
        return (try? JSONDecoder().decode([SupportDiagnostics.Failure].self, from: data)) ?? []
    }

    func recordDiagnosticFailure(_ failure: SupportDiagnostics.Failure) {
        var failures = diagnosticFailures()
        if let previous = failures.first(where: { $0.id == failure.id }),
           previous.reason != .unknown, failure.reason == .unknown { return }
        failures.removeAll { $0.id == failure.id }
        failures.insert(failure, at: 0)
        let recent = Array(failures.prefix(SupportDiagnostics.recordLimit))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try? data.write(to: diagnosticFailuresFile, options: .atomic)
    }

    func supportDiagnostics(now: Date = .now) -> SupportDiagnostics {
        let reports = archive.computers.compactMap { lastReport(for: $0.id) }.sorted { $0.capturedAt > $1.capturedAt }
        return SupportDiagnostics(exportedAt: now, connections: Array(reports.prefix(SupportDiagnostics.recordLimit)),
                                  failures: diagnosticFailures())
    }

    private func installArchive(_ next: LibraryArchive) {
        let destinations = Dictionary(uniqueKeysWithValues: next.computers.map { ($0.id, $0) })
        let previousRetryCount = videoRetryDates.count
        for previous in archive.computers where previous.savesDisconnectScreenshot == true {
            let next = destinations[previous.id]
            if next?.saved != true || next?.savesDisconnectScreenshot != true || next?.hasSameDestination(as: previous) != true {
                clearPreview(for: previous.id)
            }
        }
        for previous in archive.computers where destinations[previous.id]?.hasSameDestination(as: previous) != true {
            videoRetryDates.removeValue(forKey: previous.id)
            let file = reportDirectory.appending(path: previous.id.uuidString).appendingPathExtension("json")
            try? FileManager.default.removeItem(at: file)
        }
        if videoRetryDates.count != previousRetryCount { persistVideoRetryDates() }
        archive = next
    }

    func rememberMonitor(_ choice: VNCMonitorSelection, for computer: Computer, windowed: [UInt32] = []) {
        guard var entry = existingComputer(matching: computer) else { return }
        var display = entry.display(for: .current)
        let children = windowed.isEmpty ? nil : windowed
        guard display.rememberMonitor != false,
              display.lastMonitor != choice || display.windowedMonitors != children else { return }
        display.lastMonitor = choice
        display.windowedMonitors = children
        entry.setDisplay(display, for: .current)
        store(entry, backup: false)
    }

    @discardableResult
    func addFolder(_ name: String, in scope: LibraryFolderScope = .custom) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return change { value in
            let names = value.folders(in: scope)
            if !names.contains(name) { value.setFolders(names + [name], in: scope) }
        }
    }

    @discardableResult
    func renameFolder(_ old: String, to input: String, in scope: LibraryFolderScope = .custom) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = archive.folders(in: scope)
        guard names.contains(old), !name.isEmpty, name == old || !names.contains(name) else { return false }
        return change { value in
            value.setFolders(names.map { $0 == old ? name : $0 }, in: scope)
            for i in value.computers.indices where value.computers[i].folder(in: scope) == old {
                value.computers[i].setFolder(name, in: scope)
            }
        }
    }

    @discardableResult
    func removeFolder(_ name: String, in scope: LibraryFolderScope = .custom) -> Bool {
        change { value in
            value.setFolders(value.folders(in: scope).filter { $0 != name }, in: scope)
            for i in value.computers.indices where value.computers[i].folder(in: scope) == name {
                value.computers[i].setFolder(nil, in: scope)
            }
        }
    }

    @discardableResult
    func applySync(_ value: LibraryArchive) -> Bool {
        let knownLinks = Set(archive.computers.lazy.filter(\.isLink).map(\.id))
        func shouldBackUp(_ computer: Computer) -> Bool {
            // A new, unedited link can come from recent activity on another device.
            computer.saved || (computer.isLink && (knownLinks.contains(computer.id)
                || computer.modifiedAt != nil || computer.linkFolder != nil))
        }
        let libraryChanged = value.folders != archive.folders || value.linkFolders != archive.linkFolders ||
            value.screensDirectoryFolders != archive.screensDirectoryFolders ||
            value.computers.filter(shouldBackUp).map(\.withoutSessionHistory) !=
            archive.computers.filter(shouldBackUp).map(\.withoutSessionHistory)
        return change(backup: libraryChanged) { $0 = value }
    }

    func remove(_ computer: Computer) {
        change { $0.computers.removeAll { $0.id == computer.id } }
    }

    func move(_ source: UUID, to target: UUID, within visible: Set<UUID>) -> Bool {
        var ids = archive.computers.map(\.id).filter(visible.contains)
        guard source != target, let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(source, at: to)
        return reorder(ids)
    }

    func reorder(_ ids: [UUID]) -> Bool {
        let visible = Set(ids)
        let slots = archive.computers.indices.filter { visible.contains(archive.computers[$0].id) }
        guard slots.count == ids.count, visible.count == ids.count else { return false }
        let items = Dictionary(uniqueKeysWithValues: slots.map { slot in
            let item = archive.computers[slot]
            return (item.id, item)
        })
        return change { state in
            for (slot, id) in zip(slots, ids) {
                if let item = items[id] { state.computers[slot] = item }
            }
        }
    }

    @discardableResult
    func importArchive(_ data: Data) throws -> ArchiveImportResult? {
        let imported = try LibraryArchive.read(data)
        let existingIDs = Set(archive.computers.map(\.id))
        let additions = imported.computers.filter { !existingIDs.contains($0.id) }
        let folders = imported.folders.filter { !archive.folders.contains($0) }
        let linkFolders = imported.folders(in: .links).filter { !archive.folders(in: .links).contains($0) }
        var directories = archive.screensDirectoryFolders ?? ScreensDirectoryFolders()
        let earlierDirectoryCount = directories.count
        if let incoming = imported.screensDirectoryFolders { directories.addMissing(from: incoming) }
        let saved = change { state in
            state.folders.append(contentsOf: folders)
            state.setFolders(state.folders(in: .links) + linkFolders, in: .links)
            state.computers.append(contentsOf: additions)
            state.screensDirectoryFolders = directories.count > 0 ? directories : nil
        }
        guard saved else { return nil }
        return ArchiveImportResult(connections: additions.count, folders: folders.count + linkFolders.count,
                                   duplicates: imported.computers.count - additions.count,
                                   directoryFolders: directories.count - earlierDirectoryCount)
    }

    @discardableResult
    private func change(backup: Bool = true, _ edit: (inout LibraryArchive) -> Void) -> Bool {
        guard !loadFailed else { errorMessage = CocoaError(.fileReadCorruptFile).localizedDescription; return false }
        var next = archive
        edit(&next)
        guard next != archive else { return true }
        do {
            if backup, !archive.computers.isEmpty || archive.folderCount > 0 {
                try backups.capture(archive.encoded())
            }
            let data = try next.encoded()
            try writePrimary(data)
            installArchive(next)
            if backup {
                do { try backups.capture(data) }
                catch { errorMessage = error.localizedDescription }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restore(_ backup: LibraryBackup) throws {
        let restored = try backups.read(backup.id)
        guard loadFailed || restored != archive else { return }
        if loadFailed {
            try backups.preserveUnreadablePrimary(Data(contentsOf: file))
        } else {
            try backups.capture(archive.encoded())
        }
        try writePrimary(restored.encoded())
        installArchive(restored)
        loadFailed = false
        errorMessage = nil
    }

    private func writePrimary(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
