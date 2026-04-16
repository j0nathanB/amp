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
    
    // App lifecycle tracking to prevent inappropriate notifications
    private var isResumingFromBackground = false
    private var lastNotificationSongID: MPMediaEntityPersistentID?
    private var appWasInBackground = false
    
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
        setupAppLifecycleObservers()
        // Enable notifications by default for new users
        if UserDefaults.standard.object(forKey: "songChangeNotificationsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "songChangeNotificationsEnabled")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - App Lifecycle Tracking
    
    private func setupAppLifecycleObservers() {
        // Track when app enters background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // Track when app becomes active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Track when app will enter foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        print("🔔 [Lifecycle] App entered background")
        appWasInBackground = true
        isResumingFromBackground = false
    }
    
    @objc private func appDidBecomeActive() {
        print("🔔 [Lifecycle] App became active")
        // Clear any pending notifications when app becomes active
        clearDeliveredNotifications()

        // Set flag to prevent notifications when resuming
        if appWasInBackground {
            print("🔔 [Lifecycle] Setting resuming flag - preventing notifications")
            isResumingFromBackground = true
            // Reset flag after playback state is established
            // Using Task for proper async handling instead of arbitrary delay
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await MainActor.run {
                    print("🔔 [Lifecycle] Clearing resuming flag - notifications re-enabled")
                    self.isResumingFromBackground = false
                    self.appWasInBackground = false
                }
            }
        }
    }
    
    @objc private func appWillEnterForeground() {
        print("🔔 [Lifecycle] App will enter foreground")
        isResumingFromBackground = true
    }
    
    // MARK: - Permission Management

    func requestPermission() async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await MainActor.run {
            self.isAuthorized = granted
            self.checkAuthorizationStatus()
        }
        print("🔔 Notification permission granted: \(granted)")
        return granted
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
        print("🔔 [DEBUG] scheduleTrackChangeNotification called for: \(song.title)")
        print("🔔 [DEBUG] isEnabled: \(isEnabled), isAuthorized: \(isAuthorized)")
        print("🔔 [DEBUG] authorizationStatus: \(authorizationStatus)")
        print("🔔 [DEBUG] isManualSelection: \(isManualSelection)")
        print("🔔 [DEBUG] isResumingFromBackground: \(isResumingFromBackground)")
        print("🔔 [DEBUG] lastNotificationSongID: \(lastNotificationSongID ?? 0), current song ID: \(song.persistentID)")

        // CRITICAL: Don't send notification for the same song twice
        // This prevents duplicate notifications when unlocking from lock screen
        if lastNotificationSongID == song.persistentID {
            print("🔔 Skipping duplicate notification for same song: \(song.title)")
            return
        }

        // CRITICAL: Don't send notification when resuming from background
        // Check this BEFORE other checks to prevent lock screen unlock notifications
        if isResumingFromBackground {
            print("🔔 Skipping notification - resuming from background, updating lastNotificationSongID anyway")
            // Update tracking even when blocked to prevent notification after resumption window
            lastNotificationSongID = song.persistentID
            return
        }

        // Check if notifications should be sent
        guard shouldSendNotification(isManualSelection: isManualSelection) else {
            print("🔔 [DEBUG] shouldSendNotification returned false")
            // Update tracking even when blocked
            lastNotificationSongID = song.persistentID
            return
        }

        // Update last notification tracking
        lastNotificationSongID = song.persistentID
        
        // Debounce rapid track changes
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastNotificationTime < debounceInterval {
            print("🔔 Debouncing notification - too soon since last one")
            return
        }
        lastNotificationTime = currentTime
        
        print("🔔 [DEBUG] Proceeding to send notification")
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

        // Verify actual system authorization status in real-time
        // This prevents stale state issues if user changes permissions in Settings
        var actualAuthStatus: UNAuthorizationStatus = .notDetermined
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            actualAuthStatus = settings.authorizationStatus
            semaphore.signal()
        }
        semaphore.wait()

        // Don't send if not actually authorized according to system
        guard actualAuthStatus == .authorized else {
            print("🔔 Notifications not authorized (system status: \(actualAuthStatus.rawValue))")
            // Update cached state if desynchronized
            if isAuthorized != (actualAuthStatus == .authorized) {
                Task { @MainActor in
                    self.isAuthorized = (actualAuthStatus == .authorized)
                    self.authorizationStatus = actualAuthStatus
                }
            }
            return false
        }
        
        // Don't send for manual selections (user-initiated track changes)
        if isManualSelection {
            print("🔔 Skipping notification for manual track selection")
            return false
        }
        
        // CRITICAL FIX: Don't send if resuming from background
        if isResumingFromBackground {
            print("🔔 Skipping notification - resuming from background")
            return false
        }
        
        // Check app state and current view - ensure UI API calls are on main thread
        var appState: UIApplication.State = .active
        var selectedTab: AmpTab = .active

        if Thread.isMainThread {
            appState = UIApplication.shared.applicationState
            selectedTab = NavigationService.shared.selectedTab
        } else {
            // Use MainActor to safely access UI APIs
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                appState = UIApplication.shared.applicationState
                selectedTab = NavigationService.shared.selectedTab
                semaphore.signal()
            }
            semaphore.wait()
        }

        // Send notification if app is backgrounded OR user is not on Now Playing view
        if appState == .background {
            print("🔔 Will send notification - app is backgrounded")
            return true
        } else if appState == .active && selectedTab != .active {
            print("🔔 Will send notification - app active but not on Now Playing view (current: \(selectedTab))")
            return true
        } else {
            print("🔔 Skipping notification - app active and on Now Playing view")
            return false
        }
    }
    
    private func sendTrackChangeNotification(song: Song, artwork: UIImage?) async {
        print("🔔 [DEBUG] sendTrackChangeNotification started")
        
        // Check current notification settings
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        print("🔔 [DEBUG] Current notification settings:")
        print("🔔 [DEBUG] - authorizationStatus: \(settings.authorizationStatus.rawValue)")
        print("🔔 [DEBUG] - alertSetting: \(settings.alertSetting.rawValue)")
        print("🔔 [DEBUG] - notificationCenterSetting: \(settings.notificationCenterSetting.rawValue)")
        
        // Remove any existing notifications with the same identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        
        let content = UNMutableNotificationContent()
        content.title = song.title.isEmpty ? "Unknown Song" : song.title
        content.body = song.artist.isEmpty ? "Unknown Artist" : song.artist
        content.sound = nil
        content.categoryIdentifier = "TRACK_CHANGE"

        print("🔔 [DEBUG] Notification content:")
        print("🔔 [DEBUG] - title: '\(content.title ?? "")'")
        print("🔔 [DEBUG] - body: '\(content.body)'")
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active  // Try active instead of passive
            content.relevanceScore = 1.0  // Higher relevance
            print("🔔 [DEBUG] Set iOS 15+ properties: active interruption, relevance 1.0")
        }
        
        // Create request with the constant identifier for replacement behavior
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)  // Longer delay
        )
        
        print("🔔 [DEBUG] Created notification request with identifier: \(notificationIdentifier)")
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("🔔 Track change notification sent: \(song.title) by \(song.artist)")
            
            // Verify the notification was added
            let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            print("🔔 [DEBUG] Pending requests after adding: \(pendingRequests.count)")
            
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
    
    // MARK: - Test Methods
    
    func testNotification() {
        print("🔔 [TEST] Testing notification system")
        print("🔔 [TEST] isEnabled: \(isEnabled)")
        print("🔔 [TEST] isAuthorized: \(isAuthorized)")
        print("🔔 [TEST] authorizationStatus: \(authorizationStatus)")
        
        Task {
            let testSong = Song(
                persistentID: 12345,
                title: "Test Song",
                artist: "Test Artist",
                album: "Test Album",
                releaseDate: Date(),
                albumTrackNumber: 1
                
            )
            
            await sendTrackChangeNotification(song: testSong, artwork: nil)
        }
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
