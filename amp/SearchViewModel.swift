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
        
        let currentSearchText = searchText
        if currentSearchText.isEmpty {
            self.searchResults = SearchResults(artists: [], albums: [], songs: [])
            self.isSearching = false
            return
        }
        
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // Debounce
                
                // Use the real service on a physical device
                let results = await LibraryService.shared.search(for: currentSearchText)
                
                // This check ensures we only update for the latest search term
                if currentSearchText == self.searchText {
                    self.searchResults = results
                }
            } catch {
                print("Search task cancelled.")
            }
            isSearching = false
        }
    }
}
