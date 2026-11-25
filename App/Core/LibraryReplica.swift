import Foundation

private struct Edition: Codable, Comparable, Sendable {
    let sequence: UInt64
    let writer: UUID
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence ? lhs.writer.uuidString < rhs.writer.uuidString : lhs.sequence < rhs.sequence
    }
}

private struct Revision<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let edition: Edition
    let value: Value
    func newer(_ other: Self) -> Self { edition < other.edition ? other : self }
}

/// Each device owns one file. Logical editions resolve concurrent edits to the
/// same entry, and a deleted entry retains its edition when another device is offline.
struct LibraryReplica: Codable, Equatable, Sendable {
    private var version = 1
    private var clock: UInt64 = 0
    private var computers: [UUID: Revision<Computer?>] = [:]
    private var deviceDisplays: [UUID: [String: Revision<DesktopDisplayPreferences?>]]?
    private var folders: [String: Revision<Bool>] = [:]
    private var order: Revision<[UUID]>?
    private var folderOrder: Revision<[String]>?
    private var preferences: [String: Revision<PreferenceValue?>]?

    var preferenceValues: [String: PreferenceValue] { preferences?.compactMapValues(\.value) ?? [:] }

    mutating func recordPreferences(from baseline: [String: PreferenceValue], to current: [String: PreferenceValue], writer: UUID) throws {
        guard baseline != current else { return }
        guard clock < UInt64.max - 1 else { throw CocoaError(.fileReadCorruptFile) }
        clock += 1
        let edition = Edition(sequence: clock, writer: writer)
        var values = preferences ?? [:]
        for key in Set(baseline.keys).union(current.keys) where baseline[key] != current[key] {
            values[key] = Revision(edition: edition, value: current[key])
        }
        preferences = values
    }

    mutating func record(from baseline: LibraryArchive, to local: LibraryArchive, writer: UUID) throws {
        guard baseline != local else { return }
        guard clock < UInt64.max - 1 else { throw CocoaError(.fileReadCorruptFile) }
        clock += 1
        let edition = Edition(sequence: clock, writer: writer)
        let before = Dictionary(uniqueKeysWithValues: baseline.computers.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: local.computers.map { ($0.id, $0) })
        for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
            let previousDisplays = before[id]?.deviceDisplays ?? [:]
            let newDisplays = after[id]?.deviceDisplays ?? [:]
            if previousDisplays != newDisplays {
                var revisions = deviceDisplays?[id] ?? [:]
                for client in Set(previousDisplays.keys).union(newDisplays.keys) where previousDisplays[client] != newDisplays[client] {
                    revisions[client] = Revision(edition: edition, value: newDisplays[client])
                }
                if deviceDisplays == nil { deviceDisplays = [:] }
                deviceDisplays?[id] = revisions
            }
            var previous = before[id], current = after[id]
            previous?.deviceDisplays = nil
            current?.deviceDisplays = nil
            if previous != current {
                // A successful connection updates independent per-device counts. Keep the
                // settings revision so activity alone cannot replace a concurrent edit.
                let onlyActivity = previous?.withoutConnectionActivity == current?.withoutConnectionActivity
                let settingsEdition = onlyActivity ? computers[id]?.edition ?? edition : edition
                computers[id] = Revision(edition: settingsEdition, value: current)
            }
        }
        let was = Set(baseline.folders), now = Set(local.folders)
        for name in was.symmetricDifference(now) { folders[name] = Revision(edition: edition, value: now.contains(name)) }
        if baseline.folders != local.folders { folderOrder = Revision(edition: edition, value: local.folders) }
        let ids = local.computers.map(\.id)
        if baseline.computers.map(\.id) != ids { order = Revision(edition: edition, value: ids) }
    }

    mutating func merge(_ other: Self) {
        clock = max(clock, other.clock)
        computers.merge(other.computers) { local, remote in
            let chosen = local.newer(remote)
            guard var entry = chosen.value, let left = local.value, let right = remote.value else { return chosen }
            entry.includeActivity(from: left)
            entry.includeActivity(from: right)
            return Revision(edition: chosen.edition, value: entry)
        }
        if let incoming = other.deviceDisplays {
            deviceDisplays = (deviceDisplays ?? [:]).merging(incoming) { local, remote in
                local.merging(remote) { $0.newer($1) }
            }
        }
        folders.merge(other.folders) { $0.newer($1) }
        if let otherOrder = other.order { order = order?.newer(otherOrder) ?? otherOrder }
        if let newFolders = other.folderOrder { folderOrder = folderOrder?.newer(newFolders) ?? newFolders }
        if let incoming = other.preferences {
            preferences = (preferences ?? [:]).merging(incoming) { $0.newer($1) }
        }
    }

    var archive: LibraryArchive {
        let names = Set(folders.compactMap { $0.value.value ? $0.key : nil })
        let entries = computers.compactMapValues(\.value)
        var result = LibraryArchive()
        let rankedFolders = (folderOrder?.value ?? []).filter(names.contains)
        result.folders = rankedFolders + names.subtracting(rankedFolders).sorted()
        let ranked = (order?.value ?? []).filter { entries[$0] != nil }
        let extra = Set(entries.keys).subtracting(ranked).sorted { $0.uuidString < $1.uuidString }
        result.computers = (ranked + extra).compactMap { id in
            guard var entry = entries[id] else { return nil }
            if let profiles = deviceDisplays?[id] {
                let active = profiles.compactMapValues(\.value)
                entry.deviceDisplays = active.isEmpty ? nil : active
            }
            if let folder = entry.folder, !names.contains(folder) { entry.folder = nil }
            return entry
        }
        return result
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let ids = value.order?.value ?? [], names = value.folderOrder?.value ?? []
        guard value.version == 1, value.clock < UInt64.max,
              Set(ids).count == ids.count, Set(names).count == names.count,
              value.computers.allSatisfy({ id, item in
                  item.edition.sequence <= value.clock && (item.value.map { $0.id == id } ?? true)
              }), value.folders.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.edition.sequence <= value.clock }),
              (value.order?.edition.sequence ?? 0) <= value.clock, (value.folderOrder?.edition.sequence ?? 0) <= value.clock else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (name, revision) in value.preferences ?? [:] {
            guard revision.edition.sequence <= value.clock else { throw CocoaError(.fileReadCorruptFile) }
            if let field = SyncedPreference(rawValue: name), let stored = revision.value, !field.accepts(stored) {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for profiles in (value.deviceDisplays ?? [:]).values {
            guard profiles.values.allSatisfy({ $0.edition.sequence <= value.clock && $0.value?.fixedDesktop?.isSupported != false }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        _ = try LibraryArchive.read(value.archive.encoded())
        return value
    }
}
