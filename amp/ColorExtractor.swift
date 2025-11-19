//
//  ColorExtractor.swift
//  amp
//

import SwiftUI
import UIKit

struct ColorExtractor {
    /// Extracts the dominant color from an image using downsampling and averaging
    static func extractDominantColor(from image: UIImage) -> Color {
        // Downsample the image to 10x10 pixels for fast processing
        guard let downsampledImage = downsample(image: image, to: CGSize(width: 10, height: 10)),
              let cgImage = downsampledImage.cgImage else {
            return Color.white
        }

        // Get pixel data from the downsampled image
        guard let pixelData = cgImage.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            return Color.white
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        var totalRed: CGFloat = 0
        var totalGreen: CGFloat = 0
        var totalBlue: CGFloat = 0
        var pixelCount: CGFloat = 0

        // Sum up all pixel values
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let red = CGFloat(data[offset]) / 255.0
                let green = CGFloat(data[offset + 1]) / 255.0
                let blue = CGFloat(data[offset + 2]) / 255.0

                // Skip very dark or very light pixels (likely background/edge artifacts)
                let brightness = (red + green + blue) / 3.0
                if brightness > 0.15 && brightness < 0.95 {
                    totalRed += red
                    totalGreen += green
                    totalBlue += blue
                    pixelCount += 1
                }
            }
        }

        // Calculate average color
        guard pixelCount > 0 else { return Color.white }

        let avgRed = totalRed / pixelCount
        let avgGreen = totalGreen / pixelCount
        let avgBlue = totalBlue / pixelCount

        // Boost saturation slightly for better visual appeal
        let boostedColor = boostSaturation(red: avgRed, green: avgGreen, blue: avgBlue, factor: 1.2)

        return Color(
            red: boostedColor.red,
            green: boostedColor.green,
            blue: boostedColor.blue
        )
    }

    /// Downsamples an image to the specified size
    private static func downsample(image: UIImage, to size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Boosts the saturation of a color
    private static func boostSaturation(red: CGFloat, green: CGFloat, blue: CGFloat, factor: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        // Convert RGB to HSB
        let max = Swift.max(red, green, blue)
        let min = Swift.min(red, green, blue)
        let delta = max - min

        guard delta > 0 else {
            return (red, green, blue) // Grayscale color, no saturation to boost
        }

        let brightness = max
        let saturation = delta / max

        // Calculate hue
        var hue: CGFloat = 0
        if max == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if max == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }
        hue /= 6

        // Boost saturation
        let newSaturation = Swift.min(saturation * factor, 1.0)

        // Convert back to RGB
        let c = brightness * newSaturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c

        var newRed: CGFloat = 0
        var newGreen: CGFloat = 0
        var newBlue: CGFloat = 0

        let hueSegment = Int(hue * 6)
        switch hueSegment {
        case 0: (newRed, newGreen, newBlue) = (c, x, 0)
        case 1: (newRed, newGreen, newBlue) = (x, c, 0)
        case 2: (newRed, newGreen, newBlue) = (0, c, x)
        case 3: (newRed, newGreen, newBlue) = (0, x, c)
        case 4: (newRed, newGreen, newBlue) = (x, 0, c)
        default: (newRed, newGreen, newBlue) = (c, 0, x)
        }

        return (newRed + m, newGreen + m, newBlue + m)
    }
}

/// Cache for storing extracted colors by song ID
class ColorCache {
    static let shared = ColorCache()

    private var cache: [UInt64: Color] = [:]
    private let queue = DispatchQueue(label: "com.amp.colorcache", attributes: .concurrent)

    private init() {}

    func getColor(for songID: UInt64) -> Color? {
        queue.sync {
            cache[songID]
        }
    }

    func setColor(_ color: Color, for songID: UInt64) {
        queue.async(flags: .barrier) {
            self.cache[songID] = color
        }
    }

    func clearCache() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
