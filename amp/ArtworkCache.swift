import Foundation
import UIKit
import MediaPlayer
import os.signpost

// Instruments' built-in "Points of Interest" instrument auto-tracks
// signposts under category "PointsOfInterest". Names use an artwork.*
// prefix to separate from library.* events.
private let artworkPOI = OSSignposter(subsystem: "j0nathanb.amp", category: "PointsOfInterest")

// In-memory cache for rasterized album artwork.
//
// Problem this solves: AlbumGridCell previously called
// LibraryService.getArtworkImage per cell, which runs an MPMediaQuery and
// a synchronous artwork.image(at:) rasterization for every visible album.
// Scrolling a 2000-album grid meant 2000 queries + 2000 rasterizations,
// with nothing cached — re-scrolling re-paid the full cost.
//
// Rasterization is the expensive step (MPMediaItemArtwork pulls embedded
// image data out of the audio file's metadata). NSCache handles automatic
// eviction under memory pressure; we also coalesce concurrent requests
// for the same (albumID, size) so fast scrolling doesn't spawn duplicate
// rasterizations for cells that get recycled.
//
// Invalidated on .MPMediaLibraryDidChange so edits in Apple Music don't
// leave stale artwork in memory.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 500
        return c
    }()

    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryDidChange),
            name: .MPMediaLibraryDidChange,
            object: nil
        )
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
    }

    deinit {
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func libraryDidChange() {
        cache.removeAllObjects()
    }

    func artwork(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) async -> UIImage? {
        let key = Self.key(albumID: albumID, size: size)

        if let cached = cache.object(forKey: key) {
            artworkPOI.emitEvent("artwork.hit", "album: \(albumID)")
            return cached
        }

        if let existing = inFlight[key] {
            artworkPOI.emitEvent("artwork.coalesced", "album: \(albumID)")
            return await existing.value
        }

        artworkPOI.emitEvent("artwork.miss", "album: \(albumID)")
        let interval = artworkPOI.beginInterval("artwork.rasterize")
        let t0 = Date()

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let predicate = MPMediaPropertyPredicate(
                value: albumID,
                forProperty: MPMediaItemPropertyAlbumPersistentID
            )
            let query = MPMediaQuery.albums()
            query.addFilterPredicate(predicate)
            guard let rep = query.collections?.first?.representativeItem,
                  let artwork = rep.artwork else { return nil }
            return artwork.image(at: size)
        }

        inFlight[key] = task
        let image = await task.value
        inFlight.removeValue(forKey: key)

        artworkPOI.endInterval("artwork.rasterize", interval, "album: \(albumID), ok: \(image != nil)")
        print("[PERF] artwork.rasterize album=\(albumID) ok=\(image != nil) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private static func key(albumID: MPMediaEntityPersistentID, size: CGSize) -> NSString {
        "\(albumID)@\(Int(size.width))x\(Int(size.height))" as NSString
    }
}
