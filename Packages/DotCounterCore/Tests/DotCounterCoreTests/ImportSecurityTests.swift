import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DotCounterCore

final class ImportSecurityTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func sparse(_ url: URL, bytes: UInt64) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }
    func testGrowingJSONStreamConsumesAtMostLimitPlusSentinel() throws {
        let limit = 128 * 1024
        var consumed = 0
        // The source continues growing; no trusted size metadata is involved.
        XCTAssertThrowsError(try BoundedFileReader.read(maximumBytes: limit) { requested in
            consumed += requested
            return Data(repeating: 32, count: requested)
        }) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadTooLarge) }
        XCTAssertEqual(consumed, limit + 1)
        let bytes = Data([0, 255, 1, 254, 2, 253])
        var offset = 0
        let result = try BoundedFileReader.read(maximumBytes: bytes.count) { requested in
            defer { offset = bytes.count }
            return offset == 0 ? bytes.prefix(requested) : Data()
        }
        XCTAssertEqual(result, bytes)
    }
    func testActualJSONCeilingRejects33MiBFile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("growing.json")
        try sparse(source, bytes: 33 * 1024 * 1024)
        XCTAssertThrowsError(try BoundedFileReader.read(source, maximumBytes: ResourceLimits.maxJSONBytes)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadTooLarge)
        }
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, 33 * 1024 * 1024)
    }
    func testSourceCeilingRejects257MiBAndRemovesPartialCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider.jpg"), destination = root.appendingPathComponent("private.blob")
        try sparse(source, bytes: 257 * 1024 * 1024)
        XCTAssertThrowsError(try ImageService.copyAndHash(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, 257 * 1024 * 1024)
        let exact = Data((0..<255).map(UInt8.init))
        try exact.write(to: source)
        _ = try ImageService.copyAndHash(from: source, to: destination, maximumBytes: UInt64(exact.count))
        XCTAssertEqual(try Data(contentsOf: destination), exact)
    }
    func testCancelledCopyRemovesOnlyUnpublishedDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("partial")
        try Data(repeating: 13, count: 1024).write(to: source)
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try ImageService.copyAndHash(from: source, to: destination)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled source copy succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data(repeating: 13, count: 1024))
    }
    func testLiveOwnersAndReadersSurviveReapingAndLastReleaseCleans() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var owner: TransientDirectory? = try TransientDirectory(root: root)
        let generated = try XCTUnwrap(owner).url.appendingPathComponent("generated.png")
        try Data([1, 2, 3]).write(to: generated)
        var inFlightReader = owner
        owner = nil
        try TransientDirectory.removeOrphans(root: root)
        XCTAssertEqual(try Data(contentsOf: generated), Data([1, 2, 3]))
        XCTAssertNotNil(inFlightReader)
        inFlightReader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: generated.deletingLastPathComponent().path))
    }
    func testOrphanCleanupSkipsUnknownNamesAndAllSymlinks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try directory(); defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("keep.jpg"); try Data([42]).write(to: sentinel)
        let orphan = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data().write(to: orphan.appendingPathComponent(".lease")); try Data([1]).write(to: orphan.appendingPathComponent("old.png"))
        let unknown = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let linkedChild = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedChild, withDestinationURL: outside)
        let linkedLease = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: linkedLease, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedLease.appendingPathComponent(".lease"), withDestinationURL: sentinel)
        try TransientDirectory.removeOrphans(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        for url in [unknown, linkedChild, linkedLease, sentinel] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        XCTAssertThrowsError(try TransientDirectory.removeOrphans(root: linkedRoot))
        XCTAssertThrowsError(try TransientDirectory(root: linkedRoot))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
    }
    func testPreparedCandidateLeaseRetiresAfterImmutableRecoveryHandoff() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil); XCTAssertTrue(CGImageDestinationFinalize(encoder))
        var candidate: ImageCandidate? = try await ImageService.prepare(url: input)
        let privateDirectory = try XCTUnwrap(candidate?.owner).url
        let identity = try XCTUnwrap(candidate).identity
        try TransientDirectory.removeOrphans()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidate).sourceURL), try Data(contentsOf: input))
        let store = RecoveryStore(directory: root.appendingPathComponent("recovery"))
        let document = CountDocument(image: identity, markers: [Marker(x: 0.2, y: 0.3)])
        let committed = try await store.replace(candidate: XCTUnwrap(candidate), document: document, workspaceID: UUID(), baselineDigest: document.contentDigest)
        candidate = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateDirectory.path))
        try TransientDirectory.removeOrphans()
        XCTAssertEqual(try Data(contentsOf: committed.sourceURL), try Data(contentsOf: input))
        let recovered = try await store.load()
        XCTAssertEqual(recovered?.snapshot.markers, document.markers)
    }
}
