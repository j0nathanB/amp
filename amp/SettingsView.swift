import SwiftUI
import UIKit

// Settings service persists user preferences to UserDefaults. Kept narrow —
// the brutalist redesign is light-only so the legacy `darkMode` field is
// orphaned and no longer surfaced in the UI. Can be removed outright once
// nothing in the app reads Theme.isDarkMode.

final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @AppStorage("showLyrics") var showLyrics: Bool = true
    @AppStorage("darkMode") var darkMode: Bool = false

    private init() {}
}

// Spec §7.9: pushed view from the Library chrome. Back button + yellow
// SETTINGS title block + toggles + yellow EXPORT section + export button.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showNoLikedAlert = false

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
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("No liked tracks to export.", isPresented: $showNoLikedAlert) {
            Button("OK", role: .cancel) { }
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
                .background(Color.ampWhite)
                .brutalistStroke()
                .brutalistShadow(.small)
            }
            .buttonStyle(.plain)
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
            shareURL = url
            showShare = true
        } catch {
            showNoLikedAlert = true
        }
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
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(isOn ? Color.ampNavy : Color.ampWhite)
        .brutalistStroke()
        .brutalistShadow(.small, when: !isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - ShareSheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
