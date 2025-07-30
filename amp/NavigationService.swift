import Foundation
import SwiftUI

class NavigationService: ObservableObject {
    @Published var selectedTab: Tab = .queue
    
    func navigateToNowPlaying() {
        selectedTab = .nowPlaying
    }
    
    func navigateToQueue() {
        selectedTab = .queue
    }
    
    func navigateToSearch() {
        selectedTab = .search
    }
    
    func navigateToPlaylists() {
        selectedTab = .playlists
    }
}