import Foundation
import Observation
import RFBTransport
import rootshellVNC

enum PictureQuality: String, Codable, CaseIterable, Sendable { case standard, adaptive, lossless }
enum ColorDepth: Int, Codable, CaseIterable, Sendable { case low = 8, medium = 16, full = 32 }
enum DisplayLayout: String, Codable, CaseIterable, Sendable { case single, combined, virtualPair }

struct DesktopDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var isSupported: Bool { (1...1920).contains(width) && (1...1080).contains(height) }
    static let standard = DesktopDimensions(width: 1440, height: 900)
}

enum DisplayClient: String, Codable, Sendable {
    case mac, iPad

    static var current: Self {
        #if targetEnvironment(macCatalyst)
        .mac
        #else
        .iPad
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
}

struct Computer: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var endpoint: Endpoint
    var username = ""
    var saved = true
    var favorite = false
    var folder: String?
    var lastConnected: Date?
    var modifiedAt: Date?
    private(set) var connectionCounts: [String: UInt64]?
    var viewOnly = false
    var quality = PictureQuality.standard
    var colorDepth: ColorDepth?
    var disconnectAction: VNCDisconnectAction?
    var layout = DisplayLayout.single
    var matchWindow = false
    var fixedDesktop: DesktopDimensions?
    var retinaResolution: Bool?
    var smoothVideo: Bool?
    var remoteAudio = true
    var deviceDisplays: [String: DesktopDisplayPreferences]?
    var trackpad = false
    var framebufferQuality: FramebufferQuality?
    var momentumScrolling: Bool?
    var ssh: SSHSettings?

    init(name: String = "", endpoint: Endpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    var displayName: String { name.isEmpty ? endpoint.host : name }

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
        if connectionCounts != nil || other.connectionCounts != nil {
            connectionCounts = observedCounts.merging(other.observedCounts, uniquingKeysWith: max)
        }
        if let date = other.lastConnected { lastConnected = max(date, lastConnected ?? date) }
    }

    var withoutConnectionActivity: Self {
        var copy = self
        copy.lastConnected = nil
        copy.connectionCounts = nil
        return copy
    }

    func hasSameDestination(as other: Self) -> Bool {
        endpoint == other.endpoint && username == other.username && ssh == other.ssh
    }

    fileprivate var withoutSessionHistory: Self {
        var copy = withoutConnectionActivity
        for client in [DisplayClient.mac, .iPad] {
            var profile = copy.display(for: client)
            profile.lastMonitor = nil
            profile.windowedMonitors = nil
            copy.setDisplay(profile, for: client)
        }
        return copy
    }

    func display(for client: DisplayClient) -> DesktopDisplayPreferences {
        deviceDisplays?[client.rawValue] ?? legacyDisplay
    }

    mutating func setDisplay(_ value: DesktopDisplayPreferences, for client: DisplayClient) {
        var profiles = deviceDisplays ?? [:]
        profiles[client.rawValue] = value == legacyDisplay ? nil : value
        deviceDisplays = profiles.isEmpty ? nil : profiles
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

    var widgetComputers: [ComputerEntity] {
        computers.filter { $0.saved || $0.lastConnected != nil }.map {
            ComputerEntity(id: $0.id, name: $0.displayName, address: $0.endpoint.address)
        }
    }

    func duplicate(of computer: Computer) -> Computer {
        var copy = computer.withoutSessionHistory
        copy.id = UUID()
        copy.modifiedAt = nil
        copy.favorite = false
        copy.saved = true
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
              Set(archive.computers.map(\.id)).count == archive.computers.count,
              Set(archive.folders).count == archive.folders.count,
              archive.folders.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              archive.computers.allSatisfy({ entry in
                  entry.fixedDesktop?.isSupported != false &&
                      entry.deviceDisplays?.values.contains(where: { $0.fixedDesktop?.isSupported == false }) != true
              }),
              archive.computers.allSatisfy({ entry in
                  guard let ssh = entry.ssh else { return true }
                  return ssh.port > 0 && !ssh.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && (ssh.server == nil || ssh.server.flatMap { try? Endpoint.hostOnly($0) } == ssh.server)
              }),
              archive.computers.allSatisfy({ $0.folder.map(archive.folders.contains) ?? true }) else {
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
}

@MainActor @Observable
final class ConnectionLibrary {
    private(set) var archive = LibraryArchive()
    var errorMessage: String?
    private let file: URL
    private let reportDirectory: URL
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
            if let folder = computer.folder, !value.folders.contains(folder) { value.folders.append(folder) }
            if let i = value.computers.firstIndex(where: { $0.id == computer.id }) {
                value.computers[i] = computer
            } else {
                value.computers.append(computer)
            }
        }
    }

    func recordSuccess(_ computer: Computer, now: Date = .now) {
        var entry = existingComputer(matching: computer) ?? computer
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
        }
        guard let data = try? JSONEncoder().encode(report) else { return }
        let file = reportDirectory.appending(path: entry.id.uuidString).appendingPathExtension("json")
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func installArchive(_ next: LibraryArchive) {
        let destinations = Dictionary(uniqueKeysWithValues: next.computers.map { ($0.id, $0) })
        let previousRetryCount = videoRetryDates.count
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
    func addFolder(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return change { if !$0.folders.contains(name) { $0.folders.append(name) } }
    }

    @discardableResult
    func renameFolder(_ old: String, to input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard archive.folders.contains(old), !name.isEmpty, name == old || !archive.folders.contains(name) else { return false }
        return change { value in
            value.folders = value.folders.map { $0 == old ? name : $0 }
            for i in value.computers.indices where value.computers[i].folder == old { value.computers[i].folder = name }
        }
    }

    @discardableResult
    func removeFolder(_ name: String) -> Bool {
        change { value in
            value.folders.removeAll { $0 == name }
            for i in value.computers.indices where value.computers[i].folder == name { value.computers[i].folder = nil }
        }
    }

    @discardableResult
    func applySync(_ value: LibraryArchive) -> Bool {
        let savedChanged = value.folders != archive.folders ||
            value.computers.filter(\.saved).map(\.withoutSessionHistory) !=
            archive.computers.filter(\.saved).map(\.withoutSessionHistory)
        return change(backup: savedChanged) { $0 = value }
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
        let saved = change { state in
            state.folders.append(contentsOf: folders)
            state.computers.append(contentsOf: additions)
        }
        guard saved else { return nil }
        return ArchiveImportResult(connections: additions.count, folders: folders.count,
                                   duplicates: imported.computers.count - additions.count)
    }

    @discardableResult
    private func change(backup: Bool = true, _ edit: (inout LibraryArchive) -> Void) -> Bool {
        guard !loadFailed else { errorMessage = CocoaError(.fileReadCorruptFile).localizedDescription; return false }
        var next = archive
        edit(&next)
        guard next != archive else { return true }
        do {
            if backup, !archive.computers.isEmpty || !archive.folders.isEmpty { try backups.capture(archive.encoded()) }
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
