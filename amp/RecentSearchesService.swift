import Foundation
import Combine

// Spec §7.2: Search's recent-queries list. Capped at 10, deduped case-
// insensitively with the most recent on top. Persisted to UserDefaults —
// nothing here needs the heft of SwiftData.

final class RecentSearchesService: ObservableObject {
    static let shared = RecentSearchesService()

    private static let storageKey = "amp.recentSearches"
    private static let maxCount = 10

    @Published private(set) var recents: [String]

    private init() {
        self.recents = (UserDefaults.standard.array(forKey: Self.storageKey) as? [String]) ?? []
    }

    func addRecent(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recents.insert(trimmed, at: 0)
        if recents.count > Self.maxCount {
            recents = Array(recents.prefix(Self.maxCount))
        }
        persist()
    }

    func clearAll() {
        recents = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(recents, forKey: Self.storageKey)
    }
}
