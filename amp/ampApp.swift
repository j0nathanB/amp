import SwiftUI
import MediaPlayer

@main
struct ampApp: App {
    @StateObject private var audioPlayer = AudioPlayerService.shared
    
    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            print("Audio session configured successfully.")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        // Add memory warning observer
        setupMemoryWarningObserver()
    }
    
    var body: some Scene {
            WindowGroup {
                PermissionCheckerView()
                    .environmentObject(audioPlayer)
                    .preferredColorScheme(.light)
                    .accentColor(Theme.accentGreen) // This sets the global accent color including keyboard buttons
                    .ignoresSafeArea(.keyboard, edges: .bottom) // Handle keyboard at the app level
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
}
