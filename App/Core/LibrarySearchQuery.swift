import Foundation

struct LibrarySearchQuery: Equatable {
    struct StoredMatches: Equatable {
        var saved: [Computer] = []
        var recent: [Computer] = []
        var links: [Computer] = []

        var isEmpty: Bool { saved.isEmpty && recent.isEmpty && links.isEmpty }
    }

    private let words: [String]

    init(_ input: String) {
        words = input.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    func matches(_ fields: [String?]) -> Bool {
        let values = fields.compactMap { $0 }
        return words.allSatisfy { word in values.contains { $0.localizedStandardContains(word) } }
    }

    func storedMatches(in computers: [Computer]) -> StoredMatches {
        let matching = computers.filter { matches([$0.displayName, $0.endpoint.address, $0.folder, $0.linkFolder]) }
        var results = StoredMatches()
        for item in ComputerOrder.name.arrange(matching) {
            if item.saved { results.saved.append(item) }
            else if item.isLink { results.links.append(item) }
            else if item.lastConnected != nil { results.recent.append(item) }
        }
        return results
    }
}
