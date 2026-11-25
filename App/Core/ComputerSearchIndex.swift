import AppIntents
import CoreSpotlight
import Foundation
import os

@MainActor
final class ComputerSearchIndex {
    private let name: String
    private let defaults: UserDefaults
    private let knownIDsKey = "search.computerIDs"
    private var latest: [ComputerEntity]?
    private var published: [ComputerEntity]?
    private var updating = false

    init(name: String = "DeskLinkComputers", defaults: UserDefaults = .standard) {
        self.name = name
        self.defaults = defaults
    }

    func refresh(_ entries: [ComputerEntity]) async {
        latest = entries
        guard !updating, CSSearchableIndex.isIndexingAvailable() else { return }
        updating = true
        defer { updating = false }
        while let desired = latest {
            latest = nil
            guard desired != published else { continue }
            let known = Set((defaults.stringArray(forKey: knownIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
            let wanted = Set(desired.map(\.id))
            // Retain all possibly indexed IDs until both operations finish.
            defaults.set(known.union(wanted).map(\.uuidString), forKey: knownIDsKey)
            do {
                try await Self.write(name: name, removing: Array(known.subtracting(wanted)), desired: desired)
                defaults.set(wanted.map(\.uuidString), forKey: knownIDsKey)
                published = desired
            } catch {
                published = nil
                Logger(subsystem: "local.nikey.desklink", category: "Spotlight")
                    .error("Could not update the computer index: \((error as NSError).code)")
            }
        }
    }

    private nonisolated static func write(name: String, removing: [UUID], desired: [ComputerEntity]) async throws {
        let index = CSSearchableIndex(name: name, protectionClass: .complete)
        if !removing.isEmpty { try await index.deleteAppEntities(identifiedBy: removing, ofType: ComputerEntity.self) }
        if !desired.isEmpty { try await index.indexAppEntities(desired) }
    }
}
