//
//  ColorExtractionTester.swift
//  amp
//
//  Test the K-Means color extraction with sample images
//

import SwiftUI
import UIKit

#if DEBUG

/// Tester view for dominant color extraction
struct ColorExtractionTester: View {
    @State private var extractedColors: [Color] = []
    @State private var isProcessing = false
    @State private var processingTime: TimeInterval = 0
    @State private var selectedQuality: Int = 100
    @State private var selectedColorCount: Int = 4
    @State private var filterExtremes: Bool = true

    // Quality presets
    let qualityOptions = [50, 100, 150, 200]
    let colorCountOptions = [3, 4, 5, 6]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("🎨 Dominant Color Extractor Test")
                    .font(.title.bold())
                    .padding(.top)

                // Controls
                VStack(alignment: .leading, spacing: 15) {
                    Text("Settings")
                        .font(.headline)

                    // Quality Picker
                    VStack(alignment: .leading) {
                        Text("Quality (image downsample size)")
                        Picker("Quality", selection: $selectedQuality) {
                            ForEach(qualityOptions, id: \.self) { quality in
                                Text("\(quality)×\(quality)").tag(quality)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Color Count Picker
                    VStack(alignment: .leading) {
                        Text("Number of colors to extract")
                        Picker("Color Count", selection: $selectedColorCount) {
                            ForEach(colorCountOptions, id: \.self) { count in
                                Text("\(count) colors").tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Filter Toggle
                    Toggle("Filter near-black/white colors", isOn: $filterExtremes)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                // Extract Button
                Button(action: extractColors) {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isProcessing ? "Extracting..." : "Extract Colors from Sample")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isProcessing)

                // Processing Time
                if processingTime > 0 {
                    Text("Processing time: \(String(format: "%.1f", processingTime * 1000))ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Results
                if !extractedColors.isEmpty {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Extracted Colors (sorted by frequency)")
                            .font(.headline)

                        // Color swatches
                        VStack(spacing: 12) {
                            ForEach(Array(extractedColors.enumerated()), id: \.offset) { index, color in
                                HStack(spacing: 15) {
                                    // Color swatch
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(color)
                                        .frame(width: 60, height: 60)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )

                                    VStack(alignment: .leading) {
                                        Text("Color \(index + 1)")
                                            .font(.subheadline.bold())
                                        Text(colorDescription(color))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    // Gradient Previews
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Gradient Previews")
                            .font(.headline)

                        // Linear gradient
                        VStack(alignment: .leading) {
                            Text("Linear Gradient")
                                .font(.caption)
                            LinearGradient(
                                colors: extractedColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(height: 100)
                            .cornerRadius(8)
                        }

                        // Blurred circles (like the fallback)
                        VStack(alignment: .leading) {
                            Text("Blurred Circles (iOS <18 fallback)")
                                .font(.caption)
                            GeometryReader { geo in
                                ZStack {
                                    extractedColors[0]
                                        .opacity(0.6)

                                    Circle()
                                        .fill(extractedColors[0])
                                        .frame(width: geo.size.width * 0.8)
                                        .blur(radius: 50)
                                        .offset(x: -50, y: -30)

                                    Circle()
                                        .fill(extractedColors[1])
                                        .frame(width: geo.size.width * 0.7)
                                        .blur(radius: 45)
                                        .offset(x: 50, y: -20)

                                    if extractedColors.count > 2 {
                                        Circle()
                                            .fill(extractedColors[2])
                                            .frame(width: geo.size.width * 0.75)
                                            .blur(radius: 55)
                                            .offset(x: 20, y: 40)
                                    }

                                    if extractedColors.count > 3 {
                                        Circle()
                                            .fill(extractedColors[3])
                                            .frame(width: geo.size.width * 0.65)
                                            .blur(radius: 48)
                                            .offset(x: -30, y: 35)
                                    }
                                }
                            }
                            .frame(height: 150)
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func extractColors() {
        isProcessing = true

        Task {
            let startTime = Date()

            // Create a sample test image (gradient)
            let testImage = createSampleAlbumCover()

            // Extract colors
            let colors = await testImage.extractDominantColors(
                colorCount: selectedColorCount,
                quality: selectedQuality,
                filterExtremes: filterExtremes
            )

            let endTime = Date()

            await MainActor.run {
                extractedColors = colors
                processingTime = endTime.timeIntervalSince(startTime)
                isProcessing = false
            }
        }
    }

    // MARK: - Helper Functions

    /// Creates a sample album cover for testing
    private func createSampleAlbumCover() -> UIImage {
        let size = CGSize(width: 300, height: 300)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            // Create a complex color palette that mimics real album art

            // Background - deep blue
            UIColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Large red circle
            UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1.0).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 50, y: 50, width: 120, height: 120))

            // Orange accent
            UIColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1.0).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 180, y: 100, width: 80, height: 80))

            // Purple detail
            UIColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1.0).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 100, y: 180, width: 100, height: 100))

            // Small yellow highlight
            UIColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1.0).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 220, y: 220, width: 40, height: 40))
        }

        return image
    }

    /// Returns a human-readable description of a color
    private func colorDescription(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)

        return "RGB(\(r), \(g), \(b))"
    }
}

// MARK: - Preview

struct ColorExtractionTester_Previews: PreviewProvider {
    static var previews: some View {
        ColorExtractionTester()
    }
}

#endif
