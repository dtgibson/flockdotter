import Foundation
import Darwin

public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public let recoveryFormat: String
    public let recoveryVersion: Int
    public let workspaceID: UUID
    public let revision: UInt64
    public let sourceToken: UUID
    public let image: ImageIdentity
    public let markers: [Marker]
    public let baselineDigest: String
    public let savedAt: String

    public init(workspaceID: UUID, revision: UInt64, sourceToken: UUID,
                image: ImageIdentity, markers: [Marker], baselineDigest: String) {
        recoveryFormat = "dotcounter-recovery"; recoveryVersion = 1
        self.workspaceID = workspaceID; self.revision = revision; self.sourceToken = sourceToken
        self.image = image; self.markers = markers; self.baselineDigest = baselineDigest
        savedAt = ISO8601DateFormatter().string(from: Date())
    }

    public var document: CountDocument { CountDocument(image: image, markers: markers) }

    public func validate() throws {
        guard recoveryFormat == "dotcounter-recovery", recoveryVersion == 1 else {
            throw RecoveryError.invalid("This version of recovery data is not supported.")
        }
        try document.validate()
        guard baselineDigest.count == 64, baselineDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ISO8601DateFormatter().date(from: savedAt) != nil else {
            throw RecoveryError.invalid("Recovery metadata is invalid.")
        }
    }
}

public struct RecoveredWorkspace: @unchecked Sendable {
    public let snapshot: RecoverySnapshot
    public let candidate: ImageCandidate
}

public struct RecoveryCommit: Sendable {
    public let snapshot: RecoverySnapshot
    public let sourceURL: URL
    /// Publication succeeded. The new workspace MUST be installed even when this is non-nil.
    public let durabilityWarning: String?
}

public enum RecoveryClearResult: Sendable {
    case durableEmpty(cleanupWarning: String?)
    case failed(String)
    case durabilityUncertain(String)
}

public enum RecoveryFaultPoint: String, Sendable, CaseIterable {
    case beforeSourceCopy, afterSourceSync, beforeManifestWrite, afterManifestSync, beforePublication, afterPublication, beforeDirectorySync
    case beforeClearRemoval, afterClearRemoval, afterClearSync, beforeClearCleanup
}

public enum RecoveryError: LocalizedError, Sendable {
    case invalid(String), staleRevision, injected(RecoveryFaultPoint)
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .staleRevision: "A newer workspace change is already saved. Retry the current count."
        case .injected(let point): "Simulated recovery failure at \(point.rawValue)."
        }
    }
}

/// Its queue is the sole disk writer. No synchronous file, decode or hashing work
/// runs on the caller's actor. Replacement and edits use the same ordered queue.
public actor RecoveryStore {
    public nonisolated let directory: URL
    public nonisolated let initialEpoch: UUID
    private let worker: RecoveryWorker

    public init(directory: URL? = nil, epoch: UUID = UUID(), fault: (@Sendable (RecoveryFaultPoint) throws -> Void)? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotCounter/Recovery", isDirectory: true)
        self.directory = root
        initialEpoch = epoch
        worker = RecoveryWorker(directory: root, epoch: epoch, fault: fault)
    }

    public nonisolated func sourceURL(token: UUID) -> URL {
        directory.appendingPathComponent("source-" + token.uuidString.lowercased() + ".blob")
    }

    public func load(epoch: UUID? = nil) async throws -> RecoveredWorkspace? {
        let epoch = epoch ?? initialEpoch
        return try await worker.perform { worker in try worker.requireEpoch(epoch); return try worker.load() }
    }

    public func replace(candidate: ImageCandidate, document: CountDocument,
                        workspaceID: UUID = UUID(), baselineDigest: String, epoch: UUID? = nil, newEpoch: UUID? = nil) async throws -> RecoveryCommit {
        let epoch = epoch ?? initialEpoch
        return try await worker.perform { worker in
            try worker.requireEpoch(epoch)
            let result = try worker.replace(candidate: candidate, document: document, workspaceID: workspaceID, baselineDigest: baselineDigest)
            worker.epoch = newEpoch ?? epoch
            return result
        }
    }

    public func save(snapshot: RecoverySnapshot, epoch: UUID? = nil) async throws -> RecoveryCommit {
        let epoch = epoch ?? initialEpoch
        return try await worker.perform { worker in try worker.requireEpoch(epoch); return try worker.save(snapshot) }
    }

    public func clear(expectedWorkspaceID: UUID, sourceToken: UUID, previousEpoch: UUID, newEpoch: UUID) async throws -> RecoveryClearResult {
        try await worker.perform { worker in
            try worker.requireEpoch(previousEpoch)
            guard worker.current?.workspaceID == expectedWorkspaceID, worker.current?.sourceToken == sourceToken else { throw RecoveryError.staleRevision }
            // Revoke publication even when removal or durability subsequently fails.
            worker.epoch = newEpoch
            return worker.clear()
        }
    }

    /// Keep this token until the export/import reader has finished, even when
    /// its presentation is dismissed or a different workspace is committed.
    public func acquireSourceLease(token: UUID) async throws -> URL {
        try await worker.perform { worker in
            let url = worker.sourceURL(token)
            try worker.requireRegularFile(url)
            worker.leases[token, default: 0] += 1
            return url
        }
    }

    public func releaseSourceLease(token: UUID) async {
        _ = try? await worker.perform { worker in
            if let count = worker.leases[token], count > 1 { worker.leases[token] = count-1 }
            else { worker.leases.removeValue(forKey: token) }
            worker.cleanOrphans(keeping: Set(worker.current.map { [$0.sourceToken] } ?? []))
            return true
        }
    }
}

private final class RecoveryWorker: @unchecked Sendable {
    let directory: URL
    let queue = DispatchQueue(label: "app.dotcounter.recovery", qos: .userInitiated)
    let fault: (@Sendable (RecoveryFaultPoint) throws -> Void)?
    var current: RecoverySnapshot?
    var epoch: UUID
    var initialized = false
    var leases: [UUID: Int] = [:]
    var durabilityUncertainTokens: Set<UUID> = []

    init(directory: URL, epoch: UUID, fault: (@Sendable (RecoveryFaultPoint) throws -> Void)?) {
        self.directory = directory; self.epoch = epoch; self.fault = fault
    }

    func requireEpoch(_ requested: UUID) throws {
        guard epoch == requested else { throw RecoveryError.staleRevision }
    }

    func clear() -> RecoveryClearResult {
        var removed = false
        // current and uncertainty remain ownership pins until checked directory sync.
        do {
            try makeDirectory()
            try fault?(.beforeClearRemoval)
            if FileManager.default.fileExists(atPath: manifestURL.path) { try requireRegularFile(manifestURL) }
            guard Darwin.unlink(manifestURL.path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            removed = true
            try fault?(.afterClearRemoval)
            // Required on retry as well, even if current.json was already absent.
            try synchronizeDirectory()
        } catch {
            if let token = current?.sourceToken { durabilityUncertainTokens.insert(token) }
            return removed ? .durabilityUncertain(error.localizedDescription) : .failed(error.localizedDescription)
        }
        current = nil; initialized = true; durabilityUncertainTokens = []
        var cleanupWarning: String?
        do {
            try fault?(.afterClearSync)
            try fault?(.beforeClearCleanup)
            cleanOrphans(keeping: [])
        } catch { cleanupWarning = error.localizedDescription }
        return .durableEmpty(cleanupWarning: cleanupWarning)
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (RecoveryWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    var manifestURL: URL { directory.appendingPathComponent("current.json") }
    func sourceURL(_ token: UUID) -> URL { directory.appendingPathComponent("source-" + token.uuidString.lowercased() + ".blob") }

    func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = directory; try? mutable.setResourceValues(values)
        let valuesRead = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard valuesRead.isSymbolicLink != true else { throw RecoveryError.invalid("Recovery directory cannot be a symbolic link.") }
    }

    func requireRegularFile(_ url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
            throw RecoveryError.invalid("Recovery contains an invalid file reference.")
        }
    }

    func load() throws -> RecoveredWorkspace? {
        try makeDirectory()
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            initialized = true; current = nil; cleanOrphans(keeping: [])
            return nil
        }
        try requireRegularFile(manifestURL)
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ResourceLimits.maxJSONBytes else { throw RecoveryError.invalid("Recovery data is too large to read safely.") }
        let data = try Data(contentsOf: manifestURL)
        try JSONValidation.validateSyntax(data)
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        try snapshot.validate()
        let source = sourceURL(snapshot.sourceToken)
        try requireRegularFile(source)
        let candidate = try ImageService.inspect(url: source, hash: ImageService.hashFile(source), filename: snapshot.image.originalFilename)
        guard candidate.identity.matches(snapshot.image) else {
            throw RecoveryError.invalid("The saved original photo does not match the recovery record.")
        }
        current = snapshot; initialized = true; durabilityUncertainTokens = []
        cleanOrphans(keeping: [snapshot.sourceToken])
        return RecoveredWorkspace(snapshot: snapshot, candidate: candidate)
    }

    func replace(candidate: ImageCandidate, document: CountDocument, workspaceID: UUID, baselineDigest: String) throws -> RecoveryCommit {
        try makeDirectory(); try document.validate()
        guard candidate.identity.matches(document.image) else { throw RecoveryError.invalid("The original photo does not match the marker file.") }
        let token = UUID(), source = sourceURL(token)
        let stagingSource = directory.appendingPathComponent(".staging-" + UUID().uuidString)
        var published = false
        defer {
            try? FileManager.default.removeItem(at: stagingSource)
            if !published { try? FileManager.default.removeItem(at: source) }
        }
        try fault?(.beforeSourceCopy)
        let hash = try ImageService.copyAndHash(from: candidate.sourceURL, to: stagingSource)
        guard hash == document.image.sha256 else { throw RecoveryError.invalid("The candidate original changed while it was being copied.") }
        let verified = try ImageService.inspect(url: stagingSource, hash: hash, filename: document.image.originalFilename)
        guard verified.identity.matches(document.image) else { throw RecoveryError.invalid("The original photo dimensions do not match.") }
        try fault?(.afterSourceSync)
        try atomicRename(stagingSource, source)
        // Source rename must be durable before the manifest may refer to it.
        try synchronizeDirectory()
        let snapshot = RecoverySnapshot(workspaceID: workspaceID, revision: 0, sourceToken: token,
                                        image: document.image, markers: document.markers, baselineDigest: baselineDigest)
        let previousToken = current?.sourceToken
        let result = try publish(snapshot)
        published = true
        current = snapshot; initialized = true
        if result.durabilityWarning == nil {
            durabilityUncertainTokens = []; cleanOrphans(keeping: [token])
        } else {
            durabilityUncertainTokens.insert(token)
            if let previousToken { durabilityUncertainTokens.insert(previousToken) }
        }
        return result
    }

    func save(_ snapshot: RecoverySnapshot) throws -> RecoveryCommit {
        try snapshot.validate()
        guard initialized, let current, snapshot.workspaceID == current.workspaceID,
              snapshot.sourceToken == current.sourceToken, snapshot.revision >= current.revision,
              snapshot.image == current.image else { throw RecoveryError.staleRevision }
        if snapshot.revision == current.revision, snapshot != current {
            // savedAt is diagnostic; its timestamp alone never grants ordering.
            guard snapshot.document == current.document, snapshot.baselineDigest == current.baselineDigest else { throw RecoveryError.staleRevision }
        }
        let result = try publish(snapshot)
        self.current = snapshot
        if result.durabilityWarning == nil {
            durabilityUncertainTokens = []; cleanOrphans(keeping: [snapshot.sourceToken])
        } else { durabilityUncertainTokens.insert(snapshot.sourceToken) }
        return result
    }

    func publish(_ snapshot: RecoverySnapshot) throws -> RecoveryCommit {
        try snapshot.validate()
        let temp = directory.appendingPathComponent(".staging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try fault?(.beforeManifestWrite)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let check = try JSONDecoder().decode(RecoverySnapshot.self, from: data); try check.validate()
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try output.write(contentsOf: data); try output.synchronize(); try output.close() }
        catch { try? output.close(); throw error }
        try fault?(.afterManifestSync)
        try fault?(.beforePublication)
        try atomicRename(temp, manifestURL)
        // No throwing operation after this point may imply replacement rejection.
        var warning: String?
        do { try fault?(.afterPublication); try fault?(.beforeDirectorySync); try synchronizeDirectory() }
        catch { warning = "Recovery isn’t up to date. The new count is still here. \(error.localizedDescription)" }
        return RecoveryCommit(snapshot: snapshot, sourceURL: sourceURL(snapshot.sourceToken), durabilityWarning: warning)
    }

    func atomicRename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func synchronizeDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func cleanOrphans(keeping tokens: Set<UUID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        let names = Set(tokens.union(leases.keys).union(durabilityUncertainTokens).map { sourceURL($0).lastPathComponent })
        for url in urls {
            let name = url.lastPathComponent
            let validSource: Bool
            if name.hasPrefix("source-"), name.hasSuffix(".blob") {
                validSource = UUID(uuidString: String(name.dropFirst(7).dropLast(5))) != nil
            } else { validSource = false }
            let validStaging = name.hasPrefix(".staging-") && UUID(uuidString: String(name.dropFirst(9))) != nil
            if validStaging || (validSource && !names.contains(name)) {
                // removeItem unlinks a symlink itself; it does not follow its target.
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
