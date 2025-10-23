//
//  SearchViewModel.swift
//  amp
//
//  Created by zen on 7/14/25.
//


import Foundation
import Combine

// ViewModel for the Search View
@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var searchResults = SearchResults(artists: [], albums: [], songs: [])
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?

    func performSearch() {
        searchTask?.cancel()
        
        let currentSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Add safety checks for search text
        guard !currentSearchText.isEmpty && currentSearchText.count < 100 else {
            self.searchResults = SearchResults(artists: [], albums: [], songs: [])
            self.isSearching = false
            return
        }
        
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // Debounce
                
                // Add timeout to prevent infinite searches
                let results = try await withThrowingTaskGroup(of: SearchResults.self) { group in
                    group.addTask {
                        await LibraryService.shared.search(for: currentSearchText)
                    }
                    
                    // Add timeout task
                    group.addTask {
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 second timeout
                        throw SearchError.timeout
                    }
                    
                    // Return the first result (either search results or timeout)
                    for try await result in group {
                        group.cancelAll()
                        return result
                    }
                    
                    return SearchResults(artists: [], albums: [], songs: [])
                }
                
                // This check ensures we only update for the latest search term
                if currentSearchText == self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                    await MainActor.run {
                        self.searchResults = results
                        self.isSearching = false
                    }
                }
            } catch SearchError.timeout {
                print("Search timed out for: \(currentSearchText)")
                await MainActor.run {
                    self.isSearching = false
                }
            } catch is CancellationError {
                // Task was cancelled (normal when user types quickly)
                // No need to log or update state - the new search is already running
            } catch {
                // Only log unexpected errors
                print("Unexpected search error: \(error)")
                await MainActor.run {
                    self.isSearching = false
                }
            }
        }
    }
}

private enum SearchError: Error {
    case timeout
}
