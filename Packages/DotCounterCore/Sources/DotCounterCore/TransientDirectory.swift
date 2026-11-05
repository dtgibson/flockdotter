import Foundation
import Darwin

/// A private generated-file lifetime. Reader/request references keep the lease
/// alive; the last reference removes only this owner's generated directory.
public final class TransientDirectory: @unchecked Sendable {
    public static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Transient", isDirectory: true) }
    public let url: URL
    private let lease: Int32

    public init(root: URL = TransientDirectory.root) throws {
        try Self.ensureRoot(root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // The reaper ignores construction names. Publish the UUID directory
        // only after its lease is locked, before it can contain image bytes.
        let staging = root.appendingPathComponent("creating-" + directory.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(staging.appendingPathComponent(".lease").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: staging); throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); try? FileManager.default.removeItem(at: staging); throw POSIXError(.EIO)
        }
        do { try FileManager.default.moveItem(at: staging, to: directory) }
        catch { Darwin.close(fd); try? FileManager.default.removeItem(at: staging); throw error }
        url = directory; lease = fd
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        flock(lease, LOCK_UN); Darwin.close(lease)
    }

    private static func ensureRoot(_ root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    /// Crash leftovers only: live owners (including another process) hold an
    /// exclusive lock. Unknown names, symlinks, and unlocked files are untouched.
    public static func removeOrphans(root: URL = TransientDirectory.root) throws {
        try ensureRoot(root)
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  (try? FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
            let fd = Darwin.open(entry.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(fd, LOCK_UN) }
            // Recheck the entry after obtaining its lease before removal.
            guard (try? FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
            try FileManager.default.removeItem(at: entry)
        }
    }
}
