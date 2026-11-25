import CoreSpotlight
import XCTest
@testable import DeskLink

@MainActor final class SearchIndexTests: XCTestCase {
    func testSavedComputerIsFindableRenamedAndRemoved() async throws {
        try XCTSkipUnless(CSSearchableIndex.isIndexingAvailable(), "Core Spotlight is unavailable in this environment")
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let domain = "DeskLinkIndexTest" + suffix
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let index = ComputerSearchIndex(name: domain, defaults: defaults)
        let original = ComputerEntity(id: UUID(), name: "DeskLinkOriginal" + suffix, address: "fixture.invalid")
        let renamed = ComputerEntity(id: original.id, name: "DeskLinkUpdated" + suffix, address: original.address)
        do {
            await index.refresh([original])
            try await waitForTitle(original.name, present: true)
            await index.refresh([renamed])
            try await waitForTitle(renamed.name, present: true)
            try await waitForTitle(original.name, present: false)
            await index.refresh([])
            try await waitForTitle(renamed.name, present: false)
        } catch {
            await index.refresh([])
            throw error
        }
    }

    private func waitForTitle(_ title: String, present: Bool) async throws {
        let end = ContinuousClock.now + .seconds(12)
        repeat {
            let context = CSSearchQueryContext()
            context.fetchAttributes = ["title", "displayName"]
            let query = CSSearchQuery(queryString: "(title == \"\(title)\"c || displayName == \"\(title)\"c)", queryContext: context)
            query.protectionClasses = [.complete]
            var found = false
            for try await match in query.results {
                let attributes = match.item.attributeSet
                if attributes.title == title || attributes.displayName == title { found = true }
            }
            if found == present { return }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < end
        throw NSError(domain: "DeskLink.SpotlightTest", code: present ? 1 : 2,
                      userInfo: [NSLocalizedDescriptionKey: present ? "Saved title was not indexed" : "A removed title was still indexed"])
    }
}
