import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Disk-backed cache shared by successive UMP presentations for the same
/// video and selected formats. Media is stored in one preallocated file and
/// addressed by an atomic sidecar index.
actor UMPMediaCache {
    static let shared = UMPMediaCache()

    struct Handle: Hashable, Sendable { fileprivate let id: String }
    struct Descriptor: Sendable {
        let key: String
        let allocationBytes: Int64
        let isExact: Bool
    }
    private struct Range: Codable, Sendable { let offset: Int64; let length: Int }
    private struct Index: Codable, Sendable {
        var allocationBytes: Int64
        var isExact: Bool
        var usedBytes: Int64
        var ranges: [String: Range]
    }
    private struct Entry {
        let file: URL
        let indexFile: URL
        let descriptor: Descriptor
        var index: Index
    }

    private var entries: [String: Entry] = [:]

    func open(_ descriptor: Descriptor) throws -> Handle {
        let id = Self.digest(descriptor.key)
        if entries[id] != nil { return Handle(id: id) }
        let root = try Self.cacheRoot()
        let file = root.appendingPathComponent("\(id).media")
        let indexFile = root.appendingPathComponent("\(id).json")
        let decoded: Index?
        if let data = try? Data(contentsOf: indexFile) {
            decoded = try? JSONDecoder().decode(Index.self, from: data)
        } else {
            decoded = nil
        }
        var index = decoded ?? Index(
            allocationBytes: descriptor.allocationBytes,
            isExact: descriptor.isExact,
            usedBytes: 0,
            ranges: [:]
        )
        if !FileManager.default.fileExists(atPath: file.path) {
            try Self.createPreallocatedFile(at: file, size: descriptor.allocationBytes)
            index = Index(allocationBytes: descriptor.allocationBytes, isExact: descriptor.isExact,
                          usedBytes: 0, ranges: [:])
            try Self.persist(index, to: indexFile)
        } else if index.allocationBytes < descriptor.allocationBytes {
            try Self.growPreallocatedFile(at: file, from: index.allocationBytes, to: descriptor.allocationBytes)
            index.allocationBytes = descriptor.allocationBytes
            index.isExact = descriptor.isExact
            try Self.persist(index, to: indexFile)
        }
        entries[id] = Entry(file: file, indexFile: indexFile, descriptor: descriptor, index: index)
        return Handle(id: id)
    }

    func read(_ handle: Handle, name: String) throws -> Data? {
        guard let entry = entries[handle.id], let range = entry.index.ranges[name] else { return nil }
        return try Self.withMappedFile(entry.file, offset: range.offset, length: range.length, writable: false) {
            Data(bytes: $0, count: range.length)
        }
    }

    func contiguousRange(_ handle: Handle, namePrefix: String) -> ClosedRange<Int>? {
        guard let entry = entries[handle.id] else { return nil }
        let sequences = Set(entry.index.ranges.keys.compactMap { name -> Int? in
            guard name.hasPrefix(namePrefix) else { return nil }
            return Int(name.dropFirst(namePrefix.count))
        })
        guard let first = sequences.min() else { return nil }
        var last = first
        while sequences.contains(last + 1) { last += 1 }
        return first...last
    }

    func write(_ data: Data, to handle: Handle, name: String) throws {
        guard !data.isEmpty, var entry = entries[handle.id] else { return }
        if entry.index.ranges[name] != nil { return }
        let end = entry.index.usedBytes + Int64(data.count)
        guard end <= entry.index.allocationBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try Self.withMappedFile(entry.file, offset: entry.index.usedBytes, length: data.count, writable: true) { pointer in
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        entry.index.ranges[name] = Range(offset: entry.index.usedBytes, length: data.count)
        entry.index.usedBytes = end
        try Self.persist(entry.index, to: entry.indexFile)
        entries[handle.id] = entry
    }

    private static func cacheRoot() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Hummingbird/UMP", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func persist(_ index: Index, to url: URL) throws {
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }

    private static func createPreallocatedFile(at url: URL, size: Int64) throws {
        let fd = systemOpen(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        do { try preallocate(fd: fd, from: 0, length: size); try truncate(fd: fd, size: size) }
        catch { unlink(url.path); throw error }
    }

    private static func growPreallocatedFile(at url: URL, from oldSize: Int64, to newSize: Int64) throws {
        let fd = systemOpen(url.path, O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try preallocate(fd: fd, from: oldSize, length: newSize - oldSize)
        try truncate(fd: fd, size: newSize)
    }

    private static func preallocate(fd: Int32, from offset: Int64, length: Int64) throws {
        guard length > 0 else { return }
        #if canImport(Darwin)
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                             fst_offset: offset, fst_length: length, fst_bytesalloc: 0)
        guard fcntl(fd, F_PREALLOCATE, &store) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOSPC)
        }
        #elseif canImport(Glibc)
        let result = posix_fallocate(fd, off_t(offset), off_t(length))
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .ENOSPC) }
        #endif
    }

    private static func truncate(fd: Int32, size: Int64) throws {
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func withMappedFile<T>(_ url: URL, offset: Int64, length: Int, writable: Bool,
                                          _ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        guard length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let fd = systemOpen(url.path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let page = Int64(sysconf(_SC_PAGESIZE))
        let aligned = offset / page * page
        let delta = Int(offset - aligned)
        let mappedLength = delta + length
        let protection = PROT_READ | (writable ? PROT_WRITE : 0)
        let mapping = mmap(nil, mappedLength, protection, MAP_SHARED, fd, off_t(aligned))
        guard mapping != MAP_FAILED, let mapping else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { munmap(mapping, mappedLength) }
        let pointer = mapping.advanced(by: delta)
        let result = try body(pointer)
        if writable, msync(mapping, mappedLength, MS_SYNC) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return result
    }

    private static func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t? = nil) -> Int32 {
        #if canImport(Darwin)
        if let mode { return Darwin.open(path, flags, mode) }
        return Darwin.open(path, flags)
        #elseif canImport(Glibc)
        if let mode { return Glibc.open(path, flags, mode) }
        return Glibc.open(path, flags)
        #endif
    }
}
