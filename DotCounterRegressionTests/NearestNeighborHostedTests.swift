import XCTest
import UIKit
import DotCounterCore
@testable import DotCounter

/// These holds occur after the real detached calculation/history preparation and
/// deliberately ignore cancellation, so publication must pass the production guards.
@MainActor private final class RenumberCompletionGate {
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var entered = 0

    func pause(_ point: String) async throws {
        guard point == "renumberCompletion" else { return }
        entered += 1
        let index = entered
        try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func wait(_ count: Int = 1) async throws {
        for _ in 0..<300 {
            if entered >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Renumber completion did not reach hold \(count)")
        throw CocoaError(.coderInvalidValue)
    }
    func release(_ index: Int = 1, fail: Bool = false) {
        let continuation = waiting.removeValue(forKey: index)
        if fail { continuation?.resume(throwing: CocoaError(.fileReadUnknown)) }
        else { continuation?.resume() }
    }
    func releaseAll() { for index in Array(waiting.keys) { release(index) } }
}

@MainActor final class NearestNeighborHostedTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestNeighborHosted-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "NearestNeighborHosted-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("original.png"))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func workspace(failingClear: Bool = false, directory: URL? = nil) async throws -> Workspace {
        let fault: (@Sendable (RecoveryFaultPoint) throws -> Void)?
        if failingClear {
            fault = { point in if point == .beforeClearRemoval { throw RecoveryError.injected(point) } }
        } else { fault = nil }
        let w = Workspace(qaDirectory: directory ?? root.appendingPathComponent(UUID().uuidString), defaults: defaults, fault: fault)
        await w.startup(); await w.preparePhoto(root.appendingPathComponent("original.png"))
        // Deliberately unrelated to the canonical nearby-dot sequence.
        for point in [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.5, y: 0.8),
                      CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.8, y: 0.4)] {
            w.tap(point, hit: nil)
        }
        await w.flush()
        return w
    }
    private func settle(_ w: Workspace) async throws {
        if let task = w.qaRenumberTask { await task.value }
        XCTAssertFalse(w.renumberPending); XCTAssertFalse(w.renumberProgress)
        XCTAssertNil(w.qaRenumberTask); XCTAssertFalse(w.qaRenumberQueued)
    }
    private func held(_ w: Workspace, _ gate: RenumberCompletionGate) async throws -> Task<Void, Never> {
        w.qaSuspend = { try await gate.pause($0) }
        w.renumber(.nearestNeighbor)
        let task = try XCTUnwrap(w.qaRenumberTask)
        try await gate.wait()
        return task
    }

    func testChangedRouteIsOneEditAndPreservesLiveSelectionAppearanceAndMode() async throws {
        let w = try await workspace()
        let before = try XCTUnwrap(w.document), snapshot = try XCTUnwrap(w.snapshot)
        let undo = w.history.undoCount
        w.selectedID = w.markers[0].id
        let gate = RenumberCompletionGate(); defer { gate.releaseAll() }
        let task = try await held(w, gate)
        XCTAssertEqual(w.document, before, "No partial order is published")
        XCTAssertTrue(w.connections.isVisible, "Visibility is enabled at admission")
        // These changes made while calculating must win over captured presentation.
        let selected = w.markers[3].id
        w.selectedID = selected; w.mode = .edit
        w.setMarkerStyle(.plainDots); w.setMarkerColor(.coral); w.setConnectionsVisible(false)
        gate.release(); await task.value; w.qaSuspend = nil
        let after = try XCTUnwrap(w.document)
        XCTAssertNotEqual(after.markers, before.markers)
        XCTAssertEqual(after.markers, [before.markers[2], before.markers[3], before.markers[1], before.markers[0]])
        XCTAssertEqual(w.history.undoCount, undo+1); XCTAssertEqual(w.snapshot?.revision, snapshot.revision+1)
        XCTAssertEqual(after.image, before.image); XCTAssertEqual(w.snapshot?.sourceToken, snapshot.sourceToken)
        XCTAssertEqual(w.snapshot?.baselineDigest, snapshot.baselineDigest)
        XCTAssertEqual(w.selectedID, selected); XCTAssertEqual(w.selectedLabel, 2); XCTAssertEqual(w.mode, .edit)
        XCTAssertEqual(w.appearance, MarkerAppearance(style: .plainDots, color: .coral)); XCTAssertFalse(w.connections.isVisible)
        w.undo(); XCTAssertEqual(w.document, before); XCTAssertEqual(w.selectedID, selected)
        w.redo(); XCTAssertEqual(w.document, after); XCTAssertEqual(w.selectedID, selected)
        XCTAssertFalse(w.connections.isVisible); await w.flush()
    }

    func testUnchangedRouteEnablesConnectionsWithoutRevisionHistoryOrRedoChanges() async throws {
        let w = try await workspace()
        w.renumber(.nearestNeighbor); try await settle(w)
        w.tap(CGPoint(x: 0.95, y: 0.95), hit: nil); w.undo(); await w.flush()
        let before = w.document, snapshot = w.snapshot, undo = w.history.undoCount, redo = w.history.redoCount
        XCTAssertTrue(w.history.canRedo)
        w.setConnectionsVisible(false)
        w.renumber(.nearestNeighbor)
        XCTAssertTrue(w.connections.isVisible)
        try await settle(w)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot, snapshot)
        XCTAssertEqual(w.history.undoCount, undo); XCTAssertEqual(w.history.redoCount, redo)
        w.redo(); XCTAssertEqual(w.total, 5); await w.flush()
    }

    func testConnectionPreferenceDoesNotEditCountAndSurvivesRecoveryImportAndClear() async throws {
        let directory = root.appendingPathComponent("Recovery")
        let w = try await workspace(directory: directory)
        w.tap(CGPoint(x: 0.9, y: 0.9), hit: nil); w.undo()
        w.selectedID = w.markers[0].id; w.mode = .edit; await w.flush()
        let before = try XCTUnwrap(w.document), snapshot = w.snapshot, epoch = w.lifecycleEpoch
        let undo = w.history.undoCount, redo = w.history.redoCount
        let recoveryURL = directory.appendingPathComponent("current.json")
        let recovery = try Data(contentsOf: recoveryURL)
        let source = try ImageService.hashFile(try XCTUnwrap(w.candidate).sourceURL)
        XCTAssertFalse(w.connections.isVisible)
        for shown in [true, false, true, true] { w.setConnectionsVisible(shown) }
        w.setMarkerStyle(.plainDots); w.setMarkerColor(.yellow); w.resetMarkerAppearance()
        XCTAssertTrue(w.connections.isVisible)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot, snapshot); XCTAssertEqual(w.lifecycleEpoch, epoch)
        XCTAssertEqual(w.selectedLabel, 1); XCTAssertEqual(w.mode, .edit)
        XCTAssertEqual(w.history.undoCount, undo); XCTAssertEqual(w.history.redoCount, redo)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), recovery)
        XCTAssertEqual(try ImageService.hashFile(try XCTUnwrap(w.candidate).sourceURL), source)
        XCTAssertEqual(defaults.object(forKey: ConnectionPresentation.visibilityKey) as? String, "shown")
        let json = root.appendingPathComponent("count.json"); try before.encoded().write(to: json)
        XCTAssertFalse(String(decoding: try before.encoded(), as: UTF8.self).contains("connections"))
        XCTAssertFalse(String(decoding: recovery, as: UTF8.self).contains("connections"))
        let restored = Workspace(qaDirectory: directory, defaults: defaults)
        await restored.startup()
        XCTAssertEqual(restored.document, before); XCTAssertTrue(restored.connections.isVisible)
        await restored.prepareJSON(json); await restored.useCurrentPhoto()
        if restored.showReplacement { await restored.replace() }
        XCTAssertEqual(restored.document, before); XCTAssertTrue(restored.connections.isVisible)
        restored.requestClear(); await restored.confirmClear(try XCTUnwrap(restored.clearTarget))
        XCTAssertNil(restored.document); XCTAssertTrue(restored.connections.isVisible)
        let reopened = Workspace(qaDirectory: directory, defaults: defaults); await reopened.startup()
        XCTAssertNil(reopened.document); XCTAssertTrue(reopened.connections.isVisible)
    }

    func testObsoleteSuccessAndFailureCannotPublishAcrossInvalidationOrigins() async throws {
        let boundaries = ["cancel", "edit", "undo", "redo", "legacyNoOp", "picker", "failedPhoto", "failedJSON",
                          "replacementCanceled", "clearCanceled", "clearFailed", "baseline", "export", "lifecycle"]
        for boundary in boundaries { for failure in [false, true] {
            let w = try await workspace(failingClear: boundary == "clearFailed")
            w.tap(CGPoint(x: 0.95, y: 0.95), hit: nil); w.undo(); await w.flush()
            if boundary == "legacyNoOp" { w.renumber(.leftToRight); await w.flush() }
            let gate = RenumberCompletionGate(); defer { gate.releaseAll() }
            let task = try await held(w, gate)
            let original = w.document
            switch boundary {
            case "cancel": w.cancelRenumber()
            case "edit": w.move(w.markers[0].id, to: CGPoint(x: 0.17, y: 0.69))
            case "undo": w.undo()
            case "redo": w.redo()
            case "legacyNoOp":
                let revision = w.snapshot?.revision
                w.renumber(.leftToRight); XCTAssertEqual(w.snapshot?.revision, revision)
            case "picker": XCTAssertNotNil(w.newRequest())
            case "failedPhoto": await w.preparePhoto(root.appendingPathComponent("missing.png")); XCTAssertNotNil(w.error)
            case "failedJSON": await w.prepareJSON(root.appendingPathComponent("missing.json")); XCTAssertNotNil(w.error)
            case "replacementCanceled":
                await w.preparePhoto(root.appendingPathComponent("original.png")); XCTAssertTrue(w.showReplacement)
                w.cancelReplacement()
            case "clearCanceled": w.requestClear(); XCTAssertNotNil(w.clearTarget); w.clearTarget = nil
            case "clearFailed":
                w.requestClear(); await w.confirmClear(try XCTUnwrap(w.clearTarget)); XCTAssertTrue(w.clearFailed)
            case "baseline":
                w.recordJSONExport(try XCTUnwrap(w.document).contentDigest, workspace: try XCTUnwrap(w.snapshot).workspaceID)
            case "export":
                w.showExport(); XCTAssertEqual(w.exportCapture?.document, original)
                XCTAssertTrue(try XCTUnwrap(w.exportCapture).connections.isVisible)
            default: w.invalidateRenumber() // Same synchronous origin used by scene background/teardown.
            }
            XCTAssertFalse(w.renumberPending, boundary); XCTAssertFalse(w.renumberProgress, boundary)
            let current = w.document, snapshot = w.snapshot, error = w.error, status = w.recoveryMessage
            let undo = w.history.undoCount, redo = w.history.redoCount
            gate.release(fail: failure); await task.value; w.qaSuspend = nil
            XCTAssertEqual(w.document, current, boundary); XCTAssertEqual(w.snapshot, snapshot, boundary)
            XCTAssertEqual(w.history.undoCount, undo, boundary); XCTAssertEqual(w.history.redoCount, redo, boundary)
            XCTAssertEqual(w.error, error, boundary); XCTAssertEqual(w.recoveryMessage, status, boundary)
            XCTAssertFalse(w.renumberFailure, boundary); XCTAssertFalse(w.renumberPending, boundary)
            XCTAssertNil(w.qaRenumberTask); XCTAssertFalse(w.qaRenumberQueued)
            await w.flush()
        } }
    }

    func testNewestOnlyQueueAndProgressRemainOwnedByCurrentRequest() async throws {
        let w = try await workspace(), gate = RenumberCompletionGate()
        defer { gate.releaseAll() }
        let original = w.document, revision = try XCTUnwrap(w.snapshot).revision
        let old = try await held(w, gate)
        try await Task.sleep(for: .milliseconds(80)); XCTAssertFalse(w.renumberProgress)
        try await Task.sleep(for: .milliseconds(220)); XCTAssertTrue(w.renumberProgress)
        for _ in 0..<8 { w.renumber(.nearestNeighbor) }
        XCTAssertTrue(w.renumberPending); XCTAssertFalse(w.renumberProgress); XCTAssertTrue(w.qaRenumberQueued)
        w.setConnectionsVisible(false)
        gate.release(fail: true); await old.value
        try await gate.wait(2)
        XCTAssertEqual(gate.entered, 2, "Displaced queued captures never start")
        XCTAssertFalse(w.qaRenumberQueued); XCTAssertTrue(w.renumberPending); XCTAssertFalse(w.renumberFailure)
        XCTAssertEqual(w.document, original, "Obsolete finalizer cannot install an old result")
        gate.release(2); try await settle(w); w.qaSuspend = nil
        XCTAssertEqual(w.snapshot?.revision, revision+1); XCTAssertFalse(w.connections.isVisible)
        XCTAssertEqual(gate.entered, 2); await w.flush()
    }

    func testCancelEndsPendingImmediatelyAndCurrentFailureAllowsRetry() async throws {
        let w = try await workspace(), gate = RenumberCompletionGate()
        defer { gate.releaseAll() }
        let before = w.document, snapshot = w.snapshot
        let canceled = try await held(w, gate)
        try await Task.sleep(for: .milliseconds(300)); XCTAssertTrue(w.renumberProgress)
        w.setConnectionsVisible(false); w.cancelRenumber()
        XCTAssertFalse(w.renumberPending); XCTAssertFalse(w.renumberProgress); XCTAssertFalse(w.renumberFailure)
        gate.release(fail: true); await canceled.value
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot, snapshot); XCTAssertFalse(w.connections.isVisible)
        w.renumber(.nearestNeighbor)
        let failed = try XCTUnwrap(w.qaRenumberTask); try await gate.wait(2)
        gate.release(2, fail: true); await failed.value
        XCTAssertTrue(w.renumberFailure); XCTAssertFalse(w.renumberPending)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot, snapshot)
        w.qaSuspend = nil; w.renumber(.nearestNeighbor); try await settle(w)
        XCTAssertFalse(w.renumberFailure); XCTAssertNotEqual(w.document, before); await w.flush()
    }
}
