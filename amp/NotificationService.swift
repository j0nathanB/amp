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

    // Auto-dismiss so delivered notifications don't accumulate on the lock screen / in Notification Center
    private let autoDismissDelay: TimeInterval = 5.0
    private var autoDismissTask: Task<Void, Never>?
    
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
        // Install the UNUserNotificationCenter delegate so willPresent can hard-suppress
        // notifications while the app is foregrounded, regardless of any race between
        // scheduleTrackChangeNotification's checks and iOS's 0.1s trigger.
        UNUserNotificationCenter.current().delegate = self
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
        // Only meaningful when actually returning from background.
        // willEnterForeground ALSO fires on cold launch, where
        // appDidBecomeActive's clearing task never runs (appWasInBackground
        // is false) — setting the flag unconditionally left it stuck true
        // until the first real background cycle, suppressing every
        // track-change notification after a cold launch.
        if appWasInBackground {
            isResumingFromBackground = true
        }
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
    
    // Called from the playback path (main thread, per track change). The
    // cheap state checks run synchronously; the system queries that used to
    // block the caller behind DispatchSemaphore.wait() (notification
    // settings fetch, app state) now run in a detached continuation — the
    // playback path never waits on UNUserNotificationCenter again.
    func scheduleTrackChangeNotification(song: Song, artwork: UIImage? = nil, isManualSelection: Bool = false) {
        print("🔔 [DEBUG] scheduleTrackChangeNotification called for: \(song.title)")
        print("🔔 [DEBUG] isEnabled: \(isEnabled), isManualSelection: \(isManualSelection), isResumingFromBackground: \(isResumingFromBackground)")
        print("🔔 [DEBUG] lastNotificationSongID: \(lastNotificationSongID ?? 0), current song ID: \(song.persistentID)")

        // CRITICAL: Don't send notification for the same song twice
        // This prevents duplicate notifications when unlocking from lock screen
        if lastNotificationSongID == song.persistentID {
            print("🔔 Skipping duplicate notification for same song: \(song.title)")
            return
        }

        // Tracking updates even on blocked paths below, to prevent a late
        // notification once the blocking condition clears.
        lastNotificationSongID = song.persistentID

        // CRITICAL: Don't send notification when resuming from background
        if isResumingFromBackground {
            print("🔔 Skipping notification - resuming from background")
            return
        }

        guard isEnabled else {
            print("🔔 Notifications disabled by user")
            return
        }

        // Don't send for manual selections (user-initiated track changes)
        if isManualSelection {
            print("🔔 Skipping notification for manual track selection")
            return
        }

        // Debounce rapid track changes
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastNotificationTime < debounceInterval {
            print("🔔 Debouncing notification - too soon since last one")
            return
        }
        lastNotificationTime = currentTime

        Task { @MainActor in
            // App-state check. Foregrounded-and-visible means the user can
            // already see what's playing, so we only fire when backgrounded.
            guard UIApplication.shared.applicationState == .background else {
                print("🔔 Skipping notification - app is foregrounded")
                return
            }

            // Verify actual system authorization in real-time — prevents
            // stale state if the user changed permissions in Settings.
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.authorizationStatus = settings.authorizationStatus
            self.isAuthorized = settings.authorizationStatus == .authorized
            guard settings.authorizationStatus == .authorized else {
                print("🔔 Notifications not authorized (system status: \(settings.authorizationStatus.rawValue))")
                return
            }

            print("🔔 Will send notification - app is backgrounded")
            await self.sendTrackChangeNotification(song: song, artwork: artwork)
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
        
        // A new notification resets the auto-dismiss timer; cancel any prior task so it
        // doesn't remove the newer delivered notification early.
        autoDismissTask?.cancel()

        do {
            try await UNUserNotificationCenter.current().add(request)
            print("🔔 Track change notification sent: \(song.title) by \(song.artist)")

            // Verify the notification was added
            let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            print("🔔 [DEBUG] Pending requests after adding: \(pendingRequests.count)")

            scheduleAutoDismiss()
        } catch {
            print("❌ Failed to send track change notification: \(error)")
        }
    }

    private func scheduleAutoDismiss() {
        let identifier = notificationIdentifier
        let delayNanos = UInt64(autoDismissDelay * 1_000_000_000)
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            print("🔔 Auto-dismissed delivered notification: \(identifier)")
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

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    // Called when a notification is about to be presented while the app is foregrounded.
    // Returning empty options suppresses the banner, sound, list entry, and badge —
    // closing the race between shouldSendNotification's check and iOS's trigger delay.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
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
