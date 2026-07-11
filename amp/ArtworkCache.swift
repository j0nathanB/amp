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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sourceDidChange),
            name: .ampLibrarySourceDidChange,
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

    // Source switched or a folder library was loaded: drop the in-memory
    // tier so views re-resolve against the new source. Disk thumbnails
    // stay — keys are mode-namespaced (music unprefixed, folder "f"-
    // prefixed) so entries can't collide across sources, and folder album
    // ids are content-derived (albumArtist|album hash) so their art is
    // stable across rescans. Known v1 gap: replacing the embedded art
    // inside a file keeps serving the old folder thumbnail until the next
    // MP-change nuke wipes the shared dir.
    @objc private func sourceDidChange() {
        cache.removeAllObjects()
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
        // Mode captured once at entry (main actor); everything downstream —
        // cache keys, disk filenames, the miss path — derives from it, so
        // a mode switch mid-request can't mix sources.
        let mode = LibraryModeService.shared.mode
        let prefix = Self.keyPrefix(for: mode)
        let key = Self.key(prefix: prefix, albumID: albumID, size: size)

        if let cached = cache.object(forKey: key) {
            artworkPOI.emitEvent("artwork.hit", "album: \(albumID)")
            return cached
        }

        if let existing = inFlight[key] {
            artworkPOI.emitEvent("artwork.coalesced", "album: \(albumID)")
            return await existing.value
        }

        let dir = Self.thumbnailsDir
        // Disk read + source query + rasterize + disk write all run inside
        // this detached block. Do NOT move the disk read out to the caller
        // — keeping it here guarantees the I/O stays off-main even on disk
        // hits, so scrolling a grid never pays main-thread file I/O.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Tier 2: disk check before rasterize.
            if let image = ThumbnailCache.loadThumbnail(dir: dir, prefix: prefix, albumID: albumID, size: size) {
                artworkPOI.emitEvent("artwork.diskhit", "album: \(albumID)")
                return image
            }

            // Miss on both tiers — rasterize from the active source.
            artworkPOI.emitEvent("artwork.miss", "album: \(albumID)")
            let interval = artworkPOI.beginInterval("artwork.rasterize")
            let t0 = Date()

            let image: UIImage?
            if mode == .folder {
                // Embedded artwork from a catalog track's file, scaled to
                // the requested cell size (MP's artwork.image(at:) does
                // this scaling for the music path).
                if let data = await FolderLibraryService.shared.artworkData(forAlbum: albumID),
                   let full = UIImage(data: data) {
                    image = Self.scaled(full, toFill: size)
                } else {
                    image = nil
                }
            } else {
                let predicate = MPMediaPropertyPredicate(
                    value: albumID,
                    forProperty: MPMediaItemPropertyAlbumPersistentID
                )
                let query = MPMediaQuery.albums()
                query.addFilterPredicate(predicate)
                image = {
                    guard let rep = query.collections?.first?.representativeItem,
                          let artwork = rep.artwork else { return nil }
                    return artwork.image(at: size)
                }()
            }

            artworkPOI.endInterval("artwork.rasterize", interval, "album: \(albumID), ok: \(image != nil)")
            print("[PERF] artwork.rasterize album=\(albumID) ok=\(image != nil) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

            // Persist to disk for future sessions. Fire-and-forget at utility
            // priority so it doesn't block the caller's return.
            if let image {
                Task.detached(priority: .utility) {
                    ThumbnailCache.saveThumbnail(image, dir: dir, prefix: prefix, albumID: albumID, size: size)
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

    // Music keeps the legacy unprefixed keys (existing installs' disk
    // thumbnails stay hot); folder entries are "f"-prefixed. Namespacing
    // is load-bearing: a synthetic folder album id colliding with a real
    // MP album id must not serve the wrong art across sources.
    private static func keyPrefix(for mode: LibrarySourceMode) -> String {
        mode == .folder ? "f" : ""
    }

    private static func key(prefix: String, albumID: MPMediaEntityPersistentID, size: CGSize) -> NSString {
        "\(prefix)\(albumID)@\(Int(size.width))x\(Int(size.height))" as NSString
    }

    // Aspect-fill downscale for folder artwork (never upscales). The MP
    // path gets this from MPMediaItemArtwork.image(at:). nonisolated: runs
    // inside the detached rasterize block; UIGraphicsImageRenderer is
    // thread-safe.
    private nonisolated static func scaled(_ image: UIImage, toFill size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0,
              image.size.width > 0, image.size.height > 0 else { return image }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        guard scale < 1 else { return image }
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
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

    // prefix "" = music (legacy filenames), "f" = folder — see
    // ArtworkCache.keyPrefix for why the namespace matters.
    static func thumbnailURL(inDir dir: URL, prefix: String = "", albumID: MPMediaEntityPersistentID, size: CGSize) -> URL {
        dir.appendingPathComponent("\(prefix)\(albumID)@\(Int(size.width))x\(Int(size.height)).jpg")
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

    static func loadThumbnail(dir: URL, prefix: String = "", albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        let url = thumbnailURL(inDir: dir, prefix: prefix, albumID: albumID, size: size)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // Atomic JPEG write at quality 0.8. The .atomic flag is load-bearing —
    // an app-kill mid-write without it leaves a half-written file that
    // UIImage(data:) would accept as partially-decoded on next load. With
    // .atomic the file either exists fully or not at all.
    static func saveThumbnail(_ image: UIImage, dir: URL, prefix: String = "", albumID: MPMediaEntityPersistentID, size: CGSize) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let url = thumbnailURL(inDir: dir, prefix: prefix, albumID: albumID, size: size)
        try? data.write(to: url, options: .atomic)
    }
}
