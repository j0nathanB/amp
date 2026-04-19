import Foundation
import MediaPlayer
import CryptoKit

class QueuePersistenceService {
    static let shared = QueuePersistenceService()

    // MARK: - Properties

    private let fileManager = FileManager.default

    // Storage locations.
    //
    // Primary format is binary PropertyList — replaces JSON to cut
    // cold-launch queue-restore from ~489ms to single-digit ms on large
    // libraries (two UInt64 arrays of up to 23k each dominate the decode
    // cost; binary plist reads them near-memcpy-speed vs. JSON's char-by-
    // char number parsing).
    //
    // Legacy JSON URLs remain as read-only fallbacks for users upgrading
    // from the old format. After a successful plist save, the sibling
    // .json file is removed (see performSave). History has no legacy
    // fallback — losing one rotation on upgrade is acceptable.
    private var cacheURL: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("queue_cache.plist")
    }

    private var legacyCacheURL: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("queue_cache.json")
    }

    private var backupDirectory: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QueueData")
    }

    private var backupURL: URL? {
        backupDirectory?.appendingPathComponent("queue_backup.plist")
    }

    private var legacyBackupURL: URL? {
        backupDirectory?.appendingPathComponent("queue_backup.json")
    }

    private var historyURL: URL? {
        backupDirectory?.appendingPathComponent("queue_history.plist")
    }
    
    // Debouncing properties
    private var pendingSave: PersistedQueue?
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.amp.queuepersistence", qos: .background)
    private var changeCount = 0
    private var lastBackupTime = Date()
    
    // Constants
    private let maxHistoryCount = 5
    private let backupInterval: TimeInterval = 30 // seconds
    private let backupChangeThreshold = 10
    private let debounceDelay: TimeInterval = 1.0 // second
    
    // MARK: - Initialization
    
    private init() {
        // Create directories if needed
        createDirectoriesIfNeeded()

        // Clean up orphaned temp files on launch
        cleanupTempFiles()

        print("[QUEUE-PERSIST] [Init] [\(Date().ISO8601Format())]: Service initialized - Cache: \(cacheURL?.path ?? "nil"), Backup: \(backupURL?.path ?? "nil")")
    }
    
    // MARK: - Public Methods
    
    func saveQueue(_ queue: PersistedQueue) async {
        // Debug: Track save operations
        print("🟢 [QUEUE-PERSIST] [Save] Save requested - will NOT trigger any loads")
        
        // Cancel any pending save
        saveWorkItem?.cancel()
        
        // Store for debounced save
        pendingSave = queue
        changeCount += 1
        
        // Create new debounced save work item
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let queueToSave = self.pendingSave else { return }
            
            Task {
                await self.performSave(queueToSave)
            }
        }
        
        saveWorkItem = workItem
        
        // Schedule the save after debounce delay
        saveQueue.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
    }
    
    func saveQueueImmediately(_ queue: PersistedQueue) async {
        // Cancel any pending debounced save
        saveWorkItem?.cancel()
        pendingSave = nil
        
        await performSave(queue)
    }
    
    func loadQueue() async -> PersistedQueue? {
        let startTime = Date()
        
        // Debug: Log what's triggering this load
        print("🔴 [QUEUE-PERSIST] [Load-Stack] Load triggered from:")
        Thread.callStackSymbols.prefix(10).forEach { symbol in
            if symbol.contains("amp") || symbol.contains("QueueManager") {
                print("  -> \(symbol)")
            }
        }
        
        // 1. Try cache first (fastest)
        if let cached = await loadFromCache() {
            if validateChecksum(cached) {
                let loadTime = Date().timeIntervalSince(startTime) * 1000
                print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: Loaded from cache - \(cached.trackIDs.count) tracks in \(Int(loadTime))ms")
                return cached
            } else {
                print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: Cache checksum validation failed")
            }
        }
        
        // 2. Try permanent backup
        if let backup = await loadFromBackup() {
            if validateChecksum(backup) {
                // Restore to cache for next time
                _ = await writeToCache(backup)
                let loadTime = Date().timeIntervalSince(startTime) * 1000
                print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: Loaded from backup - \(backup.trackIDs.count) tracks in \(Int(loadTime))ms")
                return backup
            } else {
                print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: Backup checksum validation failed")
            }
        }
        
        // 3. Try migration from UserDefaults (one-time)
        if let migrated = await migrateFromUserDefaults() {
            await saveQueueImmediately(migrated)
            clearUserDefaults()
            let loadTime = Date().timeIntervalSince(startTime) * 1000
            print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: Migrated from UserDefaults - \(migrated.trackIDs.count) tracks in \(Int(loadTime))ms")
            return migrated
        }
        
        // 4. Return nil - QueueManagerService will start fresh
        print("[QUEUE-PERSIST] [Load] [\(Date().ISO8601Format())]: No saved queue found")
        return nil
    }
    
    // MARK: - Private Methods - Core Save/Load
    
    private func performSave(_ queue: PersistedQueue) async {
        let startTime = Date()

        // Always write to cache
        let cacheSuccess = await writeToCache(queue)

        // After a successful plist save, remove the sibling legacy JSON if
        // it still exists. Fire-and-forget; `removeItem` on a nonexistent
        // file is a silent no-op so there's no gate needed.
        if cacheSuccess, let legacy = legacyCacheURL {
            Task.detached(priority: .background) { [fileManager] in
                try? fileManager.removeItem(at: legacy)
            }
        }

        // Determine if we should also write to backup
        let shouldBackup = changeCount >= backupChangeThreshold ||
                          Date().timeIntervalSince(lastBackupTime) >= backupInterval

        if shouldBackup {
            let backupSuccess = await writeToBackup(queue)
            if backupSuccess {
                changeCount = 0
                lastBackupTime = Date()

                // Clean up legacy backup JSON for the same reason.
                if let legacy = legacyBackupURL {
                    Task.detached(priority: .background) { [fileManager] in
                        try? fileManager.removeItem(at: legacy)
                    }
                }

                // Also update history
                await updateHistory(queue)
            }

            let saveTime = Date().timeIntervalSince(startTime) * 1000
            print("[QUEUE-PERSIST] [Save] [\(Date().ISO8601Format())]: Saved to cache: \(cacheSuccess), backup: \(backupSuccess) - \(queue.trackIDs.count) tracks in \(Int(saveTime))ms")
        } else {
            let saveTime = Date().timeIntervalSince(startTime) * 1000
            print("[QUEUE-PERSIST] [Save] [\(Date().ISO8601Format())]: Saved to cache only - \(queue.trackIDs.count) tracks in \(Int(saveTime))ms")
        }
    }
    
    private func writeToCache(_ queue: PersistedQueue) async -> Bool {
        guard let url = cacheURL else { return false }
        return await writeToFile(queue, at: url, description: "cache")
    }
    
    private func writeToBackup(_ queue: PersistedQueue) async -> Bool {
        guard let url = backupURL else { return false }
        return await writeToFile(queue, at: url, description: "backup")
    }
    
    private func writeToFile(_ queue: PersistedQueue, at url: URL, description: String) async -> Bool {
        return await Task.detached(priority: .background) {
            do {
                let data = try QueueBinaryCoder.encode(queue)
                let tempURL = url.appendingPathExtension("tmp")

                // Write to temp file first (atomic at filesystem level)
                try data.write(to: tempURL, options: .atomic)

                // Verify: read back and decode
                let verifyData = try Data(contentsOf: tempURL)
                let verified = try QueueBinaryCoder.decode(verifyData)

                guard self.validateChecksum(verified) else {
                    try? self.fileManager.removeItem(at: tempURL)
                    print("[QUEUE-PERSIST] [Write] [\(Date().ISO8601Format())]: Failed to verify \(description) - checksum mismatch")
                    return false
                }

                // Atomically replace the real file
                if self.fileManager.fileExists(atPath: url.path) {
                    _ = try self.fileManager.replaceItem(at: url, withItemAt: tempURL, backupItemName: nil, resultingItemURL: nil)
                } else {
                    try self.fileManager.moveItem(at: tempURL, to: url)
                }

                let fileSize = (try? self.fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                print("[QUEUE-PERSIST] [Write] [\(Date().ISO8601Format())]: Successfully wrote \(description) - \(fileSize) bytes")
                return true

            } catch {
                print("[QUEUE-PERSIST] [Write] [\(Date().ISO8601Format())]: Failed to write \(description) - \(error.localizedDescription)")
                return false
            }
        }.value
    }
    
    private func loadFromCache() async -> PersistedQueue? {
        guard let url = cacheURL else { return nil }
        return await loadFromFile(plistURL: url, legacyJSONURL: legacyCacheURL, description: "cache")
    }

    private func loadFromBackup() async -> PersistedQueue? {
        guard let url = backupURL else { return nil }
        return await loadFromFile(plistURL: url, legacyJSONURL: legacyBackupURL, description: "backup")
    }

    // Tries the new binary plist first, falls back to reading the legacy
    // JSON file for users upgrading. A successful legacy read is not
    // migrated inline — the next saveQueue writes the new format and
    // deletes the legacy sibling (see performSave).
    private func loadFromFile(plistURL: URL, legacyJSONURL: URL?, description: String) async -> PersistedQueue? {
        return await Task.detached(priority: .userInitiated) {
            // Fast path: binary plist.
            if let data = try? Data(contentsOf: plistURL) {
                do {
                    let queue = try QueueBinaryCoder.decode(data)
                    print("[QUEUE-PERSIST] [Read] [\(Date().ISO8601Format())]: Successfully read \(description) plist - \(data.count) bytes, \(queue.trackIDs.count) tracks")
                    return queue
                } catch {
                    print("[QUEUE-PERSIST] [Read] [\(Date().ISO8601Format())]: Plist decode failed for \(description) - \(error.localizedDescription); trying legacy")
                }
            }

            // Legacy path: JSON from an earlier version of the app.
            if let legacyURL = legacyJSONURL, let data = try? Data(contentsOf: legacyURL) {
                do {
                    let queue = try QueueBinaryCoder.decodeLegacyJSON(data)
                    print("[QUEUE-PERSIST] [Read] [\(Date().ISO8601Format())]: Read \(description) legacy JSON - \(queue.trackIDs.count) tracks (will migrate on next save)")
                    return queue
                } catch {
                    print("[QUEUE-PERSIST] [Read] [\(Date().ISO8601Format())]: Legacy JSON decode failed for \(description) - \(error.localizedDescription)")
                }
            }

            return nil
        }.value
    }
    
    // MARK: - Migration
    
    private func migrateFromUserDefaults() async -> PersistedQueue? {
        return await Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let queueKey = "savedPlaybackQueueIDs"
            
            guard let savedIDs = defaults.array(forKey: queueKey) as? [MPMediaEntityPersistentID],
                  !savedIDs.isEmpty else {
                return nil
            }
            
            let isShuffled = defaults.bool(forKey: "shuffleOnStart")
            
            print("[QUEUE-PERSIST] [Migration] [\(Date().ISO8601Format())]: Found \(savedIDs.count) tracks in UserDefaults")
            
            return PersistedQueue(
                savedAt: Date(),
                trackIDs: savedIDs,
                currentIndex: 0,
                isShuffled: isShuffled,
                isLooped: false,
                originalOrder: savedIDs,
                checksum: self.generateChecksum(for: savedIDs)
            )
        }.value
    }
    
    private func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "savedPlaybackQueueIDs")
        print("[QUEUE-PERSIST] [Migration] [\(Date().ISO8601Format())]: Cleared UserDefaults after successful migration")
    }
    
    // MARK: - History Management
    
    private func updateHistory(_ queue: PersistedQueue) async {
        guard let url = historyURL else { return }

        await Task.detached(priority: .background) {
            var history: [PersistedQueue] = []

            // Load existing history (plist only — no JSON fallback here;
            // losing one rotation on upgrade is acceptable).
            if let data = try? Data(contentsOf: url),
               let existingHistory = try? QueueBinaryCoder.decodeHistory(data) {
                history = existingHistory
            }

            // Add new entry at beginning
            history.insert(queue, at: 0)

            // Keep only last N entries
            if history.count > self.maxHistoryCount {
                history = Array(history.prefix(self.maxHistoryCount))
            }

            // Save updated history atomically.
            if let data = try? QueueBinaryCoder.encodeHistory(history) {
                try? data.write(to: url, options: .atomic)
                print("[QUEUE-PERSIST] [History] [\(Date().ISO8601Format())]: Updated history - \(history.count) entries")
            }
        }.value
    }
    
    // MARK: - Validation
    
    private func validateChecksum(_ queue: PersistedQueue) -> Bool {
        let calculated = generateChecksum(for: queue.trackIDs)
        let isValid = calculated == queue.checksum
        if !isValid {
            print("[QUEUE-PERSIST] [Validation] [\(Date().ISO8601Format())]: Checksum mismatch - expected: \(queue.checksum), got: \(calculated)")
        }
        return isValid
    }
    
    private func generateChecksum(for trackIDs: [MPMediaEntityPersistentID]) -> String {
        let idString = trackIDs.map { String($0) }.joined(separator: ",")
        let data = Data(idString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Directory Management
    
    private func createDirectoriesIfNeeded() {
        guard let backupDir = backupDirectory else { return }
        
        if !fileManager.fileExists(atPath: backupDir.path) {
            do {
                try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: nil)
                print("[QUEUE-PERSIST] [Setup] [\(Date().ISO8601Format())]: Created backup directory at \(backupDir.path)")
            } catch {
                print("[QUEUE-PERSIST] [Setup] [\(Date().ISO8601Format())]: Failed to create backup directory - \(error.localizedDescription)")
            }
        }
    }
    
    private func cleanupTempFiles() {
        // Clean up any orphaned temp files
        let directories = [
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            backupDirectory
        ].compactMap { $0 }
        
        for directory in directories {
            do {
                let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "tmp" {
                    try fileManager.removeItem(at: file)
                    print("[QUEUE-PERSIST] [Cleanup] [\(Date().ISO8601Format())]: Removed orphaned temp file: \(file.lastPathComponent)")
                }
            } catch {
                // Ignore errors during cleanup
            }
        }
    }
}

// MARK: - Binary PropertyList coder
//
// Pure encode/decode helpers — no service state, no file I/O. Lives at
// file scope so tests can round-trip PersistedQueue payloads without
// spinning up the singleton or touching real disk locations.
//
// Binary plist replaces JSON as the primary wire format:
//   - Two UInt64 arrays of up to ~23k each (trackIDs + originalOrder)
//     drive the 489ms JSON decode baseline on cold launch. Binary plist
//     reads integer arrays ~10-50x faster (no char-by-char number parse).
//   - Date is a native plist type — no .iso8601 strategy needed.
//
// decodeLegacyJSON exists solely for upgrade-path reads of cache/backup
// files written by the pre-plist build. Successful legacy decode is not
// persisted in place; the next saveQueue rewrites in plist and
// performSave deletes the legacy sibling.
enum QueueBinaryCoder {
    static func encode(_ queue: PersistedQueue) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(queue)
    }

    static func decode(_ data: Data) throws -> PersistedQueue {
        try PropertyListDecoder().decode(PersistedQueue.self, from: data)
    }

    static func encodeHistory(_ history: [PersistedQueue]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(history)
    }

    static func decodeHistory(_ data: Data) throws -> [PersistedQueue] {
        try PropertyListDecoder().decode([PersistedQueue].self, from: data)
    }

    // Legacy-format read path — kept only for one-time upgrade reads.
    // Once every cache/backup pair has been rewritten in plist, no code
    // path in the app still calls this at runtime (only tests do).
    static func decodeLegacyJSON(_ data: Data) throws -> PersistedQueue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedQueue.self, from: data)
    }
}

// MARK: - Data Models

struct PersistedQueue: Codable {
    var version: Int = 1
    let savedAt: Date
    let trackIDs: [MPMediaEntityPersistentID]
    let currentIndex: Int?
    let isShuffled: Bool
    let isLooped: Bool
    let originalOrder: [MPMediaEntityPersistentID]
    let checksum: String
    let playbackPosition: TimeInterval?  // Persisted playback position for resume after app termination

    init(savedAt: Date, trackIDs: [MPMediaEntityPersistentID], currentIndex: Int?, isShuffled: Bool, isLooped: Bool, originalOrder: [MPMediaEntityPersistentID], checksum: String, playbackPosition: TimeInterval? = nil) {
        self.savedAt = savedAt
        self.trackIDs = trackIDs
        self.currentIndex = currentIndex
        self.isShuffled = isShuffled
        self.isLooped = isLooped
        self.originalOrder = originalOrder
        self.checksum = checksum
        self.playbackPosition = playbackPosition
    }
}

// MARK: - Debug/Testing Extensions

#if DEBUG
extension QueuePersistenceService {
    func debugInfo() -> String {
        var info = "[QUEUE-PERSIST DEBUG INFO]\n"
        info += "Cache URL: \(cacheURL?.path ?? "nil")\n"
        info += "Backup URL: \(backupURL?.path ?? "nil")\n"
        info += "History URL: \(historyURL?.path ?? "nil")\n"
        
        if let cacheURL = cacheURL, fileManager.fileExists(atPath: cacheURL.path) {
            if let attrs = try? fileManager.attributesOfItem(atPath: cacheURL.path),
               let size = attrs[.size] as? Int,
               let modified = attrs[.modificationDate] as? Date {
                info += "Cache: \(size) bytes, modified: \(modified.ISO8601Format())\n"
            }
        }
        
        if let backupURL = backupURL, fileManager.fileExists(atPath: backupURL.path) {
            if let attrs = try? fileManager.attributesOfItem(atPath: backupURL.path),
               let size = attrs[.size] as? Int,
               let modified = attrs[.modificationDate] as? Date {
                info += "Backup: \(size) bytes, modified: \(modified.ISO8601Format())\n"
            }
        }
        
        info += "Change count: \(changeCount)\n"
        info += "Last backup: \(lastBackupTime.ISO8601Format())"
        
        return info
    }
    
    func clearAllStorage() async {
        if let cacheURL = cacheURL {
            try? fileManager.removeItem(at: cacheURL)
        }
        if let backupURL = backupURL {
            try? fileManager.removeItem(at: backupURL)
        }
        if let historyURL = historyURL {
            try? fileManager.removeItem(at: historyURL)
        }
        clearUserDefaults()
        print("[QUEUE-PERSIST] [Debug] [\(Date().ISO8601Format())]: Cleared all storage")
    }
}
#endif