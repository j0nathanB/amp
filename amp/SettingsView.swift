//
//  SettingsView.swift
//  amp
//

import SwiftUI

class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @AppStorage("showLyrics") var showLyrics: Bool = true
    @AppStorage("darkMode") var darkMode: Bool = false

    private init() {}
}

struct SettingsView: View {
    @StateObject private var settings = SettingsService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(Theme.titleFont)
                        .foregroundColor(Theme.primaryText)

                    Spacer()

                    Button(action: {
                        dismiss()
                    }) {
                        Text("Done")
                            .font(Theme.bodyFont)
                            .foregroundColor(Theme.primaryText)
                    }
                }
                .frame(height: 28)
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
                .background(Theme.background)

                // Separator
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 2)
                    .padding(.horizontal, 16)

                // Settings List
                ScrollView {
                    VStack(spacing: 0) {
                        // Dark Mode Toggle
                        SettingRow(
                            title: "Dark Mode",
                            description: "Black background with light accents",
                            isOn: $settings.darkMode
                        )

                        Divider()
                            .background(Color.black.opacity(0.2))
                            .padding(.horizontal, 16)

                        // Show Lyrics Toggle
                        SettingRow(
                            title: "Show Lyrics",
                            description: "Display lyrics button in Now Playing",
                            isOn: $settings.showLyrics
                        )
                    }
                    .padding(.top, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SettingRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.primaryText)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.primaryText.opacity(0.6))
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accentLightGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    SettingsView()
}
