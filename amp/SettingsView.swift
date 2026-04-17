import SwiftUI
import UIKit

// Settings service persists user preferences to UserDefaults. Narrow by
// design — the brutalist redesign has no dark mode, so the legacy
// `darkMode` field is gone.

final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @AppStorage("showLyrics") var showLyrics: Bool = true

    private init() {}
}

// Spec §7.9: pushed view from the Library chrome. Back button + yellow
// SETTINGS title block + toggles + yellow EXPORT section + export button.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNoLikedAlert = false
    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            chrome
            titleBlock
            settingsSection
            exportSection
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .alert("No liked tracks to export.", isPresented: $showNoLikedAlert) {
            Button("OK", role: .cancel) { }
        }
        .alert("Export failed", isPresented: .constant(exportErrorMessage != nil)) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack {
            BackButton { dismiss() }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var titleBlock: some View {
        ViewTitleBlock("SETTINGS")
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
    }

    // MARK: - Settings section

    private var settingsSection: some View {
        VStack(spacing: 16) {
            BrutalistToggle(
                label: "Show lyrics button when available",
                isOn: $settings.showLyrics
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: - Export section

    private var exportSection: some View {
        VStack(spacing: 16) {
            ViewTitleBlock("EXPORT")
            Button(action: triggerExport) {
                HStack(spacing: 0) {
                    Text("Export liked tracks as .m3u")
                        .font(.listTitle)
                        .foregroundStyle(Color.ampBlack)
                        .padding(.leading, 16)
                    Spacer(minLength: 12)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ampBlack)
                        .padding(.trailing, 16)
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            }
            .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
        }
        .padding(.horizontal, 24)
    }

    private func triggerExport() {
        guard !liked.likedIDs.isEmpty else {
            showNoLikedAlert = true
            return
        }
        do {
            let url = try LikedTracksService.shared.generateM3UFile()
            presentShareSheet(for: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    // UIActivityViewController doesn't cooperate well with SwiftUI's .sheet
    // — the sheet chrome either appears empty or the activity controller
    // gets dismissed mid-presentation. Reaching into UIKit to present from
    // the topmost view controller is the reliable pattern.
    private func presentShareSheet(for url: URL) {
        guard let topVC = topmostViewController() else {
            exportErrorMessage = "Could not locate a view to present from."
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad needs an anchor for the popover; hand it the root view center.
        if let pop = activity.popoverPresentationController {
            pop.sourceView = topVC.view
            pop.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            pop.permittedArrowDirections = []
        }
        topVC.present(activity, animated: true)
    }

    private func topmostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - BrutalistToggle (§7.9)
//
// "Brutalist 44-tall row. When OFF, white box with text label. When ON,
// navy-inverted treatment to indicate active." Same primitive pattern as
// chips/tabs/etc: stroke always, shadow only when off.

struct BrutalistToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.listTitle)
                .foregroundStyle(isOn ? Color.ampWhite : Color.ampBlack)
                .lineLimit(2)
                .padding(.leading, 16)
            Spacer(minLength: 12)
            Text(isOn ? "ON" : "OFF")
                .font(.inversionLabel)
                .foregroundStyle(isOn ? Color.ampInversionLabel : Color.ampMutedText)
                .padding(.trailing, 16)
        }
        .animation(.easeInOut(duration: 0.25), value: isOn)
        .frame(maxWidth: .infinity, minHeight: 44)
        .brutalistInvertible(isActive: isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

