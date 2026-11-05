import XCTest
import SwiftUI
import UIKit
import DotCounterCore
@testable import DotCounter

@MainActor final class AppearanceHostedTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppearanceHosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AppearanceHosted-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func workspace() async throws -> Workspace {
        let url = root.appendingPathComponent("synthetic.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            UIColor(white: 0.18, alpha: 1).setFill(); ctx.fill(CGRect(x: 320, y: 0, width: 320, height: 400))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        let w = Workspace(qaDirectory: root.appendingPathComponent("recovery"), defaults: defaults)
        await w.startup(); await w.preparePhoto(url); return w
    }
    private func host<V: View>(_ view: V) throws -> (UIWindow, UIHostingController<V>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller
        window.makeKeyAndVisible(); controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        return (window, controller)
    }
    private func findCanvas(_ view: UIView) -> TouchCanvas? {
        if let canvas = view as? TouchCanvas { return canvas }
        return view.subviews.compactMap { findCanvas($0) }.first
    }
    private func capture(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected asynchronous boundary was not reached")
    }

    func testAppearancePreservesCountRecoveryHistoryReviewViewportAndNativeCanvas() async throws {
        let w = try await workspace()
        w.tap(CGPoint(x: 0.2, y: 0.4), hit: nil); w.tap(CGPoint(x: 0.6, y: 0.4), hit: nil)
        w.tap(CGPoint(x: 0.8, y: 0.7), hit: nil); w.undo()
        w.selectedID = w.markers[0].id; w.mode = .edit
        await w.flush()
        let before = try XCTUnwrap(w.document), revision = try XCTUnwrap(w.snapshot).revision
        let baseline = w.snapshot?.baselineDigest, epoch = w.lifecycleEpoch
        let recovery = try Data(contentsOf: root.appendingPathComponent("recovery/current.json"))
        let sourceHash = try ImageService.hashFile(try XCTUnwrap(w.candidate).sourceURL)
        let key = BirdDetectionKey(workspace: try XCTUnwrap(w.snapshot).workspaceID, source: try XCTUnwrap(w.snapshot).sourceToken,
                                   generation: w.birdGeneration, image: before.image, revision: revision)
        w.birdKey = key; w.birdActivity = .review
        w.birdReview = try BirdReview(key: key, suggestions: [BirdSuggestion(id: "pending", x: 0.8, y: 0.8, width: 2, height: 2, score: 0.5)], eligible: true)
        // Avoid guided targeting when testing presentation-only updates.
        w.editBirdReview { $0.skipAll() }
        let (window, controller) = try host(WorkspaceView(workspace: w)); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let canvas = try XCTUnwrap(findCanvas(controller.view))
        canvas.engine.zoom(2, at: CGPoint(x: 150, y: 100))
        let scale = canvas.engine.viewport.scale, translation = canvas.engine.viewport.translation
        for style in MarkerAppearance.Style.allCases {
            for color in MarkerAppearance.Color.allCases {
                w.setMarkerStyle(style); w.setMarkerColor(color)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(findCanvas(controller.view) === canvas)
                XCTAssertEqual(canvas.engine.appearance, w.appearance, "Explicit observable inputs must update the existing native engine")
                XCTAssertEqual(canvas.engine.viewport.scale, scale); XCTAssertEqual(canvas.engine.viewport.translation, translation)
                XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot?.revision, revision)
                XCTAssertEqual(w.snapshot?.baselineDigest, baseline); XCTAssertEqual(w.lifecycleEpoch, epoch)
                XCTAssertEqual(w.selectedLabel, 1); XCTAssertEqual(w.mode, .edit)
                XCTAssertTrue(w.history.canUndo); XCTAssertTrue(w.history.canRedo)
                XCTAssertEqual(w.birdKey, key); XCTAssertEqual(w.birdActivity, .review)
            }
        }
        w.setMarkerStyle(.plainDots); w.setMarkerColor(.coral)
        let selected = w.appearance; w.setMarkerStyle(.plainDots); w.setMarkerColor(.coral)
        XCTAssertEqual(w.appearance, selected)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recovery/current.json")), recovery)
        XCTAssertEqual(try ImageService.hashFile(try XCTUnwrap(w.candidate).sourceURL), sourceHash)
        w.resetMarkerAppearance(); w.resetMarkerAppearance(); XCTAssertEqual(w.appearance, .defaultAppearance)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot?.revision, revision)
        w.redo(); XCTAssertEqual(w.total, 3); XCTAssertEqual(w.appearance, .defaultAppearance)
        w.undo(); XCTAssertEqual(w.document, before)
        w.setMarkerStyle(.plainDots); w.setMarkerColor(.yellow); await w.flush()
        let restored = Workspace(qaDirectory: root.appendingPathComponent("recovery"), defaults: defaults)
        await restored.startup(); XCTAssertEqual(restored.appearance, w.appearance); XCTAssertEqual(restored.document, before)
        let publicJSON = try before.encoded(), saved = try Data(contentsOf: root.appendingPathComponent("recovery/current.json"))
        XCTAssertFalse(String(decoding: publicJSON, as: UTF8.self).contains("appearance"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("appearance"))
        restored.requestClear(); await restored.confirmClear(try XCTUnwrap(restored.clearTarget))
        XCTAssertNil(restored.document); XCTAssertEqual(restored.appearance, w.appearance)
        let fresh = Workspace(qaDirectory: root.appendingPathComponent("other-recovery"))
        XCTAssertEqual(fresh.appearance, .defaultAppearance)
    }

    func testHeldPNGUsesPresentationCaptureAndRetainsActualFileForCopy() async throws {
        let w = try await workspace(); w.tap(CGPoint(x: 0.5, y: 0.5), hit: nil)
        w.setMarkerStyle(.plainDots); w.setMarkerColor(.yellow)
        w.tap(CGPoint(x: 0.2, y: 0.2), hit: nil)
        w.setConnectionsVisible(true); await w.flush()
        w.showExport(); let capture = try XCTUnwrap(w.exportCapture)
        w.showExport(tab: 1); XCTAssertEqual(w.exportCapture?.id, capture.id)
        var held: CheckedContinuation<Void, Never>?, reached = false
        w.qaSuspend = { point in
            if point == "pngRender" { reached = true; await withCheckedContinuation { held = $0 } }
        }
        let output = ExportSaveState()
        let (window, _) = try host(ExportView(workspace: w, capture: capture, output: output)); defer { window.isHidden = true }
        try await eventually { reached }
        w.setMarkerStyle(.numberedDots); w.setMarkerColor(.coral); w.setConnectionsVisible(false)
        XCTAssertTrue(capture.connections.isVisible)
        // Simulate another same-workspace editor while this capture's renderer is suspended.
        w.history = MarkerHistory(markers: capture.document.markers + [Marker(x: 0.3, y: 0.3)])
        XCTAssertEqual(capture.document.markers.count, 2); XCTAssertEqual(w.total, 3)
        held?.resume(); held = nil
        try await eventually { (try? FileManager.default.contentsOfDirectory(at: output.owner?.url ?? root, includingPropertiesForKeys: nil).contains { $0.pathExtension == "png" }) == true }
        try await Task.sleep(for: .milliseconds(300))
        let rendered = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: XCTUnwrap(output.owner).url, includingPropertiesForKeys: nil).first { $0.pathExtension == "png" })
        let expectedOwner = try TransientDirectory()
        let expected = try await ImageService.renderPNG(sourceURL: capture.source, document: capture.document, directory: expectedOwner.url, appearance: capture.appearance, connections: capture.connections)
        XCTAssertEqual(try Data(contentsOf: rendered), try Data(contentsOf: expected))
        let request = ExportSaveState.Request(source: rendered, filename: "captured.png", kind: "PNG", owner: output.owner)
        let destination = root.appendingPathComponent("captured.png"), baseline = w.snapshot?.baselineDigest
        await output.save(.init(request: request, url: destination, scopedFolder: nil), workspace: w, document: capture.document,
                          workspaceID: capture.workspaceID, sourceToken: capture.sourceToken, requestEpoch: capture.requestEpoch)
        XCTAssertEqual(try Data(contentsOf: rendered), try Data(contentsOf: destination)); XCTAssertEqual(w.snapshot?.baselineDigest, baseline)
        // A destination failure retains the same request/file for retry and claims no completion.
        let failed = ExportSaveState()
        await failed.save(.init(request: request, url: destination, scopedFolder: nil), workspace: w, document: capture.document,
                          workspaceID: capture.workspaceID, sourceToken: capture.sourceToken, requestEpoch: capture.requestEpoch)
        XCTAssertNotNil(failed.error); XCTAssertNotNil(failed.retry); XCTAssertNil(failed.status["PNG"])
        self.capture(window, "Captured Plain dots Yellow PNG after workspace changed to Coral numbered dots")
        w.exportShown = false; w.retireExport(); w.showExport()
        XCTAssertNotEqual(w.exportCapture?.id, capture.id)
        XCTAssertEqual(w.exportCapture?.appearance, w.appearance); XCTAssertEqual(w.exportCapture?.document.markers.count, 3); XCTAssertEqual(w.exportCapture?.connections, .hidden)
        w.qaSuspend = nil; await w.flush()
    }

    func testNativeSettingsWorkspaceAndLargeTextEvidence() async throws {
        let w = try await workspace()
        if let photo = Bundle.main.url(forResource: "QA-flock", withExtension: "jpg") { await w.preparePhoto(photo) }
        for index in 0..<18 { w.tap(CGPoint(x: 0.08 + Double(index%6)*0.16, y: 0.18 + Double(index/6)*0.28), hit: nil) }
        w.tap(.zero, hit: nil); w.tap(CGPoint(x: 1, y: 1), hit: nil)
        w.selectedID = w.markers[17].id
        let (window, _) = try host(WorkspaceView(workspace: w)); defer { window.isHidden = true }
        for style in MarkerAppearance.Style.allCases {
            w.setMarkerStyle(style); w.setMarkerColor(style == .plainDots ? .coral : .legacy)
            try await Task.sleep(for: .milliseconds(180))
            capture(window, "Native workspace \(style.name)")
        }
        let (settings, _) = try host(MarkerAppearanceView(workspace: w)); defer { settings.isHidden = true }
        try await Task.sleep(for: .milliseconds(200)); capture(settings, "Native Marker appearance settings")
        let (large, _) = try host(MarkerAppearanceView(workspace: w).environment(\.dynamicTypeSize, .accessibility3)); defer { large.isHidden = true }
        try await Task.sleep(for: .milliseconds(200)); capture(large, "Native Marker appearance accessibility text")
        func scroll(_ view: UIView) -> UIScrollView? {
            if let value = view as? UIScrollView, value.contentSize.height > value.bounds.height { return value }
            return view.subviews.compactMap { scroll($0) }.first
        }
        if let content = scroll(large) {
            content.setContentOffset(CGPoint(x: 0, y: content.contentSize.height-content.bounds.height+content.adjustedContentInset.bottom), animated: false)
        }
        try await Task.sleep(for: .milliseconds(100)); capture(large, "Native Marker appearance accessibility reset and guidance")
        await w.flush()
    }
}
