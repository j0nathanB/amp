import Foundation
import UserNotifications
import UIKit
import MediaPlayer

class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()
    
    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    
    private let notificationIdentifier = "track-change-notification"
    private var lastNotificationTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 2.0
    
    // User preference for notifications
    var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "songChangeNotificationsEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "songChangeNotificationsEnabled")
            objectWillChange.send()
        }
    }
    
    override init() {
        super.init()
        setupNotificationCategories()
        checkAuthorizationStatus()
        // Enable notifications by default for new users
        if UserDefaults.standard.object(forKey: "songChangeNotificationsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "songChangeNotificationsEnabled")
        }
    }
    
    // MARK: - Permission Management
    
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.isAuthorized = granted
                self.checkAuthorizationStatus()
            }
            print("🔔 Notification permission granted: \(granted)")
            return granted
        } catch {
            print("❌ Failed to request notification permission: \(error)")
            await MainActor.run {
                self.isAuthorized = false
                self.authorizationStatus = .denied
            }
            return false
        }
    }
    
    private func checkAuthorizationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                self.authorizationStatus = settings.authorizationStatus
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
    
    // MARK: - Notification Scheduling
    
    func scheduleTrackChangeNotification(song: Song, artwork: UIImage? = nil, isManualSelection: Bool = false) {
        // Check if notifications should be sent
        guard shouldSendNotification(isManualSelection: isManualSelection) else {
            return
        }
        
        // Debounce rapid track changes
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastNotificationTime < debounceInterval {
            print("🔔 Debouncing notification - too soon since last one")
            return
        }
        lastNotificationTime = currentTime
        
        Task {
            await sendTrackChangeNotification(song: song, artwork: artwork)
        }
    }
    
    private func shouldSendNotification(isManualSelection: Bool) -> Bool {
        // Don't send if disabled by user
        guard isEnabled else {
            print("🔔 Notifications disabled by user")
            return false
        }
        
        // Don't send if not authorized
        guard isAuthorized else {
            print("🔔 Notifications not authorized")
            return false
        }
        
        // Don't send for manual selections (user-initiated track changes)
        if isManualSelection {
            print("🔔 Skipping notification for manual track selection")
            return false
        }
        
        // Check app state and current view - ensure UI API calls are on main thread
        var appState: UIApplication.State = .active
        var selectedTab: Tab = .nowPlaying
        
        if Thread.isMainThread {
            appState = UIApplication.shared.applicationState
            selectedTab = AudioPlayerService.shared.selectedTab
        } else {
            // Use MainActor to safely access UI APIs
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                appState = UIApplication.shared.applicationState
                selectedTab = AudioPlayerService.shared.selectedTab
                semaphore.signal()
            }
            semaphore.wait()
        }
        
        // Send notification if app is backgrounded OR user is not on Now Playing view
        if appState == .background {
            print("🔔 Will send notification - app is backgrounded")
            return true
        } else if appState == .active && selectedTab != .nowPlaying {
            print("🔔 Will send notification - app active but not on Now Playing view (current: \(selectedTab))")
            return true
        } else {
            print("🔔 Skipping notification - app active and on Now Playing view")
            return false
        }
    }
    
    private func sendTrackChangeNotification(song: Song, artwork: UIImage?) async {
        // Remove any existing notifications with the same identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        
        let content = UNMutableNotificationContent()
        content.title = song.title.isEmpty ? "Unknown Song" : song.title
        content.subtitle = song.artist.isEmpty ? "Unknown Artist" : song.artist
        content.body = song.album.isEmpty ? "" : song.album
        content.sound = nil
        content.categoryIdentifier = "TRACK_CHANGE"
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
            content.relevanceScore = 0
        }
        
        // Add artwork attachment if available
        if let artwork = artwork {
            do {
                let attachment = try await createImageAttachment(from: artwork, identifier: "artwork")
                content.attachments = [attachment]
            } catch {
                print("⚠️ Failed to create artwork attachment: \(error)")
            }
        }
        
        // Create request with the constant identifier for replacement behavior
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("🔔 Track change notification sent: \(song.title) by \(song.artist)")
        } catch {
            print("❌ Failed to send track change notification: \(error)")
        }
    }
    
    private func createImageAttachment(from image: UIImage, identifier: String) async throws -> UNNotificationAttachment {
        // Resize image to notification-appropriate size to save memory
        let targetSize = CGSize(width: 300, height: 300)
        let resizedImage = await resizeImage(image, to: targetSize)
        
        guard let imageData = resizedImage.jpegData(compressionQuality: 0.8) else {
            throw NotificationError.imageProcessingFailed
        }
        
        // Create temporary file for the attachment
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "\(identifier)_\(UUID().uuidString).jpg"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        try imageData.write(to: fileURL)
        
        return try UNNotificationAttachment(identifier: identifier, url: fileURL)
    }
    
    private func resizeImage(_ image: UIImage, to size: CGSize) async -> UIImage {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let renderer = UIGraphicsImageRenderer(size: size)
                let resizedImage = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                continuation.resume(returning: resizedImage)
            }
        }
    }
    
    // MARK: - Notification Management
    
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    func clearPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    func clearDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    func setupNotificationCategories() {
        let trackChangeCategory = UNNotificationCategory(
            identifier: "TRACK_CHANGE",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([trackChangeCategory])
    }
}

// MARK: - Error Types

enum NotificationError: Error {
    case imageProcessingFailed
    case attachmentCreationFailed
}

// MARK: - Helper Extensions

extension NotificationService {
    // Extract artwork from a Song's MPMediaItem
    func getArtwork(for song: Song) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let predicate = MPMediaPropertyPredicate(
                    value: NSNumber(value: song.persistentID),
                    forProperty: MPMediaItemPropertyPersistentID
                )
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(predicate)
                
                guard let item = query.items?.first,
                      let artwork = item.artwork else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Get image at a reasonable size for notifications
                let image = artwork.image(at: CGSize(width: 300, height: 300))
                continuation.resume(returning: image)
            }
        }
    }
}