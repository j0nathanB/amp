import Foundation
import UIKit
import MediaPlayer
import os.signpost

// Instruments' built-in "Points of Interest" instrument auto-tracks
// signposts under category "PointsOfInterest". Names use an artwork.*
// prefix to separate from library.* events.
private let artworkPOI = OSSignposter(subsystem: "j0nathanb.amp", category: "PointsOfInterest")

// In-memory + on-disk cache for rasterized album artwork.
//
// Problem this solves: AlbumGridCell previously called
// LibraryService.getArtworkImage per cell, which runs an MPMediaQuery and
// a synchronous artwork.image(at:) rasterization for every visible album.
// Scrolling a 2000-album grid meant 2000 queries + 2000 rasterizations,
// with nothing cached — re-scrolling re-paid the full cost.
//
// Two-tier cache:
// 1. NSCache in memory — auto-evicts under memory pressure. Also coalesces
//    concurrent requests so fast scrolling doesn't spawn duplicate
//    rasterizations for cells that get recycled.
// 2. JPEG thumbnails on disk (Caches/thumbnails/) — survives across app
//    launches so cold launch doesn't re-pay the ~200ms per-album rasterize.
//    Lazy-persist: we only write a thumbnail after the user has actually
//    seen it (first rasterize). Invalidation via a single marker file
//    compared against MPMediaLibrary.lastModifiedDate; mismatch nukes the
//    whole dir rather than tracking per-file staleness.
//
// Invalidated on .MPMediaLibraryDidChange so edits in Apple Music don't
// leave stale artwork in memory or on disk.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 500
        return c
    }()

    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    // Disk cache root. Holds JPEG thumbnails keyed by {albumID}@{W}x{H}.jpg
    // plus a single .library_modified marker file.
    private static let thumbnailsDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails")
    }()

    private init() {
        // Invalidate disk cache if the library changed since last session.
        // Runs detached so init stays cheap. Reads may race with the wipe
        // in the tiny window before first artwork request — the marker is
        // written AFTER wipe so a crash mid-wipe re-invalidates next
        // session; worst case in-session is one stale image that gets
        // replaced on next libraryDidChange or app restart.
        let dir = Self.thumbnailsDir
        Task.detached(priority: .userInitiated) {
            let current = MPMediaLibrary.default().lastModifiedDate
            ThumbnailCache.invalidateIfStale(dir: dir, currentLibraryDate: current)
        }

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
        let dir = Self.thumbnailsDir
        Task.detached(priority: .utility) {
            let current = MPMediaLibrary.default().lastModifiedDate
            ThumbnailCache.nukeCache(dir: dir, currentLibraryDate: current)
        }
    }

    // Keyed by albumPersistentID, not trackPersistentID — tracks on the
    // same album share one cache entry (same-album skip = cache hit).
    // Trade-off: compilations with per-track custom artwork show the
    // album-rep art instead. That's the existing MediaPlayer behavior
    // pre-cache (MPMediaItem.artwork on any track of an album returns
    // the album's representative art), so no regression — just don't
    // "fix" this to track-keyed without understanding what the sharing
    // is buying.
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

        let dir = Self.thumbnailsDir
        // Disk read + MPMediaQuery + rasterize + disk write all run inside
        // this detached block. Do NOT move the disk read out to the caller
        // — keeping it here guarantees the I/O stays off-main even on disk
        // hits, so scrolling a grid never pays main-thread file I/O.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Tier 2: disk check before rasterize.
            if let image = ThumbnailCache.loadThumbnail(dir: dir, albumID: albumID, size: size) {
                artworkPOI.emitEvent("artwork.diskhit", "album: \(albumID)")
                return image
            }

            // Miss on both tiers — rasterize from MPMediaItem.
            artworkPOI.emitEvent("artwork.miss", "album: \(albumID)")
            let interval = artworkPOI.beginInterval("artwork.rasterize")
            let t0 = Date()

            let predicate = MPMediaPropertyPredicate(
                value: albumID,
                forProperty: MPMediaItemPropertyAlbumPersistentID
            )
            let query = MPMediaQuery.albums()
            query.addFilterPredicate(predicate)
            let image: UIImage? = {
                guard let rep = query.collections?.first?.representativeItem,
                      let artwork = rep.artwork else { return nil }
                return artwork.image(at: size)
            }()

            artworkPOI.endInterval("artwork.rasterize", interval, "album: \(albumID), ok: \(image != nil)")
            print("[PERF] artwork.rasterize album=\(albumID) ok=\(image != nil) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

            // Persist to disk for future sessions. Fire-and-forget at utility
            // priority so it doesn't block the caller's return.
            if let image {
                Task.detached(priority: .utility) {
                    ThumbnailCache.saveThumbnail(image, dir: dir, albumID: albumID, size: size)
                }
            }

            return image
        }

        inFlight[key] = task
        let image = await task.value
        inFlight.removeValue(forKey: key)

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private static func key(albumID: MPMediaEntityPersistentID, size: CGSize) -> NSString {
        "\(albumID)@\(Int(size.width))x\(Int(size.height))" as NSString
    }
}

// MARK: - ThumbnailCache
//
// Pure disk helpers, dir-injectable so tests can use a temp directory
// instead of polluting the real Caches/. ArtworkCache calls these with
// its hardcoded Caches/thumbnails/ path; test cases pass a UUID-suffixed
// temp dir.
//
// All writes use .atomic. This is load-bearing: JPEG decoders accept
// partial data variably (nil / partial image / subtly-wrong image); the
// atomic rename at write time eliminates the half-written-file case at
// the source rather than relying on the read side to detect it.
enum ThumbnailCache {
    static func markerURL(inDir dir: URL) -> URL {
        dir.appendingPathComponent(".library_modified")
    }

    static func thumbnailURL(inDir dir: URL, albumID: MPMediaEntityPersistentID, size: CGSize) -> URL {
        dir.appendingPathComponent("\(albumID)@\(Int(size.width))x\(Int(size.height)).jpg")
    }

    // Check marker vs. current library date; if stale or missing, wipe the
    // dir and rewrite the marker. Called once at ArtworkCache init.
    static func invalidateIfStale(dir: URL, currentLibraryDate: Date) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = markerURL(inDir: dir)

        let isFresh: Bool = {
            guard let data = try? Data(contentsOf: marker),
                  let cachedDate = try? JSONDecoder().decode(Date.self, from: data)
            else { return false }
            return cachedDate >= currentLibraryDate
        }()

        if !isFresh {
            nukeCache(dir: dir, currentLibraryDate: currentLibraryDate)
        }
    }

    // Unconditional wipe + marker rewrite. Called from libraryDidChange.
    // Marker is written AFTER the wipe (atomically) — if the app is killed
    // mid-wipe, next session's invalidateIfStale still finds a stale or
    // missing marker and re-wipes. Never the other way around, which would
    // leave stale thumbnails behind a fresh marker.
    static func nukeCache(dir: URL, currentLibraryDate: Date) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(currentLibraryDate) {
            try? data.write(to: markerURL(inDir: dir), options: .atomic)
        }
    }

    static func loadThumbnail(dir: URL, albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        let url = thumbnailURL(inDir: dir, albumID: albumID, size: size)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // Atomic JPEG write at quality 0.8. The .atomic flag is load-bearing —
    // an app-kill mid-write without it leaves a half-written file that
    // UIImage(data:) would accept as partially-decoded on next load. With
    // .atomic the file either exists fully or not at all.
    static func saveThumbnail(_ image: UIImage, dir: URL, albumID: MPMediaEntityPersistentID, size: CGSize) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let url = thumbnailURL(inDir: dir, albumID: albumID, size: size)
        try? data.write(to: url, options: .atomic)
    }
}
