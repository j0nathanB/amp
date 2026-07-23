import SwiftUI
import UIKit

// Settings service persists user preferences to UserDefaults. Narrow by
// design — the brutalist redesign has no dark mode, so the legacy
// `darkMode` field is gone.

final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @AppStorage("showLyrics") var showLyrics: Bool = true
    @AppStorage("queuePinDefaultTop") var queuePinDefaultTop: Bool = false

    private init() {}
}

// Spec §7.9: pushed view from the Library chrome. Back button + yellow
// SETTINGS title block + toggles + yellow EXPORT section + export button.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @ObservedObject private var libraryMode = LibraryModeService.shared
    @ObservedObject private var nav = NavigationService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNoLikedAlert = false
    @State private var exportErrorMessage: String?
    @State private var showFirstFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
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

    // Back button sits inline with the yellow SETTINGS title block (both are
    // 44pt tall), same arrangement as Album / Genre Detail chrome.
    private var header: some View {
        HStack(spacing: 12) {
            BackButton { dismiss() }
            ViewTitleBlock("SETTINGS")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Settings section

    private var settingsSection: some View {
        VStack(spacing: 16) {
            BrutalistToggle(
                label: "Lyrics button",
                isOn: $settings.showLyrics
            )
            BrutalistToggle(
                label: "Miniplayer",
                onLabel: "TOP",
                offLabel: "BOTTOM",
                isInvertible: false,
                isOn: $settings.queuePinDefaultTop
            )
            // Library source (FOLDER_LIBRARY_TOGGLE_PLAN). Non-invertible:
            // MUSIC and FOLDER are equally valid choices, like TOP/BOTTOM.
            // Switching stops playback and erases the queue (decision #6) —
            // LibraryModeService owns that sequence. First flip to FOLDER
            // with no roots opens the system picker instead (decision #9);
            // cancelling leaves the mode untouched, so the toggle — which
            // reads the mode — stays on MUSIC by construction.
            BrutalistToggle(
                label: "Library source",
                onLabel: "FOLDER",
                offLabel: "MUSIC",
                isInvertible: false,
                isOn: Binding(
                    get: { libraryMode.mode == .folder },
                    set: { wantsFolder in
                        if wantsFolder && FolderLibraryService.shared.roots.isEmpty {
                            showFirstFolderPicker = true
                        } else {
                            libraryMode.setMode(wantsFolder ? .folder : .music)
                        }
                    }
                )
            )
            // Folder roots management (add/remove/rescan/load). Only
            // meaningful while the FOLDER source is active — greyed out in
            // MUSIC mode so folder scans can't be mistaken for "loaded into
            // the library" while Music is what's on screen (dogfood
            // feedback 2026-07-11).
            Button {
                nav.push(.folderSettings)
            } label: {
                HStack(spacing: 0) {
                    Text("Folders")
                        .font(.listTitle)
                        .foregroundStyle(folderModeActive ? Color.ampBlack : Color.ampMutedText)
                        .padding(.leading, 16)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(folderModeActive ? Color.ampBlack : Color.ampMutedText)
                        .padding(.trailing, 16)
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            }
            .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
            .disabled(!folderModeActive)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .sheet(isPresented: $showFirstFolderPicker) {
            FolderPicker { url in
                FolderLibraryService.shared.addFolder(pickedURL: url)
                libraryMode.setMode(.folder)
                // Land on the Folders screen: scan progress is visible and
                // the Load button lights up when staging completes.
                nav.push(.folderSettings)
            }
            // Cancel: no mode change; toggle stays MUSIC.
        }
    }

    private var folderModeActive: Bool {
        libraryMode.mode == .folder
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
    let onLabel: String
    let offLabel: String
    let isInvertible: Bool
    @Binding var isOn: Bool

    init(
        label: String,
        onLabel: String = "ON",
        offLabel: String = "OFF",
        isInvertible: Bool = true,
        isOn: Binding<Bool>
    ) {
        self.label = label
        self.onLabel = onLabel
        self.offLabel = offLabel
        self.isInvertible = isInvertible
        self._isOn = isOn
    }

    var body: some View {
        // Non-invertible toggles never enter the navy "active" treatment —
        // both sides of the binding are equally valid choices (e.g.
        // TOP/BOTTOM), so neither should read as the highlighted option.
        let active = isInvertible && isOn
        let labelColor: Color = active ? Color.ampWhite : Color.ampBlack
        let valueColor: Color = isInvertible
            ? (isOn ? Color.ampInversionLabel : Color.ampMutedText)
            : Color.ampBlack
        HStack(spacing: 0) {
            Text(label)
                .font(.listTitle)
                .foregroundStyle(labelColor)
                .lineLimit(2)
                .padding(.leading, 16)
            Spacer(minLength: 12)
            Text(isOn ? onLabel : offLabel)
                .font(.inversionLabel)
                .foregroundStyle(valueColor)
                .padding(.trailing, 16)
        }
        .animation(.easeInOut(duration: 0.25), value: isOn)
        .frame(maxWidth: .infinity, minHeight: 44)
        .brutalistInvertible(isActive: active)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? onLabel : offLabel)
        .accessibilityAddTraits(.isButton)
    }
}

