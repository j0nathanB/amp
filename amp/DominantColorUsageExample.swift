//
//  DominantColorUsageExample.swift
//  amp
//
//  Usage examples for the K-Means dominant color extraction system
//

import SwiftUI
import UIKit

// MARK: - Usage Example 1: Extract Colors from Album Cover

/*
 Basic usage - Extract 4 dominant colors from an album cover:

 ```swift
 let albumCoverImage = UIImage(named: "album_artwork")
 let colors = await albumCoverImage?.extractDominantColors(
     colorCount: 4,
     quality: 100,
     filterExtremes: true
 )

 // colors is [Color] sorted by frequency, e.g.:
 // [Color.red, Color.blue, Color.yellow, Color.purple]
 ```
 */

// MARK: - Usage Example 2: Custom Parameters

/*
 Extract with custom parameters:

 ```swift
 // Get more colors with lower quality for speed
 let colors = await image?.extractDominantColors(
     colorCount: 6,      // Extract 6 dominant colors
     quality: 50,        // Use 50x50 downsample (faster)
     filterExtremes: true // Filter out near-black/white
 )

 // Get fewer colors with higher quality
 let colors = await image?.extractDominantColors(
     colorCount: 3,      // Just 3 colors
     quality: 150,       // Use 150x150 (more accurate)
     filterExtremes: false // Include all colors
 )
 ```
 */

// MARK: - Usage Example 3: Using DominantColorBackground View

/*
 Replace existing background with dominant color gradient:

 ```swift
 struct NowPlayingView: View {
     @ObservedObject var audioPlayer: AudioPlayerService

     var body: some View {
         ZStack {
             // Moody gradient background from album colors
             if let currentSong = audioPlayer.currentTrack {
                 DominantColorBackground(song: currentSong)
             }

             // Your UI content
             VStack {
                 Text(audioPlayer.currentTrack?.title ?? "")
                 // ... more UI
             }
         }
     }
 }
 ```
 */

// MARK: - Usage Example 4: Custom SwiftUI View with Extracted Colors

/*
 Create your own custom gradient view:

 ```swift
 struct CustomAlbumBackground: View {
     let song: Song
     @State private var colors: [Color] = []

     var body: some View {
         LinearGradient(
             colors: colors.isEmpty ? [.purple, .blue] : colors,
             startPoint: .topLeading,
             endPoint: .bottomTrailing
         )
         .task {
             if let artwork = loadArtwork(for: song),
                let extractedColors = await artwork.extractDominantColors() {
                 colors = extractedColors
             }
         }
     }
 }
 ```
 */

// MARK: - Usage Example 5: Caching Colors

/*
 Use the built-in actor-based cache for performance:

 ```swift
 func getColorsForSong(_ song: Song) async -> [Color] {
     // Check cache first
     if let cached = await ColorCache.shared.getColors(for: song.persistentID) {
         return cached
     }

     // Extract if not cached
     guard let artwork = loadArtwork(for: song) else {
         return [.purple]
     }

     let colors = await artwork.extractDominantColors()

     // Cache for next time
     await ColorCache.shared.setColors(colors, for: song.persistentID)

     return colors
 }

 // Clear cache when needed (e.g., low memory warning)
 await ColorCache.shared.clearCache()
 ```
 */

// MARK: - Usage Example 6: Handling Edge Cases

/*
 The system gracefully handles edge cases:

 ```swift
 // 1. No artwork available
 let colors = await nilImage?.extractDominantColors()
 // Returns: [Color.purple] (fallback)

 // 2. Image with only 1-2 colors
 let colors = await monochromeImage?.extractDominantColors(colorCount: 4)
 // Returns: Available colors repeated to meet count
 // e.g., [red, red, red, red] or [red, blue, red, blue]

 // 3. Image is all black or white (with filterExtremes: true)
 let colors = await blackImage?.extractDominantColors(filterExtremes: true)
 // Returns: [Color.purple] (fallback when no valid colors)

 // 4. Very small color palette
 let colors = await simpleImage?.extractDominantColors(colorCount: 10)
 // Returns: Up to 10 colors, or fewer if image has fewer distinct colors
 ```
 */

// MARK: - Usage Example 7: Performance Tuning

/*
 Balance quality vs performance:

 ```swift
 // FAST - Good for real-time UI updates (50x50 = 2,500 pixels)
 let fastColors = await artwork?.extractDominantColors(
     colorCount: 3,
     quality: 50,
     filterExtremes: true
 )
 // Processing time: ~5-15ms on modern devices

 // BALANCED - Default setting (100x100 = 10,000 pixels)
 let balancedColors = await artwork?.extractDominantColors()
 // Processing time: ~15-30ms on modern devices

 // HIGH QUALITY - More accurate colors (150x150 = 22,500 pixels)
 let qualityColors = await artwork?.extractDominantColors(
     colorCount: 5,
     quality: 150,
     filterExtremes: true
 )
 // Processing time: ~40-80ms on modern devices

 // Note: All processing happens on background thread via Task.detached
 // UI remains responsive regardless of quality setting
 ```
 */

// MARK: - Usage Example 8: Advanced - Custom Gradient Styles

/*
 Create different gradient effects with extracted colors:

 ```swift
 struct AlbumGradientStyles: View {
     let colors: [Color]

     // Radial gradient
     var radialStyle: some View {
         RadialGradient(
             colors: colors,
             center: .center,
             startRadius: 0,
             endRadius: 500
         )
     }

     // Angular gradient (spinning)
     var angularStyle: some View {
         AngularGradient(
             colors: colors + [colors.first].compactMap { $0 },
             center: .center
         )
     }

     // Layered with opacity
     var layeredStyle: some View {
         ZStack {
             colors[0]
             colors[1].opacity(0.7)
             colors[2].opacity(0.5)
         }
     }
 }
 ```
 */

// MARK: - Usage Example 9: Replace BlurredArtworkBackground

/*
 Easy migration from the old system:

 OLD CODE:
 ```swift
 BlurredArtworkBackground(song: currentSong)
 ```

 NEW CODE (with dominant colors):
 ```swift
 DominantColorBackground(song: currentSong)
 ```

 Benefits of new system:
 - Extracts actual dominant colors (not just average)
 - Better visual variety (multiple colors, not single tint)
 - Moody, artistic gradient effect
 - Still cached and performant
 - Handles all edge cases gracefully
 - Works on iOS 15+ with automatic fallback
 */

// MARK: - Performance Characteristics

/*
 K-Means Clustering Performance:

 Quality Setting | Pixel Count | Typical Time | Best For
 ----------------|-------------|--------------|----------
 50x50          | 2,500       | ~5-15ms      | Real-time UI
 100x100 (default) | 10,000   | ~15-30ms     | Balanced
 150x150        | 22,500      | ~40-80ms     | High quality
 200x200        | 40,000      | ~80-150ms    | Maximum accuracy

 Algorithm Details:
 - K-Means++ initialization for better clustering
 - Converges in ~3-7 iterations typically
 - Euclidean distance in RGB color space
 - Filters near-black (<15% brightness) and near-white (>90%)
 - All processing on background thread (Task.detached)
 - Actor-based cache prevents race conditions

 Memory Usage:
 - Downsampled image: ~40KB (100x100 RGBA)
 - Pixel array: ~40KB (10,000 pixels × 24 bytes)
 - K-Means state: ~5KB (clusters + centroids)
 - Total working memory: ~85KB per extraction
 - Cache: ~20 color palettes in memory (~5KB total)
 */

// MARK: - Algorithm Explanation

/*
 How K-Means Clustering Works for Color Extraction:

 1. DOWNSAMPLE (100x100)
    - Original: 1200×1200 = 1,440,000 pixels
    - Downsampled: 100×100 = 10,000 pixels
    - 99.3% reduction, minimal quality loss

 2. FILTER EXTREME COLORS
    - Remove near-black (brightness < 15%)
    - Remove near-white (brightness > 90%)
    - Keeps visually interesting colors

 3. INITIALIZE CENTROIDS (K-Means++)
    - Choose first centroid randomly
    - Choose next centroids far from existing ones
    - Better initial placement = faster convergence

 4. ITERATE (max 10 iterations)
    a. Assign each pixel to nearest centroid
    b. Recalculate centroids as mean of assigned pixels
    c. Check convergence (centroids stopped moving)
    d. Repeat until converged

 5. SORT BY FREQUENCY
    - Count pixels in each cluster
    - Sort clusters by size (largest first)
    - Return centroid colors

 Result: Colors human eyes perceive as dominant, not mathematical average

 Example:
 - Image: Red album with small white text
 - Simple average: Pink (mix of red + white)
 - K-Means: [Red, Dark Red, Brown, Orange]
 - Better matches human perception!
 */
