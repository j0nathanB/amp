import SwiftUI

// Folder-roots management (Phase 3 of dev/FOLDER_LIBRARY_TOGGLE_PLAN.md),
// pushed from Settings. Add/remove roots, per-root track count and stale
// ("unavailable") state, manual rescan, scan progress. Brutalist chrome
// mirrors SettingsView: back button + yellow title block + 44pt rows.
struct FolderSettingsView: View {
    @ObservedObject private var folders = FolderLibraryService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            rootsList
            actions
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            FolderPicker { url in
                folders.addFolder(pickedURL: url)
            }
        }
    }

    // MARK: - Chrome

    // Back button sits inline with the yellow FOLDERS title block (both are
    // 44pt tall), mirroring SettingsView.
    private var header: some View {
        HStack(spacing: 12) {
            BackButton { dismiss() }
            ViewTitleBlock("FOLDERS")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Roots

    private var rootsList: some View {
        VStack(spacing: 16) {
            if folders.roots.isEmpty {
                Text("No folders added.")
                    .font(.listTitle)
                    .foregroundStyle(Color.ampMutedText)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(folders.roots) { root in
                    rootRow(root)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func rootRow(_ root: FolderRoot) -> some View {
        let isStale = folders.staleRootIDs.contains(root.id)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                Text(isStale ? "⚠ Folder unavailable — re-add to restore" : subtitle(for: root))
                    .font(.inversionLabel)
                    .foregroundStyle(Color.ampMutedText)
                    .lineLimit(1)
            }
            .padding(.leading, 16)
            Spacer(minLength: 12)
            Button {
                folders.removeFolder(id: root.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ampBlack)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .brutalistInvertible(isActive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(root.displayName), \(isStale ? "unavailable" : "\(root.trackCount) tracks")")
    }

    private func subtitle(for root: FolderRoot) -> String {
        if root.lastScanCompletedAt == nil && folders.isScanning {
            return "Scanning…"
        }
        return "\(root.trackCount) track\(root.trackCount == 1 ? "" : "s")"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 16) {
            // The explicit load step (dogfood feedback 2026-07-11): a scan
            // only stages results; this applies them to the live library,
            // erasing the queue and rebuilding library/search views.
            if folders.stagedTrackCount != nil || folders.isScanning {
                Button {
                    folders.loadStagedLibrary()
                } label: {
                    HStack(spacing: 0) {
                        Text(loadButtonLabel)
                            .font(.listTitle)
                            .foregroundStyle(loadEnabled ? Color.ampBlack : Color.ampMutedText)
                            .padding(.leading, 16)
                        Spacer(minLength: 12)
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(loadEnabled ? Color.ampBlack : Color.ampMutedText)
                            .padding(.trailing, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                }
                .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
                .disabled(!loadEnabled)
            }

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 0) {
                    Text("Add folder")
                        .font(.listTitle)
                        .foregroundStyle(Color.ampBlack)
                        .padding(.leading, 16)
                    Spacer(minLength: 12)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ampBlack)
                        .padding(.trailing, 16)
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            }
            .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))

            if !folders.roots.isEmpty {
                Button {
                    folders.rescan()
                } label: {
                    HStack(spacing: 0) {
                        Text(scanButtonLabel)
                            .font(.listTitle)
                            .foregroundStyle(Color.ampBlack)
                            .padding(.leading, 16)
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.ampBlack)
                            .padding(.trailing, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                }
                .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
                .disabled(folders.isScanning)
            }
        }
        .padding(.horizontal, 24)
    }

    private var scanButtonLabel: String {
        if folders.isScanning {
            if let progress = folders.scanProgress {
                return "Scanning… \(progress.processed)/\(progress.discovered)"
            }
            return "Scanning…"
        }
        return "Rescan folders"
    }

    private var loadEnabled: Bool {
        folders.stagedTrackCount != nil && !folders.isScanning
    }

    private var loadButtonLabel: String {
        if folders.isScanning {
            return "Load library"
        }
        if let count = folders.stagedTrackCount {
            return "Load library (\(count) track\(count == 1 ? "" : "s"))"
        }
        return "Load library"
    }
}
