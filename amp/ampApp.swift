import SwiftUI
import MediaPlayer

@main
struct ampApp: App {
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        // Audio session is now managed by PlaybackEngineService
        setupMemoryWarningObserver()
        setupNotificationService()
    }
    
    var body: some Scene {
            WindowGroup {
                PermissionCheckerView()
                    .environmentObject(audioPlayer)
                    .preferredColorScheme(.light)
                    .accentColor(Theme.accentGreen) // This sets the global accent color including keyboard buttons
                    .ignoresSafeArea(.keyboard, edges: .bottom) // Handle keyboard at the app level
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                        print("[App] Entering foreground")
                        audioPlayer.queueManager.enterForeground()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                        print("[App] Entering background")
                        audioPlayer.queueManager.enterBackground()
                    }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        switch newPhase {
                        case .active:
                            NotificationService.shared.clearAllNotifications()
                        case .background:
                            break
                        default:
                            break
                        }
                    }
            }
        }
}

struct PermissionCheckerView: View {
    @State private var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined

    var body: some View {
        Group {
            switch authorizationStatus {
            case .authorized:
                MainTabView()
                
            case .notDetermined:
                VStack(spacing: 20) {
                    Text("Music Library Access Required").font(.title2).fontWeight(.bold)
                    Text("Please grant permission to access your local music.").multilineTextAlignment(.center)
                    Button("Grant Permission") {
                        requestMusicLibraryAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                
            default:
                VStack(spacing: 20) {
                    Text("Permission Denied").font(.title2).fontWeight(.bold)
                    Text("Please enable Media & Apple Music access in the Settings app to continue.").multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .onAppear {
            authorizationStatus = MPMediaLibrary.authorizationStatus()
        }
    }
    
    private func requestMusicLibraryAccess() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
            }
        }
    }
}

extension ampApp {
    func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("⚠️ Memory warning received")
//            AudioPlayerService.shared.handleMemoryPressure()
        }
    }
    
    func setupNotificationService() {
        // Set up notification categories
        NotificationService.shared.setupNotificationCategories()
        
        // Request permissions after a short delay to let the app finish launching
        Task {
            // Wait for the app to finish launching
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Request notification permission
            let granted = await NotificationService.shared.requestPermission()
            print("🔔 Notification permission granted: \(granted)")
        }
    }
}
