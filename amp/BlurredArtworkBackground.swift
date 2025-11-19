//
//  BlurredArtworkBackground.swift
//  amp
//

import SwiftUI
import MediaPlayer
import CoreImage
import Accelerate

struct BlurredArtworkBackground: View {
    let song: Song
    @State private var processedImage: UIImage?
    @State private var loadedSongID: UInt64 = 0
    @State private var loadTask: Task<Void, Never>?

    // Cache for processed images to avoid reprocessing
    private static var imageCache: [UInt64: UIImage] = [:]
    private static let maxCacheSize = 5 // Keep last 5 processed backgrounds

    // Public method to clear cache (called when feature is disabled)
    static func clearCache() {
        imageCache.removeAll()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = processedImage {
                    // Display pre-processed image (already blurred, scaled, and color-adjusted)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Fallback to white when no artwork
                    Color.white
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onChange(of: song.persistentID) { oldValue, newValue in
            if newValue != loadedSongID {
                loadTask?.cancel()
                loadAndProcessArtwork()
            }
        }
        .onAppear {
            if loadedSongID != song.persistentID {
                loadAndProcessArtwork()
            }
        }
        .onDisappear {
            // Cancel any ongoing processing when view is removed
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadAndProcessArtwork() {
        loadedSongID = song.persistentID

        // Check cache first
        if let cached = Self.imageCache[song.persistentID] {
            Task { @MainActor in
                processedImage = cached
            }
            return
        }

        // Store the task so it can be cancelled if needed
        loadTask = Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: song.persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)

            // Check if cancelled before expensive operation
            if Task.isCancelled { return }

            // Load smaller artwork since we're blurring it anyway (300x300 is sufficient)
            guard let artworkImage = query.items?.first?.artwork?.image(at: CGSize(width: 300, height: 300)) else {
                return
            }

            // Check if cancelled before expensive processing
            if Task.isCancelled { return }

            // Process the image off the main thread
            if let processed = await processImageForBackground(artworkImage) {
                // Check if cancelled before updating UI
                if Task.isCancelled { return }

                // Cache the processed image
                await MainActor.run {
                    Self.imageCache[song.persistentID] = processed

                    // Limit cache size
                    if Self.imageCache.count > Self.maxCacheSize {
                        // Remove oldest entry (simple FIFO)
                        if let firstKey = Self.imageCache.keys.first {
                            Self.imageCache.removeValue(forKey: firstKey)
                        }
                    }

                    processedImage = processed
                }
            }
        }
    }

    private func processImageForBackground(_ image: UIImage) async -> UIImage? {
        // Get screen size for proper scaling
        let screenSize = UIScreen.main.bounds.size
        let targetSize = CGSize(
            width: screenSize.width * 2.5,
            height: screenSize.height * 2.5
        )

        // All processing happens here, once, off the main thread
        guard let ciImage = CIImage(image: image) else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: false])

        // 1. Scale up the image
        let scaleX = targetSize.width / ciImage.extent.width
        let scaleY = targetSize.height / ciImage.extent.height
        let scale = max(scaleX, scaleY)

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Store the scaled image extent before blur expands it
        let scaledExtent = scaledImage.extent

        // 2. Apply Gaussian blur (radius 60 for dreamy effect)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(scaledImage, forKey: kCIInputImageKey)
        blurFilter.setValue(60.0, forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage else { return nil }

        // 3. Boost saturation for vibrant colors
        guard let saturationFilter = CIFilter(name: "CIColorControls") else { return nil }
        saturationFilter.setValue(blurred, forKey: kCIInputImageKey)
        saturationFilter.setValue(1.3, forKey: kCIInputSaturationKey)

        guard let saturated = saturationFilter.outputImage else { return nil }

        // 4. Reduce brightness slightly and add opacity effect
        guard let brightnessFilter = CIFilter(name: "CIColorControls") else { return nil }
        brightnessFilter.setValue(saturated, forKey: kCIInputImageKey)
        brightnessFilter.setValue(-0.1, forKey: kCIInputBrightnessKey)

        guard let adjusted = brightnessFilter.outputImage else { return nil }

        // 5. Render to UIImage (crop to target size from center of ORIGINAL scaled image)
        // Important: Use scaledExtent, not adjusted.extent, because blur expands the extent
        let cropRect = CGRect(
            x: (scaledExtent.width - targetSize.width) / 2 + scaledExtent.origin.x,
            y: (scaledExtent.height - targetSize.height) / 2 + scaledExtent.origin.y,
            width: targetSize.width,
            height: targetSize.height
        )

        guard let cgImage = context.createCGImage(adjusted, from: cropRect) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
