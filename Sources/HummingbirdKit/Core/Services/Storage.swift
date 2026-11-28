import ATAppSync
import CSQLite
import Foundation
import os
import PlatformSupport

/// App persistence backed by one SQLite database (`storage.sqlite3`) in a
/// data directory. Existing JSON stores are imported lazily, so upgrades
/// retain user data without a separate migration.
///
/// Writes are encoded and committed in submission order on a background
/// queue, so the main actor never waits for JSON or SQLite.
///
/// Every value is sealed at rest (ATAppSync's `AtRestSealer`, a profile's
/// key for its own data, the device's for the rest): the database, legacy
/// files and the pending-write queue hold nothing readable without the key.
/// Files are `completeUntilFirstUserAuthentication`, so background work can
/// read and write them while the device is locked once it has been unlocked
/// since boot; the keys are readable under the same condition. A write that
/// can't land (locked before that, or failing) goes to the pending-write
/// queue, never nowhere; reads see queued values first; the queue is
/// applied, in order and once, at launch and when protected data becomes
/// available again.
final class Storage: Sendable {
    private let backend: StorageBackend
    private let writer = DispatchQueue(label: "app.hummingbird.storage", qos: .utility)
    /// Writes waiting for protected data; also where crash-safe progress is
    /// kept (`ProgressRecovery`). Nil for an in-memory database.
    let pendingWrites: PendingWriteQueue?
    /// The platform's data protection (unavailable while locked), for
    /// stores kept beside this one (the synced cache).
    let protectedData: any ProtectedDataAvailability

    /// The keys everything here is sealed with; stores kept beside this one
    /// (the profile journals) use them too.
    let atRest: AtRestKeyring

    init(directory: URL, protectedData: any ProtectedDataAvailability, atRest: AtRestKeyring) {
        self.protectedData = protectedData
        self.atRest = atRest
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = PendingWriteQueue(fileURL: directory.appendingPathComponent("pending-writes.queue"),
                                      availability: protectedData,
                                      sealer: atRest.sealer(profile: nil, purpose: "pending-writes"))
        pendingWrites = queue
        backend = StorageBackend(directory: directory, queue: queue, protectedData: protectedData, atRest: atRest)
        // Whatever a locked device or a killed process left queued lands now,
        // and again whenever the device unlocks.
        let backend = backend
        let writer = writer
        writer.async { backend.applyPendingWrites() }
        protectedData.observeProtectedDataAvailability { available in
            guard available else { return }
            writer.async { backend.applyPendingWrites() }
        }
    }

    private init(backend: StorageBackend, atRest: AtRestKeyring) {
        self.backend = backend
        self.atRest = atRest
        pendingWrites = nil
        protectedData = UnprotectedDataAvailability()
    }

    /// A private in-memory database with no files at all, for tests.
    static func inMemory() -> Storage {
        let atRest = AtRestKeyring.ephemeral()
        return Storage(backend: StorageBackend(directory: nil, queue: nil, protectedData: UnprotectedDataAvailability(),
                                               atRest: atRest), atRest: atRest)
    }

    /// The value stored for `name`. A value that can't be read now is
    /// `unavailable`, never "missing": a caller that saves after reading
    /// must not save then, or it would write over what it couldn't read.
    func read<T: Decodable>(_ type: T.Type, name: String) -> StoredRead<T> {
        backend.read(type, name: name)
    }

    func save<T: Encodable & Sendable>(_ value: T, name: String) {
        writer.async { [backend] in backend.save(value, name: name) }
    }

    /// Applies queued writes now, if protected data is available.
    func applyPendingWrites() async {
        await withCheckedContinuation { continuation in
            writer.async { [backend] in
                backend.applyPendingWrites()
                continuation.resume()
            }
        }
    }

    /// Deletes `name` (a store whose data moved elsewhere), in order with the writes.
    func remove(name: String) {
        writer.async { [backend] in backend.remove(name: name) }
    }

    /// Waits for every write submitted so far.
    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }

    /// Waits for every write submitted so far, but never past `deadline`: only
    /// for the moment the application exits. True if everything was written.
    @discardableResult
    func flushBeforeTermination(until deadline: ExitDeadline) -> Bool { deadline.drain(writer) }
}

/// Serializes migration and ordinary reads/writes as one operation. A legacy
/// file is authoritative while present: it either predates first import or is
/// the durable fallback from a failed SQLite write.
final class StorageBackend: @unchecked Sendable {
    private let lock = NSLock()
    /// Nil for an in-memory database, which has no legacy files.
    private let directory: URL?
    private let database: StorageDatabase
    private let queue: PendingWriteQueue?
    private let protectedData: any ProtectedDataAvailability
    private let atRest: AtRestKeyring
    private static let queuePrefix = "storage/"

    init(directory: URL?, queue: PendingWriteQueue?, protectedData: any ProtectedDataAvailability, atRest: AtRestKeyring) {
        self.atRest = atRest
        self.directory = directory
        self.queue = queue
        self.protectedData = protectedData
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = StorageDatabase(url: directory.appendingPathComponent("storage.sqlite3"),
                                       protectedData: protectedData, atRest: atRest)
        } else {
            database = StorageDatabase(path: ":memory:", atRest: atRest)
        }
    }

    /// Data that doesn't decode as `T` reads as missing (as it always has);
    /// data that can't be read now is `unavailable`.
    func read<T: Decodable>(_ type: T.Type, name: String) -> StoredRead<T> {
        lock.lock()
        defer { lock.unlock() }
        return readData(name: name).decoded(as: type)
    }

    private func readData(name: String) -> StoredRead<Data> {
        // A queued write is newer than anything stored, and is all there is
        // to read while the device is locked.
        switch queue?.read(key: Self.queuePrefix + name) ?? .missing {
        case .value(let data): return .value(data)
        case .unavailable: return .unavailable
        case .missing: break
        }
        guard let directory else { return database.read(name: name) }
        let legacyURL = directory.appendingPathComponent(name + ".json")
        let legacy: Data?
        do { legacy = try AtomicFile.contents(of: legacyURL) } catch { return .unavailable }
        if let legacy {
            switch openLegacy(legacy, name: name, file: legacyURL) {
            case .value(let data):
                if database.save(data, name: name) { try? FileManager.default.removeItem(at: legacyURL) }
                return .value(data)
            case .unavailable: return .unavailable
            case .missing: break
            }
        }
        return database.read(name: name)
    }

    func save<T: Encodable>(_ value: T, name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let directory else {
            database.save(data, name: name)
            return
        }
        // Locked: the database can't be opened for writing; queue instead.
        guard protectedData.isProtectedDataAvailable else {
            enqueue(data, name: name, reason: "protected_data_unavailable")
            return
        }
        let legacyURL = directory.appendingPathComponent(name + ".json")
        if database.save(data, name: name) {
            do { try FileManager.default.removeItem(at: legacyURL) }
            catch where (error as NSError).code == NSFileNoSuchFileError { }
            catch {
                if !saveLegacy(data, to: legacyURL) {
                    enqueue(data, name: name, reason: "legacy_cleanup_failed")
                    return
                }
            }
        } else if !saveLegacy(data, to: legacyURL) {
            enqueue(data, name: name, reason: "database_and_legacy_write_failed")
            return
        }
        // Stored: anything still queued for this name is older (it was
        // queued before this save), so it must neither shadow this value on
        // read nor overwrite it when the queue is applied.
        discardQueued(name: name)
    }

    private func discardQueued(name: String) {
        // By sequence, not by opening it: a value that can't be read now is
        // still older than this save, and must not land over it later.
        guard let queue, let sequence = queue.latestSequence(key: Self.queuePrefix + name) else { return }
        do { try queue.clear(key: Self.queuePrefix + name, through: sequence) }
        catch {
            Logger.performance.error("storage_queue_clear_failed name=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Writes queued values into the database, oldest first; each leaves the
    /// queue once it is stored.
    func applyPendingWrites() {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }
        let landed = queue.apply(keyPrefix: Self.queuePrefix) { write in
            guard let payload = write.payload else { return true }
            return database.save(payload, name: String(write.key.dropFirst(Self.queuePrefix.count)))
        }
        if landed > 0 { Logger.performance.notice("storage_pending_applied count=\(landed)") }
    }

    private func enqueue(_ data: Data, name: String, reason: StaticString) {
        guard let queue else {
            Logger.performance.error("storage_write_lost name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
            return
        }
        do {
            try queue.append(key: Self.queuePrefix + name, payload: data)
            Logger.performance.notice("storage_write_queued name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
        } catch {
            Logger.performance.error("storage_write_lost name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func remove(name: String) {
        lock.lock()
        defer { lock.unlock() }
        openIfNeeded()
        database.remove(name: name)
        discardQueued(name: name)
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json")) }
    }

    /// The fallback file is sealed like the database.
    private func saveLegacy(_ data: Data, to url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let sealed = try StorageSealing.sealer(for: name, in: atRest).seal(data, context: name)
            try AtomicFile.write(sealed, to: url, protection: .completeUntilFirstUserAuthentication)
            try protectedData.setProtection(.completeUntilFirstUserAuthentication, for: url)
            return true
        } catch {
            return false
        }
    }

    /// A legacy file's contents: written before sealing (plain JSON) or
    /// sealed by `saveLegacy`. One that doesn't open is quarantined, not read.
    private func openLegacy(_ stored: Data, name: String, file: URL) -> StoredRead<Data> {
        switch StorageSealing.sealer(for: name, in: atRest).open(stored, context: name) {
        case .opened(let data), .legacyPlaintext(let data): return .value(data)
        case .damaged:
            // Removed only once a copy is kept; until then it is left as it
            // is, and unavailable, so nothing saves over it.
            guard (try? AtRestQuarantine.keep(stored, label: name, near: file)) != nil else { return .unavailable }
            try? FileManager.default.removeItem(at: file)
            return .missing
        case .unavailable: return .unavailable
        }
    }
}

extension StoredRead where Value == Data {
    /// Decoded as `type`; data that doesn't decode reads as missing.
    func decoded<T: Decodable>(as type: T.Type) -> StoredRead<T> {
        switch self {
        case .value(let data):
            guard let value = try? JSONDecoder().decode(type, from: data) else { return .missing }
            return .value(value)
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
    }
}

/// Which key seals a stored value: the profile's for names of its data
/// (`profile.<id>.…`), the device's for everything else.
enum StorageSealing {
    static func sealer(for name: String, in keyring: AtRestKeyring) -> AtRestSealer {
        keyring.sealer(profile: profile(of: name), purpose: "storage")
    }

    static func profile(of name: String) -> UUID? {
        guard name.hasPrefix("profile.") else { return nil }
        let rest = name.dropFirst("profile.".count)
        guard let end = rest.firstIndex(of: ".") else { return nil }
        return UUID(uuidString: String(rest[..<end]))
    }
}

/// Synchronized key/value database. Values remain JSON blobs so persisted model
/// compatibility stays independent of the SQL schema.
///
/// Every value is sealed at rest (`StorageSealing`): `save` seals, `load`
/// opens, and there is no way to reach the table around them. A value
/// written before sealing is read once and sealed in place; one that doesn't
/// open is moved to the `quarantine` table, never deleted. The sealed-value
/// approach (rather than an encrypted page layer such as SQLCipher) keeps
/// the system SQLite every platform ships, and keeps salvage per value.
final class StorageDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let path: String
    private let atRest: AtRestKeyring

    /// Protected `completeUntilFirstUserAuthentication`: readable by work done
    /// while the device is locked, once it has been unlocked since boot.
    convenience init(url: URL, protectedData: any ProtectedDataAvailability, atRest: AtRestKeyring) {
        self.init(path: url.path, atRest: atRest)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            do { try protectedData.setProtection(.completeUntilFirstUserAuthentication, for: URL(fileURLWithPath: path)) }
            catch { Logger.performance.error("storage_protection_failed error=\(String(describing: error), privacy: .public)") }
        }
    }

    /// `":memory:"` opens a private in-memory database.
    init(path: String, atRest: AtRestKeyring) {
        self.atRest = atRest
        self.path = path
        openIfNeeded()
    }

    /// Opens the database if it isn't open: at launch, and again on each use
    /// after it couldn't be (its file unreadable before the first unlock), so
    /// it becomes available without a relaunch. Called with `lock` held, or
    /// from `init`.
    private func openIfNeeded() {
        guard handle == nil else { return }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK {
            handle = opened
            sqlite3_busy_timeout(opened, 2_000)
            if sqlite3_exec(opened, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK ||
               sqlite3_exec(opened, "CREATE TABLE IF NOT EXISTS storage (name TEXT PRIMARY KEY, payload BLOB NOT NULL, updated REAL NOT NULL)", nil, nil, nil) != SQLITE_OK ||
               sqlite3_exec(opened, "CREATE TABLE IF NOT EXISTS quarantine (name TEXT NOT NULL, payload BLOB NOT NULL, quarantined REAL NOT NULL)", nil, nil, nil) != SQLITE_OK {
                sqlite3_close(opened)
                handle = nil
            }
        } else if let opened {
            sqlite3_close(opened)
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    /// The value stored for `name`, unsealed. `missing` when there is none
    /// (or it didn't open and is now in quarantine); `unavailable` when the
    /// database or the key can't be read now, or a value that didn't open
    /// couldn't be moved aside: never mistaken for "nothing stored".
    func read(name: String) -> StoredRead<Data> {
        lock.lock()
        defer { lock.unlock() }
        openIfNeeded()
        let stored: Data
        switch readStored(name: name) {
        case .value(let data): stored = data
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
        switch StorageSealing.sealer(for: name, in: atRest).open(stored, context: name) {
        case .opened(let data):
            return .value(data)
        case .legacyPlaintext(let data):
            // Written before sealing: sealed in place now, once.
            _ = saveStored(data, name: name)
            return .value(data)
        case .damaged:
            return quarantine(stored, name: name) ? .missing : .unavailable
        case .unavailable:
            return .unavailable
        }
    }

    /// Whether `name` has a value that didn't open and was quarantined
    /// (tests and diagnostics).
    func quarantinedCount(name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        openIfNeeded()
        guard let handle else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM quarantine WHERE name = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Seals `data` for `name` and stores it.
    @discardableResult
    func save(_ data: Data, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openIfNeeded()
        return saveStored(data, name: name)
    }

    /// A database that couldn't be opened (its file unreadable before the
    /// first unlock) or a query that fails is `unavailable`; only a query
    /// that ran and found no row is `missing`.
    private func readStored(name: String) -> StoredRead<Data> {
        guard let handle else { return .unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM storage WHERE name = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return .unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return .unavailable }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: break
        case SQLITE_DONE: return .missing
        default: return .unavailable
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return .value(Data()) }
        return .value(Data(bytes: bytes, count: count))
    }

    /// Moves a value that didn't open out of the way, keeping it.
    /// One transaction: a crash or a full disk part way leaves the value
    /// where it was, never in neither place.
    private func quarantine(_ stored: Data, name: String) -> Bool {
        guard let handle, sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        guard moveToQuarantine(stored, name: name), sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return false
        }
        Logger.performance.error("storage_value_quarantined bytes=\(stored.count)")
        return true
    }

    private func moveToQuarantine(_ stored: Data, name: String) -> Bool {
        guard let handle else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO quarantine(name, payload, quarantined) VALUES(?1, ?2, ?3)",
                                 -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let bound = sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK
            && stored.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), sqliteTransient) } == SQLITE_OK
            && sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK
        guard bound, sqlite3_step(statement) == SQLITE_DONE else { return false }
        return removeStored(name: name)
    }

    @discardableResult
    private func removeStored(name: String) -> Bool {
        guard let handle else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM storage WHERE name = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func saveStored(_ plaintext: Data, name: String) -> Bool {
        guard let handle,
              let data = try? StorageSealing.sealer(for: name, in: atRest).seal(plaintext, context: name) else { return false }
        var statement: OpaquePointer?
        let sql = "INSERT INTO storage(name, payload, updated) VALUES(?1, ?2, ?3) ON CONFLICT(name) DO UPDATE SET payload=excluded.payload, updated=excluded.updated"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
        let blobResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard blobResult == SQLITE_OK,
              sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }
}

extension StorageDatabase {
    func remove(name: String) {
        lock.lock()
        defer { lock.unlock() }
        removeStored(name: name)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
