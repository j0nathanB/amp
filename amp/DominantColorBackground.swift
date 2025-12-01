//
//  DominantColorBackground.swift
//  amp
//
//  Provides a moody, distorted gradient background from extracted dominant colors
//

import SwiftUI
import MediaPlayer

struct DominantColorBackground: View {
    let song: Song
    @State private var dominantColors: [Color] = []
    @State private var loadedSongID: UInt64 = 0
    @State private var loadTask: Task<Void, Never>?

    // NSCache for processed images to avoid reprocessing
    private static let colorCache: NSCache<NSNumber, NSArray> = {
        let cache = NSCache<NSNumber, NSArray>()
        cache.countLimit = 20 // Keep up to 20 color palettes in memory
        return cache
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if dominantColors.isEmpty {
                    // Fallback while loading
                    Color.purple.opacity(0.3)
                } else {
                    // Use iOS 18 MeshGradient if available, otherwise fallback
                    if #available(iOS 18.0, *) {
                        meshGradientBackground(size: geometry.size)
                    } else {
                        blurredCirclesBackground(size: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onChange(of: song.persistentID) { oldValue, newValue in
            if newValue != loadedSongID {
                loadTask?.cancel()
                loadDominantColors()
            }
        }
        .onAppear {
            if loadedSongID != song.persistentID {
                loadDominantColors()
            }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    // MARK: - iOS 18+ MeshGradient

    @available(iOS 18.0, *)
    private func meshGradientBackground(size: CGSize) -> some View {
        let colors = ensureMinimumColors(dominantColors, minimum: 2)

        // Create a 3x3 mesh grid with distorted color placement (using 2 colors)
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                // Row 1
                .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),
                // Row 2 (distorted)
                .init(0.0, 0.4), .init(0.6, 0.5), .init(1.0, 0.5),
                // Row 3
                .init(0.0, 1.0), .init(0.4, 1.0), .init(1.0, 1.0)
            ],
            colors: [
                // Alternate between 2 colors for organic bleeding effect
                colors[0], colors[1], colors[0],
                colors[1], colors[0], colors[1],
                colors[0], colors[1], colors[0]
            ]
        )
        .blur(radius: 60)
        .brightness(-0.1)
        .saturation(1.2)
    }

    // MARK: - Legacy Blurred Circles Fallback

    private func blurredCirclesBackground(size: CGSize) -> some View {
        let colors = ensureMinimumColors(dominantColors, minimum: 2)

        return ZStack {
            // Base layer
            colors[0]
                .opacity(0.6)

            // Overlapping blurred circles create the "bleeding" effect with 2 colors
            Circle()
                .fill(colors[0])
                .frame(width: size.width * 1.3, height: size.width * 1.3)
                .blur(radius: 110)
                .offset(x: -size.width * 0.25, y: -size.height * 0.15)

            Circle()
                .fill(colors[1])
                .frame(width: size.width * 1.2, height: size.width * 1.2)
                .blur(radius: 100)
                .offset(x: size.width * 0.25, y: size.height * 0.15)

            Circle()
                .fill(colors[0])
                .frame(width: size.width * 1.0, height: size.width * 1.0)
                .blur(radius: 90)
                .offset(x: size.width * 0.15, y: -size.height * 0.25)

            Circle()
                .fill(colors[1])
                .frame(width: size.width * 1.1, height: size.width * 1.1)
                .blur(radius: 95)
                .offset(x: -size.width * 0.15, y: size.height * 0.25)
        }
        .brightness(-0.1)
        .saturation(1.2)
    }

    // MARK: - Color Loading & Processing

    private func loadDominantColors() {
        loadedSongID = song.persistentID

        // Check cache first
        let cacheKey = NSNumber(value: song.persistentID)
        if let cached = Self.colorCache.object(forKey: cacheKey) as? [Color] {
            Task { @MainActor in
                dominantColors = cached
            }
            return
        }

        // Load and process artwork
        loadTask = Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: song.persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)

            if Task.isCancelled { return }

            // Load artwork at reasonable size
            guard let artworkImage = query.items?.first?.artwork?.image(at: CGSize(width: 300, height: 300)) else {
                return
            }

            if Task.isCancelled { return }

            // Extract dominant colors using K-Means clustering
            let colors = await artworkImage.extractDominantColors(
                colorCount: 2,
                quality: 100,
                filterExtremes: true
            )

            if Task.isCancelled { return }

            // Cache and update UI
            await MainActor.run {
                Self.colorCache.setObject(colors as NSArray, forKey: cacheKey)
                dominantColors = colors
            }
        }
    }

    // MARK: - Helper Functions

    /// Ensures we have at least the minimum number of colors by repeating existing colors
    private func ensureMinimumColors(_ colors: [Color], minimum: Int) -> [Color] {
        guard !colors.isEmpty else {
            // Ultimate fallback: return purple gradient
            return Array(repeating: Color.purple, count: minimum)
        }

        var result = colors

        // If we have fewer colors than needed, repeat them
        while result.count < minimum {
            result.append(contentsOf: colors)
        }

        // Trim to exact count needed
        return Array(result.prefix(minimum))
    }

    // Public method to clear cache
    static func clearCache() {
        colorCache.removeAllObjects()
    }
}

// MARK: - Preview Provider

#if DEBUG
struct DominantColorBackground_Previews: PreviewProvider {
    static var previews: some View {
        // Mock song for preview
        let mockSong = Song(
            persistentID: 12345,
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180.0
        )

        DominantColorBackground(song: mockSong)
            .previewLayout(.fixed(width: 400, height: 600))
    }
}
#endif
