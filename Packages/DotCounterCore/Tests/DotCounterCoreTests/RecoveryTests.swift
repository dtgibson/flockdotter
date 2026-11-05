import XCTest
import Foundation
@testable import DotCounterCore

final class RecoveryTests: XCTestCase, @unchecked Sendable {
    final class FaultSwitch: @unchecked Sendable {
        let lock = NSLock()
        private var point: RecoveryFaultPoint?
        func set(_ value: RecoveryFaultPoint?) { lock.lock(); defer { lock.unlock() }; point = value }
        func check(_ value: RecoveryFaultPoint) throws {
            lock.lock(); let selected = point; lock.unlock()
            if value == selected { throw RecoveryError.injected(value) }
        }
    }

    func testEveryCommitBoundaryRecoversCompleteOldOrNewPair() async throws {
        for boundary in RecoveryFaultPoint.allCases where !boundary.rawValue.contains("Clear") {
            let directory = try ImageServiceTests().temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = directory.appendingPathComponent("source.jpg")
            try ImageServiceTests().writeFixture(fixture)
            let candidate = try await ImageService.prepare(url: fixture)
            defer { try? FileManager.default.removeItem(at: candidate.sourceURL) }
            let recovery = directory.appendingPathComponent("Recovery")
            let faults = FaultSwitch()
            let store = RecoveryStore(directory: recovery, fault: { try faults.check($0) })
            _ = try await store.load()
            let old = CountDocument(image: candidate.identity,markers: [Marker(x: 0.1,y: 0.2)])
            let oldCommit = try await store.replace(candidate: candidate,document: old,baselineDigest: old.contentDigest)
            _ = try await store.acquireSourceLease(token: oldCommit.snapshot.sourceToken)
            let new = CountDocument(image: candidate.identity,markers: [Marker(x: 0.7,y: 0.8),Marker(x: 1,y: 1)])
            faults.set(boundary)
            let afterPublication = boundary == .afterPublication || boundary == .beforeDirectorySync
            do {
                let commit = try await store.replace(candidate: candidate,document: new,baselineDigest: new.contentDigest)
                XCTAssertTrue(afterPublication, "\(boundary) must fail before publication")
                XCTAssertNotNil(commit.durabilityWarning)
            } catch {
                XCTAssertFalse(afterPublication, "published workspace must be returned as committed")
            }
            await store.releaseSourceLease(token: oldCommit.snapshot.sourceToken)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldCommit.sourceURL.path), "prior source survives failed or durability-uncertain publication")
            // A fresh instance simulates termination, ignoring all in-memory state.
            let reopened = RecoveryStore(directory: recovery)
            let recovered = try await reopened.load()
            let restored = try XCTUnwrap(recovered)
            XCTAssertEqual(restored.snapshot.document, afterPublication ? new : old, "\(boundary)")
            XCTAssertEqual(try ImageService.hashFile(restored.candidate.sourceURL), restored.snapshot.image.sha256)
            if !afterPublication { XCTAssertEqual(restored.snapshot.sourceToken, oldCommit.snapshot.sourceToken) }
        }
    }

    func testRevisionAndWorkspaceBarrierBaselineAndSourceIndependentRecovery() async throws {
        let directory = try ImageServiceTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("source.jpg")
        try ImageServiceTests().writeFixture(fixture)
        let candidate = try await ImageService.prepare(url: fixture)
        let store = RecoveryStore(directory: directory.appendingPathComponent("Recovery"))
        let first = CountDocument(image: candidate.identity,markers: [])
        let initial = try await store.replace(candidate: candidate,document: first,baselineDigest: first.contentDigest)
        let markers = [Marker(x: 0.123456789012345,y: 1)]
        let latest = RecoverySnapshot(workspaceID: initial.snapshot.workspaceID, revision: 10,sourceToken: initial.snapshot.sourceToken,
                                      image: first.image,markers: markers,baselineDigest: first.contentDigest)
        _ = try await store.save(snapshot: latest)
        do { _ = try await store.save(snapshot: initial.snapshot); XCTFail("stale revision must reject") } catch RecoveryError.staleRevision { }
        let leasedURL = try await store.acquireSourceLease(token: initial.snapshot.sourceToken)
        let next = try await store.replace(candidate: candidate,document: first,baselineDigest: first.contentDigest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leasedURL.path), "an active export reader keeps the prior source alive")
        do { _ = try await store.save(snapshot: latest); XCTFail("old workspace must never overwrite replacement") } catch RecoveryError.staleRevision { }
        await store.releaseSourceLease(token: initial.snapshot.sourceToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasedURL.path), "last reader release retires the replaced source")
        XCTAssertNotEqual(initial.snapshot.workspaceID,next.snapshot.workspaceID)
        try FileManager.default.removeItem(at: fixture)
        try FileManager.default.removeItem(at: candidate.sourceURL)
        let recovered = try await RecoveryStore(directory: store.directory).load()
        let restored = try XCTUnwrap(recovered)
        XCTAssertEqual(restored.snapshot,next.snapshot)
        XCTAssertEqual(restored.snapshot.baselineDigest,first.contentDigest)
        let blobs = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys:nil).filter { $0.pathExtension == "blob" }
        XCTAssertEqual(blobs.count,1)
    }

    func testClearDurabilityFaultsRetryReaderDrainAndPreservation() async throws {
        for boundary in [RecoveryFaultPoint.beforeClearRemoval, .afterClearRemoval, .afterClearSync, .beforeClearCleanup] {
            let directory = try ImageServiceTests().temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = directory.appendingPathComponent("original.jpg")
            try ImageServiceTests().writeFixture(fixture)
            let originalBytes = try Data(contentsOf: fixture)
            let image = try await ImageService.prepare(url: fixture)
            defer { try? FileManager.default.removeItem(at: image.sourceURL) }
            let faults = FaultSwitch(), epoch = UUID(), next = UUID()
            let store = RecoveryStore(directory: directory.appendingPathComponent("Recovery"), epoch: epoch, fault: { try faults.check($0) })
            let doc = CountDocument(image: image.identity, markers: [Marker(x: 0.1, y: 0.2)])
            let commit = try await store.replace(candidate: image, document: doc, baselineDigest: doc.contentDigest, epoch: epoch)
            let held = try await store.acquireSourceLease(token: commit.snapshot.sourceToken)
            let unrelated = store.directory.appendingPathComponent(".staging-unknown")
            try Data("keep".utf8).write(to: unrelated)
            faults.set(boundary)
            let result = try await store.clear(expectedWorkspaceID: commit.snapshot.workspaceID, sourceToken: commit.snapshot.sourceToken, previousEpoch: epoch, newEpoch: next)
            switch (boundary, result) {
            case (.beforeClearRemoval, .failed), (.afterClearRemoval, .durabilityUncertain): break
            case (.afterClearSync, .durableEmpty(let warning)), (.beforeClearCleanup, .durableEmpty(let warning)): XCTAssertNotNil(warning)
            default: XCTFail("Incorrect clear result at \(boundary)")
            }
            XCTAssertEqual(try Data(contentsOf: held), originalBytes, "readers survive every clear outcome")
            XCTAssertEqual(try Data(contentsOf: fixture), originalBytes)
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
            do { _ = try await store.save(snapshot: commit.snapshot, epoch: epoch); XCTFail("old save cannot publish") } catch RecoveryError.staleRevision { }
            do { _ = try await store.load(epoch: epoch); XCTFail("old load cannot change worker state") } catch RecoveryError.staleRevision { }
            do { _ = try await store.replace(candidate: image, document: doc, baselineDigest: doc.contentDigest, epoch: epoch); XCTFail("late import cannot publish") } catch RecoveryError.staleRevision { }
            if boundary == .beforeClearRemoval || boundary == .afterClearRemoval {
                // Before success a separate process sees either a valid old pair or empty.
                if boundary == .beforeClearRemoval {
                    let restored = try await RecoveryStore(directory: store.directory).load()
                    XCTAssertEqual(restored?.snapshot.document, doc)
                }
                faults.set(nil)
                let retried = try await store.clear(expectedWorkspaceID: commit.snapshot.workspaceID, sourceToken: commit.snapshot.sourceToken, previousEpoch: next, newEpoch: UUID())
                guard case .durableEmpty = retried else { return XCTFail("retry must synchronize even an absent manifest") }
            }
            await store.releaseSourceLease(token: commit.snapshot.sourceToken)
            XCTAssertFalse(FileManager.default.fileExists(atPath: held.path), "last reader retires the old source")
            let reopened = try await RecoveryStore(directory: store.directory).load()
            XCTAssertNil(reopened, "fresh process stays empty after success")
            XCTAssertEqual(try Data(contentsOf: fixture), originalBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    func testClearBarrierDrainsEarlierSaveAndRejectsLaterOldRequests() async throws {
        let directory = try ImageServiceTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("original.jpg")
        try ImageServiceTests().writeFixture(fixture)
        let candidate = try await ImageService.prepare(url: fixture)
        defer { try? FileManager.default.removeItem(at: candidate.sourceURL) }
        let epoch = UUID(), next = UUID(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let faults = FaultSwitch()
        let store = RecoveryStore(directory: directory.appendingPathComponent("Recovery"), epoch: epoch, fault: { point in
            if point == .beforeManifestWrite {
                do { try faults.check(point) } catch { entered.signal(); release.wait() }
            }
        })
        let doc = CountDocument(image: candidate.identity, markers: [])
        let commit = try await store.replace(candidate: candidate, document: doc, baselineDigest: doc.contentDigest, epoch: epoch)
        faults.set(.beforeManifestWrite)
        let save = Task { try await store.save(snapshot: commit.snapshot, epoch: epoch) }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        XCTAssertTrue(reached)
        let clear = Task { try await store.clear(expectedWorkspaceID: commit.snapshot.workspaceID, sourceToken: commit.snapshot.sourceToken, previousEpoch: epoch, newEpoch: next) }
        release.signal()
        _ = try await save.value
        guard case .durableEmpty = try await clear.value else { return XCTFail("clear must follow the held save") }
        do { _ = try await store.save(snapshot: commit.snapshot, epoch: epoch); XCTFail("old flush rejected") } catch RecoveryError.staleRevision { }
        let empty = try await store.load(epoch: next)
        XCTAssertNil(empty)
    }

    func testCorruptManifestSourceAndSymlinkNeverInstallOrOverwrite() async throws {
        let directory = try ImageServiceTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("source.jpg")
        try ImageServiceTests().writeFixture(fixture)
        let candidate = try await ImageService.prepare(url: fixture)
        defer { try? FileManager.default.removeItem(at:candidate.sourceURL) }
        let recovery = directory.appendingPathComponent("Recovery")
        let store = RecoveryStore(directory:recovery)
        let doc = CountDocument(image:candidate.identity,markers:[Marker(x:0,y:0)])
        let commit = try await store.replace(candidate:candidate,document:doc,baselineDigest:doc.contentDigest)
        let manifest = recovery.appendingPathComponent("current.json")
        let originalManifest = try Data(contentsOf:manifest)
        try Data("broken".utf8).write(to:manifest)
        do { _ = try await RecoveryStore(directory:recovery).load(); XCTFail("corrupt manifest must reject") } catch { }
        XCTAssertEqual(try Data(contentsOf:manifest),Data("broken".utf8))
        try originalManifest.write(to:manifest)
        try FileManager.default.removeItem(at:commit.sourceURL)
        try FileManager.default.createSymbolicLink(at:commit.sourceURL,withDestinationURL:fixture)
        do { _ = try await RecoveryStore(directory:recovery).load(); XCTFail("source symlink must reject") } catch { }
        try FileManager.default.removeItem(at:commit.sourceURL)
        try Data("changed photo".utf8).write(to:commit.sourceURL)
        do { _ = try await RecoveryStore(directory:recovery).load(); XCTFail("changed source must reject") } catch { }
        XCTAssertEqual(try Data(contentsOf:manifest),originalManifest)
    }
}
