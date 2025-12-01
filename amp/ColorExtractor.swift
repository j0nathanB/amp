//
//  ColorExtractor.swift
//  amp
//

import SwiftUI
import UIKit

// MARK: - UIImage Extension for Dominant Color Extraction

extension UIImage {
    /// Extracts dominant colors from an image using K-Means clustering
    /// - Parameters:
    ///   - colorCount: Number of dominant colors to extract (default: 2)
    ///   - quality: Downsample size for performance (default: 100x100)
    ///   - filterExtremes: Whether to filter out near-black/white colors (default: true)
    /// - Returns: Array of SwiftUI Colors sorted by frequency
    func extractDominantColors(
        colorCount: Int = 2,
        quality: Int = 100,
        filterExtremes: Bool = true
    ) async -> [Color] {
        // Perform heavy computation on background thread
        return await Task.detached(priority: .userInitiated) {
            // Step 1: Downsample image for performance
            guard let downsampledImage = self.downsample(to: CGSize(width: quality, height: quality)),
                  let cgImage = downsampledImage.cgImage else {
                return [Color.purple] // Fallback color
            }

            // Step 2: Extract pixel data
            guard let pixels = cgImage.extractPixels() else {
                return [Color.purple]
            }

            // Step 3: Filter out extreme colors if requested
            let filteredPixels = filterExtremes ? pixels.filter { pixel in
                let brightness = (pixel.red + pixel.green + pixel.blue) / 3.0
                return brightness > 0.15 && brightness < 0.90
            } : pixels

            // Need at least some pixels to work with
            guard !filteredPixels.isEmpty else {
                return [Color.purple]
            }

            // Step 4: Run K-Means clustering to find dominant colors
            let clusters = KMeans.cluster(pixels: filteredPixels, k: colorCount)

            // Step 5: Sort clusters by size (frequency) and convert to SwiftUI Colors
            let sortedClusters = clusters.sorted { $0.pixels.count > $1.pixels.count }

            return sortedClusters.map { cluster in
                Color(
                    red: Double(cluster.centroid.red),
                    green: Double(cluster.centroid.green),
                    blue: Double(cluster.centroid.blue)
                )
            }
        }.value
    }

    /// Downsamples an image to the specified size for performance
    private func downsample(to size: CGSize) -> UIImage? {
        // Use a specific format to ensure consistent color space
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Force 1x scale for consistent pixel addressing
        format.opaque = false
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Pixel Data Structures

/// Represents a single pixel with RGB values (0.0 - 1.0)
struct Pixel {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    /// Calculate Euclidean distance to another pixel in RGB space
    func distance(to other: Pixel) -> CGFloat {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return sqrt(dr * dr + dg * dg + db * db)
    }

    /// Calculate perceptual brightness (0.0 - 1.0)
    var brightness: CGFloat {
        // Use weighted formula that better matches human perception
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}

/// Represents a cluster of similar colored pixels
struct ColorCluster {
    var centroid: Pixel
    var pixels: [Pixel]
}

// MARK: - K-Means Clustering Algorithm

struct KMeans {
    /// Performs K-Means clustering on pixel data to find dominant colors
    /// - Parameters:
    ///   - pixels: Array of pixels to cluster
    ///   - k: Number of clusters (dominant colors) to find
    ///   - maxIterations: Maximum iterations for convergence (default: 10)
    /// - Returns: Array of color clusters
    static func cluster(pixels: [Pixel], k: Int, maxIterations: Int = 10) -> [ColorCluster] {
        guard pixels.count >= k else {
            // If we have fewer pixels than clusters, return each pixel as its own cluster
            return pixels.map { ColorCluster(centroid: $0, pixels: [$0]) }
        }

        // Step 1: Initialize centroids using K-Means++ for better initial placement
        var centroids = initializeCentroidsKMeansPlusPlus(pixels: pixels, k: k)

        // Step 2: Iteratively refine clusters
        for _ in 0..<maxIterations {
            // Assign each pixel to nearest centroid
            var clusters = centroids.map { ColorCluster(centroid: $0, pixels: []) }

            for pixel in pixels {
                var nearestIndex = 0
                var nearestDistance = CGFloat.infinity

                for (index, centroid) in centroids.enumerated() {
                    let distance = pixel.distance(to: centroid)
                    if distance < nearestDistance {
                        nearestDistance = distance
                        nearestIndex = index
                    }
                }

                clusters[nearestIndex].pixels.append(pixel)
            }

            // Remove empty clusters
            clusters = clusters.filter { !$0.pixels.isEmpty }

            // Recalculate centroids as the mean of assigned pixels
            let newCentroids = clusters.map { cluster -> Pixel in
                let count = CGFloat(cluster.pixels.count)
                let sumRed = cluster.pixels.reduce(0.0) { $0 + $1.red }
                let sumGreen = cluster.pixels.reduce(0.0) { $0 + $1.green }
                let sumBlue = cluster.pixels.reduce(0.0) { $0 + $1.blue }

                return Pixel(
                    red: sumRed / count,
                    green: sumGreen / count,
                    blue: sumBlue / count
                )
            }

            // Check for convergence (centroids haven't moved much)
            let hasConverged = zip(centroids, newCentroids).allSatisfy { old, new in
                old.distance(to: new) < 0.01
            }

            centroids = newCentroids

            if hasConverged {
                break
            }
        }

        // Final assignment
        var finalClusters = centroids.map { ColorCluster(centroid: $0, pixels: []) }

        for pixel in pixels {
            var nearestIndex = 0
            var nearestDistance = CGFloat.infinity

            for (index, centroid) in centroids.enumerated() {
                let distance = pixel.distance(to: centroid)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = index
                }
            }

            finalClusters[nearestIndex].pixels.append(pixel)
        }

        return finalClusters.filter { !$0.pixels.isEmpty }
    }

    /// K-Means++ initialization for better initial centroid placement
    private static func initializeCentroidsKMeansPlusPlus(pixels: [Pixel], k: Int) -> [Pixel] {
        var centroids: [Pixel] = []

        // Choose first centroid randomly
        if let firstCentroid = pixels.randomElement() {
            centroids.append(firstCentroid)
        }

        // Choose remaining centroids with probability proportional to distance squared
        while centroids.count < k {
            var distances: [CGFloat] = []
            var totalDistance: CGFloat = 0

            for pixel in pixels {
                let minDistance = centroids.map { pixel.distance(to: $0) }.min() ?? 0
                let distanceSquared = minDistance * minDistance
                distances.append(distanceSquared)
                totalDistance += distanceSquared
            }

            // Select next centroid using weighted random selection
            let random = CGFloat.random(in: 0..<totalDistance)
            var sum: CGFloat = 0

            for (index, distance) in distances.enumerated() {
                sum += distance
                if sum >= random {
                    centroids.append(pixels[index])
                    break
                }
            }
        }

        return centroids
    }
}

// MARK: - CGImage Extension for Pixel Extraction

extension CGImage {
    /// Extracts pixel data from a CGImage
    func extractPixels() -> [Pixel]? {
        guard let pixelData = dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            return nil
        }

        let width = self.width
        let height = self.height
        let bytesPerPixel = 4
        let bytesPerRow = self.bytesPerRow

        // Check the bitmap info to determine byte order
        let alphaInfo = self.alphaInfo
        let byteOrder = self.bitmapInfo.contains(.byteOrder32Little)

        // Determine if we're in BGRA or RGBA format
        // iOS typically uses BGRA with premultiplied alpha
        let isBGRA = byteOrder || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst

        var pixels: [Pixel] = []
        pixels.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)

                let red: CGFloat
                let green: CGFloat
                let blue: CGFloat

                if isBGRA {
                    // BGRA format (most common on iOS)
                    blue = CGFloat(data[offset]) / 255.0
                    green = CGFloat(data[offset + 1]) / 255.0
                    red = CGFloat(data[offset + 2]) / 255.0
                } else {
                    // RGBA format
                    red = CGFloat(data[offset]) / 255.0
                    green = CGFloat(data[offset + 1]) / 255.0
                    blue = CGFloat(data[offset + 2]) / 255.0
                }

                pixels.append(Pixel(red: red, green: green, blue: blue))
            }
        }

        return pixels
    }
}

// MARK: - Color Cache (Thread-Safe)

/// Cache for storing extracted colors by song ID
actor ColorCache {
    static let shared = ColorCache()

    private var cache: [UInt64: [Color]] = [:]

    private init() {}

    func getColors(for songID: UInt64) -> [Color]? {
        return cache[songID]
    }

    func setColors(_ colors: [Color], for songID: UInt64) {
        cache[songID] = colors
    }

    func clearCache() {
        cache.removeAll()
    }
}
